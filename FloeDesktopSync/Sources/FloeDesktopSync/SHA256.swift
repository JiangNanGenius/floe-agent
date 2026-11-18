import Foundation

/// Small, dependency-free SHA-256 used only as a payload integrity digest.
/// It is not a signature, MAC or authorization primitive. The implementation
/// follows FIPS 180-4 and is checked against published vectors in the tests.
enum SHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var blockStart = 0
        while blockStart < padded.count {
            for index in 0..<16 {
                let offset = blockStart + index * 4
                w[index] = (UInt32(padded[offset]) << 24)
                    | (UInt32(padded[offset + 1]) << 16)
                    | (UInt32(padded[offset + 2]) << 8)
                    | UInt32(padded[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(w[index - 15], by: 7)
                    ^ rotateRight(w[index - 15], by: 18)
                    ^ (w[index - 15] >> 3)
                let s1 = rotateRight(w[index - 2], by: 17)
                    ^ rotateRight(w[index - 2], by: 19)
                    ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7

            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choose &+ roundConstants[index] &+ w[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h

            blockStart += 64
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for value in [h0, h1, h2, h3, h4, h5, h6, h7] {
            output.append(UInt8(truncatingIfNeeded: value >> 24))
            output.append(UInt8(truncatingIfNeeded: value >> 16))
            output.append(UInt8(truncatingIfNeeded: value >> 8))
            output.append(UInt8(truncatingIfNeeded: value))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

/// Lowercase `sha256:<64 hex>` digest. Comparisons are done on the validated
/// digest, never on the original wire casing.
public struct ContentDigest: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let hex: String

    public init(validating value: String) throws {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else {
            throw SyncStoreError.invalidDigest(value)
        }
        let raw = String(value.dropFirst(prefix.count)).lowercased()
        guard raw.count == 64, raw.allSatisfy({ $0.isHexDigit }) else {
            throw SyncStoreError.invalidDigest(value)
        }
        hex = raw
    }

    public static func compute(_ bytes: [UInt8]) -> ContentDigest {
        let digest = SHA256.digest(bytes)
        var text = ""
        text.reserveCapacity(64)
        for byte in digest {
            text.append(hexCharacters[Int(byte >> 4)])
            text.append(hexCharacters[Int(byte & 0x0f)])
        }
        return ContentDigest(uncheckedHex: text)
    }

    private init(uncheckedHex: String) {
        hex = uncheckedHex
    }

    public var description: String { "sha256:\(hex)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.hex < rhs.hex
    }

    private static let hexCharacters: [Character] = Array("0123456789abcdef")
}
