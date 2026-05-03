import Foundation

// `watchEquityChart` / `watchPnlChart` treat a watch as a "live tail" when
// the requested `to` is within this distance of construction time, and
// slide the window forward on every refresh. Watches with `to` further in
// the past are treated as fixed-window watches and stay pinned.
internal let LIVE_TAIL_THRESHOLD_S: TimeInterval = 60

// In the chart streams' boundary timer: if no aggregation event has arrived
// for this much wall-clock time AND the bucket boundary has advanced, treat
// it as a tab freeze / quiet realm and refetch the dense server window.
// 1.5 x interval gives one grace bucket for ordinary network jitter before
// we suspect the stream.
internal let BOUNDARY_AGG_SILENCE_FACTOR: Double = 1.5

// Helper: format a `Date` to RFC 3339 with fractional seconds. Each call
// constructs a fresh formatter because `ISO8601DateFormatter` is non-Sendable.
@inline(__always)
internal func iso8601String(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

/// Range presets accepted by `Arca.watchEquityChartLive` /
/// `watchPnlChartLive` and by `Arca.computeChartRange`. Mirror of the
/// TypeScript `ChartRangePreset`.
public enum ChartRangePreset: String, Sendable {
    case oneHour = "1h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case threeMonths = "3m"
    case oneYear = "1y"
    case ytd = "ytd"
    case all = "all"
}

// chartResolutionSeconds maps a server-side resolution string (the same set
// returned by /history's `resolution` field) to the seconds-per-bucket the
// chart streams use to detect bucket-boundary crossings. The branches must
// stay in sync with the server-side ladder in
// backend/services/aggregation/internal/ladder/ladder.go and its TS mirror.
// Unknown strings fall back to 1h, which is conservative: a slightly-too-big
// boundary just means a delayed historical-tail append, not a data error.
private func chartResolutionSeconds(_ resolution: String?) -> Int64 {
    switch resolution {
    case "1m": return 60
    case "5m": return 300
    case "15m": return 900
    case "30m": return 1_800
    case "1h", "hour": return 3_600
    case "4h": return 14_400
    case "1d", "day": return 86_400
    default: return 3_600
    }
}

private struct V2HistoryPoint: Codable, Sendable {
    let ts: String
    let equityUsd: String
    let status: ChartPointStatus?
    let cumInflowsUsd: String?
    let cumOutflowsUsd: String?
    let lastEventOpId: String?
    let midSetId: String?
}

private struct V2HistoryResponse: Codable, Sendable {
    let resolution: String?
    let resolutionRequested: String?
    let serverNow: String?
    let points: [V2HistoryPoint]?
}

private struct V2PnlHistoryPoint: Codable, Sendable {
    let ts: String
    let pnlUsd: String
    let equityUsd: String
    let status: ChartPointStatus?
    let cumInflowsUsd: String?
    let cumOutflowsUsd: String?
    let lastEventOpId: String?
    let midSetId: String?
    let valueUsd: String?
}

private struct V2PnlHistoryResponse: Codable, Sendable {
    let resolution: String?
    let resolutionRequested: String?
    let serverNow: String?
    let startEquityUsd: String?
    let startingEquityUsd: String?
    let effectiveFrom: String?
    let externalFlows: [ExternalFlowEntry]?
    let midPrices: [String: String]?
    let points: [V2PnlHistoryPoint]?
}

// MARK: - Aggregation, P&L, Equity History

extension Arca {

    /// Get the valuation for a single Arca object.
    /// Uses the same computation path as aggregation (Axiom 10: Observational Consistency).
    ///
    /// - Parameter path: Path of the Arca object
    public func getObjectValuation(path: String) async throws -> ObjectValuation {
        try await client.get("/objects/valuation", query: ["realmId": realm, "path": path])
    }

    /// Get aggregated valuation for objects at a path.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): returns valuation for a single object.
    ///     Path prefix (trailing slash): returns aggregated valuation for all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - asOf: Optional timestamp for historical aggregation
    public func getPathAggregation(path: String, asOf: String? = nil) async throws -> PathAggregation {
        try validatePath(path)
        var query: [String: String] = ["realmId": realm, "prefix": path]
        if let asOf = asOf { query["asOf"] = asOf }
        return try await client.get("/objects/aggregate", query: query)
    }

    /// Get P&L for objects at a path over a time range.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): returns P&L for a single object.
    ///     Path prefix (trailing slash): returns aggregated P&L for all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    public func getPnl(path: String, from: String, to: String) async throws -> PnlResponse {
        try validatePath(path)
        return try await client.get("/objects/pnl", query: [
            "realmId": realm,
            "prefix": path,
            "from": from,
            "to": to,
        ])
    }

    /// Get P&L history (time-series) for objects at a path.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): returns P&L history for a single object.
    ///     Path prefix (trailing slash): returns aggregated P&L history for all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of samples (default 1000, max 1000). The backend ladder
    ///     picks the finest resolution whose bucket count fits within `points`,
    ///     so a higher value gives finer-grained charts. The default targets
    ///     `5m` for 24h, `1h` for 1M, and `4h` for 3M.
    public func getPnlHistory(
        path: String,
        from: String,
        to: String,
        points: Int = 1000
    ) async throws -> PnlHistoryResponse {
        try validatePath(path)
        let key = buildCacheKey("pnlHistory", [
            "target": path, "kind": "path", "from": from, "to": to, "points": String(points),
        ])
        if let cached: PnlHistoryResponse = historyCache.get(key) {
            return cached
        }
        let result: V2PnlHistoryResponse = try await client.get("/objects/pnl/history", query: [
            "realmId": realm,
            "target": path,
            "kind": "path",
            "from": from,
            "to": to,
            "points": String(points),
        ])
        let normalized = PnlHistoryResponse(
            prefix: path,
            from: from,
            to: to,
            points: result.points?.count ?? 0,
            resolution: result.resolution,
            resolutionRequested: result.resolutionRequested,
            serverNow: result.serverNow,
            startingEquityUsd: result.startEquityUsd ?? result.startingEquityUsd ?? "0",
            effectiveFrom: result.effectiveFrom,
            pnlPoints: result.points?.map {
                PnlPoint(
                    timestamp: $0.ts,
                    pnlUsd: $0.pnlUsd,
                    equityUsd: $0.equityUsd,
                    status: $0.status,
                    cumInflowsUsd: $0.cumInflowsUsd,
                    cumOutflowsUsd: $0.cumOutflowsUsd,
                    lastEventOpId: $0.lastEventOpId,
                    midSetId: $0.midSetId,
                    valueUsd: $0.valueUsd
                )
            } ?? [],
            externalFlows: result.externalFlows ?? [],
            midPrices: result.midPrices ?? [:]
        )
        historyCache.set(key, value: normalized)
        return normalized
    }

    /// Get equity history (time-series) for objects at a path.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): returns equity history for a single object.
    ///     Path prefix (trailing slash): returns aggregated equity history for all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of samples (default 1000, max 1000). The backend ladder
    ///     picks the finest resolution whose bucket count fits within `points`,
    ///     so a higher value gives finer-grained charts. The default targets
    ///     `5m` for 24h, `1h` for 1M, and `4h` for 3M.
    public func getEquityHistory(
        path: String,
        from: String,
        to: String,
        points: Int = 1000
    ) async throws -> EquityHistoryResponse {
        try validatePath(path)
        let key = buildCacheKey("equityHistory", [
            "target": path, "kind": "path", "from": from, "to": to, "points": String(points),
        ])
        if let cached: EquityHistoryResponse = historyCache.get(key) {
            return cached
        }
        let result: V2HistoryResponse = try await client.get("/objects/aggregate/history", query: [
            "realmId": realm,
            "target": path,
            "kind": "path",
            "from": from,
            "to": to,
            "points": String(points),
        ])
        let normalized = EquityHistoryResponse(
            prefix: path,
            from: from,
            to: to,
            points: result.points?.count ?? 0,
            resolution: result.resolution,
            resolutionRequested: result.resolutionRequested,
            serverNow: result.serverNow,
            equityPoints: result.points?.map {
                EquityPoint(
                    timestamp: $0.ts,
                    equityUsd: $0.equityUsd,
                    status: $0.status,
                    cumInflowsUsd: $0.cumInflowsUsd,
                    cumOutflowsUsd: $0.cumOutflowsUsd,
                    lastEventOpId: $0.lastEventOpId,
                    midSetId: $0.midSetId
                )
            } ?? []
        )
        historyCache.set(key, value: normalized)
        return normalized
    }

    /// Create a live equity chart that merges historical data with real-time
    /// aggregation updates. The last point reflects the current live equity;
    /// when the hour boundary crosses, the live point is promoted to historical
    /// and a new live point starts.
    ///
    /// The stream buffers the latest value and drops intermediate updates if the consumer
    /// is slow. Updates are also dropped if the live point hasn't materially changed.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): chart for a single object.
    ///     Path prefix (trailing slash): chart aggregated across all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 1000, max 1000). Higher
    ///     values yield finer chart resolution from the server's ladder.
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchEquityChart(
        path: String,
        from: String,
        to: String,
        points: Int = 1000,
        exchange: String = "sim"
    ) async throws -> EquityChartStream {
        try validatePath(path)
        // Live-tail heuristic: if `to` was within ~60s of construction time,
        // the caller wants a "last N hours up to now" sliding window. On
        // every refresh, recompute `from`/`to` so the window stays current.
        // Otherwise the watch is fixed-window — keep `from`/`to` pinned.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdAt = Date()
        let fromDateOrig = iso.date(from: from)
        let toDateOrig = iso.date(from: to)
        let isLiveTail: Bool = {
            guard let f = fromDateOrig, let t = toDateOrig else { return false }
            _ = f
            return abs(t.timeIntervalSince(createdAt)) <= LIVE_TAIL_THRESHOLD_S
        }()
        let windowSeconds: TimeInterval = isLiveTail
            ? max(0, (toDateOrig?.timeIntervalSince1970 ?? 0) - (fromDateOrig?.timeIntervalSince1970 ?? 0))
            : 0
        let windowBox = SendableBox<(from: String, to: String)>((from, to))
        let slideIfLive: @Sendable () -> Void = {
            guard isLiveTail else { return }
            let now = Date()
            let newFrom = iso8601String(from: now.addingTimeInterval(-windowSeconds))
            let newTo = iso8601String(from: now)
            windowBox.update { $0 = (newFrom, newTo) }
        }

        var history: EquityHistoryResponse
        do {
            let w = windowBox.value
            history = try await getEquityHistory(path: path, from: w.from, to: w.to, points: points)
        } catch {
            history = EquityHistoryResponse(prefix: path, from: from, to: to, points: 0, equityPoints: [])
        }
        let aggStream = try await watchAggregation(
            sources: [AggregationSource(type: .prefix, value: path)],
            exchange: exchange
        )

        // If live equity is non-zero but cached history is all zeros (new
        // account after deposit), drop the stale cache and refetch.
        if let liveAgg = aggStream.aggregation.value,
           let live = Double(liveAgg.totalEquityUsd), live > 0.01 {
            let allZero = history.equityPoints.isEmpty ||
                history.equityPoints.allSatisfy { abs(Double($0.equityUsd) ?? 0) < 0.01 }
            if allZero {
                let w = windowBox.value
                let key = buildCacheKey("equityHistory", [
                    "target": path, "kind": "path", "from": w.from, "to": w.to, "points": String(points),
                ])
                historyCache.delete(key)
                if let fresh = try? await getEquityHistory(path: path, from: w.from, to: w.to, points: points) {
                    history = fresh
                }
            }
        }

        let resolutionSecondsBox = SendableBox<Int64>(chartResolutionSeconds(history.resolution))
        let initialHourBoundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value

        var trimmedHistorical = history.equityPoints
        while let last = trimmedHistorical.last,
              let ts = iso.date(from: last.timestamp),
              Int64(ts.timeIntervalSince1970) > initialHourBoundary {
            trimmedHistorical.removeLast()
        }

        var initialChart = trimmedHistorical
        if let agg = aggStream.aggregation.value {
            initialChart.append(EquityPoint(
                timestamp: iso.string(from: Date()),
                equityUsd: agg.totalEquityUsd
            ))
        }

        let state = SendableBox<WatchStreamState>(.connected)
        let historicalBox = SendableBox<[EquityPoint]>(trimmedHistorical)
        let chartBox = SendableBox<[EquityPoint]>(initialChart)
        let hourBoundaryBox = SendableBox<Int64>(initialHourBoundary)
        let liveEquityBox = SendableBox<String?>(aggStream.aggregation.value?.totalEquityUsd)
        let lastAggAtBox = SendableBox<Date>(Date())
        let chartWatchId = await ws.watchChartHistory(target: path)
        let gapId = await ws.onGap { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                slideIfLive()
                let w = windowBox.value
                let key = buildCacheKey("equityHistory", [
                    "target": path, "kind": "path", "from": w.from, "to": w.to, "points": String(points),
                ])
                self.historyCache.delete(key)
                if let fresh = try? await self.getEquityHistory(path: path, from: w.from, to: w.to, points: points) {
                    resolutionSecondsBox.update { $0 = chartResolutionSeconds(fresh.resolution) }
                    let boundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value
                    hourBoundaryBox.update { $0 = boundary }
                    historicalBox.update { pts in
                        pts = fresh.equityPoints.filter { $0.status != .open }
                    }
                }
            }
        }

        let updates = AsyncStream(EquityChartUpdate.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Refetches historical equity from the server and re-yields the
            // chart with the freshly-fetched points + the current live tip.
            // Shared by every recovery trigger: chart_snapshot push, WS
            // reconnect, app foreground (`onResume`), every successful auth
            // (`onAuthenticated`), wall-clock boundary timer for quiet realms,
            // and multi-bucket gaps detected on the agg-tick path.
            // ISO8601DateFormatter is non-Sendable so we construct a fresh
            // instance per call rather than capturing the outer `iso`.
            let refreshHistory: @Sendable () async -> Void = { [weak self] in
                guard let self = self else { return }
                slideIfLive()
                let w = windowBox.value
                let key = buildCacheKey("equityHistory", [
                    "target": path, "kind": "path", "from": w.from, "to": w.to, "points": String(points),
                ])
                self.historyCache.delete(key)
                guard let fresh = try? await self.getEquityHistory(path: path, from: w.from, to: w.to, points: points) else { return }
                resolutionSecondsBox.update { $0 = chartResolutionSeconds(fresh.resolution) }
                let boundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value
                hourBoundaryBox.update { $0 = boundary }
                let filtered = fresh.equityPoints.filter { $0.status != .open }
                historicalBox.update { $0 = filtered }
                var allPoints = filtered
                if let agg = aggStream.aggregation.value {
                    liveEquityBox.update { $0 = agg.totalEquityUsd }
                    let localIso = ISO8601DateFormatter()
                    localIso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    allPoints.append(EquityPoint(timestamp: localIso.string(from: Date()), equityUsd: agg.totalEquityUsd, status: .open))
                }
                chartBox.update { $0 = allPoints }
                continuation.yield(EquityChartUpdate(points: allPoints))
            }

            let task = Task {
                for await agg in aggStream.updates {
                    lastAggAtBox.update { $0 = Date() }
                    let previousLiveEquity = liveEquityBox.value
                    let liveEquity = agg.totalEquityUsd
                    let nowEpoch = Int64(Date().timeIntervalSince1970)
                    let currentHourBoundary = (nowEpoch / resolutionSecondsBox.value) * resolutionSecondsBox.value
                    let lastBoundary = hourBoundaryBox.value

                    if currentHourBoundary - lastBoundary > resolutionSecondsBox.value && !historicalBox.value.isEmpty {
                        // Multi-bucket gap: more than one bucket has elapsed
                        // since the last agg event. Single-point patching here
                        // would leave intermediate buckets empty (the
                        // visible-on-resume bug). Refetch the dense server
                        // window which fills every bucket.
                        await refreshHistory()
                        continue
                    } else if currentHourBoundary > lastBoundary, let previousLiveEquity {
                        historicalBox.update { historical in
                            guard !historical.isEmpty else { return }
                            let boundaryDate = Date(timeIntervalSince1970: TimeInterval(lastBoundary))
                            historical.append(EquityPoint(
                                timestamp: iso.string(from: boundaryDate),
                                equityUsd: previousLiveEquity
                            ))
                        }
                        hourBoundaryBox.update { $0 = currentHourBoundary }
                    }
                    liveEquityBox.update { $0 = liveEquity }

                    let livePoint = EquityPoint(
                        timestamp: iso.string(from: Date()),
                        equityUsd: liveEquity
                    )
                    var allPoints = historicalBox.value
                    allPoints.append(livePoint)
                    
                    let prevPoints = chartBox.value
                    if prevPoints.count == allPoints.count, prevPoints.last?.equityUsd == liveEquity {
                        chartBox.update { $0 = allPoints }
                        continue
                    }
                    
                    chartBox.update { $0 = allPoints }

                    continuation.yield(EquityChartUpdate(points: allPoints))
                }
                continuation.finish()
            }
            let chartTask = Task {
                let events = await ws.chartSnapshotEvents()
                for await (eventWatchId, _) in events {
                    guard eventWatchId == chartWatchId else { continue }
                    await refreshHistory()
                }
            }
            let statusTask = Task { [ws] in
                let statusStream = await ws.statusStream
                for await s in statusStream {
                    if s == .disconnected && state.value != .loading {
                        state.update { $0 = .reconnecting }
                    } else if s == .connected && state.value == .reconnecting {
                        // Refresh handled by `authenticatedStream` below —
                        // that fires after the WS has finished re-issuing
                        // all subscriptions, so the chart-history watch is
                        // already re-registered before we refetch.
                        state.update { $0 = .connected }
                    }
                }
            }
            // Tab/app resume: refresh on foreground after a hidden period.
            let resumeTask = Task { [ws] in
                let stream = await ws.resumeStream
                for await _ in stream {
                    await refreshHistory()
                }
            }
            // Every successful auth (initial post-reconnect re-auth, token
            // refresh re-auth, etc.). Registered after the manager is already
            // authenticated, so the very first auth does not fire.
            let authTask = Task { [ws] in
                let stream = await ws.authenticatedStream
                for await _ in stream {
                    await refreshHistory()
                }
            }
            // Wall-clock boundary timer for quiet realms: the materializer
            // pushes chart snapshots only on data change, so a no-fill window
            // produces no events. Refetch when the boundary advances without
            // any agg activity.
            let boundaryTask = Task {
                let tickSeconds = max(min(Int64(30), resolutionSecondsBox.value), 1)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(tickSeconds) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    let nowEpoch = Int64(Date().timeIntervalSince1970)
                    let currentHourBoundary = (nowEpoch / resolutionSecondsBox.value) * resolutionSecondsBox.value
                    let lastBoundary = hourBoundaryBox.value
                    let aggSilence = Date().timeIntervalSince(lastAggAtBox.value)
                    if currentHourBoundary > lastBoundary,
                       aggSilence > BOUNDARY_AGG_SILENCE_FACTOR * Double(resolutionSecondsBox.value) {
                        await refreshHistory()
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                chartTask.cancel()
                statusTask.cancel()
                resumeTask.cancel()
                authTask.cancel()
                boundaryTask.cancel()
            }
        }

        return EquityChartStream(
            state: state,
            chart: chartBox,
            updates: updates,
            stop: {
                await self.ws.removeGapHandler(gapId)
                await self.ws.unwatchChartHistory(watchId: chartWatchId)
                await aggStream.stop()
            }
        )
    }

    /// Create a live P&L chart that merges historical data with real-time
    /// aggregation updates and operation events. The last point reflects
    /// current live P&L. Operation events update cumulative flows client-side.
    ///
    /// The stream buffers the latest value and drops intermediate updates if the consumer
    /// is slow. Updates are also dropped if the live point hasn't materially changed.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): P&L chart for a single object.
    ///     Path prefix (trailing slash): P&L chart aggregated across all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 1000, max 1000). Higher
    ///     values yield finer chart resolution from the server's ladder.
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    ///   - anchor: `.zero` (default) for standard P&L; `.equity` to shift the
    ///     chart so the live (rightmost) value equals the current account equity.
    ///     When `.equity`, each `PnlPoint` includes `valueUsd`.
    public func watchPnlChart(
        path: String,
        from: String,
        to: String,
        points: Int = 1000,
        exchange: String = "sim",
        anchor: PnlAnchor = .zero
    ) async throws -> PnlChartStream {
        try validatePath(path)
        let history = try await getPnlHistory(path: path, from: from, to: to, points: points)
        await ws.watchPath(path)
        let flowsSince = history.effectiveFrom ?? from
        let aggStream = try await watchAggregation(
            sources: [AggregationSource(type: .prefix, value: path)],
            exchange: exchange,
            flowsSince: flowsSince
        )

        let startingEquity = Double(history.startingEquityUsd) ?? 0

        var currentCumInflows = 0.0
        var currentCumOutflows = 0.0
        for flow in history.externalFlows ?? [] {
            let val = Double(flow.valueUsd) ?? 0
            if flow.direction == "inflow" { currentCumInflows += val }
            else { currentCumOutflows += val }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resolutionSecondsBox = SendableBox<Int64>(chartResolutionSeconds(history.resolution))
        let initialHourBoundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value

        // Override flow seed with server-provided cumulative flows from the
        // initial aggregation snapshot (authoritative, covers from..now).
        if let agg = aggStream.aggregation.value {
            if let inStr = agg.cumInflowsUsd, let inVal = Double(inStr) {
                currentCumInflows = inVal
            }
            if let outStr = agg.cumOutflowsUsd, let outVal = Double(outStr) {
                currentCumOutflows = outVal
            }
        }

        // Trim trailing points within the current time bucket. The server's
        // response may include a live-equity-based point for timestamps after
        // lastClosed. Removing it prevents a discontinuity between the server's
        // live equity (Redis at HTTP time) and the SDK's live equity
        // (aggregation watch, potentially revalued with latest mids).
        var trimmedHistorical = history.pnlPoints
        while let last = trimmedHistorical.last,
              let ts = iso.date(from: last.timestamp),
              Int64(ts.timeIntervalSince1970) > initialHourBoundary {
            trimmedHistorical.removeLast()
        }

        var initialChart = trimmedHistorical
        if let agg = aggStream.aggregation.value {
            let liveEquity = Double(agg.totalEquityUsd) ?? 0
            let pnl = liveEquity - startingEquity - currentCumInflows + currentCumOutflows
            let livePnlStr = String(format: "%.2f", pnl)
            initialChart.append(PnlPoint(
                timestamp: iso.string(from: Date()),
                pnlUsd: livePnlStr,
                equityUsd: agg.totalEquityUsd
            ))
            if anchor == .equity {
                applyEquityAnchor(to: &initialChart)
            }
        }

        let state = SendableBox<WatchStreamState>(.connected)
        let historicalBox = SendableBox<[PnlPoint]>(trimmedHistorical)
        let flowsBox = SendableBox<[ExternalFlowEntry]>(history.externalFlows ?? [])
        let chartBox = SendableBox<[PnlPoint]>(initialChart)
        let hourBoundaryBox = SendableBox<Int64>(initialHourBoundary)
        let cumInflowsBox = SendableBox<Double>(currentCumInflows)
        let cumOutflowsBox = SendableBox<Double>(currentCumOutflows)
        let chartWatchId = await ws.watchChartHistory(target: path)
        let gapId = await ws.onGap { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                let key = buildCacheKey("pnlHistory", [
                    "target": path, "kind": "path", "from": from, "to": to, "points": String(points),
                ])
                self.historyCache.delete(key)
                if let fresh = try? await self.getPnlHistory(path: path, from: from, to: to, points: points) {
                    resolutionSecondsBox.update { $0 = chartResolutionSeconds(fresh.resolution) }
                    let boundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value
                    hourBoundaryBox.update { $0 = boundary }
                    historicalBox.update { pts in
                        pts = fresh.pnlPoints.filter { $0.status != .open }
                    }
                    flowsBox.update { $0 = fresh.externalFlows ?? [] }
                }
            }
        }

        let updates = AsyncStream(PnlChartUpdate.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Refetches historical P&L from the server and re-yields the chart
            // with the freshly-fetched points + the current live tip. Shared by
            // the chart_snapshot path (server pushes when a bucket closes) and
            // the reconnect path (WS status flips reconnecting → connected
            // after a long network pause / iOS process suspension).
            // ISO8601DateFormatter is non-Sendable so we construct a fresh
            // instance per call rather than capturing the outer `iso`.
            let refreshHistory: @Sendable () async -> Void = { [weak self] in
                guard let self = self else { return }
                let key = buildCacheKey("pnlHistory", [
                    "target": path, "kind": "path", "from": from, "to": to, "points": String(points),
                ])
                self.historyCache.delete(key)
                guard let fresh = try? await self.getPnlHistory(path: path, from: from, to: to, points: points) else { return }
                resolutionSecondsBox.update { $0 = chartResolutionSeconds(fresh.resolution) }
                let boundary = Int64(Date().timeIntervalSince1970 / Double(resolutionSecondsBox.value)) * resolutionSecondsBox.value
                hourBoundaryBox.update { $0 = boundary }
                let filtered = fresh.pnlPoints.filter { $0.status != .open }
                historicalBox.update { $0 = filtered }
                flowsBox.update { $0 = fresh.externalFlows ?? [] }
                var allPoints = filtered
                if let agg = aggStream.aggregation.value {
                    let liveEquity = Double(agg.totalEquityUsd) ?? 0
                    let pnl = liveEquity - startingEquity - cumInflowsBox.value + cumOutflowsBox.value
                    let localIso = ISO8601DateFormatter()
                    localIso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    allPoints.append(PnlPoint(
                        timestamp: localIso.string(from: Date()),
                        pnlUsd: String(format: "%.2f", pnl),
                        equityUsd: agg.totalEquityUsd,
                        status: .open
                    ))
                }
                if anchor == .equity {
                    applyEquityAnchor(to: &allPoints)
                }
                chartBox.update { $0 = allPoints }
                continuation.yield(PnlChartUpdate(points: allPoints, externalFlows: flowsBox.value))
            }

            let aggTask = Task {
                for await agg in aggStream.updates {
                    let liveEquity = Double(agg.totalEquityUsd) ?? 0
                    let nowEpoch = Int64(Date().timeIntervalSince1970)
                    let currentHourBoundary = (nowEpoch / resolutionSecondsBox.value) * resolutionSecondsBox.value
                    let lastBoundary = hourBoundaryBox.value

                    if currentHourBoundary > lastBoundary {
                        historicalBox.update { pts in
                            guard !pts.isEmpty else { return }
                            let last = pts[pts.count - 1]
                            let boundaryDate = Date(timeIntervalSince1970: TimeInterval(lastBoundary))
                            pts.append(PnlPoint(
                                timestamp: iso.string(from: boundaryDate),
                                pnlUsd: last.pnlUsd,
                                equityUsd: last.equityUsd
                            ))
                        }
                        hourBoundaryBox.update { $0 = currentHourBoundary }
                    }

                    if let inStr = agg.cumInflowsUsd, let inVal = Double(inStr) {
                        cumInflowsBox.update { $0 = inVal }
                    }
                    if let outStr = agg.cumOutflowsUsd, let outVal = Double(outStr) {
                        cumOutflowsBox.update { $0 = outVal }
                    }

                    let pnl = liveEquity - startingEquity - cumInflowsBox.value + cumOutflowsBox.value
                    let livePnlStr = String(format: "%.2f", pnl)
                    let livePoint = PnlPoint(
                        timestamp: iso.string(from: Date()),
                        pnlUsd: livePnlStr,
                        equityUsd: agg.totalEquityUsd
                    )
                    var allPoints = historicalBox.value
                    allPoints.append(livePoint)

                    if anchor == .equity {
                        applyEquityAnchor(to: &allPoints)
                    }

                    let prevPoints = chartBox.value
                    let isSameValue: Bool
                    if anchor == .equity {
                        isSameValue = prevPoints.last?.valueUsd == allPoints.last?.valueUsd
                    } else {
                        isSameValue = prevPoints.last?.pnlUsd == allPoints.last?.pnlUsd
                    }

                    if prevPoints.count == allPoints.count && isSameValue {
                        chartBox.update { $0 = allPoints }
                        continue
                    }

                    chartBox.update { $0 = allPoints }

                    continuation.yield(PnlChartUpdate(
                        points: allPoints,
                        externalFlows: flowsBox.value
                    ))
                }
            }
            let chartTask = Task {
                let events = await ws.chartSnapshotEvents()
                for await (eventWatchId, _) in events {
                    guard eventWatchId == chartWatchId else { continue }
                    await refreshHistory()
                }
            }
            let statusTask = Task { [ws] in
                let statusStream = await ws.statusStream
                for await s in statusStream {
                    if s == .disconnected && state.value != .loading {
                        state.update { $0 = .reconnecting }
                    } else if s == .connected && state.value == .reconnecting {
                        await refreshHistory()
                        state.update { $0 = .connected }
                    }
                }
            }

            continuation.onTermination = { _ in
                aggTask.cancel()
                chartTask.cancel()
                statusTask.cancel()
            }
        }

        return PnlChartStream(
            state: state,
            chart: chartBox,
            updates: updates,
            stop: {
                await self.ws.removeGapHandler(gapId)
                await self.ws.unwatchChartHistory(watchId: chartWatchId)
                await self.ws.unwatchPath(path)
                await aggStream.stop()
            }
        )
    }

    /// Compute `from`/`to` ISO timestamps for a chart range preset, anchored
    /// to the current wall clock. Mirror of the TypeScript SDK's
    /// `computeChartRange`. Use to derive the same windows the SDK uses
    /// when building custom UIs.
    public static func computeChartRange(_ range: ChartRangePreset) -> (from: String, to: String) {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let fromDate: Date
        switch range {
        case .oneHour:         fromDate = calendar.date(byAdding: .hour, value: -1, to: now) ?? now
        case .twentyFourHours: fromDate = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        case .sevenDays:       fromDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .thirtyDays:      fromDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .threeMonths:     fromDate = calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .oneYear:         fromDate = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .ytd:
            var comps = calendar.dateComponents([.year], from: now)
            comps.month = 1; comps.day = 1; comps.hour = 0; comps.minute = 0; comps.second = 0
            fromDate = calendar.date(from: comps) ?? now
        case .all:             fromDate = calendar.date(byAdding: .year, value: -5, to: now) ?? now
        }
        return (iso8601String(from: fromDate), iso8601String(from: now))
    }

    /// Convenience: open a live equity chart for a sliding range preset.
    /// Computes `from`/`to` from the current wall clock and delegates to
    /// `watchEquityChart`, which handles sliding the window forward on
    /// every refresh and self-healing across app suspension.
    public func watchEquityChartLive(
        path: String,
        range: ChartRangePreset,
        points: Int = 1000,
        exchange: String = "sim"
    ) async throws -> EquityChartStream {
        let (from, to) = Arca.computeChartRange(range)
        return try await watchEquityChart(
            path: path, from: from, to: to, points: points, exchange: exchange
        )
    }

    /// Convenience: open a live P&L chart for a sliding range preset.
    /// See ``watchEquityChartLive``.
    public func watchPnlChartLive(
        path: String,
        range: ChartRangePreset,
        points: Int = 1000,
        exchange: String = "sim",
        anchor: PnlAnchor = .zero
    ) async throws -> PnlChartStream {
        let (from, to) = Arca.computeChartRange(range)
        return try await watchPnlChart(
            path: path, from: from, to: to, points: points, exchange: exchange, anchor: anchor
        )
    }

    /// Create an aggregation watch that tracks a set of sources.
    ///
    /// When the underlying data changes, `aggregation.updated` events
    /// are pushed via WebSocket.
    ///
    /// - Parameter sources: Sources to track
    public func createAggregationWatch(sources: [AggregationSource], flowsSince: String? = nil) async throws -> CreateWatchResponse {
        try await client.post("/aggregations/watch", body: CreateWatchRequest(
            realmId: realm,
            sources: sources,
            flowsSince: flowsSince
        ))
    }

    /// Get the current aggregation for an existing watch.
    public func getWatchAggregation(watchId: String) async throws -> PathAggregation {
        let response: GetWatchAggregationResponse = try await client.get("/aggregations/watch/\(watchId)")
        return response.aggregation
    }

    /// Destroy an aggregation watch.
    public func destroyAggregationWatch(watchId: String) async throws {
        let _: EmptyResponse = try await client.delete("/aggregations/watch/\(watchId)")
    }
}

// MARK: - Request Bodies

private struct CreateWatchRequest: Encodable {
    let realmId: String
    let sources: [AggregationSource]
    let flowsSince: String?
}

private struct GetWatchAggregationResponse: Decodable {
    let watchId: String
    let aggregation: PathAggregation
}

private struct EmptyResponse: Decodable {}
