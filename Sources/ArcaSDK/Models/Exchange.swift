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
    public let market: String
    public let side: PositionSide
    public let size: String
    public let entryPrice: String
    public let leverage: Int
    public let marginUsed: String
    /// The position's margin mode. Isolated positions carry their own dedicated
    /// collateral (`isolatedMargin`) and are liquidated independently of the
    /// cross pool.
    public var marginMode: MarginMode = .cross
    /// Locked collateral for an isolated position (decimal string); may exceed
    /// the leverage-implied margin after `updateIsolatedMargin`. `nil` for
    /// cross positions.
    public var isolatedMargin: String? = nil
    public let liquidationPrice: String?
    public let unrealizedPnl: String?
    public let returnOnEquity: String?
    public let positionValue: String?
    /// Present when computed fields (unrealizedPnl, positionValue, returnOnEquity) could not be calculated.
    public let error: String?
    /// Cumulative funding paid (negative) or received (positive) over the
    /// position's *current open lot* — i.e. since net position size last
    /// went 0 → non-zero. Resets when the lot ends: a full close removes
    /// the position; a flip-through-zero starts a fresh lot at zero.
    /// Decimal string. `nil` when no funding has accrued.
    public let cumulativeFunding: String?
    /// Cumulative trading fee paid over the position's *current open lot*,
    /// summed across the exchange / platform / builder buckets below.
    /// Equal by construction to
    /// `cumulativeExchangeFee + cumulativePlatformFee + cumulativeBuilderFee`.
    /// Same lot semantics as `cumulativeFunding`. Decimal string;
    /// `nil` when no fees have accrued.
    public let cumulativeFee: String?
    /// Cumulative exchange (taker / maker) fee component. See `cumulativeFee`.
    public let cumulativeExchangeFee: String?
    /// Cumulative platform fee component. See `cumulativeFee`.
    public let cumulativePlatformFee: String?
    /// Cumulative builder fee component. See `cumulativeFee`.
    public let cumulativeBuilderFee: String?
    /// When the position's *current open lot* began — the same lot boundary the
    /// `cumulative*` fields use. Survives increases, partial reduces, and
    /// leverage / margin-mode changes; resets on a flip-through-zero and on a
    /// reopen after a full close.
    ///
    /// Derived from the platform's own fill history rather than reported by the
    /// venue, so it means the same thing on every exchange. `nil` when no
    /// history exists to derive it from.
    public let createdAt: String?
    public let updatedAt: String?
}

