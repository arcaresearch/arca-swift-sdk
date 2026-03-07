import Foundation

// MARK: - Operations, Events, Deltas, Nonces, Summary

extension Arca {

    /// Get operation detail by ID (includes correlated events and deltas).
    public func getOperation(operationId: String) async throws -> OperationDetailResponse {
        try await client.get("/operations/\(operationId)")
    }

    /// List operations in the realm.
    ///
    /// - Parameters:
    ///   - type: Filter by operation type
    ///   - arcaPath: Filter by source or target arca path
    ///   - path: Filter by operation path prefix
    public func listOperations(
        type: OperationType? = nil,
        arcaPath: String? = nil,
        path: String? = nil
    ) async throws -> OperationListResponse {
        var query: [String: String] = ["realmId": realm]
        if let type = type { query["type"] = type.rawValue }
        if let arcaPath = arcaPath { query["arcaPath"] = arcaPath }
        if let path = path { query["path"] = path }
        return try await client.get("/operations", query: query)
    }

    /// List events in the realm.
    ///
    /// - Parameters:
    ///   - arcaPath: Filter by arca path
    ///   - path: Filter by event path prefix
    public func listEvents(arcaPath: String? = nil, path: String? = nil) async throws -> EventListResponse {
        var query: [String: String] = ["realmId": realm]
        if let arcaPath = arcaPath { query["arcaPath"] = arcaPath }
        if let path = path { query["path"] = path }
        return try await client.get("/events", query: query)
    }

    /// Get event detail by ID (includes parent operation and deltas).
    public func getEventDetail(eventId: String) async throws -> EventDetailResponse {
        try await client.get("/events/\(eventId)")
    }

    /// List state deltas for a given Arca path.
    public func listDeltas(arcaPath: String) async throws -> StateDeltaListResponse {
        try await client.get("/deltas", query: [
            "realmId": realm,
            "arcaPath": arcaPath,
        ])
    }

    /// Get the next unique nonce for a path prefix.
    ///
    /// Reserve the nonce *before* the operation and store the resulting path.
    /// Reuse the stored path on retry — never call `nonce()` inline inside an
    /// operation call, as each invocation produces a new unique path.
    ///
    /// - Parameters:
    ///   - prefix: Path prefix (e.g. `/op/transfer/fund`)
    ///   - separator: Override separator between prefix and nonce number.
    ///     Default: `/` if prefix ends with `/`, otherwise `-`.
    ///     Use `:` for operation nonces.
    public func nonce(prefix: String, separator: String? = nil) async throws -> NonceResponse {
        var body: [String: String] = [
            "realmId": realm,
            "prefix": prefix,
        ]
        if let separator = separator { body["separator"] = separator }
        return try await client.post("/nonce", body: body)
    }

    /// Get aggregate counts for the realm.
    public func summary() async throws -> ExplorerSummary {
        try await client.get("/summary", query: ["realmId": realm])
    }

    /// Wait for a specific operation to reach a terminal state.
    ///
    /// Polls the operation via HTTP at regular intervals until the state
    /// is no longer `pending`.
    ///
    /// - Parameters:
    ///   - operationId: The operation to wait for
    ///   - timeoutSeconds: Maximum wait time (default: 30)
    ///   - pollIntervalSeconds: Time between polls (default: 1)
    public func waitForOperation(
        operationId: String,
        timeoutSeconds: TimeInterval = 30,
        pollIntervalSeconds: TimeInterval = 1
    ) async throws -> Operation {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            let detail = try await getOperation(operationId: operationId)
            if detail.operation.state.isTerminal {
                return detail.operation
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }

        throw ArcaError.unknown(
            code: "TIMEOUT",
            message: "Timed out waiting for operation \(operationId) after \(Int(timeoutSeconds))s",
            errorId: nil
        )
    }
}
