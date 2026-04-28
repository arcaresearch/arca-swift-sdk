import Foundation

// MARK: - Aggregation

public enum AssetCategory: String, Codable, Sendable {
    case spot
    case perp
    case exchange
}

public struct AssetBreakdown: Codable, Sendable {
    public let asset: String
    public let category: AssetCategory
    public let amount: String
    public let price: String?
    public let valueUsd: String
    public let weightedAvgLeverage: String?
    public let avgEntryPrice: String?
}

public struct BalanceValue: Codable, Sendable {
    public let denomination: String
    public let amount: String
    public let price: String?
    public let valueUsd: String
}

public struct PositionValue: Codable, Sendable {
    public let coin: String
    public let side: String
    public let size: String
    public let entryPrice: String
    public let markPrice: String?
    public let unrealizedPnl: String?
    public let valueUsd: String?
}

public struct ReservedValue: Codable, Sendable {
    public let denomination: String
    public let amount: String
    public let price: String?
    public let valueUsd: String
    public let operationId: OperationID
    public let sourceArcaPath: String?
    public let destinationArcaPath: String?
    public let startedAt: String?
    public let inTransit: Bool?
}

public struct ObjectValuation: Codable, Sendable {
    public let objectId: ObjectID
    public let path: String
    public let type: String
    public let denomination: String?
    public let valueUsd: String
    public let balances: [BalanceValue]
    public let reservedBalances: [ReservedValue]?
    public let pendingInbound: [ReservedValue]?
    public let positions: [PositionValue]?
}

public struct PathAggregation: Codable, Sendable {
    public let prefix: String
    public let totalEquityUsd: String
    public let departingUsd: String
    public let arrivingUsd: String?
    public let breakdown: [AssetBreakdown]
    public let asOf: String?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?
}

// MARK: - Client-Side Revaluation

extension BalanceValue {
    /// Returns a copy with `valueUsd` and `price` recomputed from current mid prices.
    public func revalued(with mids: [String: String]) -> BalanceValue {
        let mid = mids[denomination] ?? "1"
        let amountDec = Decimal(string: amount) ?? 0
        let priceDec = Decimal(string: mid) ?? 1
        let value = amountDec * priceDec
        return BalanceValue(denomination: denomination, amount: amount,
                            price: mid, valueUsd: "\(value)")
    }
}

extension PositionValue {
    /// Returns a copy with `markPrice`, `unrealizedPnl`, and `valueUsd` recomputed.
    public func revalued(with mids: [String: String]) -> PositionValue {
        guard let mid = mids[coin], let markDec = Decimal(string: mid) else { return self }
        let sizeDec = Decimal(string: size) ?? 0
        let entryDec = Decimal(string: entryPrice) ?? 0
        let signedSize: Decimal = (side == "SHORT") ? -sizeDec : sizeDec
        let pnl = signedSize * (markDec - entryDec)
        return PositionValue(coin: coin, side: side, size: size, entryPrice: entryPrice,
                             markPrice: mid, unrealizedPnl: "\(pnl)", valueUsd: "\(pnl)")
    }
}

extension ReservedValue {
    /// Returns a copy with `valueUsd` and `price` recomputed from current mid prices.
    public func revalued(with mids: [String: String]) -> ReservedValue {
        let mid = mids[denomination] ?? "1"
        let amountDec = Decimal(string: amount) ?? 0
        let priceDec = Decimal(string: mid) ?? 1
        let value = amountDec * priceDec
        return ReservedValue(denomination: denomination, amount: amount, price: mid,
                             valueUsd: "\(value)", operationId: operationId,
                             sourceArcaPath: sourceArcaPath, destinationArcaPath: destinationArcaPath,
                             startedAt: startedAt, inTransit: inTransit)
    }
}

extension ObjectValuation {
    /// Returns a copy with all price-derived fields recomputed from mid prices.
    /// Static data (amounts, sizes, entry prices, paths) is preserved.
    public func revalued(with mids: [String: String]) -> ObjectValuation {
        if type == "exchange" {
            let newPositions = positions?.map { $0.revalued(with: mids) }
            let cashStr = balances.first?.amount ?? "0"
            let cashDec = Decimal(string: cashStr) ?? 0
            let totalPnl = newPositions?.reduce(Decimal(0)) { sum, pos in
                sum + (Decimal(string: pos.unrealizedPnl ?? "0") ?? 0)
            } ?? 0
            let equity = cashDec + totalPnl
            let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
            let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
            return ObjectValuation(objectId: objectId, path: path, type: type,
                                   denomination: denomination, valueUsd: "\(equity)",
                                   balances: balances, reservedBalances: newReserved,
                                   pendingInbound: newInbound, positions: newPositions)
        }

        let newBalances = balances.map { $0.revalued(with: mids) }
        let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
        let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
        let objValue = newBalances.reduce(Decimal(0)) { sum, b in
            sum + (Decimal(string: b.valueUsd) ?? 0)
        }
        return ObjectValuation(objectId: objectId, path: path, type: type,
                               denomination: denomination, valueUsd: "\(objValue)",
                               balances: newBalances, reservedBalances: newReserved,
                               pendingInbound: newInbound, positions: positions)
    }
}

