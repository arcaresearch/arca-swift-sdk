import Foundation

// MARK: - Arca Object Types

public enum ArcaObjectType: Codable, Sendable, Equatable {
    case denominated
    case exchange
    case deposit
    case withdrawal
    case escrow
    case info
    case unknown(String)

    private static let mapping: [(String, ArcaObjectType)] = [
        ("denominated", .denominated),
        ("exchange", .exchange),
        ("deposit", .deposit),
        ("withdrawal", .withdrawal),
        ("escrow", .escrow),
        ("info", .info),
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

    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.mapping.first(where: { $0.1 == self })?.0 ?? ""
    }
}

public enum ArcaObjectStatus: String, Codable, Sendable {
    case active
    case deleting
    case deleted
}

/// Per-boundary recovery-hatch state surfaced on `ArcaObject`. Present
/// (non-nil) only when the object's isolation boundary is currently
/// `soft_frozen` or `hard_frozen` — i.e. the recovery key holder has
/// taken action on-chain and the platform has refused to dispatch new
/// operations into the boundary. Active boundaries omit the field.
///
/// `softFrozen` is reversible: the recovery key holder may unlock the
/// boundary on-chain and the platform will return to `active`. Once a
/// `Withdrawn` event fires, the boundary becomes `hardFrozen` and is
/// terminal — the platform sweeps every wallet in the boundary into a
/// system-owned recovery arca at `recoveryArcaPath`. New operations
/// against the boundary return HTTP 409 `BOUNDARY_FROZEN`.
public enum BoundaryStatus: String, Codable, Sendable {
    case active
    case softFrozen = "soft_frozen"
    case hardFrozen = "hard_frozen"
}

public struct BoundarySnapshot: Codable, Sendable {
    public let boundaryId: String
    public let status: BoundaryStatus
    public let lockedAt: String?
    public let frozenAt: String?
    public let recoveryActor: String?
    public let recoveryTxHash: String?
    public let recoveryArcaPath: String?
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
    /// Recovery-hatch state. Nil when the boundary is `active` (the
    /// happy path). When non-nil, callers should refuse to dispatch new
    /// operations on this object — the server will reject them with
    /// `BOUNDARY_FROZEN` anyway. Frozen wallets read $0 after the
    /// platform's recovery sweep lands.
    public let boundary: BoundarySnapshot?
}

// MARK: - Balances

public struct ArcaBalance: Codable, Sendable {
    public let id: BalanceID?
    public let arcaId: ObjectID?
    public let denomination: String
    public let amount: String?
    public let arriving: String?
    public let settled: String?
    public let departing: String?
    public let total: String?
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
    public let entryPx: String?
    public let updatedAt: String
}

// MARK: - Response Types

public struct ArcaObjectListResponse: Codable, Sendable {
    public let objects: [ArcaObject]
    public let total: Int
}

public struct ArcaObjectBrowseResponse: Codable, Sendable {
    public let folders: [String]
    public let objects: [ArcaObject]
    public let total: Int?
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
    public let reservedBalances: [ReservedBalance]?
    public let positions: [ArcaPositionCurrent]?
}

public struct ArcaObjectVersionsResponse: Codable, Sendable {
    public let versions: [ArcaObject]
}

// MARK: - Realm

public enum RealmType: String, Codable, Sendable {
    case development
    case production
}

public struct RealmSettings: Codable, Sendable {
    public let defaultBuilderFeeBps: Int?
}

public struct Realm: Codable, Sendable {
    public let id: RealmID
    public let orgId: OrgID
    public let name: String
    public let slug: String
    public let type: RealmType
    public let description: String?
    public let settings: RealmSettings?
    public let archivedAt: String?
    public let createdBy: UserID?
    public let createdAt: String
    public let updatedAt: String
}
