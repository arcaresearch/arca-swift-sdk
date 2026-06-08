import XCTest
@testable import ArcaSDK

final class WebSocketManagerTests: XCTestCase {

    // MARK: - WebSocket Message Encoding

    func testAuthMessageEncoding() throws {
        let message = OutboundMessage.auth(
            token: "jwt_token",
            realmId: "rlm_01abc",
            capabilities: ["server-authoritative-pricing"]
        )
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "auth")
        XCTAssertEqual(json["token"] as? String, "jwt_token")
        XCTAssertEqual(json["realmId"] as? String, "rlm_01abc")
        XCTAssertEqual(json["capabilities"] as? [String], ["server-authoritative-pricing"])
    }

    /// The WS manager advertises `ArcaClient.advertisedCapabilities` on every
    /// `auth` send. Pin that the server-authoritative-pricing capability is in
    /// the advertised set and survives encoding.
    func testAuthMessageAdvertisesServerPricingCapability() throws {
        XCTAssertTrue(ArcaClient.advertisedCapabilities.contains("server-authoritative-pricing"))
        let message = OutboundMessage.auth(
            token: "t", realmId: "r", capabilities: ArcaClient.advertisedCapabilities)
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let caps = json["capabilities"] as? [String]
        XCTAssertNotNil(caps)
        XCTAssertTrue(caps?.contains("server-authoritative-pricing") ?? false)
    }

    func testWatchMessageEncoding() throws {
        let message = OutboundMessage.watch(path: "/users/alice/main")
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "watch")
        XCTAssertEqual(json["path"] as? String, "/users/alice/main")
    }

    func testUnwatchMessageEncoding() throws {
        let message = OutboundMessage.unwatch(path: "/users/alice/main")
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "unwatch")
        XCTAssertEqual(json["path"] as? String, "/users/alice/main")
    }

    func testSubscribeMidsMessageEncoding() throws {
        let message = OutboundMessage.subscribeMids(exchange: "sim-hl", coins: ["BTC", "ETH"])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "subscribe_mids")
        XCTAssertEqual(json["exchange"] as? String, "sim-hl")
        XCTAssertEqual(json["coins"] as? [String], ["BTC", "ETH"])
    }

    func testUnsubscribeMidsMessageEncoding() throws {
        let message = OutboundMessage.unsubscribeMids
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "unsubscribe_mids")
    }

    // MARK: - Control Message Decoding

    func testAuthenticatedMessageDecoding() throws {
        let json = #"{"type":"authenticated","message":null}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(InboundControlMessage.self, from: json)
        XCTAssertEqual(msg.type, "authenticated")
    }

    func testErrorMessageDecoding() throws {
        let json = #"{"type":"error","message":"Invalid realm"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(InboundControlMessage.self, from: json)
        XCTAssertEqual(msg.type, "error")
        XCTAssertEqual(msg.message, "Invalid realm")
    }

    // MARK: - WebSocketManager State

    func testInitialStatus() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )
        let status = await manager.status
        XCTAssertEqual(status, .disconnected)
    }

    // MARK: - Subscribe Candles Message Encoding

    func testSubscribeCandlesMessageEncoding() throws {
        let message = OutboundMessage.subscribeCandles(coins: ["BTC"], intervals: ["1m", "5m"])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "subscribe_candles")
        XCTAssertEqual(json["coins"] as? [String], ["BTC"])
        XCTAssertEqual(json["intervals"] as? [String], ["1m", "5m"])
    }

    func testUnsubscribeCandlesMessageEncoding() throws {
        let message = OutboundMessage.unsubscribeCandles
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "unsubscribe_candles")
    }

    // MARK: - WatchStream Types

    func testSendableBoxValue() {
        let box = SendableBox([1, 2, 3])
        XCTAssertEqual(box.value, [1, 2, 3])
    }

    func testSendableBoxUpdate() {
        let box = SendableBox([1, 2, 3])
        box.update { $0.append(4) }
        XCTAssertEqual(box.value, [1, 2, 3, 4])
    }

    func testSendableBoxThreadSafety() {
        let box = SendableBox(0)
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                box.update { $0 += 1 }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(box.value, 100)
    }

    // MARK: - mids.snapshot normalization

    func testMidsSnapshotNormalizedToMidsUpdated() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let midsStream = await manager.midsEvents()

        let snapshotJSON = #"{"type":"mids.snapshot","mids":{"hl:0:BTC":"97000.5","hl:0:ETH":"3500.25"}}"#
        await manager.injectMessage(snapshotJSON)

        var received: [String: String]?
        let consumer = Task {
            for await mids in midsStream {
                received = mids
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        consumer.cancel()

        XCTAssertNotNil(received, "mids.snapshot should flow through midsEvents()")
        XCTAssertEqual(received?["hl:0:BTC"], "97000.5")
        XCTAssertEqual(received?["hl:0:ETH"], "3500.25")
    }

    func testMidsSnapshotEmptyMapStillDelivered() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let events = await manager.events

        let snapshotJSON = #"{"type":"mids.snapshot","mids":{}}"#
        await manager.injectMessage(snapshotJSON)

        var received: RealmEvent?
        let consumer = Task {
            for await event in events {
                received = event
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        XCTAssertNotNil(received, "Empty mids.snapshot should still be delivered")
        XCTAssertEqual(received?.type, EventType.midsUpdated.rawValue,
                       "mids.snapshot should be rewritten to mids.updated type")
        XCTAssertEqual(received?.mids, [:])
    }

    func testMidsUpdatedStillPassesThroughNormally() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let midsStream = await manager.midsEvents()

        let updateJSON = #"{"type":"mids.updated","mids":{"hl:0:BTC":"97100"},"deliverySeq":1}"#
        await manager.injectMessage(updateJSON)

        var received: [String: String]?
        let consumer = Task {
            for await mids in midsStream {
                received = mids
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        XCTAssertNotNil(received, "mids.updated should still pass through midsEvents()")
        XCTAssertEqual(received?["hl:0:BTC"], "97100")
    }

    func testExchangeNotificationsDeliverBareExchangeUpdated() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let exchangeNotifications = await manager.exchangeNotifications()
        await manager.injectMessage(#"{"type":"exchange.updated","entityId":"obj_1","entityPath":"/exchanges/main"}"#)

        var received: RealmEvent?
        let consumer = Task {
            for await event in exchangeNotifications {
                received = event
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        XCTAssertEqual(received?.type, EventType.exchangeUpdated.rawValue)
        XCTAssertEqual(received?.entityId, "obj_1")
        XCTAssertNil(received?.exchangeState)
    }

    // MARK: - watch_snapshot normalization

    func testWatchSnapshotValuationNormalizedToObjectValuation() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let valEvents = await manager.objectValuationEvents()

        let snapshotJSON = """
        {"type":"watch_snapshot","path":"/exchanges/strategy-1","watchId":"req_abc123","valuation":{"objectId":"obj_001","path":"/exchanges/strategy-1","type":"exchange","denomination":"USD","valueUsd":"200.00","balances":[{"denomination":"USD","amount":"200.00","valueUsd":"200.00"}]}}
        """
        await manager.injectMessage(snapshotJSON)

        var received: (ObjectValuation, String, String, RealmEvent)?
        let consumer = Task {
            for await item in valEvents {
                received = item
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        XCTAssertNotNil(received, "watch_snapshot should flow through objectValuationEvents()")
        let (valuation, path, watchId, _) = received!
        XCTAssertEqual(path, "/exchanges/strategy-1")
        XCTAssertEqual(watchId, "req_abc123")
        XCTAssertEqual(valuation.valueUsd, "200.00")
        XCTAssertEqual(valuation.objectId, "obj_001")
        XCTAssertEqual(valuation.type, "exchange")
    }

    func testWatchSnapshotWithoutValuationDoesNotEmit() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let valEvents = await manager.objectValuationEvents()

        let snapshotJSON = #"{"type":"watch_snapshot","path":"/wallets/main","watchId":"req_xyz"}"#
        await manager.injectMessage(snapshotJSON)

        var received: (ObjectValuation, String, String, RealmEvent)?
        let consumer = Task {
            for await item in valEvents {
                received = item
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        XCTAssertNil(received, "watch_snapshot without valuation should not emit object.valuation")
    }

    func testWatchSnapshotMultiObjectValuationsEmitPerPath() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let valEvents = await manager.objectValuationEvents()

        let snapshotJSON = """
        {"type":"watch_snapshot","path":"/","watchId":"req_multi","valuations":{"/exchanges/s1":{"objectId":"obj_1","path":"/exchanges/s1","type":"exchange","denomination":"USD","valueUsd":"500.00","balances":[{"denomination":"USD","amount":"500.00","valueUsd":"500.00"}]},"/exchanges/s2":{"objectId":"obj_2","path":"/exchanges/s2","type":"exchange","denomination":"USD","valueUsd":"300.00","balances":[{"denomination":"USD","amount":"300.00","valueUsd":"300.00"}]}}}
        """
        await manager.injectMessage(snapshotJSON)

        var received: [(ObjectValuation, String, String)] = []
        let consumer = Task {
            for await (val, path, watchId, _) in valEvents {
                received.append((val, path, watchId))
                if received.count >= 2 { break }
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()

        XCTAssertEqual(received.count, 2, "should emit one object.valuation per entry in valuations map")
        let paths = Set(received.map { $0.1 })
        XCTAssertTrue(paths.contains("/exchanges/s1"))
        XCTAssertTrue(paths.contains("/exchanges/s2"))
        for (_, _, watchId) in received {
            XCTAssertEqual(watchId, "req_multi")
        }
    }

    // MARK: - StoppedBox guard prevents yield after stop

    func testStoppedBoxPreventsYieldAfterStop() async {
        let continuationBox = SendableBox<AsyncStream<Int>.Continuation?>(nil)
        let stoppedBox = SendableBox<Bool>(false)
        var received = [Int]()

        let stream = AsyncStream<Int> { continuation in
            continuationBox.update { $0 = continuation }
        }

        let consumer = Task {
            for await value in stream {
                received.append(value)
            }
        }

        try? await Task.sleep(nanoseconds: 10_000_000)

        continuationBox.value?.yield(1)

        stoppedBox.update { $0 = true }
        continuationBox.update { $0 = nil }

        // Simulate a gap handler Task that checks stoppedBox before yielding
        // (the pattern we fixed). This should be a no-op.
        if !stoppedBox.value {
            continuationBox.value?.yield(2)
        }
        // Also verify that nil continuation prevents yield even without the guard
        continuationBox.value?.yield(3)

        try? await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()

        XCTAssertEqual(received, [1], "Only pre-stop yield should have been received")
    }

    // MARK: - Logger instrumentation

    func testServerErrorMessageEmitsErrorLogRecord() async throws {
        let handler = CapturingLogHandler()
        let logger = ArcaLogger(minLevel: .debug, handler: handler)
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test",
            logger: logger
        )

        await manager.injectMessage(#"{"type":"error","message":"Invalid realm"}"#)

        let deadline = Date().addingTimeInterval(0.5)
        while handler.records.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let errorRecords = handler.records.filter { $0.level == .error && $0.category == "websocket" }
        XCTAssertFalse(errorRecords.isEmpty,
                       "Server error message should emit an error-level websocket record")
        XCTAssertEqual(errorRecords.first?.metadata["message"], "Invalid realm")
    }

    func testDeliveryGapEmitsWarningLogRecord() async throws {
        let handler = CapturingLogHandler()
        let logger = ArcaLogger(minLevel: .debug, handler: handler)
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test",
            logger: logger
        )

        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"1"},"deliverySeq":1}"#)
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"2"},"deliverySeq":5}"#)

        let deadline = Date().addingTimeInterval(0.5)
        while !handler.records.contains(where: { $0.message.contains("delivery gap") }),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let gapRecords = handler.records.filter { $0.message.contains("delivery gap") }
        XCTAssertFalse(gapRecords.isEmpty, "Delivery gap should emit a warning record")
        XCTAssertEqual(gapRecords.first?.level, .warning)
        XCTAssertEqual(gapRecords.first?.metadata["missed"], "3")
    }

    // MARK: - Resume / Authenticated lifecycle

    func testTriggerResumeFiresOnResumeHandlersWithDuration() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )
        let captured = SendableBox<[TimeInterval]>([])
        _ = await manager.onResume { duration in
            captured.update { $0.append(duration) }
        }

        await manager.triggerResume(hiddenDuration: 30.0)

        XCTAssertEqual(captured.value, [30.0])
    }

    func testRemoveResumeHandlerStopsFurtherCalls() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )
        let captured = SendableBox<[TimeInterval]>([])
        let id = await manager.onResume { duration in
            captured.update { $0.append(duration) }
        }

        await manager.triggerResume(hiddenDuration: 10.0)
        await manager.removeResumeHandler(id)
        await manager.triggerResume(hiddenDuration: 20.0)

        XCTAssertEqual(captured.value, [10.0])
    }

    func testAuthenticatedHandlerFiresOnEveryAuthMessage() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )
        let count = SendableBox<Int>(0)
        _ = await manager.onAuthenticated {
            count.update { $0 += 1 }
        }

        // Two synthetic re-auths (e.g. token refresh path) — both fire.
        await manager.injectMessage(#"{"type":"authenticated","message":null}"#)
        await manager.injectMessage(#"{"type":"authenticated","message":null}"#)

        // injectMessage is async-dispatched; give the actor a chance to drain.
        let deadline = Date().addingTimeInterval(0.5)
        while count.value < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(count.value, 2)
    }

    func testAuthenticatedHandlerDoesNotFireForAuthBeforeRegistration() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        // Authenticate first.
        await manager.injectMessage(#"{"type":"authenticated","message":null}"#)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Register AFTER auth — should NOT retroactively fire.
        let count = SendableBox<Int>(0)
        _ = await manager.onAuthenticated {
            count.update { $0 += 1 }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(count.value, 0)
    }

    func testRemoveAuthenticatedHandlerStopsFurtherCalls() async {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )
        let count = SendableBox<Int>(0)
        let id = await manager.onAuthenticated {
            count.update { $0 += 1 }
        }

        await manager.injectMessage(#"{"type":"authenticated","message":null}"#)
        // Wait for first fire.
        let deadline1 = Date().addingTimeInterval(0.5)
        while count.value < 1, Date() < deadline1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        await manager.removeAuthenticatedHandler(id)
        await manager.injectMessage(#"{"type":"authenticated","message":null}"#)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(count.value, 1)
    }

    // MARK: - Malformed payload hardening (NSInvalidArgumentException)

    /// A `candles.updated` frame whose `candle` field is a JSON *fragment*
    /// (a bare number rather than an object) must be skipped, not crash the
    /// process. Before the `JSONSafe`/`isValidJSONObject` guard,
    /// `JSONSerialization.data(withJSONObject:)` raised an Obj-C
    /// `NSInvalidArgumentException` that `try?` could not catch, aborting the
    /// host app with `SIGABRT`. This test would crash the test runner without
    /// the fix.
    func testCandlesUpdatedFragmentCandleIsSkippedWithoutCrashing() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let events = await manager.events

        let received = SendableBox<[RealmEvent]>([])
        let consumer = Task {
            for await event in events {
                received.update { $0.append(event) }
            }
        }

        // `candle` is a bare number (fragment) — the exact off-the-wire shape
        // that triggered the production crash.
        await manager.injectMessage(
            #"{"type":"candles.updated","candles":[{"market":"hl:0:BTC","interval":"1m","candle":0}]}"#)

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        let candleEvents = received.value.filter { $0.type == EventType.candleUpdated.rawValue }
        XCTAssertTrue(candleEvents.isEmpty,
                      "A fragment `candle` value must be skipped, emitting no candle event")
    }

    /// Positive control: a well-formed `candles.updated` frame still decodes and
    /// emits a `candle.updated` event after the guard is added.
    func testCandlesUpdatedValidCandleStillEmits() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let events = await manager.events

        let received = SendableBox<[RealmEvent]>([])
        let consumer = Task {
            for await event in events {
                received.update { $0.append(event) }
            }
        }

        await manager.injectMessage(#"""
        {"type":"candles.updated","candles":[{"market":"hl:0:BTC","interval":"1m","candle":{"t":1,"o":"100","h":"110","l":"90","c":"105","v":"12","n":3}}]}
        """#)

        let deadline = Date().addingTimeInterval(0.5)
        while received.value.allSatisfy({ $0.type != EventType.candleUpdated.rawValue }),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        consumer.cancel()

        let candleEvents = received.value.filter { $0.type == EventType.candleUpdated.rawValue }
        XCTAssertEqual(candleEvents.count, 1, "A valid candle should emit exactly one candle event")
        XCTAssertEqual(candleEvents.first?.market, "hl:0:BTC")
        XCTAssertEqual(candleEvents.first?.interval, "1m")
        XCTAssertEqual(candleEvents.first?.candle?.c, "105")
    }

    /// A `watch_snapshot` frame whose `valuation` is a fragment must be skipped
    /// rather than aborting the process (same Obj-C exception class as the
    /// candle path).
    func testWatchSnapshotFragmentValuationIsSkippedWithoutCrashing() async throws {
        let manager = WebSocketManager(
            baseURL: URL(string: "http://localhost:3052")!,
            token: "test",
            realmId: "rlm_test"
        )

        let events = await manager.events

        let received = SendableBox<[RealmEvent]>([])
        let consumer = Task {
            for await event in events {
                received.update { $0.append(event) }
            }
        }

        // Both the single `valuation` and a `valuations` map entry are fragments.
        await manager.injectMessage(#"""
        {"type":"watch_snapshot","watchId":"w1","path":"/a","valuation":42,"valuations":{"/b":"oops"}}
        """#)

        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()

        let valuationEvents = received.value.filter { $0.type == EventType.objectValuation.rawValue }
        XCTAssertTrue(valuationEvents.isEmpty,
                      "Fragment valuation values must be skipped, emitting no valuation event")
    }
}
