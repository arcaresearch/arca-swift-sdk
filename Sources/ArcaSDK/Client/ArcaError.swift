import Foundation

/// All errors thrown by the Arca SDK.
/// Each case carries a human-readable message and an optional server-side
/// error correlation ID (`errorId`).
public enum ArcaError: Error, Sendable {
    /// Validation error (HTTP 400).
    case validation(message: String, errorId: String?)

    /// Authentication failed (HTTP 401).
    case unauthorized(message: String, errorId: String?)

    /// Forbidden — insufficient permissions (HTTP 403).
    case forbidden(message: String, errorId: String?)

    /// Resource not found (HTTP 404). `code` carries the domain-specific
    /// variant (e.g. `OBJECT_NOT_FOUND`, `REALM_NOT_FOUND`).
    case notFound(code: String, message: String, errorId: String?)

    /// Conflict (HTTP 409). Covers duplicates, idempotency violations, and
    /// venue refusals where `code` carries the specific reason:
    /// `NO_LIQUIDITY` (empty book side, retry or use a marketable limit),
    /// `MARKET_DELISTED` (market delisted, positions settled by the venue),
    /// `MARKET_NOT_TRADABLE` (halted or not yet live),
    /// `MARKET_NOT_USDC_COLLATERAL`, `VENUE_RATE_LIMITED` (the account's venue
    /// request allowance is spent — on Hyperliquid it is earned by cumulative
    /// volume traded rather than elapsed time, so waiting does not restore it),
    /// or `ORDER_FAILED` (a refusal with no narrower code — `message` carries
    /// the venue's verbatim text).
    ///
    /// None are retryable as-is: the venue evaluated the request and said no.
    case conflict(code: String, message: String, errorId: String?)

    /// Unexpected server error (HTTP 500).
    case internalError(message: String, errorId: String?)

    /// The request couldn't be delivered to the upstream exchange, or its
    /// answer couldn't be read (HTTP 502) — a transport fault, so retryable.
    /// A refusal *by* the venue is `.conflict` or `.validation` instead,
    /// carrying the venue's own reason.
    case exchangeError(code: String, message: String, errorId: String?)

    /// Network-level failure (no response received).
    case networkError(underlying: Error)

    /// Failed to decode the response body.
    case decodingError(underlying: Error)

    /// Server returned a non-JSON response.
    case nonJsonResponse(statusCode: Int, body: String)

    /// The operation completed with a non-success terminal state (`failed` or `expired`).
    /// The full `Operation` is available for inspection (e.g. `operation.outcome`).
    case operationFailed(operation: Operation)

    /// Unknown API error code.
    case unknown(code: String, message: String, errorId: String?)
}

extension ArcaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .validation(let message, _): return message
        case .unauthorized(let message, _): return message
        case .forbidden(let message, _): return message
        case .notFound(_, let message, _): return message
        case .conflict(_, let message, _): return message
        case .internalError(let message, _): return message
        case .exchangeError(_, let message, _): return message
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let err): return "Decoding error: \(err.localizedDescription)"
        case .nonJsonResponse(let status, let body):
            let preview = body.prefix(200)
            return "Non-JSON response (HTTP \(status)): \(preview)"
        case .operationFailed(let op):
            let reason = op.outcome ?? op.state.rawValue
            return "Operation \(op.id) \(op.state.rawValue): \(reason)"
        case .unknown(let code, let message, _): return "\(code): \(message)"
        }
    }
}

// MARK: - Error Mapping

/// Maps an API error response code to the appropriate `ArcaError` case.
public func mapAPIError(code: String, message: String, errorId: String?) -> ArcaError {
    switch code {
    case "VALIDATION_ERROR":
        return .validation(message: message, errorId: errorId)

    case "UNAUTHORIZED", "UNAUTHENTICATED":
        return .unauthorized(message: message, errorId: errorId)

    case "FORBIDDEN", "REALM_SCOPE_MISMATCH":
        return .forbidden(message: message, errorId: errorId)

    case "NOT_FOUND", "USER_NOT_FOUND", "REALM_NOT_FOUND", "OBJECT_NOT_FOUND",
         "ORG_NOT_FOUND", "ORDER_NOT_FOUND", "ACCOUNT_NOT_FOUND",
         "MEMBER_NOT_FOUND", "PROFILE_NOT_FOUND", "INVITATION_NOT_FOUND":
        return .notFound(code: code, message: message, errorId: errorId)

    case "CONFLICT", "ALREADY_EXISTS", "ALREADY_MEMBER", "ALREADY_DELETED",
         "DUPLICATE_REALM", "ALREADY_REVOKED", "IDEMPOTENCY_VIOLATION",
         // Venue refusals (409): the venue evaluated a well-formed request and
         // said no. NO_LIQUIDITY = empty book side (retry / marketable limit);
         // MARKET_DELISTED = market delisted, positions settled by the venue;
         // MARKET_NOT_TRADABLE = halted or not yet live; VENUE_RATE_LIMITED =
         // the account's venue request allowance is spent (volume-earned on
         // HL, so waiting does not help); ORDER_FAILED = a refusal with no
         // narrower code, verbatim venue text in `message`.
         "NO_LIQUIDITY", "MARKET_DELISTED", "MARKET_NOT_TRADABLE",
         "MARKET_NOT_USDC_COLLATERAL", "VENUE_RATE_LIMITED", "ORDER_FAILED":
        return .conflict(code: code, message: message, errorId: errorId)

    case "INTERNAL_ERROR":
        return .internalError(message: message, errorId: errorId)

    case "EXCHANGE_ERROR", "EXCHANGE_UNAVAILABLE", "INVALID_REQUEST":
        return .exchangeError(code: code, message: message, errorId: errorId)

    default:
        return .unknown(code: code, message: message, errorId: errorId)
    }
}
