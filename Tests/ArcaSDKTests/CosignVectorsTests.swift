import XCTest
@testable import ArcaSDK

/// Golden vectors from `sdk/typescript/src/fixtures/cosign-vectors.json`, the
/// cross-SDK contract for the co-signed OperatorAction wire format. That
/// fixture is pinned against the authoritative kernel by
/// `backend/contracts/test/v7/CosignVectors.t.sol`, so agreeing with it here
/// is agreeing with the chain.
///
/// A failure means one of two very different things. If the fixture was
/// regenerated, these constants are stale — update them. If it was not, this
/// SDK derives a digest the kernel would reject, and every signature it
/// verifies is worthless.
enum Vectors {
    static let chainId: Int64 = 998
    static let kernel = "0x1111111111111111111111111111111111111111"
    static let domainSeparator = "0xce2ffc6a26f978eacc195d1d9872aff6655c30e93d4a50ae143c2c7332a92d77"
    static let typehash = "0x72c47eb99437aa8c5d7633e14eb25453c9518b3cb628a9db653ca36935b792ea"

    static let fromVenue = "0x000000000000000000000000000000000000beef"
    static let boundary = "0x00000000000000000000000000000000000000000000000000000000000000b0"
    static let toBoundary = "0x00000000000000000000000000000000000000000000000000000000000000b1"
    static let toVenue = "0x000000000000000000000000000000000000feed"
    static let toVenueAccount = "0x0000000000000000000000000000000000000000000000000000000000000009"
    static let token = "0xb88339CB7199b77E23DB6E890353E22632Ba630f"
    static let amountRaw = "75000000"
    static let ref = "0xcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
    static let paramsHash = "0x760217cbdcb92a92a352c5d3253ea65800224dc1ba88ed2cf4aeafe54a735037"

    static let nonce = "12"
    static let deadline: Int64 = 1_900_000_000
    static let digest = "0x684ecc5abcf75bf9258a26a74095027b1be24568ae4d9dd5faa545382ae68581"

    static let preAuthNonce = "13"
    static let preAuthDigest = "0x70be367f6c3880a63b8e89d845af1899f4f71e7050886c8f7b8caad1025b49cc"

    static func proposal(toVenue overrideToVenue: String? = nil) -> VenueHopProposal {
        VenueHopProposal(
            action: CosignAction.transferBetweenVenues,
            boundaryId: "bnd_src",
            boundaryKey: boundary,
            targetBoundaryId: "bnd_dst",
            targetBoundaryKey: toBoundary,
            fromVenue: fromVenue,
            toVenue: overrideToVenue ?? toVenue,
            toVenueAccountKey: toVenueAccount,
            token: token,
            domain: CosignDomain(
                name: cosignDomainName,
                version: cosignDomainVersion,
                chainId: Int(chainId),
                verifyingContract: kernel
            ),
            amount: "75",
            amountRaw: amountRaw,
            ref: ref,
            nonce: nonce,
            deadline: deadline,
            paramsHash: paramsHash,
            digest: digest
        )
    }