extension SimPosition {
    /// Custom decoder so an absent `marginMode` key decodes as `.cross` rather
    /// than throwing. `encode(to:)` and the memberwise initializer remain
    /// synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(SimPositionID.self, forKey: .id)
        self.accountId = try c.decodeIfPresent(SimAccountID.self, forKey: .accountId)
        self.realmId = try c.decodeIfPresent(RealmID.self, forKey: .realmId)
        self.market = try c.decode(String.self, forKey: .market)
        self.side = try c.decode(PositionSide.self, forKey: .side)
        self.size = try c.decode(String.self, forKey: .size)
        self.entryPrice = try c.decode(String.self, forKey: .entryPrice)
        self.leverage = try c.decode(Int.self, forKey: .leverage)
        self.marginUsed = try c.decode(String.self, forKey: .marginUsed)
        self.marginMode = try c.decodeIfPresent(MarginMode.self, forKey: .marginMode) ?? .cross
        self.isolatedMargin = try c.decodeIfPresent(String.self, forKey: .isolatedMargin)
        self.liquidationPrice = try c.decodeIfPresent(String.self, forKey: .liquidationPrice)
        self.unrealizedPnl = try c.decodeIfPresent(String.self, forKey: .unrealizedPnl)
        self.returnOnEquity = try c.decodeIfPresent(String.self, forKey: .returnOnEquity)
        self.positionValue = try c.decodeIfPresent(String.self, forKey: .positionValue)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)
        self.cumulativeFunding = try c.decodeIfPresent(String.self, forKey: .cumulativeFunding)
        self.cumulativeFee = try c.decodeIfPresent(String.self, forKey: .cumulativeFee)
        self.cumulativeExchangeFee = try c.decodeIfPresent(String.self, forKey: .cumulativeExchangeFee)
        self.cumulativePlatformFee = try c.decodeIfPresent(String.self, forKey: .cumulativePlatformFee)
        self.cumulativeBuilderFee = try c.decodeIfPresent(String.self, forKey: .cumulativeBuilderFee)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
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
    public let market: String
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
    /// `true` for an unsized ("size to max") TP/SL that closes the entire
    /// position when fired.
    public let sizeToMax: Bool?
    /// Links the legs of a TP/SL bracket so that when one leg fills (even
    /// partially) the venue cancels the sibling legs sharing this id
    /// (one-cancels-the-other). `nil` for a standalone order. `setPositionTpsl`
    /// assigns one id to both legs; it is advisory and never part of the signed
    /// order digest.
    public let ocoGroupId: String?
    /// Why a `.cancelled` order was cancelled — one of `user_requested`,
    /// `sibling_filled`, `position_closed`, `position_flipped`, `liquidated`,
    /// `position_gone`, `market_delisted`, `insufficient_margin`. `nil` unless
    /// `status == .cancelled`.
    ///
    /// `insufficient_margin` means a resting limit order kept reaching its
    /// price while the account could not afford the fill: placement checks
    /// margin but does not reserve it, so an order can become unaffordable
    /// while it rests. A brief dip is tolerated — the venue only retires the
    /// order after it stays unaffordable across repeated attempts over
    /// several minutes.
    public let cancelReason: String?
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
    /// Client order id (Hyperliquid cloid). A `normalTpsl` bracket child is not
    /// a live venue order until the entry fills and the venue arms it — until
    /// then it has no venue `orderId`, so its fills correlate only by `cloid`.
    public let cloid: String?
    public let accountId: SimAccountID?
    public let realmId: RealmID?
    public let market: String
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
    public let market: String
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
    public let market: String
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
    /// When `.server`, price-derived fields (position uPnL, margin summary
    /// equity, max-order-size) are server-authoritative and the SDK does not
    /// recompute them from mids. Absent ⇒ `.client`.
    public let pricingMode: PricingMode?
    /// The venue's collateral rule for this account. Drives
    /// ``ActiveAssetData/availableToTrade`` and its
    /// ``ActiveAssetData/availability`` breakdown. Absent on venues that have
    /// not declared a model, which clients read as "no reservation".
    public let collateralModel: CollateralModel?

    public init(
        account: SimAccount, marginSummary: SimMarginSummary,
        crossMarginSummary: SimMarginSummary?, crossMaintenanceMarginUsed: String?,
        positions: [SimPosition], openOrders: [SimOrder],
        feeRates: SimFeeRates?, pendingIntents: [ExchangeIntent]?,
        pricingMode: PricingMode? = nil,
        collateralModel: CollateralModel? = nil
    ) {
        self.account = account; self.marginSummary = marginSummary
        self.crossMarginSummary = crossMarginSummary
        self.crossMaintenanceMarginUsed = crossMaintenanceMarginUsed
        self.positions = positions; self.openOrders = openOrders
        self.feeRates = feeRates; self.pendingIntents = pendingIntents
        self.pricingMode = pricingMode
        self.collateralModel = collateralModel
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
        pricingMode = try container.decodeIfPresent(PricingMode.self, forKey: .pricingMode)
        collateralModel = try container.decodeIfPresent(CollateralModel.self, forKey: .collateralModel)
    }

    private enum CodingKeys: String, CodingKey {
        case account, marginSummary, crossMarginSummary, crossMaintenanceMarginUsed
        case positions, openOrders, feeRates, pendingIntents, pricingMode, collateralModel
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
    public let market: String
    public let leverage: LeverageInfo
    /// Max buy size in tokens (positive).
    public let maxBuySize: String
    /// Max sell size in tokens (positive).
    public let maxSellSize: String
    /// Max buy size in USD (positive).
    public let maxBuyUsd: String
    /// Max sell size in USD (positive).
    public let maxSellUsd: String
    /// The part of `maxBuySize` that reduces an open short, in tokens.
    ///
    /// `maxBuySize == maxBuyReduceSize + maxBuyOpenSize`. This leg is the open
    /// position's size when a buy closes it, and `"0"` otherwise. It is always
    /// available: a strictly-reducing order lowers both the initial and the
    /// maintenance requirement, so it is never refused for balance.
    ///
    /// `nil` on venues that do not report the split (Hyperliquid) — treat that
    /// as "unknown", not as `"0"`.
    public let maxBuyReduceSize: String?
    /// The part of `maxBuySize` that opens new long exposure, in tokens. This is
    /// the leg constrained by collateral. See ``maxBuyReduceSize``.
    public let maxBuyOpenSize: String?
    /// The part of `maxSellSize` that reduces an open long, in tokens.
    /// See ``maxBuyReduceSize``.
    public let maxSellReduceSize: String?
    /// The part of `maxSellSize` that opens new short exposure, in tokens.
    /// See ``maxBuyReduceSize``.
    public let maxSellOpenSize: String?
    /// Raw available margin in USD: cross equity minus cross **initial** margin.
    /// Direction-agnostic; use for "buying power" display. Per-side max exposure
    /// uses maxBuyUsd/maxSellUsd.
    ///
    /// Not the same as `withdrawable` on the exchange state, which is cross
    /// equity minus cross **maintenance** margin. Maintenance is the lower
    /// requirement, so `withdrawable` is normally the larger number, and this
    /// value can go negative while the account is still solvent and far from
    /// liquidation.
    public let availableToTrade: String
    public let markPx: String
    /// Effective fee rate as a decimal (all-in: exchange taker + platform + builder fee).
    public let feeRate: String
    /// Base maintenance margin rate as a decimal (e.g. "0.01" for 1%, "0.03" for 3%).
    public let maintenanceMarginRate: String
    /// Ordered margin tiers for this asset, if any.
    public let marginTiers: [MarginTier]?
    /// Top-of-book best bid as a decimal string. Market sells are margin-checked
    /// at the bid, so this is the directional execution price for max-sell
    /// sizing. Equals `markPx` when no order book is available.
    public let bidPx: String?
    /// Top-of-book best ask as a decimal string. Market buys are margin-checked
    /// at the ask, so this is the directional execution price for max-buy
    /// sizing. Equals `markPx` when no order book is available.
    public let askPx: String?
    /// Why ``availableToTrade`` is what it is, when a venue rule holds part of
    /// the account back from this market.
    ///
    /// Present whenever the client derived the figure
    /// (``Arca/watchMaxOrderSize(options:)``); nil on older SDKs. Gate
    /// reservation-aware UI on ``AvailabilityBreakdown/reservationEnforced`` —
    /// it is both the capability signal and the live state, so a screen written
    /// against it renders correctly before and after a venue is switched on,
    /// with no coordination.
    public let availability: AvailabilityBreakdown?
}

