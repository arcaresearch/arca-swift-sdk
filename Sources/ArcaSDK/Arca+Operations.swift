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
    ///   - type: Filter by a single operation type
    ///   - types: Filter by multiple operation types (takes precedence over `type`)
    ///   - arcaPath: Filter by source or target arca path
    ///   - path: Filter by operation path prefix
    ///   - includeContext: When true, each operation includes its typed context
    ///     (transfer amount/fee, fill details, etc.) inline
    public func listOperations(
        type: OperationType? = nil,
        types: [OperationType]? = nil,
        arcaPath: String? = nil,
        path: String? = nil,
        includeContext: Bool = false
    ) async throws -> OperationListResponse {
        var query: [String: String] = ["realmId": realm]
        if let types = types, !types.isEmpty {
            query["types"] = types.map(\.rawValue).joined(separator: ",")
        } else if let type = type {
            query["type"] = type.rawValue
        }
        if let arcaPath = arcaPath { query["arcaPath"] = arcaPath }
        if let path = path { query["path"] = path }
        if includeContext { query["includeContext"] = "true" }
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
    /// Uses WebSocket `operation.updated` events for real-time settlement
    /// detection with periodic HTTP polling as a safety net. Automatically
    /// ensures the WebSocket is connected and subscribed to operations.
    ///
    /// Throws ``ArcaError/operationFailed(operation:)`` if the terminal
    /// state is `failed` or `expired`.
    ///
    /// - Parameters:
    ///   - operationId: The operation to wait for
    ///   - timeoutSeconds: Maximum wait time (default: 30)
    public func waitForOperation(
        operationId: String,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> Operation {
        try await waitForSettlement(operationId, timeoutSeconds: timeoutSeconds)
    }

    /// Internal WebSocket-based settlement wait used by ``OperationHandle``.
    func waitForSettlement(
        _ operationId: String,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> Operation {
        await ws.ensureConnected()
        await ws.watchPath("/")
        defer { Task { [ws] in await ws.unwatchPath("/") } }

        return try await withThrowingTaskGroup(of: Operation.self) { group in
            // WebSocket path: listen for matching operation.updated events
            group.addTask {
                let stream = await self.ws.operationEvents()
                for await (op, _) in stream {
                    if op.id.rawValue == operationId && op.state.isTerminal {
                        try self.throwIfOperationFailed(op)
                        return op
                    }
                }
                throw ArcaError.unknown(
                    code: "STREAM_ENDED",
                    message: "Operation event stream ended",
                    errorId: nil
                )
            }

            // HTTP fallback: immediate first check, then periodic polling
            group.addTask {
                while !Task.isCancelled {
                    let detail = try await self.getOperation(operationId: operationId)
                    if detail.operation.state.isTerminal {
                        try self.throwIfOperationFailed(detail.operation)
                        return detail.operation
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                throw CancellationError()
            }

            // Timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ArcaError.unknown(
                    code: "TIMEOUT",
                    message: "Timed out waiting for operation \(operationId) after \(Int(timeoutSeconds))s",
                    errorId: nil
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Throws ``ArcaError/operationFailed(operation:)`` when the operation
    /// reached a non-success terminal state.
    func throwIfOperationFailed(_ operation: Operation) throws {
        switch operation.state {
        case .failed, .expired:
            throw ArcaError.operationFailed(operation: operation)
        case .pending, .completed:
            break
        }
    }
}
