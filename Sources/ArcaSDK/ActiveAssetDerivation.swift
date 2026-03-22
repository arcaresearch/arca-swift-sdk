import Foundation

private let extraNotionalBufferRate: Double = 0.00005 // 0.5 bps
private let defaultPlatformFeeRate: Double = 0.0001   // 1 bps

private func parsePositiveDouble(_ value: String?) -> Double {
    guard let value, let n = Double(value), n.isFinite, n > 0 else { return 0 }
    return n
}

private func floorToDecimals(_ value: Double, _ decimals: Int) -> Double {
    guard value.isFinite, value > 0 else { return 0 }
    let factor = pow(10.0, Double(decimals))
    return (value * factor).rounded(.down) / factor
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
    szDecimals: Int = 5
) -> ActiveAssetData? {
    guard markPx.isFinite, markPx > 0, leverage > 0 else { return nil }

    let available = parsePositiveDouble(exchangeState.marginSummary.availableToWithdraw)
    let takerRate = parsePositiveDouble(exchangeState.feeRates?.taker)
    let platformRate: Double = {
        let parsed = parsePositiveDouble(exchangeState.feeRates?.platformFee)
        return parsed > 0 ? parsed : defaultPlatformFeeRate
    }()
    let builderRate = builderFeeBps > 0 ? Double(builderFeeBps) / 100_000 : 0
    let feeRate = takerRate + platformRate + builderRate
    let calcFeeRate = feeRate + extraNotionalBufferRate
    let costPerToken = markPx / Double(leverage) + markPx * calcFeeRate
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
        let closeFees = posSize * markPx * calcFeeRate
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

    return ActiveAssetData(
        coin: coin,
        leverage: LeverageInfo(type: .cross, value: leverage),
        maxBuySize: toDecimalString(buyMax, decimals: szDecimals),
        maxSellSize: toDecimalString(sellMax, decimals: szDecimals),
        maxBuyUsd: toDecimalString(buyMax * markPx),
        maxSellUsd: toDecimalString(sellMax * markPx),
        availableToTrade: [
            toDecimalString(buyMax, decimals: szDecimals),
            toDecimalString(sellMax, decimals: szDecimals),
        ],
        markPx: toDecimalString(markPx),
        feeRate: toDecimalString(feeRate)
    )
}
