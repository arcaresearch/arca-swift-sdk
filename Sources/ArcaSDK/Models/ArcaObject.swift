import Foundation

// MARK: - Arca Object Types

public enum ArcaObjectType: String, Codable, Sendable {
    case denominated
    case exchange
    case deposit
    case withdrawal
    case escrow
}

public enum ArcaObjectStatus: String, Codable, Sendable {
    case active
    case deleting
    case deleted
}

public struct ArcaObject: Codable, Sendable {
    public let id: ObjectID
    public let realmId: RealmID
    public let path: String
    public let type: ArcaObjectType
    public let denomination: String?
    public let status: ArcaObjectStatus
    public let metadata: String?
    public let deletedAt: String?
    public let systemOwned: Bool
    public let createdAt: String
    public let updatedAt: String
}

// MARK: - Balances

public struct ArcaBalance: Codable, Sendable {
    public let id: BalanceID
    public let arcaId: ObjectID
    public let denomination: String
    public let amount: String
    public let arriving: String
    public let settled: String
    public let departing: String
    public let total: String
}

public struct ArcaBalanceListResponse: Codable, Sendable {
    public let balances: [ArcaBalance]
}

// MARK: - Reserved Balances

public enum ReservedBalanceStatus: String, Codable, Sendable {
    case held
    case released
    case cancelled
}

public enum ReservedBalanceDirection: String, Codable, Sendable {
    case inbound
    case outbound
}

public struct ReservedBalance: Codable, Sendable {
    public let id: ReservedBalanceID
    public let arcaId: ObjectID
    public let operationId: OperationID
    public let denomination: String
    public let amount: String
    public let status: ReservedBalanceStatus
    public let direction: ReservedBalanceDirection
    public let sourceArcaPath: String?
    public let destinationArcaPath: String?
    public let createdAt: String
    public let updatedAt: String
}

// MARK: - Positions

public struct ArcaPositionCurrent: Codable, Sendable {
    public let id: PositionID
    public let realmId: RealmID
    public let arcaId: ObjectID
    public let market: String
    public let side: String
    public let size: String
    public let leverage: Int
    public let entryPrice: String?
    public let updatedAt: String
}

// MARK: - Response Types

public struct ArcaObjectListResponse: Codable, Sendable {
    public let objects: [ArcaObject]
    public let total: Int
}

public struct ArcaObjectBrowseResponse: Codable, Sendable {
    public let prefix: String
    public let folders: [String]
    public let objects: [ArcaObject]
}

public struct CreateArcaObjectResponse: Codable, Sendable, OperationResponse {
    public let object: ArcaObject
    public let operation: Operation

    public func withOperation(_ op: Operation) -> Self {
        .init(object: object, operation: op)
    }
}

public struct DeleteArcaObjectResponse: Codable, Sendable, OperationResponse {
    public let object: ArcaObject
    public let operation: Operation

    public func withOperation(_ op: Operation) -> Self {
        .init(object: object, operation: op)
    }
}

public struct ArcaObjectDetailResponse: Codable, Sendable {
    public let object: ArcaObject
    public let operations: [Operation]
    public let events: [ArcaEvent]
    public let deltas: [StateDelta]
    public let balances: [ArcaBalance]
    public let reservedBalances: [ReservedBalance]
    public let positions: [ArcaPositionCurrent]
}

public struct ArcaObjectVersionsResponse: Codable, Sendable {
    public let versions: [ArcaObject]
}
