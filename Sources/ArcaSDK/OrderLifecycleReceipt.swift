import Foundation

/// Execution and accounting semantics are projected by the shared Go owner.
public struct OrderLifecycleReceipt: Codable, Sendable, Equatable {
    public let objectId: String
    public let operationId: String
    public let leg: String
    public let market: String
    public let orderId: String
    public let status: String
    public let filledSize: String
    public let requestedSize: String?
    public let remainingSize: String?
    public let executionState: String
    public let fulfillmentState: String
    public let remainingDisposition: String
    public let avgFillPrice: String?
    public let averagePriceFinal: Bool
    public let averagePriceSource: String
    public let fillsComplete: Bool

    var receipt: OrderExecutionReceipt {
        OrderExecutionReceipt(objectId: objectId, operationId: operationId, orderId: orderId,
            status: status, filledSize: filledSize, requestedSize: requestedSize, remainingSize: remainingSize,
            executionState: executionState, fulfillmentState: fulfillmentState, remainingDisposition: remainingDisposition,
            avgFillPrice: avgFillPrice, averagePriceFinal: averagePriceFinal, averagePriceSource: averagePriceSource,
            fillsComplete: fillsComplete)
    }
}

// Cancellation ends this wait without canceling or repeating the independently
// admitted submission. A late HTTP response cannot attach a canceled reader.
func withOrderLifecycleDeadline<T: Sendable>(_ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard seconds.isFinite, seconds > 0 else {
        throw ArcaError.validation(message: "A positive order wait timeout is required", errorId: nil)
    }
    let (stream, continuation) = AsyncThrowingStream<T, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let worker = Task {
        do {
            let value = try await operation()
            try Task.checkCancellation()
            continuation.yield(value); continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    let timer = Task {
        do {
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
            continuation.finish(throwing: ArcaError.unknown(code: "TIMEOUT", message: "Original order wait timed out", errorId: nil))
        } catch { }
    }
    continuation.onTermination = { _ in worker.cancel(); timer.cancel() }
    defer { worker.cancel(); timer.cancel(); continuation.finish() }
    for try await result in stream { return result }
    throw CancellationError()
}
