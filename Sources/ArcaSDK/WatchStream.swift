import Foundation

// MARK: - WatchStreamState

/// Lifecycle state for a watch stream.
///
/// Streams follow: `loading → connected ⇄ reconnecting`.
/// They never enter a terminal error state.
public enum WatchStreamState: Sendable {
    case loading, connected, reconnecting
}

// MARK: - OperationWatchStream

/// A stream of real-time operation events.
/// `operations` contains the running list; `updates` yields each new event.
public struct OperationWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Operations list, populated on first snapshot and refreshed on reconnect.
    public let operations: SendableBox<[Operation]>
    /// Async stream of operation create/update events.
    public let updates: AsyncStream<(Operation, RealmEvent)>
    /// Stop listening and unsubscribe from operation updates.
    public let stop: @Sendable () async -> Void

    /// Returns when the first snapshot has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
        }
    }
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
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current balances by object ID, updated as events arrive.
    public let balances: SendableBox<[String: BalanceSnapshot]>
    /// Async stream of balance update events.
    public let updates: AsyncStream<(String, RealmEvent)>
    /// Stop listening and unsubscribe from balance updates.
    public let stop: @Sendable () async -> Void

    /// Returns when the first snapshot has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - ExchangeWatchStream

/// A stream of real-time exchange state and fill events.
public struct ExchangeWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current exchange state (updated on each `exchange.updated` event).
    public let exchangeState: SendableBox<ExchangeState?>
    /// Async stream of exchange state updates and fills.
    public let updates: AsyncStream<ExchangeUpdate>
    /// Stop listening and unsubscribe from exchange updates.
    public let stop: @Sendable () async -> Void

    /// Returns when the stream is connected. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// An exchange update — either a state change or a fill.
public enum ExchangeUpdate: Sendable {
    case stateUpdate(ExchangeState, RealmEvent)
    case fill(SimFill, RealmEvent)
}

// MARK: - MarketPriceStream

/// A stream of real-time mid prices.
public struct MarketPriceStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current mid prices, populated on first snapshot and refreshed on reconnect.
    public let prices: SendableBox<[String: String]>
    /// Async stream of mid price updates (each update is a full snapshot of all prices).
    public let updates: AsyncStream<[String: String]>
    /// Stop listening and unsubscribe from mid price updates.
    public let stop: @Sendable () async -> Void

    /// Returns when the first snapshot has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - CandleWatchStream

/// A stream of real-time candle updates.
public struct CandleWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Async stream of candle events (both closed and in-progress).
    public let updates: AsyncStream<CandleEvent>
    /// Stop listening and unsubscribe from candle updates.
    public let stop: @Sendable () async -> Void

    /// Returns when the stream is connected. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