/// Both buying-power numbers for an account, and which one this market uses.
/// See ``CollateralModel``.
public struct AvailabilityBreakdown: Codable, Sendable {
    /// Whether *this* market draws on the shared cross-dex pool rather than the
    /// native dex's own budget — true for a market on any non-native perp dex
    /// when the venue declares a reservation.
    ///
    /// This is the flag to gate reservation-aware UI on: it is both the
    /// capability signal (nil on older SDKs) and the per-market state.
    public let reservationEnforced: Bool
    /// Buying power on every non-native perp dex. One number, shared by all of
    /// them — a position on one costs its margin on all the others equally.
    public let crossDexAvailableUsd: String
    /// Buying power on the venue-native dex (`equity - totalMargin`). Equal to
    /// ``crossDexAvailableUsd`` unless a native position is levered above
    /// `1/reservationRate`; that is the only thing that separates them.
    public let nativeAvailableUsd: String
    /// The venue's notional fraction (`"0.1"`), or `"0"` when nothing applies.
    public let reservationRate: String

    public init(reservationEnforced: Bool, crossDexAvailableUsd: String,
                nativeAvailableUsd: String, reservationRate: String) {
        self.reservationEnforced = reservationEnforced
        self.crossDexAvailableUsd = crossDexAvailableUsd
        self.nativeAvailableUsd = nativeAvailableUsd
        self.reservationRate = reservationRate
    }
}

