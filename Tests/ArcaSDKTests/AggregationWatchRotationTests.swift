import XCTest
@testable import ArcaSDK

/// An aggregation watch must be re-created after rotation because its
/// replacement connection can reach another pod. Rotation preserves connected
/// status, so recovery needs an explicit rotation hook.
final class AggregationWatchRotationTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!
    private var factory: MockTransportFactory!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AggregationWatchProtocol.self] + (sessionConfig.protocolClasses ?? [])
        AggregationWatchProtocol.reset()
        factory = MockTransportFactory()
    }

    override func tearDown() {
        sessionConfig = nil
        factory = nil
        AggregationWatchProtocol.reset()
        super.tearDown()
    }

    func testAggregationWatchIsRecreatedOnRotationWithoutReconnectingState() async throws {
        let arca = makeArca()
        await arca.ws.setTransportFactory(factory.make())

        let pending = Task { try await arca.watchAggregation(sources: [AggregationSource(type: .prefix, value: "/")]) }
        try await waitFor { self.factory.count >= 1 }
        guard let original = factory.socket(0) else { return XCTFail("no socket") }
        original.deliver(#"{"type":"authenticated"}"#)
        try await answerCreate(original, watchId: "agw_1")
        let stream = try await pending.value
        let firstWatchId = stream.watchId

        let observedStates = SendableBox<[WatchStreamState]>([])
        let observer = stream.state.onChange { s in observedStates.update { $0.append(s) } }

        await arca.ws.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        guard let replacement = factory.socket(1) else { return XCTFail("no replacement socket") }
        replacement.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { replacement.sentActions.contains("ping") }
        replacement.deliver(#"{"type":"pong"}"#)
        try await answerCreate(replacement, watchId: "agw_2", timeout: 2.0)

        try await waitFor { replacement.destroyedWatchIds.contains(firstWatchId) }
        XCTAssertTrue(replacement.destroyedWatchIds.contains(firstWatchId),
                      "the watch the retired connection held must be cleaned up")
        XCTAssertEqual(AggregationWatchProtocol.createCount, 0,
                       "the watch is created on the socket, never over REST")
        XCTAssertFalse(observedStates.value.contains(.reconnecting),
                       "a rotation is not an outage; the stream must never enter reconnecting")

        stream.state.removeObserver(observer)
        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Helpers

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19998")!,
            urlSessionConfiguration: sessionConfig
        )
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

    private func answerCreate(_ socket: MockWebSocketTransport, watchId: String, timeout: TimeInterval = 1.0) async throws {
        try await waitFor(timeout: timeout) { socket.frames("create_aggregation_watch").count > 0 }
        let requestId = try XCTUnwrap(socket.frames("create_aggregation_watch").last?["requestId"] as? String)
        socket.deliver("""
        {"type":"aggregation_watch_created","requestId":"\(requestId)","watchId":"\(watchId)","aggregation":{"prefix":"/","totalEquityUsd":"100.00","departingUsd":"0","arrivingUsd":"0","breakdown":[],"asOf":null,"cumInflowsUsd":null,"cumOutflowsUsd":null}}
        """)
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
    func frames(_ action: String) -> [[String: Any]] {
        sent.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { $0["action"] as? String == action }
    }

    var destroyedWatchIds: [String] {
        frames("destroy_aggregation_watch").compactMap { $0["watchId"] as? String }
    }
}

private final class AggregationWatchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _createCount = 0
    private static var _destroyedIds: [String] = []

    static var createCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _createCount
    }

    static var destroyedIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return _destroyedIds
    }

    static func reset() {
        lock.lock()
        _createCount = 0
        _destroyedIds = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.hasPrefix("/api/v1/aggregations/watch")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: String
        if request.httpMethod == "DELETE" {
            Self.lock.lock()
            Self._destroyedIds.append(url.lastPathComponent)
            Self.lock.unlock()
            body = #"{"success":true,"data":{}}"#
        } else {
            Self.lock.lock()
            Self._createCount += 1
            let watchId = "agw_\(Self._createCount)"
            Self.lock.unlock()
            body = """
            {"success":true,"data":{"watchId":"\(watchId)","aggregation":{"prefix":"/","totalEquityUsd":"100.00","departingUsd":"0","arrivingUsd":"0","breakdown":[],"asOf":null,"cumInflowsUsd":null,"cumOutflowsUsd":null}}}
            """
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
