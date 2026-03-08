import Foundation

// MARK: - OperationWatchStream

/// A stream of real-time operation events.
/// `operations` contains the running list; `updates` yields each new event.
public struct OperationWatchStream: Sendable {
    /// Operations at the time the stream was created, updated as events arrive.
    public let operations: SendableBox<[Operation]>
    /// Async stream of operation create/update events.
    public let updates: AsyncStream<(Operation, RealmEvent)>
    /// Stop listening and unsubscribe from operation updates.
    public let stop: @Sendable () async -> Void
}

/// Thread-safe mutable wrapper for use in Sendable stream types.
public final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    public init(_ value: T) { self._value = value }

    public var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    public func update(_ transform: (inout T) -> Void) {
        lock.lock()
        transform(&_value)
        lock.unlock()
    }
}

// MARK: - BalanceWatchStream

/// Snapshot of balances for a single object.
public struct BalanceSnapshot: Codable, Sendable {
    public let entityId: String
    public let entityPath: String?
    public let balances: [ArcaBalance]
}

/// A stream of real-time balance updates.
public struct BalanceWatchStream: Sendable {
    /// Current balances by object ID, updated as events arrive.
    public let balances: SendableBox<[String: BalanceSnapshot]>
    /// Async stream of balance update events.
    public let updates: AsyncStream<(String, RealmEvent)>
    /// Stop listening and unsubscribe from balance updates.
    public let stop: @Sendable () async -> Void
}

// MARK: - ExchangeWatchStream

/// A stream of real-time exchange state and fill events.
public struct ExchangeWatchStream: Sendable {
    /// Current exchange state (updated on each `exchange.updated` event).
    public let exchangeState: SendableBox<ExchangeState?>
    /// Async stream of exchange state updates and fills.
    public let updates: AsyncStream<ExchangeUpdate>
    /// Stop listening and unsubscribe from exchange updates.
    public let stop: @Sendable () async -> Void
}

/// An exchange update — either a state change or a fill.
public enum ExchangeUpdate: Sendable {
    case stateUpdate(ExchangeState, RealmEvent)
    case fill(SimFill, RealmEvent)
}

// MARK: - CandleWatchStream

/// A stream of real-time candle updates.
public struct CandleWatchStream: Sendable {
    /// Async stream of candle events (both closed and in-progress).
    public let updates: AsyncStream<CandleEvent>
    /// Stop listening and unsubscribe from candle updates.
    public let stop: @Sendable () async -> Void
}
