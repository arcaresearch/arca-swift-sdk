import Foundation

// MARK: - Exchange State

public struct SimAccount: Codable, Sendable {
    public let id: SimAccountID
    public let realmId: RealmID
    public let name: String
    public let createdAt: String
    public let updatedAt: String
}

public struct SimMarginSummary: Codable, Sendable {
    public let equity: String
    public let initialMarginUsed: String
    public let maintenanceMarginRequired: String
    public let availableToWithdraw: String
    public let totalNtlPos: String
    public let totalUnrealizedPnl: String
    public let totalRawUsd: String?
}

public struct SimPosition: Codable, Sendable {
    public let id: SimPositionID
    public let accountId: SimAccountID?
    public let realmId: RealmID?
    public let coin: String
    public let side: PositionSide
    public let size: String
    public let entryPrice: String
    public let leverage: Int
    public let marginUsed: String
    public let liquidationPrice: String?
    public let unrealizedPnl: String?
    public let returnOnEquity: String?
    public let positionValue: String?
    /// Present when computed fields (unrealizedPnl, positionValue, returnOnEquity) could not be calculated.
    public let error: String?
    public let createdAt: String?
    public let updatedAt: String?
}

struct PositionListResponse: Codable, Sendable {
    let positions: [SimPosition]
    let total: Int
}

public struct SimOrder: Codable, Sendable {
    public let id: SimOrderID
    public let accountId: SimAccountID?
    public let realmId: RealmID?
    public let coin: String
    public let side: OrderSide
    public let orderType: OrderType
    public let price: String?
    public let size: String
    public let filledSize: String
    public let avgFillPrice: String?
    public let status: OrderStatus
    public let reduceOnly: Bool
    public let timeInForce: TimeInForce
    public let leverage: Int
    public let builderFeeBps: Int?
    public let createdAt: String?
    public let updatedAt: String?
}

public extension SimOrder {
    /// `true` when the order reached a terminal status and has at least one fill.
    /// Covers both fully filled orders and IOC orders whose unfilled remainder was cancelled.
    var isTerminalWithFills: Bool {
        switch status {
        case .filled:
            return true
        case .cancelled:
            return filledSize != "0" && !filledSize.isEmpty
        case .failed, .pending, .open, .partiallyFilled:
            return false
        }
    }

    /// `true` when the order was partially filled and the remainder cancelled (IOC semantics).
    var isPartiallyFilled: Bool {
        status == .cancelled && filledSize != "0" && !filledSize.isEmpty && filledSize != size
    }
}

public struct SimFill: Codable, Sendable {
    public let id: SimFillID
    public let orderId: SimOrderID
    public let accountId: SimAccountID
    public let realmId: RealmID
    public let coin: String
    public let side: OrderSide
    public let price: String
    public let size: String
    public let fee: String
    public let builderFee: String?
    public let realizedPnl: String?
    public let isLiquidation: Bool
    public let createdAt: String
}

public struct FundingPayment: Codable, Sendable {
    public let accountId: String
    public let coin: String
    public let side: String
    public let size: String
    public let price: String
    public let fundingRate: String
    public let payment: String
}

public struct SimFeeTierEntry: Codable, Sendable {
    public let tier: Int
    public let label: String
    public let minVolume14d: Int
    public let takerBps: Int
    public let makerBps: Int
}

public struct SimFeeRates: Codable, Sendable {
    public let taker: String
    public let maker: String
    public let platformFee: String?
    public let tier: Int?
    public let tierLabel: String?
    public let volume14d: String?
    public let schedule: [SimFeeTierEntry]?
}

/// A pending order operation projected as a structured intent.
/// Analogous to a transfer hold: "we intend to place this order
/// but haven't heard back from the venue yet."
public struct ExchangeIntent: Codable, Sendable {
    public let operationId: String
    public let operationPath: String
    public let coin: String
    public let side: String
    public let size: String
    public let orderType: String
    public let reduceOnly: Bool
    public let createdAt: String
}

public struct ExchangeState: Codable, Sendable {
    public let account: SimAccount
    public let marginSummary: SimMarginSummary
    public let crossMarginSummary: SimMarginSummary?
    public let crossMaintenanceMarginUsed: String?
    public let positions: [SimPosition]
    public let openOrders: [SimOrder]
    public let feeRates: SimFeeRates?
    /// Pending order operations that haven't settled yet.
    public let pendingIntents: [ExchangeIntent]?
}

public struct SimOrderWithFills: Codable, Sendable {
    public let order: SimOrder
    public let fills: [SimFill]
}

// MARK: - Active Asset Data

public struct LeverageInfo: Codable, Sendable {
    public let type: LeverageType
    public let value: Int
}

