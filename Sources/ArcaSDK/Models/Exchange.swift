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
    public let cumulativeFunding: String?
    public let createdAt: String?
    public let updatedAt: String?
}

struct PositionListResponse: Codable, Sendable {
    let positions: [SimPosition]
    let total: Int
}

struct OrderListResponse: Codable, Sendable {
    let orders: [SimOrder]
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
    public let isTrigger: Bool?
    public let triggerPx: String?
    public let isMarket: Bool?
    public let tpsl: String?
    public let grouping: String?
    public let parentOrderId: String?
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
        case .failed, .pending, .open, .partiallyFilled, .waitingForTrigger, .triggered:
            return false
        }
    }

    /// `true` when the order was partially filled and the remainder cancelled (IOC semantics).
    var isPartiallyFilled: Bool {
        status == .cancelled && filledSize != "0" && !filledSize.isEmpty && filledSize != size
    }

    /// `true` when this is a trigger (TP/SL) order.
    var isTriggerOrder: Bool {
        isTrigger == true
    }
}

public struct SimFill: Codable, Sendable {
    public let id: SimFillID
    public let orderId: SimOrderID
    public let accountId: SimAccountID?
    public let realmId: RealmID?
    public let coin: String
    public let side: OrderSide
    public let price: String
    public let size: String
    public let fee: String
    public let builderFee: String?
    public let platformFee: String?
    public let realizedPnl: String?
    public let isLiquidation: Bool
    public let createdAt: String?
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

    public init(
        account: SimAccount, marginSummary: SimMarginSummary,
        crossMarginSummary: SimMarginSummary?, crossMaintenanceMarginUsed: String?,
        positions: [SimPosition], openOrders: [SimOrder],
        feeRates: SimFeeRates?, pendingIntents: [ExchangeIntent]?
    ) {
        self.account = account; self.marginSummary = marginSummary
        self.crossMarginSummary = crossMarginSummary
        self.crossMaintenanceMarginUsed = crossMaintenanceMarginUsed
        self.positions = positions; self.openOrders = openOrders
        self.feeRates = feeRates; self.pendingIntents = pendingIntents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(SimAccount.self, forKey: .account)
        marginSummary = try container.decode(SimMarginSummary.self, forKey: .marginSummary)
        crossMarginSummary = try container.decodeIfPresent(SimMarginSummary.self, forKey: .crossMarginSummary)
        crossMaintenanceMarginUsed = try container.decodeIfPresent(String.self, forKey: .crossMaintenanceMarginUsed)
        positions = try container.decodeIfPresent([SimPosition].self, forKey: .positions) ?? []
        openOrders = try container.decodeIfPresent([SimOrder].self, forKey: .openOrders) ?? []
        feeRates = try container.decodeIfPresent(SimFeeRates.self, forKey: .feeRates)
        pendingIntents = try container.decodeIfPresent([ExchangeIntent].self, forKey: .pendingIntents)
    }

    private enum CodingKeys: String, CodingKey {
        case account, marginSummary, crossMarginSummary, crossMaintenanceMarginUsed
        case positions, openOrders, feeRates, pendingIntents
    }
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
    /// Raw available margin in USD (equity minus margin in use). Direction-agnostic.
    /// Use for "buying power" display. Per-side max exposure uses maxBuyUsd/maxSellUsd.
    public let availableToTrade: String
    public let markPx: String
    /// Effective fee rate as a decimal (all-in: exchange taker + platform + builder fee).
    public let feeRate: String
}

// MARK: - Asset Fee Rates

/// Per-asset fee rate entry returned by `getAssetFees`.
public struct AssetFeeEntry: Codable, Sendable {
    /// Coin in canonical format (e.g. "hl:BTC", "hl:1:TSLA").
    public let coin: String
    /// Effective taker fee rate as a decimal string (e.g. "0.00045" = 4.5 bps).
    public let takerFeeRate: String
    /// Effective maker fee rate as a decimal string (e.g. "0.00015" = 1.5 bps).
    public let makerFeeRate: String
}

// MARK: - Order Breakdown

