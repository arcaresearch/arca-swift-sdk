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

    func testSubscribeMessageEncoding() throws {
        let message = OutboundMessage.subscribe(channels: ["operations", "balances"])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "subscribe")
        XCTAssertEqual(json["channels"] as? [String], ["operations", "balances"])
    }

    func testUnsubscribeMessageEncoding() throws {
        let message = OutboundMessage.unsubscribe(channels: ["exchange"])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["action"] as? String, "unsubscribe")
        XCTAssertEqual(json["channels"] as? [String], ["exchange"])
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
}
