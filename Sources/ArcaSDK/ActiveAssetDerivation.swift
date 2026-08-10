import Foundation

private let safetyMarginFactor: Double = 1.001 // 10 bps multiplicative buffer on total cost
// The Arca network takes no platform fee. When the server omits a platformFee
// rate we assume 0; the server reports the live rate in feeRates.platformFee
// if a network fee is ever re-enabled.
private let defaultPlatformFeeRate: Double = 0   // Arca network fee disabled

private func parsePositiveDouble(_ value: String?) -> Double {
    guard let value, let n = Double(value), n.isFinite, n > 0 else { return 0 }
    return n
}

private func floorToDecimals(_ value: Double, _ decimals: Int) -> Double {
    guard value.isFinite, value > 0 else { return 0 }
    let factor = pow(10.0, Double(decimals))
    // IEEE 754: division can land epsilon above a tick boundary, e.g.
    // 0.004099... becomes 0.00410000000000001, making floor(x * 10000) = 41
    // instead of 40. Nudge down by 1e-9 before flooring to prevent overshoot.
    return max(0, (value * factor - 1e-9).rounded(.down)) / factor
}

private func toDecimalString(_ value: Double, decimals: Int = 8) -> String {
    guard value.isFinite else { return "0" }
    var s = String(format: "%.\(decimals)f", value)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s
}

