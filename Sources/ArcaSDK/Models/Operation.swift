import Foundation

// MARK: - JSONValue

/// Type-erased JSON value for fields like `parsedOutcome` where the server
/// may return strings, numbers, booleans, arrays, or nested objects.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience accessor for string values.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Convenience accessor for integer values.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
}

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
    case adjustment
    case funding
    case twap
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
    public let parsedOutcome: [String: JSONValue]?
    public let failureMessage: String?
    public let actorType: String?
    public let actorId: UserID?
    public let tokenJti: String?
    public let createdAt: String
    public let updatedAt: String
    public let context: OperationContext?
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

public enum DeltaType: Codable, Sendable, Equatable {
    case balanceChange
    case balanceAdjustment
    case settlementChange
    case positionChange
    case statusChange
    case holdChange
    case labelsChange
    case creation
    case deletion
    case unknown(String)

    private static let mapping: [(String, DeltaType)] = [
        ("balance_change", .balanceChange),
        ("balance_adjustment", .balanceAdjustment),
        ("settlement_change", .settlementChange),
        ("position_change", .positionChange),
        ("status_change", .statusChange),
        ("hold_change", .holdChange),
        ("labels_change", .labelsChange),
        ("creation", .creation),
        ("deletion", .deletion),
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.mapping.first(where: { $0.0 == raw })?.1 ?? .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .unknown(let raw) = self {
            try container.encode(raw)
            return
        }
        if let pair = Self.mapping.first(where: { $0.1 == self }) {
            try container.encode(pair.0)
        }
    }
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
