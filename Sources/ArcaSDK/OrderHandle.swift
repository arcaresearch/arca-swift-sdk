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
    /// Platform-recorded fills (`fill.recorded`), the accounting-time event.
    /// Optional so partial bundles keep working; without it
    /// ``OrderHandle/accounted(timeoutSeconds:)`` converges through its
    /// bounded reads alone.
    var recordedFillEvents: (@Sendable () async -> AsyncStream<(Fill, RealmEvent)>)? = nil
    /// Keep the realm root watched until the returned release runs, so
    /// `fill.recorded` frames for this order reach the socket even when the
    /// application holds no other watch covering the account.
    var holdAccountWatch: (@Sendable () async -> @Sendable () async -> Void)? = nil
    /// Tell any live exchange-state watch for the object that its account
    /// changed, so it re-reads. Called when accounting completion was learned
    /// through a REST read — the moment a lost account push is most likely.
    var exchangeStateChanged: (@Sendable (String) -> Void)? = nil
}

/// Bounded fallback-read schedule for ``OrderHandle/accounted(timeoutSeconds:)``.
private let accountedReadInitialSeconds: TimeInterval = 0.5
private let accountedReadMaxSeconds: TimeInterval = 8

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
    private let positionUpdate = SendableBox<PositionUpdate?>(nil)
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

    /// Bind a baseline captured before submission, including backend-submitted orders.
    public func trackPositionUpdate(_ update: PositionUpdate) async throws {
        let response = try await inner.submitted
        try update.view.bind(update, operation: response.operation, objectId: objectId)
        positionUpdate.update { $0 = update }
    }

    /// Retire this display scope only after server proof of terminal zero execution.
    /// Read-only and retryable. False leaves the scope active; errors leave it unchanged.
    /// This is not ledger completion and does not turn a rejected order into success.
    public func retirePositionUpdateIfNoExecution() async throws -> Bool {
        guard let update = positionUpdate.value else { return false }
        let original = try await inner.submitted.operation
        let operation: Operation
        if let read = deps.getExecutionOperation { operation = try await read(original.id.rawValue) }
        else { operation = original }
        guard operation.id == original.id else { return false }
        if await update.view.retireNoExecution(update, operation: operation) { return true }
        // The lifecycle endpoint explicitly accepts the original operation ID,
        // including rejections that never acquired a venue order ID.
        let detail = try await deps.getOrder(objectId, original.id.rawValue)
        return await update.view.retireNoExecution(update, operation: operation, detail: detail)
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
        do {
            let receipt = try await waitExecutionReceipt(timeoutSeconds: timeoutSeconds)
            if let update = positionUpdate.value { update.view.receive(update, receipt: receipt) }
            await deps.releaseExecution?()
            return receipt
        } catch let error as ArcaError {
            if case .operationFailed = error {
                _ = try? await retirePositionUpdateIfNoExecution()
                await deps.releaseExecution?()
            }
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

    /// Wait until the account reflects this order's execution.
    ///
    /// ``executionReceipt(timeoutSeconds:)`` proves terminal execution at the
    /// venue; the ledger commit that updates the account's positions and
    /// balances happens afterwards, and an exchange-state read taken in
    /// between returns the pre-accounting snapshot. This resolves once every
    /// executed quantity is recorded — the platform's `fillsComplete` — so a
    /// `getExchangeState` / `watchExchangeState` observation taken after it
    /// includes the execution. A live `watchExchangeState` for the account is
    /// refreshed when completion had to be learned through a read.
    ///
    /// Push-first: each `fill.recorded` for this order triggers one order
    /// read, as do delivery gaps and reconnects. A lost push is covered by a
    /// bounded backoff read (500ms doubling to 8s) until the deadline. On
    /// venues whose order read carries no `fillsComplete`, completion is the
    /// recorded fills for the order covering its executed size exactly.
    ///
    /// Resolves for a zero-fill terminal order too (nothing to account).
    /// Throws the placement failure, or `TIMEOUT` when accounting has not
    /// completed within `timeoutSeconds`.
    ///
    /// ```swift
    /// let receipt = try await order.executionReceipt()   // show the receipt
    /// let detail = try await order.accounted()           // then trust the account
    /// let state = try await arca.getExchangeState(objectId: id)
    /// ```
    public func accounted(timeoutSeconds: TimeInterval = 30) async throws -> SimOrderWithFills {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        // Register recorded-fill delivery and hold the root watch BEFORE the
        // receipt, so a fill recorded between the two cannot be missed.
        let recorded = await deps.recordedFillEvents?()
        let release = await deps.holdAccountWatch?()
        do {
            let detail = try await accountedDetail(deadline: deadline, recorded: recorded)
            if let update = positionUpdate.value { await update.view.accounted(update, detail: detail) }
            await release?()
            return detail
        } catch {
            await release?()
            throw error
        }
    }

    private func accountedDetail(deadline: Date, recorded: AsyncStream<(Fill, RealmEvent)>?) async throws -> SimOrderWithFills {
        let receipt = try await executionReceipt(timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
        let orderId = receipt.orderId
        let operationId = receipt.operationId
        if let cached = executionDetail.value, cached.order.id.rawValue == orderId, cached.fillsComplete == true {
            return cached
        }
        let gaps = await deps.executionGaps?()
        let (requests, request) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        request.yield(())
        let detail: SimOrderWithFills = try await withThrowingTaskGroup(of: SimOrderWithFills?.self) { group in
            defer { group.cancelAll(); request.finish() }
            if let recorded {
                group.addTask {
                    for await (fill, _) in recorded {
                        if Self.recordedFillMatches(fill, orderId: orderId, operationId: operationId) { request.yield(()) }
                    }
                    return nil
                }
            }
            if let gaps {
                group.addTask {
                    for await _ in gaps { request.yield(()) }
                    return nil
                }
            }
            group.addTask {
                // The fallback for a lost push: exchange.updated / fill.recorded
                // have no durable log, and a deferred enrichment is dropped
                // without a deliverySeq, so a quiet socket proves nothing.
                var attempt = 0
                while !Task.isCancelled {
                    let delay = min(accountedReadMaxSeconds, accountedReadInitialSeconds * pow(2.0, Double(attempt)))
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    request.yield(())
                }
                return nil
            }
            group.addTask {
                for await _ in requests {
                    try Task.checkCancellation()
                    do {
                        let current = try await self.deps.getOrder(self.objectId, orderId)
                        guard current.order.id.rawValue == orderId else { continue }
                        if try await self.isAccounted(current, orderId: orderId, operationId: operationId) {
                            return current
                        }
                    } catch let error as ArcaError {
                        if case .operationFailed = error { throw error }
                        // Transient read failure: the next trigger re-reads.
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Transient read failure: the next trigger re-reads.
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
                throw ArcaError.unknown(code: "TIMEOUT", message: "Order accounting timed out", errorId: nil)
            }
            while let candidate = try await group.next() { if let candidate { return candidate } }
            throw ArcaError.unknown(code: "STREAM_ENDED", message: "Order accounting evidence unavailable", errorId: nil)
        }
        // Completion was established by a read. The account push for this
        // commit travels a different path (the mirror relay) from the
        // `fill.recorded` push that may have triggered the read, so seeing one
        // proves nothing about the other: always nudge the account watch. Its
        // re-read coalesces with any push-triggered read already in flight.
        deps.exchangeStateChanged?(objectId)
        return detail
    }

    /// Completion check with the venue-read fallback: when the order read
    /// does not carry the platform's accounting view, the platform-recorded
    /// fills for the order must cover its executed size exactly (a zero-fill
    /// terminal order is trivially covered).
    private func isAccounted(_ detail: SimOrderWithFills, orderId: String, operationId: String) async throws -> Bool {
        if let complete = detail.fillsComplete { return complete }
        switch detail.order.status {
        case .filled, .cancelled, .failed: break
        default: return false
        }
        let executed = detail.order.filledSize
        if Self.recordedSizesCover([], executed) { return true }
        let recorded = try await deps.listFills(objectId)
        let sizes = recorded.fills
            .filter { $0.operationId?.isEmpty == false && ($0.orderId == orderId || $0.orderOperationId == operationId) }
            .compactMap { $0.size }
        return !sizes.isEmpty && Self.recordedSizesCover(sizes, executed)
    }

    /// Whether a platform-recorded fill belongs to this order. Recorded fills
    /// carry the venue order id and the placement operation id; a
    /// bracket child that was still pending when it filled is matched by the
    /// latter.
    static func recordedFillMatches(_ fill: Fill, orderId: String, operationId: String) -> Bool {
        if let id = fill.orderId, !id.isEmpty, id == orderId { return true }
        if let op = fill.orderOperationId, !op.isEmpty, op == operationId { return true }
        return false
    }

    /// Exact decimal comparison: the recorded sizes must sum to the executed
    /// size. Sizes cross the wire as decimal strings and never round-trip
    /// through a binary float here — `0.1 + 0.2` must cover `0.3`.
    static func recordedSizesCover(_ sizes: [String], _ executed: String) -> Bool {
        guard let expected = OrderExecutionReceipt.decimal(executed) else { return false }
        var total = Decimal.zero
        for raw in sizes {
            guard var size = OrderExecutionReceipt.decimal(raw) else { return false }
            var next = Decimal.zero
            guard NSDecimalAdd(&next, &total, &size, .plain) == .noError else { return false }
            total = next
        }
        return total == expected
    }

    /// Wait for the order to be fully filled.
    ///
    /// Resolves execution evidence, then reads complete order metadata.
    /// Fill history completeness is reported separately by the response.
    ///
    /// - Parameter timeoutSeconds: Maximum wait time (default: 30 seconds).
    /// - Returns: The order with all its fills.
    public func filled(timeoutSeconds: TimeInterval = 30) async throws -> SimOrderWithFills {
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
