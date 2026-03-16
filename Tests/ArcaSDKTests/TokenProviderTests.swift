import XCTest
@testable import ArcaSDK

final class TokenProviderTests: XCTestCase {

    // MARK: - Helpers

    private func base64url(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func fakeJwt(claims: [String: Any] = [:]) -> String {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        var allClaims: [String: Any] = ["realmId": "rlm_test123", "sub": "usr_abc"]
        for (key, value) in claims {
            allClaims[key] = value
        }
        let payloadData = try! JSONSerialization.data(withJSONObject: allClaims)
        let payloadStr = String(data: payloadData, encoding: .utf8)!
        let payload = base64url(payloadStr)
        return "\(header).\(payload).fakesig"
    }

    private func fakeJwtWithExp(secondsFromNow: TimeInterval) -> String {
        let exp = Date().timeIntervalSince1970 + secondsFromNow
        return fakeJwt(claims: ["exp": exp])
    }

    // MARK: - Construction

    func testInitWithTokenProvider() throws {
        let provider: TokenProvider = { self.fakeJwt() }
        let arca = try Arca(token: fakeJwt(), tokenProvider: provider)
        XCTAssertEqual(arca.realm, "rlm_test123")
    }

    func testWithTokenProviderFactory() async throws {
        let jwt = fakeJwt()
        let provider: TokenProvider = { jwt }
        let arca = try await Arca.withTokenProvider(provider)
        XCTAssertEqual(arca.realm, "rlm_test123")
    }

    func testWithTokenProviderFactoryCallsProvider() async throws {
        var callCount = 0
        let jwt = fakeJwt()
        let provider: TokenProvider = {
            callCount += 1
            return jwt
        }
        _ = try await Arca.withTokenProvider(provider)
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - TokenManager

    func testTokenManagerRefreshDeduplication() async throws {
        var callCount = 0
        let jwt = fakeJwt()
        let manager = TokenManager(provider: {
            callCount += 1
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            return jwt
        })

        async let t1 = manager.refreshToken()
        async let t2 = manager.refreshToken()
        let results = try await [t1, t2]

        XCTAssertEqual(results[0], jwt)
        XCTAssertEqual(results[1], jwt)
        XCTAssertEqual(callCount, 1)
    }

    func testTokenManagerRefreshWithoutProvider() async {
        let manager = TokenManager(provider: nil)
        do {
            _ = try await manager.refreshToken()
            XCTFail("Expected error")
        } catch {
            if case ArcaError.unauthorized = error {
                // expected
            } else {
                XCTFail("Expected unauthorized error, got \(error)")
            }
        }
    }

    func testTokenManagerHasProvider() async {
        let withProvider = TokenManager(provider: { "token" })
        let without = TokenManager(provider: nil)
        let hasTrue = await withProvider.hasProvider
        let hasFalse = await without.hasProvider
        XCTAssertTrue(hasTrue)
        XCTAssertFalse(hasFalse)
    }

    // MARK: - Auth Error Events

    func testOnAuthError() async throws {
        let manager = TokenManager(provider: nil)
        let expectation = XCTestExpectation(description: "auth error fired")
        var receivedError: Error?

        await manager.onAuthError { error in
            receivedError = error
            expectation.fulfill()
        }

        await manager.emitAuthError(
            ArcaError.unauthorized(message: "expired", errorId: nil)
        )

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertNotNil(receivedError)
    }

    func testRemoveAuthErrorHandler() async throws {
        let manager = TokenManager(provider: nil)
        var called = false

        let id = await manager.onAuthError { _ in
            called = true
        }
        await manager.removeAuthErrorHandler(id)
        await manager.emitAuthError(
            ArcaError.unauthorized(message: "expired", errorId: nil)
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(called)
    }

    // MARK: - Proactive Refresh

    func testProactiveRefreshSchedules() async throws {
        let expectation = XCTestExpectation(description: "proactive refresh")
        let freshJwt = fakeJwt(claims: ["sub": "refreshed"])
        var refreshedToken: String?

        let manager = TokenManager(provider: { freshJwt })

        let almostExpired = fakeJwtWithExp(secondsFromNow: 2) // expires in 2s, buffer is 30s, so fires immediately

        await manager.scheduleProactiveRefresh(token: almostExpired) { token in
            refreshedToken = token
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(refreshedToken, freshJwt)
    }

    // MARK: - Arca onAuthError

    func testArcaOnAuthError() async throws {
        let arca = try Arca(token: fakeJwt())
        let expectation = XCTestExpectation(description: "auth error")
        var receivedError: Error?

        let id = await arca.onAuthError { error in
            receivedError = error
            expectation.fulfill()
        }

        await arca.tokenManager.emitAuthError(
            ArcaError.unauthorized(message: "test", errorId: nil)
        )

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertNotNil(receivedError)

        // Cleanup
        await arca.removeAuthErrorHandler(id)
    }
}
