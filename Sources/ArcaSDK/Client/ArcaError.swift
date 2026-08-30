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

    /// The operation would move value out of a co-sign-armed boundary without
    /// the owner's signature (HTTP 412 `COSIGN_REQUIRED`).
    ///
    /// The SDK cannot transparently retry this the way it could a browser
    /// confirmation: a co-signature comes from a key the platform does not
    /// hold. Route `challenge` to whatever holds the boundary's co-sign key.
    ///
    /// For venue hops, `hopVenues(..., sign:)` handles this end to end.
    case cosignRequired(message: String, challenge: CosignRequiredChallenge, errorId: String?)

    /// A co-signed submission named a nonce that can no longer be spent
    /// (HTTP 412 `COSIGN_NONCE_USED`).
    ///
    /// **This is not a signature failure.** The signature was very likely
    /// fine; the slot it committed to is gone — a retry racing the original
    /// already spent it, or the user cancelled the approval. The remedy is
    /// always the same: propose again, have the device sign the fresh digest,
    /// resubmit. Reporting it as "that approval didn't match this request"
    /// tells the user their wallet misbehaved when it did not.
    ///
    /// Treat it as blocked-pending-user rather than retryable: replaying the
    /// same envelope can never succeed, so a reconciler must re-propose.
    ///
    /// ``Arca/getCosignNonceState(boundaryId:nonce:)`` checks the slot before
    /// submitting, which avoids the round trip for an envelope that has been
    /// outstanding a while.
    case cosignNonceUsed(message: String, details: CosignNonceUsedDetails, errorId: String?)

    /// Unknown API error code.
    case unknown(code: String, message: String, errorId: String?)
}

/// The structured payload accompanying a 412 `COSIGN_NONCE_USED` response.
///
/// `reason` is either `nonce_consumed` (the burn-set kernel, marker 7+, says
/// this exact slot is spent: the action executed, or the owner revoked it with
/// `invalidateCosignNonce`) or `counter_stale` (a frozen-counter kernel,
/// marker 3-6, moved its counter while the device was signing). Both resolve
/// identically, so branch on the error case; `reason` is for logs.
public struct CosignNonceUsedDetails: Sendable, Equatable {
    public let boundaryId: String
    /// The nonce that was refused, as a decimal string.
    public let nonce: String?
    public let reason: String?
    /// Human-readable remedy, always "re-propose … re-sign … resubmit".
    public let resolution: String?

    /// Builds the details from the server's `details` map.
    ///
    /// Only `boundaryId` is required, matching ``CosignRequiredChallenge``: an
    /// error naming the boundary is actionable even if a future field is
    /// unrecognized.
    init?(details: [String: String]?) {
        guard let details, let boundaryId = details["boundaryId"], !boundaryId.isEmpty else {
            return nil
        }
        self.boundaryId = boundaryId
        self.nonce = details["nonce"]
        self.reason = details["reason"]
        self.resolution = details["resolution"]
    }
}

/// The structured payload accompanying a 412 `COSIGN_REQUIRED` response.
///
/// A co-sign-armed isolation boundary requires the boundary owner's EIP-712
/// signature before value may leave it, and the platform cannot produce that
/// signature — only the key holder can. The challenge names which surface was
/// gated and where to take the propose/submit pair that collects it.
///
/// `surface` is the discriminator worth branching on: `transfer.venue_hop`,
/// `transfer.venue_deposit`, `transfer.cross_boundary`,
/// `deposit.venue_deposit`, `withdrawal.plain`.
public struct CosignRequiredChallenge: Sendable, Equatable {
    public let surface: String
    public let boundaryId: String
    /// Set on single-object surfaces (deposit, withdrawal).
    public let arcaPath: String?
    /// Set on the two-ended surfaces (transfer, hop).
    public let sourceArcaPath: String?
    public let targetArcaPath: String?
    /// Endpoints that collect the signature, when the surface has a pair.
    public let propose: String?
    public let submit: String?

    /// Builds a challenge from the server's `details` map.
    ///
    /// Only `boundaryId` is required: the surfaces differ in which path fields
    /// they carry, and a challenge naming the boundary is still actionable
    /// even if a future surface adds fields this version does not know.
    init?(details: [String: String]?) {
        guard let details, let boundaryId = details["boundaryId"], !boundaryId.isEmpty else {
            return nil
        }
        self.surface = details["surface"] ?? ""
        self.boundaryId = boundaryId
        self.arcaPath = details["arcaPath"]
        self.sourceArcaPath = details["sourceArcaPath"]
        self.targetArcaPath = details["targetArcaPath"]
        self.propose = details["propose"]
        self.submit = details["submit"]
    }
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
        case .cosignRequired(let message, _, _): return message
        case .cosignNonceUsed(let message, _, _): return message
        case .unknown(let code, let message, _): return "\(code): \(message)"
        }
    }
}

// MARK: - Error Mapping

/// Maps an API error response code to the appropriate `ArcaError` case.
public func mapAPIError(
    code: String,
    message: String,
    errorId: String?,
    details: [String: String]? = nil
) -> ArcaError {
    switch code {
    case "COSIGN_REQUIRED":
        guard let challenge = CosignRequiredChallenge(details: details) else {
            return .unknown(code: code, message: message, errorId: errorId)
        }
        return .cosignRequired(message: message, challenge: challenge, errorId: errorId)

    case "COSIGN_NONCE_USED":
        guard let parsed = CosignNonceUsedDetails(details: details) else {
            return .unknown(code: code, message: message, errorId: errorId)
        }
        return .cosignNonceUsed(message: message, details: parsed, errorId: errorId)

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
