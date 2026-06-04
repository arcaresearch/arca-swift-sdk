import XCTest
@testable import ArcaSDK

/// Pins that every REST request advertises the SDK's client capabilities via
/// the `X-Arca-Client-Capabilities` header. This is the always-on half of the
/// server-authoritative-pricing contract (the server ignores it today).
final class CapabilityHeaderTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CapabilityHeaderMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        CapabilityHeaderMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        CapabilityHeaderMockProtocol.reset()
        super.tearDown()
    }

    private struct Probe: Decodable, Sendable { let ok: Bool }

    func testRESTRequestsAdvertiseClientCapabilitiesHeader() async throws {
        let client = ArcaClient(
            token: "jwt",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig
        )

        let probe: Probe = try await client.get("/probe")
        XCTAssertTrue(probe.ok)

        let header = CapabilityHeaderMockProtocol.lastCapabilitiesHeader
        XCTAssertNotNil(header, "every REST request must carry X-Arca-Client-Capabilities")
        XCTAssertTrue(header?.contains("server-authoritative-pricing") ?? false,
                      "the server-authoritative-pricing capability must be advertised")
        // The header value is exactly the comma-joined advertised set.
        XCTAssertEqual(header, ArcaClient.advertisedCapabilities.joined(separator: ","))
    }
}

private final class CapabilityHeaderMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _lastCapabilitiesHeader: String?

    static var lastCapabilitiesHeader: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastCapabilitiesHeader
    }

    static func reset() {
        lock.lock()
        _lastCapabilitiesHeader = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._lastCapabilitiesHeader = request.value(forHTTPHeaderField: "X-Arca-Client-Capabilities")
        Self.lock.unlock()

        let url = request.url!
        let body = #"{"success":true,"data":{"ok":true}}"#
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
