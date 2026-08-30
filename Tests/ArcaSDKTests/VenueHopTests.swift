import XCTest
@testable import ArcaSDK

/// Venue-hop tests.
///
/// `hopVenues` exists so a caller does not have to know whether the source
/// boundary is co-sign armed: it runs the plain transfer, and only if that is
/// refused does it propose, sign, and submit. These pin both arms and, more
/// importantly, the refusals that must NOT take the signed path.
final class VenueHopTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [HopMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        HopMockProtocol.reset()
    }

    func testUnarmedBoundaryIsAPlainTransferAndNeverSigns() async throws {
        let arca = makeArca()
        let signed = Flag()

        let res = try await arca.hopVenues(
            path: "/op/transfer/hop-1",
            from: "/users/a/exchange/hl",
            to: "/users/b/exchange/paper",
            amount: "500",
            sign: { _, _ in signed.set(); return "0xsig" }
        ).submitted

        XCTAssertEqual(res.operation.id.rawValue, "op_plain")
        XCTAssertFalse(signed.value, "the signer ran on an unarmed boundary; no signature is needed there")
        XCTAssertEqual(HopMockProtocol.requests.count, 1, "issued more than the plain transfer")
    }

    func testArmedBoundaryProposesSignsAndSubmits() async throws {
        HopMockProtocol.armed = true
        let arca = makeArca()
        let seen = Captured()

        let res = try await arca.hopVenues(
            path: "/op/transfer/hop-2",
            from: "/users/a/exchange/hl",
            to: "/users/b/exchange/paper",
            amount: "500",
            sign: { digest, proposal in
                seen.record(digest: digest, amountRaw: proposal.amountRaw)
                return "0xsignature"
            }
        ).submitted

        XCTAssertEqual(seen.digest, Vectors.digest, "the signer must see the kernel-derived digest")
        // The paramsHash commits to the raw uint256; a signer that encodes the
        // decimal string produces a hash the kernel will not match.
        XCTAssertEqual(seen.amountRaw, Vectors.amountRaw)
        XCTAssertEqual(res.boundaryId, "bnd_src")
        XCTAssertEqual(res.targetBoundaryId, "bnd_dst")

        let reqs = HopMockProtocol.requests
        XCTAssertEqual(reqs.count, 3, "want transfer + propose + submit, got \(reqs.map(\.path))")

        // These routes read the realm from the query string, and the ordinary
        // post() sent none until it gained a query parameter.
        XCTAssertTrue(reqs[1].query.contains("realmId="), "propose carried no realmId: \(reqs[1].query)")
        XCTAssertTrue(reqs[2].query.contains("realmId="), "submit carried no realmId: \(reqs[2].query)")

        XCTAssertEqual(reqs[1].body["path"] as? String, "/op/transfer/hop-2")
        // The signed ref derives from the operation path, so submitting at a
        // different path than was proposed would be refused server-side.
        XCTAssertEqual(reqs[2].body["path"] as? String, reqs[1].body["path"] as? String)
        XCTAssertEqual(reqs[2].body["signature"] as? String, "0xsignature")
        XCTAssertEqual(reqs[2].body["nonce"] as? String, Vectors.nonce)
    }

    /// The reason the digest is re-derived rather than relayed. A server that
    /// describes one hop and asks for a signature over another is caught
    /// before the key is used, so the co-signature means what the user was
    /// shown.
    func testTamperedProposalNeverReachesTheSigner() async {
        HopMockProtocol.armed = true
        HopMockProtocol.tampered = true
        let arca = makeArca()
        let signed = Flag()

        do {
            _ = try await arca.hopVenues(
                path: "/op/transfer/hop-4",
                from: "/users/a/exchange/hl",
                to: "/users/b/exchange/paper",
                amount: "500",
                sign: { _, _ in signed.set(); return "0xsignature" }
            ).submitted
            XCTFail("expected a refusal for a proposal whose digest does not match its parameters")
        } catch let error as CosignVerificationError {
            guard case .paramsHashMismatch = error else {
                return XCTFail("expected a paramsHash mismatch, got \(error)")
            }
        } catch {
            XCTFail("error is \(error), want a CosignVerificationError")
        }

        XCTAssertFalse(signed.value, "the signer was handed a digest the proposal's own fields do not produce")
        XCTAssertEqual(
            HopMockProtocol.requests.count, 2,
            "want transfer + propose and no submit, got \(HopMockProtocol.requests.map(\.path))"
        )
    }

    func testArmedBoundaryWithoutSignerSurfacesTheChallenge() async {
        HopMockProtocol.armed = true
        let arca = makeArca()

        do {
            _ = try await arca.hopVenues(
                path: "/op/transfer/hop-3", from: "/a/exchange", to: "/b/exchange", amount: "5"
            ).submitted
            XCTFail("expected a refusal with no signer on an armed boundary")
        } catch let ArcaError.cosignRequired(_, challenge, _) {
            XCTAssertEqual(challenge.surface, "transfer.venue_hop")
            XCTAssertEqual(challenge.boundaryId, "bnd_src")
            XCTAssertEqual(challenge.propose, "/api/v1/custody/venue-hops/propose")
        } catch {
            XCTFail("error is \(error), want .cosignRequired with a challenge")
        }
        XCTAssertEqual(HopMockProtocol.requests.count, 1, "issued more than the refused transfer")
    }

    func testRefusalASignatureCannotFixDoesNotTakeTheSignedPath() async {
        HopMockProtocol.plainRefusal = ("VALIDATION_ERROR", "Venue-to-venue transfers cannot charge a transfer fee")
        let arca = makeArca()
        let signed = Flag()

        do {
            _ = try await arca.hopVenues(
                path: "/op/transfer/hop-4", from: "/a/exchange", to: "/b/exchange", amount: "5",
                sign: { _, _ in signed.set(); return "0xsig" }
            ).submitted
            XCTFail("expected the validation refusal to propagate")
        } catch let ArcaError.validation(message, _) {
            XCTAssertTrue(message.contains("transfer fee"))
        } catch {
            XCTFail("error is \(error), want .validation")
        }
        XCTAssertFalse(signed.value, "the signer ran for a refusal a signature cannot fix")
    }

    /// A spent nonce is an ordinary lifecycle outcome — a retry racing the
    /// original, or a user who cancelled — not a signing failure. Before the
    /// dedicated code existed, the only signal separating the two was message
    /// text, so integrators reported "that approval didn't match this request"
    /// for signatures that were perfectly valid.
    func testSpentNonceSurfacesAsItsOwnCaseNotAValidationFailure() async {
        HopMockProtocol.armed = true
        HopMockProtocol.nonceUsedOnSubmit = true
        let arca = makeArca()

        do {
            _ = try await arca.hopVenues(
                path: "/op/transfer/hop-6", from: "/a/exchange", to: "/b/exchange", amount: "5",
                sign: { _, _ in "0xsignature" }
            ).submitted
            XCTFail("expected the spent-nonce refusal to propagate")
        } catch let ArcaError.cosignNonceUsed(_, details, _) {
            XCTAssertEqual(details.boundaryId, "bnd_src")
            XCTAssertEqual(details.reason, "nonce_consumed")
            XCTAssertEqual(details.nonce, Vectors.nonce)
            XCTAssertTrue(
                details.resolution?.contains("re-propose") == true,
                "the refusal must name the remedy: \(details.resolution ?? "nil")"
            )
            // The owner cancelled it, so nothing moved and there is no
            // operation of ours to name. Only this disposition licenses the
            // caller to assert that.
            XCTAssertEqual(details.disposition, .revoked)
            XCTAssertNil(details.operationId)
        } catch {
            XCTFail("error is \(error), want .cosignNonceUsed — a spent slot is not a bad signature")
        }
    }

    func testGetCosignNonceStateReadsTheBurnSetOnAnUnorderedKernel() async throws {
        let arca = makeArca()
        let state = try await arca.getCosignNonceState(
            boundaryId: "bnd_v7", nonce: "9223372036854775807"
        )

        XCTAssertFalse(state.spendable)
        XCTAssertTrue(state.consumed)
        XCTAssertTrue(state.unordered)
        // A 63-bit nonce exceeds what a JSON number carries losslessly in
        // every consumer, so it must round-trip as a string.
        XCTAssertEqual(state.nonce, "9223372036854775807")
        XCTAssertNil(state.counterNonce, "surfacing the frozen slot invites signing against it")
        XCTAssertTrue(HopMockProtocol.getRequests[0].query.contains("realmId="))
        XCTAssertTrue(
            HopMockProtocol.getRequests[0].path.hasSuffix("/cosign-nonces/9223372036854775807")
        )
    }

    /// The trap: a frozen-counter kernel has no burn set, so `consumed` is
    /// structurally false even for a nonce it will refuse. Callers must be able
    /// to trust `spendable` alone.
    func testGetCosignNonceStateReportsNotSpendableOnACounterKernel() async throws {
        HopMockProtocol.counterKernel = true
        let arca = makeArca()
        let state = try await arca.getCosignNonceState(boundaryId: "bnd_k5", nonce: "8")

        XCTAssertFalse(state.consumed, "consumed is structural on a kernel with no burn set")
        XCTAssertFalse(state.spendable)
        XCTAssertFalse(state.unordered)
        XCTAssertEqual(state.counterNonce, "9")
    }

    /// `spendable == false` alone leaves the caller unable to say whether the
    /// customer's money moved. These three fields are the answer.
    func testGetCosignNonceStateAttributesABurnedSlotToItsExecution() async throws {
        HopMockProtocol.nonceStateBody = HopMockProtocol.nonceStateExecuted
        let state = try await makeArca().getCosignNonceState(boundaryId: "bnd_v7", nonce: "42")

        XCTAssertEqual(state.disposition, .executed)
        XCTAssertEqual(state.operationId, "op_01k")
        XCTAssertEqual(state.txHash, "0xabc")
    }

    func testGetCosignNonceStateLeavesASpendableSlotUnattributed() async throws {
        HopMockProtocol.nonceStateBody = HopMockProtocol.nonceStateSpendable
        let state = try await makeArca().getCosignNonceState(boundaryId: "bnd_v7", nonce: "42")

        XCTAssertTrue(state.spendable)
        // Nothing burned it, so there is nothing to attribute. Reporting
        // `.unknown` here would read as "we couldn't tell", which is wrong.
        XCTAssertNil(state.disposition)
        XCTAssertNil(state.txHash)
    }

    /// Swift's synthesized `Codable` for a `String` enum *throws* on an
    /// unrecognized raw value, so without the custom decoder a newer server
    /// value would turn this read into a decode failure — and a `default` arm
    /// gets written as "not executed, so nothing moved" far more often than as
    /// "unrecognized, go reconcile".
    func testGetCosignNonceStateNarrowsAnUnrecognizedDispositionToUnknown() async throws {
        HopMockProtocol.nonceStateBody = HopMockProtocol.nonceStateFutureDisposition
        let state = try await makeArca().getCosignNonceState(boundaryId: "bnd_v7", nonce: "42")

        XCTAssertEqual(state.disposition, .unknown)
    }

    func testSubmitVenueHopOmitsAnUnsetRefSoTheServerDerivesIt() async throws {
        let arca = makeArca()
        _ = try await arca.submitVenueHop(
            path: "/op/transfer/hop-5", from: "/a/exchange", to: "/b/exchange",
            amount: "25", nonce: "3", deadline: 1_893_456_000, signature: "0xsig"
        ).submitted

        let body = HopMockProtocol.requests[0].body
        XCTAssertEqual(body["signature"] as? String, "0xsig")
        // A supplied ref is a cross-check; sending an empty one would fail it.
        XCTAssertNil(body["ref"], "an unset ref was serialized")
        XCTAssertTrue(HopMockProtocol.requests[0].query.contains("realmId="))
    }

    // MARK: - Helpers

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19996")!,
            urlSessionConfiguration: sessionConfig
        )
    }

    private func fakeJwt() -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64(#"{"realmId":"rlm_test","sub":"usr_test"}"#)).sig"
    }
}

