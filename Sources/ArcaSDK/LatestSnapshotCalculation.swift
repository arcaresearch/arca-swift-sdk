import Foundation

/// One active calculation and one replaceable pending snapshot. Completing
/// active work (instead of cancelling it on every tick) guarantees progress
/// under sustained input. Only use for derived snapshots, never event history.
final class LatestSnapshotCalculation<Input: Sendable, Output: Sendable>: Sendable {
    private let continuation: AsyncStream<Input>.Continuation
    private let worker: Task<Void, Never>

    init(
        calculate: @escaping @Sendable (Input) async -> Output,
        publish: @escaping @Sendable (Input, Output) -> Void
    ) {
        let (stream, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        worker = Task.detached(priority: .utility) {
            for await input in stream {
                guard !Task.isCancelled else { break }
                let output = await calculate(input)
                guard !Task.isCancelled else { break }
                publish(input, output)
            }
        }
    }

    func submit(_ input: Input) { continuation.yield(input) }
    func stop() { continuation.finish(); worker.cancel() }
    deinit { continuation.finish(); worker.cancel() }
}
