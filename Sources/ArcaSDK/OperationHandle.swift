import Foundation

// MARK: - OperationResponse Protocol

/// Protocol for response types that carry an Operation.
/// Conforming types can be used with ``OperationHandle``.
public protocol OperationResponse: Codable, Sendable {
    var operation: Operation { get }
    /// Create a copy of the response with the operation replaced.
    func withOperation(_ op: Operation) -> Self
}

// MARK: - OperationHandle

/// A handle returned synchronously from mutation methods.
///
/// The HTTP call starts immediately when the handle is created.
/// Use `settled` to wait for both submission and operation settlement,
/// or `submitted` to access the HTTP response before settlement.
///
/// ```swift
/// // Simple: one-liner await to settlement
/// try await arca.deposit(arcaRef: "/wallets/main", amount: "1000").settled
///
/// // Progressive disclosure
/// let deposit = arca.deposit(arcaRef: "/wallets/main", amount: "1000")
/// let response = try await deposit.submitted   // before settlement
/// try await deposit.settled                     // full settlement
/// try await deposit.settled(timeoutSeconds: 15)
///
/// // Batching
/// async let d1 = arca.deposit(arcaRef: "/wallets/main", amount: "500").settled
/// async let d2 = arca.deposit(arcaRef: "/wallets/savings", amount: "300").settled
/// let (r1, r2) = try await (d1, d2)
/// ```
public final class OperationHandle<Response: OperationResponse>: @unchecked Sendable {
    private let _submitted: Task<Response, Error>
    private let _settled: Task<Response, Error>

    init(
        submit: @escaping @Sendable () async throws -> Response,
        waitForSettlement: @escaping @Sendable (String) async throws -> Operation
    ) {
        let submitted = Task { try await submit() }
        self._submitted = submitted
        self._settled = Task {
            let response = try await submitted.value
            guard response.operation.state == .pending else { return response }
            let completed = try await waitForSettlement(response.operation.id.rawValue)
            return response.withOperation(completed)
        }
    }

    /// The HTTP response (before settlement).
    ///
    /// Resolves as soon as the server accepts the request.
    /// The operation may still be in `pending` state.
    public var submitted: Response {
        get async throws { try await _submitted.value }
    }

    /// Wait for full operation settlement.
    ///
    /// Resolves when the operation reaches a terminal state (`completed`,
    /// `failed`, or `expired`). Throws ``ArcaError/operationFailed(operation:)``
    /// if the terminal state is `failed` or `expired`.
    public var settled: Response {
        get async throws { try await _settled.value }
    }

    /// Wait for full operation settlement (discardable).
    ///
    /// Same as ``settled`` but marked `@discardableResult` so callers that
    /// only need to wait — without inspecting the response — avoid an
    /// "unused result" warning.
    @discardableResult
    public func settle() async throws -> Response {
        try await _settled.value
    }

    /// Wait for settlement with an explicit timeout.
    ///
    /// - Parameter timeoutSeconds: Maximum time to wait for settlement, in seconds.
    /// - Throws: ``ArcaError`` with code `TIMEOUT` if the deadline passes.
    public func settled(timeoutSeconds: TimeInterval) async throws -> Response {
        try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await self._settled.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ArcaError.unknown(
                    code: "TIMEOUT",
                    message: "Operation timed out after \(Int(timeoutSeconds))s",
                    errorId: nil
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
