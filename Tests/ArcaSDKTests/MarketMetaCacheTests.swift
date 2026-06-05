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

    // MARK: - market(_:) exact-id lookup

    func testMarketReturnsCachedMetadata() async throws {
        let arca = makeArca()

        let btc = try await arca.market("hl:0:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(btc?.symbol, "BTC")
        XCTAssertEqual(btc?.venueSymbol, "BTC")
        XCTAssertEqual(btc?.exchange, "hl")
        XCTAssertEqual(btc?.maxLeverage, 50)
        XCTAssertEqual(btc?.logoUrl, "https://example.com/btc.png")
        XCTAssertEqual(btc?.logoSources?.count, 1)
        XCTAssertEqual(btc?.logoSources?.first?.width, 128)
        XCTAssertEqual(btc?.assetType, "crypto")
        XCTAssertEqual(btc?.categoryLabel, "Crypto")
        XCTAssertEqual(btc?.mapped, true)
        XCTAssertEqual(btc?.hasLogo, true)
        XCTAssertEqual(btc?.descriptionStatus, "curated")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)
    }

    func testMarketReturnsNilForUnknownCoin() async throws {
        let arca = makeArca()

        let unknown = try await arca.market("hl:0:DOESNOTEXIST")
        XCTAssertNil(unknown)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)
    }

    func testSubsequentCallsUseCacheWithoutRefetch() async throws {
        let arca = makeArca()

        _ = try await arca.market("hl:0:BTC")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let eth = try await arca.market("hl:0:ETH")
        XCTAssertNotNil(eth)
        XCTAssertEqual(eth?.symbol, "ETH")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1, "Should not re-fetch")
    }

    func testPreloadPopulatesCache() async throws {
        let arca = makeArca()

        try await arca.preloadMarketMeta()
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let btc = try await arca.market("hl:0:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1, "Should use cached data")
    }

    func testRefreshReplacesCache() async throws {
        let arca = makeArca()

        let btc1 = try await arca.market("hl:0:BTC")
        XCTAssertNotNil(btc1)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        try await arca.refreshMarketMeta()
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should re-fetch on refresh")

        let btc2 = try await arca.market("hl:0:BTC")
        XCTAssertNotNil(btc2)
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should use refreshed cache")
    }

    func testHip3MarketLookup() async throws {
        let arca = makeArca()

        let tsla = try await arca.market("hl:1:TSLA")
        XCTAssertNotNil(tsla)
        XCTAssertEqual(tsla?.symbol, "TSLA")
        XCTAssertEqual(tsla?.venueSymbol, "xyz:TSLA")
        XCTAssertEqual(tsla?.displayName, "Tesla")
        XCTAssertEqual(tsla?.assetType, "equity")
        XCTAssertEqual(tsla?.categoryLabel, "Equity")
        XCTAssertEqual(tsla?.hasDisplayName, true)
        XCTAssertEqual(tsla?.descriptionStatus, "curated")
        XCTAssertEqual(tsla?.isHip3, true)
        XCTAssertEqual(tsla?.feeScale, 3.0)
    }

    func testRetriesAfterFailedFetch() async throws {
        MetaCacheMockProtocol.failNextN = 1
        let arca = makeArca()

        do {
            _ = try await arca.market("hl:0:BTC")
            XCTFail("Expected error on first call")
        } catch {
            // expected
        }
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 1)

        let btc = try await arca.market("hl:0:BTC")
        XCTAssertNotNil(btc)
        XCTAssertEqual(btc?.symbol, "BTC")
        XCTAssertEqual(MetaCacheMockProtocol.metaRequestCount, 2, "Should retry after failure")
    }

    // MARK: - resolveMarkets(_:exchange:dex:)

    func testResolveMarketsReturnsAllForSymbol() async throws {
        let arca = makeArca()

        let markets = try await arca.resolveMarkets("BTC")
        XCTAssertEqual(markets.count, 2)
        let names = Set(markets.map { $0.name })
        XCTAssertEqual(names, ["hl:0:BTC", "hl:1:BTC"])
    }

    func testResolveMarketsSingleMatch() async throws {
        let arca = makeArca()

        let markets = try await arca.resolveMarkets("ETH")
        XCTAssertEqual(markets.count, 1)
        XCTAssertEqual(markets.first?.name, "hl:0:ETH")
    }

    func testResolveMarketsNoMatchReturnsEmpty() async throws {
        let arca = makeArca()

        let markets = try await arca.resolveMarkets("NOPE")
        XCTAssertEqual(markets.count, 0)
    }

    func testResolveMarketsFilterByDex() async throws {
        let arca = makeArca()

        let markets = try await arca.resolveMarkets("BTC", dex: "xyz")
        XCTAssertEqual(markets.count, 1)
        XCTAssertEqual(markets.first?.name, "hl:1:BTC")
    }

    func testResolveMarketsFilterByExchange() async throws {
        let arca = makeArca()

        let hlMarkets = try await arca.resolveMarkets("BTC", exchange: "hl")
        XCTAssertEqual(hlMarkets.count, 2)

        let pmMarkets = try await arca.resolveMarkets("BTC", exchange: "pm")
        XCTAssertEqual(pmMarkets.count, 0)
    }

    func testResolveMarketsCaseSensitive() async throws {
        let arca = makeArca()

        let markets = try await arca.resolveMarkets("btc")
        XCTAssertEqual(markets.count, 0, "symbol match is case-sensitive")
    }

    // MARK: - resolveMarketOrThrow(_:exchange:dex:)

    func testResolveMarketOrThrowSingle() async throws {
        let arca = makeArca()

        let eth = try await arca.resolveMarketOrThrow("ETH")
        XCTAssertEqual(eth.name, "hl:0:ETH")
    }

    func testResolveMarketOrThrowZeroThrows() async throws {
        let arca = makeArca()

        do {
            _ = try await arca.resolveMarketOrThrow("NOPE")
            XCTFail("Expected throw for unknown symbol")
        } catch let ArcaError.validation(message, _) {
            XCTAssertTrue(message.contains("No market found"))
        }
    }

    func testResolveMarketOrThrowAmbiguousThrows() async throws {
        let arca = makeArca()

        do {
            _ = try await arca.resolveMarketOrThrow("BTC")
            XCTFail("Expected throw for ambiguous symbol")
        } catch let ArcaError.validation(message, _) {
            XCTAssertTrue(message.contains("ambiguous"))
        }
    }

    func testResolveMarketOrThrowNarrowedByDex() async throws {
        let arca = makeArca()

        let btc = try await arca.resolveMarketOrThrow("BTC", dex: "xyz")
        XCTAssertEqual(btc.name, "hl:1:BTC")
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
                "name": "hl:0:BTC",
                "dex": null,
                "symbol": "BTC",
                "venueSymbol": "BTC",
                "displayName": null,
                "logoUrl": "https://example.com/btc.png",
                "logoSources": [{"url": "https://example.com/btc-128.webp", "format": "webp", "width": 128}],
                "exchange": "hl",
                "assetType": "crypto",
                "categoryLabel": "Crypto",
                "mapped": true,
                "hasDisplayName": false,
                "hasLogo": true,
                "descriptionStatus": "curated",
                "isHip3": false,
                "deployerDisplayName": null,
                "index": 0,
                "szDecimals": 5,
                "maxLeverage": 50,
                "onlyIsolated": false,
                "feeScale": 1.0
              },
              {
                "name": "hl:0:ETH",
                "dex": null,
                "symbol": "ETH",
                "venueSymbol": "ETH",
                "displayName": null,
                "logoUrl": "https://example.com/eth.png",
                "exchange": "hl",
                "assetType": "crypto",
                "categoryLabel": "Crypto",
                "mapped": true,
                "hasDisplayName": false,
                "hasLogo": true,
                "descriptionStatus": "curated",
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
                "venueSymbol": "xyz:TSLA",
                "displayName": "Tesla",
                "logoUrl": "https://example.com/tsla.png",
                "exchange": "hl",
                "assetType": "equity",
                "categoryLabel": "Equity",
                "mapped": true,
                "hasDisplayName": true,
                "hasLogo": true,
                "descriptionStatus": "curated",
                "isHip3": true,
                "deployerDisplayName": "xyz",
                "index": 2,
                "szDecimals": 2,
                "maxLeverage": 5,
                "onlyIsolated": false,
                "feeScale": 3.0
              },
              {
                "name": "hl:1:BTC",
                "dex": "xyz",
                "symbol": "BTC",
                "venueSymbol": "xyz:BTC",
                "displayName": null,
                "logoUrl": "https://example.com/btc.png",
                "exchange": "hl",
                "assetType": "crypto",
                "categoryLabel": "Crypto",
                "mapped": true,
                "hasDisplayName": false,
                "hasLogo": true,
                "descriptionStatus": "curated",
                "isHip3": true,
                "deployerDisplayName": "xyz",
                "index": 3,
                "szDecimals": 5,
                "maxLeverage": 20,
                "onlyIsolated": false,
                "feeScale": 2.0
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
