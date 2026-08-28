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

/// Perp-dex index of a canonical market id (`hl:<dexIndex>:<symbol>`), or nil
/// when the id is not in the three-segment form (a bare symbol, or a venue that
/// does not carry a dex index).
private func perpDexIndexOf(_ market: String?) -> Int? {
    guard let market else { return nil }
    let parts = market.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3, let idx = Int(parts[1]), idx >= 0 else { return nil }
    return idx
}

/// Both buying-power numbers for an account, and which one `market` uses.
struct ResolvedAvailability {
    let available: Double
    let crossDex: Double
    let native: Double
    let enforced: Bool
    let rate: Double
}

/// Both of an account's buying-power numbers, from an ``ExchangeState`` you
/// already have. No network call.
///
/// ``Arca/watchMaxOrderSize(options:)`` reports this on every tick as
/// ``ActiveAssetData/availability``; this is the same computation for callers
/// holding a one-shot `getExchangeState` result — a market list, a portfolio
/// header, or an order ticket not driving a live slider.
///
/// ```swift
/// let state = try await arca.getExchangeState(objectId: objectId)
/// let a = marketAvailability(exchangeState: state, market: "hl:1:NVDA")
/// a.crossDexAvailableUsd  // buying power on NVIDIA (and every non-native dex)
/// a.nativeAvailableUsd    // buying power on hl:0:* — larger when native is >10x
/// a.reservationEnforced   // whether THIS market draws on the shared pool
/// ```
///
/// On a venue that declares no reservation both numbers are equal and
/// `reservationEnforced` is false, so a caller can render one code path.
public func marketAvailability(exchangeState: ExchangeState, market: String) -> AvailabilityBreakdown {
    let summary = exchangeState.crossMarginSummary ?? exchangeState.marginSummary
    let a = resolveAvailability(
        exchangeState: exchangeState, market: market,
        equity: parsePositiveDouble(summary.equity),
        initialMarginUsed: parsePositiveDouble(summary.initialMarginUsed))
    return AvailabilityBreakdown(
        reservationEnforced: a.enforced,
        crossDexAvailableUsd: toDecimalString(a.crossDex),
        nativeAvailableUsd: toDecimalString(a.native),
        reservationRate: toDecimalString(a.rate))
}

/// An account on a venue with a cross-dex reservation has exactly TWO buying
/// power numbers, and this returns both.
///
///     native   = equity - totalMargin           (the venue-native dex)
///     crossDex = totalCollateral - reserved     (shared by EVERY other dex)
///     reserved = max(marginNative, rate * notionalNative) + marginOnOtherDexes
///
/// Pinned against Hyperliquid mainnet on 2026-08-28 across three live accounts
/// and nine constructed states. Two properties are load-bearing and an earlier
/// revision of this function got both wrong:
///
/// - The notional floor applies to the VENUE-NATIVE dex only. A position on any
///   other dex contributes exactly its own initial margin and is never charged
///   the floor.
/// - Every non-native dex shares the ONE `crossDex` number. A position on one of
///   them costs its margin uniformly — on the native dex, on itself, and on
///   every sibling alike. Only a native position is asymmetric, and only above
///   `1/rate` leverage, where the floor exceeds the margin it posted.
///
/// The intuition: the shared pool is charged as if the native position had been
/// opened at `1/rate` leverage. Native leverage beyond that is invisible to the
/// native dex's own budget and charged in full to every other dex.
func resolveAvailability(
    exchangeState: ExchangeState,
    market: String,
    equity: Double,
    initialMarginUsed: Double
) -> ResolvedAvailability {
    let native = max(0, equity - initialMarginUsed)
    let model = exchangeState.collateralModel
    let rate = parsePositiveDouble(model?.crossDexReservationRate)
    let total = parsePositiveDouble(model?.totalCollateralUsd)

    // No declared rule (a single-pool venue), or a term the venue did not send:
    // there is one budget and it is the ordinary one. Never guess a reservation.
    guard let model, model.crossDexReservationEnforced, rate > 0, total > 0 else {
        return ResolvedAvailability(available: native, crossDex: native,
                                    native: native, enforced: false, rate: rate)
    }

    var marginNative = 0.0, notionalNative = 0.0, marginOtherDexes = 0.0
    for p in exchangeState.positions {
        guard let d = perpDexIndexOf(p.market) else { continue }
        let mu = parsePositiveDouble(p.marginUsed)
        if d == 0 {
            marginNative += mu
            notionalNative += parsePositiveDouble(p.positionValue)
        } else {
            marginOtherDexes += mu
        }
    }
    let reserved = max(marginNative, rate * notionalNative) + marginOtherDexes
    let crossDex = max(0, total - reserved)
    // The native dex keeps the ordinary budget; every other dex draws on the
    // shared pool — including one this account already holds a position on,
    // because adding there still has to move collateral into it.
    let onNativeDex = perpDexIndexOf(market) == 0
    return ResolvedAvailability(available: onNativeDex ? native : crossDex,
                                crossDex: crossDex, native: native,
                                enforced: !onNativeDex, rate: rate)
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
    bidRatio: Double = 1,
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
    let avail = resolveAvailability(exchangeState: exchangeState, market: market,
                                    equity: equity, initialMarginUsed: initialMarginUsed)
    let available = max(0, avail.available * availableGuard)
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

    let rawAvailableUsd = avail.available

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
        askPx: toDecimalString(buyPx),
        availability: AvailabilityBreakdown(
            reservationEnforced: avail.enforced,
            crossDexAvailableUsd: toDecimalString(avail.crossDex),
            nativeAvailableUsd: toDecimalString(avail.native),
            reservationRate: toDecimalString(avail.rate)
        )
    )
}
