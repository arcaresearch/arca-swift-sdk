import XCTest
@testable import ArcaSDK

final class TradingAllocationRuntimeTests: XCTestCase {
    func testExistingLeverageAndMirrorQuoteWireContracts() async throws {
        AllocationMockProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AllocationMockProtocol.self]
        let payload = Data(#"{"realmId":"rlm_test","sub":"user"}"#.utf8).base64EncodedString()
        let arca = try Arca(token: "e30.\(payload).signature", baseURL: URL(string: "http://allocation.test")!, urlSessionConfiguration: config)
        let result = try await arca.updateLeverage(objectId: "obj", market: "gllt:3", leverage: 8, mode: .fixed, commandId: "same-retry")
        XCTAssertNil(result.leverage)
        XCTAssertEqual(result.intendedLeverage, 8)
        XCTAssertEqual(result.revision, "9007199254740993")
        _ = try await arca.updateLeverage(objectId: "obj", market: "gllt:3", mode: .venueDefault)
        _ = try await arca.updateLeverage(objectId: "obj", market: "hl:0:BTC", leverage: 5)
        let settings = try await arca.getLeverage(objectId: "obj", market: "gllt:3")
        XCTAssertNil(settings[0].leverage)
        XCTAssertEqual(settings[0].intendedLeverage, 8)
        let read = try await arca.getTradingAllocation(objectId: "obj", market: "gllt:3")
        XCTAssertFalse(read.enabled)
        XCTAssertTrue(read.allocation.projectionUnavailable)
        XCTAssertNil(read.allocation.projection)
        let quote = try await arca.quoteTradingAllocation(objectId: "obj", request: .init(market: "gllt:3", side: .buy, orderType: "market", selection: .init(mode: .fixed, leverage: 1)))
        XCTAssertEqual(quote.maximum.maxSize, "1.234567890123456789")
        XCTAssertEqual(quote.affordable, false)
        _ = try await arca.placeOrder(path: "/op/1", objectId: "obj", market: "gllt:3", side: .buy, orderType: .market, size: "1", leverage: 1, leverageMode: .fixed, slippageBps: 100).submitted
        let requests = AllocationMockProtocol.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests[0].0.hasSuffix("/exchange/leverage"))
        XCTAssertEqual(requests[0].1["mode"] as? String, "fixed")
        XCTAssertEqual(requests[0].1["commandId"] as? String, "same-retry")
        XCTAssertNil(requests[1].1["leverage"])
        XCTAssertEqual(requests[1].1["mode"] as? String, "venue-default")
        XCTAssertNotNil(requests[1].1["commandId"])
        XCTAssertEqual(requests[2].1.count, 2, "HL request shape remains unchanged")
        XCTAssertTrue(requests[4].0.contains("market=gllt"))
        XCTAssertTrue(requests[5].0.hasSuffix("/allocation/quote"))
        XCTAssertEqual(requests[6].1["leverageMode"] as? String, "fixed")
        XCTAssertEqual(requests[6].1["slippageBps"] as? Int, 100)
    }
}

private final class AllocationMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [(String, [String: Any])] = []
    static var requests: [(String, [String: Any])] { lock.lock(); defer {lock.unlock()}; return captured }
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "allocation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 {break}; data.append(contentsOf: buffer.prefix(count)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.captured.append((request.url!.absoluteString, body)); Self.lock.unlock()
        let path = request.url!.path
        let state = #"{"revision":"9007199254740993","preferences":{},"projectionUnavailable":true}"#
        var response: String
        if path.hasSuffix("/leverage") {
            response = request.httpMethod == "GET" ? #"{"market":"gllt:3","leverage":null,"marginMode":"cross","mode":"fixed","intendedLeverage":8}"# : #"{"accountId":"a","market":"gllt:3","leverage":null,"previousLeverage":null,"mode":"fixed","intendedLeverage":8,"revision":"9007199254740993"}"#
        } else if path.hasSuffix("/allocation/quote") {
            response = "{\"inputId\":\"input\",\"market\":\"gllt:3\",\"referencePrice\":\"1000\",\"limitPrice\":\"1010.0\",\"allocation\":\(state),\"maximum\":{\"revision\":\"2\",\"maxSize\":\"1.234567890123456789\",\"maxNotional\":\"1234.567890123456789\"},\"affordable\":false}"
        } else if path.hasSuffix("/allocation") {
            response = "{\"enabled\":false,\"inputId\":\"input\",\"allocation\":\(state),\"unavailableReason\":\"applied_risk_unavailable\"}"
        } else {
            response = #"{"operation":{"id":"op","realmId":"rlm_test","path":"/op/1","type":"order","state":"completed","createdAt":"2026-09-06T00:00:00Z","updatedAt":"2026-09-06T00:00:00Z"}}"#
        }
        let envelope = "{\"success\":true,\"data\":\(response)}"
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(envelope.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
