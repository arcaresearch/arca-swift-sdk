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
    feeScale: Double = 1
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
    let costPerToken = (markPx / Double(leverage) + markPx * feeRate) * safetyMarginFactor
    guard costPerToken > 0 else { return nil }

    func maxTokensForDir(_ avail: Double) -> Double {
        guard avail.isFinite, avail > 0 else { return 0 }
        return floorToDecimals(avail / costPerToken, szDecimals)
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
        feeRate: toDecimalString(feeRate)
    )
}
