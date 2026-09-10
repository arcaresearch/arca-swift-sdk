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

    /// Get the next unique nonce for a path.
    ///
    /// Reserve the nonce *before* the operation and store the resulting path.
    /// Reuse the stored path on retry — never call `nonce()` inline inside an
    /// operation call, as each invocation produces a new unique path.
    ///
    /// - Parameters:
    ///   - path: Path prefix for nonce generation (e.g. `/op/transfer/fund`).
    ///     Always used as a prefix — the nonce number is appended.
    ///   - separator: Override separator between path and nonce number.
    ///     Default: `/` if path ends with `/`, otherwise `-`.
    ///     Use `:` for operation nonces.
    public func nonce(path: String, separator: String? = nil) async throws -> NonceResponse {
        try validatePath(path)
        var body: [String: String] = [
            "realmId": realm,
            "prefix": path,
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
    /// detection with bounded snapshot recovery on startup and actual gaps. Automatically
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
        let events = await ws.events
        let requests = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let revision = SendableBox(0)
        let recover: @Sendable () -> Void = { revision.update { $0 += 1; requests.continuation.yield($0) } }
        let gap = await ws.onGap { _ in recover() }
        let auth = await ws.onAuthenticated { recover() }
        let rotated = await ws.onRotated { recover() }
        let snapshotResults = AsyncStream<Operation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let snapshots = await ws.onOperationSnapshot { operations in
            if let operation = operations.first(where: { $0.id.rawValue == operationId && $0.state.isTerminal }) {
                snapshotResults.continuation.yield(operation)
            }
        }
        await ws.watchPath("/")
        defer {
            requests.continuation.finish()
            snapshotResults.continuation.finish()
            Task { [ws] in
                await ws.removeGapHandler(gap)
                await ws.removeAuthenticatedHandler(auth)
                await ws.removeRotatedHandler(rotated)
                await ws.removeOperationSnapshotHandler(snapshots)
                await ws.unwatchPath("/")
            }
        }
        recover()
        let result = try await withThrowingTaskGroup(of: Operation.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await event in events {
                    if let operation = event.operation, operation.id.rawValue == operationId {
                        if operation.state.isTerminal { return operation }
                    } else if event.operation == nil && event.entityId == operationId && (event.type == "operation.updated" || event.type == "operation.created") {
                        recover() // a real sparse notification, never a healthy timer
                    }
                }
                throw ArcaError.unknown(code: "STREAM_ENDED", message: "Operation event stream ended", errorId: nil)
            }
            group.addTask {
                for await operation in snapshotResults.stream { return operation }
                throw CancellationError()
            }
            group.addTask {
                var completed = 0
                for await requested in requests.stream {
                    try Task.checkCancellation()
                    if requested <= completed { continue }
                    var covered = requested
                    for attempt in 0..<3 {
                        var acknowledged = false
                        do {
                            let operations = try await withThrowingTaskGroup(of: [Operation].self) { ack in
                                defer { ack.cancelAll() }
                                ack.addTask { try await self.ws.recoverPathSnapshotOperations("/") }
                                ack.addTask {
                                    try await Task.sleep(nanoseconds: 1_000_000_000)
                                    throw ArcaError.unknown(code: "ACK_TIMEOUT", message: "Operation snapshot acknowledgement timed out", errorId: nil)
                                }
                                return try await ack.next()!
                            }
                            acknowledged = true
                            if let operation = operations.first(where: { $0.id.rawValue == operationId && $0.state.isTerminal }) { return operation }
                        }
                        catch { try Task.checkCancellation() }
                        covered = revision.value
                        do {
                            let operation = try await self.getOperation(operationId: operationId).operation
                            try Task.checkCancellation()
                            guard operation.id.rawValue == operationId else {
                                throw ArcaError.unknown(code: "IDENTITY_MISMATCH", message: "Operation recovery identity mismatch", errorId: nil)
                            }
                            if operation.state.isTerminal { return operation }
                            if acknowledged { break } // a healthy pending operation stays on the stream
                        } catch { try Task.checkCancellation() }
                        if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 100_000_000) }
                    }
                    completed = covered
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ArcaError.unknown(code: "TIMEOUT", message: "Timed out waiting for operation \(operationId) after \(Int(timeoutSeconds))s", errorId: nil)
            }
            return try await group.next()!
        }
        try throwIfOperationFailed(result)
        return result
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
