import XCTest
@testable import ArcaSDK

/// Pins the 403 → token-provider refresh contract.
///
/// A cached token can be valid (not expired) but scoped to a different
/// identity than the provider would now mint for — e.g. the app switched
/// signed-in users. The server rejects such requests with 403 `FORBIDDEN` /
/// `REALM_SCOPE_MISMATCH`, NOT 401, so the client must treat a 403 as a
/// refresh trigger when a provider is configured. Without a provider a 403
/// is a plain permission denial: no refresh, no onAuthError.
final class ForbiddenRefreshTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ScriptedResponseProtocol.self] + (sessionConfig.protocolClasses ?? [])
        ScriptedResponseProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        ScriptedResponseProtocol.reset()
        super.tearDown()
    }

    private struct Probe: Decodable, Sendable { let ok: Bool }

    private static let success = ScriptedResponseProtocol.Scripted(
        status: 200, body: #"{"success":true,"data":{"ok":true}}"#
    )

    private static func denial(_ code: String, _ message: String, status: Int = 403) -> ScriptedResponseProtocol.Scripted {
        ScriptedResponseProtocol.Scripted(
            status: status,
            body: #"{"success":false,"error":{"code":"\#(code)","message":"\#(message)"}}"#
        )
    }

    func testForbiddenTriggersRefreshAndRetry() async throws {
        ScriptedResponseProtocol.enqueue([
            Self.denial("FORBIDDEN", "Access denied"),
            Self.success,
        ])

        let triggerBox = SendableBox<AuthRefreshTrigger?>(nil)
        let client = ArcaClient(
            token: "stale-identity-token",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            onUnauthorized: { trigger in
                triggerBox.update { $0 = trigger }
                return "fresh-identity-token"
            }
        )

        let probe: Probe = try await client.get("/probe")
        XCTAssertTrue(probe.ok)
        XCTAssertEqual(triggerBox.value, .forbidden)

        let authHeaders = ScriptedResponseProtocol.authorizationHeaders
        XCTAssertEqual(authHeaders.count, 2)
        XCTAssertEqual(authHeaders.last, "Bearer fresh-identity-token",
                       "the retry must carry the provider-minted token")
    }

    func testRealmScopeMismatchTriggersRefresh() async throws {
        ScriptedResponseProtocol.enqueue([
            Self.denial("REALM_SCOPE_MISMATCH", "Token is scoped to a different realm"),
            Self.success,
        ])

        let refreshCount = SendableBox<Int>(0)
        let client = ArcaClient(
            token: "stale",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            onUnauthorized: { _ in
                refreshCount.update { $0 += 1 }
                return "fresh"
            }
        )

        let probe: Probe = try await client.get("/probe")
        XCTAssertTrue(probe.ok)
        XCTAssertEqual(refreshCount.value, 1)
    }

    func testRealmScopeMismatchMapsToForbidden() {
        let mapped = mapAPIError(code: "REALM_SCOPE_MISMATCH", message: "mismatch", errorId: nil)
        if case .forbidden = mapped {
            // expected
        } else {
            XCTFail("Expected .forbidden, got \(mapped)")
        }
    }

    func testUnauthorizedPassesUnauthorizedTrigger() async throws {
        ScriptedResponseProtocol.enqueue([
            Self.denial("UNAUTHORIZED", "expired", status: 401),
            Self.success,
        ])

        let triggerBox = SendableBox<AuthRefreshTrigger?>(nil)
        let client = ArcaClient(
            token: "expired-token",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            onUnauthorized: { trigger in
                triggerBox.update { $0 = trigger }
                return "fresh"
            }
        )

        let probe: Probe = try await client.get("/probe")
        XCTAssertTrue(probe.ok)
        XCTAssertEqual(triggerBox.value, .unauthorized)
    }

    func testForbiddenWithoutProviderThrowsWithoutAuthError() async {
        ScriptedResponseProtocol.enqueue([
            Self.denial("FORBIDDEN", "Access denied"),
        ])

        let authErrorBox = SendableBox<Error?>(nil)
        let client = ArcaClient(
            token: "token",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            onAuthError: { error in
                authErrorBox.update { $0 = error }
            }
        )

        do {
            let _: Probe = try await client.get("/probe")
            XCTFail("Expected forbidden error")
        } catch {
            if case ArcaError.forbidden = error {
                // expected
            } else {
                XCTFail("Expected .forbidden, got \(error)")
            }
        }
        // A plain permission denial must not look like session expiry.
        XCTAssertNil(authErrorBox.value)
    }

    func testStillForbiddenAfterRefreshEmitsAuthError() async {
        ScriptedResponseProtocol.enqueue([
            Self.denial("FORBIDDEN", "Access denied"),
            Self.denial("FORBIDDEN", "still denied"),
        ])

        let authErrorBox = SendableBox<Error?>(nil)
        let client = ArcaClient(
            token: "stale",
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            onUnauthorized: { _ in "still-wrong-identity" },
            onAuthError: { error in
                authErrorBox.update { $0 = error }
            }
        )

        do {
            let _: Probe = try await client.get("/probe")
            XCTFail("Expected forbidden error")
        } catch {
            if case ArcaError.forbidden = error {
                // expected
            } else {
                XCTFail("Expected .forbidden, got \(error)")
            }
        }
        guard let reported = authErrorBox.value else {
            return XCTFail("Expected onAuthError to fire for an unrecoverable 403")
        }
        if case ArcaError.forbidden = reported {
            // expected
        } else {
            XCTFail("Expected onAuthError with .forbidden, got \(reported)")
        }
    }
}

/// URLProtocol that serves a scripted FIFO sequence of responses and records
/// the Authorization header of every request it handles.
private final class ScriptedResponseProtocol: URLProtocol {
    struct Scripted {
        let status: Int
        let body: String
    }

    private static let lock = NSLock()
    private static var queue: [Scripted] = []
    private static var _authorizationHeaders: [String] = []

    static var authorizationHeaders: [String] {
        lock.lock(); defer { lock.unlock() }
        return _authorizationHeaders
    }

    static func enqueue(_ responses: [Scripted]) {
        lock.lock()
        queue.append(contentsOf: responses)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        queue = []
        _authorizationHeaders = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if let auth = request.value(forHTTPHeaderField: "Authorization") {
            Self._authorizationHeaders.append(auth)
        }
        let scripted = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        let url = request.url!
        let response = HTTPURLResponse(
            url: url,
            statusCode: scripted?.status ?? 500,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = scripted?.body ?? #"{"success":false,"error":{"code":"INTERNAL_ERROR","message":"no scripted response"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
