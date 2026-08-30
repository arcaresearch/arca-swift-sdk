import Foundation

/// Signs a co-sign digest with the boundary's co-sign key.
///
/// Receives the kernel-derived EIP-712 digest (0x-prefixed 32 bytes) and the
/// full proposal, and returns a 0x-prefixed 65-byte secp256k1 signature.
/// Async so it can be a device prompt, a Secure Enclave operation, or a
/// hardware wallet — the SDK never holds this key, which is the whole property
/// a co-signature provides.
///
/// ``Arca/hopVenues(path:from:to:amount:sign:deadline:)`` has already
/// re-derived the digest from the proposal's own fields by the time this is
/// called, so the hash is verified rather than merely relayed; the proposal is
/// passed alongside so the signer can show the user what it commits to.
public typealias CosignDigestSigner = @Sendable (String, VenueHopProposal) async throws -> String

extension Arca {

    // MARK: - Venue-to-venue hops

    /// Move capital straight from one exchange object to another.
    ///
    /// A transfer whose source and target are both exchange objects hops
    /// venue-to-venue in a single on-chain frame — no intermediate denominated
    /// arca, and the value never rests at a boundary. Hops carry no transfer
    /// fee and work across isolation boundaries.
    ///
    /// This is ``transfer(path:from:to:amount:feeOverride:)`` plus the co-sign
    /// fallback. On an unarmed source boundary it is exactly a transfer. On an
    /// armed one the plain call is refused (the kernel will not move value out
    /// without the owner's signature), so this proposes the hop, hands the
    /// digest to `sign`, and submits.
    ///
    /// ```swift
    /// let res = try await arca.hopVenues(
    ///     path: "/op/transfer/rebalance-1",
    ///     from: "/users/alice/exchange/hl",
    ///     to: "/users/alice/exchange/paper",
    ///     amount: "500",
    ///     sign: { digest, _ in try await wallet.sign(digest) }
    /// ).settle()
    /// ```
    ///
    /// Destinations are limited to Hyperliquid and the paper venue; a
    /// GLL-paper target is refused, because its account is credited by faucet
    /// rather than by value landing at the venue contract.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key). The signed ref derives from it.
    ///   - from: Source exchange arca — its boundary is the one that signs.
    ///   - to: Target exchange arca.
    ///   - amount: Amount as a decimal string.
    ///   - sign: Called ONLY if the source boundary is co-sign armed. Pass
    ///     `nil` on unarmed boundaries — it is never invoked there. Passing
    ///     `nil` on an ARMED boundary throws ``ArcaError/cosignRequired(message:challenge:errorId:)``
    ///     unchanged.
    ///   - deadline: Optional unix-seconds co-signature expiry, used only on
    ///     the signed path.
    public func hopVenues(
        path: String,
        from: String,
        to: String,
        amount: String,
        sign: CosignDigestSigner? = nil,
        deadline: Int64 = 0
    ) -> OperationHandle<VenueHopResponse> {
        operationHandle { [self] in
            do {
                let plain: TransferResponse = try await client.post("/transfer", body: PlainHopTransferRequest(
                    realmId: realm,
                    path: path,
                    sourceArcaPath: from,
                    targetArcaPath: to,
                    amount: amount
                ))
                return VenueHopResponse(operation: plain.operation, boundaryId: nil, targetBoundaryId: nil)
            } catch let error as ArcaError {
                // Only the armed-boundary refusal is recoverable here, and
                // only with a signer. Every other refusal — an unhoppable
                // destination, a fee, an insufficient balance — propagates
                // untouched, because retrying it under a signature would fail
                // again after asking the key holder for one.
                guard case .cosignRequired = error, let sign else { throw error }

                let proposal = try await proposeVenueHop(
                    path: path, from: from, to: to, amount: amount, deadline: deadline
                )
                // Re-derive before handing the key a hash it cannot read. A
                // server that returned a digest for a different destination or
                // a larger amount is caught here rather than on-chain.
                try proposal.verify()
                let signature = try await sign(proposal.digest, proposal)
                return try await submitVenueHopRequest(
                    path: path,
                    from: from,
                    to: to,
                    amount: amount,
                    nonce: proposal.nonce,
                    deadline: proposal.deadline,
                    signature: signature,
                    ref: proposal.ref
                )
            }
        }
    }

