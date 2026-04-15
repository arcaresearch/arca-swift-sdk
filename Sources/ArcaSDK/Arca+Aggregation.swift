import Foundation

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
    ///   - points: Number of samples (default 200, max 1000)
    public func getPnlHistory(
        path: String,
        from: String,
        to: String,
        points: Int = 200
    ) async throws -> PnlHistoryResponse {
        try validatePath(path)
        let key = buildCacheKey("pnlHistory", [
            "prefix": path, "from": from, "to": to, "points": String(points),
        ])
        if let cached: PnlHistoryResponse = historyCache.get(key) {
            return cached
        }
        let result: PnlHistoryResponse = try await client.get("/objects/pnl/history", query: [
            "realmId": realm,
            "prefix": path,
            "from": from,
            "to": to,
            "points": String(points),
        ])
        historyCache.set(key, value: result)
        return result
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
    ///   - points: Number of samples (default 200, max 1000)
    public func getEquityHistory(
        path: String,
        from: String,
        to: String,
        points: Int = 200
    ) async throws -> EquityHistoryResponse {
        try validatePath(path)
        let key = buildCacheKey("equityHistory", [
            "prefix": path, "from": from, "to": to, "points": String(points),
        ])
        if let cached: EquityHistoryResponse = historyCache.get(key) {
            return cached
        }
        let result: EquityHistoryResponse = try await client.get("/objects/aggregate/history", query: [
            "realmId": realm,
            "prefix": path,
            "from": from,
            "to": to,
            "points": String(points),
        ])
        historyCache.set(key, value: result)
        return result
    }

    /// Create a live equity chart that merges historical data with real-time
    /// aggregation updates. The last point reflects the current live equity;
    /// when the hour boundary crosses, the live point is promoted to historical
    /// and a new live point starts.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): chart for a single object.
    ///     Path prefix (trailing slash): chart aggregated across all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 200, max 1000)
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchEquityChart(
        path: String,
        from: String,
        to: String,
        points: Int = 200,
        exchange: String = "sim"
    ) async throws -> EquityChartStream {
        try validatePath(path)
        var history: EquityHistoryResponse
        do {
            history = try await getEquityHistory(path: path, from: from, to: to, points: points)
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
                let key = buildCacheKey("equityHistory", [
                    "prefix": path, "from": from, "to": to, "points": String(points),
                ])
                historyCache.delete(key)
                if let fresh = try? await getEquityHistory(path: path, from: from, to: to, points: points) {
                    history = fresh
                }
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let initialHourBoundary = Int64(Date().timeIntervalSince1970 / 3600) * 3600

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

        let updates = AsyncStream<EquityChartUpdate> { continuation in
            let task = Task {
                for await agg in aggStream.updates {
                    let liveEquity = agg.totalEquityUsd
                    let nowEpoch = Int64(Date().timeIntervalSince1970)
                    let currentHourBoundary = (nowEpoch / 3600) * 3600
                    let lastBoundary = hourBoundaryBox.value

                    if currentHourBoundary > lastBoundary {
                        historicalBox.update { historical in
                            guard !historical.isEmpty else { return }
                            let lastPoint = historical[historical.count - 1]
                            let boundaryDate = Date(timeIntervalSince1970: TimeInterval(lastBoundary))
                            historical.append(EquityPoint(
                                timestamp: iso.string(from: boundaryDate),
                                equityUsd: lastPoint.equityUsd
                            ))
                        }
                        hourBoundaryBox.update { $0 = currentHourBoundary }
                    }

                    let livePoint = EquityPoint(
                        timestamp: iso.string(from: Date()),
                        equityUsd: liveEquity
                    )
                    var allPoints = historicalBox.value
                    allPoints.append(livePoint)
                    chartBox.update { $0 = allPoints }

                    continuation.yield(EquityChartUpdate(points: allPoints))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return EquityChartStream(
            state: state,
            chart: chartBox,
            updates: updates,
            stop: { await aggStream.stop() }
        )
    }

    /// Create a live P&L chart that merges historical data with real-time
    /// aggregation updates and operation events. The last point reflects
    /// current live P&L. Operation events update cumulative flows client-side.
    ///
    /// - Parameters:
    ///   - path: Object path or path prefix.
    ///     Exact path (no trailing slash): P&L chart for a single object.
    ///     Path prefix (trailing slash): P&L chart aggregated across all objects under that prefix.
    ///     Examples: "/users/alice/main" (single object), "/users/alice/" (all of alice's objects)
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 200, max 1000)
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    ///   - anchor: `.zero` (default) for standard P&L; `.equity` to shift the
    ///     chart so the live (rightmost) value equals the current account equity.
    ///     When `.equity`, each `PnlPoint` includes `valueUsd`.
    public func watchPnlChart(
        path: String,
        from: String,
        to: String,
        points: Int = 200,
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
        let initialHourBoundary = Int64(Date().timeIntervalSince1970 / 3600) * 3600

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
                applyEquityAnchor(to: &initialChart, liveEquity: liveEquity, livePnl: pnl)
            }
        }

        let state = SendableBox<WatchStreamState>(.connected)
        let historicalBox = SendableBox<[PnlPoint]>(trimmedHistorical)
        let flowsBox = SendableBox<[ExternalFlowEntry]>(history.externalFlows ?? [])
        let chartBox = SendableBox<[PnlPoint]>(initialChart)
        let hourBoundaryBox = SendableBox<Int64>(initialHourBoundary)
        let cumInflowsBox = SendableBox<Double>(currentCumInflows)
        let cumOutflowsBox = SendableBox<Double>(currentCumOutflows)

        let updates = AsyncStream<PnlChartUpdate> { continuation in
            let aggTask = Task {
                for await agg in aggStream.updates {
                    let liveEquity = Double(agg.totalEquityUsd) ?? 0
                    let nowEpoch = Int64(Date().timeIntervalSince1970)
                    let currentHourBoundary = (nowEpoch / 3600) * 3600
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
                        applyEquityAnchor(to: &allPoints, liveEquity: liveEquity, livePnl: pnl)
                    }
                    chartBox.update { $0 = allPoints }

                    continuation.yield(PnlChartUpdate(
                        points: allPoints,
                        externalFlows: flowsBox.value
                    ))
                }
            }

            continuation.onTermination = { _ in
                aggTask.cancel()
            }
        }

        return PnlChartStream(
            state: state,
            chart: chartBox,
            updates: updates,
            stop: {
                await self.ws.unwatchPath(path)
                await aggStream.stop()
            }
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