/// How a venue decides whether an account's free collateral can back an order
/// on a perp dex it holds no margin on.
///
/// This is a venue rule, not a market property, and the two venues answer it
/// differently over *identical* market ids: the live `hl` venue reserves
/// `max(initialMargin, rate * totalNotional)` behind the open positions before
/// collateral can move to another dex, while the `hl-sim` paper venue has a
/// single pool and no transfer to gate. Both publish `hl:<dexIndex>:<symbol>`,
/// so a client inspecting the market id cannot tell them apart.
///
/// Absent means no reservation — read it that way rather than guessing.
public struct CollateralModel: Codable, Sendable {
    /// Whether collateral already backing open positions is held back from a
    /// perp dex other than the venue-native one.
    ///
    /// When true the account has exactly **two** buying-power numbers, and
    /// ``ActiveAssetData/availability`` reports both:
    ///
    ///     native   = equity - totalMargin              (the venue-native dex)
    ///     crossDex = totalCollateral - reserved        (EVERY other dex, shared)
    ///     reserved = max(marginNative, rate * notionalNative) + marginOtherDexes
    ///
    /// The notional floor applies to the **native dex only**; a position on any
    /// other dex contributes just its own margin, uniformly, everywhere. So only
    /// a native position above `1/rate` leverage separates the two numbers — the
    /// shared pool is charged as if it had been opened at exactly `1/rate`.
    public let crossDexReservationEnforced: Bool
    /// The notional fraction in that formula, as a decimal string (`"0.1"` on
    /// Hyperliquid). Also the leverage threshold: below `1/rate` on the native
    /// dex the margin term wins and there is no gap between the two numbers.
    public let crossDexReservationRate: String?
    /// The account's whole settlement-asset pool (spot USDC on Hyperliquid),
    /// before any of it is committed to a perp dex.
    ///
    /// Sent because it is **price-invariant** — it is cash — so a client can
    /// recompute the reservation exactly against live marks between state
    /// reads. Do not substitute equity: equity carries unrealized P&L and moves
    /// with the mark.
    public let totalCollateralUsd: String?

    public init(crossDexReservationEnforced: Bool, crossDexReservationRate: String? = nil,
                totalCollateralUsd: String? = nil) {
        self.crossDexReservationEnforced = crossDexReservationEnforced
        self.crossDexReservationRate = crossDexReservationRate
        self.totalCollateralUsd = totalCollateralUsd
    }
}

// MARK: - Asset Fee Rates

/// Per-asset fee rate entry returned by `getAssetFees`.
public struct AssetFeeEntry: Codable, Sendable {
    /// Coin in canonical format (e.g. "hl:0:BTC", "hl:1:TSLA").
    public let market: String
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

/// Existing same-coin position passed via ``OrderBreakdownAccountContext``.
/// The merge math in ``Arca/orderBreakdown(options:)`` mirrors
/// `PositionService.ApplyFill` in the sim-exchange backend (same-side blends
/// entry, opposite-side reduces or flips).
public struct OrderBreakdownExistingPosition: Sendable {
    public let side: PositionSide
    public let size: String
    public let entryPrice: String

    public init(side: PositionSide, size: String, entryPrice: String) {
        self.side = side
        self.size = size
        self.entryPrice = entryPrice
    }
}

/// Account-wide context required by ``Arca/orderBreakdown(options:)`` to
/// produce a cross-margin liquidation estimate. The estimate matches the
/// formula the sim-exchange backend uses at read time
/// (`marginAvailable = equity - maintenanceMargin`, then
/// `liq = mid -/+ marginAvailable / (size * (1 -/+ mmr))`). The `(1 -/+ mmr)`
/// term is maintenance relief: the position's own requirement is a percentage
/// of notional, so it moves with the mark and equity closes on it at
/// `size * (1 -/+ mmr)` per unit rather than `size`.
public struct OrderBreakdownAccountContext: Sendable {
    /// Account equity in USD. From `ExchangeState.marginSummary.equity`.
    public let equity: String
    /// Total maintenance margin requirement (USD) from all positions in the
    /// account EXCEPT any position in the same coin as this order. Compute by
    /// summing `mmr * size * entryPrice` across
    /// `exchangeState.positions.filter { $0.market != market }`.
    public let otherMaintenanceMargin: String
    /// Existing open position in the same coin as this order, if any. Omit
    /// when the account has no position in this coin.
    public let existingPosition: OrderBreakdownExistingPosition?

