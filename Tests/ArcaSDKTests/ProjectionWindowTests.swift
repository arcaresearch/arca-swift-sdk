import XCTest
@testable import ArcaSDK

/// Windowed projection figures and the projection stream's recovery paths:
/// re-marking moves `equity`, `unrealizedValue` and `pnl` by the position
/// P&L change only (unsettled funding and the baseline stay as delivered,
/// volume never moves), rows decode one by one, a replaced account at the
/// same path survives its frame, a delivery gap or server resync re-reads
/// the scope under the same watch, a failed re-create is retried, and
/// `stop()` ends `updates`.
final class ProjectionWindowTests: XCTestCase {

    // MARK: - Re-marking

    func testRemarkKeepsUnsettledFunding() throws {
        // equity 1047.5 = realized 1000 + position P&L 50 - unsettled funding 2.5
        let v = try row(#"""
        {"objectId": "obj_a", "path": "/users/alice", "type": "exchange",
         "equity": "1047.5", "realizedValue": "1000", "unrealizedValue": "50",
         "positions": [{"market": "hl:0:BTC", "side": "long", "size": "1", "entryPrice": "100",
                        "markPrice": "150", "unrealizedPnl": "50", "valueUsd": "50"}]}
        """#)
        let out = v.revalued(with: ["hl:0:BTC": "160"])
        XCTAssertEqual(out.equity, "1057.5", "funding owed stays owed when the mark moves")
        XCTAssertEqual(out.unrealizedValue, "60")
        XCTAssertEqual(out.realizedValue, "1000")
    }

    func testRemarkShiftsWindowedPnlButNeverVolume() throws {
        let v = try row(#"""
        {"objectId": "obj_a", "path": "/users/alice", "type": "exchange", "equity": "1000",
         "positions": [{"market": "hl:0:ETH", "side": "long", "size": "2", "entryPrice": "100",
                        "markPrice": "100", "unrealizedPnl": "0", "valueUsd": "0"}],
         "pnl": {"window": "30d", "from": "2026-10-01T00:00:00Z", "asOf": "2026-10-31T00:00:00Z",
                 "coverage": "full", "status": "complete", "pnlUsd": "12.5"},
         "volume": {"window": "30d", "from": "2026-10-01T00:00:00Z", "asOf": "2026-10-31T00:00:00Z",
                    "coverage": "full", "status": "complete", "volumeUsd": "3000"}}
        """#)
        let out = v.revalued(with: ["hl:0:ETH": "110"])
        XCTAssertEqual(out.pnl?.pnlUsd, "32.5")
        XCTAssertEqual(out.pnl?.from, "2026-10-01T00:00:00Z")
        XCTAssertEqual(out.volume?.volumeUsd, "3000", "a price move is not volume")
        XCTAssertEqual(out.equity, "1020")
    }

    func testRemarkIsExactDecimal() throws {
        let v = try row(#"""
        {"objectId": "obj_a", "path": "/users/alice", "type": "exchange", "equity": "100.1",
         "unrealizedValue": "0",
         "positions": [{"market": "hl:0:XRP", "side": "long", "size": "3", "entryPrice": "0.1",
                        "markPrice": "0.1", "unrealizedPnl": "0", "valueUsd": "0"}]}
        """#)
        let out = v.revalued(with: ["hl:0:XRP": "0.3"])
        XCTAssertEqual(out.unrealizedValue, "0.6")
        XCTAssertEqual(out.equity, "100.7")
    }

    func testPendingPnlIsNotGivenANumber() throws {
        let v = try row(#"""
        {"objectId": "obj_a", "path": "/users/alice", "type": "exchange", "equity": "1000",
         "positions": [{"market": "hl:0:BTC", "side": "long", "size": "1", "entryPrice": "100",
                        "markPrice": "100", "unrealizedPnl": "0", "valueUsd": "0"}],
         "pnl": {"window": "30d", "from": "2026-10-01T00:00:00Z", "status": "pending"},
         "volume": {"window": "30d", "from": "2026-10-01T00:00:00Z", "status": "pending"}}
        """#)
        let out = v.revalued(with: ["hl:0:BTC": "200"])
        XCTAssertNil(out.pnl?.pnlUsd, "pending P&L must not read as zero")
        XCTAssertEqual(out.pnl?.windowedStatus, .pending)
        XCTAssertNil(out.volume?.volumeUsd)
        XCTAssertEqual(out.equity, "1100")
    }

    func testServerPricedRowIsNotRemarked() throws {
        let v = try row(#"""
        {"objectId": "obj_a", "path": "/users/alice", "type": "exchange", "equity": "1000",
         "pricingMode": "server",
         "positions": [{"market": "hl:0:BTC", "side": "long", "size": "1", "entryPrice": "100",
                        "markPrice": "100", "unrealizedPnl": "0", "valueUsd": "0"}],
         "pnl": {"window": "30d", "from": "2026-10-01T00:00:00Z", "status": "complete", "pnlUsd": "5"}}
        """#)
        let out = v.revalued(with: ["hl:0:BTC": "200"])
        XCTAssertEqual(out.equity, "1000")
        XCTAssertEqual(out.pnl?.pnlUsd, "5")
    }

    // MARK: - Decoding

    func testPageDecodesRowByRow() throws {
        let json = #"""
        {"projection": "board", "fields": ["equity"], "window": "30d",
         "valuations": [
           {"objectId": "obj_a", "path": "/users/alice", "type": "exchange", "equity": "1"},
           {"objectId": "obj_b", "type": "exchange", "equity": "2"},
           {"objectId": "obj_c", "path": "/users/carol", "type": "exchange", "equity": "3",
            "pnl": {"window": "30d", "from": "2026-10-01T00:00:00Z", "status": "incomplete",
                    "coverage": "partial", "coveredFrom": "2026-10-20T00:00:00Z", "pnlUsd": "4"}}
         ]}
        """#
        let page = try JSONDecoder().decode(ProjectionValuationsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.window, "30d")
        XCTAssertEqual(page.valuations.map(\.path), ["/users/alice", "/users/carol"], "the unreadable row is skipped, not the page")
        XCTAssertEqual(page.valuations.last?.pnl?.windowedStatus, .incomplete)
        XCTAssertEqual(page.valuations.last?.pnl?.coveredFrom, "2026-10-20T00:00:00Z")
    }

    func testWindowIsEncodedOnWatchAndUpdate() throws {
        let created = try encode(.watchProjection(projection: "board", paths: ["/users/a"], prefix: nil, window: "30d", requestId: "proj-1"))
        XCTAssertEqual(created["window"] as? String, "30d")
        let updated = try encode(.updateProjectionWatch(watchId: "w1", paths: ["/users/b"], prefix: nil, requestId: "proj-2"))
        XCTAssertNil(updated["window"], "an update without a window keeps the watch's window")
    }

    // MARK: - Stream

    func testWatchSendsTheWindowAndRowsCarryFigures() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/alice"], window: .thirtyDays) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let request = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        XCTAssertEqual(request["window"] as? String, "30d")

        socket.deliver(reply(type: "projection_watch_created", requestId: request["requestId"] as? String ?? "", watchId: "w1", window: "30d", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "12", volume: "900"),
        ]))
        let stream = try await task.value
        XCTAssertEqual(stream.window, "30d")
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.pnl?.pnlUsd, "12")
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.volume?.volumeUsd, "900")
        XCTAssertFalse(stream.isStale)

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testSnapshotWithAnUnreadableRowKeepsTheRest() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/alice", "/users/bob"]) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let request = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        socket.deliver(reply(type: "projection_watch_created", requestId: request["requestId"] as? String ?? "", watchId: "w1", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "1", volume: "1"),
            #"{"objectId": "obj_b", "type": "exchange"}"#,
        ]))
        let stream = try await task.value
        XCTAssertEqual(Array(stream.valuations.value.keys), ["/users/alice"])

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testReplacedAccountAtTheSamePathIsKept() async throws {
        let (arca, socket, stream) = try await openedStream()

        socket.deliver(#"""
        {"type": "object.valuation", "watchId": "w1", "projection": "board", "deliverySeq": 1,
         "removed": ["/users/alice"],
         "valuations": {"/users/alice": \#(windowedRow("/users/alice", objectId: "obj_new", pnl: "0", volume: "0"))}}
        """#)
        try await waitUntil { stream.valuations.value["/users/alice"]?.objectId.rawValue == "obj_new" }
        XCTAssertEqual(stream.valuations.value.count, 1)

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testDeliveryGapReReadsUnderTheSameWatch() async throws {
        let (arca, socket, stream) = try await openedStream()

        socket.deliver(frame(seq: 1, path: "/users/alice", objectId: "obj_a", pnl: "2"))
        try await waitUntil { stream.valuations.value["/users/alice"]?.pnl?.pnlUsd == "2" }
        socket.deliver(frame(seq: 4, path: "/users/alice", objectId: "obj_a", pnl: "3"))

        try await waitUntil { socket.sentActions.contains("update_projection_watch") }
        let request = try XCTUnwrap(lastMessage(socket, action: "update_projection_watch"))
        XCTAssertEqual(request["watchId"] as? String, "w1", "a gap re-reads under the same watch")
        XCTAssertEqual(request["paths"] as? [String], ["/users/alice"])
        XCTAssertTrue(stream.isStale)
        socket.deliver(reply(type: "projection_watch_updated", requestId: request["requestId"] as? String ?? "", watchId: "w1", window: "30d", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "7", volume: "70"),
        ]))
        try await waitUntil { stream.valuations.value["/users/alice"]?.pnl?.pnlUsd == "7" }
        try await waitUntil { !stream.isStale }
        XCTAssertEqual(socket.sentActions.filter { $0 == "watch_projection" }.count, 1, "no new watch for a gap")

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testServerResyncReReadsTheScope() async throws {
        let (arca, socket, stream) = try await openedStream()

        socket.deliver(#"{"type": "stream.resync", "deliverySeq": 1}"#)
        try await waitUntil { socket.sentActions.contains("update_projection_watch") }
        let request = try XCTUnwrap(lastMessage(socket, action: "update_projection_watch"))
        socket.deliver(reply(type: "projection_watch_updated", requestId: request["requestId"] as? String ?? "", watchId: "w1", window: "30d", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "9", volume: "90"),
        ]))
        try await waitUntil { stream.valuations.value["/users/alice"]?.volume?.volumeUsd == "90" }

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testFailedRecreateIsRetriedWithTheLastRowsKept() async throws {
        let (arca, socket, stream) = try await openedStream()
        let factory = currentFactory!

        socket.fail()
        try await waitUntil(timeout: 5) { factory.count >= 2 }
        guard let next = factory.socket(1) else { return XCTFail("no replacement socket") }
        next.deliver(#"{"type":"authenticated"}"#)
        try await waitUntil(timeout: 3) { next.sentActions.contains("watch_projection") }
        let first = try XCTUnwrap(lastMessage(next, action: "watch_projection"))
        XCTAssertEqual(first["window"] as? String, "30d", "the re-create keeps the window")
        next.deliver(#"{"type": "error", "requestId": "\#(first["requestId"] as? String ?? "")", "message": "busy"}"#)

        try await waitUntil { stream.isStale }
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.pnl?.pnlUsd, "1", "the last rows stay while retrying")

        try await waitUntil(timeout: 4) { next.sentActions.filter { $0 == "watch_projection" }.count >= 2 }
        let second = try XCTUnwrap(lastMessage(next, action: "watch_projection"))
        next.deliver(reply(type: "projection_watch_created", requestId: second["requestId"] as? String ?? "", watchId: "w2", window: "30d", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "5", volume: "50"),
        ]))
        try await waitUntil { stream.watchId.value == "w2" && !stream.isStale }
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.pnl?.pnlUsd, "5")

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testStopFinishesUpdates() async throws {
        let (arca, _, stream) = try await openedStream()
        let finished = SendableBox<Bool>(false)
        let consumer = Task {
            for await _ in stream.updates {}
            finished.update { $0 = true }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await stream.stop()
        try await waitUntil { finished.value }
        consumer.cancel()
        await arca.ws.disconnect()
    }

    // MARK: - Helpers

    private var currentFactory: MockTransportFactory?

    private func row(_ json: String) throws -> ProjectedValuation {
        try JSONDecoder().decode(ProjectedValuation.self, from: Data(json.utf8))
    }

    private func encode(_ message: OutboundMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func connectedArca() async throws -> (Arca, MockWebSocketTransport) {
        let arca = try Arca(token: fakeJwt(), baseURL: URL(string: "http://localhost:19997")!)
        let factory = MockTransportFactory()
        currentFactory = factory
        await arca.ws.setTransportFactory(factory.make())
        await arca.ws.connect()
        try await waitUntil { factory.count >= 1 }
        guard let socket = factory.socket(0) else { throw MockTransportError.closed }
        socket.deliver(#"{"type":"authenticated"}"#)
        try await waitUntil { await arca.ws.status == .connected }
        return (arca, socket)
    }

    private func openedStream() async throws -> (Arca, MockWebSocketTransport, ProjectionWatchStream) {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/alice"], window: .thirtyDays) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let request = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        socket.deliver(reply(type: "projection_watch_created", requestId: request["requestId"] as? String ?? "", watchId: "w1", window: "30d", rows: [
            windowedRow("/users/alice", objectId: "obj_a", pnl: "1", volume: "10"),
        ]))
        return (arca, socket, try await task.value)
    }

    private func lastMessage(_ socket: MockWebSocketTransport, action: String) -> [String: Any]? {
        socket.sent.reversed().lazy.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["action"] as? String == action else { return nil }
            return json
        }.first
    }

    private func windowedRow(_ path: String, objectId: String, pnl: String, volume: String) -> String {
        #"""
        {"objectId": "\#(objectId)", "path": "\#(path)", "type": "exchange", "equity": "1000", "positions": [],
         "pnl": {"window": "30d", "from": "2026-10-01T00:00:00Z", "asOf": "2026-10-31T00:00:00Z",
                 "coverage": "full", "status": "complete", "pnlUsd": "\#(pnl)"},
         "volume": {"window": "30d", "from": "2026-10-01T00:00:00Z", "asOf": "2026-10-31T00:00:00Z",
                    "coverage": "full", "status": "complete", "volumeUsd": "\#(volume)"}}
        """#
    }

    private func frame(seq: Int, path: String, objectId: String, pnl: String) -> String {
        #"""
        {"type": "object.valuation", "watchId": "w1", "projection": "board", "deliverySeq": \#(seq),
         "valuations": {"\#(path)": \#(windowedRow(path, objectId: objectId, pnl: pnl, volume: "10"))}}
        """#
    }

    private func reply(type: String, requestId: String, watchId: String, window: String? = nil, rows: [String]) -> String {
        let windowField = window.map { #", "window": "\#($0)""# } ?? ""
        return #"""
        {"type": "\#(type)", "requestId": "\#(requestId)", "watchId": "\#(watchId)",
         "projection": "board", "fields": ["equity", "positions", "pnl", "volume"]\#(windowField),
         "valuations": [\#(rows.joined(separator: ","))]}
        """#
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let met = await condition()
        XCTAssertTrue(met, "condition not met within \(timeout)s")
    }

    private func fakeJwt() -> String {
        func base64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"realmId":"rlm_test","sub":"usr_test"}"#)
        return "\(header).\(payload).fakesig"
    }
}
