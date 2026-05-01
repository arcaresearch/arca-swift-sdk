import Foundation

// MARK: - TWAP Methods

extension Arca {

    /// Start a TWAP (Time-Weighted Average Price) order that executes a total size
    /// over a duration by placing market orders at regular intervals.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key).
    ///   - exchangeId: Exchange Arca object ID.
    ///   - coin: Canonical coin identifier (e.g. `"hl:BTC"`).
    ///   - side: `"BUY"` or `"SELL"`.
    ///   - totalSize: Total size to execute over the duration.
    ///   - durationMinutes: Duration in minutes (1 to 43200).
    ///   - intervalSeconds: Interval between slices in seconds (10 to 3600, default 30).
    ///   - randomize: Add timing jitter to slice placement.
    ///   - reduceOnly: Reduce-only mode.
    ///   - leverage: Leverage multiplier.
    ///   - slippageBps: Max slippage in basis points (10 to 1000, default 300).
    public func placeTwap(
        path: String,
        exchangeId: String,
        coin: String,
        side: OrderSide,
        totalSize: String,
        durationMinutes: Int,
        intervalSeconds: Int? = nil,
        randomize: Bool = false,
        reduceOnly: Bool = false,
        leverage: Int? = nil,
        slippageBps: Int? = nil
    ) -> OperationHandle<TwapOperationResponse> {
        operationHandle { [self] in
            try await client.post("/objects/\(exchangeId)/exchange/twap", body: PlaceTwapRequest(
                realmId: realm,
                path: path,
                coin: coin,
                side: side.rawValue,
                totalSize: totalSize,
                durationMinutes: durationMinutes,
                intervalSeconds: intervalSeconds,
                randomize: randomize,
                reduceOnly: reduceOnly,
                leverage: leverage,
                slippageBps: slippageBps
            ))
        }
    }

    /// Cancel an active TWAP.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - operationId: The parent operation ID of the TWAP.
    public func cancelTwap(
        exchangeId: String,
        operationId: String
    ) -> OperationHandle<TwapOperationResponse> {
        operationHandle { [self] in
            try await client.delete(
                "/objects/\(exchangeId)/exchange/twap/\(operationId)",
                query: ["realmId": realm]
            )
        }
    }

    /// Get TWAP status and progress by its parent operation ID.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - operationId: The parent operation ID of the TWAP.
    public func getTwap(exchangeId: String, operationId: String) async throws -> TwapOperationResponse {
        try await client.get(
            "/objects/\(exchangeId)/exchange/twap/\(operationId)",
            query: ["realmId": realm]
        )
    }

    /// List TWAPs for an exchange object.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - activeOnly: If true, only returns active TWAPs.
    public func listTwaps(exchangeId: String, activeOnly: Bool = false) async throws -> [Twap] {
        var query = ["realmId": realm]
        if activeOnly { query["active"] = "true" }
        return try await client.get(
            "/objects/\(exchangeId)/exchange/twaps",
            query: query
        )
    }

    /// Get TWAP limits + recommendation curve from the server. The
    /// response is static for the process lifetime; the SDK caches it
    /// after the first call so bumping limits is a server-side change
    /// only.
    ///
    /// Use `getTwapLimits().recommendation.buckets` directly for
    /// custom pickers, or call ``recommendedIntervalSeconds(for:)`` for
    /// the one-shot helper.
    ///
    /// ```swift
    /// let response = try await arca.getTwapLimits()
    /// guard duration <= response.limits.maxDurationMinutes else {
    ///     throw ValidationError.tooLong
    /// }
    /// ```
    public func getTwapLimits() async throws -> TwapLimits {
        if let cached = await TwapLimitsCache.shared.value() {
            return cached
        }
        let response: TwapLimits = try await client.get("/twap/limits")
        await TwapLimitsCache.shared.set(response)
        return response
    }

    /// Returns the recommended `intervalSeconds` for a given TWAP
    /// duration, picked from the server's recommendation curve. Use
    /// this to populate a default in your TWAP entry UI so retail-sized
    /// 1h TWAPs aren't sliced into 120 30-second orders.
    ///
    /// ```swift
    /// let interval = try await arca.recommendedIntervalSeconds(for: 60) // 300 (5m)
    /// ```
    public func recommendedIntervalSeconds(for durationMinutes: Int) async throws -> Int {
        let response = try await getTwapLimits()
        for bucket in response.recommendation.buckets {
            if durationMinutes <= bucket.maxDurationMinutes {
                return bucket.recommendedIntervalSeconds
            }
        }
        return response.limits.defaultIntervalSeconds
    }

    /// Watch a single TWAP by its parent operation ID. The returned
    /// `AsyncStream` emits the latest server-side ``Twap`` snapshot on
    /// every TWAP event targeting this operation
    /// (`twap.started`, `twap.progress`, `twap.completed`,
    /// `twap.cancelled`, `twap.failed`).
    ///
    /// The first element is the result of an eager REST fetch so the
    /// caller can render initial state without waiting for an event.
    /// Subsequent elements are pushed by the WebSocket. The stream
    /// terminates when the caller cancels the underlying `Task` or
    /// when the WebSocket is closed.
    ///
    /// ```swift
    /// for await twap in arca.watchTwap(exchangeId: exchangeId, operationId: opId) {
    ///     print("\(twap.sliceCount)/\(twap.expectedSliceCount) — \(twap.status)")
    ///     if twap.status != .active { break }
    /// }
    /// ```
    public func watchTwap(exchangeId: String, operationId: String) -> AsyncStream<Twap> {
        AsyncStream { continuation in
            let initialTask = Task { [self] in
                if let initial = try? await getTwap(exchangeId: exchangeId, operationId: operationId).twap {
                    continuation.yield(initial)
                }
            }
            let liveTask = Task { [ws] in
                for await event in await ws.twapEvents() {
                    switch event {
                    case .twapStarted(let twap, _),
                         .twapProgress(let twap, _),
                         .twapCompleted(let twap, _),
                         .twapCancelled(let twap, _),
                         .twapFailed(let twap, _):
                        if twap.operationId == operationId {
                            continuation.yield(twap)
                        }
                    default:
                        continue
                    }
                }
            }
            continuation.onTermination = { _ in
                initialTask.cancel()
                liveTask.cancel()
            }
        }
    }
}

/// Process-lifetime cache for the ``TwapLimits`` response.
/// Wrapped in an actor so concurrent ``Arca/getTwapLimits()`` calls
/// from different tasks share a single in-flight network request.
private actor TwapLimitsCache {
    static let shared = TwapLimitsCache()
    private var cached: TwapLimits?

    func value() -> TwapLimits? { cached }
    func set(_ value: TwapLimits) { cached = value }
}

// MARK: - Private Request Types

private struct PlaceTwapRequest: Encodable {
    let realmId: String
    let path: String
    let coin: String
    let side: String
    let totalSize: String
    let durationMinutes: Int
    let intervalSeconds: Int?
    let randomize: Bool
    let reduceOnly: Bool
    let leverage: Int?
    let slippageBps: Int?
}
