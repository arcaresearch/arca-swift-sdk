import XCTest
@testable import ArcaSDK

/// Gobi iOS dropped its socket roughly a hundred times a day right after
/// connecting. `watchPath`, `watchChartHistory` and `acquireEventTypes` sent
/// their frame as soon as a socket existed, ahead of the server's
/// `authenticated` reply. The server answers a pre-auth `watch` (and
/// `watch_chart_history`) with "not authenticated" and no requestId, which
/// the SDK reads as a dead connection: it closed the socket and backed off,
/// and the home equity chart could wait long enough for the app to give up.
/// Each send now waits for auth; `resubscribeAll` replays them once it lands.
final class PreAuthSendTests: XCTestCase {

    private var factory: MockTransportFactory!

    override func setUp() {
        super.setUp()
        factory = MockTransportFactory()
    }

    override func tearDown() {
        factory = nil
        super.tearDown()
    }

    func testWatchPathOnAConnectingSocketWaitsForAuth() async throws {
        let (manager, socket) = try await connectingManager()

        await manager.watchPath(Self.path)
        try await settle()
        XCTAssertEqual(socket.sentActions, ["auth"], "a path watch must not reach the server before auth")

        socket.deliver(Self.authenticated)
        try await waitFor { socket.sentActions.contains("watch") }
        XCTAssertEqual(socket.lastFrame("watch")["path"] as? String, Self.path)
        XCTAssertEqual(socket.sentActions.filter { $0 == "watch" }.count, 1)
        XCTAssertFalse(socket.stopped)
        XCTAssertEqual(factory.count, 1)
        let status = await manager.status
        XCTAssertEqual(status, .connected)
        await manager.disconnect()
    }

    func testWatchPathOnAnAuthenticatedSocketSendsAtOnce() async throws {
        let (manager, socket) = try await connectingManager()
        socket.deliver(Self.authenticated)
        try await waitFor { await manager.status == .connected }

        await manager.watchPath(Self.path)
        try await waitFor { socket.sentActions.contains("watch") }
        XCTAssertEqual(socket.lastFrame("watch")["path"] as? String, Self.path)
        await manager.disconnect()
    }

    func testWatchChartHistoryOnAConnectingSocketWaitsForAuth() async throws {
        let (manager, socket) = try await connectingManager()

        let watchId = await manager.watchChartHistory(target: Self.path)
        try await settle()
        XCTAssertEqual(socket.sentActions, ["auth"], "a chart history watch must not reach the server before auth")

        socket.deliver(Self.authenticated)
        try await waitFor { socket.sentActions.contains("watch_chart_history") }
        XCTAssertEqual(socket.lastFrame("watch_chart_history")["watchId"] as? String, watchId)
        XCTAssertEqual(socket.sentActions.filter { $0 == "watch_chart_history" }.count, 1)
        await manager.disconnect()
    }

    func testEventTypesOnAConnectingSocketWaitForAuth() async throws {
        let (manager, socket) = try await connectingManager()

        await manager.acquireEventTypes(["fill.recorded"])
        try await settle()
        XCTAssertEqual(socket.sentActions, ["auth"])

        socket.deliver(Self.authenticated)
        try await waitFor { socket.sentActions.contains("subscribe_events") }
        XCTAssertEqual(socket.sentActions.filter { $0 == "subscribe_events" }.count, 1)
        await manager.disconnect()
    }

    func testPathRecoveryOnAConnectingSocketWaitsForAuthAndCompletes() async throws {
        let (manager, socket) = try await connectingManager()

        let completed = LockedFlag()
        let recovery = Task { try await manager.recoverPathReady(Self.path); completed.set() }
        try await settle()
        XCTAssertEqual(socket.sentActions, ["auth"], "recovery must not resend a watch before auth")

        socket.deliver(Self.authenticated)
        try await waitFor { socket.sentActions.contains("watch") }
        let requestId = try XCTUnwrap(socket.lastFrame("watch")["requestId"] as? String)
        socket.deliver(#"{"type":"watch_snapshot","path":"\#(Self.path)","requestId":"\#(requestId)","operations":[]}"#)
        try await waitFor { completed.value }
        recovery.cancel()
        XCTAssertTrue(completed.value, "recovery must complete on the authenticated socket")
        XCTAssertEqual(socket.sentActions.filter { $0 == "watch" }.count, 1)
        await manager.disconnect()
    }

    // MARK: - Harness

    private static let authenticated = #"{"type":"authenticated"}"#
    private static let path = "/users/u1/exchange"

    /// A manager whose first socket is open and has sent `auth`, with the
    /// server's reply not yet delivered.
    private func connectingManager() async throws -> (WebSocketManager, MockWebSocketTransport) {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:19997")!,
            token: "t",
            realmId: "rlm_test",
            connectionLifetime: 0,
            logger: .disabled
        )
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try await waitFor { self.factory.socket(0)?.sentActions.contains("auth") == true }
        let socket = try XCTUnwrap(factory.socket(0))
        let status = await manager.status
        XCTAssertEqual(status, .connecting)
        return (manager, socket)
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

private extension MockWebSocketTransport {
    func lastFrame(_ action: String) -> [String: Any] {
        sent.compactMap { $0.data(using: .utf8) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .last { $0["action"] as? String == action } ?? [:]
    }
}
