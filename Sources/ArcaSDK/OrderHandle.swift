import Foundation

/// Dependencies injected into ``OrderHandle`` from the ``Arca`` client.
public struct OrderHandleDeps: Sendable {
    let getOrder: @Sendable (String, String) async throws -> SimOrderWithFills
    let fillEvents: @Sendable () async -> AsyncStream<(SimFill, RealmEvent)>
    let cancelOrder: @Sendable (String, String, String) -> OperationHandle<OrderOperationResponse>
    let waitForSettlement: @Sendable (String) async throws -> Operation
}

/// Handle for exchange order lifecycle.
///
/// Extends the ``OperationHandle`` pattern with order-specific methods
/// for waiting on fills, streaming fills, and cancelling.
///
/// ```swift
/// let order = arca.placeOrder(path: "/op/order/btc-1", objectId: id, ...)
/// try await order.settled  // wait for placement
///
/// let filled = try await order.filled(timeoutSeconds: 30)
///
/// for try await fill in order.fills() {
///     print("Filled \(fill.size) @ \(fill.price)")
/// }
///
/// try await order.cancel().settled
/// ```
public final class OrderHandle: @unchecked Sendable {
    private let inner: OperationHandle<OrderOperationResponse>
    private let objectId: String
    private let placementPath: String
    private let deps: OrderHandleDeps

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

    /// The HTTP response (before settlement).
    public var submitted: OrderOperationResponse {
        get async throws { try await inner.submitted }
    }

    /// Wait for full operation settlement (order placement confirmed).
    public var settled: OrderOperationResponse {
        get async throws { try await inner.settled }
    }

    /// Wait for settlement with an explicit timeout.
    public func settled(timeoutSeconds: TimeInterval) async throws -> OrderOperationResponse {
        try await inner.settled(timeoutSeconds: timeoutSeconds)
    }

    /// Wait for the order to be fully filled.
    ///
    /// Polls the order state after settlement, returning the order with
    /// all its fills once the status is `filled`.
    ///
    /// - Parameter timeoutSeconds: Maximum wait time (default: 30 seconds).
    /// - Returns: The order with all its fills.
    public func filled(timeoutSeconds: TimeInterval = 30) async throws -> SimOrderWithFills {
        _ = try await inner.settled

        let orderId = try await resolveOrderId()

        return try await withThrowingTaskGroup(of: SimOrderWithFills.self) { group in
            group.addTask {
                let detail = try await self.deps.getOrder(self.objectId, orderId)
                if detail.order.isTerminalWithFills { return detail }
                try Self.throwIfTerminalWithoutFills(detail.order, orderId: orderId)

                let fillStream = await self.deps.fillEvents()
                for await (_, _) in fillStream {
                    let detail = try await self.deps.getOrder(self.objectId, orderId)
                    if detail.order.isTerminalWithFills { return detail }
                    try Self.throwIfTerminalWithoutFills(detail.order, orderId: orderId)
                }
                throw ArcaError.unknown(
                    code: "STREAM_ENDED",
                    message: "Fill event stream ended before order was filled",
                    errorId: nil
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ArcaError.unknown(
                    code: "TIMEOUT",
                    message: "Order fill timed out after \(Int(timeoutSeconds))s",
                    errorId: nil
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
    public func fills(timeoutSeconds: TimeInterval = 300) -> AsyncThrowingStream<SimFill, Error> {
        let objectId = self.objectId
        let inner = self.inner
        let deps = self.deps

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await inner.submitted
                    let orderId = response.operation.outcome ?? ""
                    guard !orderId.isEmpty else {
                        continuation.finish(throwing: ArcaError.unknown(
                            code: "NO_ORDER_ID",
                            message: "Operation outcome does not contain an order ID",
                            errorId: nil
                        ))
                        return
                    }

                    let fillStream = await deps.fillEvents()
                    for await (fill, _) in fillStream {
                        if fill.orderId.rawValue == orderId {
                            continuation.yield(fill)

                            let detail = try await deps.getOrder(objectId, orderId)
                            if detail.order.status == .filled ||
                               detail.order.status == .cancelled ||
                               detail.order.status == .failed {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if !task.isCancelled {
                    continuation.finish(throwing: ArcaError.unknown(
                        code: "TIMEOUT",
                        message: "Fill stream timed out after \(Int(timeoutSeconds))s",
                        errorId: nil
                    ))
                    task.cancel()
                }
            }
        }
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
                let response = try await inner.submitted
                let orderId = response.operation.outcome ?? ""
                guard !orderId.isEmpty else { return }

                let fillStream = await deps.fillEvents()
                for await (fill, _) in fillStream {
                    if fill.orderId.rawValue == orderId {
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
                let orderId = response.operation.outcome ?? ""
                guard !orderId.isEmpty else {
                    throw ArcaError.unknown(
                        code: "NO_ORDER_ID",
                        message: "Cannot cancel: operation outcome does not contain an order ID",
                        errorId: nil
                    )
                }
                let cancelHandle = deps.cancelOrder(cancelPath, objectId, orderId)
                return try await cancelHandle.submitted
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
        case .cancelled where order.filledSize == "0" || order.filledSize.isEmpty:
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
        let response = try await inner.submitted
        let orderId = response.operation.outcome ?? ""
        guard !orderId.isEmpty else {
            throw ArcaError.unknown(
                code: "NO_ORDER_ID",
                message: "Operation outcome does not contain an order ID",
                errorId: nil
            )
        }
        return orderId
    }
}
