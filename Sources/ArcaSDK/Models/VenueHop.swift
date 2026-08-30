import Foundation

/// The EIP-712 domain a co-sign digest is bound to.
/// `verifyingContract` is the realm's kernel proxy.
public struct CosignDomain: Codable, Sendable {
    public let name: String
    public let version: String
    public let chainId: Int
    public let verifyingContract: String
}

/// Whether one co-signature nonce can still be spent on a boundary.
///
/// Returned by ``Arca/getCosignNonceState(boundaryId:nonce:)``. Read
/// ``spendable`` — it is the only field correct on both kernel generations.
public struct CosignNonceState: Codable, Sendable {
    public let boundaryId: String
    /// The nonce that was checked, echoed as a decimal string.
    public let nonce: String
    /// The single answer most callers want: can this envelope still be
    /// submitted? Correct on both kernel generations.
    public let spendable: Bool
    /// Burn-set read: `true` means this slot is spent.
    ///
    /// Meaningful **only when ``unordered`` is true**. A frozen-counter kernel
    /// has no burn set, so this is always `false` there — including for nonces
    /// the counter will refuse. Prefer ``spendable``.
    public let consumed: Bool
    /// `true` on a burn-set kernel (marker 7+) that accepts caller-chosen
    /// nonces; `false` on a frozen-counter kernel (marker 3-6), where
    /// ``counterNonce`` is the only value it will accept.
    public let unordered: Bool
    /// The boundary's live counter, present only when ``unordered`` is false.
    /// On such a kernel an envelope is live iff it was signed over exactly
    /// this.
    public let counterNonce: String?
}

/// Everything a signer needs to re-derive and sign a venue hop.
///
/// `amountRaw` — not `amount` — is what the paramsHash commits to. Encoding
/// the decimal string produces a different hash than the kernel and the
/// signature is rejected.
public struct VenueHopProposal: Codable, Sendable {
    /// CosignAction discriminator (11 = TransferBetweenVenues).
    public let action: Int
    /// The debited (source) boundary — the co-sign owner.
    public let boundaryId: String
    public let boundaryKey: String
    /// The credited boundary. Equal to `boundaryId` for a same-boundary rebalance.
    public let targetBoundaryId: String
    public let targetBoundaryKey: String
    /// Venue CONTRACT addresses the hop routes between; both are in the digest.
    public let fromVenue: String
    public let toVenue: String
    /// Destination venue sub-account (bytes32).
    public let toVenueAccountKey: String
    public let token: String
    public let domain: CosignDomain?
    public let amount: String
    /// The uint256 the paramsHash commits to. Encode THIS, never `amount`.
    public let amountRaw: String
    /// Correlation word bound into the digest; derived from realm + operation path.
    public let ref: String
    public let nonce: String
    public let deadline: Int64
    public let paramsHash: String
    /// Read from the kernel, so a signer can cross-check its own derivation.
    public let digest: String

    /// Re-derives `paramsHash` and `digest` from this proposal's own semantic
    /// fields and throws when they disagree with what the server returned.
    ///
    /// This is what makes a co-signature meaningful. Without it a signer is
    /// attesting to a 32-byte number it cannot read; with it, a server that
    /// returned a digest for a different destination, a different amount, or a
    /// different kernel is caught before the key is ever used.
    ///
    /// ``Arca/hopVenues(path:from:to:amount:deadline:sign:)`` calls this
    /// automatically before invoking its signer, so the common path is
    /// verified by default. Call it directly when you drive
    /// ``Arca/proposeVenueHop(path:from:to:amount:deadline:)`` yourself.
    ///
    /// - Throws: ``CosignVerificationError`` when the proposal does not
    ///   describe what it asks to have signed.
    public func verify() throws {
        guard let domain else { throw CosignVerificationError.missingDomain }
        guard domain.name == cosignDomainName, domain.version == cosignDomainVersion else {
            throw CosignVerificationError.unknownDomain(name: domain.name, version: domain.version)
        }
        guard action == CosignAction.transferBetweenVenues
            || action == CosignAction.transferBetweenVenuesPreAuth
        else {
            throw CosignVerificationError.unexpectedAction(action)
        }

        let derivedParams = try Cosign.transferBetweenVenuesParamsHash(
            fromVenue: fromVenue,
            fromBoundary: boundaryKey,
            toBoundary: targetBoundaryKey,
            toVenue: toVenue,
            toVenueAccountId: toVenueAccountKey,
            token: token,
            amount: amountRaw,
            ref: ref
        )
        guard Cosign.hexEqual(derivedParams, paramsHash) else {
            throw CosignVerificationError.paramsHashMismatch(server: paramsHash, derived: derivedParams)
        }

        let derivedDigest = try Cosign.operatorActionDigest(
            chainId: Int64(domain.chainId),
            kernelAddress: domain.verifyingContract,
            action: action,
            boundary: boundaryKey,
            paramsHash: derivedParams,
            nonce: nonce,
            deadline: deadline
        )
        guard Cosign.hexEqual(derivedDigest, digest) else {
            throw CosignVerificationError.digestMismatch(server: digest, derived: derivedDigest)
        }
    }
}

/// The accepted co-signed hop.
public struct VenueHopResponse: Codable, Sendable, OperationResponse {
    public let operation: Operation
    /// The debited boundary. Empty on the unarmed path, where the plain
    /// transfer endpoint does not report boundaries.
    public let boundaryId: String?
    /// The credited boundary.
    public let targetBoundaryId: String?

    public func withOperation(_ op: Operation) -> Self {
        .init(operation: op, boundaryId: boundaryId, targetBoundaryId: targetBoundaryId)
    }
}
