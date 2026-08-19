import Foundation
@testable import ArcaSDK

enum MockTransportError: Error {
    case closed
}

/// A socket the test drives frame by frame.
///
/// Rotation is only interesting when two sockets are live at once, so the
/// tests need to say exactly which socket a frame arrived on and in what
/// order — something `URLSession` gives no way to stage.
final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<URLSessionWebSocketTask.Message, any Error>] = []
    private var waiter: CheckedContinuation<Result<URLSessionWebSocketTask.Message, any Error>, Never>?
    private var _sent: [String] = []
    private var _started = false
    private var _stopped = false

    /// Leave a parked receive alive through `stop()` so a test can push the
    /// frame a real socket would still have had buffered when it was retired.
    var keepReceivingAfterStop = false

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    /// Outbound frames decoded into their `action` values, in send order.
    var sentActions: [String] {
        sent.compactMap {
            guard let data = $0.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["action"] as? String
        }
    }

    // MARK: - Driving

    func deliver(_ text: String) {
        push(.success(.string(text)))
    }

    /// Kill the socket, as an unexpected close would.
    func fail(_ error: any Error = MockTransportError.closed) {
        push(.failure(error))
    }

    private func push(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: result)
        } else {
            inbox.append(result)
            lock.unlock()
        }
    }

    // MARK: - WebSocketTransport

    func start() {
        lock.lock(); _started = true; lock.unlock()
    }

    func stop(reason: String?) {
        lock.lock()
        _stopped = true
        guard !keepReceivingAfterStop, let waiter else {
            lock.unlock()
            return
        }
        self.waiter = nil
        lock.unlock()
        waiter.resume(returning: .failure(MockTransportError.closed))
    }

    func sendText(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        let closed = _stopped
        if !closed { _sent.append(text) }
        lock.unlock()
        completion(closed ? MockTransportError.closed : nil)
    }

    func receiveMessage() async throws -> URLSessionWebSocketTask.Message {
        let result: Result<URLSessionWebSocketTask.Message, any Error> = await withCheckedContinuation { cont in
            lock.lock()
            if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                cont.resume(returning: next)
            } else if _stopped && !keepReceivingAfterStop {
                lock.unlock()
                cont.resume(returning: .failure(MockTransportError.closed))
            } else {
                waiter = cont
                lock.unlock()
            }
        }
        return try result.get()
    }
}

/// Hands out ``MockWebSocketTransport``s in creation order so a test can
/// address the original socket and its replacement separately.
final class MockTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [MockWebSocketTransport] = []

    var created: [MockWebSocketTransport] {
        lock.lock(); defer { lock.unlock() }
        return _created
    }

    var count: Int { created.count }

    func socket(_ index: Int) -> MockWebSocketTransport? {
        let all = created
        return index < all.count ? all[index] : nil
    }

    func make() -> @Sendable (URL) -> any WebSocketTransport {
        { [self] _ in
            let transport = MockWebSocketTransport()
            lock.lock()
            _created.append(transport)
            lock.unlock()
            return transport
        }
    }
}
