import Foundation

/// The EIP-712 domain the v7 kernel line verifies co-signatures against.
///
/// Only `chainId` and `verifyingContract` vary between realms. A proposal
/// claiming a different name or version describes a kernel this SDK does not
/// know how to hash for, and is refused rather than signed.
public let cosignDomainName = "ArcaCustodyKernel"
public let cosignDomainVersion = "2"

/// The discriminator bound into the EIP-712 digest. It is what stops a
/// signature collected for one action from authorizing another.
public enum CosignAction {
    public static let transferBetweenVenues = 11
    public static let transferBetweenVenuesPreAuth = 12
}

/// Something a proposal claims that its own fields do not support.
public enum CosignVerificationError: Error, CustomStringConvertible, Equatable {
    /// The proposal is for an EIP-712 domain this SDK cannot derive.
    case unknownDomain(name: String, version: String)
    /// The proposal carries no domain at all.
    case missingDomain
    /// The action is not one of the venue-hop discriminators.
    case unexpectedAction(Int)
    /// A field is not the hex or decimal shape the ABI encoding needs.
    case malformedField(String, value: String)
    /// The server's hash disagrees with the one its own parameters produce.
    case paramsHashMismatch(server: String, derived: String)
    /// The server's digest disagrees with the one its own parameters produce.
    case digestMismatch(server: String, derived: String)

    public var description: String {
        switch self {
        case let .unknownDomain(name, version):
            return """
            arca: venue hop proposal is for EIP-712 domain "\(name)" version "\(version)", but this SDK derives \
            "\(cosignDomainName)" version "\(cosignDomainVersion)" — the kernel's signing contract has moved and \
            this SDK cannot verify what it would be signing
            """
        case .missingDomain:
            return "arca: venue hop proposal carries no EIP-712 domain; there is nothing to verify it against"
        case let .unexpectedAction(action):
            return """
            arca: venue hop proposal carries action \(action), want \(CosignAction.transferBetweenVenues) or \
            \(CosignAction.transferBetweenVenuesPreAuth)
            """
        case let .malformedField(field, value):
            return "arca: venue hop proposal field \(field) is malformed: \"\(value)\""
        case let .paramsHashMismatch(server, derived):
            return """
            arca: venue hop paramsHash mismatch: server returned \(server), the returned parameters hash to \
            \(derived) — do not sign this proposal
            """
        case let .digestMismatch(server, derived):
            return """
            arca: venue hop digest mismatch: server returned \(server), the returned parameters digest to \
            \(derived) — do not sign this proposal
            """
        }
    }
}

/// Derives the hashes a co-signature commits to.
///
/// A co-signature over a digest you did not compute is an attestation to a
/// 32-byte number you cannot read. These helpers let a signer re-derive that
/// number from the semantic fields it was shown — destination venue, amount,
/// boundary — and refuse when the two disagree.
///
/// Signing itself is deliberately absent. It needs secp256k1, which this SDK
/// does not depend on and should not hand-roll; on iOS the key belongs in the
/// Secure Enclave or a wallet app anyway. Verify here, sign there.
public enum Cosign {
    private static let eip712DomainTypehash = Keccak256.digest(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    )
    private static let operatorActionTypehashBytes = Keccak256.digest(
        "OperatorAction(uint8 actionType,bytes32 boundary,bytes32 paramsHash,uint256 nonce,uint256 deadline)"
    )

    /// The EIP-712 struct typehash, for cross-checking against the kernel's constant.
    public static var operatorActionTypehash: String { "0x" + hex(operatorActionTypehashBytes) }

    /// The EIP-712 domain separator for a kernel — equal to its
    /// `eip712DomainSeparator()` view, derived locally so a signer never has
    /// to trust a server's answer for it.
    public static func domainSeparator(chainId: Int64, kernelAddress: String) throws -> String {
        var buf = eip712DomainTypehash
        buf += Keccak256.digest(cosignDomainName)
        buf += Keccak256.digest(cosignDomainVersion)
        buf += abiUInt(chainId)
        buf += try abiAddress(kernelAddress, field: "verifyingContract")
        return "0x" + hex(Keccak256.digest(buf))
    }

