import XCTest
@testable import ArcaSDK

final class ExchangeProvisioningTests: XCTestCase {
    /// The wire strings are the contract with the server. A typo here means the
    /// client never sees the event, which is indistinguishable from the account
    /// never becoming ready.
    func testEventTypeWireStrings() {
        XCTAssertEqual(EventType.exchangeProvisioned.rawValue, "exchange.provisioned")
        XCTAssertEqual(EventType.exchangeReady.rawValue, "exchange.ready")
        XCTAssertEqual(EventType.depositDetected.rawValue, "deposit.detected")
    }

    /// A provisioned event on a cosign-armed boundary is the case the two-event
    /// split exists for: the account is usable for reads but cannot trade until
    /// the user co-signs, so the two flags must decode independently.
    func testDecodesProvisionedOnArmedBoundary() throws {
        let json = """
        {
          "type": "exchange.provisioned",
          "entityId": "obj_1",
          "entityPath": "/users/alice/exchange",
          "exchange": {
            "objectId": "obj_1",
            "path": "/users/alice/exchange",
            "cosignRequired": true,
            "tradable": false,
            "accountAddress": "0x8f2a"
          }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RealmEvent.self, from: json)
        let exchange = try XCTUnwrap(
            event.exchange,
            "the payload must decode, or the event arrives with nothing actionable on it")
        XCTAssertEqual(exchange.cosignRequired, true)
        XCTAssertEqual(exchange.tradable, false, "provisioned on an armed boundary cannot trade yet")
        XCTAssertEqual(exchange.accountAddress, "0x8f2a")
    }

    func testDecodesReady() throws {
        let json = """
        {"type":"exchange.ready","entityId":"obj_1","exchange":{"tradable":true,"cosignRequired":false}}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RealmEvent.self, from: json)
        XCTAssertEqual(event.exchange?.tradable, true)
    }

    func testDecodesDetectedDeposit() throws {
        let json = """
        {"type":"deposit.detected","deposit":{"address":"0xabc","amount":"15","sweeping":true}}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(RealmEvent.self, from: json)
        XCTAssertEqual(event.deposit?.amount, "15")
        XCTAssertEqual(event.deposit?.sweeping, true)
    }
}
