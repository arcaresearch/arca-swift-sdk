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

    internal let updateCallbacks: SendableBox<[UUID: @Sendable (Operation, RealmEvent) -> Void]>

    /// Register a callback invoked on each operation event. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (Operation, RealmEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

    /// Returns when the first snapshot has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
        }
    }

    /// Track a mutation's operation: when the HTTP response arrives,
    /// the operation is immediately injected into the `operations` list,
    /// giving instant UI feedback before the server-side WebSocket event.
    func trackSubmission<T: OperationResponse>(_ handle: OperationHandle<T>) {
        let ops = self.operations
        Task { [ops] in
            guard let response = try? await handle.submitted else { return }
            let op = response.operation
            ops.update { list in
                if !list.contains(where: { $0.id == op.id }) {
                    list.insert(op, at: 0)
                }
            }
        }
    }
}

/// Thread-safe mutable wrapper for use in Sendable stream types.
///
/// Supports callback-based change observation via ``onChange(_:)``.
/// Register a handler to be notified after each mutation — useful for
/// driving SwiftUI state or bridging to other reactive patterns without
/// needing to iterate an `AsyncStream`.
public final class SendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    private var _observers: [UUID: @Sendable (T) -> Void] = [:]

    public init(_ value: T) { self._value = value }

    public var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    public func update(_ transform: (inout T) -> Void) {
        lock.lock()
        transform(&_value)
        let snapshot = _value
        let observers = _observers
        lock.unlock()
        for cb in observers.values { cb(snapshot) }
    }

    /// Atomically mutate the value and return the post-mutation snapshot.
    public func updateAndGet(_ transform: (inout T) -> Void) -> T {
        lock.lock()
        transform(&_value)
        let result = _value
        let observers = _observers
        lock.unlock()
        for cb in observers.values { cb(result) }
        return result
    }

    /// Register a callback invoked after each mutation with the new value.
    /// Returns an ID that can be passed to ``removeObserver(_:)`` to unregister.
    @discardableResult
    public func onChange(_ handler: @escaping @Sendable (T) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        _observers[id] = handler
        lock.unlock()
        return id
    }

    /// Remove a previously registered ``onChange(_:)`` handler.
    public func removeObserver(_ id: UUID) {
        lock.lock()
        _observers.removeValue(forKey: id)
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

    internal let updateCallbacks: SendableBox<[UUID: @Sendable (String, RealmEvent) -> Void]>

    /// Register a callback invoked on each balance update. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (String, RealmEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

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

    internal let updateCallbacks: SendableBox<[UUID: @Sendable (ObjectValuation) -> Void]>

    /// Register a callback invoked on each valuation update. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (ObjectValuation) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

    /// Returns when the first valuation has been received. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - ObjectsWatchStream

/// Merges multiple ``ObjectWatchStream`` instances into one dictionary keyed by
/// object path. Each valuation update from any child emits the full merged snapshot.
public struct ObjectsWatchStream: Sendable {
    /// Aggregate lifecycle state derived from child streams (reconnecting if any child is reconnecting, else loading if any is still loading, else connected).
    public let state: SendableBox<WatchStreamState>
    /// Latest valuations keyed by Arca object path.
    public let valuations: SendableBox<[String: ObjectValuation]>
    /// Underlying per-path streams (same order as deduplicated paths).
    public let childStreams: [ObjectWatchStream]
    /// Async stream of merged valuation dictionaries.
    public let updates: AsyncStream<[String: ObjectValuation]>
    /// Stop all child streams and release subscriptions.
    public let stop: @Sendable () async -> Void

    internal let updateCallbacks: SendableBox<[UUID: @Sendable ([String: ObjectValuation]) -> Void]>

    /// Register a callback invoked on each merged snapshot. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable ([String: ObjectValuation]) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

    /// Returns when every child stream has received its first valuation. Never throws.
    /// For an empty path list, returns immediately.
    public func ready() async {
        for s in childStreams {
            await s.ready()
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

    internal let updateCallbacks: SendableBox<[UUID: @Sendable (PathAggregation) -> Void]>

    /// Register a callback invoked on each aggregation update. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (PathAggregation) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

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

// MARK: - PnlChartStream

/// Merges historical P&L data with a live aggregation stream and operation
/// events. The rightmost point updates on each aggregation event. Operation
/// events update cumulative flows client-side (zero additional server reads).
public struct PnlChartStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current P&L chart points (historical + live tail).
    public let chart: SendableBox<[PnlPoint]>
    /// Async stream of P&L chart updates.
    public let updates: AsyncStream<PnlChartUpdate>
    /// Stop listening, unsubscribe, and destroy the underlying streams.
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

// MARK: - CandleChartStream

/// Merges historical candle data with real-time WebSocket candle events.
/// Maintains a deduped, sorted candle array that updates on every
/// `candle.updated` and `candle.closed` event. Automatically recovers
/// gaps on WebSocket reconnection by refetching recent candles.
///
/// Two ways to observe live updates:
/// - **AsyncStream**: iterate ``updates`` with `for await`.
/// - **Callback**: call ``onUpdate(_:)`` for push-based delivery
///   (easier to integrate with SwiftUI `@State`).
///
/// The ``candles`` property is always current; use ``SendableBox/onChange(_:)``
/// on it directly if you only need the raw array.
public struct CandleChartStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current candle array (historical + live), sorted by `t`, deduped.
    public let candles: SendableBox<[Candle]>
    /// Async stream of chart updates.
    public let updates: AsyncStream<CandleChartUpdate>

    internal let updateCallbacks: SendableBox<[UUID: @Sendable (CandleChartUpdate) -> Void]>

    /// Register a callback invoked on each chart update (candle added or
    /// updated). Returns an unsubscribe function.
    ///
    /// ```swift
    /// let unsub = stream.onUpdate { update in
    ///     self.chartCandles = update.candles
    /// }
    /// // later:
    /// unsub()
    /// ```
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (CandleChartUpdate) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

    /// Ensure candles are loaded for the given time range. The SDK tracks
    /// which ranges have already been fetched and only requests the gaps.
    /// Calling with an already-loaded range is a no-op (idempotent).
    /// Overlapping calls are coalesced into the pending range instead of
    /// being dropped.
    ///
    /// Use this when the chart viewport changes (zoom, resize, scroll, or
    /// jumping to a specific date).
    public let ensureRange: @Sendable (_ start: Int, _ end: Int) async -> LoadRangeResult

    /// Load older candles backwards from the current earliest candle.
    /// Convenience wrapper around ``ensureRange``.
    ///
    /// - Parameter count: Number of candle periods to load (default 300).
    public let loadMore: @Sendable (_ count: Int) async -> LoadRangeResult

    /// Stop listening, unsubscribe, and clean up.
    public let stop: @Sendable () async -> Void

    /// Returns when the first historical data has loaded. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - MaxOrderSizeWatchStream

/// Options for ``Arca/watchMaxOrderSize(options:)``.
public struct MaxOrderSizeWatchOptions: Sendable {
    public let objectId: String
    public let coin: String
    public let side: OrderSide
    public let leverage: Int
    public let builderFeeBps: Int
    public let szDecimals: Int
    /// HIP-3 fee multiplier for this asset. Defaults to 1 (standard perps).
    /// When nil, ``Arca/watchMaxOrderSize(options:)`` auto-fetches from tickers.
    public let feeScale: Double?
    /// Asset's base maintenance margin rate as a decimal (e.g. "0.01" for 1%).
    /// Used to populate ``ActiveAssetData/maintenanceMarginRate``, which
    /// feeds ``Arca/orderBreakdown(options:)``'s liquidation estimate. When
    /// nil, ``Arca/watchMaxOrderSize(options:)`` auto-fetches it via
    /// ``Arca/getActiveAssetData(_:_:builderFeeBps:leverage:)``.
    public let maintenanceMarginRate: String?

    public init(
        objectId: String,
        coin: String,
        side: OrderSide,
        leverage: Int,
        builderFeeBps: Int = 0,
        szDecimals: Int = 5,
        feeScale: Double? = nil,
        maintenanceMarginRate: String? = nil
    ) {
        self.objectId = objectId
        self.coin = coin
        self.side = side
        self.leverage = leverage
        self.builderFeeBps = builderFeeBps
        self.szDecimals = szDecimals
        self.feeScale = feeScale
        self.maintenanceMarginRate = maintenanceMarginRate
    }
}

/// A stream that recomputes ``ActiveAssetData`` whenever exchange state
/// or mid prices change. Matches the TypeScript SDK's `MaxOrderSizeWatchStream`.
public struct MaxOrderSizeWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Latest derived active asset data (nil until first computation).
    public let activeAssetData: SendableBox<ActiveAssetData?>
    /// Async stream of recomputed active asset data.
    public let updates: AsyncStream<ActiveAssetData>
    /// Stop listening and unsubscribe from all underlying streams.
    public let stop: @Sendable () async -> Void

    /// Returns when the first computation has completed. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - ExchangeStateWatchStream

/// A stream of real-time exchange state updates for an Arca exchange object.
/// Fetches initial state via REST, then re-fetches on each `exchange.updated` event.
public struct ExchangeStateWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Current exchange state (positions, orders, margin).
    public let exchangeState: SendableBox<ExchangeState?>
    /// Async stream of exchange state updates.
    public let updates: AsyncStream<ExchangeState>
    /// Stop listening and unsubscribe.
    public let stop: @Sendable () async -> Void

    /// Returns when the first state has been fetched. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - FundingWatchStream

/// A stream of real-time funding payment events for an exchange Arca object.
public struct FundingWatchStream: Sendable {
    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Async stream of funding payment events.
    public let updates: AsyncStream<(FundingPayment, EventEnvelope)>
    /// Stop listening and unsubscribe.
    public let stop: @Sendable () async -> Void

    /// Returns when the stream is connected. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - FillWatchStream

/// A stream of platform-level trade history for an exchange Arca object.
///
/// Two-phase fill delivery with envelope-based correlation:
/// 1. `exchange.fill` — instant preview with venue data (matched by `correlationId`)
/// 2. `fill.recorded` — authoritative fill replaces preview (matched by `correlationId`)
///
/// A convergence timeout fires if a preview doesn't receive its authoritative
/// update within 10 seconds. On reconnect, re-fetches from REST to reconcile gaps.
public struct FillWatchStream: Sendable {
    /// Convergence timeout for preview fills awaiting authoritative updates.
    public static let convergenceTimeoutNs: UInt64 = 10_000_000_000 // 10s

    /// Current lifecycle state of the stream.
    public let state: SendableBox<WatchStreamState>
    /// Running list of fills, populated on initial fetch and updated live.
    public let fills: SendableBox<[Fill]>
    /// Async stream of new fill events.
    public let updates: AsyncStream<(Fill, RealmEvent)>
    /// Stop listening and unsubscribe from fill updates.
    public let stop: @Sendable () async -> Void

    internal let convergenceCallbacks: SendableBox<[UUID: @Sendable (String) -> Void]>

    /// Register a callback for convergence timeouts. Fires when a preview
    /// (`exchange.fill`) doesn't receive its authoritative update (`fill.recorded`)
    /// within the timeout window. Returns a UUID to remove the handler later.
    @discardableResult
    public func onConvergenceTimeout(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        convergenceCallbacks.update { $0[id] = handler }
        return id
    }

    /// Remove a previously registered convergence timeout handler.
    public func removeConvergenceHandler(id: UUID) {
        convergenceCallbacks.update { $0.removeValue(forKey: id) }
    }

    /// Returns when the initial fill list has been fetched. Never throws.
    public func ready() async {
        while state.value == .loading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