    /// The digest a co-sign key must sign, equal to the kernel's
    /// `hashOperatorAction(...)` view.
    ///
    /// `nonce` is decimal. On the v7 line nonces are unordered: any unused
    /// value works and each is single-use.
    public static func operatorActionDigest(
        chainId: Int64,
        kernelAddress: String,
        action: Int,
        boundary: String,
        paramsHash: String,
        nonce: String,
        deadline: Int64
    ) throws -> String {
        var structBuf = operatorActionTypehashBytes
        structBuf += abiUInt(Int64(action))
        structBuf += try abiBytes32(boundary, field: "boundary")
        structBuf += try abiBytes32(paramsHash, field: "paramsHash")
        structBuf += try abiDecimal(nonce, field: "nonce")
        structBuf += abiUInt(deadline)
        let structHash = Keccak256.digest(structBuf)

        let separator = try abiBytes32(
            domainSeparator(chainId: chainId, kernelAddress: kernelAddress),
            field: "domainSeparator"
        )
        return "0x" + hex(Keccak256.digest([0x19, 0x01] + separator + structHash))
    }

    /// The `paramsHash` of a venue-to-venue hop.
    ///
    /// Matches the kernel's `keccak256(abi.encode(...))` over the same fields.
    /// The exact (action 11) and capped pre-auth (action 12) forms share this
    /// preimage; only the action discriminator in the digest separates them.
    ///
    /// `amount` is the uint256 the kernel moves, in token base units — a
    /// proposal's `amountRaw`, never its human-decimal `amount`. Encoding the
    /// decimal produces a different hash and a signature the kernel rejects.
    public static func transferBetweenVenuesParamsHash(
        fromVenue: String,
        fromBoundary: String,
        toBoundary: String,
        toVenue: String,
        toVenueAccountId: String,
        token: String,
        amount: String,
        ref: String
    ) throws -> String {
        var buf = try abiAddress(fromVenue, field: "fromVenue")
        buf += try abiBytes32(fromBoundary, field: "fromBoundary")
        buf += try abiBytes32(toBoundary, field: "toBoundary")
        buf += try abiAddress(toVenue, field: "toVenue")
        buf += try abiBytes32(toVenueAccountId, field: "toVenueAccountId")
        buf += try abiAddress(token, field: "token")
        buf += try abiDecimal(amount, field: "amount")
        buf += try abiBytes32(ref, field: "ref")
        return "0x" + hex(Keccak256.digest(buf))
    }

    // MARK: - ABI word encoding

    private static func abiUInt(_ value: Int64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var v = UInt64(bitPattern: value)
        for i in stride(from: 31, through: 24, by: -1) {
            out[i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
        return out
    }

    /// Big-endian 32-byte encoding of an arbitrary-width decimal. Done by hand
    /// because a uint256 does not fit any Swift integer type and the SDK has
    /// no BigInt to lean on.
    private static func abiDecimal(_ s: String, field: String) throws -> [UInt8] {
        let digits = s.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw CosignVerificationError.malformedField(field, value: s)
        }
        // Repeated base-256 long division: multiply the accumulator by ten and
        // add each digit, carrying across the 32 bytes.
        var out = [UInt8](repeating: 0, count: 32)
        for character in digits {
            var carry = UInt32(character.wholeNumberValue ?? 0)
            for i in stride(from: 31, through: 0, by: -1) {
                let product = UInt32(out[i]) * 10 + carry
                out[i] = UInt8(product & 0xFF)
                carry = product >> 8
            }
            if carry != 0 {
                throw CosignVerificationError.malformedField(field, value: s) // overflows uint256
            }
        }
        return out
    }

    private static func abiAddress(_ s: String, field: String) throws -> [UInt8] {
        let raw = try decodeHex(s, field: field)
        guard raw.count == 20 else { throw CosignVerificationError.malformedField(field, value: s) }
        return [UInt8](repeating: 0, count: 12) + raw
    }

    private static func abiBytes32(_ s: String, field: String) throws -> [UInt8] {
        let raw = try decodeHex(s, field: field)
        guard raw.count == 32 else { throw CosignVerificationError.malformedField(field, value: s) }
        return raw
    }

    private static func decodeHex(_ s: String, field: String) throws -> [UInt8] {
        var body = Substring(s.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
        guard !body.isEmpty, body.count % 2 == 0 else {
            throw CosignVerificationError.malformedField(field, value: s)
        }
        var out = [UInt8]()
        out.reserveCapacity(body.count / 2)
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2)
            guard let byte = UInt8(body[index..<next], radix: 16) else {
                throw CosignVerificationError.malformedField(field, value: s)
            }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hexEqual(_ a: String, _ b: String) -> Bool {
        func normalise(_ s: String) -> String {
            var t = Substring(s)
            if t.hasPrefix("0x") || t.hasPrefix("0X") { t = t.dropFirst(2) }
            return t.lowercased()
        }
        return normalise(a) == normalise(b)
    }
}
