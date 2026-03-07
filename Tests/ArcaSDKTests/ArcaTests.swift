import XCTest
@testable import ArcaSDK

final class ArcaTests: XCTestCase {

    // MARK: - JWT Decoding

    func testInitWithValidToken() throws {
        // JWT with payload: { "realmId": "rlm_test123", "sub": "usr_abc" }
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"realmId":"rlm_test123","sub":"usr_abc"}"#)
        let token = "\(header).\(payload).fakesignature"

        let arca = try Arca(token: token)
        XCTAssertEqual(arca.realm, "rlm_test123")
    }

    func testInitWithExplicitRealmId() throws {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"sub":"usr_abc"}"#)
        let token = "\(header).\(payload).fakesignature"

        let arca = try Arca(token: token, realmId: "rlm_explicit")
        XCTAssertEqual(arca.realm, "rlm_explicit")
    }

    func testInitFailsWithoutRealmId() {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"sub":"usr_abc"}"#)
        let token = "\(header).\(payload).fakesignature"

        XCTAssertThrowsError(try Arca(token: token)) { error in
            if case ArcaError.validation(let msg, _) = error {
                XCTAssertTrue(msg.contains("realmId"))
            } else {
                XCTFail("Expected validation error, got \(error)")
            }
        }
    }

    func testInitFailsWithInvalidJWT() {
        XCTAssertThrowsError(try Arca(token: "not-a-jwt")) { error in
            if case ArcaError.validation(let msg, _) = error {
                XCTAssertTrue(msg.contains("JWT"))
            } else {
                XCTFail("Expected validation error, got \(error)")
            }
        }
    }

    // MARK: - Event Types

    func testEventTypeRawValues() {
        XCTAssertEqual(EventType.operationCreated.rawValue, "operation.created")
        XCTAssertEqual(EventType.operationUpdated.rawValue, "operation.updated")
        XCTAssertEqual(EventType.balanceUpdated.rawValue, "balance.updated")
        XCTAssertEqual(EventType.exchangeUpdated.rawValue, "exchange.updated")
        XCTAssertEqual(EventType.aggregationUpdated.rawValue, "aggregation.updated")
        XCTAssertEqual(EventType.midsUpdated.rawValue, "mids.updated")
    }

    func testChannelRawValues() {
        XCTAssertEqual(Channel.operations.rawValue, "operations")
        XCTAssertEqual(Channel.balances.rawValue, "balances")
        XCTAssertEqual(Channel.exchange.rawValue, "exchange")
        XCTAssertEqual(Channel.objects.rawValue, "objects")
        XCTAssertEqual(Channel.agent.rawValue, "agent")
    }

    // MARK: - Exchange Enums

    func testOrderSideRawValues() {
        XCTAssertEqual(OrderSide.buy.rawValue, "BUY")
        XCTAssertEqual(OrderSide.sell.rawValue, "SELL")
    }

    func testOrderTypeRawValues() {
        XCTAssertEqual(OrderType.market.rawValue, "MARKET")
        XCTAssertEqual(OrderType.limit.rawValue, "LIMIT")
    }

    func testTimeInForceRawValues() {
        XCTAssertEqual(TimeInForce.gtc.rawValue, "GTC")
        XCTAssertEqual(TimeInForce.ioc.rawValue, "IOC")
        XCTAssertEqual(TimeInForce.alo.rawValue, "ALO")
    }

    // MARK: - Helpers

    private func base64url(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
