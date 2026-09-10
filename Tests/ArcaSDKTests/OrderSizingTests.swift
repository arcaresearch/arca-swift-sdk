import XCTest
@testable import ArcaSDK

final class OrderSizingTests: XCTestCase {
    func testExactDownwardLots() throws {
        XCTAssertEqual(try Arca.normalizedReductionSize(size: "0.17552", fraction: "0.5", decimals: 5), "0.08776")
        XCTAssertEqual(try Arca.normalizedReductionSize(size: "0.17553", fraction: "0.5", decimals: 5), "0.08776")
        XCTAssertEqual(try Arca.normalizedReductionSize(size: "123456789.123456789", fraction: "1", decimals: 9), "123456789.123456789")
        XCTAssertEqual(try Arca.normalizedReductionSize(size: "5", fraction: "0.5", decimals: 0), "2")
    }
    func testInvalidAndSubLotInputsFailClosed() {
        for size in ["0", "-1", "NaN", "1junk", "1e9", " 1"] {
            XCTAssertThrowsError(try Arca.normalizedReductionSize(size: size, fraction: "1", decimals: 5))
        }
        for fraction in ["0", "-1", "1.1", "NaN"] {
            XCTAssertThrowsError(try Arca.normalizedReductionSize(size: "1", fraction: fraction, decimals: 5))
        }
        XCTAssertThrowsError(try Arca.normalizedReductionSize(size: "0.00001", fraction: "0.5", decimals: 5))
        XCTAssertThrowsError(try Arca.normalizedReductionSize(size: "1", fraction: "1", decimals: -1))
    }
}

final class OrderSizingHTTPTests: XCTestCase {
    func testCanonicalMetadataBothFamiliesAndAccountCapabilities() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrderSizingProtocol.self]
        let arca = try Arca(token: "fixture", baseURL: URL(string: "https://sizing.test")!, realmId: "realm", urlSessionConfiguration: config)
        let hl = try await arca.normalizedReductionSize(market: "hl:0:BTC", size: "0.17553", fraction: "0.5")
        let atlas = try await arca.normalizedReductionSize(market: "gllt:13", size: "0.17553", fraction: "0.5")
        XCTAssertEqual(hl, "0.08776")
        XCTAssertEqual(atlas, "0.087")
        do { _ = try await arca.normalizedReductionSize(market: "missing", size: "1", fraction: "1"); XCTFail("Missing metadata must fail") } catch {}
        let capabilities = try await arca.getExchangeCapabilities(objectId: "account")
        XCTAssertEqual(capabilities.objectId, "account")
        XCTAssertFalse(capabilities.brackets)
        do { _ = try await arca.getExchangeCapabilities(objectId: "different"); XCTFail("Wrong account must fail") } catch {}
    }
}

private final class OrderSizingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data = request.url!.path.hasSuffix("/meta")
            ? #"{"universe":[{"name":"hl:0:BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false},{"name":"gllt:13","symbol":"SP500","exchange":"gll","index":13,"szDecimals":3,"maxLeverage":10,"onlyIsolated":false}]}"#
            : #"{"objectId":"account","orderTypes":["MARKET","LIMIT"],"timeInForce":["GTC","IOC"],"marginModes":["cross"],"leverageSelection":true,"positionTriggers":false,"brackets":false,"orderKeyRetirement":true}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("{\"success\":true,\"data\":" + data + "}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
