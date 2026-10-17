import XCTest
@testable import ArcaSDK

/// A projection watch is scoped to the accounts the client names, and the
/// Arca mids subscription is scoped to the markets the client's consumers
/// declare. These pin the wire shape (paths / prefix on `watch_projection`,
/// `update_projection_watch` under the same watch id, an empty scope sent as
/// exactly that), the reconnect contract (re-create with the CURRENT scope),
/// and that `subscribe_mids` carries the union of declared interests — never
/// `coins: []` on behalf of a consumer that named its markets.
final class ScopedProjectionAndMidsTests: XCTestCase {

    // MARK: - Wire shape

    func testWatchProjectionEncodesPathsAndPrefix() throws {
        let json = try encode(.watchProjection(projection: "board", paths: ["/users/bob/main"], prefix: "/users", requestId: "proj-1"))
        XCTAssertEqual(json["action"] as? String, "watch_projection")
        XCTAssertEqual(json["projection"] as? String, "board")
        XCTAssertEqual(json["paths"] as? [String], ["/users/bob/main"])
        XCTAssertEqual(json["prefix"] as? String, "/users")
        XCTAssertEqual(json["requestId"] as? String, "proj-1")
    }

    func testWatchProjectionWithNoScopeSendsNoScopeFields() throws {
        let scope = ProjectionWatchScope(paths: [], prefix: "")
        XCTAssertTrue(scope.isEmpty)
        let json = try encode(.watchProjection(projection: "board", paths: scope.wirePaths, prefix: scope.wirePrefix, requestId: "proj-1"))
        XCTAssertNil(json["paths"], "an empty scope is an empty watch, not everyone")
        XCTAssertNil(json["prefix"])
    }

    func testUpdateProjectionWatchEncodesWatchIdAndScope() throws {
        let json = try encode(.updateProjectionWatch(watchId: "w1", paths: ["/users/carol/main"], prefix: nil, requestId: "proj-2"))
        XCTAssertEqual(json["action"] as? String, "update_projection_watch")
        XCTAssertEqual(json["watchId"] as? String, "w1")
        XCTAssertEqual(json["paths"] as? [String], ["/users/carol/main"])
        XCTAssertNil(json["prefix"])
    }

    // MARK: - Interest-scoped Arca mids

    /// A consumer that names its markets gets a `subscribe_mids` carrying
    /// exactly those markets; a second consumer widens the set in place.
    func testArcaMidsSubscriptionCarriesDeclaredInterests() async throws {
        let (arca, socket) = try await connectedArca()

        let btc = Task { try await arca.watchPrices(markets: ["hl:0:BTC"]) }
        try await waitUntil { socket.sentActions.contains("subscribe_mids") }
        XCTAssertEqual(lastMidsCoins(socket), ["hl:0:BTC"])
        socket.deliver(#"{"type":"mids.snapshot","mids":{"hl:0:BTC":"80000"}}"#)
        let btcStream = try await btc.value

        let eth = Task { try await arca.watchPrices(markets: ["hl:0:ETH"]) }
        try await waitUntil { self.lastMidsCoins(socket) == ["hl:0:BTC", "hl:0:ETH"] }
        socket.deliver(#"{"type":"mids.snapshot","mids":{"hl:0:BTC":"80000","hl:0:ETH":"3000"}}"#)
        let ethStream = try await eth.value
        // The second consumer returns off the retained map (BTC only) and
        // its own market lands with the snapshot the widened subscription
        // triggers, one round trip later.
        try await waitUntil { ethStream.prices.value["hl:0:ETH"] == "3000" }

        // Dropping a consumer narrows the set after the release debounce.
        await ethStream.stop()
        try await waitUntil(timeout: 3) { self.lastMidsCoins(socket) == ["hl:0:BTC"] }

        await btcStream.stop()
        try await waitUntil(timeout: 3) { socket.sentActions.contains("unsubscribe_mids") }
        await arca.ws.disconnect()
    }

    /// `setMarkets` re-sends the subscription with the new set in place.
    func testSetMarketsResendsTheArcaSubscription() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchPrices(markets: ["hl:0:BTC"]) }
        try await waitUntil { socket.sentActions.contains("subscribe_mids") }
        socket.deliver(#"{"type":"mids.snapshot","mids":{"hl:0:BTC":"80000"}}"#)
        let stream = try await task.value

        await stream.setMarkets(["hl:0:SOL", "hl:0:BTC"])
        try await waitUntil { self.lastMidsCoins(socket) == ["hl:0:BTC", "hl:0:SOL"] }

        await stream.stop()
        await arca.ws.disconnect()
    }

    /// The pre-existing all-markets shape is still available, explicitly:
    /// an unscoped `watchPrices()` subscribes to every market.
    func testUnscopedWatchPricesStillAsksForEveryMarket() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchPrices() }
        try await waitUntil { socket.sentActions.contains("subscribe_mids") }
        XCTAssertEqual(lastMidsCoins(socket), [])
        socket.deliver(#"{"type":"mids.snapshot","mids":{"hl:0:BTC":"80000"}}"#)
        let stream = try await task.value
        await stream.stop()
        await arca.ws.disconnect()
    }

