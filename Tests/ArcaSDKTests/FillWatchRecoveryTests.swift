import XCTest
@testable import ArcaSDK

final class FillWatchRecoveryTests: XCTestCase {
    private var arca: Arca!
    private var factory: MockTransportFactory!
    private var ackTask: Task<Void, Never>?
    override func setUp() {
        super.setUp()
        FillHistoryProtocol.handler.update { $0 = { _ in (["fills": [], "total": 0], nil) } }
        FillHistoryProtocol.reads.update { $0 = 0 }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FillHistoryProtocol.self]
        arca = try! Arca(token: "test", baseURL: URL(string: "http://fill-watch.test")!, realmId: "realm", urlSessionConfiguration: config)
        factory = MockTransportFactory()
    }
    override func tearDown() {
        ackTask?.cancel()
        let ws = arca.ws
        Task { await ws.disconnect() }
        arca = nil
        super.tearDown()
    }
    private func startAcks() async {
        await arca.ws.setTransportFactory(factory.make())
        let factory = factory!
        ackTask = Task {
            var seen = Set<String>()
            while !Task.isCancelled {
                for socket in factory.created {
                    for raw in socket.sent where seen.insert(raw).inserted {
                        let json = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                        if json["action"] as? String == "auth" { socket.deliver(#"{"type":"authenticated"}"#) }
                        if json["action"] as? String == "watch" {
                            let body: [String: Any] = ["type": "watch_snapshot", "path": json["path"]!, "requestId": json["requestId"]!]
                            socket.deliver(String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    func testPaginationRetainsLiveFillDuringSnapshotAndFiltersForeignAccount() async throws {
        await startAcks()
        let ws = arca.ws
        FillHistoryProtocol.handler.update { handler in handler = { url in
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "cursor" }?.value
            if cursor == nil {
                return (["fills": (0..<200).map { Self.row("row\($0)") }, "total": 201, "cursor": "next"], {
                    await ws.injectMessage(Self.event("live"))
                    await ws.injectMessage(Self.event("foreign", account: "another"))
                })
            }
            return (["fills": [Self.row("row200")], "total": 201], nil)
        } }
        let stream = try await arca.watchFills(objectId: "account", limit: 200)
        try await waitFor { stream.fills.value.count == 202 }
        XCTAssertEqual(FillHistoryProtocol.reads.value, 2)
        XCTAssertFalse(stream.fills.value.contains { $0.id == "foreign" })
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(FillHistoryProtocol.reads.value, 2, "healthy watch must stay quiet")
        await stream.stop()
    }
    func testEmptyWatchRecoversOnQuietAuthenticationAndResyncWithoutPolling() async throws {
        await startAcks()
        let stream = try await arca.watchFills(objectId: "account")
        XCTAssertTrue(stream.fills.value.isEmpty)
        FillHistoryProtocol.handler.update { $0 = { _ in (["fills": [Self.row("quiet")], "total": 1], nil) } }
        await arca.ws.injectMessage(#"{"type":"authenticated"}"#)
        try await waitFor { stream.fills.value.contains { $0.id == "quiet" } }
        FillHistoryProtocol.handler.update { $0 = { _ in (["fills": [Self.row("gap")], "total": 1], nil) } }
        await arca.ws.injectMessage(#"{"type":"stream.resync"}"#)
        try await waitFor { stream.fills.value.contains { $0.id == "gap" } }
        let reads = FillHistoryProtocol.reads.value
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(FillHistoryProtocol.reads.value, reads)
        await stream.stop()
        await arca.ws.injectMessage(#"{"type":"stream.resync"}"#)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(FillHistoryProtocol.reads.value, reads)
    }
    func testRepeatedCursorExhaustsFiniteBudgetThenNewGapCanRecover() async throws {
        await startAcks()
        FillHistoryProtocol.handler.update { $0 = { _ in (["fills": [Self.row("old")], "total": 10, "cursor": "loop"], nil) } }
        let stream = try await arca.watchFills(objectId: "account")
        XCTAssertEqual(stream.state.value, .reconnecting)
        XCTAssertEqual(FillHistoryProtocol.reads.value, 6)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(FillHistoryProtocol.reads.value, 6)
        FillHistoryProtocol.handler.update { $0 = { _ in (["fills": [Self.row("recovered")], "total": 1], nil) } }
        await arca.ws.injectMessage(#"{"type":"stream.resync"}"#)
        try await waitFor { stream.fills.value.contains { $0.id == "recovered" } }
        XCTAssertEqual(stream.state.value, .connected)
        await stream.stop()
    }
    func testStableFillIdentityKeepsAllPartialExecutionsAndConflicts() throws {
        func decode(_ value: [String: Any]) throws -> Fill { try JSONDecoder().decode(Fill.self, from: JSONSerialization.data(withJSONObject: value)) }
        var preview1 = Self.row("one"), preview2 = Self.row("two")
        preview1.removeValue(forKey: "operationId"); preview2.removeValue(forKey: "operationId")
        var recorded = Self.row("ledger-one"); recorded["fillId"] = "one"
        var conflict = recorded; conflict["price"] = "101"
        let merged = mergeWatchedFills(try [decode(preview1), decode(preview2)], try [decode(recorded), decode(recorded), decode(conflict)])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.filter { $0.operationId == nil }.map(\.id), ["two"])
    }
    private static func row(_ id: String) -> [String: Any] {
        ["id": id, "fillId": id, "operationId": "fill-\(id)", "orderOperationId": "original", "orderId": "order", "market": "gll:test:1", "size": "1", "price": "100", "side": "buy"]
    }
    private static func event(_ id: String, account: String = "account") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["type": "fill.recorded", "entityId": id, "entityPath": "/" + account, "fill": row(id)]), encoding: .utf8)!
    }
}

private final class FillHistoryProtocol: URLProtocol {
    typealias Handler = @Sendable (URL) -> ([String: Any], (@Sendable () async -> Void)?)
    static let handler = SendableBox<Handler>({ _ in ([:], nil) })
    static let reads = SendableBox(0)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fill-watch.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data: [String: Any]
        var before: (@Sendable () async -> Void)?
        if url.path.hasSuffix("/fills") {
            Self.reads.update { $0 += 1 }
            (data, before) = Self.handler.value(url)
        } else {
            data = ["object": ["id": "account", "realmId": "realm", "path": "/account", "type": "exchange", "status": "active", "systemOwned": false, "createdAt": "2026-01-01", "updatedAt": "2026-01-01"], "operations": [], "events": [], "deltas": [], "balances": []]
        }
        let body = try! JSONSerialization.data(withJSONObject: ["success": true, "data": data])
        Task {
            await before?()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