/// How the `amount` should be interpreted by ``Arca/orderBreakdown(options:)``.
public enum OrderBreakdownAmountType: String, Sendable {
    case spend
    case notional
    case tokens
}

/// Input options for ``Arca/orderBreakdown(options:)``.
public struct OrderBreakdownOptions: Sendable {
    public let amount: String
    public let amountType: OrderBreakdownAmountType
    public let leverage: Int
    public let feeRate: String
    public let price: String
    public let side: OrderSide
    public let szDecimals: Int

    public init(amount: String, amountType: OrderBreakdownAmountType, leverage: Int,
                feeRate: String, price: String, side: OrderSide, szDecimals: Int = 5) {
        self.amount = amount
        self.amountType = amountType
        self.leverage = leverage
        self.feeRate = feeRate
        self.price = price
        self.side = side
        self.szDecimals = szDecimals
    }
}

/// Result of ``Arca/orderBreakdown(options:)``.
public struct OrderBreakdown: Sendable {
    /// Position size in tokens (committed quantity).
    public let tokens: String
    /// Position exposure in USD (tokens * price).
    public let notionalUsd: String
    /// Margin required from balance (notional / leverage).
    public let marginRequired: String
    /// Estimated fee from balance (notional * feeRate).
    public let estimatedFee: String
    /// Total deducted from balance (margin + fee).
    public let totalSpend: String
    /// Price used for the calculation.
    public let price: String
    /// Fee rate used for the calculation.
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

/// Earliest candle timestamps for an asset. When `earliestMs < hlEarliestMs`,
/// extended (pre-listing) history is available.
public struct CandleHistoryBounds: Codable, Sendable {
    /// Absolute earliest candle timestamp (includes external pre-listing data).
    public let earliestMs: Int
    /// Earliest venue-native (Hyperliquid) candle timestamp.
    public let hlEarliestMs: Int
}

public struct SimMetaAsset: Codable, Sendable {
    public let name: String
    public let dex: String?
    public let symbol: String
    public let displayName: String?
    public let logoUrl: String?
    public let exchange: String
    public let isHip3: Bool?
    public let deployerDisplayName: String?
    public let index: Int
    public let szDecimals: Int
    public let maxLeverage: Int
    public let onlyIsolated: Bool
    /// HIP-3 fee multiplier. Nil or absent for standard perps (defaults to 1.0).
    public let feeScale: Double?
    /// Candle history availability. Present when history bounds are known.
    public let candleHistory: CandleHistoryBounds?
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
    /// HIP-3 fee multiplier. 1.0 for standard perps; >1 for builder-deployed perps.
    public let feeScale: Double
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
    case fifteenSeconds = "15s"
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case fourHours = "4h"
    case oneDay = "1d"

