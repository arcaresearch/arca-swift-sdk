import XCTest
@testable import ArcaSDK

/// Operation waits used to hold a realm-root watch: every wait assembled a
/// full-realm snapshot (a realm-wide operations scan) and put every realm
/// event on the socket. They now subscribe to operation events by type and
/// use the server's acknowledgement of that subscription as the barrier
/// before their read.
final class OperationWatchRecoveryTests: XCTestCase {
    private var arca: Arca!
    private var factory: MockTransportFactory!
    private var ackTask: Task<Void, Never>?
    private let acknowledge = SendableBox(true)
    private let lastAck = SendableBox<String?>(nil)
    override func setUp() {
        super.setUp()
        OperationHistoryProtocol.reads.update { $0 = 0 }
        OperationHistoryProtocol.failures.update { $0 = 0 }
        OperationHistoryProtocol.state.update { $0 = "pending" }
        acknowledge.update { $0 = true }; lastAck.update { $0 = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OperationHistoryProtocol.self]
        arca = try! Arca(token: "test", baseURL: URL(string: "http://operation-watch.test")!, realmId: "realm", urlSessionConfiguration: config)
        factory = MockTransportFactory()
    }
    override func tearDown() {
        ackTask?.cancel()
        let ws = arca.ws; Task { await ws.disconnect() }
        arca = nil; super.tearDown()
    }
    /// Authenticates every socket and answers acknowledged subscriptions on
    /// the primary (warming sockets are answered by the tests themselves).
    private func start() async {
        await arca.ws.setTransportFactory(factory.make())
        let factory = factory!, acknowledge = acknowledge, lastAck = lastAck
        ackTask = Task {
            var seen = Set<String>()
            while !Task.isCancelled {
                for (index, socket) in factory.created.enumerated() {
                    for raw in socket.sent where seen.insert("\(index):\(raw)").inserted {
                        let json = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                        if json["action"] as? String == "auth" { socket.deliver(#"{"type":"authenticated"}"#) }
                        if json["action"] as? String == "subscribe_events", let requestId = json["requestId"] as? String, index == 0 {
                            let ack = Self.ack(requestId: requestId, types: json["types"])
                            lastAck.update { $0 = ack }
                            if acknowledge.value { socket.deliver(ack) }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
    private static func ack(requestId: String, types: Any?) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["type": "events_subscribed", "requestId": requestId, "types": types ?? []]), encoding: .utf8)!
    }
    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2.5)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { XCTFail("Condition did not become true", file: file, line: line); throw CancellationError() }
    }
    private static func messages(_ socket: MockWebSocketTransport) -> [[String: Any]] {
        socket.sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    private static func confirmation(_ socket: MockWebSocketTransport) -> [String: Any]? {
        messages(socket).last { $0["action"] as? String == "subscribe_events" && $0["requestId"] != nil }
    }

    func testSubscribesToOperationEventsByTypeAndNeverWatchesTheRoot() async throws {
        await start(); OperationHistoryProtocol.state.update { $0 = "completed" }
        let result = try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3)
        XCTAssertEqual(result.state, .completed)
        let socket = factory.socket(0)!
        XCTAssertFalse(socket.sentActions.contains("watch"))
        let types = Set(Self.confirmation(socket)?["types"] as? [String] ?? [])
        XCTAssertEqual(types, ["operation.created", "operation.updated"])
        try await waitFor { socket.sentActions.contains("unsubscribe_events") }
    }

    func testStaleAcknowledgementCannotReleaseTheRead() async throws {
        acknowledge.update { $0 = false }; await start()
        let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
        try await waitFor { lastAck.value != nil }
        factory.socket(0)!.deliver(Self.ack(requestId: "stale-request", types: ["operation.created", "operation.updated"]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 0)
        factory.socket(0)!.deliver(lastAck.value!)
        try await waitFor { OperationHistoryProtocol.reads.value == 1 }
        factory.socket(0)!.deliver(Self.event(operation: OperationHistoryProtocol.operation("completed")))
        let result = try await waiting.value
        XCTAssertEqual(result.id.rawValue, "op"); XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 1)
    }

    func testRotationRequiresAFreshReplacementAcknowledgementCompleted() async throws { try await rotationCase("completed") }
    func testRotationRequiresAFreshReplacementAcknowledgementFailed() async throws { try await rotationCase("failed") }
    func testRotationRequiresAFreshReplacementAcknowledgementExpired() async throws { try await rotationCase("expired") }

    private func rotationCase(_ state: String) async throws {
        do {
            acknowledge.update { $0 = false }; await start()
            let arca = arca!
            let completed = SendableBox(false)
            let waiting = Task {
                defer { completed.update { $0 = true } }
                return try await arca.waitForOperation(operationId: "op", timeoutSeconds: 4)
            }
            try await waitFor { lastAck.value != nil }
            factory.socket(0)!.deliver(lastAck.value!)
            try await waitFor { OperationHistoryProtocol.reads.value == 1 }
            OperationHistoryProtocol.state.update { $0 = state }
            let started = await arca.ws.rotateConnection(); XCTAssertTrue(started)
            try await waitFor { self.factory.count == 2 }
            let replacement = factory.socket(1)!
            try await waitFor { replacement.sentActions.contains("ping") }
            let warming = Self.confirmation(replacement)!
            replacement.deliver(Self.ack(requestId: warming["requestId"] as! String, types: warming["types"]))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(OperationHistoryProtocol.reads.value, 1, "Warming traffic cannot release a read")
            replacement.deliver(#"{"type":"pong"}"#)
            try await waitFor { Self.confirmation(replacement)?["requestId"] as? String != warming["requestId"] as? String }
            replacement.deliver(Self.ack(requestId: warming["requestId"] as! String, types: warming["types"]))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(OperationHistoryProtocol.reads.value, 1, "A stale acknowledgement is not a fresh barrier")
            let fresh = Self.confirmation(replacement)!
            replacement.deliver(Self.ack(requestId: fresh["requestId"] as! String, types: fresh["types"]))
            do {
                let result = try await waiting.value
                XCTAssertEqual(state, "completed"); XCTAssertEqual(result.id.rawValue, "op")
            } catch ArcaError.operationFailed(let operation) {
                XCTAssertNotEqual(state, "completed"); XCTAssertEqual(operation.state.rawValue, state)
            }
            XCTAssertTrue(completed.value)
            XCTAssertEqual(OperationHistoryProtocol.reads.value, 2)
        }
    }

    /// Another owner's realm-root watch snapshot still carries terminal
    /// evidence the wait accepts without a read.
    func testAnotherRootOwnersSnapshotCompletesTheWait() async throws {
        acknowledge.update { $0 = false }; await start()
        let arca = arca!
        await arca.ws.watchPath("/")
        try await waitFor { self.factory.socket(0).map { Self.messages($0).contains { $0["action"] as? String == "watch" && $0["requestId"] != nil } } ?? false }
        let connected = SendableBox(false)
        while !connected.value { let status = await arca.ws.status; connected.update { $0 = status == .connected }; try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let watch = Self.messages(factory.socket(0)!).last { $0["action"] as? String == "watch" && $0["requestId"] != nil }!
        for state in ["completed", "failed", "expired"] {
            let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
            try await Task.sleep(nanoseconds: 30_000_000)
            let body: [String: Any] = ["type": "watch_snapshot", "path": "/", "requestId": watch["requestId"]!,
                "operations": [OperationHistoryProtocol.operation("completed", id: "foreign"), OperationHistoryProtocol.operation("pending")],
                "bufferedOperations": [OperationHistoryProtocol.operation(state)]]
            factory.socket(0)!.deliver(String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
            do {
                let result = try await waiting.value
                XCTAssertEqual(state, "completed"); XCTAssertEqual(result.id.rawValue, "op")
            } catch ArcaError.operationFailed(let operation) {
                XCTAssertNotEqual(state, "completed"); XCTAssertEqual(operation.state.rawValue, state)
            }
            XCTAssertEqual(OperationHistoryProtocol.reads.value, 0, "Shared terminal evidence must not GET")
        }
        await arca.ws.unwatchPath("/")
    }

    func testFreshAckPrecedesReadAndHealthyPendingOnlyRecoversAfterActualGap() async throws {
        acknowledge.update { $0 = false }; await start()
        let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 6) }
        try await waitFor { lastAck.value != nil }; try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 0)
        acknowledge.update { $0 = true }; factory.socket(0)!.deliver(lastAck.value!)
        try await waitFor { OperationHistoryProtocol.reads.value == 1 }
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 1, "Healthy pending operations cannot poll")
        OperationHistoryProtocol.state.update { $0 = "completed" }
        await arca.ws.injectMessage(#"{"type":"stream.resync"}"#)
        let result = try await waiting.value; XCTAssertEqual(result.id.rawValue, "op")
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 2)
    }

    func testFailedReadsHaveFiniteBudgetAndLiveTerminalStillCompletes() async throws {
        await start(); OperationHistoryProtocol.failures.update { $0 = 9 }
        let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 6) }
        try await waitFor { OperationHistoryProtocol.reads.value == 3 }
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 3)
        await arca.ws.injectMessage(Self.event(operation: OperationHistoryProtocol.operation("completed")))
        let result = try await waiting.value; XCTAssertEqual(result.id.rawValue, "op")
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 3)
    }

    func testSparseOperationNotificationRecoversButForeignPayloadDoesNot() async throws {
        await start(); let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
        try await waitFor { OperationHistoryProtocol.reads.value == 1 }
        await arca.ws.injectMessage(Self.event(operation: OperationHistoryProtocol.operation("completed", id: "foreign")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 1)
        OperationHistoryProtocol.state.update { $0 = "completed" }
        await arca.ws.injectMessage(#"{"type":"operation.updated","entityId":"op"}"#)
        let result = try await waiting.value; XCTAssertEqual(result.id.rawValue, "op")
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 2)
    }

    func testTerminalPushBeatsMissingAcknowledgement() async throws {
        acknowledge.update { $0 = false }; await start()
        let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
        try await waitFor { lastAck.value != nil }
        let pushedAt = Date()
        await arca.ws.injectMessage(Self.event(operation: OperationHistoryProtocol.operation("completed")))
        let result = try await waiting.value
        XCTAssertEqual(result.id.rawValue, "op")
        XCTAssertLessThan(Date().timeIntervalSince(pushedAt), 0.5)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 0)
    }

    private static func event(operation: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["type": "operation.updated", "entityId": "op", "operation": operation]), encoding: .utf8)!
    }
}

private final class OperationHistoryProtocol: URLProtocol {
    static let reads = SendableBox(0), failures = SendableBox(0)
    static let state = SendableBox("pending")
    static func operation(_ state: String, id: String = "op") -> [String: Any] {
        ["id": id, "realmId": "realm", "path": "/op", "type": "order", "state": state, "createdAt": "2026-01-01", "updatedAt": "2026-01-01"]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "operation-watch.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.reads.update { $0 += 1 }
        var failing = false
        Self.failures.update { if $0 > 0 { $0 -= 1; failing = true } }
        let body: [String: Any] = failing ? ["success": false, "error": ["code": "VALIDATION", "message": "fixture failure"]] : ["success": true, "data": ["operation": Self.operation(Self.state.value, id: request.url!.lastPathComponent), "events": [], "deltas": []]]
        let response = HTTPURLResponse(url: request.url!, statusCode: failing ? 422 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
