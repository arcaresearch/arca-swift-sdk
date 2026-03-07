import XCTest
@testable import ArcaSDK

final class ArcaErrorTests: XCTestCase {

    // MARK: - Error Mapping

    func testValidationErrorMapping() {
        let error = mapAPIError(code: "VALIDATION_ERROR", message: "Name is required", errorId: "err_01abc")
        if case .validation(let msg, let errorId) = error {
            XCTAssertEqual(msg, "Name is required")
            XCTAssertEqual(errorId, "err_01abc")
        } else {
            XCTFail("Expected validation error")
        }
    }

    func testUnauthorizedMapping() {
        let error = mapAPIError(code: "UNAUTHORIZED", message: "Invalid token", errorId: nil)
        if case .unauthorized(let msg, _) = error {
            XCTAssertEqual(msg, "Invalid token")
        } else {
            XCTFail("Expected unauthorized error")
        }
    }

    func testNotFoundVariants() {
        let variants = [
            "NOT_FOUND", "USER_NOT_FOUND", "REALM_NOT_FOUND", "OBJECT_NOT_FOUND",
            "ORG_NOT_FOUND", "ORDER_NOT_FOUND", "ACCOUNT_NOT_FOUND",
            "MEMBER_NOT_FOUND", "PROFILE_NOT_FOUND", "INVITATION_NOT_FOUND",
        ]
        for code in variants {
            let error = mapAPIError(code: code, message: "Not found", errorId: nil)
            if case .notFound(let errorCode, _, _) = error {
                XCTAssertEqual(errorCode, code)
            } else {
                XCTFail("Expected notFound for code \(code)")
            }
        }
    }

    func testConflictVariants() {
        let variants = [
            "CONFLICT", "ALREADY_EXISTS", "ALREADY_MEMBER", "ALREADY_DELETED",
            "DUPLICATE_REALM", "ALREADY_REVOKED", "IDEMPOTENCY_VIOLATION",
        ]
        for code in variants {
            let error = mapAPIError(code: code, message: "Conflict", errorId: nil)
            if case .conflict(let errorCode, _, _) = error {
                XCTAssertEqual(errorCode, code)
            } else {
                XCTFail("Expected conflict for code \(code)")
            }
        }
    }

    func testExchangeErrorVariants() {
        let variants = ["EXCHANGE_ERROR", "EXCHANGE_UNAVAILABLE", "ORDER_FAILED", "INVALID_REQUEST"]
        for code in variants {
            let error = mapAPIError(code: code, message: "Exchange error", errorId: nil)
            if case .exchangeError(let errorCode, _, _) = error {
                XCTAssertEqual(errorCode, code)
            } else {
                XCTFail("Expected exchangeError for code \(code)")
            }
        }
    }

    func testInternalErrorMapping() {
        let error = mapAPIError(code: "INTERNAL_ERROR", message: "Something went wrong", errorId: "err_01xyz")
        if case .internalError(let msg, let errorId) = error {
            XCTAssertEqual(msg, "Something went wrong")
            XCTAssertEqual(errorId, "err_01xyz")
        } else {
            XCTFail("Expected internal error")
        }
    }

    func testUnknownCodeMapping() {
        let error = mapAPIError(code: "SOME_NEW_CODE", message: "Unknown", errorId: nil)
        if case .unknown(let code, let msg, _) = error {
            XCTAssertEqual(code, "SOME_NEW_CODE")
            XCTAssertEqual(msg, "Unknown")
        } else {
            XCTFail("Expected unknown error")
        }
    }

    func testForbiddenMapping() {
        let error = mapAPIError(code: "FORBIDDEN", message: "Access denied", errorId: nil)
        if case .forbidden(let msg, _) = error {
            XCTAssertEqual(msg, "Access denied")
        } else {
            XCTFail("Expected forbidden error")
        }
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        let cases: [(ArcaError, String)] = [
            (.validation(message: "Bad input", errorId: nil), "Bad input"),
            (.unauthorized(message: "Expired", errorId: nil), "Expired"),
            (.nonJsonResponse(statusCode: 500, body: "<html>"), "Non-JSON response (HTTP 500): <html>"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    // MARK: - APIResponse Decoding

    func testAPIResponseSuccessDecoding() throws {
        let json = """
        {
            "success": true,
            "data": { "objectCount": 5, "operationCount": 10, "eventCount": 20 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIResponse<ExplorerSummary>.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.data?.objectCount, 5)
        XCTAssertNil(response.error)
    }

    func testAPIResponseErrorDecoding() throws {
        let json = """
        {
            "success": false,
            "error": {
                "code": "VALIDATION_ERROR",
                "message": "Realm name is required",
                "errorId": "err_01abc"
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIResponse<ExplorerSummary>.self, from: json)
        XCTAssertFalse(response.success)
        XCTAssertNil(response.data)
        XCTAssertEqual(response.error?.code, "VALIDATION_ERROR")
        XCTAssertEqual(response.error?.message, "Realm name is required")
        XCTAssertEqual(response.error?.errorId, "err_01abc")
    }
}
