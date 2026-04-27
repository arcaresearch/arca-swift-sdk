import Foundation
import XCTest
@testable import ArcaSDK

final class AggregationHistoryTests: XCTestCase {
    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = .ephemeral
        sessionConfig.protocolClasses = [HistoryMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        HistoryMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        HistoryMockProtocol.reset()
        super.tearDown()
    }

    func testGetEquityHistoryRequestsV2TargetFormatAndNormalizesResponse() async throws {
        let from = "2026-01-01T00:00:00Z"
        let to = "2026-01-01T01:00:00Z"
        HistoryMockProtocol.responseBody = """
        {
          "success": true,
          "data": {
            "resolution": "5m",
            "points": [
              { "ts": "\(from)", "equityUsd": "1000.00" },
              { "ts": "\(to)", "equityUsd": "1250.00" }
            ]
          }
        }
        """
        let arca = try makeArca()

        let result = try await arca.getEquityHistory(path: "/users/alice/main", from: from, to: to, points: 2)

        let query = try XCTUnwrap(HistoryMockProtocol.lastQuery)
        XCTAssertEqual(HistoryMockProtocol.lastPath, "/api/v1/objects/aggregate/history")
        XCTAssertEqual(query["target"], "/users/alice/main")
        XCTAssertEqual(query["kind"], "path")
        XCTAssertNil(query["prefix"])
        XCTAssertEqual(result.prefix, "/users/alice/main")
        XCTAssertEqual(result.points, 2)
        XCTAssertEqual(result.equityPoints.first?.timestamp, from)
        XCTAssertEqual(result.equityPoints.first?.equityUsd, "1000.00")
    }

    func testGetPnlHistoryRequestsV2TargetFormatAndNormalizesResponse() async throws {
        let from = "2026-01-01T00:00:00Z"
        let to = "2026-01-01T01:00:00Z"
        HistoryMockProtocol.responseBody = """
        {
          "success": true,
          "data": {
            "resolution": "5m",
            "startEquityUsd": "1000.00",
            "points": [
              { "ts": "\(from)", "equityUsd": "1000.00", "pnlUsd": "0.00", "valueUsd": "1000.00" },
              { "ts": "\(to)", "equityUsd": "1250.00", "pnlUsd": "250.00", "valueUsd": "1250.00" }
            ]
          }
        }
        """
        let arca = try makeArca()

        let result = try await arca.getPnlHistory(path: "/users/alice/main", from: from, to: to, points: 2)

        let query = try XCTUnwrap(HistoryMockProtocol.lastQuery)
        XCTAssertEqual(HistoryMockProtocol.lastPath, "/api/v1/objects/pnl/history")
        XCTAssertEqual(query["target"], "/users/alice/main")
        XCTAssertEqual(query["kind"], "path")
        XCTAssertNil(query["prefix"])
        XCTAssertEqual(result.startingEquityUsd, "1000.00")
        XCTAssertEqual(result.points, 2)
        XCTAssertEqual(result.pnlPoints.last?.timestamp, to)
        XCTAssertEqual(result.pnlPoints.last?.pnlUsd, "250.00")
        XCTAssertEqual(result.pnlPoints.last?.valueUsd, "1250.00")
    }

    private func makeArca() throws -> Arca {
        try Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19997")!,
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

private final class HistoryMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static var responseBody = ""

    static var lastPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.url?.path
    }

    static var lastQuery: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = requests.last?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var query: [String: String] = [:]
        components.queryItems?.forEach { query[$0.name] = $0.value }
        return query
    }

    static func reset() {
        lock.lock()
        requests = []
        responseBody = ""
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