public struct ActiveAssetData: Codable, Sendable {
    public let coin: String
    public let leverage: LeverageInfo
    /// Max buy size in tokens (positive).
    public let maxBuySize: String
    /// Max sell size in tokens (positive).
    public let maxSellSize: String
    /// Max buy size in USD (positive).
    public let maxBuyUsd: String
    /// Max sell size in USD (positive).
    public let maxSellUsd: String
    /// Buy/sell token amounts currently available to trade [buy, sell].
    public let availableToTrade: [String]?
    public let markPx: String
    public let feeRate: String
}

// MARK: - Leverage

public struct UpdateLeverageResponse: Codable, Sendable {
    public let accountId: String
    public let coin: String
    public let leverage: Int
    public let previousLeverage: Int
}

public struct LeverageSetting: Codable, Sendable {
    public let coin: String
    public let leverage: Int
}

// MARK: - Order Operation

public struct OrderOperationResponse: Codable, Sendable, OperationResponse {
    public let operation: Operation

    public func withOperation(_ op: Operation) -> Self {
        .init(operation: op)
    }
}

// MARK: - Fee Target

public struct FeeTarget: Codable, Sendable {
    public let arcaPath: String
    public let percentage: Int
}

// MARK: - Market Data

public struct SimMetaAsset: Codable, Sendable {
    public let name: String
    public let dex: String?
    public let symbol: String
    public let exchange: String
    public let index: Int
    public let szDecimals: Int
    public let maxLeverage: Int
    public let onlyIsolated: Bool
}

public struct SimMetaResponse: Codable, Sendable {
    public let universe: [SimMetaAsset]
}

public struct SimMidsResponse: Codable, Sendable {
    public let mids: [String: String]
}

public struct MarketTicker: Codable, Sendable {
    public let coin: String
    public let dex: String?
    public let symbol: String
    public let exchange: String
    public let markPx: String
    public let midPx: String
    public let prevDayPx: String
    public let dayNtlVlm: String
    public let priceChange24hPct: String
    public let openInterest: String
    public let funding: String
    /// Unix timestamp in milliseconds of the next funding event.
    public let nextFundingTime: Int64?
    public let isDelisted: Bool
}

public struct MarketTickersResponse: Codable, Sendable {
    public let tickers: [MarketTicker]
}

public struct SimBookLevel: Codable, Sendable {
    public let price: String
    public let size: String
    public let orderCount: Int
}

public struct SimBookResponse: Codable, Sendable {
    public let coin: String
    public let bids: [SimBookLevel]
    public let asks: [SimBookLevel]
    public let time: Int
}

// MARK: - Candle Data

public enum CandleInterval: String, Codable, Sendable, CaseIterable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case fourHours = "4h"
    case oneDay = "1d"
}

public struct Candle: Codable, Sendable {
    public let t: Int
    public let o: String
    public let h: String
    public let l: String
    public let c: String
    public let v: String
    public let n: Int
}

public struct CandlesResponse: Codable, Sendable {
    public let coin: String
    public let interval: String
    public let candles: [Candle]
}

public struct CandleEvent: Sendable {
    public let coin: String
    public let interval: CandleInterval
    public let candle: Candle
}

// MARK: - Sparklines

public struct SparklinesResponse: Codable, Sendable {
    public let sparklines: [String: [Double]]
}

// MARK: - Fill / Trade History (Platform-Side)

public struct FillResultingPosition: Codable, Sendable {
    public let side: PositionSide
    public let size: String
    public let entryPx: String?
    public let leverage: Int
}

public struct Fill: Codable, Sendable {
    public let id: String
    public let operationId: String
    public let orderOperationId: String?
    public let orderId: String?
    public let market: String
    public let side: OrderSide?
    public let size: String?
    public let price: String?
    public let dir: String?
    public let startPosition: String?
    public let fee: String?
    public let exchangeFee: String?
    public let platformFee: String?
    public let builderFee: String?
    public let realizedPnl: String?
    public let resultingPosition: FillResultingPosition
    public let isLiquidation: Bool?
    public let createdAt: String
}

public struct FillListResponse: Codable, Sendable {
    public let fills: [Fill]
    public let total: Int
    public let cursor: String?
}

public struct MarketTradeSummaryItem: Codable, Sendable {
    public let market: String
    public let totalRealizedPnl: String
    public let totalFees: String
    public let tradeCount: Int
    public let totalVolume: String
}

public struct TradeSummaryTotals: Codable, Sendable {
    public let totalRealizedPnl: String
    public let totalFees: String
    public let tradeCount: Int
    public let totalVolume: String
}

public struct TradeSummaryResponse: Codable, Sendable {
    public let markets: [MarketTradeSummaryItem]
    public let totals: TradeSummaryTotals
}
