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

    /// Get aggregated valuation for all objects under a path prefix.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix to aggregate
    ///   - asOf: Optional timestamp for historical aggregation
    public func getPathAggregation(prefix: String, asOf: String? = nil) async throws -> PathAggregation {
        var query: [String: String] = ["realmId": realm, "prefix": prefix]
        if let asOf = asOf { query["asOf"] = asOf }
        return try await client.get("/objects/aggregate", query: query)
    }

    /// Get P&L for objects under a path prefix over a time range.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    public func getPnl(prefix: String, from: String, to: String) async throws -> PnlResponse {
        try await client.get("/objects/pnl", query: [
            "realmId": realm,
            "prefix": prefix,
            "from": from,
            "to": to,
        ])
    }

    /// Get P&L history (time-series) for objects under a path prefix.
    /// Returns P&L and equity values adjusted for external flows.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of samples (default 200, max 1000)
    public func getPnlHistory(
        prefix: String,
        from: String,
        to: String,
        points: Int = 200
    ) async throws -> PnlHistoryResponse {
        try await client.get("/objects/pnl/history", query: [
            "realmId": realm,
            "prefix": prefix,
            "from": from,
            "to": to,
            "points": String(points),
        ])
    }

    /// Get equity history (time-series) for objects under a path prefix.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of samples (default 200, max 1000)
    public func getEquityHistory(
        prefix: String,
        from: String,
        to: String,
        points: Int = 200
    ) async throws -> EquityHistoryResponse {
        try await client.get("/objects/aggregate/history", query: [
            "realmId": realm,
            "prefix": prefix,
            "from": from,
            "to": to,
            "points": String(points),
        ])
    }

    /// Create a live equity chart that merges historical data with real-time
    /// aggregation updates. The last point reflects the current live equity;
    /// when the hour boundary crosses, the live point is promoted to historical
    /// and a new live point starts.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix to chart
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 200, max 1000)
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchEquityChart(
        prefix: String,
        from: String,
        to: String,
        points: Int = 200,
        exchange: String = "sim"
    ) async throws -> EquityChartStream {
        let history = try await getEquityHistory(prefix: prefix, from: from, to: to, points: points)
        let aggStream = try await watchAggregation(
            sources: [AggregationSource(type: .prefix, value: prefix)],
            exchange: exchange
        )

        let state = SendableBox<WatchStreamState>(.connected)
        let historicalBox = SendableBox<[EquityPoint]>(history.equityPoints)
        let chartBox = SendableBox<[EquityPoint]>(history.equityPoints)
        let hourBoundaryBox = SendableBox<Int64>(Int64(Date().timeIntervalSince1970 / 3600) * 3600)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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

    /// Create an aggregation watch that tracks a set of sources.
    ///
    /// When the underlying data changes, `aggregation.updated` events
    /// are pushed via WebSocket.
    ///
    /// - Parameter sources: Sources to track
    public func createAggregationWatch(sources: [AggregationSource]) async throws -> CreateWatchResponse {
        try await client.post("/aggregations/watch", body: CreateWatchRequest(
            realmId: realm,
            sources: sources
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
}

private struct GetWatchAggregationResponse: Decodable {
    let watchId: String
    let aggregation: PathAggregation
}

private struct EmptyResponse: Decodable {}
