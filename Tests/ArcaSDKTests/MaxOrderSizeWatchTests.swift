import XCTest
@testable import ArcaSDK

/// Integration tests for `Arca.watchMaxOrderSize`.
///
/// These mirror the TypeScript SDK's `MaxOrderSizeWatchStream` tests for
/// dynamic MMR resolution. The pure-function `deriveActiveAssetData` is
/// covered separately in `ActiveAssetDerivationTests`; the value of these
/// tests is in exercising the watch stream's wiring — proving that:
///
/// 1. `watchMaxOrderSize` actually calls `getActiveAssetData` to resolve MMR
///    when the caller doesn't supply one.
/// 2. The resolved MMR (e.g. `0.01` for BTC, derived from the asset's margin
///    table) flows into the first `ActiveAssetData` emitted by the stream
///    instead of the hardcoded `0.03` fallback.
/// 3. The MMR persists across price recomputes — every subsequent emit from
///    the live mids stream must carry the same dynamic MMR, otherwise
///    `Arca.orderBreakdown`'s liquidation estimate flips between the right
///    value and `0.03` as prices tick.
/// 4. When the caller supplies an explicit MMR, the stream uses it verbatim
///    and does NOT make the extra `getActiveAssetData` HTTP call.
final class MaxOrderSizeWatchTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MaxOrderSizeMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        MaxOrderSizeMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        MaxOrderSizeMockProtocol.reset()
        super.tearDown()
    }

    // MARK: - Auto-fetch MMR

    func testAutoFetchesDynamicMaintenanceMarginRateWhenOmitted() async throws {
        // Backend returns 0.01 (a real value for tiered assets like BTC).
        // Without auto-fetch, the stream would emit 0.03 — the old hardcoded
        // default — and `orderBreakdown`'s liquidation price would be wrong
        // for every tiered asset.
        MaxOrderSizeMockProtocol.maintenanceMarginRate = "0.01"

        let arca = makeArca()
        let watchTask = Task { () -> MaxOrderSizeWatchStream in
            try await arca.watchMaxOrderSize(options: MaxOrderSizeWatchOptions(
                objectId: "obj_1",
                coin: "hl:BTC",
                side: .buy,
                leverage: 5,
                feeScale: 1.0
            ))
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await arca.ws.injectMessage(#"{"type":"mids.snapshot","mids":{"hl:BTC":"80000"}}"#)

        let stream = try await watchTask.value
        await stream.ready()

        XCTAssertEqual(stream.activeAssetData.value?.maintenanceMarginRate, "0.01",
                       "Stream must surface the per-asset MMR resolved at construction, not the 0.03 fallback")
        XCTAssertEqual(MaxOrderSizeMockProtocol.activeAssetDataRequestCount, 1,
                       "watchMaxOrderSize should fetch MMR once via getActiveAssetData when not provided")

        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Explicit override

    func testHonorsExplicitMaintenanceMarginRateWithoutFetching() async throws {
        // When the caller already knows the MMR (e.g. cached from a prior
        // call), we must not pay for an extra round trip — and we must not
        // overwrite their value with whatever the server happens to return.
        MaxOrderSizeMockProtocol.maintenanceMarginRate = "0.01"

        let arca = makeArca()
        let watchTask = Task { () -> MaxOrderSizeWatchStream in
            try await arca.watchMaxOrderSize(options: MaxOrderSizeWatchOptions(
                objectId: "obj_1",
                coin: "hl:BTC",
                side: .buy,
                leverage: 5,
                feeScale: 1.0,
                maintenanceMarginRate: "0.005"
            ))
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await arca.ws.injectMessage(#"{"type":"mids.snapshot","mids":{"hl:BTC":"80000"}}"#)

        let stream = try await watchTask.value
        await stream.ready()

        XCTAssertEqual(stream.activeAssetData.value?.maintenanceMarginRate, "0.005",
                       "Caller-supplied MMR must win over the auto-fetched value")
        XCTAssertEqual(MaxOrderSizeMockProtocol.activeAssetDataRequestCount, 0,
                       "Explicit MMR must short-circuit the getActiveAssetData fetch")

        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Persistence across recomputes

    func testMaintenanceMarginRatePersistsAcrossPriceUpdates() async throws {
        // Regression: an earlier implementation resolved MMR once but then
        // dropped it on every recompute, so the very next mids tick would
        // emit 0.03. Verify a price update keeps the dynamic value.
        MaxOrderSizeMockProtocol.maintenanceMarginRate = "0.012"

        let arca = makeArca()
        let watchTask = Task { () -> MaxOrderSizeWatchStream in
            try await arca.watchMaxOrderSize(options: MaxOrderSizeWatchOptions(
                objectId: "obj_1",
                coin: "hl:BTC",
                side: .buy,
                leverage: 5,
                feeScale: 1.0
            ))
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await arca.ws.injectMessage(#"{"type":"mids.snapshot","mids":{"hl:BTC":"80000"}}"#)

        let stream = try await watchTask.value
        await stream.ready()

        XCTAssertEqual(stream.activeAssetData.value?.maintenanceMarginRate, "0.012")

        let received = expectation(description: "received recomputed update on price tick")
        let consumer = Task {
            for await update in stream.updates {
                XCTAssertEqual(update.maintenanceMarginRate, "0.012",
                               "Recomputes triggered by mids must reuse the dynamic MMR")
                received.fulfill()
                return
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await arca.ws.injectMessage(#"{"type":"mids.updated","mids":{"hl:BTC":"80100"},"deliverySeq":1}"#)

        await fulfillment(of: [received], timeout: 1.0)
        XCTAssertEqual(stream.activeAssetData.value?.maintenanceMarginRate, "0.012",
                       "Latest snapshot on the box must still carry the dynamic MMR")

        consumer.cancel()
        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Helpers

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

// MARK: - URLProtocol mock

private final class MaxOrderSizeMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _activeAssetDataRequestCount = 0
    private static var _maintenanceMarginRate: String = "0.01"

    static var activeAssetDataRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _activeAssetDataRequestCount
    }

    static var maintenanceMarginRate: String {
        get { lock.lock(); defer { lock.unlock() }; return _maintenanceMarginRate }
        set { lock.lock(); _maintenanceMarginRate = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock()
        _activeAssetDataRequestCount = 0
        _maintenanceMarginRate = "0.01"
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.hasPrefix("/api/v1/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: String
        var status = 200

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
                  "equity": "10000",
                  "initialMarginUsed": "0",
                  "maintenanceMarginRequired": "0",
                  "availableToWithdraw": "10000",
                  "totalNtlPos": "0",
                  "totalUnrealizedPnl": "0"
                },
                "positions": [],
                "openOrders": [],
                "feeRates": {
                  "taker": "0.00035",
                  "maker": "0.0001",
                  "platformFee": "0.0001"
                },
                "pendingIntents": []
              }
            }
            """#

        case "/api/v1/objects/obj_1/exchange/active-asset-data":
            Self.lock.lock()
            Self._activeAssetDataRequestCount += 1
            let mmr = Self._maintenanceMarginRate
            Self.lock.unlock()
            body = """
            {
              "success": true,
              "data": {
                "coin": "hl:BTC",
                "leverage": { "type": "cross", "value": 5 },
                "maxBuySize": "0",
                "maxSellSize": "0",
                "maxBuyUsd": "0",
                "maxSellUsd": "0",
                "availableToTrade": "10000",
                "markPx": "80000",
                "feeRate": "0.00045",
                "maintenanceMarginRate": "\(mmr)"
              }
            }
            """

        default:
            body = #"{"success":false,"error":{"code":"NOT_FOUND","message":"Not found"}}"#
            status = 404
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
