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

// MARK: - ObjectWatchStream

/// A stream of real-time valuation updates for a single Arca object.
/// Uses the same computation path as aggregation (Axiom 10: Observational Consistency).
public struct ObjectWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Path of the watched object.
    public let path: String
    /// Watch ID assigned by the server (used for unsubscribe).
    public let watchId: SendableBox<String?>
    /// Current valuation (updated on each server push).
    public let valuation: SendableBox<ObjectValuation?>
    /// Async stream of valuation updates.
    public let updates: AsyncStream<ObjectValuation>
    /// Stop listening and unsubscribe.
    public let stop: @Sendable () async -> Void

    /// Returns when the first valuation has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - AggregationWatchStream

/// A stream of real-time aggregation updates with client-side revaluation.
/// Structural changes come from the server; mid-price revaluation is performed
/// client-side so updates reflect live prices without extra server bandwidth.
public struct AggregationWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Server-assigned watch ID.
    public let watchId: String
    /// Current aggregation (updated on structural changes and price ticks).
    public let aggregation: SendableBox<PathAggregation?>
    /// Async stream of revalued aggregation updates.
    public let updates: AsyncStream<PathAggregation>
    /// Stop listening, unsubscribe from updates, and destroy the server-side watch.
    public let stop: @Sendable () async -> Void

    /// Returns when the first aggregation has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
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

// MARK: - EquityChartStream

/// Merges historical equity data with a live aggregation stream.
/// The rightmost point updates on each aggregation event. When the hour
/// boundary is crossed, the current point is promoted to historical and
/// a new live point starts.
public struct EquityChartStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current chart points (historical + live tail), updated on each aggregation event.
    public let chart: SendableBox<[EquityPoint]>
    /// Async stream of chart updates.
    public let updates: AsyncStream<EquityChartUpdate>
    /// Stop listening, unsubscribe, and destroy the underlying aggregation watch.
    public let stop: @Sendable () async -> Void

    /// Returns when the first update has been emitted. Never throws.
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