    static func hopParamsHash() throws -> String {
        try Cosign.transferBetweenVenuesParamsHash(
            fromVenue: fromVenue,
            fromBoundary: boundary,
            toBoundary: toBoundary,
            toVenue: toVenue,
            toVenueAccountId: toVenueAccount,
            token: token,
            amount: amountRaw,
            ref: ref
        )
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

final class Keccak256Tests: XCTestCase {
    /// The published Keccak-256 vectors. These are what separate a correct
    /// permutation from one that merely runs — and specifically what catches
    /// the SHA-3 padding confusion, since SHA3-256("") is a completely
    /// different digest.
    func testMatchesThePublishedVectors() {
        XCTAssertEqual(
            hex(Keccak256.digest("")),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            "Keccak-256 of the empty string"
        )
        XCTAssertEqual(
            hex(Keccak256.digest("abc")),
            "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        )
        XCTAssertEqual(
            hex(Keccak256.digest("hello")),
            "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"
        )
    }

    /// A 136-byte input is the one that fills the rate exactly, so its padding
    /// needs a whole extra block. Getting that wrong is invisible to short
    /// inputs and to the co-sign vectors, whose preimages are all one block.
    ///
    /// Pinned against an independent implementation (Go's
    /// `sha3.NewLegacyKeccak256`) over `0,1,2,…` truncated to a byte.
    func testPadsCorrectlyAcrossTheRateBoundary() {
        let expected: [Int: String] = [
            135: "cbdfd9dee5faad3818d6b06f95a219fd290b0e1706f6a82e5a595b9ce9faca62",
            136: "7ce759f1ab7f9ce437719970c26b0a66ff11fe3e38e17df89cf5d29c7d7f807e",
            137: "ac73d4fae68b8453f764007c1a20ce95994187861f0c3227a3a8e99a73a3b1db",
        ]
        for (length, want) in expected {
            let input = (0..<length).map { UInt8($0 % 251) }
            XCTAssertEqual(hex(Keccak256.digest(input)), want, "Keccak-256 of a \(length)-byte input")
        }
    }
}

final class CosignVectorsTests: XCTestCase {
    func testOperatorActionTypehashMatchesTheGoldenVector() {
        XCTAssertTrue(Cosign.hexEqual(Cosign.operatorActionTypehash, Vectors.typehash))
    }

    func testDomainSeparatorMatchesTheGoldenVector() throws {
        let derived = try Cosign.domainSeparator(chainId: Vectors.chainId, kernelAddress: Vectors.kernel)
        XCTAssertTrue(
            Cosign.hexEqual(derived, Vectors.domainSeparator),
            "domain separator disagrees with the kernel: \(derived)"
        )
    }

    func testVenueHopParamsHashMatchesTheGoldenVector() throws {
        XCTAssertTrue(Cosign.hexEqual(try Vectors.hopParamsHash(), Vectors.paramsHash))
    }

    /// The exact and capped forms share one preimage; only the action
    /// discriminator inside the digest separates them. If that stopped being
    /// true, a signature authorizing a ceiling would also authorize an exact
    /// move.
    func testExactAndPreAuthShareAParamsHashButNotADigest() throws {
        let paramsHash = try Vectors.hopParamsHash()
        let exact = try Cosign.operatorActionDigest(
            chainId: Vectors.chainId,
            kernelAddress: Vectors.kernel,
            action: CosignAction.transferBetweenVenues,
            boundary: Vectors.boundary,
            paramsHash: paramsHash,
            nonce: Vectors.nonce,
            deadline: Vectors.deadline
        )
        let preAuth = try Cosign.operatorActionDigest(
            chainId: Vectors.chainId,
            kernelAddress: Vectors.kernel,
            action: CosignAction.transferBetweenVenuesPreAuth,
            boundary: Vectors.boundary,
            paramsHash: paramsHash,
            nonce: Vectors.preAuthNonce,
            deadline: Vectors.deadline
        )
        XCTAssertTrue(Cosign.hexEqual(exact, Vectors.digest), "exact digest disagrees with the kernel")
        XCTAssertTrue(Cosign.hexEqual(preAuth, Vectors.preAuthDigest), "pre-auth digest disagrees with the kernel")
        XCTAssertNotEqual(exact, preAuth, "the action discriminator is not bound into the digest")
    }

    func testVerifyAcceptsTheGoldenProposal() throws {
        try Vectors.proposal().verify()
    }

    /// Every field of the preimage must move the paramsHash. A field that does
    /// not is a field an attacker can change after the signature is collected.
    func testEveryHopFieldIsBoundIntoTheParamsHash() throws {
        let base = try Vectors.hopParamsHash()
        let mutations: [(String, () throws -> String)] = [
            ("fromVenue", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: "0x000000000000000000000000000000000000bee0", fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("fromBoundary", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.toBoundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("toBoundary", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.boundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("toVenue", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: "0x000000000000000000000000000000000000fee0",
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("toVenueAccountId", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.ref, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("token", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.kernel,
                amount: Vectors.amountRaw, ref: Vectors.ref) }),
            ("amount", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: "75000001", ref: Vectors.ref) }),
            ("ref", { try Cosign.transferBetweenVenuesParamsHash(
                fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
                toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
                toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
                amount: Vectors.amountRaw, ref: Vectors.toVenueAccount) }),
        ]
        for (field, derive) in mutations {
            XCTAssertNotEqual(
                base, try derive(),
                "changing \(field) left the paramsHash unchanged; it is not bound into the signature"
            )
        }
    }

    /// The uint256 encoder is hand-rolled long multiplication, because a
    /// 256-bit amount fits no Swift integer type. Values above 2^64 are where
    /// a naive implementation silently truncates.
    func testDecimalEncodingHandlesValuesBeyondUInt64() throws {
        let huge = "123456789012345678901234567890123456789"
        let a = try Cosign.transferBetweenVenuesParamsHash(
            fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
            toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
            toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
            amount: huge, ref: Vectors.ref
        )
        let b = try Cosign.transferBetweenVenuesParamsHash(
            fromVenue: Vectors.fromVenue, fromBoundary: Vectors.boundary,
            toBoundary: Vectors.toBoundary, toVenue: Vectors.toVenue,
            toVenueAccountId: Vectors.toVenueAccount, token: Vectors.token,
            amount: "123456789012345678901234567890123456780", ref: Vectors.ref
        )
        XCTAssertNotEqual(a, b, "two 39-digit amounts hashed the same; the encoder is truncating")
    }

    func testVerifyRefusesADomainItCannotDerive() {
        let p = Vectors.proposal()
        let moved = VenueHopProposal(
            action: p.action, boundaryId: p.boundaryId, boundaryKey: p.boundaryKey,
            targetBoundaryId: p.targetBoundaryId, targetBoundaryKey: p.targetBoundaryKey,
            fromVenue: p.fromVenue, toVenue: p.toVenue, toVenueAccountKey: p.toVenueAccountKey,
            token: p.token,
            domain: CosignDomain(name: cosignDomainName, version: "3", chainId: Int(Vectors.chainId),
                                 verifyingContract: Vectors.kernel),
            amount: p.amount, amountRaw: p.amountRaw, ref: p.ref, nonce: p.nonce,
            deadline: p.deadline, paramsHash: p.paramsHash, digest: p.digest
        )
        XCTAssertThrowsError(try moved.verify()) { error in
            XCTAssertEqual(error as? CosignVerificationError, .unknownDomain(name: cosignDomainName, version: "3"))
        }
    }

    func testVerifyCatchesATamperedDestination() {
        XCTAssertThrowsError(try Vectors.proposal(toVenue: "0x000000000000000000000000000000000000dead").verify()) {
            guard case .paramsHashMismatch = ($0 as? CosignVerificationError) else {
                return XCTFail("expected a paramsHash mismatch, got \($0)")
            }
        }
    }

    /// The attack `verify` exists to catch: the paramsHash and digest are the
    /// server's originals, and only the amount the caller is shown has moved.
    func testVerifyCatchesARaisedAmount() {
        let p = Vectors.proposal()
        let raised = VenueHopProposal(
            action: p.action, boundaryId: p.boundaryId, boundaryKey: p.boundaryKey,
            targetBoundaryId: p.targetBoundaryId, targetBoundaryKey: p.targetBoundaryKey,
            fromVenue: p.fromVenue, toVenue: p.toVenue, toVenueAccountKey: p.toVenueAccountKey,
            token: p.token, domain: p.domain, amount: "750", amountRaw: "750000000",
            ref: p.ref, nonce: p.nonce, deadline: p.deadline,
            paramsHash: p.paramsHash, digest: p.digest
        )
        XCTAssertThrowsError(try raised.verify()) {
            guard case .paramsHashMismatch = ($0 as? CosignVerificationError) else {
                return XCTFail("expected a paramsHash mismatch, got \($0)")
            }
        }
    }
}
