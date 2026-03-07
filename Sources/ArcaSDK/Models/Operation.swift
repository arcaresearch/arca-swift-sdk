import Foundation

// MARK: - Operation

public enum OperationType: String, Codable, Sendable {
    case transfer
    case create
    case delete
    case deposit
    case withdrawal
    case swap
    case order
    case cancel
    case feeDistribution = "fee_distribution"
}

public enum OperationState: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case expired

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .expired: return true
        case .pending: return false
        }
    }
}

public struct Operation: Codable, Sendable {
    public let id: OperationID
    public let realmId: RealmID
    public let path: String
    public let type: OperationType
    public let state: OperationState
    public let sourceArcaPath: String?
    public let targetArcaPath: String?
    public let input: String?
    public let outcome: String?
    public let actorType: String?
    public let actorId: UserID?
    public let tokenJti: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct OperationListResponse: Codable, Sendable {
    public let operations: [Operation]
    public let total: Int
}

public struct OperationDetailResponse: Codable, Sendable {
    public let operation: Operation
    public let events: [ArcaEvent]
    public let deltas: [StateDelta]
}

// MARK: - Event

public struct ArcaEvent: Codable, Sendable {
    public let id: EventID
    public let realmId: RealmID
    public let operationId: OperationID?
    public let arcaPath: String?
    public let type: String
    public let path: String?
    public let payload: String?
    public let createdAt: String
}

public struct EventListResponse: Codable, Sendable {
    public let events: [ArcaEvent]
    public let total: Int
}

public struct EventDetailResponse: Codable, Sendable {
    public let event: ArcaEvent
    public let operation: Operation?
    public let deltas: [StateDelta]
}

// MARK: - State Delta

public enum DeltaType: String, Codable, Sendable {
    case balanceChange = "balance_change"
    case settlementChange = "settlement_change"
    case positionChange = "position_change"
    case statusChange = "status_change"
    case holdChange = "hold_change"
    case creation
    case deletion
}

public struct StateDelta: Codable, Sendable {
    public let id: DeltaID
    public let realmId: RealmID
    public let eventId: EventID?
    public let arcaPath: String
    public let deltaType: DeltaType
    public let beforeValue: String?
    public let afterValue: String?
    public let createdAt: String
}

public struct StateDeltaListResponse: Codable, Sendable {
    public let deltas: [StateDelta]
    public let total: Int
}