    /// Reconnect replays the interest set, not `[]`.
    func testReconnectResubscribesWithTheInterestSet() async throws {
        let (arca, socket) = try await connectedArca()
        let factory = currentFactory!
        let task = Task { try await arca.watchPrices(markets: ["hl:0:BTC"]) }
        try await waitUntil { socket.sentActions.contains("subscribe_mids") }
        socket.deliver(#"{"type":"mids.snapshot","mids":{"hl:0:BTC":"80000"}}"#)
        let stream = try await task.value

        socket.fail()
        try await waitUntil(timeout: 5) { factory.count >= 2 }
        guard let next = factory.socket(1) else { return XCTFail("no replacement socket") }
        next.deliver(#"{"type":"authenticated"}"#)
        try await waitUntil(timeout: 3) { next.sentActions.contains("subscribe_mids") }
        XCTAssertEqual(lastMidsCoins(next), ["hl:0:BTC"])

        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Scoped projection watch

    func testWatchProjectionSendsPathsAndSubscribesToRowMarkets() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/bob", "/users/alice"]) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let request = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        XCTAssertEqual(request["paths"] as? [String], ["/users/bob", "/users/alice"])
        XCTAssertNil(request["prefix"])

        socket.deliver(projectionReply(type: "projection_watch_created", requestId: request["requestId"] as? String ?? "", watchId: "w1", rows: [
            row("/users/alice", equity: "1000", markets: ["hl:0:BTC"]),
            row("/users/bob", equity: "2000", markets: ["hl:0:ETH", "hl:0:BTC"]),
        ]))
        let stream = try await task.value
        XCTAssertEqual(stream.valuations.value.count, 2)
        XCTAssertEqual(stream.scope.value, ProjectionWatchScope(paths: ["/users/bob", "/users/alice"]))

        // The stream's mids interest is its rows' markets, not every market.
        try await waitUntil { self.lastMidsCoins(socket) == ["hl:0:BTC", "hl:0:ETH"] }

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testSetPathsUpdatesInPlaceAndReplacesRows() async throws {
        let (arca, socket) = try await connectedArca()
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/alice"]) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let created = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        socket.deliver(projectionReply(type: "projection_watch_created", requestId: created["requestId"] as? String ?? "", watchId: "w1", rows: [
            row("/users/alice", equity: "1000", markets: ["hl:0:BTC"]),
        ]))
        let stream = try await task.value

        let update = Task { try await stream.setPaths(["/users/carol"]) }
        try await waitUntil { socket.sentActions.contains("update_projection_watch") }
        let request = try XCTUnwrap(lastMessage(socket, action: "update_projection_watch"))
        XCTAssertEqual(request["watchId"] as? String, "w1")
        XCTAssertEqual(request["paths"] as? [String], ["/users/carol"])
        socket.deliver(projectionReply(type: "projection_watch_updated", requestId: request["requestId"] as? String ?? "", watchId: "w1", rows: [
            row("/users/carol", equity: "3000", markets: ["hl:0:SOL"]),
        ]))
        try await update.value

        XCTAssertEqual(stream.watchId.value, "w1", "an update keeps the watch id")
        XCTAssertEqual(Array(stream.valuations.value.keys), ["/users/carol"], "the new scope's snapshot replaces the rows")
        XCTAssertEqual(stream.scope.value, ProjectionWatchScope(paths: ["/users/carol"]))
        try await waitUntil(timeout: 3) { self.lastMidsCoins(socket) == ["hl:0:SOL"] }

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testReconnectRecreatesTheWatchWithTheCurrentScope() async throws {
        let (arca, socket) = try await connectedArca()
        let factory = currentFactory!
        let task = Task { try await arca.watchProjection(name: "board", paths: ["/users/alice"]) }
        try await waitUntil { socket.sentActions.contains("watch_projection") }
        let created = try XCTUnwrap(lastMessage(socket, action: "watch_projection"))
        socket.deliver(projectionReply(type: "projection_watch_created", requestId: created["requestId"] as? String ?? "", watchId: "w1", rows: [
            row("/users/alice", equity: "1000", markets: []),
        ]))
        let stream = try await task.value

        let update = Task { try await stream.setPaths(["/users/bob"]) }
        try await waitUntil { socket.sentActions.contains("update_projection_watch") }
        let request = try XCTUnwrap(lastMessage(socket, action: "update_projection_watch"))
        socket.deliver(projectionReply(type: "projection_watch_updated", requestId: request["requestId"] as? String ?? "", watchId: "w1", rows: [
            row("/users/bob", equity: "2000", markets: []),
        ]))
        try await update.value

        socket.fail()
        try await waitUntil(timeout: 5) { factory.count >= 2 }
        guard let next = factory.socket(1) else { return XCTFail("no replacement socket") }
        next.deliver(#"{"type":"authenticated"}"#)
        try await waitUntil(timeout: 3) { next.sentActions.contains("watch_projection") }
        let recreated = try XCTUnwrap(lastMessage(next, action: "watch_projection"))
        XCTAssertEqual(recreated["paths"] as? [String], ["/users/bob"], "re-create uses the scope as updated, not as first opened")

        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Helpers

    private var currentFactory: MockTransportFactory?

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

    private func encode(_ message: OutboundMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func lastMessage(_ socket: MockWebSocketTransport, action: String) -> [String: Any]? {
        socket.sent.reversed().lazy.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["action"] as? String == action else { return nil }
            return json
        }.first
    }

    private func lastMidsCoins(_ socket: MockWebSocketTransport) -> [String]? {
        lastMessage(socket, action: "subscribe_mids")?["coins"] as? [String]
    }

    private func row(_ path: String, equity: String, markets: [String]) -> String {
        let positions = markets.map {
            #"{"market": "\#($0)", "side": "long", "size": "1", "entryPrice": "100", "markPrice": "100", "unrealizedPnl": "0", "valueUsd": "0"}"#
        }.joined(separator: ",")
        return #"{"objectId": "obj_\#(path.hashValue)", "path": "\#(path)", "type": "exchange", "equity": "\#(equity)", "positions": [\#(positions)]}"#
    }

    private func projectionReply(type: String, requestId: String, watchId: String, rows: [String]) -> String {
        #"""
        {"type": "\#(type)", "requestId": "\#(requestId)", "watchId": "\#(watchId)",
         "projection": "board", "fields": ["equity", "positions"],
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
