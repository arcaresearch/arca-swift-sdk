import Foundation

/// A type-safe identifier wrapper using phantom types for compile-time ID safety.
/// All entity IDs follow the TypeID format: `prefix_base32suffix`.
public struct TypedID<Tag>: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

extension TypedID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension TypedID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

// MARK: - Tag Types

public enum ObjectTag {}
public enum OperationTag {}
public enum EventTag {}
public enum DeltaTag {}
public enum BalanceTag {}
public enum ReservedBalanceTag {}
public enum PositionTag {}
public enum RealmTag {}
public enum UserTag {}
public enum OrgTag {}
public enum SimAccountTag {}
public enum SimPositionTag {}
public enum SimOrderTag {}
public enum SimFillTag {}
public enum ErrorTag {}
public enum WatchTag {}

// MARK: - Type Aliases

public typealias ObjectID = TypedID<ObjectTag>
public typealias OperationID = TypedID<OperationTag>
public typealias EventID = TypedID<EventTag>
public typealias DeltaID = TypedID<DeltaTag>
public typealias BalanceID = TypedID<BalanceTag>
public typealias ReservedBalanceID = TypedID<ReservedBalanceTag>
public typealias PositionID = TypedID<PositionTag>
public typealias RealmID = TypedID<RealmTag>
public typealias UserID = TypedID<UserTag>
public typealias OrgID = TypedID<OrgTag>
public typealias SimAccountID = TypedID<SimAccountTag>
public typealias SimPositionID = TypedID<SimPositionTag>
public typealias SimOrderID = TypedID<SimOrderTag>
public typealias SimFillID = TypedID<SimFillTag>
public typealias ErrorID = TypedID<ErrorTag>
public typealias WatchID = TypedID<WatchTag>
