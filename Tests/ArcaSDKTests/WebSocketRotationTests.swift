import XCTest
@testable import ArcaSDK

final class WebSocketRotationTests: XCTestCase {

    private var factory: MockTransportFactory!

    override func setUp() {
        super.setUp()
        factory = MockTransportFactory()
    }

    override func tearDown() {
        factory = nil
        super.tearDown()
    }

    // MARK: - Warming

    func testWarmsReplacementWithoutClosingOriginalOrChangingStatus() async throws {
        let manager = await makeConnectedManager()
        let statuses = SendableBox<[ConnectionStatus]>([])
        let statusStream = await manager.statusStream
        let watcher = Task {
            for await s in statusStream { statuses.update { $0.append(s) } }
        }
        try await settle()

        let started = await manager.rotateConnection()
        XCTAssertTrue(started)
        try await waitFor { self.factory.count == 2 }

        XCTAssertEqual(factory.count, 2, "a second socket should be opened")
        XCTAssertTrue(factory.socket(1)?.started ?? false)
        XCTAssertFalse(factory.socket(0)?.stopped ?? true, "the original must keep serving")
        let status = await manager.status
        XCTAssertEqual(status, .connected)
        XCTAssertEqual(statuses.value, [.connected],
                       "warming must not emit a status change beyond the stream's priming value")

        watcher.cancel()
        await manager.disconnect()
    }

    func testReissuesSubscriptionsOnReplacement() async throws {
        let manager = await makeConnectedManager()
        await manager.watchPath("/users/alice")
        await manager.acquireMids(exchange: "hl")
        try await settle()

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        guard let replacement = factory.socket(1) else { return XCTFail("no replacement socket") }

        replacement.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { replacement.sentActions.contains("ping") }

        let actions = replacement.sentActions
        XCTAssertEqual(actions.first, "auth")
        XCTAssertTrue(actions.contains("subscribe_mids"))
        XCTAssertTrue(actions.contains("watch"))
        XCTAssertEqual(actions.last, "ping", "the barrier ping must be queued behind the resubscribe batch")

        await manager.disconnect()
    }

    // MARK: - Promotion

