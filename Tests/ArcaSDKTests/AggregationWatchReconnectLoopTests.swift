import XCTest
@testable import ArcaSDK

/// Gobi's P&L chart held its socket in a reconnect loop for as long as the
/// chart was open. A replacement socket replayed `attach_aggregation_watch`
/// for a watch the server had destroyed with the previous connection; the
/// "unknown watch" reply carried no requestId, so the SDK read it as a
/// connection failure, dropped the socket and, with the backoff reset at
/// auth, reconnected a second later into the same error.
final class AggregationWatchReconnectLoopTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!
    private var factory: MockTransportFactory!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RestAggregationCounter.self] + (sessionConfig.protocolClasses ?? [])
        RestAggregationCounter.reset()
        factory = MockTransportFactory()
    }

    override func tearDown() {
        sessionConfig = nil
        factory = nil
        RestAggregationCounter.reset()
        super.tearDown()
    }

    // MARK: - Request-scoped errors

    func testUnknownWatchAttachDropsTheWatchNotTheSocket() async throws {
        let manager = await makeConnectedManager()
        let socket = factory.socket(0)!
        await manager.attachAggregationWatch(watchId: "wch_gone")
        try await waitFor { socket.sentActions.contains("attach_aggregation_watch") }
        let requestId = try XCTUnwrap(socket.lastFrame("attach_aggregation_watch")["requestId"] as? String)

        socket.deliver(#"{"type":"error","message":"unknown watch","requestId":"\#(requestId)"}"#)
        try await settle()

        XCTAssertFalse(socket.stopped, "a rejected attach must not close the socket")
        XCTAssertEqual(factory.count, 1)
        let status = await manager.status
        XCTAssertEqual(status, .connected)

        // Dropped locally, so the next socket does not replay it.
        socket.fail()
        try await waitFor(timeout: 3) { self.factory.count == 2 }
        factory.socket(1)!.deliver(Self.authenticated)
        try await waitFor { await manager.status == .connected }
        try await settle()
        XCTAssertFalse(factory.socket(1)!.sentActions.contains("attach_aggregation_watch"))
        await manager.disconnect()
    }

    func testErrorForAnUntrackedRequestKeepsTheSocket() async throws {
        let manager = await makeConnectedManager()
        let socket = factory.socket(0)!

        socket.deliver(#"{"type":"error","message":"unknown watch","requestId":"attach-req-999"}"#)
        try await settle()

        XCTAssertFalse(socket.stopped)
        XCTAssertEqual(factory.count, 1)
        let status = await manager.status
        XCTAssertEqual(status, .connected)
        await manager.disconnect()
    }

    func testAttachWaitsForAuthentication() async throws {
        let manager = makeManager()
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try await waitFor { self.factory.count >= 1 }
        let socket = factory.socket(0)!

        // Sent before auth, the server answers "not authenticated" with no
        // requestId, which is a connection-level failure.
        await manager.attachAggregationWatch(watchId: "wch_1")
        try await settle()
        XCTAssertFalse(socket.sentActions.contains("attach_aggregation_watch"))

        socket.deliver(Self.authenticated)
        try await waitFor { socket.sentActions.contains("attach_aggregation_watch") }
        XCTAssertNotNil(socket.lastFrame("attach_aggregation_watch")["requestId"] as? String)
        await manager.disconnect()
    }

    func testErrorWithoutARequestIdAfterAuthenticationKeepsTheSocket() async throws {
        let manager = await makeConnectedManager()
        let socket = factory.socket(0)!

        // A bad id stays in the subscription set; reconnecting would resend it.
        socket.deliver(Self.nonCanonicalCoin)
        try await settle()

        XCTAssertFalse(socket.stopped, "an authenticated connection must survive a rejected subscription")
        XCTAssertEqual(factory.count, 1)
        let status = await manager.status
        XCTAssertEqual(status, .connected)
        await manager.disconnect()
    }

    func testErrorBeforeAuthenticationStillReconnects() async throws {
        let manager = makeManager()
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try await waitFor { self.factory.count >= 1 }

        factory.socket(0)!.deliver(Self.authRejected)

        try await waitFor { self.factory.socket(0)!.stopped }
        XCTAssertTrue(factory.socket(0)!.stopped, "a refused authentication leaves the socket unusable")
        try await waitFor(timeout: 3) { self.factory.count == 2 }
        XCTAssertEqual(factory.count, 2)
        await manager.disconnect()
    }

    func testErrorWithoutARequestIdOnAnAuthenticatedHandoffDoesNotAbortTheRotation() async throws {
        let manager = await makeConnectedManager()
        let original = factory.socket(0)!

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        let replacement = factory.socket(1)!
        replacement.deliver(Self.authenticated)
        try await waitFor { replacement.sentActions.contains("ping") }
        replacement.deliver(Self.nonCanonicalCoin)
        replacement.deliver(Self.pong)
        try await waitFor { original.stopped }

        XCTAssertTrue(original.stopped, "the replacement should have taken over")
        XCTAssertFalse(replacement.stopped)
        await manager.disconnect()
    }

    func testRejectedAttachDuringHandoffDoesNotAbortTheRotation() async throws {
        let manager = await makeConnectedManager()
        let original = factory.socket(0)!
        await manager.attachAggregationWatch(watchId: "wch_1")
        try await waitFor { original.sentActions.contains("attach_aggregation_watch") }

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        let replacement = factory.socket(1)!
        replacement.deliver(Self.authenticated)
        try await waitFor { replacement.sentActions.contains("attach_aggregation_watch") }
        let requestId = try XCTUnwrap(replacement.lastFrame("attach_aggregation_watch")["requestId"] as? String)
        replacement.deliver(#"{"type":"error","message":"unknown watch","requestId":"\#(requestId)"}"#)

        try await waitFor { replacement.sentActions.contains("ping") }
        replacement.deliver(Self.pong)
        try await waitFor { original.stopped }

        XCTAssertFalse(replacement.stopped, "the replacement must be promoted, not abandoned")
        XCTAssertEqual(factory.count, 2)
        await manager.disconnect()
    }

    // MARK: - Socket-created watches

    func testWatchIsCreatedOnTheSocketAndRecreatedAfterReconnectWithoutREST() async throws {
        let arca = makeArca()
        await arca.ws.setTransportFactory(factory.make())

        let pending = Task { try await arca.watchAggregation(sources: Self.sources) }
        try await waitFor { self.factory.count >= 1 }
        factory.socket(0)!.deliver(Self.authenticated)
        try await answerCreate(factory.socket(0)!, watchId: "wch_1", equity: "1000")
        let stream = try await pending.value
        XCTAssertEqual(stream.watchId, "wch_1")

        factory.socket(0)!.fail()
        try await waitFor(timeout: 3) { self.factory.count == 2 }
        factory.socket(1)!.deliver(Self.authenticated)
        try await answerCreate(factory.socket(1)!, watchId: "wch_2", equity: "2000")

        try await waitFor {
            stream.state.value == .connected && stream.aggregation.value?.totalEquityUsd == "2000"
        }
        XCTAssertEqual(stream.state.value, .connected)
        XCTAssertFalse(factory.socket(1)!.sentActions.contains("attach_aggregation_watch"),
                       "a socket-created watch is re-created, never re-attached")
        XCTAssertEqual(RestAggregationCounter.createCount, 0)
        await stream.stop()
        await arca.ws.disconnect()
    }

    func testCreateInFlightWhenTheSocketDropsIsResentOnTheNextOne() async throws {
        let arca = makeArca()
        await arca.ws.setTransportFactory(factory.make())

        let pending = Task { try await arca.watchAggregation(sources: Self.sources) }
        try await waitFor { self.factory.count >= 1 }
        factory.socket(0)!.deliver(Self.authenticated)
        try await waitFor { self.factory.socket(0)!.sentActions.contains("create_aggregation_watch") }
        let inFlight = try XCTUnwrap(factory.socket(0)!.lastFrame("create_aggregation_watch")["requestId"] as? String)

        // Unanswered when its socket dies: the create must not hang on a reply
        // that can no longer arrive.
        factory.socket(0)!.fail()
        try await waitFor(timeout: 3) { self.factory.count == 2 }
        factory.socket(1)!.deliver(Self.authenticated)
        try await waitFor { self.factory.socket(1)!.sentActions.contains("create_aggregation_watch") }
        XCTAssertEqual(factory.socket(1)!.lastFrame("create_aggregation_watch")["requestId"] as? String, inFlight)
        try await answerCreate(factory.socket(1)!, watchId: "wch_2", equity: "1000")

        let stream = try await pending.value
        XCTAssertEqual(stream.watchId, "wch_2")
        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Backoff

    func testBackoffDoesNotResetUntilTheConnectionHasStayedUp() async throws {
        let handler = CapturingLogHandler()
        let manager = makeManager(logger: ArcaLogger(minLevel: .warning, handler: handler))
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try await waitFor { self.factory.count >= 1 }

        factory.socket(0)!.deliver(Self.authenticated)
        factory.socket(0)!.fail()
        try await waitFor(timeout: 3) { self.factory.count == 2 }
        factory.socket(1)!.deliver(Self.authenticated)
        factory.socket(1)!.fail()

        try await waitFor { Self.reconnectDelays(handler).count == 2 }
        XCTAssertEqual(Self.reconnectDelays(handler), ["1.0", "2.0"],
                       "a socket that fails right after auth must keep backing off")
        await manager.disconnect()
    }

    func testEnsureConnectedDuringBackoffOpensNoExtraSocket() async throws {
        let manager = await makeConnectedManager()
        factory.socket(0)!.fail()
        try await waitFor { await manager.status == .disconnected }

        await manager.ensureConnected()
        XCTAssertEqual(factory.count, 1, "a scheduled reconnect is already connecting")

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(factory.count, 2, "exactly the scheduled reconnect opens a socket")
        XCTAssertFalse(factory.socket(1)!.stopped)
        await manager.disconnect()
    }

    func testForegroundDuringBackoffConnectsNowAndKeepsBackingOff() async throws {
        let handler = CapturingLogHandler()
        let manager = makeManager(logger: ArcaLogger(minLevel: .warning, handler: handler))
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try await waitFor { self.factory.count >= 1 }
        factory.socket(0)!.deliver(Self.authenticated)
        try await waitFor { await manager.status == .connected }
        await manager.handleAppDidEnterBackground()
        factory.socket(0)!.fail()
        try await waitFor { await manager.status == .disconnected }

        await manager.handleAppWillEnterForeground()
        XCTAssertEqual(factory.count, 2, "returning to the app must not wait out the backoff")

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(factory.count, 2, "the superseded scheduled reconnect must not open a third socket")
        XCTAssertFalse(factory.socket(1)!.stopped)

        factory.socket(1)!.deliver(Self.authenticated)
        factory.socket(1)!.fail()
        try await waitFor { Self.reconnectDelays(handler).count == 2 }
        XCTAssertEqual(Self.reconnectDelays(handler), ["1.0", "2.0"],
                       "the foreground connect must not reset the backoff")
        await manager.disconnect()
    }

    // MARK: - Helpers

    private static let authenticated = #"{"type":"authenticated"}"#
    private static let pong = #"{"type":"pong"}"#
    private static let authRejected = #"{"type":"error","message":"Authentication failed"}"#
    private static let nonCanonicalCoin =
        #"{"type":"error","message":"coin \"BTC\" is not in canonical format — use e.g. hl:0:BTC, hl:1:SILVER; ignored, kept 0 valid subscription(s)"}"#
    private static let sources = [AggregationSource(type: .prefix, value: "/users")]

    private func makeManager(logger: ArcaLogger = .disabled) -> WebSocketManager {
        WebSocketManager(
            baseURL: URL(string: "http://localhost:19997")!,
            token: "t",
            realmId: "rlm_test",
            connectionLifetime: 0,
            logger: logger
        )
    }

    private func makeConnectedManager() async -> WebSocketManager {
        let manager = makeManager()
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try? await waitFor { self.factory.count >= 1 }
        factory.socket(0)?.deliver(Self.authenticated)
        try? await waitFor { await manager.status == .connected }
        return manager
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19997")!,
            urlSessionConfiguration: sessionConfig
        )
    }

    private func answerCreate(_ socket: MockWebSocketTransport, watchId: String, equity: String) async throws {
        try await waitFor { socket.sentActions.contains("create_aggregation_watch") }
        let requestId = try XCTUnwrap(socket.lastFrame("create_aggregation_watch")["requestId"] as? String)
        socket.deliver("""
        {"type":"aggregation_watch_created","requestId":"\(requestId)","watchId":"\(watchId)","aggregation":{"prefix":"/users","totalEquityUsd":"\(equity)","departingUsd":"0","arrivingUsd":"0","breakdown":[],"asOf":null,"cumInflowsUsd":null,"cumOutflowsUsd":null}}
        """)
    }

    private static func reconnectDelays(_ handler: CapturingLogHandler) -> [String] {
        handler.records.filter { $0.message == "scheduling reconnect" }.compactMap { $0.metadata["delaySeconds"] }
    }

    private func fakeJwt() -> String {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"realmId":"rlm_test","sub":"usr_test"}"#)
        return "\(header).\(payload).fakesig"
    }

    private func base64url(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func waitFor(
        timeout: TimeInterval = 1.0,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = await condition()
    }
}

private extension MockWebSocketTransport {
    func lastFrame(_ action: String) -> [String: Any] {
        sent.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .last { $0["action"] as? String == action } ?? [:]
    }
}

/// Counts REST aggregation-watch creates, which a socket-created watch must never make.
private final class RestAggregationCounter: URLProtocol {
    private static let lock = NSLock()
    private static var _createCount = 0

    static var createCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _createCount
    }

    static func reset() {
        lock.lock(); _createCount = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.hasPrefix("/api/v1/aggregations/watch")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.httpMethod == "POST" {
            Self.lock.lock(); Self._createCount += 1; Self.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
