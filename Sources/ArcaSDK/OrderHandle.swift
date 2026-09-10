import Foundation

/// Dependencies injected into ``OrderHandle`` from the ``Arca`` client.
public struct OrderHandleDeps: Sendable {
    let getOrder: @Sendable (String, String) async throws -> SimOrderWithFills
    let fillEvents: @Sendable () async -> AsyncStream<(SimFill, RealmEvent)>
    let cancelOrder: @Sendable (String, String, String) -> OperationHandle<OrderOperationResponse>
    let modifyOrder: @Sendable (String, String, String, String) -> OperationHandle<OrderOperationResponse>
    let waitForSettlement: @Sendable (String) async throws -> Operation
    let listFills: @Sendable (String) async throws -> FillListResponse
    var releaseExecution: (@Sendable () async -> Void)? = nil
    var awaitExecutionReady: (@Sendable () async throws -> Void)? = nil
    var executionEvents: (@Sendable () async -> AsyncStream<RealmEvent>)? = nil
    var getExecutionOperation: (@Sendable (String) async throws -> Operation)? = nil
    var executionGaps: (@Sendable () async -> AsyncStream<Void>)? = nil
    var recoverExecutionReady: (@Sendable () async throws -> Void)? = nil
    var watchLifecycle: (@Sendable (String, OriginalOrderReference, Int) async throws -> OrderLifecycleWatch)? = nil
    var lifecycleLeg: Int = 0
}

/// Handle for exchange order lifecycle.
///
/// Extends the ``OperationHandle`` pattern with order-specific methods
/// for waiting on fills, streaming fills, and cancelling.
///
/// ```swift
/// let order = arca.placeOrder(path: "/op/order/btc-1", objectId: id, ...)
/// try await order.settle()  // wait for placement
///
/// let filled = try await order.filled(timeoutSeconds: 30)
///
/// for try await fill in order.fills() {
///     print("Filled \(fill.size) @ \(fill.price)")
/// }
///
/// try await order.cancel().settle()
/// ```
public final class OrderHandle: @unchecked Sendable {
    private let inner: OperationHandle<OrderOperationResponse>
    private let objectId: String
    private let placementPath: String
    private let deps: OrderHandleDeps
    private let executionDetail = SendableBox<SimOrderWithFills?>(nil)

    init(
        inner: OperationHandle<OrderOperationResponse>,
        objectId: String,
        placementPath: String,
        deps: OrderHandleDeps
    ) {
        self.inner = inner
        self.objectId = objectId
        self.placementPath = placementPath
        self.deps = deps
    }

    deinit {
        let release = deps.releaseExecution
        Task { await release?() }
    }

    /// The HTTP response (before settlement).
    public var submitted: OrderOperationResponse {
        get async throws { try await inner.submitted }
    }

    /// Wait for full operation settlement (order placement confirmed).
    public var settled: OrderOperationResponse {
        get async throws { try await inner.settled }
    }

    /// Wait for full operation settlement (discardable).
    ///
    /// Same as ``settled`` but marked `@discardableResult` so callers that
    /// only need to wait — without inspecting the response — avoid an
    /// "unused result" warning.
    @discardableResult
    public func settle() async throws -> OrderOperationResponse {
        try await inner.settle()
    }

    /// Wait for settlement with an explicit timeout.
    public func settled(timeoutSeconds: TimeInterval) async throws -> OrderOperationResponse {
        try await inner.settled(timeoutSeconds: timeoutSeconds)
    }

    /// Prompt terminal evidence, independent of full order metadata and ledger history.
    public func executionReceipt(timeoutSeconds: TimeInterval = 30) async throws -> OrderExecutionReceipt {
        if deps.watchLifecycle != nil {
            return try await serverLifecycleReceipt(timeoutSeconds: timeoutSeconds, accounting: false).receipt
        }
        do {
            let receipt = try await waitExecutionReceipt(timeoutSeconds: timeoutSeconds)
            await deps.releaseExecution?()
            return receipt
        } catch let error as ArcaError {
            if case .operationFailed = error { await deps.releaseExecution?() }
            throw error
        }
    }