extension PathAggregation {
    /// Returns a copy with totals recomputed from ``breakdown`` using mid prices.
    /// Spot rows use `amount × mid`; perp rows recompute mark-to-market P&L.
    /// Exchange rows keep server ``AssetBreakdown/valueUsd``.
    /// ``departingUsd`` and ``arrivingUsd`` are USD-denominated and pass through unchanged.
    public func revalued(with mids: [String: String]) -> PathAggregation {
        let newBreakdown = breakdown.map { entry -> AssetBreakdown in
            switch entry.category {
            case .spot:
                guard let mid = mids[entry.asset] else { return entry }
                let amountDec = Decimal(string: entry.amount) ?? 0
                let priceDec = Decimal(string: mid) ?? 1
                let value = amountDec * priceDec
                return AssetBreakdown(
                    asset: entry.asset,
                    category: entry.category,
                    amount: entry.amount,
                    price: mid,
                    valueUsd: "\(value)",
                    weightedAvgLeverage: entry.weightedAvgLeverage,
                    avgEntryPrice: entry.avgEntryPrice
                )
            case .perp:
                guard let mid = mids[entry.asset],
                      let newMid = Decimal(string: mid),
                      let oldPrice = entry.price,
                      let oldMid = Decimal(string: oldPrice),
                      oldMid != 0,
                      let avgEntryPrice = entry.avgEntryPrice,
                      let entryPrice = Decimal(string: avgEntryPrice) else {
                    return entry
                }
                let amountDec = Decimal(string: entry.amount) ?? 0
                let currentValue = Decimal(string: entry.valueUsd) ?? 0
                let entryNotional = entryPrice * amountDec
                let netSignedSize = (currentValue + entryNotional) / oldMid
                let newValue = newMid * netSignedSize - entryNotional
                return AssetBreakdown(
                    asset: entry.asset,
                    category: entry.category,
                    amount: entry.amount,
                    price: mid,
                    valueUsd: "\(newValue)",
                    weightedAvgLeverage: entry.weightedAvgLeverage,
                    avgEntryPrice: entry.avgEntryPrice
                )
            case .exchange:
                return entry
            }
        }
        let totalEquity = newBreakdown.reduce(Decimal(0)) { sum, entry in
            sum + (Decimal(string: entry.valueUsd) ?? 0)
        }
        return PathAggregation(
            prefix: prefix,
            totalEquityUsd: "\(totalEquity)",
            departingUsd: departingUsd,
            arrivingUsd: arrivingUsd,
            breakdown: newBreakdown,
            asOf: asOf,
            cumInflowsUsd: cumInflowsUsd,
            cumOutflowsUsd: cumOutflowsUsd
        )
    }
}

// MARK: - Aggregation Source

public enum AggregationSourceType: String, Codable, Sendable {
    case prefix
    case pattern
    case paths
    case watch
}

public struct AggregationSource: Codable, Sendable {
    public let type: AggregationSourceType
    public let value: String

    public init(type: AggregationSourceType, value: String) {
        self.type = type
        self.value = value
    }
}

public struct CreateWatchResponse: Codable, Sendable {
    public let watchId: WatchID
    public let aggregation: PathAggregation
}

// MARK: - P&L

public struct ExternalFlowEntry: Codable, Sendable {
    public let operationId: OperationID
    public let type: String
    public let direction: String
    public let amount: String
    public let denomination: String
    public let valueUsd: String
    public let sourceArcaPath: String?
    public let targetArcaPath: String?
    public let timestamp: String
}

public struct PnlResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let startingEquityUsd: String
    public let endingEquityUsd: String
    public let netInflowsUsd: String
    public let netOutflowsUsd: String
    public let pnlUsd: String
    public let externalFlows: [ExternalFlowEntry]?
}

// MARK: - P&L History

public struct PnlPoint: Codable, Sendable {
    public let timestamp: String
    public let pnlUsd: String
    public let equityUsd: String
    public let status: ChartPointStatus?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?
    public let lastEventOpId: String?
    public let midSetId: String?
    /// Present when the chart is created with `anchor: .equity`.
    /// Equal to pnlUsd shifted so the live (rightmost) point equals current equity.
    public var valueUsd: String?