    public init(equity: String, otherMaintenanceMargin: String,
                existingPosition: OrderBreakdownExistingPosition? = nil) {
        self.equity = equity
        self.otherMaintenanceMargin = otherMaintenanceMargin
        self.existingPosition = existingPosition
    }
}

/// Input options for ``Arca/orderBreakdown(options:)``.
///
/// When `maintenanceMarginRate` is provided, `accountContext` must also be
/// provided (use the dedicated initializer) so the returned
/// `estimatedLiquidationPrice` reflects cross-margin reality rather than a
/// misleading isolated-position estimate.
public struct OrderBreakdownOptions: Sendable {
    public let amount: String
    public let amountType: OrderBreakdownAmountType
    public let leverage: Int
    public let feeRate: String
    public let price: String
    public let side: OrderSide
    public let szDecimals: Int
    public let maintenanceMarginRate: String?
    public let accountContext: OrderBreakdownAccountContext?
    public let marginTiers: [MarginTier]?

    /// Initializer for callers that don't need a liquidation estimate.
    public init(amount: String, amountType: OrderBreakdownAmountType, leverage: Int,
                feeRate: String, price: String, side: OrderSide, szDecimals: Int = 5,
                marginTiers: [MarginTier]? = nil) {
        self.amount = amount
        self.amountType = amountType
        self.leverage = leverage
        self.feeRate = feeRate
        self.price = price
        self.side = side
        self.szDecimals = szDecimals
        self.maintenanceMarginRate = nil
        self.accountContext = nil
        self.marginTiers = marginTiers
    }

