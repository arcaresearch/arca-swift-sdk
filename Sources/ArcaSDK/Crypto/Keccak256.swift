import Foundation

/// Keccak-256, the hash Ethereum uses.
///
/// Hand-rolled because this SDK ships with zero third-party dependencies and
/// adding a crypto package to compute one hash would end that. Apple's
/// CryptoKit is not a substitute: it offers SHA-2 and SHA-3, and SHA3-256
/// finalises with the 0x06 domain byte where original Keccak uses 0x01, so it
/// produces a different digest for every input.
///
/// Correctness is pinned by the published Keccak vectors and by the cross-SDK
/// co-sign golden vectors in `CosignVectorsTests`.
enum Keccak256 {
    /// 1600-bit state with a 256-bit capacity.
    private static let rateBytes = 136

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    /// Lane destinations and rotation offsets for the combined rho+pi step, in
    /// the order the standard's compact formulation visits them.
    private static let piLanes: [Int] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
        15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]
    private static let rhoOffsets: [UInt64] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
        27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]

    static func digest(_ input: [UInt8]) -> [UInt8] {
        var state = [UInt64](repeating: 0, count: 25)

        // Absorb every whole block.
        var offset = 0
        while input.count - offset >= rateBytes {
            absorb(&state, input, offset)
            permute(&state)
            offset += rateBytes
        }

        // Absorb the tail under pad10*1 with Keccak's 0x01 domain byte.
        var tail = [UInt8](repeating: 0, count: rateBytes)
        let remaining = input.count - offset
        for i in 0..<remaining { tail[i] = input[offset + i] }
        tail[remaining] = 0x01
        tail[rateBytes - 1] |= 0x80
        absorb(&state, tail, 0)
        permute(&state)

        // Squeeze 32 bytes; the rate is wider, so one pass suffices.
        var out = [UInt8](repeating: 0, count: 32)
        for lane in 0..<4 {
            var value = state[lane]
            for byte in 0..<8 {
                out[lane * 8 + byte] = UInt8(truncatingIfNeeded: value)
                value >>= 8
            }
        }
        return out
    }

    static func digest(_ input: Data) -> [UInt8] { digest([UInt8](input)) }
    static func digest(_ input: String) -> [UInt8] { digest([UInt8](input.utf8)) }

    private static func absorb(_ state: inout [UInt64], _ block: [UInt8], _ offset: Int) {
        for i in 0..<(rateBytes / 8) {
            var lane: UInt64 = 0
            for b in stride(from: 7, through: 0, by: -1) {
                lane = (lane << 8) | UInt64(block[offset + i * 8 + b])
            }
            state[i] ^= lane
        }
    }

    private static func permute(_ a: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // theta
            for x in 0..<5 {
                c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
            }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) {
                    a[x + y] ^= d
                }
            }

            // rho + pi
            var last = a[1]
            for i in 0..<24 {
                let lane = piLanes[i]
                let held = a[lane]
                a[lane] = rotl(last, rhoOffsets[i])
                last = held
            }

            // chi
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0..<5 { c[x] = a[y + x] }
                for x in 0..<5 {
                    a[y + x] = c[x] ^ (~c[(x + 1) % 5] & c[(x + 2) % 5])
                }
            }

            // iota
            a[0] ^= roundConstants[round]
        }
    }

    private static func rotl(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        (value << shift) | (value >> (64 - shift))
    }
}