/// Derives ``ActiveAssetData`` from an ``ExchangeState`` and user-selected
/// trading parameters, matching the TypeScript SDK's
/// `deriveActiveAssetDataFromState` implementation.
public func deriveActiveAssetData(
    from exchangeState: ExchangeState,
    market: String,
    markPx: Double,
    leverage: Int,
    side: OrderSide,
    builderFeeBps: Int = 0,
    szDecimals: Int = 5,
    feeScale: Double = 1,
    // Per-asset base MMR resolved by the caller (e.g. from the initial
    // `getActiveAssetData` fetch). Server derives this from the asset's
    // margin table (`0.5 / firstTier.maxLeverage`) and falls back to 0.03
    // when there is no table. We fall back to the same default when the
    // caller omits it.
    maintenanceMarginRate: String? = nil,
    // Ordered margin tiers for laddered leverage. Server populates this for tiered assets.
    marginTiers: [MarginTier]? = nil,
    // Directional spread ratios (ask/mid and bid/mid) resolved once from the
    // server snapshot. The market-order margin check prices buys at the ask and
    // sells at the bid, so we convert the live mid to the directional execution
    // price via these ratios. Default 1 (no spread) reproduces mid-based sizing.
    askRatio: Double = 1,
    bidRatio: Double = 1
) -> ActiveAssetData? {
    guard markPx.isFinite, markPx > 0, leverage > 0 else { return nil }

    // Cross bucket, not the account-wide summary. The server budgets orders
    // from cross equity alone (PositionService.AvailableBalance) because an
    // isolated position's collateral and P&L are locked to that position and
    // can neither fund nor drain another order. Deriving from `marginSummary`
    // instead lets an isolated position's unrealized profit inflate the
    // previewed max above what the venue will accept. Falls back to
    // `marginSummary` for older servers that do not send the cross bucket
    // (identical when nothing is isolated).
    let summary = exchangeState.crossMarginSummary ?? exchangeState.marginSummary
    let equity = parsePositiveDouble(summary.equity)
    let initialMarginUsed = parsePositiveDouble(summary.initialMarginUsed)
    let hasPositions = !exchangeState.positions.isEmpty
    let availableGuard: Double = hasPositions ? 0.97 : 1.0
    let available = max(0, (equity - initialMarginUsed) * availableGuard)
    let takerRate = parsePositiveDouble(exchangeState.feeRates?.taker)
    let effectiveScale = feeScale.isFinite && feeScale > 0 ? feeScale : 1
    let platformRate: Double = {
        let parsed = parsePositiveDouble(exchangeState.feeRates?.platformFee)
        return parsed > 0 ? parsed : defaultPlatformFeeRate
    }()
    let builderRate = builderFeeBps > 0 ? Double(builderFeeBps) / 100_000 : 0
    let feeRate = takerRate * effectiveScale + platformRate + builderRate

    // Directional execution prices. Max notional is price-independent (a
    // function of available budget, margin rate, and fee rate); the price only
    // enters when converting notional -> tokens. Buys execute at the ask, sells
    // at the bid, so dividing by the directional price (not the mid) makes the
    // previewed max match the server's margin check.
    let safeAskRatio = askRatio.isFinite && askRatio > 0 ? askRatio : 1
    let safeBidRatio = bidRatio.isFinite && bidRatio > 0 ? bidRatio : 1
    let buyPx = markPx * safeAskRatio
    let sellPx = markPx * safeBidRatio

    func maxTokensForDir(_ avail: Double, _ execPx: Double) -> Double {
        guard avail.isFinite, avail > 0 else { return 0 }
        let targetSpend = avail / safetyMarginFactor

        var activeRate = 1.0 / Double(leverage)
        var deduction = 0.0

        if let tiers = marginTiers, !tiers.isEmpty {
            let tierMaxLev = tiers[0].maxLeverage
            var effLev = leverage
            if tierMaxLev < effLev { effLev = tierMaxLev }
            activeRate = 1.0 / Double(effLev)
            var prevRate = activeRate
            var prevDeduction = 0.0

            for tier in tiers {
                guard let lowerBound = Double(tier.lowerBound) else { continue }

                let tierLev = tier.maxLeverage
                var lev = leverage
                if tierLev < lev { lev = tierLev }
                let rate = 1.0 / Double(lev)

                let nextDeduction = prevDeduction + lowerBound * (rate - prevRate)
                let spendAtBound = lowerBound * rate - nextDeduction + lowerBound * feeRate

                if targetSpend < spendAtBound {
                    break
                }

                activeRate = rate
                prevRate = rate
                prevDeduction = nextDeduction
                deduction = nextDeduction
            }
        }

        let notional = (targetSpend + deduction) / (activeRate + feeRate)
        guard notional.isFinite, notional > 0 else { return 0 }
        return floorToDecimals(notional / execPx, szDecimals)
    }

    let currentPosition = exchangeState.positions.first { $0.market == market }
    // Each side splits into the part that reduces the open position and the
    // part that opens new exposure. The reduce leg is unconditional — a
    // strictly-reducing fill lowers both the initial and the maintenance
    // requirement, so the venue never refuses it for balance.
    var buyReduce: Double = 0
    var buyOpen: Double = 0
    var sellReduce: Double = 0
    var sellOpen: Double = 0

    if let pos = currentPosition {
        let posSize = parsePositiveDouble(pos.size)
        // Isolated positions carry dedicated collateral that can exceed the
        // leverage-implied marginUsed after updateIsolatedMargin; closing
        // releases that full amount. Mirrors the server's lockedCollateral().
        let isolated = parsePositiveDouble(pos.isolatedMargin)
        let posMargin = isolated > 0 ? isolated : parsePositiveDouble(pos.marginUsed)
        let closeFees = posSize * markPx * feeRate * safetyMarginFactor
        let availableAfterClose = max(0, available + posMargin - closeFees)

        switch pos.side {
        case .long:
            buyOpen = maxTokensForDir(available, buyPx)
            sellReduce = posSize
            sellOpen = maxTokensForDir(availableAfterClose, sellPx)
        case .short:
            sellOpen = maxTokensForDir(available, sellPx)
            buyReduce = posSize
            buyOpen = maxTokensForDir(availableAfterClose, buyPx)
        }
    } else {
        buyOpen = maxTokensForDir(available, buyPx)
        sellOpen = maxTokensForDir(available, sellPx)
    }

    // Only the open legs are floored, and only because they are budget-derived:
    // floorToDecimals deliberately nudges down to avoid advertising a size the
    // venue would refuse. The reduce legs are the position size itself, already
    // at the venue's tick precision, and that nudge would shave a tick off them
    // (0.02 -> 0.01999) — leaving the user unable to fully close from a slider
    // that reads this. The server floors both with exact decimal math, where
    // the reduce leg is a no-op.
    buyOpen = floorToDecimals(buyOpen, szDecimals)
    sellOpen = floorToDecimals(sellOpen, szDecimals)
    let buyMax = buyReduce + buyOpen
    let sellMax = sellReduce + sellOpen

    let rawAvailableUsd = max(0, equity - initialMarginUsed)

    return ActiveAssetData(
        market: market,
        leverage: LeverageInfo(type: .cross, value: leverage),
        maxBuySize: toDecimalString(buyMax, decimals: szDecimals),
        maxSellSize: toDecimalString(sellMax, decimals: szDecimals),
        maxBuyUsd: toDecimalString(buyMax * markPx),
        maxSellUsd: toDecimalString(sellMax * markPx),
        maxBuyReduceSize: toDecimalString(buyReduce, decimals: szDecimals),
        maxBuyOpenSize: toDecimalString(buyOpen, decimals: szDecimals),
        maxSellReduceSize: toDecimalString(sellReduce, decimals: szDecimals),
        maxSellOpenSize: toDecimalString(sellOpen, decimals: szDecimals),
        availableToTrade: toDecimalString(rawAvailableUsd),
        markPx: toDecimalString(markPx),
        feeRate: toDecimalString(feeRate),
        maintenanceMarginRate: maintenanceMarginRate ?? "0.03",
        marginTiers: marginTiers,
        // Live directional prices = mid * resolved spread ratio. Equal to markPx
        // until the spread is resolved (ratio 1).
        bidPx: toDecimalString(sellPx),
        askPx: toDecimalString(buyPx)
    )
}