    public init(
        timestamp: String,
        pnlUsd: String,
        equityUsd: String,
        status: ChartPointStatus? = nil,
        cumInflowsUsd: String? = nil,
        cumOutflowsUsd: String? = nil,
        lastEventOpId: String? = nil,
        midSetId: String? = nil,
        valueUsd: String? = nil
    ) {
        self.timestamp = timestamp
        self.pnlUsd = pnlUsd
        self.equityUsd = equityUsd
        self.status = status
        self.cumInflowsUsd = cumInflowsUsd
        self.cumOutflowsUsd = cumOutflowsUsd
        self.lastEventOpId = lastEventOpId
        self.midSetId = midSetId
        self.valueUsd = valueUsd
    }
}

/// Controls the y-axis baseline for P&L charts.
public enum PnlAnchor: Sendable {
    /// Standard P&L chart starting at 0.
    case zero
    /// P&L shifted so the live (rightmost) value equals the current account equity.
    case equity
}

/// Populates `valueUsd` with `equityUsd` for equity-anchored P&L charts.
/// This provides a true historical portfolio value view, rather than a translated P&L curve.
func applyEquityAnchor(to points: inout [PnlPoint]) {
    for i in points.indices {
        points[i].valueUsd = points[i].equityUsd
    }
}

public struct PnlHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    public let resolution: String?
    public let resolutionRequested: String?
    public let serverNow: String?
    public let startingEquityUsd: String
    /// Timestamp of the first non-zero equity point (after leading-zero
    /// trimming). Use as `flowsSince` for the live watch to avoid
    /// double-counting flows already reflected in `startingEquityUsd`.
    public let effectiveFrom: String?
    public let pnlPoints: [PnlPoint]
    public let externalFlows: [ExternalFlowEntry]?
    public let midPrices: [String: String]?

    public init(
        prefix: String,
        from: String,
        to: String,
        points: Int,
        resolution: String? = nil,
        resolutionRequested: String? = nil,
        serverNow: String? = nil,
        startingEquityUsd: String,
        effectiveFrom: String? = nil,
        pnlPoints: [PnlPoint],
        externalFlows: [ExternalFlowEntry]? = nil,
        midPrices: [String: String]? = nil
    ) {
        self.prefix = prefix
        self.from = from
        self.to = to
        self.points = points
        self.resolution = resolution
        self.resolutionRequested = resolutionRequested
        self.serverNow = serverNow
        self.startingEquityUsd = startingEquityUsd
        self.effectiveFrom = effectiveFrom
        self.pnlPoints = pnlPoints
        self.externalFlows = externalFlows
        self.midPrices = midPrices
    }
}

// MARK: - Equity History

public enum ChartPointStatus: String, Codable, Sendable {
    case open
    case sealed
    case carried
    case incomplete
}

public struct EquityPoint: Codable, Sendable {
    public let timestamp: String
    public let equityUsd: String
    public let status: ChartPointStatus?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?
    public let lastEventOpId: String?
    public let midSetId: String?

    public init(
        timestamp: String,
        equityUsd: String,
        status: ChartPointStatus? = nil,
        cumInflowsUsd: String? = nil,
        cumOutflowsUsd: String? = nil,
        lastEventOpId: String? = nil,
        midSetId: String? = nil
    ) {
        self.timestamp = timestamp
        self.equityUsd = equityUsd
        self.status = status
        self.cumInflowsUsd = cumInflowsUsd
        self.cumOutflowsUsd = cumOutflowsUsd
        self.lastEventOpId = lastEventOpId
        self.midSetId = midSetId
    }
}

public struct EquityHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    public let resolution: String?
    public let resolutionRequested: String?
    public let serverNow: String?
    public let equityPoints: [EquityPoint]

    public init(
        prefix: String,
        from: String,
        to: String,
        points: Int,
        resolution: String? = nil,
        resolutionRequested: String? = nil,
        serverNow: String? = nil,
        equityPoints: [EquityPoint]
    ) {
        self.prefix = prefix
        self.from = from
        self.to = to
        self.points = points
        self.resolution = resolution
        self.resolutionRequested = resolutionRequested
        self.serverNow = serverNow
        self.equityPoints = equityPoints
    }
}

/// Emitted by `EquityChartStream` on each update.
/// Contains the full point array (historical + live tail).
public struct EquityChartUpdate: Sendable {
    public let points: [EquityPoint]
}

/// Emitted by `PnlChartStream` on each update.
/// Contains the full P&L point array (historical + live tail) and all flows.
public struct PnlChartUpdate: Sendable {
    public let points: [PnlPoint]
    public let externalFlows: [ExternalFlowEntry]
}
