import XCTest
@testable import ArcaSDK

final class MarketMetaCacheTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MetaCacheMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        MetaCacheMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        MetaCacheMockProtocol.reset()
        super.tearDown()
    }

    // MARK: - Tests

    func testAssetReturnsCachedMetadata() async throws {
        let arca = makeArca()

        let btc = try await arca.asset("hl:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(btc?.symbol, "BTC")
        XCTAssertEqual(btc?.exchange, "hl")
        XCTAssertEqual(btc?.maxLeverage, 50)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)
    }

    func testAssetReturnsNilForUnknownCoin() async throws {
        let arca = makeArca()

        let unknown = try await arca.asset("hl:DOESNOTEXIST")
        XCTAssertNil(unknown)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)
    }

    func testSubsequentCallsUseCacheWithoutRefetch() async throws {
        let arca = makeArca()

        _ = try await arca.asset("hl:BTC")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let eth = try await arca.asset("hl:ETH")
        XCTAssertNotNil(eth)
        XCTAssertEqual(eth?.symbol, "ETH")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1, "Should not re-fetch")
    }

    func testPreloadPopulatesCache() async throws {
        let arca = makeArca()

        try await arca.preloadMarketMeta()
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let btc = try await arca.asset("hl:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1, "Should use cached data")
    }

    func testRefreshReplacesCache() async throws {
        let arca = makeArca()

        let btc1 = try await arca.asset("hl:BTC")
        XCTAssertNotNil(btc1)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        try await arca.refreshMarketMeta()
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should re-fetch on refresh")

        let btc2 = try await arca.asset("hl:BTC")
        XCTAssertNotNil(btc2)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should use refreshed cache")
    }

    func testHip3AssetLookup() async throws {
        let arca = makeArca()

        let tsla = try await arca.asset("hl:1:TSLA")
        XCTAssertNotNil(tsla)
        XCTAssertEqual(tsla?.symbol, "TSLA")
        XCTAssertEqual(tsla?.displayName, "Tesla")
        XCTAssertEqual(tsla?.isHip3, true)
        XCTAssertEqual(tsla?.feeScale, 3.0)
    }

    func testRetriesAfterFailedFetch() async throws {
        MetaCacheMockProtocol.failNextN = 1
        let arca = makeArca()

        do {
            _ = try await arca.asset("hl:BTC")
            XCTFail("Expected error on first call")
        } catch {
            // expected
        }
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let btc = try await arca.asset("hl:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(btc?.symbol, "BTC")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should retry after failure")
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

// MARK: - Mock URLProtocol

private final class MetaCacheMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _metaRequestCount = 0
    static var failNextN = 0

    static var metaRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _metaRequestCount
    }

    static func reset() {
        lock.lock()
        _metaRequestCount = 0
        failNextN = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.contains("/exchange/market/meta")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self._metaRequestCount += 1
        let shouldFail = Self.failNextN > 0
        if shouldFail { Self.failNextN -= 1 }
        Self.lock.unlock()

        if shouldFail {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let errorBody = Data(#"{"success":false,"error":{"code":"INTERNAL","message":"boom"}}"#.utf8)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: errorBody)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let body = #"""
        {
          "success": true,
          "data": {
            "universe": [
              {
                "name": "hl:BTC",
                "dex": null,
                "symbol": "BTC",
                "displayName": null,
                "logoUrl": "https://example.com/btc.png",
                "exchange": "hl",
                "isHip3": false,
                "deployerDisplayName": null,
                "index": 0,
                "szDecimals": 5,
                "maxLeverage": 50,
                "onlyIsolated": false,
                "feeScale": 1.0
              },
              {
                "name": "hl:ETH",
                "dex": null,
                "symbol": "ETH",
                "displayName": null,
                "logoUrl": "https://example.com/eth.png",
                "exchange": "hl",
                "isHip3": false,
                "deployerDisplayName": null,
                "index": 1,
                "szDecimals": 4,
                "maxLeverage": 50,
                "onlyIsolated": false,
                "feeScale": 1.0
              },
              {
                "name": "hl:1:TSLA",
                "dex": "xyz",
                "symbol": "TSLA",
                "displayName": "Tesla",
                "logoUrl": "https://example.com/tsla.png",
                "exchange": "hl",
                "isHip3": true,
                "deployerDisplayName": "xyz",
                "index": 2,
                "szDecimals": 2,
                "maxLeverage": 5,
                "onlyIsolated": false,
                "feeScale": 3.0
              }
            ]
          }
        }
        """#

        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
