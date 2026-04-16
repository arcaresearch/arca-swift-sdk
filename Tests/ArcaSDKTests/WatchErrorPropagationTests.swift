import XCTest
@testable import ArcaSDK

/// Verifies that `watchFills`, `watchFunding`, and `watchExchangeState` propagate
/// errors from `getObjectDetail` instead of silently falling back to watching "/".
final class WatchErrorPropagationTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ObjectNotFoundProtocol.self] + (sessionConfig.protocolClasses ?? [])
    }

    override func tearDown() {
        sessionConfig = nil
        super.tearDown()
    }

    func testWatchFillsThrowsWhenGetObjectDetailFails() async {
        let arca = makeArca()
        do {
            _ = try await arca.watchFills(objectId: "nonexistent")
            XCTFail("Expected watchFills to throw when object lookup fails")
        } catch {
            assertIsNotFoundError(error)
        }
    }

    func testWatchFundingThrowsWhenGetObjectDetailFails() async {
        let arca = makeArca()
        do {
            _ = try await arca.watchFunding(objectId: "nonexistent")
            XCTFail("Expected watchFunding to throw when object lookup fails")
        } catch {
            assertIsNotFoundError(error)
        }
    }

    func testWatchExchangeStateThrowsWhenGetObjectDetailFails() async {
        let arca = makeArca()
        do {
            _ = try await arca.watchExchangeState(objectId: "nonexistent")
            XCTFail("Expected watchExchangeState to throw when object lookup fails")
        } catch {
            assertIsNotFoundError(error)
        }
    }

    /// Regression guard for the diagnostic logging story: when a REST call
    /// fails with 404 inside a watch-stream path, the SDK must emit at least
    /// one warning-level record on the `network` or `watch` category.
    /// Previously these errors were discarded via `try?` and builders got no
    /// visibility.
    func testRestFailureSurfacesViaLogHandler() async {
        let handler = CapturingLogHandler()
        let arca = makeArca(logLevel: .debug, logHandler: handler)
        _ = try? await arca.watchFills(objectId: "nonexistent")

        let isRelevant: (ArcaLogRecord) -> Bool = { record in
            record.level >= .warning &&
            (record.category == "network" || record.category == "watch")
        }

        let deadline = Date().addingTimeInterval(2.0)
        while !handler.records.contains(where: isRelevant), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let relevant = handler.records.filter(isRelevant)
        XCTAssertFalse(relevant.isEmpty,
                       "Expected at least one warning record on network/watch category; got \(handler.records.map { ($0.level, $0.category, $0.message) })")
    }

    // MARK: - Helpers

    private func makeArca(
        logLevel: ArcaLogLevel = .warning,
        logHandler: ArcaLogHandler? = nil
    ) -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            logLevel: logLevel,
            logHandler: logHandler
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

    private func assertIsNotFoundError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case ArcaError.notFound = error else {
            XCTFail("Expected ArcaError.notFound, got \(error)", file: file, line: line)
            return
        }
    }
}

// MARK: - Mock URLProtocol

/// Intercepts HTTP requests to `/objects/` and returns a 404 NOT_FOUND response
/// matching the Arca API envelope format. Only handles data tasks (GET requests);
/// WebSocket tasks are unaffected.
private class ObjectNotFoundProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.path.contains("/objects/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = #"{"success":false,"error":{"code":"OBJECT_NOT_FOUND","message":"Object not found"}}"#
        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