    /// Initializer that requests a cross-margin liquidation estimate.
    /// Both `maintenanceMarginRate` and `accountContext` are required so the
    /// helper has the inputs it needs to compute a faithful estimate.
    public init(amount: String, amountType: OrderBreakdownAmountType, leverage: Int,
                feeRate: String, price: String, side: OrderSide, szDecimals: Int = 5,
                maintenanceMarginRate: String?,
                accountContext: OrderBreakdownAccountContext,
                marginTiers: [MarginTier]? = nil) {
        self.amount = amount
        self.amountType = amountType
        self.leverage = leverage
        self.feeRate = feeRate
        self.price = price
        self.side = side
        self.szDecimals = szDecimals
        self.maintenanceMarginRate = maintenanceMarginRate
        self.accountContext = accountContext
        self.marginTiers = marginTiers
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
    /// Effective leverage ratio (notional / required margin).
    public let effectiveLeverage: String?
    /// Effective maintenance margin rate for the total size.
    public let effectiveMaintenanceMarginRate: String?
    /// The notional value marking the start of the next margin tier, if any exist beyond the current notional.
    public let nextTierThreshold: String?
    /// Estimated cross-margin liquidation price for the position that will
    /// exist after this order fills. Computed using the supplied
    /// `accountContext` (account equity, maintenance margin from other
    /// positions, and any existing same-coin position to merge with).
    /// Omitted when `maintenanceMarginRate` / `accountContext` were not
    /// provided, when the order fully closes an opposite-side position, or
    /// when no positive liquidation price exists.
    public let estimatedLiquidationPrice: String?
    
    public init(tokens: String, notionalUsd: String, marginRequired: String, estimatedFee: String, totalSpend: String, price: String, feeRate: String, effectiveLeverage: String? = nil, effectiveMaintenanceMarginRate: String? = nil, nextTierThreshold: String? = nil, estimatedLiquidationPrice: String? = nil) {
        self.tokens = tokens
        self.notionalUsd = notionalUsd
        self.marginRequired = marginRequired
        self.estimatedFee = estimatedFee
        self.totalSpend = totalSpend
        self.price = price
        self.feeRate = feeRate
        self.effectiveLeverage = effectiveLeverage
        self.effectiveMaintenanceMarginRate = effectiveMaintenanceMarginRate
        self.nextTierThreshold = nextTierThreshold
        self.estimatedLiquidationPrice = estimatedLiquidationPrice
    }
}

// MARK: - Leverage

public struct UpdateLeverageResponse: Codable, Sendable {
    public let accountId: String
    public let market: String
    public let leverage: Int
    public let previousLeverage: Int
}

public struct LeverageSetting: Codable, Sendable {
    public let market: String
    public let leverage: Int
    /// Asset's configured margin mode.
    public let marginMode: MarginMode
}

public struct UpdateIsolatedMarginResponse: Codable, Sendable {
    public let accountId: String
    public let market: String
    /// Resulting locked isolated collateral.
    public let isolatedMargin: String
    /// Recomputed liquidation price.
    public let liquidationPrice: String
}

public struct SetMarginModeResponse: Codable, Sendable {
    public let accountId: String
    public let market: String
    public let marginMode: MarginMode
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

public struct LogoSource: Codable, Sendable {
    public let url: String
    public let format: String
    public let width: Int
}

public struct MarginTier: Codable, Sendable {
    public let lowerBound: String
    public let maxLeverage: Int
}

public struct MarginTable: Codable, Sendable {
    public let description: String
    public let marginTiers: [MarginTier]
}

public struct Market: Codable, Sendable {
    /// Case-sensitive canonical market ID to pass back to trading and market-data APIs
    /// (for example, "hl:0:BTC", "hl:0:kSHIB", or "hl:1:TSLA").
    public let name: String
    public let dex: String?
    /// Display symbol only. Do not reconstruct API coin IDs from this field.
    public let symbol: String
    /// Venue-native market symbol for display or venue deep links, for example "BTC" or "xyz:TSLA".
    /// Do not pass this value to Arca APIs; use `name` instead.
    public let venueSymbol: String?
    public let displayName: String?
    public let logoUrl: String?
    public let logoSources: [LogoSource]?
    public let exchange: String
    /// Machine-readable asset class when Arca recognizes the underlying instrument.
    public let assetType: String?
    /// Human-readable label for `assetType`, suitable for UI grouping.
    public let categoryLabel: String?
    /// True when the asset is mapped to Arca's underlying-instrument registry.
    public let mapped: Bool?
    /// True when a curated display name is available.
    public let hasDisplayName: Bool?
    /// True when a curated logo URL or logo source set is available.
    public let hasLogo: Bool?
    /// Whether curated display metadata is available or the asset is only known from the live venue listing.
    public let descriptionStatus: String?
    public let isHip3: Bool?
    public let deployerDisplayName: String?
    public let index: Int
    public let szDecimals: Int
    public let maxLeverage: Int
    /// Minimum order notional in USD (`size * price`) for this market. Use
    /// ``Arca/getMinOrderSize(market:price:reduceOnly:isTrigger:sizeToMax:)`` to
    /// convert it into a minimum order size in base-asset units, or
    /// ``Arca/validateOrderSize(market:price:size:reduceOnly:isTrigger:sizeToMax:)``
    /// to check a size before placing an order. Reduce-only orders and unsized
    /// (`sizeToMax`) triggers are exempt. Optional for backward compatibility
    /// with older servers; clients fall back to the venue-wide `getOrderLimits()`
    /// default when absent.
    public let minOrderNotionalUsd: Double?
    /// Hyperliquid-specific. Deprecated in favor of `marginModes` — read that
    /// instead. `onlyIsolated == true` is equivalent to `marginModes` being
    /// `["isolated"]`.
    public let onlyIsolated: Bool
    /// The margin modes this asset supports: `["isolated"]` for isolated-only
    /// markets, `["cross", "isolated"]` otherwise. Read this instead of
    /// inferring from `onlyIsolated` or `isHip3` — margin mode is independent of
    /// HIP-3 (some HIP-3 markets, e.g. `hl:1:TSLA`, are cross-eligible).
    /// Optional for backward compatibility with older servers.
    public let marginModes: [String]?
    /// HIP-3 fee multiplier. Nil or absent for standard perps (defaults to 1.0).
    public let feeScale: Double?
    public let marginTableId: Int?
    /// Candle history availability. Present when history bounds are known.
    public let candleHistory: CandleHistoryBounds?
}

public struct SimMetaResponse: Codable, Sendable {
    public let universe: [Market]
    public let marginTables: [String: MarginTable]?
}

/// Static venue-wide order limits returned by ``Arca/getOrderLimits()``.
/// Hyperliquid enforces a $10 minimum notional (`size * price`) on every
/// non-reduce-only order. Reduce-only orders and unsized (`sizeToMax`)
/// triggers are exempt so dust positions can always be closed.
public struct OrderLimits: Codable, Sendable {
    /// Minimum order notional in USD (size * price). Hyperliquid: 10.
    public let minOrderNotionalUsd: Double

