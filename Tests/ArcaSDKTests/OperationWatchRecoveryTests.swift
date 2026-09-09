import XCTest
@testable import ArcaSDK

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
    private func start() async {
        await arca.ws.setTransportFactory(factory.make())
        let factory = factory!, acknowledge = acknowledge, lastAck = lastAck
        ackTask = Task {
            var seen = Set<String>()
            while !Task.isCancelled {
                for socket in factory.created {
                    for raw in socket.sent where seen.insert(raw).inserted {
                        let json = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                        if json["action"] as? String == "auth" { socket.deliver(#"{"type":"authenticated"}"#) }
                        if json["action"] as? String == "watch" {
                            let body: [String: Any] = ["type": "watch_snapshot", "path": json["path"]!, "requestId": json["requestId"]!]
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
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2.5)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { XCTFail("Condition did not become true"); throw CancellationError() }
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
        let body: [String: Any] = failing ? ["success": false, "error": ["code": "VALIDATION", "message": "fixture failure"]] : ["success": true, "data": ["operation": Self.operation(Self.state.value), "events": [], "deltas": []]]
        let response = HTTPURLResponse(url: request.url!, statusCode: failing ? 422 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
