import XCTest
@testable import ArcaSDK

final class WebSocketManagerTests: XCTestCase {

    // MARK: - WebSocket Message Encoding

    func testAuthMessageEncoding() throws {
        let message = OutboundMessage.auth(token: "jwt_token", realmId: "rlm_01abc")
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "auth")
        XCTAssertEqual(json["token"] as? String, "jwt_token")
        XCTAssertEqual(json["realmId"] as? String, "rlm_01abc")
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
}