    /// Duration of one interval in milliseconds.
    public var milliseconds: Int {
        switch self {
        case .fifteenSeconds: return 15_000
        case .oneMinute: return 60_000
        case .fiveMinutes: return 300_000
        case .fifteenMinutes: return 900_000
        case .oneHour: return 3_600_000
        case .fourHours: return 14_400_000
        case .oneDay: return 86_400_000
        }
    }
}

public struct Candle: Codable, Sendable {
    public let t: Int
    public let o: String
    public let h: String
    public let l: String
    public let c: String
    public let v: String
    public let n: Int
    /// Data source. `nil` = venue-native (Hyperliquid), `"ext"` = external historical data.
    public let s: String?
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

/// A single trade from the market-wide trade tape.
public struct MarketTrade: Codable, Sendable {
    public let coin: String
    public let px: String
    public let sz: String
    public let side: String
    public let time: String
    public let hash: String?
}

/// Callback-friendly trade event.
public struct TradeEvent: Sendable {
    public let coin: String
    public let trade: MarketTrade
}

/// Emitted by ``CandleChartStream`` on every chart change.
public struct CandleChartUpdate: Sendable {
    /// Full candle array (historical + live), sorted by `t`, deduped.
    public let candles: [Candle]
    /// The candle that triggered this update.
    public let latestCandle: Candle
}

/// Result of ``CandleChartStream/ensureRange`` or ``CandleChartStream/loadMore``.
public struct LoadRangeResult: Sendable {
    /// Number of new candles fetched in this call (0 when the range was already loaded).
    public let loadedCount: Int
    /// Total candles now in the chart array.
    public let totalCount: Int
    /// Timestamp of the earliest candle in the array, or 0 if empty.
    public let rangeStart: Int
    /// Timestamp of the latest candle in the array, or 0 if empty.
    public let rangeEnd: Int
    /// True if the earliest available candle for this asset is now loaded
    /// (no more history exists before the current array start).
    public let reachedStart: Bool
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
    /// Platform operation ID. Absent on preview fills from `exchange.fill`.
    public let operationId: String?
    public let fillId: String?
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
    /// Absent on preview fills from `exchange.fill`; populated by `fill.recorded`.
    public let resultingPosition: FillResultingPosition?
    public let isLiquidation: Bool?
    public let createdAt: String?
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

// MARK: - Client-Side Mid-Price Revaluation

extension SimPosition {
    /// Returns a copy with `unrealizedPnl`, `positionValue`, and `returnOnEquity`
    /// recomputed from the mid price for this position's coin.
    public func revalued(with mids: [String: String]) -> SimPosition {
        guard let mid = mids[coin], let markDec = Decimal(string: mid) else { return self }
        let sizeDec = Decimal(string: size) ?? 0
        let entryDec = Decimal(string: entryPrice) ?? 0
        let signedSize: Decimal = (side == .short) ? -sizeDec : sizeDec
        let pnl = signedSize * (markDec - entryDec)
        let posVal = sizeDec * markDec
        let marginDec = Decimal(string: marginUsed) ?? 0
        let roe: Decimal = marginDec > 0 ? pnl / marginDec : 0
        return SimPosition(
            id: id, accountId: accountId, realmId: realmId, coin: coin,
            side: side, size: size, entryPrice: entryPrice, leverage: leverage,
            marginUsed: marginUsed, liquidationPrice: liquidationPrice,
            unrealizedPnl: "\(pnl)", returnOnEquity: "\(roe)",
            positionValue: "\(posVal)", error: nil,
            cumulativeFunding: cumulativeFunding,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension SimMarginSummary {
    /// Returns a copy with `totalUnrealizedPnl`, `equity`, and `availableToWithdraw`
    /// recomputed from revalued positions.
    func revalued(positions: [SimPosition]) -> SimMarginSummary {
        let totalPnl = positions.reduce(Decimal(0)) { sum, pos in
            sum + (Decimal(string: pos.unrealizedPnl ?? "0") ?? 0)
        }
        let rawUsd = Decimal(string: totalRawUsd ?? "") ?? 0
        let eq: Decimal
        if rawUsd > 0 {
            eq = rawUsd + totalPnl
        } else {
            eq = Decimal(string: equity) ?? 0
        }
        let maintenance = Decimal(string: maintenanceMarginRequired) ?? 0
        let withdrawable = max(0, eq - maintenance)
        return SimMarginSummary(
            equity: "\(eq)", initialMarginUsed: initialMarginUsed,
            maintenanceMarginRequired: maintenanceMarginRequired,
            availableToWithdraw: "\(withdrawable)", totalNtlPos: totalNtlPos,
            totalUnrealizedPnl: "\(totalPnl)", totalRawUsd: totalRawUsd)
    }
}

extension ExchangeState {
    /// Returns a copy with all price-derived fields recomputed from mid prices.
    /// Position P&L, margin summary totals, and equity are updated.
    /// Structural data (orders, account, margins, intents) is preserved unchanged.
    public func revalued(with mids: [String: String]) -> ExchangeState {
        let newPositions = positions.map { $0.revalued(with: mids) }
        let newSummary = marginSummary.revalued(positions: newPositions)
        let newCross = crossMarginSummary?.revalued(positions: newPositions)
        return ExchangeState(
            account: account, marginSummary: newSummary,
            crossMarginSummary: newCross,
            crossMaintenanceMarginUsed: crossMaintenanceMarginUsed,
            positions: newPositions, openOrders: openOrders,
            feeRates: feeRates, pendingIntents: pendingIntents)
    }
}
