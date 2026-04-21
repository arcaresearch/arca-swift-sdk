import Foundation

private let safetyMarginFactor: Double = 1.001 // 10 bps multiplicative buffer on total cost
private let defaultPlatformFeeRate: Double = 0.0001   // 1 bps

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
    coin: String,
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
    marginTiers: [MarginTier]? = nil
) -> ActiveAssetData? {
    guard markPx.isFinite, markPx > 0, leverage > 0 else { return nil }

    let equity = parsePositiveDouble(exchangeState.marginSummary.equity)
    let initialMarginUsed = parsePositiveDouble(exchangeState.marginSummary.initialMarginUsed)
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

    func maxTokensForDir(_ avail: Double) -> Double {
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
        return floorToDecimals(notional / markPx, szDecimals)
    }

    let currentPosition = exchangeState.positions.first { $0.coin == coin }
    var buyMax: Double = 0
    var sellMax: Double = 0

    if let pos = currentPosition {
        let posSize = parsePositiveDouble(pos.size)
        let posMargin = parsePositiveDouble(pos.marginUsed)
        let closeFees = posSize * markPx * feeRate * safetyMarginFactor
        let availableAfterClose = max(0, available + posMargin - closeFees)

        switch pos.side {
        case .long:
            buyMax = maxTokensForDir(available)
            sellMax = posSize + maxTokensForDir(availableAfterClose)
        case .short:
            sellMax = maxTokensForDir(available)
            buyMax = posSize + maxTokensForDir(availableAfterClose)
        }
    } else {
        buyMax = maxTokensForDir(available)
        sellMax = maxTokensForDir(available)
    }

    buyMax = floorToDecimals(buyMax, szDecimals)
    sellMax = floorToDecimals(sellMax, szDecimals)

    let rawAvailableUsd = max(0, equity - initialMarginUsed)

    return ActiveAssetData(
        coin: coin,
        leverage: LeverageInfo(type: .cross, value: leverage),
        maxBuySize: toDecimalString(buyMax, decimals: szDecimals),
        maxSellSize: toDecimalString(sellMax, decimals: szDecimals),
        maxBuyUsd: toDecimalString(buyMax * markPx),
        maxSellUsd: toDecimalString(sellMax * markPx),
        availableToTrade: toDecimalString(rawAvailableUsd),
        markPx: toDecimalString(markPx),
        feeRate: toDecimalString(feeRate),
        maintenanceMarginRate: maintenanceMarginRate ?? "0.03",
        marginTiers: marginTiers
    )
}