    func testRetiresOriginalAndDeliversFromReplacement() async throws {
        let manager = await makeConnectedManager()
        let mids = await manager.midsEvents()
        let received = SendableBox<[[String: String]]>([])
        let consumer = Task {
            for await m in mids { received.update { $0.append(m) } }
        }
        try await settle()

        let (original, replacement) = try await promote(manager)

        XCTAssertTrue(original.stopped, "the retired socket must be closed")
        XCTAssertFalse(replacement.stopped)

        replacement.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"101"},"deliverySeq":1}"#)
        try await waitFor { received.value.contains { $0["hl:0:BTC"] == "101" } }
        XCTAssertTrue(received.value.contains { $0["hl:0:BTC"] == "101" })

        consumer.cancel()
        await manager.disconnect()
    }

    func testDropsDuplicateEventsArrivingOnWarmingSocket() async throws {
        let manager = await makeConnectedManager()
        let mids = await manager.midsEvents()
        let received = SendableBox<[[String: String]]>([])
        let consumer = Task {
            for await m in mids { received.update { $0.append(m) } }
        }
        try await settle()

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        guard let replacement = factory.socket(1) else { return XCTFail("no replacement socket") }
        replacement.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { replacement.sentActions.contains("ping") }

        // The original is carrying this same tick, so the warming copy is a
        // duplicate that must never reach consumers.
        replacement.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"999"},"deliverySeq":7}"#)
        try await settle()

        XCTAssertFalse(received.value.contains { $0["hl:0:BTC"] == "999" },
                       "warming-socket traffic must be dropped")

        consumer.cancel()
        await manager.disconnect()
    }

    func testIgnoresLateTrafficFromRetiredSocket() async throws {
        let manager = await makeConnectedManager()
        factory.socket(0)?.keepReceivingAfterStop = true
        let mids = await manager.midsEvents()
        let received = SendableBox<[[String: String]]>([])
        let consumer = Task {
            for await m in mids { received.update { $0.append(m) } }
        }
        try await settle()

        let (original, _) = try await promote(manager)

        // A frame the retired socket already had buffered when it was closed.
        original.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"555"},"deliverySeq":3}"#)
        try await settle()

        XCTAssertFalse(received.value.contains { $0["hl:0:BTC"] == "555" },
                       "a retired socket must not reach consumers")

        consumer.cancel()
        await manager.disconnect()
    }

    /// The server numbers deliveries per connection, and it numbers the frames
    /// it sends the warming socket too — snapshots and ticks the client drops
    /// while that socket is still warming. So the first frame the promoted
    /// socket actually delivers is already several numbers in, on a sequence
    /// that has nothing to do with the retired socket's. Carrying the old
    /// cursor across reads that offset as missed events and fires a REST
    /// refetch on every rotation.
    func testDoesNotReportDeliveryGapAcrossHandoff() async throws {
        let manager = await makeConnectedManager()
        let gaps = SendableBox<[Int]>([])
        _ = await manager.onGap { missed in gaps.update { $0.append(missed) } }
        try await settle()

        guard let original = factory.socket(0) else { return XCTFail("no original socket") }
        original.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"1"},"deliverySeq":2}"#)
        original.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"2"},"deliverySeq":3}"#)
        try await settle()
        XCTAssertTrue(gaps.value.isEmpty)

        let (_, replacement) = try await promote(manager)

        // Frames 1-8 on the new connection were the warm-up traffic it dropped.
        replacement.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"3"},"deliverySeq":9}"#)
        replacement.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"4"},"deliverySeq":10}"#)
        try await settle()

        XCTAssertTrue(gaps.value.isEmpty, "a rotation is not a gap; got \(gaps.value)")

        await manager.disconnect()
    }

    func testFiresRotatedButNotAuthenticated() async throws {
        let manager = await makeConnectedManager()
        let rotated = SendableBox<Int>(0)
        let authed = SendableBox<Int>(0)
        _ = await manager.onRotated { rotated.update { $0 += 1 } }
        _ = await manager.onAuthenticated { authed.update { $0 += 1 } }
        try await settle()

        _ = try await promote(manager)

        XCTAssertEqual(rotated.value, 1)
        XCTAssertEqual(authed.value, 0, "a rotation is not a re-auth for consumers")

        await manager.disconnect()
    }

    // MARK: - Failure handling

    func testKeepsOriginalServingWhenReplacementDies() async throws {
        let manager = await makeConnectedManager()
        let mids = await manager.midsEvents()
        let received = SendableBox<[[String: String]]>([])
        let consumer = Task {
            for await m in mids { received.update { $0.append(m) } }
        }
        let statuses = SendableBox<[ConnectionStatus]>([])
        let statusStream = await manager.statusStream
        let watcher = Task {
            for await s in statusStream { statuses.update { $0.append(s) } }
        }
        try await settle()

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        factory.socket(1)?.fail()
        try await settle()

        XCTAssertFalse(factory.socket(0)?.stopped ?? true, "the original must survive a failed handoff")
        let status = await manager.status
        XCTAssertEqual(status, .connected)
        XCTAssertEqual(statuses.value, [.connected],
                       "a failed handoff must not surface as a disconnect")

        guard let original = factory.socket(0) else { return XCTFail("no original socket") }
        original.deliver(#"{"type":"mids.updated","mids":{"hl:0:BTC":"77"},"deliverySeq":1}"#)
        try await waitFor { received.value.contains { $0["hl:0:BTC"] == "77" } }
        XCTAssertTrue(received.value.contains { $0["hl:0:BTC"] == "77" })

        consumer.cancel()
        watcher.cancel()
        await manager.disconnect()
    }

    func testAbandonsReplacementThatNeverCompletesHandoff() async throws {
        let manager = await makeConnectedManager()
        await manager.setHandoffTimeout(0.15)
        try await settle()

        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        guard let replacement = factory.socket(1) else { return XCTFail("no replacement socket") }

        // Never authenticates, so the barrier is never reached.
        try await waitFor(timeout: 1.0) { replacement.stopped }

        XCTAssertTrue(replacement.stopped, "a stalled replacement must be abandoned")
        XCTAssertFalse(factory.socket(0)?.stopped ?? true)
        let status = await manager.status
        XCTAssertEqual(status, .connected)

        await manager.disconnect()
    }

    // MARK: - Guards

    func testNoOpWhenDisconnected() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:19999")!,
            token: "t",
            realmId: "rlm_test"
        )
        await manager.setTransportFactory(factory.make())

        let started = await manager.rotateConnection()
        XCTAssertFalse(started)
        XCTAssertEqual(factory.count, 0)
    }

    func testDoesNotStartSecondHandoffInParallel() async throws {
        let manager = await makeConnectedManager()
        try await settle()

        let first = await manager.rotateConnection()
        XCTAssertTrue(first)
        try await waitFor { self.factory.count == 2 }
        let second = await manager.rotateConnection()
        XCTAssertFalse(second, "a handoff is already under way")
        try await settle()
        XCTAssertEqual(factory.count, 2)

        await manager.disconnect()
    }

    // MARK: - Scheduling

    func testAutoRotatesOnLifetimeSchedule() async throws {
        let manager = await makeConnectedManager(connectionLifetime: 0.2)
        try await waitFor(timeout: 2.0) { self.factory.count == 2 }
        XCTAssertEqual(factory.count, 2, "the lifetime schedule should have opened a replacement")
        await manager.disconnect()
    }

    func testNoRotationWhenLifetimeIsZero() async throws {
        let manager = await makeConnectedManager(connectionLifetime: 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(factory.count, 1, "a zero lifetime disables rotation")
        await manager.disconnect()
    }

    func testLifetimeZeroIgnoresServerReportedLifetime() async throws {
        // Production advertises a cap, so a server value that overrode an
        // explicit 0 would make the documented opt-out inoperative exactly where
        // it is reached for — during an incident, on the live fleet.
        let manager = await makeConnectedManager(
            connectionLifetime: 0,
            authFrame: #"{"type":"authenticated","maxConnectionLifetimeSec":0.2}"#
        )
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(factory.count, 1, "a configured 0 must outrank the server's lifetime")
        await manager.disconnect()
    }

    func testPrefersServerReportedLifetime() async throws {
        // The client figure is far outside the test window, so a rotation
        // inside it can only have come from the server's.
        let manager = await makeConnectedManager(
            connectionLifetime: 600,
            authFrame: #"{"type":"authenticated","maxConnectionLifetimeSec":0.2}"#
        )
        try await waitFor(timeout: 2.0) { self.factory.count == 2 }
        XCTAssertEqual(factory.count, 2, "the server-reported lifetime should win")
        await manager.disconnect()
    }

    // MARK: - Helpers

    private func makeConnectedManager(
        connectionLifetime: TimeInterval = WebSocketManager.defaultConnectionLifetime,
        authFrame: String = #"{"type":"authenticated"}"#
    ) async -> WebSocketManager {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:19999")!,
            token: "t",
            realmId: "rlm_test",
            connectionLifetime: connectionLifetime
        )
        await manager.setTransportFactory(factory.make())
        await manager.connect()
        try? await waitFor { self.factory.count >= 1 }
        factory.socket(0)?.deliver(authFrame)
        try? await waitFor { await manager.status == .connected }
        return manager
    }

    /// Run a full handoff and return the retired and promoted sockets.
    private func promote(_ manager: WebSocketManager) async throws
        -> (MockWebSocketTransport, MockWebSocketTransport) {
        guard let original = factory.socket(0) else {
            throw XCTSkip("no original socket")
        }
        await manager.rotateConnection()
        try await waitFor { self.factory.count == 2 }
        guard let replacement = factory.socket(1) else {
            throw XCTSkip("no replacement socket")
        }
        replacement.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { replacement.sentActions.contains("ping") }
        replacement.deliver(#"{"type":"pong"}"#)
        try await waitFor { original.stopped }
        return (original, replacement)
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
