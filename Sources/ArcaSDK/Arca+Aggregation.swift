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
        let key = buildCacheKey("pnlHistory", [
            "prefix": prefix, "from": from, "to": to, "points": String(points),
        ])
        if let cached: PnlHistoryResponse = await historyCache.get(key) {
            return cached
        }
        let result: PnlHistoryResponse = try await client.get("/objects/pnl/history", query: [
            "realmId": realm,
            "prefix": prefix,
            "from": from,
            "to": to,
            "points": String(points),
        ])
        await historyCache.set(key, value: result)
        return result
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
        let key = buildCacheKey("equityHistory", [
            "prefix": prefix, "from": from, "to": to, "points": String(points),
        ])
        if let cached: EquityHistoryResponse = await historyCache.get(key) {
            return cached
        }
        let result: EquityHistoryResponse = try await client.get("/objects/aggregate/history", query: [
            "realmId": realm,
            "prefix": prefix,
            "from": from,
            "to": to,
            "points": String(points),
        ])
        await historyCache.set(key, value: result)
        return result
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

    /// Create a live P&L chart that merges historical data with real-time
    /// aggregation updates and operation events. The last point reflects
    /// current live P&L. Operation events update cumulative flows client-side.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix to chart
    ///   - from: Start timestamp (RFC 3339)
    ///   - to: End timestamp (RFC 3339)
    ///   - points: Number of historical samples (default 200, max 1000)
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchPnlChart(
        prefix: String,
        from: String,
        to: String,
        points: Int = 200,
        exchange: String = "sim"
    ) async throws -> PnlChartStream {
        let history = try await getPnlHistory(prefix: prefix, from: from, to: to, points: points)
        await ws.acquireChannel(.operations)
        let aggStream = try await watchAggregation(
            sources: [AggregationSource(type: .prefix, value: prefix)],
            exchange: exchange
        )
        let opStream = await ws.operationEvents()

        let cachedMids = history.midPrices ?? [:]
        let startingEquity = Double(history.startingEquityUsd) ?? 0

        var initCumInflows = 0.0
        var initCumOutflows = 0.0
        for flow in history.externalFlows {
            let val = Double(flow.valueUsd) ?? 0
            if flow.direction == "inflow" { initCumInflows += val }
            else { initCumOutflows += val }
        }

        let state = SendableBox<WatchStreamState>(.connected)
        let historicalBox = SendableBox<[PnlPoint]>(history.pnlPoints)
        let flowsBox = SendableBox<[ExternalFlowEntry]>(history.externalFlows)
        let chartBox = SendableBox<[PnlPoint]>(history.pnlPoints)
        let hourBoundaryBox = SendableBox<Int64>(Int64(Date().timeIntervalSince1970 / 3600) * 3600)
        let cumInflowsBox = SendableBox<Double>(initCumInflows)
        let cumOutflowsBox = SendableBox<Double>(initCumOutflows)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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

                    let pnl = liveEquity - startingEquity - cumInflowsBox.value + cumOutflowsBox.value
                    let livePoint = PnlPoint(
                        timestamp: iso.string(from: Date()),
                        pnlUsd: String(format: "%.2f", pnl),
                        equityUsd: agg.totalEquityUsd
                    )
                    var allPoints = historicalBox.value
                    allPoints.append(livePoint)
                    chartBox.update { $0 = allPoints }

                    continuation.yield(PnlChartUpdate(
                        points: allPoints,
                        externalFlows: flowsBox.value
                    ))
                }
            }

            let opTask = Task {
                for await (op, _) in opStream {
                    guard op.state == .completed else { continue }
                    guard op.type == .deposit || op.type == .transfer else { continue }
                    guard let inputStr = op.input,
                          let inputData = inputStr.data(using: .utf8),
                          let inputJSON = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
                          let amountStr = inputJSON["amount"] as? String,
                          let amount = Double(amountStr), amount > 0 else { continue }

                    let denomination = (inputJSON["denomination"] as? String) ?? "USD"
                    var price = 1.0
                    if denomination != "USD" {
                        guard let midStr = cachedMids[denomination],
                              let mid = Double(midStr), mid > 0 else { continue }
                        price = mid
                    }
                    let valueUsd = amount * price

                    let prefixMode = prefix.hasSuffix("/")
                    let sourceIn = op.sourceArcaPath.map {
                        prefixMode ? $0.hasPrefix(prefix) : $0 == prefix
                    } ?? false
                    let targetIn = op.targetArcaPath.map {
                        prefixMode ? $0.hasPrefix(prefix) : $0 == prefix
                    } ?? false

                    var direction: String?
                    if op.type == .deposit && targetIn {
                        direction = "inflow"
                    } else if op.type == .transfer {
                        if sourceIn && !targetIn { direction = "outflow" }
                        else if !sourceIn && targetIn { direction = "inflow" }
                    }
                    guard let dir = direction else { continue }

                    if dir == "inflow" {
                        cumInflowsBox.update { $0 += valueUsd }
                    } else {
                        cumOutflowsBox.update { $0 += valueUsd }
                    }

                    let flow = ExternalFlowEntry(
                        operationId: op.id,
                        type: op.type.rawValue,
                        direction: dir,
                        amount: amountStr,
                        denomination: denomination,
                        valueUsd: String(format: "%.2f", valueUsd),
                        sourceArcaPath: op.sourceArcaPath,
                        targetArcaPath: op.targetArcaPath,
                        timestamp: op.updatedAt
                    )
                    flowsBox.update { $0.append(flow) }
                }
            }

            continuation.onTermination = { _ in
                aggTask.cancel()
                opTask.cancel()
            }
        }

        return PnlChartStream(
            state: state,
            chart: chartBox,
            updates: updates,
            stop: {
                await self.ws.releaseChannel(.operations)
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
