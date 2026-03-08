import Foundation

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

    private var subscribedChannels: Set<String> = []
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

    public init(
        baseURL: URL,
        token: String,
        realmId: String,
        maxReconnectDelay: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.token = token
        self.realmId = realmId
        self.maxReconnectDelay = maxReconnectDelay
        self.session = URLSession(configuration: .default)
    }

    /// Update the bearer token (e.g., after refresh). Takes effect on next reconnect.
    public func updateToken(_ newToken: String) {
        self.token = newToken
    }

    /// Current connection status.
    public var status: ConnectionStatus { _status }

    // MARK: - Connection Lifecycle

    /// Connect to the WebSocket and subscribe to the given channels.
    public func connect(channels: [Channel] = []) {
        shouldReconnect = true
        for ch in channels {
            subscribedChannels.insert(ch.rawValue)
        }
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
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        setStatus(.disconnected)
    }

    // MARK: - Channel Subscriptions

    /// Subscribe to additional channels.
    public func subscribe(channels: [Channel]) {
        for ch in channels { subscribedChannels.insert(ch.rawValue) }
        sendMessage(.subscribe(channels: channels.map(\.rawValue)))
    }

    /// Unsubscribe from channels.
    public func unsubscribe(channels: [Channel]) {
        for ch in channels { subscribedChannels.remove(ch.rawValue) }
        sendMessage(.unsubscribe(channels: channels.map(\.rawValue)))
    }

    /// Subscribe to real-time mid price updates.
    /// Pass an empty `coins` array (the default) to subscribe to all assets.
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

    /// Stream of exchange fill events (fill data + originating event).
    public func fillEvents() -> AsyncStream<(SimFill, RealmEvent)> {
        filteredStream { event in
            guard event.type == EventType.exchangeFill.rawValue,
                  let fill = event.fill else { return nil }
            return (fill, event)
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

        let task = session.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()

        sendMessage(.auth(token: token, realmId: realmId))

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
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
        let decoder = JSONDecoder()

        if let control = try? decoder.decode(InboundControlMessage.self, from: data) {
            if control.type == "authenticated" {
                reconnectAttempt = 0
                setStatus(.connected)
                if !subscribedChannels.isEmpty {
                    sendMessage(.subscribe(channels: Array(subscribedChannels)))
                }
                if let mids = subscribedMids {
                    sendMessage(.subscribeMids(exchange: mids.exchange, coins: mids.coins))
                }
                if let candles = subscribedCandles {
                    sendMessage(.subscribeCandles(coins: candles.coins, intervals: candles.intervals.map(\.rawValue)))
                }
                return
            }
            if control.type == "error" {
                return
            }
        }

        if let event = try? decoder.decode(RealmEvent.self, from: data) {
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }

    // MARK: - Private: Reconnection

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1

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

    // MARK: - Private: Messaging

    private func sendMessage(_ message: OutboundMessage) {
        guard let task = webSocketTask else { return }
        do {
            let data = try JSONEncoder().encode(message)
            if let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { _ in }
            }
        } catch {
            // Encoding failures are programming errors; silently dropped
        }
    }

    // MARK: - Private: Status

    private func setStatus(_ newStatus: ConnectionStatus) {
        guard newStatus != _status else { return }
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