    private func waitExecutionReceipt(timeoutSeconds: TimeInterval) async throws -> OrderExecutionReceipt {
        // Factory-owned capture supplies replay; register before reading submission.
        let events = await deps.executionEvents?()
        let submitted = try await inner.submitted
        let operation = submitted.operation
        if operation.state == .failed || operation.state == .expired { throw ArcaError.operationFailed(operation: operation) }
        if let receipt = OrderExecutionReceipt.from(operation, objectId: objectId) { return receipt }
        let gaps = await deps.executionGaps?()
        let orderId = try? Self.extractOrderId(from: operation.outcome, allowStructuredFallback: false)
        let evidence = OrderExecutionEvidence(operation: operation, objectId: objectId, orderId: orderId)
        let (requests, request) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let recoveryVersion = SendableBox(0)
        request.yield(0)
        return try await withThrowingTaskGroup(of: OrderExecutionReceipt?.self) { group in
            defer { group.cancelAll(); request.finish() }
            if let events {
                group.addTask {
                    for await event in events {
                        if let receipt = try await evidence.receive(event) { return receipt }
                    }
                    return nil
                }
            }
            if let gaps {
                group.addTask {
                    for await _ in gaps {
                        recoveryVersion.update { $0 += 1 }
                        request.yield(recoveryVersion.value)
                    }
                    return nil
                }
            }
            group.addTask {
                var attempts = 0
                var consumedVersion = -1
                for await version in requests {
                    if version <= consumedVersion { continue }
                    var retry = true
                    while retry && attempts < 3 {
                        attempts += 1
                        retry = false
                        do {
                            if attempts == 1 { try await self.deps.awaitExecutionReady?() }
                            else { try await self.deps.recoverExecutionReady?() }
                            try Task.checkCancellation()
                            consumedVersion = recoveryVersion.value
                            if await evidence.orderId == nil, let getOperation = self.deps.getExecutionOperation {
                                let recovered = try await getOperation(operation.id.rawValue)
                                if let receipt = try await evidence.receive(RealmEvent(type: "operation.updated", operation: recovered)) { return receipt }
                                // A healthy pending operation waits for push; its ID is
                                // never substituted for a venue ID by modern factories.
                                if await evidence.orderId == nil { break }
                            }
                            let id = await evidence.orderId ?? operation.id.rawValue
                            let detail = try await self.deps.getOrder(self.objectId, id)
                            let receipt = try await evidence.snapshot(detail)
                            if await evidence.orderId == detail.order.id.rawValue { self.executionDetail.update { $0 = detail } }
                            if let receipt { return receipt }
                            // OPEN is healthy: no timer or repeated read.
                        } catch let error as ArcaError {
                            if case .operationFailed = error { throw error }
                            retry = attempts < 3
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            retry = attempts < 3
                        }
                        if retry { try await Task.sleep(nanoseconds: UInt64(attempts) * 250_000_000) }
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ArcaError.unknown(code: "TIMEOUT", message: "Order execution timed out", errorId: nil)
            }
            while let candidate = try await group.next() { if let candidate { return candidate } }
            throw ArcaError.unknown(code: "STREAM_ENDED", message: "Order execution evidence unavailable", errorId: nil)
        }
    }

    /// Follow this handle's retained operation and exact batch leg. Stopping
    /// the returned watch releases its attachment; recovery never places again.
    public func lifecycleUpdates(timeoutSeconds: TimeInterval = 30) async throws -> OrderLifecycleWatch {
        guard let watch = deps.watchLifecycle else {
            throw ArcaError.unknown(code: "ORDER_LIFECYCLE_UNAVAILABLE", message: "Original order lifecycle is unavailable", errorId: nil)
        }
        return try await withOrderLifecycleDeadline(timeoutSeconds) { [self] in
            let original: OriginalOrderReference
            do { original = .id(try await inner.submitted.operation.id.rawValue) }
            catch { try Task.checkCancellation(); original = .path(placementPath) }
            try Task.checkCancellation()
            let attachment = try await watch(objectId, original, deps.lifecycleLeg)
            do { try Task.checkCancellation() }
            catch { await attachment.stop(); throw error }
            return attachment
        }
    }

    private func serverLifecycleReceipt(timeoutSeconds: TimeInterval, accounting: Bool) async throws -> OrderLifecycleReceipt {
        do {
            let receipt = try await withOrderLifecycleDeadline(timeoutSeconds) { [self] in
                let watch = try await lifecycleUpdates(timeoutSeconds: timeoutSeconds)
                do {
                    for await update in watch.updates {
                        try Task.checkCancellation()
                        if update.unavailable {
                            if !update.recoverable {
                                throw ArcaError.unknown(code: "ORDER_LIFECYCLE_UNAVAILABLE", message: update.reason ?? "Original order unavailable", errorId: nil)
                            }
                            continue
                        }
                        if let receipt = update.lifecycle?.executionReceipt, !accounting || receipt.fillsComplete {
                            await watch.stop()
                            return receipt
                        }
                    }
                    try Task.checkCancellation()
                    throw ArcaError.unknown(code: "ORDER_LIFECYCLE_UNAVAILABLE", message: "Original order stream ended", errorId: nil)
                } catch { await watch.stop(); throw error }
            }
            await deps.releaseExecution?()
            return receipt
        } catch { await deps.releaseExecution?(); throw error }
    }

    /// Wait for the order to be fully filled.
    ///
    /// Resolves execution evidence, then reads complete order metadata.
    /// Fill history completeness is reported separately by the response.
    ///
    /// - Parameter timeoutSeconds: Maximum wait time (default: 30 seconds).
    /// - Returns: The order with all its fills.
    public func filled(timeoutSeconds: TimeInterval = 30) async throws -> SimOrderWithFills {
        if deps.watchLifecycle != nil {
            let receipt = try await serverLifecycleReceipt(timeoutSeconds: timeoutSeconds, accounting: true)
            guard !receipt.orderId.isEmpty else {
                throw ArcaError.unknown(code: "ORDER_DETAILS_UNAVAILABLE", message: "Original execution has no venue order metadata", errorId: nil)
            }
            let detail = try await deps.getOrder(objectId, receipt.orderId)
            guard detail.order.id.rawValue == receipt.orderId, detail.fillsComplete == true else {
                throw ArcaError.unknown(code: "ORDER_DETAILS_PENDING", message: "Complete original order accounting is unavailable", errorId: nil)
            }
            return detail
        }
        let receipt = try await executionReceipt(timeoutSeconds: timeoutSeconds)
        let cached = executionDetail.value
        let detail: SimOrderWithFills
        if let cached, cached.order.id.rawValue == receipt.orderId, cached.order.isTerminalWithFills {
            detail = cached
        } else { detail = try await deps.getOrder(objectId, receipt.orderId) }
        guard detail.order.id.rawValue == receipt.orderId else {
            throw ArcaError.unknown(code: "ORDER_IDENTITY_MISMATCH", message: "Order details do not match execution", errorId: nil)
        }
        try Self.throwIfTerminalWithoutFills(detail.order, orderId: receipt.orderId)
        guard detail.order.isTerminalWithFills,
              let materialized = detail.order.executionQuantity,
              let executed = OrderExecutionReceipt.decimal(receipt.filledSize), materialized == executed else {
            throw ArcaError.unknown(code: "ORDER_DETAILS_PENDING", message: "Execution completed; full order details are not available yet", errorId: nil)
        }
        return detail
    }

    /// An async stream of fills as they arrive via WebSocket.
    ///
    /// ```swift
    /// for try await fill in order.fills() {
    ///     print("Filled \(fill.size) @ \(fill.price)")
    /// }
    /// ```
    ///
    /// - Parameter timeoutSeconds: Stream closes if no fill arrives within this duration (default: 300 seconds).
    private enum FillMessage: Sendable { case fill(SimFill); case event(RealmEvent) }

    public func fills(timeoutSeconds: TimeInterval = 300) -> AsyncThrowingStream<SimFill, Error> {
        if deps.watchLifecycle != nil { return lifecycleFills(timeoutSeconds: timeoutSeconds) }
        return legacyFills(timeoutSeconds: timeoutSeconds)
    }

    private func lifecycleFills(timeoutSeconds: TimeInterval) -> AsyncThrowingStream<SimFill, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withOrderLifecycleDeadline(timeoutSeconds) { [self] in
                        let watch = try await lifecycleUpdates(timeoutSeconds: timeoutSeconds)
                        do {
                            var seen = Set<String>()
                            for await update in watch.updates {
                                try Task.checkCancellation()
                                if update.unavailable {
                                    if !update.recoverable { throw ArcaError.unknown(code: "ORDER_LIFECYCLE_UNAVAILABLE", message: update.reason ?? "Original order unavailable", errorId: nil) }
                                    continue
                                }
                                guard let view = update.lifecycle else { continue }
                                guard let fills = view.committedFills else { throw ArcaError.unknown(code: "ORDER_FILLS_UNAVAILABLE", message: "Original order has no canonical fill snapshot", errorId: nil) }
                                for fill in fills {
                                    try Task.checkCancellation()
                                    if seen.insert(fill.id).inserted { continuation.yield(fill.fill) }
                                }
                                if view.accountingComplete && !view.recoveryRequired { await watch.stop(); return }
                            }
                            try Task.checkCancellation()
                            throw ArcaError.unknown(code: "ORDER_LIFECYCLE_UNAVAILABLE", message: "Original order stream ended", errorId: nil)
                        } catch { await watch.stop(); throw error }
                    }
                    await deps.releaseExecution?(); continuation.finish()
                } catch { await deps.releaseExecution?(); continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func legacyFills(timeoutSeconds: TimeInterval) -> AsyncThrowingStream<SimFill, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Local collectors precede submission and the finite history seed.
                    let live = await self.deps.fillEvents()
                    let execution = await self.deps.executionEvents?()
                    let (messages, input) = AsyncStream<FillMessage>.makeStream()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        defer { group.cancelAll(); input.finish() }
                        group.addTask { for await (fill, _) in live { input.yield(.fill(fill)) } }
                        if let execution { group.addTask { for await event in execution { input.yield(.event(event)) } } }
                        let response = try await self.inner.submitted
                        if response.operation.state == .failed || response.operation.state == .expired { throw ArcaError.operationFailed(operation: response.operation) }
                        let orderId = try Self.extractOrderId(from: response.operation.outcome)
                        let cloid = Self.extractCloid(from: response.operation.outcome)
                        var receipt = OrderExecutionReceipt.from(response.operation, objectId: self.objectId)
                        var seen: [String: SimFill] = [:]
                        if let receipt, Self.fillTotalMatches([], receipt.filledSize) { return }
                        group.addTask {
                            if let detail = try? await self.deps.getOrder(self.objectId, orderId), detail.order.id.rawValue == orderId {
                                for fill in detail.fills { input.yield(.fill(fill)) }
                                let update = OrderExecutionUpdate(order: .init(id: orderId, orderId: orderId, status: detail.order.status.rawValue, filledSize: detail.order.filledSize, avgFillPrice: detail.order.avgFillPrice), fillsComplete: detail.fillsComplete)
                                input.yield(.event(RealmEvent(type: "order.updated", entityId: self.objectId, order: update)))
                            }
                        }
                        for await message in messages {
                            switch message {
                            case .fill(let fill):
                                let key = fill.fillId ?? fill.id.rawValue
                                if fill.isOptimistic != true, !key.isEmpty, Self.fillMatches(fill, orderId: orderId, cloid: cloid), seen[key] == nil {
                                    seen[key] = fill
                                    continuation.yield(fill)
                                }
                            case .event(let event):
                                if let op = event.operation, op.id == response.operation.id,
                                   let candidate = OrderExecutionReceipt.from(op, objectId: self.objectId, originalInput: response.operation.input), candidate.orderId == orderId { receipt = candidate }
                                if event.entityId == self.objectId, let update = event.order?.order, (update.orderId ?? update.id) == orderId,
                                   let candidate = OrderExecutionReceipt.from(response.operation, objectId: self.objectId, update: update) { receipt = candidate }
                            }
                            if let receipt, Self.fillTotalMatches(Array(seen.values), receipt.filledSize) { return }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) }
                catch { return }
                continuation.finish(throwing: ArcaError.unknown(code: "TIMEOUT", message: "Fill stream timed out", errorId: nil))
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); deadline.cancel() }
        }
    }

    private static func fillTotalMatches(_ fills: [SimFill], _ executed: String) -> Bool {
        guard let expected = OrderExecutionReceipt.decimal(executed) else { return false }
        var total = Decimal.zero
        for fill in fills {
            guard var size = OrderExecutionReceipt.decimal(fill.size) else { return false }
            var next = Decimal.zero
            guard NSDecimalAdd(&next, &total, &size, .plain) == .noError else { return false }
            total = next
        }
        return total == expected
    }

    /// Get the platform-side fill record for this order with P&L, fee breakdown,
    /// direction, and resulting position. Waits for the order to be filled first.
    ///
    /// ```swift
    /// let summary = try await order.fillSummary()
    /// print("Realized P&L: \(summary?.realizedPnl ?? "N/A")")
    /// print("Direction: \(summary?.direction ?? "N/A")")
    /// ```
    public func fillSummary(timeoutSeconds: TimeInterval = 30) async throws -> Fill? {
        let result = try await filled(timeoutSeconds: timeoutSeconds)
        let response = try await inner.submitted
        let opId = response.operation.id
        let fills = try await deps.listFills(objectId)
        return fills.fills.first { $0.operationId == opId.rawValue || $0.orderId == result.order.id.rawValue }
    }

    /// Callback-based fill listener. Returns a cancellation closure.
    ///
    /// ```swift
    /// let unsub = order.onFill { fill in
    ///     print("Got fill: \(fill.size) @ \(fill.price)")
    /// }
    /// // later...
    /// unsub()
    /// ```
    @discardableResult
    public func onFill(_ callback: @escaping @Sendable (SimFill) -> Void) -> @Sendable () -> Void {
        if deps.watchLifecycle != nil {
            let task = Task {
                do { for try await fill in fills() { try Task.checkCancellation(); callback(fill) } }
                catch { /* Callback API has no error channel; cancellation releases its watch. */ }
            }
            return { task.cancel() }
        }
        let inner = self.inner
        let deps = self.deps

        let task = Task {
            do {
                let fillStream = await deps.fillEvents()
                let response = try await inner.submitted
                let orderId = try Self.extractOrderId(from: response.operation.outcome)
                let cloid = Self.extractCloid(from: response.operation.outcome)

                var seen = Set<String>()
                for await (fill, _) in fillStream {
                    let key = fill.fillId ?? fill.id.rawValue
                    if !Task.isCancelled, fill.isOptimistic != true, !key.isEmpty, Self.fillMatches(fill, orderId: orderId, cloid: cloid), seen.insert(key).inserted {
                        callback(fill)
                    }
                }
            } catch {
                // Swallow — callback mode is fire-and-forget
            }
        }

        return { task.cancel() }
    }

    /// Cancel the order.
    ///
    /// - Parameter path: Optional operation path for idempotency. Defaults to
    ///   `<placementPath>/cancel`.
    /// - Returns: An ``OperationHandle`` for the cancellation operation.
    public func cancel(path: String? = nil) -> OperationHandle<OrderOperationResponse> {
        let cancelPath = path ?? "\(placementPath)/cancel"
        let objectId = self.objectId
        let inner = self.inner
        let deps = self.deps

        return OperationHandle(
            submit: {
                let response = try await inner.submitted
                let orderId = try Self.extractOrderId(from: response.operation.outcome)
                let cancelHandle = deps.cancelOrder(cancelPath, objectId, orderId)
                return try await cancelHandle.submitted
            },
            waitForSettlement: deps.waitForSettlement
        )
    }

    /// Resize the order to a new total size.
    ///
    /// Only **sized** orders can be resized: resting limit orders and sized
    /// TP/SL triggers. Unsized ("size to max") TP/SL triggers are rejected by
    /// the venue — they always close the whole position and have no size to
    /// amend. `newSize` must exceed the order's already-filled quantity.
    ///
    /// - Parameters:
    ///   - newSize: The new total order size.
    ///   - path: Optional operation path for idempotency. Defaults to the
    ///     placement path with `/op/order/` replaced by `/op/modify/`, then
    ///     `-<newSize>` appended. Distinct resizes need distinct paths.
    /// - Returns: An ``OperationHandle`` for the resize operation.
    public func resize(_ newSize: String, path: String? = nil) -> OperationHandle<OrderOperationResponse> {
        let modifyPath = path
            ?? placementPath.replacingOccurrences(of: "/op/order/", with: "/op/modify/") + "-\(newSize)"
        let objectId = self.objectId
        let inner = self.inner
        let deps = self.deps

        return OperationHandle(
            submit: {
                let response = try await inner.submitted
                let orderId = try Self.extractOrderId(from: response.operation.outcome)
                let modifyHandle = deps.modifyOrder(modifyPath, objectId, orderId, newSize)
                return try await modifyHandle.submitted
            },
            waitForSettlement: deps.waitForSettlement
        )
    }

    // MARK: - Private

    private static func throwIfTerminalWithoutFills(_ order: SimOrder, orderId: String) throws {
        switch order.status {
        case .failed:
            throw ArcaError.unknown(
                code: "ORDER_\(order.status.rawValue)",
                message: "Order \(orderId) reached \(order.status.rawValue)",
                errorId: nil
            )
        case .cancelled where order.executionQuantity == 0:
            throw ArcaError.unknown(
                code: "ORDER_\(order.status.rawValue)",
                message: "Order \(orderId) was cancelled with no fills",
                errorId: nil
            )
        default:
            break
        }
    }

    private func resolveOrderId() async throws -> String {
        let response = try await inner.settled
        return try Self.extractOrderId(from: response.operation.outcome)
    }

    private static func extractOrderId(from outcome: String?, allowStructuredFallback: Bool = true) throws -> String {
        guard let raw = outcome, !raw.isEmpty else {
            throw ArcaError.unknown(
                code: "NO_ORDER_ID",
                message: "Operation outcome does not contain an order ID",
                errorId: nil
            )
        }
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let orderId = parsed["orderId"] as? String, !orderId.isEmpty {
            return orderId
        }
        if !allowStructuredFallback, raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            throw ArcaError.unknown(code: "NO_ORDER_ID", message: "Operation outcome has no venue order ID yet", errorId: nil)
        }
        return raw
    }

    /// The order's client id (Hyperliquid cloid) from the placement outcome. A
    /// `normalTpsl` bracket child is not a live venue order until the entry
    /// fills and the venue arms it — until then it has NO venue order id and is
    /// addressable only by its cloid, so fill matching must also key on it.
    /// Returns nil when the outcome carries no cloid (e.g. sim orders).
    private static func extractCloid(from outcome: String?) -> String? {
        guard let raw = outcome, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cloid = parsed["cloid"] as? String, !cloid.isEmpty else {
            return nil
        }
        return cloid
    }

    /// Whether a fill belongs to this order. Matches on the venue order id when
    /// the order is live, OR on the cloid — the latter is the only handle a
    /// still-pending bracket child has before the venue assigns it an oid.
    private static func fillMatches(_ fill: SimFill, orderId: String, cloid: String?) -> Bool {
        if !fill.orderId.rawValue.isEmpty, fill.orderId.rawValue == orderId {
            return true
        }
        if let cloid, !cloid.isEmpty, let fillCloid = fill.cloid, fillCloid == cloid {
            return true
        }
        return false
    }
}