    /// Check whether a co-signature's nonce can still be spent.
    ///
    /// Use this before submitting an envelope that has been outstanding long
    /// enough to have been overtaken — a retry that raced the original, a
    /// second device, or a user who cancelled the approval. Submitting a spent
    /// nonce throws ``ArcaError/cosignNonceUsed(message:details:errorId:)``;
    /// this read tells you first, so you can re-propose without asking for a
    /// signature that cannot land.
    ///
    /// ```swift
    /// let state = try await arca.getCosignNonceState(
    ///     boundaryId: "bnd_abc", nonce: proposal.nonce
    /// )
    /// if !state.spendable {
    ///     // re-propose rather than prompting the device for a dead slot
    /// }
    /// ```
    ///
    /// Read ``CosignNonceState/spendable``, not `consumed`: on a frozen-counter
    /// kernel (marker 3-6) there is no burn set, so `consumed` is always
    /// `false` even for a nonce the kernel will refuse.
    ///
    /// This answers about the nonce, not the signature over it. A spendable
    /// nonce means submitting is not futile — not that the envelope will
    /// verify.
    public func getCosignNonceState(
        boundaryId: String,
        nonce: String
    ) async throws -> CosignNonceState {
        try await client.get(
            "/custody/boundaries/\(boundaryId)/cosign-nonces/\(nonce)",
            query: ["realmId": realm]
        )
    }

    /// Signable fields for a co-signed venue hop. Nothing is persisted and no
    /// funds move.
    ///
    /// Only the SOURCE boundary signs — value arriving is consent-free, so the
    /// destination's owner never has to be online.
    ///
    /// `path` is required because the signed ref derives from it: a submit at
    /// a different path produces a different digest and is refused. A careful
    /// signer should re-derive `digest` from the returned fields (encoding
    /// `amountRaw`, never `amount`) and refuse on mismatch rather than
    /// blind-signing the server's hash.
    ///
    /// Most callers want ``hopVenues(path:from:to:amount:sign:deadline:)``,
    /// which does propose → sign → submit and skips all of it on an unarmed
    /// boundary.
    public func proposeVenueHop(
        path: String,
        from: String,
        to: String,
        amount: String,
        deadline: Int64 = 0
    ) async throws -> VenueHopProposal {
        try await client.post(
            "/custody/venue-hops/propose",
            query: ["realmId": realm],
            body: VenueHopProposeRequest(
                path: path,
                sourceArcaPath: from,
                targetArcaPath: to,
                amount: amount,
                deadline: deadline
            )
        )
    }

    /// Submit a venue hop co-signed by the source boundary's wallet.
    ///
    /// The server re-derives the digest and verifies the signature against
    /// that boundary's on-chain co-sign key before anything moves. `path`,
    /// `amount`, `nonce`, and `deadline` must match what was signed.
    ///
    /// - Parameter ref: Optional. The server derives the authoritative ref
    ///   from `path`; supplying one only cross-checks it, so a ref from a
    ///   different path is refused by name rather than surfacing as an opaque
    ///   signature mismatch.
    public func submitVenueHop(
        path: String,
        from: String,
        to: String,
        amount: String,
        nonce: String,
        deadline: Int64,
        signature: String,
        ref: String? = nil
    ) -> OperationHandle<VenueHopResponse> {
        operationHandle { [self] in
            try await submitVenueHopRequest(
                path: path, from: from, to: to, amount: amount,
                nonce: nonce, deadline: deadline, signature: signature, ref: ref
            )
        }
    }

    /// The bare HTTP call, shared by ``submitVenueHop(path:from:to:amount:nonce:deadline:signature:ref:)``
    /// and the fallback inside ``hopVenues(path:from:to:amount:sign:deadline:)``
    /// — which already runs inside an operation handle and must not start a
    /// second one.
    private func submitVenueHopRequest(
        path: String,
        from: String,
        to: String,
        amount: String,
        nonce: String,
        deadline: Int64,
        signature: String,
        ref: String?
    ) async throws -> VenueHopResponse {
        try await client.post(
            "/custody/venue-hops",
            query: ["realmId": realm],
            body: VenueHopSubmitRequest(
                path: path,
                sourceArcaPath: from,
                targetArcaPath: to,
                amount: amount,
                nonce: nonce,
                deadline: deadline,
                signature: signature,
                ref: ref
            )
        )
    }
}

private struct PlainHopTransferRequest: Encodable {
    let realmId: String
    let path: String
    let sourceArcaPath: String
    let targetArcaPath: String
    let amount: String
}

private struct VenueHopProposeRequest: Encodable {
    let path: String
    let sourceArcaPath: String
    let targetArcaPath: String
    let amount: String
    let deadline: Int64
}

private struct VenueHopSubmitRequest: Encodable {
    let path: String
    let sourceArcaPath: String
    let targetArcaPath: String
    let amount: String
    let nonce: String
    let deadline: Int64
    let signature: String
    // Omitted when nil, which is what lets the server derive the
    // authoritative ref instead of cross-checking an empty one.
    let ref: String?
}
