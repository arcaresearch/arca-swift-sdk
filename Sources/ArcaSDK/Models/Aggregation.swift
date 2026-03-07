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
    public let reservedBalances: [ReservedValue]
    public let pendingInbound: [ReservedValue]?
    public let positions: [PositionValue]?
}

public struct PathAggregation: Codable, Sendable {
    public let prefix: String
    public let totalEquityUsd: String
    public let totalReservedUsd: String
    public let totalInTransitUsd: String?
    public let breakdown: [AssetBreakdown]
    public let objects: [ObjectValuation]
    public let asOf: String?
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
