import Foundation

// MARK: - Aggregation, P&L, Equity History

extension Arca {

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
        try await client.get("/aggregations/watch/\(watchId)")
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

private struct EmptyResponse: Decodable {}
