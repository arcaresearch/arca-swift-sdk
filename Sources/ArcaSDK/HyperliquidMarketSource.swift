import Foundation

/// Public-only connection: no Arca bearer token, authenticated session, or cookies.
actor HyperliquidMarketSource: PublicMarketSource {
    private let url: URL
    private let receive: @Sendable (UInt64, PublicMarketUpdate) async -> Void
    private let session: URLSession
    private var desired: Set<PublicMarketSubscription> = []
    private var sent: Set<PublicMarketSubscription> = []
    private var socket: URLSessionWebSocketTask?
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var closed = false
    private var attempt = 0
    private var openedAt = 0.0
    private var lastReceivedAt = 0.0
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var changes: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(url: URL, receive: @escaping @Sendable (UInt64, PublicMarketUpdate) async -> Void) {
        self.url = url; self.receive = receive
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) {
        guard !closed, revision >= self.revision else { return }
        self.revision = revision
        guard subscriptions != desired else { return }
        desired = subscriptions
        if desired.isEmpty { stopSocket(); retry?.cancel(); retry = nil; return }
        if socket == nil && retry == nil { connect() }
        sync()
    }
    private func connect() {
        generation += 1
        let epoch = generation
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 262_144
        socket = task; sent = []
        openedAt = ProcessInfo.processInfo.systemUptime; lastReceivedAt = openedAt
        task.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard !Task.isCancelled else { return }
                    await self?.message(message, epoch: epoch)
                }
            } catch { await self?.fail(epoch: epoch, reason: "Hyperliquid connection failed") }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                await self?.ping(epoch: epoch)
            }
        }
        sync()
    }
    private func message(_ message: URLSessionWebSocketTask.Message, epoch: UInt64) async {
        guard !closed, epoch == generation else { return }
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
        let data: Data
        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: return }
        await receive(epoch, .traffic(bytes: data.count))
        guard data.count <= 262_144 else { await fail(epoch: epoch, reason: "Hyperliquid frame exceeded size budget"); return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if json["channel"] as? String == "error" { await fail(epoch: epoch, reason: "Hyperliquid subscription rejected"); return }
        if let update = decodePublicMarketUpdate(json, subscriptions: sent) { await receive(epoch, update) }
    }
    private func ping(epoch: UInt64) async {
        guard epoch == generation, let socket else { return }
        if ProcessInfo.processInfo.systemUptime - lastReceivedAt > 45 {
            await fail(epoch: epoch, reason: "Hyperliquid heartbeat timed out"); return
        }
        do { try await socket.send(.string("{\"method\":\"ping\"}")) }
        catch { await fail(epoch: epoch, reason: "Hyperliquid heartbeat failed") }
    }
    private func sync() {
        guard changes == nil, socket != nil else { return }
        let epoch = generation
        changes = Task { [weak self] in await self?.sendChanges(epoch: epoch) }
    }
    private func sendChanges(epoch: UInt64) async {
        while !Task.isCancelled, epoch == generation, let socket {
            let remove = sent.subtracting(desired).first
            guard let sub = remove ?? desired.subtracting(sent).first else { changes = nil; return }
            var subscription = ["type": sub.interval == nil ? "bbo" : "candle", "coin": sub.coin]
            if let interval = sub.interval { subscription["interval"] = interval.rawValue }
            let json: [String: Any] = ["method": remove == nil ? "subscribe" : "unsubscribe", "subscription": subscription]
            guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { return }
            // Register before suspension so an immediate snapshot can be decoded.
            if remove == nil { sent.insert(sub) } else { sent.remove(sub) }
            do {
                try await socket.send(.string(text))
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                if !Task.isCancelled { await fail(epoch: epoch, reason: "Hyperliquid subscription send failed") }
                return
            }
        }
    }
    private func fail(epoch: UInt64, reason: String) async {
        guard !closed, epoch == generation else { return }
        if ProcessInfo.processInfo.systemUptime - openedAt >= 60 { attempt = 0 }
        stopSocket()
        let failedGeneration = generation
        if !desired.isEmpty {
            let delay = min(60, 2 << min(attempt, 5))
            attempt = min(attempt + 1, 6)
            retry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000 + UInt64.random(in: 0..<500_000_000)) } catch { return }
                await self?.reconnect()
            }
        }
        await receive(failedGeneration, .unavailable(reason))
    }
    private func reconnect() { retry = nil; if !closed && !desired.isEmpty { connect() } }
    private func stopSocket() {
        generation += 1
        reader?.cancel(); reader = nil; heartbeat?.cancel(); heartbeat = nil; changes?.cancel(); changes = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; sent = []
    }
    func close() {
        closed = true; desired = []; stopSocket(); retry?.cancel(); retry = nil
        session.invalidateAndCancel()
    }
}

private func marketDecimal(_ value: Any?) -> Decimal? {
    guard let text = value as? String, text.count <= 48,
          text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
          let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
    return number
}

/// Decode only exact subscriptions; HL candle `s` is a symbol, not Arca provenance.
func decodePublicMarketUpdate(_ json: [String: Any], subscriptions: Set<PublicMarketSubscription>) -> PublicMarketUpdate? {
    guard let channel = json["channel"] as? String, let data = json["data"] as? [String: Any] else { return nil }
    if channel == "bbo" {
        guard let coin = data["coin"] as? String,
              let sub = subscriptions.first(where: { $0.coin == coin && $0.interval == nil }),
              let levels = data["bbo"] as? [[String: Any]], levels.count == 2,
              let bid = marketDecimal(levels[0]["px"]), let ask = marketDecimal(levels[1]["px"]), bid > 0, ask >= bid,
              let time = data["time"] as? Int else { return nil }
        var midpoint = (bid + ask) / 2
        guard !midpoint.isNaN else { return nil }
        return .quote(market: sub.market, price: NSDecimalString(&midpoint, Locale(identifier: "en_US_POSIX")), timeMs: time)
    }
    if channel == "candle" {
        guard let coin = data["s"] as? String, let raw = data["i"] as? String, let interval = CandleInterval(rawValue: raw),
              let sub = subscriptions.first(where: { $0.coin == coin && $0.interval == interval }),
              let o = marketDecimal(data["o"]), let h = marketDecimal(data["h"]), let l = marketDecimal(data["l"]),
              let c = marketDecimal(data["c"]), let v = marketDecimal(data["v"]),
              min(o, h, l, c) > 0, v >= 0, h >= max(o, l, c), l <= min(o, h, c),
              let bytes = try? JSONSerialization.data(withJSONObject: data.filter { ["t", "o", "h", "l", "c", "v", "n"].contains($0.key) }),
              let candle = try? JSONDecoder().decode(Candle.self, from: bytes), candle.n >= 0 else { return nil }
        return .bar(market: sub.market, interval: interval, candle: candle)
    }
    return nil
}