    public init(minOrderNotionalUsd: Double) {
        self.minOrderNotionalUsd = minOrderNotionalUsd
    }
}

/// The smallest valid order for a market at a given price, expressed both as a
/// base-asset size and its USD notional. Returned by
/// ``Arca/getMinOrderSize(market:price:reduceOnly:isTrigger:sizeToMax:)``.
public struct MinOrderSize: Codable, Sendable {
    /// Minimum order size in base-asset units (decimal string), rounded up to
    /// the market's `szDecimals` precision so it always clears the notional
    /// floor. For exempt orders this is a single size tick (`10^-szDecimals`).
    public let minSize: String
    /// USD notional floor applied. Zero for exempt (reduce-only / unsized-trigger) orders.
    public let minNotionalUsd: Double

    public init(minSize: String, minNotionalUsd: Double) {
        self.minSize = minSize
        self.minNotionalUsd = minNotionalUsd
    }
}

/// Result of ``Arca/validateOrderSize(market:price:size:reduceOnly:isTrigger:sizeToMax:)``.
public struct OrderSizeValidation: Codable, Sendable {
    /// True when the order clears the minimum (or is exempt).
    public let ok: Bool
    /// Human-readable explanation when `ok` is false; nil when valid.
    public let reason: String?
    /// The minimum order size in base-asset units.
    public let minSize: String
    /// USD notional floor applied. Zero for exempt orders.
    public let minNotionalUsd: Double

