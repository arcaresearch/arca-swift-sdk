import XCTest
@testable import ArcaSDK

final class ExchangeStateWatchTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ExchangeStateWatchProtocol.self] + (sessionConfig.protocolClasses ?? [])
        ExchangeStateWatchProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        ExchangeStateWatchProtocol.reset()
        super.tearDown()
    }

    func testWatchExchangeStateUsesInlineStateWhenPendingIntentsPresent() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)

        let updated = expectation(description: "inline exchange state applied")
        let observer = stream.exchangeState.onChange { state in
            if state?.pendingIntents?.count == 1 {
                updated.fulfill()
            }
        }

        await arca.ws.injectMessage(#"""
        {
          "type": "exchange.updated",
          "entityId": "obj_1",
          "entityPath": "/exchanges/main",
          "exchangeState": {
            "account": {
              "id": "act_1",
              "realmId": "rlm_test",
              "name": "main",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            },
            "marginSummary": {
              "equity": "1200",
              "initialMarginUsed": "0",
              "maintenanceMarginRequired": "0",
              "availableToWithdraw": "1200",
              "totalNtlPos": "0",
              "totalUnrealizedPnl": "0"
            },
            "positions": [],
            "openOrders": [],
            "pendingIntents": [
              {
                "operationId": "op_1",
                "operationPath": "/ops/1",
                "coin": "hl:BTC",
                "side": "BUY",
                "size": "0.1",
                "orderType": "MARKET",
                "reduceOnly": false,
                "createdAt": "2026-01-01T00:00:00Z"
              }
            ]
          }
        }
        """#)

        await fulfillment(of: [updated], timeout: 1.0)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)

        stream.exchangeState.removeObserver(observer)
        await stream.stop()
        await arca.ws.disconnect()
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19999")!,
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
}

private final class ExchangeStateWatchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _stateRequestCount = 0

    static var stateRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stateRequestCount
    }

    static func reset() {
        lock.lock()
        _stateRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.hasPrefix("/api/v1/objects/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: String
        switch url.path {
        case "/api/v1/objects/obj_1":
            body = #"""
            {
              "success": true,
              "data": {
                "object": {
                  "id": "obj_1",
                  "realmId": "rlm_test",
                  "path": "/exchanges/main",
                  "type": "exchange",
                  "denomination": "USD",
                  "status": "active",
                  "metadata": null,
                  "deletedAt": null,
                  "systemOwned": false,
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-01T00:00:00Z"
                },
                "operations": [],
                "events": [],
                "deltas": [],
                "balances": []
              }
            }
            """#
        case "/api/v1/objects/obj_1/exchange/state":
            Self.lock.lock()
            Self._stateRequestCount += 1
            Self.lock.unlock()
            body = #"""
            {
              "success": true,
              "data": {
                "account": {
                  "id": "act_1",
                  "realmId": "rlm_test",
                  "name": "main",
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-01T00:00:00Z"
                },
                "marginSummary": {
                  "equity": "1000",
                  "initialMarginUsed": "0",
                  "maintenanceMarginRequired": "0",
                  "availableToWithdraw": "1000",
                  "totalNtlPos": "0",
                  "totalUnrealizedPnl": "0"
                },
                "positions": [],
                "openOrders": [],
                "pendingIntents": []
              }
            }
            """#
        default:
            body = #"{"success":false,"error":{"code":"NOT_FOUND","message":"Not found"}}"#
        }

        let statusCode = url.path == "/api/v1/objects/obj_1" || url.path == "/api/v1/objects/obj_1/exchange/state" ? 200 : 404
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