/// Mutable capture boxes — the signer closure is `@Sendable`, so it cannot
/// write to a local `var` directly.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _digest = ""
    private var _amountRaw = ""
    func record(digest: String, amountRaw: String) {
        lock.lock(); _digest = digest; _amountRaw = amountRaw; lock.unlock()
    }
    var digest: String { lock.lock(); defer { lock.unlock() }; return _digest }
    var amountRaw: String { lock.lock(); defer { lock.unlock() }; return _amountRaw }
}

private struct RecordedRequest {
    let path: String
    let query: String
    let body: [String: Any]
}

private final class HopMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [RecordedRequest] = []
    private static var _getRequests: [RecordedRequest] = []
    /// When true, the plain transfer answers 412 like an armed boundary.
    nonisolated(unsafe) static var armed = false
    /// When set, the plain transfer answers with this refusal instead.
    nonisolated(unsafe) static var plainRefusal: (String, String)?
    /// When true, propose returns a destination its own paramsHash disowns.
    nonisolated(unsafe) static var tampered = false
    /// When true, the submit answers 412 COSIGN_NONCE_USED.
    nonisolated(unsafe) static var nonceUsedOnSubmit = false
    /// When true, the nonce-state read answers as a pre-v7 counter kernel.
    nonisolated(unsafe) static var counterKernel = false
    /// When set, the nonce-state read answers with this body verbatim.
    nonisolated(unsafe) static var nonceStateBody: String?

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    /// GETs, kept separately so the POST-ordering assertions stay exact.
    static var getRequests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }; return _getRequests
    }

    static func reset() {
        lock.lock(); _requests = []; _getRequests = []; lock.unlock()
        armed = false
        plainRefusal = nil
        tampered = false
        nonceUsedOnSubmit = false
        counterKernel = false
        nonceStateBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        var body: [String: Any] = [:]
        if let data = Self.readBody(request),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = obj
        }
        Self.lock.lock()
        if request.httpMethod == "POST" {
            Self._requests.append(RecordedRequest(path: path, query: query, body: body))
        } else {
            Self._getRequests.append(RecordedRequest(path: path, query: query, body: body))
        }
        Self.lock.unlock()

        if path.contains("/cosign-nonces/") {
            respond(
                Self.nonceStateBody
                    ?? (Self.counterKernel ? Self.nonceStateCounter : Self.nonceStateConsumed)
            )
        } else if path.hasSuffix("/custody/venue-hops/propose") {
            respond(Self.tampered ? Self.tamperedProposal : Self.proposal)
        } else if path.hasSuffix("/custody/venue-hops") {
            if Self.nonceUsedOnSubmit {
                respond(Self.nonceUsedRefusal, status: 412)
            } else {
                respond(Self.submitted)
            }
        } else if path.hasSuffix("/transfer") {
            if Self.armed {
                respond(Self.cosignRefusal, status: 412)
            } else if let refusal = Self.plainRefusal {
                respond(#"{"success":false,"error":{"code":"\#(refusal.0)","message":"\#(refusal.1)"}}"#, status: 400)
            } else {
                respond(Self.plainTransfer)
            }
        } else {
            respond(#"{"success":true,"data":{}}"#)
        }
    }

    private func respond(_ json: String, status: Int = 200) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLProtocol strips httpBody for streamed uploads; read the stream when
    /// the body property is empty.
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func operation(_ id: String) -> String {
        """
        {"id":"\(id)","realmId":"rlm_test","path":"/op/transfer/hop","type":"transfer",
         "state":"completed","createdAt":"2026-08-29T00:00:00Z","updatedAt":"2026-08-29T00:00:00Z"}
        """
    }

    static var plainTransfer: String {
        #"{"success":true,"data":{"operation":\#(operation("op_plain"))}}"#
    }

    static var submitted: String {
        #"""
        {"success":true,"data":{"operation":\#(operation("op_hop")),
         "boundaryId":"bnd_src","targetBoundaryId":"bnd_dst"}}
        """#
    }

    /// The cross-SDK golden vector dressed as a live proposal, so the armed
    /// path exercises a digest that actually verifies rather than a
    /// placeholder. `hopVenues` re-derives it before signing and would reject
    /// anything else.
    static var proposal: String { proposalJSON(toVenue: Vectors.toVenue) }

    /// The same proposal with a redirected destination — a server describing
    /// one hop while asking for a signature over another.
    static var tamperedProposal: String {
        proposalJSON(toVenue: "0x000000000000000000000000000000000000dead")
    }

    private static func proposalJSON(toVenue: String) -> String {
        """
        {"success":true,"data":{"action":\(CosignAction.transferBetweenVenues),
         "boundaryId":"bnd_src","boundaryKey":"\(Vectors.boundary)",
         "targetBoundaryId":"bnd_dst","targetBoundaryKey":"\(Vectors.toBoundary)",
         "fromVenue":"\(Vectors.fromVenue)","toVenue":"\(toVenue)",
         "toVenueAccountKey":"\(Vectors.toVenueAccount)","token":"\(Vectors.token)",
         "domain":{"name":"\(cosignDomainName)","version":"\(cosignDomainVersion)",
                   "chainId":\(Vectors.chainId),"verifyingContract":"\(Vectors.kernel)"},
         "amount":"75.000000","amountRaw":"\(Vectors.amountRaw)",
         "ref":"\(Vectors.ref)","nonce":"\(Vectors.nonce)","deadline":\(Vectors.deadline),
         "paramsHash":"\(Vectors.paramsHash)","digest":"\(Vectors.digest)"}}
        """
    }

    static let cosignRefusal = #"""
    {"success":false,"error":{"code":"COSIGN_REQUIRED",
     "message":"The source exchange object's boundary requires user co-signed value-out operations.",
     "details":{"surface":"transfer.venue_hop","boundaryId":"bnd_src",
       "sourceArcaPath":"/users/a/exchange/hl","targetArcaPath":"/users/b/exchange/paper",
       "propose":"/api/v1/custody/venue-hops/propose","submit":"/api/v1/custody/venue-hops"}}}
    """#

    static var nonceUsedRefusal: String {
        """
        {"success":false,"error":{"code":"COSIGN_NONCE_USED",
         "message":"co-sign nonce has already been used; re-propose the action",
         "details":{"boundaryId":"bnd_src","nonce":"\(Vectors.nonce)","reason":"nonce_consumed",
           "resolution":"re-propose the action to obtain a fresh nonce, re-sign, and resubmit",
           "disposition":"revoked","txHash":"0xdead"}}}
        """
    }

    static let nonceStateConsumed = #"""
    {"success":true,"data":{"boundaryId":"bnd_v7","nonce":"9223372036854775807",
     "spendable":false,"consumed":true,"unordered":true}}
    """#

    static let nonceStateCounter = #"""
    {"success":true,"data":{"boundaryId":"bnd_k5","nonce":"8",
     "spendable":false,"consumed":false,"unordered":false,"counterNonce":"9"}}
    """#

    static let nonceStateExecuted = #"""
    {"success":true,"data":{"boundaryId":"bnd_v7","nonce":"42",
     "spendable":false,"consumed":true,"unordered":true,
     "disposition":"executed","txHash":"0xabc","operationId":"op_01k"}}
    """#

    static let nonceStateSpendable = #"""
    {"success":true,"data":{"boundaryId":"bnd_v7","nonce":"42",
     "spendable":true,"consumed":false,"unordered":true}}
    """#

    /// A disposition from a server newer than this SDK.
    static let nonceStateFutureDisposition = #"""
    {"success":true,"data":{"boundaryId":"bnd_v7","nonce":"42",
     "spendable":false,"consumed":true,"unordered":true,
     "disposition":"superseded_by_something_new"}}
    """#
}