    public init(ok: Bool, reason: String?, minSize: String, minNotionalUsd: Double) {
        self.ok = ok
        self.reason = reason
        self.minSize = minSize
        self.minNotionalUsd = minNotionalUsd
    }
}

public struct SimMidsResponse: Codable, Sendable {
    public let mids: [String: String]
}

public struct MarketTicker: Codable, Sendable {
    public let market: String
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
    public let market: String
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
    public let market: String
    public let interval: String
    public let candles: [Candle]
}

public struct CandleEvent: Sendable {
    public let market: String
    public let interval: CandleInterval
    public let candle: Candle
}

/// A single open-interest / 24h-notional bar. The OHLC values track open
/// interest (base-asset units) over the bucket; `ntlVlm` is the rolling 24h
/// notional volume (USD) at bucket close; `mark` is the last mark price in the
/// bucket (USD OI ≈ `oiClose * mark`). `s` is the data source (`nil`/`""`
/// self-recorded, `"0xa"` 0xArchive backfill).
public struct OIBar: Codable, Sendable {
    public let t: Int
    public let oiOpen: String
    public let oiHigh: String
    public let oiLow: String
    public let oiClose: String
    public let ntlVlm: String
    public let mark: String?
    public let s: String?
}

public struct OIHistoryResponse: Codable, Sendable {
    public let market: String
    public let interval: String
    public let bars: [OIBar]
}

/// A single SETTLED funding-rate observation for a market. Unlike ``OIBar`` /
/// ``Candle`` this is not interval-bucketed — it is a raw event at the venue's
/// real settlement timestamp (`t`, Unix ms), so a market's true funding
/// schedule is preserved. `fundingRate`/`premium` are settled historical rates,
/// never predicted (use the ticker's `funding` + `nextFundingTime` for the
/// current/predicted rate). `s` is the data source (`"hl"`).
public struct FundingObservation: Codable, Sendable {
    public let t: Int
    public let fundingRate: String
    public let premium: String?
    public let s: String?
}

public struct FundingHistoryResponse: Codable, Sendable {
    public let market: String
    public let funding: [FundingObservation]
}

/// Emitted by ``OIWatchStream`` on each live open-interest bar update.
public struct OIEvent: Sendable {
    public let market: String
    public let interval: CandleInterval
    public let bar: OIBar
    public let isClosed: Bool
}

/// A single trade from the market-wide trade tape.
public struct MarketTrade: Codable, Sendable {
    public let market: String
    public let px: String
    public let sz: String
    public let side: String
    public let time: String
    public let hash: String?
}

/// Callback-friendly trade event.
public struct TradeEvent: Sendable {
    public let market: String
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
    /// Platform operation ID. Absent on preview fills from `fill.previewed`.
    public let operationId: String?
    public let fillId: String?
    public let orderOperationId: String?
    public let orderId: String?
    public let market: String
    public let side: OrderSide?
    public let size: String?
    public let price: String?
    public let direction: String?
    public let startPosition: String?
    public let fee: String?
    public let exchangeFee: String?
    public let platformFee: String?
    public let builderFee: String?
    public let realizedPnl: String?
    /// Absent on preview fills from `fill.previewed`; populated by `fill.recorded`.
    public let resultingPosition: FillResultingPosition?
    public let isLiquidation: Bool?
    public let createdAt: String?
    /// Whether the originating order was a trigger (TP/SL) order, decorated
    /// server-side from the order operation. `false` means "known regular
    /// order"; `nil` means the fill is unattributable (external trade,
    /// liquidation) — absence and falseness are distinct.
    public let isTrigger: Bool?
    /// Trigger kind ("tp" | "sl") of the originating order. Present only for trigger orders.
    public let tpsl: String?
    /// Trigger price of the originating order. Present only for trigger orders.
    public let triggerPx: String?
    /// Classification of an `isLiquidation` fill: "liquidation" (margin
    /// call) or "adl" (backstop / auto-deleverage close). Absent on
    /// liquidations recorded before the venue method was stamped.
    public let liquidationKind: String?
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
        guard let mid = mids[market], let markDec = Decimal(string: mid) else { return self }
        let sizeDec = Decimal(string: size) ?? 0
        let entryDec = Decimal(string: entryPrice) ?? 0
        let signedSize: Decimal = (side == .short) ? -sizeDec : sizeDec
        let pnl = signedSize * (markDec - entryDec)
        let posVal = sizeDec * markDec
        let marginDec = Decimal(string: marginUsed) ?? 0
        let roe: Decimal = marginDec > 0 ? pnl / marginDec : 0
        return SimPosition(
            id: id, accountId: accountId, realmId: realmId, market: market,
            side: side, size: size, entryPrice: entryPrice, leverage: leverage,
            marginUsed: marginUsed, marginMode: marginMode, isolatedMargin: isolatedMargin,
            liquidationPrice: liquidationPrice,
            unrealizedPnl: "\(pnl)", returnOnEquity: "\(roe)",
            positionValue: "\(posVal)", error: nil,
            cumulativeFunding: cumulativeFunding,
            cumulativeFee: cumulativeFee,
            cumulativeExchangeFee: cumulativeExchangeFee,
            cumulativePlatformFee: cumulativePlatformFee,
            cumulativeBuilderFee: cumulativeBuilderFee,
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
        // Server-authoritative pricing: trust server equity/uPnL verbatim.
        if pricingMode == .server { return self }
        let newPositions = positions.map { $0.revalued(with: mids) }
        let newSummary = marginSummary.revalued(positions: newPositions)
        let newCross = crossMarginSummary?.revalued(positions: newPositions)
        return ExchangeState(
            account: account, marginSummary: newSummary,
            crossMarginSummary: newCross,
            crossMaintenanceMarginUsed: crossMaintenanceMarginUsed,
            positions: newPositions, openOrders: openOrders,
            feeRates: feeRates, pendingIntents: pendingIntents,
            pricingMode: pricingMode)
    }
}
