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
    case fill
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
    public let parsedOutcome: [String: String]?
    public let failureMessage: String?
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
    public let context: OperationContext?
    public let events: [ArcaEvent]
    public let deltas: [StateDelta]
}

// MARK: - Operation Context

public struct OperationContext: Codable, Sendable {
    public let type: String
    public let fill: FillContext?
    public let transfer: TransferContext?
    public let deposit: DepositContext?
    public let withdrawal: WithdrawalContext?
    public let order: OrderPlacedContext?
    public let cancel: CancelContext?
    public let delete: DeleteContext?
}

public struct FeeBreakdown: Codable, Sendable {
    public let exchange: String
    public let platform: String
    public let builder: String
}

public struct FillContext: Codable, Sendable {
    public let coin: String
    public let side: String
    public let size: String
    public let price: String
    public let market: String
    public let dir: String?
    public let orderId: String?
    public let orderOperationId: String?
    public let realizedPnl: String
    public let fee: String
    public let feeBreakdown: FeeBreakdown?
    public let netBalanceChange: String
    public let startPosition: String?
    public let resultingPosition: FillResultingPosition?
    public let isLiquidation: Bool
}

public struct TransferContext: Codable, Sendable {
    public let amount: String
    public let denomination: String
    public let sourceArcaPath: String
    public let targetArcaPath: String
    public let feeAmount: String?
}

public struct DepositContext: Codable, Sendable {
    public let amount: String
    public let denomination: String
    public let destination: String?
}

public struct WithdrawalContext: Codable, Sendable {
    public let amount: String
    public let denomination: String
    public let txHash: String?
}

public struct OrderPlacedContext: Codable, Sendable {
    public let orderId: String
    public let coin: String
    public let side: String
    public let orderType: String
    public let size: String
    public let leverage: String?
}

public struct CancelContext: Codable, Sendable {
    public let orderId: String
}

public struct DeleteContext: Codable, Sendable {
    public let objectPath: String
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
    public let `internal`: Bool?
    public let createdAt: String
}

public struct StateDeltaListResponse: Codable, Sendable {
    public let deltas: [StateDelta]
    public let total: Int
}
