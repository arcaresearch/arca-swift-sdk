import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Actor-based WebSocket manager for real-time Arca events.
///
/// Handles authentication, channel subscriptions, automatic reconnection
/// with exponential backoff, and delivers events via `AsyncStream`.
///
/// ```swift
/// let arca = try Arca(token: jwt)
/// await arca.ws.connect(channels: [.operations, .balances])
///
/// for await event in await arca.ws.events {
///     print(event.type, event.entityId ?? "")
/// }
/// ```
public actor WebSocketManager {
    private let baseURL: URL
    private var token: String
    private let realmId: String

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession

    private var subscribedMids: (exchange: String, coins: [String])?
    private var subscribedCandles: (coins: [String], intervals: [CandleInterval])?
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private var eventContinuations: [UUID: AsyncStream<RealmEvent>.Continuation] = [:]
    private var statusContinuations: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    private var _status: ConnectionStatus = .disconnected

    // Ref-counted path watch engine
    private var pathRefs: [String: Int] = [:]
    private var midsRefs = 0
    private var midsExchange = "sim"
    private var candleRefCoins: [String: Set<String>] = [:]
    private var chartHistoryWatches: [String: (target: String, kind: String, objectId: String?)] = [:]
    private var unsubTasks: [String: Task<Void, Never>] = [:]
    private var idleDisconnectTask: Task<Void, Never>?
    private static let unsubDebounceNs: UInt64 = 100_000_000 // 100ms
    private static let idleDisconnectNs: UInt64 = 60_000_000_000 // 60s

    // Application-level heartbeat for half-open connection detection
    private var pingTask: Task<Void, Never>?
    private var lastMessageAt: Date = Date()
    private static let pingIntervalNs: UInt64 = 30_000_000_000  // 30s
    private static let staleThresholdS: TimeInterval = 45        // 45s
    // Hidden duration shorter than this is treated as a quick switch and
    // does NOT trigger a resume signal.
    private static let resumeHiddenThresholdS: TimeInterval = 5
    // After resuming, ping and wait this long for any inbound traffic;
    // absence is treated as a half-open TCP and forces a reconnect.
    private static let resumePingTimeoutNs: UInt64 = 2_000_000_000  // 2s

    private var lastDeliverySeq: Int = 0
    private var gapHandlers: [UUID: @Sendable (Int) -> Void] = [:]
    private var resumeHandlers: [UUID: @Sendable (TimeInterval) -> Void] = [:]
    private var authenticatedHandlers: [UUID: @Sendable () -> Void] = [:]
    private var resumeContinuations: [UUID: AsyncStream<TimeInterval>.Continuation] = [:]
    private var authenticatedContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var hiddenAt: Date?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var resumeProbeTask: Task<Void, Never>?

    /// If set, called on each reconnect to obtain a fresh token.
    private let getToken: (@Sendable () async throws -> String)?

    /// Diagnostic logger. Emits records under category `websocket`.
    private let log: ArcaLogger

    public init(
        baseURL: URL,
        token: String,
        realmId: String,
        getToken: (@Sendable () async throws -> String)? = nil,
        maxReconnectDelay: TimeInterval = 30,
        logger: ArcaLogger = .disabled
    ) {
        self.baseURL = baseURL
        self.token = token
        self.realmId = realmId
        self.getToken = getToken
        self.maxReconnectDelay = maxReconnectDelay
        self.session = URLSession(configuration: .default)
        self.log = logger
    }

    /// Update the bearer token. If disconnected and should reconnect,
    /// triggers an immediate reconnect with the new token.
    public func updateToken(_ newToken: String) {
        self.token = newToken

        if shouldReconnect && webSocketTask == nil {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            doConnect()
        }
    }

    /// Current connection status.
    public var status: ConnectionStatus { _status }

    // MARK: - Connection Lifecycle

    /// Connect to the WebSocket.
    public func connect() {
        shouldReconnect = true
        // Install lifecycle observers lazily on first connect so we
        // observe app foreground/background only when actually using the
        // network. `installLifecycleObservers()` is idempotent so repeat
        // connects after `disconnect()` work too.
        installLifecycleObservers()
        doConnect()
    }

    /// Connect only if not already connected or connecting.
    public func ensureConnected() {
        if webSocketTask != nil { return }
        connect()
    }

    /// Disconnect and stop reconnecting.
    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        stopHeartbeat()
        cancelIdleTimer()
        for task in unsubTasks.values { task.cancel() }
        unsubTasks.removeAll()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        setStatus(.disconnected)
        removeLifecycleObservers()
    }

    /// Subscribe to real-time mid price updates.
    public func subscribeMids(exchange: String, coins: [String] = []) {
        subscribedMids = (exchange, coins)
        sendMessage(.subscribeMids(exchange: exchange, coins: coins))
    }

    /// Unsubscribe from mid price updates.
    public func unsubscribeMids() {
        subscribedMids = nil
        sendMessage(.unsubscribeMids)
    }

    /// Subscribe to real-time candle updates for given coins and intervals.
    public func subscribeCandles(coins: [String], intervals: [CandleInterval]) {
        subscribedCandles = (coins, intervals)
        sendMessage(.subscribeCandles(coins: coins, intervals: intervals.map(\.rawValue)))
    }

    /// Unsubscribe from candle updates.
    public func unsubscribeCandles() {
        subscribedCandles = nil
        sendMessage(.unsubscribeCandles)
    }

    // MARK: - Path Watch Management

    /// Watch a path. Increments the ref count; sends a `watch` message on first interest.
    public func watchPath(_ path: String) {
        cancelIdleTimer()
        let prev = pathRefs[path, default: 0]
        pathRefs[path] = prev + 1
        if prev == 0 {
            let timerKey = "path:\(path)"
            if let task = unsubTasks.removeValue(forKey: timerKey) {
                task.cancel()
            } else {
                ensureConnected()
                sendMessage(.watch(path: path))
            }
        }
    }

    /// Unwatch a path. Decrements the ref count; debounced unwatch when last watcher leaves.
    public func unwatchPath(_ path: String) {
        let current = pathRefs[path, default: 0]
        if current <= 1 {
            pathRefs.removeValue(forKey: path)
            let timerKey = "path:\(path)"
            unsubTasks[timerKey] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: WebSocketManager.unsubDebounceNs)
                guard !Task.isCancelled else { return }
                await self?.finishPathUnwatch(path: path, timerKey: timerKey)
            }
        } else {
            pathRefs[path] = current - 1
        }
    }

    private func finishPathUnwatch(path: String, timerKey: String) {
        unsubTasks.removeValue(forKey: timerKey)
        if pathRefs[path] == nil {
            sendMessage(.unwatch(path: path))
        }
        maybeStartIdleTimer()
    }

    /// Acquire interest in mid price updates.
    public func acquireMids(exchange: String) {
        cancelIdleTimer()
        midsExchange = exchange
        midsRefs += 1
        if midsRefs == 1 {
            let timerKey = "mids"
            if let task = unsubTasks.removeValue(forKey: timerKey) {
                task.cancel()
            } else {
                ensureConnected()
                subscribeMids(exchange: exchange)
            }
        }
    }

    /// Release interest in mid price updates.
    public func releaseMids() {
        midsRefs = max(0, midsRefs - 1)
        if midsRefs == 0 {
            let timerKey = "mids"
            unsubTasks[timerKey] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: WebSocketManager.unsubDebounceNs)
                guard !Task.isCancelled else { return }
                await self?.finishMidsRelease(timerKey: timerKey)
            }
        }
    }

    private func finishMidsRelease(timerKey: String) {
        unsubTasks.removeValue(forKey: timerKey)
        if midsRefs == 0 {
            unsubscribeMids()
        }
        maybeStartIdleTimer()
    }

    /// Acquire interest in candle updates.
    public func acquireCandles(coins: [String], intervals: [CandleInterval]) {
        cancelIdleTimer()
        for coin in coins {
            if candleRefCoins[coin] == nil {
                candleRefCoins[coin] = Set()
            }
            for iv in intervals {
                candleRefCoins[coin]!.insert(iv.rawValue)
            }
        }
        ensureConnected()
        syncCandleSubscription()
    }

    /// Release interest in candle updates.
    public func releaseCandles(coins: [String], intervals: [CandleInterval]) {
        for coin in coins {
            guard var ivs = candleRefCoins[coin] else { continue }
            for iv in intervals { ivs.remove(iv.rawValue) }
            if ivs.isEmpty {
                candleRefCoins.removeValue(forKey: coin)
            } else {
                candleRefCoins[coin] = ivs
            }
        }
        let timerKey = "candles"
        unsubTasks[timerKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: WebSocketManager.unsubDebounceNs)
            guard !Task.isCancelled else { return }
            await self?.finishCandleRelease(timerKey: timerKey)
        }
    }

    private func finishCandleRelease(timerKey: String) {
        unsubTasks.removeValue(forKey: timerKey)
        syncCandleSubscription()
        maybeStartIdleTimer()
    }

    private func syncCandleSubscription() {
        if candleRefCoins.isEmpty {
            unsubscribeCandles()
            return
        }
        let allCoins = Array(candleRefCoins.keys)
        var allIntervals = Set<String>()
        for ivs in candleRefCoins.values {
            allIntervals.formUnion(ivs)
        }
        let intervals = allIntervals.compactMap { CandleInterval(rawValue: $0) }
        subscribeCandles(coins: allCoins, intervals: intervals)
    }

    private func hasAnyInterest() -> Bool {
        !pathRefs.isEmpty || midsRefs > 0 || !candleRefCoins.isEmpty || !chartHistoryWatches.isEmpty
    }

    public func watchChartHistory(target: String, kind: String = "path", objectId: String? = nil) -> String {
        cancelIdleTimer()
        let watchId = UUID().uuidString
        chartHistoryWatches[watchId] = (target: target, kind: kind, objectId: objectId)
        ensureConnected()
        sendMessage(.watchChartHistory(watchId: watchId, target: target, kind: kind, objectId: objectId))
        return watchId
    }

    public func unwatchChartHistory(watchId: String) {
        chartHistoryWatches.removeValue(forKey: watchId)
        sendMessage(.unwatchChartHistory(watchId: watchId))
        maybeStartIdleTimer()
    }

    private func maybeStartIdleTimer() {
        guard !hasAnyInterest() else { return }
        guard idleDisconnectTask == nil else { return }
        idleDisconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: WebSocketManager.idleDisconnectNs)
            guard !Task.isCancelled else { return }
            await self?.idleDisconnect()
        }
    }

    private func idleDisconnect() {
        idleDisconnectTask = nil
        if !hasAnyInterest() {
            disconnect()
        }
    }

    private func cancelIdleTimer() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
    }

    // MARK: - Event Streams

    /// A stream of all realm events. Each call creates an independent stream;
    /// multiple consumers can iterate concurrently.
    public var events: AsyncStream<RealmEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeEventContinuation(id: id)
                }
            }
            self.eventContinuations[id] = continuation
        }
    }

    /// A stream of discriminated ``TypedEvent`` values. Each event carries its
    /// strongly-typed payload and an ``EventEnvelope`` with correlation spine
    /// fields. Use `switch` for exhaustive handling.
    public var typedEvents: AsyncStream<TypedEvent> {
        filteredStream { event in TypedEvent.from(event) }
    }

    /// A stream of connection status changes.
    public var statusStream: AsyncStream<ConnectionStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeStatusContinuation(id: id)
                }
            }
            self.statusContinuations[id] = continuation
            continuation.yield(self._status)
        }
    }

    /// Stream of operation events (created or updated).
    public func operationEvents() -> AsyncStream<(Operation, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.operationCreated.rawValue
               || event.type == EventType.operationUpdated.rawValue,
                  let op = event.operation else { return nil }
            return (op, event)
        }
    }

    /// Stream of balance update events.
    public func balanceEvents() -> AsyncStream<(String, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.balanceUpdated.rawValue,
                  let entityId = event.entityId else { return nil }
            return (entityId, event)
        }
    }

    /// Stream of exchange state update events.
    public func exchangeEvents() -> AsyncStream<(ExchangeState, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.exchangeUpdated.rawValue,
                  let state = event.exchangeState else { return nil }
            return (state, event)
        }
    }

    /// Stream of raw exchange update notifications, including events without inline state.
    public func exchangeNotifications() -> AsyncStream<RealmEvent> {
        filteredStream { event in
            guard event.type == EventType.exchangeUpdated.rawValue else { return nil }
            return event
        }
    }

    /// Stream of mid price updates.
    public func midsEvents() -> AsyncStream<[String: String]> {
        filteredStream { event in
            guard event.type == EventType.midsUpdated.rawValue,
                  let mids = event.mids else { return nil }
            return mids
        }
    }

    /// Stream of aggregation update events.
    public func aggregationEvents() -> AsyncStream<(String, PathAggregation?, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.aggregationUpdated.rawValue,
                  let entityId = event.entityId else { return nil }
            return (entityId, event.aggregation, event)
        }
    }

    /// Stream of all TWAP events (`twap.started`, `twap.progress`,
    /// `twap.completed`, `twap.cancelled`, `twap.failed`). Each emission
    /// carries the strongly-typed ``TypedEvent`` so the consumer can
    /// `switch` on the kind. To listen to a single TWAP, filter on
    /// `event.envelope?.entityId == twapId` or use ``Arca/watchTwap(exchangeId:operationId:)``.
    public func twapEvents() -> AsyncStream<TypedEvent> {
        filteredStream { event in
            switch event.type {
            case EventType.twapStarted.rawValue,
                 EventType.twapProgress.rawValue,
                 EventType.twapCompleted.rawValue,
                 EventType.twapCancelled.rawValue,
                 EventType.twapFailed.rawValue:
                return TypedEvent.from(event)
            default:
                return nil
            }
        }
    }

    public func chartSnapshotEvents() -> AsyncStream<(String, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.chartSnapshotUpdated.rawValue,
                  let watchId = event.watchId else { return nil }
            return (watchId, event)
        }
    }

    /// Stream of candle events (both closed and in-progress updates).
    public func candleEvents() -> AsyncStream<CandleEvent> {
        filteredStream { event in
            guard event.type == EventType.candleClosed.rawValue
               || event.type == EventType.candleUpdated.rawValue,
                  let coin = event.coin,
                  let intervalStr = event.interval,
                  let interval = CandleInterval(rawValue: intervalStr),
                  let candle = event.candle else { return nil }
            return CandleEvent(coin: coin, interval: interval, candle: candle)
        }
    }

    /// Stream of object valuation events (valuation + path + watchId + raw event).
    public func objectValuationEvents() -> AsyncStream<(ObjectValuation, String, String, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.objectValuation.rawValue,
                  let valuation = event.valuation,
                  let path = event.path,
                  let watchId = event.watchId else { return nil }
            return (valuation, path, watchId, event)
        }
    }

    /// Stream of exchange fill events (fill data + originating event).
    public func fillEvents() -> AsyncStream<(SimFill, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.exchangeFill.rawValue,
                  let fill = event.fill else { return nil }
            return (fill, event)
        }
    }

    /// Stream of platform-level fill recorded events (full Fill data + originating event).
    public func fillRecordedEvents() -> AsyncStream<(Fill, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.fillRecorded.rawValue,
                  let fill = event.recordedFill else { return nil }
            return (fill, event)
        }
    }

    /// Stream of exchange funding payment events.
    public func fundingEvents() -> AsyncStream<(FundingPayment, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.exchangeFunding.rawValue,
                  let funding = event.funding else { return nil }
            return (funding, event)
        }
    }

    /// Stream of closed candle events only (finalized candles).
    public func candleClosedEvents() -> AsyncStream<CandleEvent> {
        filteredStream { event in
            guard event.type == EventType.candleClosed.rawValue,
                  let coin = event.coin,
                  let intervalStr = event.interval,
                  let interval = CandleInterval(rawValue: intervalStr),
                  let candle = event.candle else { return nil }
            return CandleEvent(coin: coin, interval: interval, candle: candle)
        }
    }

    // MARK: - Typed Event Streams

    /// Stream of trading-related typed events (exchange state, fills, funding).
    /// Exhaustive switching on the result gives compile-time safety.
    public func typedExchangeEvents() -> AsyncStream<TypedEvent> {
        filteredStream { event in
            let typed = TypedEvent.from(event)
            switch typed {
            case .exchangeUpdated, .fillPreview, .fillRecorded, .fundingPayment:
                return typed
            default:
                return nil
            }
        }
    }

    /// Stream of typed fill events (both preview and recorded phases).
    public func typedFillEvents() -> AsyncStream<TypedEvent> {
        filteredStream { event in
            let typed = TypedEvent.from(event)
            switch typed {
            case .fillPreview, .fillRecorded:
                return typed
            default:
                return nil
            }
        }
    }

    /// Stream of typed funding payment events.
    public func typedFundingEvents() -> AsyncStream<TypedEvent> {
        filteredStream { event in
            let typed = TypedEvent.from(event)
            switch typed {
            case .fundingPayment:
                return typed
            default:
                return nil
            }
        }
    }

    // MARK: - Internal: Testing

    /// Inject a raw WebSocket message for testing. Not for production use.
    internal func injectMessage(_ text: String) {
        handleMessage(text)
    }

    // MARK: - Private: Connection

    private func doConnect() {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        var wsURL = baseURL
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        components.path += "/api/v1/ws"
        wsURL = components.url!

        setStatus(.connecting)
        log.debug("websocket", "connecting",
                  metadata: ["url": wsURL.absoluteString, "realmId": realmId])

        let task = session.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()

        if let getToken {
            Task { [weak self] in
                do {
                    let freshToken = try await getToken()
                    await self?.applyTokenAndAuth(freshToken)
                } catch {
                    await self?.logTokenRefreshFailedOnReconnect(error)
                    await self?.sendAuthWithCurrentToken()
                }
            }
        } else {
            sendMessage(.auth(token: token, realmId: realmId))
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func logTokenRefreshFailedOnReconnect(_ error: Error) {
        log.error("websocket", "token refresh failed on reconnect, falling back to cached token",
                  error: error)
    }

    private func applyTokenAndAuth(_ freshToken: String) {
        self.token = freshToken
        sendMessage(.auth(token: freshToken, realmId: realmId))
    }

    private func sendAuthWithCurrentToken() {
        sendMessage(.auth(token: token, realmId: realmId))
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    log.warning("websocket", "receive loop error", error: error)
                    setStatus(.disconnected)
                    if shouldReconnect {
                        scheduleReconnect()
                    }
                }
                return
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lastMessageAt = Date()
        let decoder = JSONDecoder()

        // Try to parse as a generic JSON dictionary first for snapshot handling
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let msgType = json["type"] as? String ?? ""

            if msgType == "pong" {
                return
            }

            if msgType == "authenticated" {
                log.info("websocket", "authenticated")
                reconnectAttempt = 0
                lastDeliverySeq = 0
                setStatus(.connected)
                startHeartbeat()
                // Re-subscribe mids
                if let mids = subscribedMids {
                    sendMessage(.subscribeMids(exchange: mids.exchange, coins: mids.coins))
                }
                if let candles = subscribedCandles {
                    sendMessage(.subscribeCandles(coins: candles.coins, intervals: candles.intervals.map(\.rawValue)))
                }
                if midsRefs > 0 && subscribedMids == nil {
                    sendMessage(.subscribeMids(exchange: midsExchange, coins: []))
                }
                if !candleRefCoins.isEmpty && subscribedCandles == nil {
                    syncCandleSubscription()
                }
                // Re-watch all paths from ref-counted state
                for path in pathRefs.keys {
                    sendMessage(.watch(path: path))
                }
                for (watchId, req) in chartHistoryWatches {
                    sendMessage(.watchChartHistory(watchId: watchId, target: req.target, kind: req.kind, objectId: req.objectId))
                }
                // Notify subscribers AFTER all subscriptions are re-issued so
                // any chart-history watch IDs they depend on are already
                // registered.
                for handler in authenticatedHandlers.values { handler() }
                for continuation in authenticatedContinuations.values {
                    continuation.yield(())
                }
                return
            }

            if msgType == "error" {
                let errorMessage = json["message"] as? String ?? "Unknown WebSocket error"
                log.error("websocket", "server error",
                          metadata: ["message": errorMessage])
                setStatus(.disconnected)
                webSocketTask?.cancel(with: .goingAway, reason: errorMessage.data(using: .utf8))
                webSocketTask = nil
                if shouldReconnect {
                    scheduleReconnect()
                }
                return
            }

            // Normalize mids.snapshot → mids.updated so midsEvents() receives
            // the initial price map (mirrors TypeScript SDK behavior).
            if msgType == "mids.snapshot",
               let midsRaw = json["mids"] as? [String: String] {
                let syntheticEvent = RealmEvent(type: EventType.midsUpdated.rawValue, mids: midsRaw)
                for continuation in eventContinuations.values {
                    continuation.yield(syntheticEvent)
                }
                return
            }

            // Normalize candles.updated (batched) → individual candle.updated
            // events so candleEvents() receives each candle separately.
            if msgType == "candles.updated",
               let items = json["candles"] as? [[String: Any]] {
                if let seq = json["deliverySeq"] as? Int {
                    checkDeliveryGap(seq)
                }
                for item in items {
                    guard let coin = item["coin"] as? String,
                          let interval = item["interval"] as? String,
                          let candleRaw = item["candle"],
                          let candleData = try? JSONSerialization.data(withJSONObject: candleRaw),
                          let candle = try? JSONDecoder().decode(Candle.self, from: candleData) else {
                        continue
                    }
                    let syntheticEvent = RealmEvent(
                        type: EventType.candleUpdated.rawValue,
                        coin: coin,
                        interval: interval,
                        candle: candle
                    )
                    for continuation in eventContinuations.values {
                        continuation.yield(syntheticEvent)
                    }
                }
                return
            }

            // Normalize watch_snapshot → object.valuation so objectValuationEvents()
            // receives the initial valuation (mirrors TypeScript SDK behavior where
            // watchPath resolves with the snapshot valuation as the first value).
            if msgType == "watch_snapshot",
               let watchIdStr = json["watchId"] as? String {
                // Single-object valuation
                if let valRaw = json["valuation"],
                   let pathStr = json["path"] as? String,
                   let valData = try? JSONSerialization.data(withJSONObject: valRaw),
                   let valuation = try? JSONDecoder().decode(ObjectValuation.self, from: valData) {
                    let syntheticEvent = RealmEvent(
                        type: EventType.objectValuation.rawValue,
                        valuation: valuation,
                        path: pathStr,
                        watchId: watchIdStr
                    )
                    for continuation in eventContinuations.values {
                        continuation.yield(syntheticEvent)
                    }
                }
                // Multi-object valuations map
                if let valsRaw = json["valuations"] as? [String: Any] {
                    for (objPath, valObj) in valsRaw {
                        if let valData = try? JSONSerialization.data(withJSONObject: valObj),
                           let valuation = try? JSONDecoder().decode(ObjectValuation.self, from: valData) {
                            let syntheticEvent = RealmEvent(
                                type: EventType.objectValuation.rawValue,
                                valuation: valuation,
                                path: objPath,
                                watchId: watchIdStr
                            )
                            for continuation in eventContinuations.values {
                                continuation.yield(syntheticEvent)
                            }
                        }
                    }
                }
            }

        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let seq = json["deliverySeq"] as? Int {
            checkDeliveryGap(seq)
        }

        if let event = try? decoder.decode(RealmEvent.self, from: data) {
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }

    // MARK: - Delivery gap detection

    private func checkDeliveryGap(_ seq: Int) {
        if lastDeliverySeq > 0 && seq > lastDeliverySeq + 1 {
            let missed = seq - lastDeliverySeq - 1
            log.warning("websocket", "delivery gap detected",
                        metadata: [
                            "missed": String(missed),
                            "previousSeq": String(lastDeliverySeq),
                            "currentSeq": String(seq),
                        ])
            for handler in gapHandlers.values {
                handler(missed)
            }
        }
        lastDeliverySeq = seq
    }

    /// Register a handler that fires when a delivery sequence gap is detected.
    /// The handler receives the number of missed events.
    /// Returns an ID that can be passed to ``removeGapHandler`` to unregister.
    @discardableResult
    public func onGap(_ handler: @escaping @Sendable (Int) -> Void) -> UUID {
        let id = UUID()
        gapHandlers[id] = handler
        return id
    }

    /// Remove a previously registered gap handler.
    public func removeGapHandler(_ id: UUID) {
        gapHandlers.removeValue(forKey: id)
    }

    /// Register a handler that fires when the host app returns from a
    /// backgrounded state (iOS / tvOS / visionOS:
    /// `UIApplication.willEnterForegroundNotification`; macOS:
    /// `NSApplication.willBecomeActiveNotification`) after at least
    /// `resumeHiddenThresholdS` seconds hidden. The handler receives the
    /// hidden duration. Watch streams use this to refresh historical data
    /// even when the WS stayed nominally connected through the freeze.
    /// Returns an ID that can be passed to ``removeResumeHandler`` to unregister.
    @discardableResult
    public func onResume(_ handler: @escaping @Sendable (TimeInterval) -> Void) -> UUID {
        let id = UUID()
        resumeHandlers[id] = handler
        return id
    }

    /// Remove a previously registered resume handler.
    public func removeResumeHandler(_ id: UUID) {
        resumeHandlers.removeValue(forKey: id)
    }

    /// Register a handler that fires on every successful WebSocket
    /// `authenticated` message. Includes the very first auth and every
    /// subsequent reconnect-and-auth. Watch streams use this to refresh
    /// on fresh auth instead of relying on observing a `disconnected ->
    /// connected` status transition (which can be missed if the WS
    /// reconnects faster than the disconnect callback fires).
    /// Returns an ID that can be passed to ``removeAuthenticatedHandler`` to unregister.
    @discardableResult
    public func onAuthenticated(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        authenticatedHandlers[id] = handler
        return id
    }

    /// Remove a previously registered authenticated handler.
    public func removeAuthenticatedHandler(_ id: UUID) {
        authenticatedHandlers.removeValue(forKey: id)
    }

    /// A stream of resume events. Each emission carries the hidden
    /// duration in seconds. Mirrors ``onResume`` for SwiftUI / structured-
    /// concurrency consumers.
    public var resumeStream: AsyncStream<TimeInterval> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeResumeContinuation(id: id)
                }
            }
            self.resumeContinuations[id] = continuation
        }
    }

    /// A stream that emits whenever the WebSocket completes authentication.
    /// Mirrors ``onAuthenticated`` for SwiftUI / structured-concurrency consumers.
    public var authenticatedStream: AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeAuthenticatedContinuation(id: id)
                }
            }
            self.authenticatedContinuations[id] = continuation
        }
    }

    private func removeResumeContinuation(id: UUID) {
        resumeContinuations.removeValue(forKey: id)
    }

    private func removeAuthenticatedContinuation(id: UUID) {
        authenticatedContinuations.removeValue(forKey: id)
    }

    // MARK: - App Lifecycle Observation

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default

        let foregroundHandler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { [weak self] in await self?.handleAppWillEnterForeground() }
        }
        let backgroundHandler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { [weak self] in await self?.handleAppDidEnterBackground() }
        }

        #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil,
            using: foregroundHandler
        )
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil,
            using: backgroundHandler
        )
        lifecycleObservers = [foreground, background]
        #elseif canImport(AppKit) && os(macOS)
        let active = center.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: nil,
            using: foregroundHandler
        )
        let inactive = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil,
            using: backgroundHandler
        )
        lifecycleObservers = [active, inactive]
        #else
        // Linux / server-side Swift: no native foreground/background signal.
        _ = foregroundHandler; _ = backgroundHandler
        #endif
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        for observer in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    private func handleAppDidEnterBackground() {
        hiddenAt = Date()
    }

    private func handleAppWillEnterForeground() {
        guard let hiddenAt = hiddenAt else { return }
        self.hiddenAt = nil
        let hiddenDuration = Date().timeIntervalSince(hiddenAt)
        guard hiddenDuration >= WebSocketManager.resumeHiddenThresholdS else { return }
        fireResume(hiddenDuration: hiddenDuration)
        probeStaleConnection()
    }

    /// Internal: invoked when the host app foregrounds after a hidden
    /// period beyond the threshold. Exposed for tests to drive without
    /// requiring `NotificationCenter`.
    public func triggerResume(hiddenDuration: TimeInterval) {
        fireResume(hiddenDuration: hiddenDuration)
        probeStaleConnection()
    }

    private func fireResume(hiddenDuration: TimeInterval) {
        for handler in resumeHandlers.values { handler(hiddenDuration) }
        for continuation in resumeContinuations.values {
            continuation.yield(hiddenDuration)
        }
    }

    private func probeStaleConnection() {
        resumeProbeTask?.cancel()
        guard webSocketTask != nil, _status == .connected else { return }
        let baselineMessageAt = lastMessageAt
        sendMessage(.ping)
        resumeProbeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: WebSocketManager.resumePingTimeoutNs)
            guard !Task.isCancelled else { return }
            await self?.checkResumeProbe(baselineMessageAt: baselineMessageAt)
        }
    }

    private func checkResumeProbe(baselineMessageAt: Date) {
        resumeProbeTask = nil
        guard lastMessageAt == baselineMessageAt else { return } // any inbound message means alive
        log.warning("websocket", "resume probe timeout, forcing reconnect")
        stopHeartbeat()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        setStatus(.disconnected)
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    // MARK: - Private: Reconnection

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1
        log.warning("websocket", "scheduling reconnect",
                    metadata: [
                        "attempt": String(reconnectAttempt),
                        "delaySeconds": String(format: "%.1f", delay),
                    ])

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performReconnect()
        }
    }

    private func performReconnect() {
        reconnectTask = nil
        doConnect()
    }

    // MARK: - Private: Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        lastMessageAt = Date()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: WebSocketManager.pingIntervalNs)
                guard !Task.isCancelled else { return }
                await self?.heartbeatTick()
            }
        }
    }

    private func stopHeartbeat() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func heartbeatTick() {
        let elapsed = Date().timeIntervalSince(lastMessageAt)
        if elapsed >= WebSocketManager.staleThresholdS {
            log.warning("websocket", "connection stale, forcing reconnect",
                        metadata: [
                            "elapsedSeconds": String(format: "%.1f", elapsed),
                            "thresholdSeconds": String(format: "%.1f", WebSocketManager.staleThresholdS),
                        ])
            stopHeartbeat()
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            receiveTask?.cancel()
            receiveTask = nil
            setStatus(.disconnected)
            if shouldReconnect {
                scheduleReconnect()
            }
            return
        }
        sendMessage(.ping)
    }

    // MARK: - Private: Messaging

    private func sendMessage(_ message: OutboundMessage) {
        guard let task = webSocketTask else { return }
        do {
            let data = try JSONEncoder().encode(message)
            if let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { [log] err in
                    if let err = err {
                        log.warning("websocket", "message send failed", error: err)
                    }
                }
            }
        } catch {
            log.error("websocket", "outbound message encode failed", error: error)
        }
    }

    // MARK: - Private: Status

    private func setStatus(_ newStatus: ConnectionStatus) {
        guard newStatus != _status else { return }
        log.debug("websocket", "status",
                  metadata: ["from": String(describing: _status), "to": String(describing: newStatus)])
        _status = newStatus
        for continuation in statusContinuations.values {
            continuation.yield(newStatus)
        }
    }

    // MARK: - Private: Cleanup

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func removeStatusContinuation(id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    // MARK: - Private: Filtered Streams

    private func filteredStream<T>(
        transform: @Sendable @escaping (RealmEvent) -> T?
    ) -> AsyncStream<T> {
        let parentEvents = self.events
        return AsyncStream { continuation in
            let task = Task {
                for await event in parentEvents {
                    if let value = transform(event) {
                        continuation.yield(value)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
