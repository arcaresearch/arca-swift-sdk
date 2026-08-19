import Foundation

/// The slice of `URLSessionWebSocketTask` the manager drives.
///
/// A rotation runs two sockets at the same time, so everything interesting
/// about it is a question of which socket a frame arrived on and in what
/// order — something `URLSession` gives no way to stage. This protocol is the
/// seam that lets a test supply that ordering directly; production always uses
/// the `URLSessionWebSocketTask` conformance below.
protocol WebSocketTransport: AnyObject {
    func start()
    func stop(reason: String?)
    func sendText(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    func receiveMessage() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: WebSocketTransport {
    func start() {
        resume()
    }

    func stop(reason: String?) {
        cancel(with: .goingAway, reason: reason?.data(using: .utf8))
    }

    func sendText(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        send(.string(text), completionHandler: completion)
    }

    func receiveMessage() async throws -> URLSessionWebSocketTask.Message {
        try await receive()
    }
}
