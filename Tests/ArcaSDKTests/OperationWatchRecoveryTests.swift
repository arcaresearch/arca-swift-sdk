import XCTest
@testable import ArcaSDK

final class OperationWatchRecoveryTests: XCTestCase {
    private var arca: Arca!
    private var factory: MockTransportFactory!
    private var ackTask: Task<Void, Never>?
    private let acknowledge = SendableBox(true)
    private let lastAck = SendableBox<String?>(nil)
    private let snapshotOperations = SendableBox("[]"), bufferedOperations = SendableBox("[]")
    override func setUp() {
        super.setUp()
        OperationHistoryProtocol.reads.update { $0 = 0 }
        OperationHistoryProtocol.failures.update { $0 = 0 }
        OperationHistoryProtocol.state.update { $0 = "pending" }
        acknowledge.update { $0 = true }; lastAck.update { $0 = nil }
        snapshotOperations.update { $0 = "[]" }; bufferedOperations.update { $0 = "[]" }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OperationHistoryProtocol.self]
        arca = try! Arca(token: "test", baseURL: URL(string: "http://operation-watch.test")!, realmId: "realm", urlSessionConfiguration: config)
        factory = MockTransportFactory()
    }
    override func tearDown() {
        ackTask?.cancel()
        let ws = arca.ws; Task { await ws.disconnect() }
        arca = nil; super.tearDown()
    }
    private func start() async {
        await arca.ws.setTransportFactory(factory.make())
        let factory = factory!, acknowledge = acknowledge, lastAck = lastAck, snapshotOperations = snapshotOperations, bufferedOperations = bufferedOperations
        ackTask = Task {
            var seen = Set<String>()
            while !Task.isCancelled {
                for (index, socket) in factory.created.enumerated() {
                    for raw in socket.sent where seen.insert("\(index):\(raw)").inserted {
                        let json = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                        if json["action"] as? String == "auth" { socket.deliver(#"{"type":"authenticated"}"#) }
                        if json["action"] as? String == "watch" {
                            let body: [String: Any] = ["type": "watch_snapshot", "path": json["path"]!, "requestId": json["requestId"]!,
                                "operations": try! JSONSerialization.jsonObject(with: Data(snapshotOperations.value.utf8)),
                                "bufferedOperations": try! JSONSerialization.jsonObject(with: Data(bufferedOperations.value.utf8))]
                            let ack = String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
                            lastAck.update { $0 = ack }
                            if acknowledge.value { socket.deliver(ack) }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2.5)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { XCTFail("Condition did not become true", file: file, line: line); throw CancellationError() }
    }
    func testTerminalSnapshotAndBufferedTransitionsCompleteWithoutHTTP() async throws {
        await start(); OperationHistoryProtocol.failures.update { $0 = 99 }
        for state in ["completed", "failed", "expired"] {
            for buffered in [false, true] {
                let rows = [OperationHistoryProtocol.operation("completed", id: "foreign"), OperationHistoryProtocol.operation(buffered ? "pending" : state)]
                snapshotOperations.update { $0 = String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)! }
                bufferedOperations.update { $0 = String(data: try! JSONSerialization.data(withJSONObject: buffered ? [OperationHistoryProtocol.operation(state)] : []), encoding: .utf8)! }
                do {
                    let operation = try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3)
                    XCTAssertEqual(state, "completed"); XCTAssertEqual(operation.id.rawValue, "op")
                } catch ArcaError.operationFailed(let operation) {
                    XCTAssertNotEqual(state, "completed"); XCTAssertEqual(operation.state.rawValue, state)
                }
                XCTAssertEqual(OperationHistoryProtocol.reads.value, 0, "Terminal snapshot must precede HTTP recovery")
            }
        }
    }
    func testStaleSnapshotAndForeignTerminalCannotCompleteWait() async throws {
        acknowledge.update { $0 = false }; await start()
        let arca = arca!
        let waiting = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
        try await waitFor { lastAck.value != nil }; try await Task.sleep(nanoseconds: 30_000_000)
        var ack = try JSONSerialization.jsonObject(with: Data(lastAck.value!.utf8)) as! [String: Any]
        var stale = ack
        stale["requestId"] = "stale-request"
        stale["operations"] = [OperationHistoryProtocol.operation("completed")]
        factory.socket(0)!.deliver(String(data: try JSONSerialization.data(withJSONObject: stale), encoding: .utf8)!)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 0)
        ack["operations"] = [OperationHistoryProtocol.operation("pending")]
        ack["bufferedOperations"] = [OperationHistoryProtocol.operation("failed", id: "foreign")]
        factory.socket(0)!.deliver(String(data: try JSONSerialization.data(withJSONObject: ack), encoding: .utf8)!)
        try await waitFor { OperationHistoryProtocol.reads.value == 1 }
        factory.socket(0)!.deliver(Self.event(operation: OperationHistoryProtocol.operation("completed")))
        let result = try await waiting.value
        XCTAssertEqual(result.id.rawValue, "op"); XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(OperationHistoryProtocol.reads.value, 1)
    }
    func testRotationRequiresFreshReplacementSnapshotForTerminalEvidence() async throws {
        acknowledge.update { $0 = false }; await start()
        func request(_ socket: MockWebSocketTransport) -> [String: Any]? {
            socket.sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .last { $0["action"] as? String == "watch" }
        }
        func snapshot(_ watch: [String: Any], state: String) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["type": "watch_snapshot", "path": "/", "requestId": watch["requestId"]!,
                "operations": [OperationHistoryProtocol.operation("pending")], "bufferedOperations": [OperationHistoryProtocol.operation(state)]]), encoding: .utf8)!
        }
        for healthy in [false, true] {
            for state in ["completed", "failed", "expired"] {
                let before = OperationHistoryProtocol.reads.value
                let oldIndex = max(0, factory.count - 1)
                let oldRequest = factory.socket(oldIndex).flatMap { request($0)?["requestId"] as? String }
                let completed = SendableBox(false), arca = arca!
                let waiting = Task {
                    defer { completed.update { $0 = true } }
                    return try await arca.waitForOperation(operationId: "op", timeoutSeconds: 4)
                }
                defer { waiting.cancel() }
                try await waitFor { self.factory.socket(oldIndex).flatMap { request($0)?["requestId"] as? String }.map { $0 != oldRequest } ?? false }
                try await Task.sleep(nanoseconds: 30_000_000)
                let original = factory.socket(oldIndex)!
                if healthy {
                    original.deliver(try snapshot(request(original)!, state: "pending"))
                    try await waitFor { OperationHistoryProtocol.reads.value == before + 1 }
                }
                let started = await arca.ws.rotateConnection(); XCTAssertTrue(started)
                try await waitFor { self.factory.count == oldIndex + 2 }
                let replacement = factory.socket(oldIndex + 1)!
                try await waitFor { replacement.sentActions.contains("ping") }
                let warming = request(replacement)!
                replacement.deliver(try snapshot(warming, state: state))
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertFalse(completed.value, "Warming traffic cannot complete a live wait")
                replacement.deliver(#"{"type":"pong"}"#)
                try await waitFor { request(replacement)?["requestId"] as? String != warming["requestId"] as? String }
                try await Task.sleep(nanoseconds: 30_000_000)
                replacement.deliver(try snapshot(warming, state: state))
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertFalse(completed.value, "Pong and stale snapshots carry no fresh payload")
                XCTAssertEqual(OperationHistoryProtocol.reads.value, before + (healthy ? 1 : 0))
                replacement.deliver(try snapshot(request(replacement)!, state: state))
                do {
                    let result = try await waiting.value
                    XCTAssertEqual(state, "completed"); XCTAssertEqual(result.id.rawValue, "op")
                } catch ArcaError.operationFailed(let operation) {
                    XCTAssertNotEqual(state, "completed"); XCTAssertEqual(operation.state.rawValue, state)
                }
                XCTAssertEqual(OperationHistoryProtocol.reads.value, before + (healthy ? 1 : 0), "Terminal replacement payload must not GET")
            }
        }
    }
    func testSharedSnapshotCompletesOtherWaiterAndPreservesOwner() async throws {
        await start()
        let arca = arca!
        for state in ["completed", "failed", "expired"] {
            let before = OperationHistoryProtocol.reads.value
            acknowledge.update { $0 = true }
            let a = Task { try await arca.waitForOperation(operationId: "op", timeoutSeconds: 3) }
            defer { a.cancel() }
            try await waitFor { OperationHistoryProtocol.reads.value == before + 1 }
            acknowledge.update { $0 = false }
            let old = lastAck.value, bDone = SendableBox(false)
            let b = Task { let result = try await arca.waitForOperation(operationId: "op-b", timeoutSeconds: 3); bDone.update { $0 = true }; return result }
            defer { b.cancel() }
            try await waitFor { lastAck.value != old }; try await Task.sleep(nanoseconds: 30_000_000)
            var ack = try JSONSerialization.jsonObject(with: Data(lastAck.value!.utf8)) as! [String: Any]
            ack["operations"] = [OperationHistoryProtocol.operation("pending", id: "op-b")]
            ack["bufferedOperations"] = [OperationHistoryProtocol.operation(state)]
            factory.socket(0)!.deliver(String(data: try JSONSerialization.data(withJSONObject: ack), encoding: .utf8)!)
            do {
                let result = try await a.value
                XCTAssertEqual(state, "completed"); XCTAssertEqual(result.id.rawValue, "op")
            } catch ArcaError.operationFailed(let operation) {
                XCTAssertNotEqual(state, "completed"); XCTAssertEqual(operation.state.rawValue, state)
            }
            try await waitFor { OperationHistoryProtocol.reads.value == before + 2 }
            XCTAssertFalse(bDone.value)
            factory.socket(0)!.deliver(Self.event(operation: OperationHistoryProtocol.operation("completed", id: "op-b")))
            let result = try await b.value; XCTAssertEqual(result.id.rawValue, "op-b")
            XCTAssertEqual(OperationHistoryProtocol.reads.value, before + 2)
        }
    }
    func testFreshAckPrecedesSnapshotAndHealthyPendingOnlyRecoversAfterActualGap() async throws {
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
    func testFailedSnapshotsHaveFiniteBudgetAndLiveTerminalStillCompletes() async throws {
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
