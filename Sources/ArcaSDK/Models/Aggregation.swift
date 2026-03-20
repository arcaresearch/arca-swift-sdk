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
    public let unrealizedPnl: String
    public let valueUsd: String
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
    public let computed: Bool?
}

public struct PathAggregation: Codable, Sendable {
    public let prefix: String
    public let totalEquityUsd: String
    public let departingUsd: String
    public let arrivingUsd: String?
    public let breakdown: [AssetBreakdown]
    public let objects: [ObjectValuation]
    public let asOf: String?
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
                sum + (Decimal(string: pos.unrealizedPnl) ?? 0)
            } ?? 0
            let equity = cashDec + totalPnl
            let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
            let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
            return ObjectValuation(objectId: objectId, path: path, type: type,
                                   denomination: denomination, valueUsd: "\(equity)",
                                   balances: balances, reservedBalances: newReserved,
                                   pendingInbound: newInbound, positions: newPositions,
                                   computed: computed)
        }

        let newBalances = balances.map { $0.revalued(with: mids) }
        let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
        let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
        let objValue = newBalances.reduce(Decimal(0)) { sum, b in
            sum + (Decimal(string: b.valueUsd) ?? 0)
        } + (newReserved?.reduce(Decimal(0)) { sum, r in
            sum + (Decimal(string: r.valueUsd) ?? 0)
        } ?? 0)
        return ObjectValuation(objectId: objectId, path: path, type: type,
                               denomination: denomination, valueUsd: "\(objValue)",
                               balances: newBalances, reservedBalances: newReserved,
                               pendingInbound: newInbound, positions: positions,
                               computed: computed)
    }
}

extension PathAggregation {
    /// Returns a copy with all objects revalued and totals recomputed.
    public func revalued(with mids: [String: String]) -> PathAggregation {
        let newObjects = objects.map { $0.revalued(with: mids) }
        let totalEquity = newObjects.reduce(Decimal(0)) { sum, obj in
            sum + (Decimal(string: obj.valueUsd) ?? 0)
        }
        let departing = newObjects.reduce(Decimal(0)) { sum, obj in
            sum + (obj.reservedBalances?.reduce(Decimal(0)) { s, r in
                s + (Decimal(string: r.valueUsd) ?? 0)
            } ?? 0)
        }
        let arriving = newObjects.reduce(Decimal(0)) { sum, obj in
            sum + (obj.pendingInbound?.reduce(Decimal(0)) { s, r in
                s + (Decimal(string: r.valueUsd) ?? 0)
            } ?? 0)
        }
        return PathAggregation(prefix: prefix, totalEquityUsd: "\(totalEquity)",
                               departingUsd: "\(departing)", arrivingUsd: "\(arriving)",
                               breakdown: breakdown, objects: newObjects, asOf: asOf)
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
    public let externalFlows: [ExternalFlowEntry]
}

// MARK: - P&L History

public struct PnlPoint: Codable, Sendable {
    public let timestamp: String
    public let pnlUsd: String
    public let equityUsd: String
}

public struct PnlHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    public let startingEquityUsd: String
    public let pnlPoints: [PnlPoint]
    public let externalFlows: [ExternalFlowEntry]
    public let midPrices: [String: String]?
}

// MARK: - Equity History

public struct EquityPoint: Codable, Sendable {
    public let timestamp: String
    public let equityUsd: String
}

public struct EquityHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    public let equityPoints: [EquityPoint]
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
