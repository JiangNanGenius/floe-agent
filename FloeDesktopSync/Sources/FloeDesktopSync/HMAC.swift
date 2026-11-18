import Foundation

/// HMAC-SHA-256 (RFC 2104 / FIPS 180-4). This is a symmetric authentication
/// primitive, not a content digest: a tag cannot be produced without the key.
/// The shared key is established by the authenticated pairing/transport layer
/// and is never persisted in the sync database.
enum HMACSHA256 {
    static let blockSize = 64

    /// RFC 2104 key block. Different raw keys can normalize to the same block
    /// (short zero-padding, or a long key and its digest). Peer registration
    /// must compare this effective key, never just the input byte strings.
    static func normalizeKey(_ key: [UInt8]) -> [UInt8] {
        var normalized = key.count > blockSize ? SHA256.digest(key) : key
        if normalized.count < blockSize {
            normalized.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalized.count))
        }
        return normalized
    }

    static func authenticationCode(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let normalized = normalizeKey(key)
        var inner = [UInt8](repeating: 0x36, count: blockSize)
        var outer = [UInt8](repeating: 0x5c, count: blockSize)
        for index in 0..<blockSize {
            inner[index] ^= normalized[index]
            outer[index] ^= normalized[index]
        }
        let innerDigest = SHA256.digest(inner + message)
        return SHA256.digest(outer + innerDigest)
    }

    /// Compares every byte in constant time. Callers must not leak how many
    /// leading bytes matched.
    static func isValid(tag: [UInt8], key: [UInt8], message: [UInt8]) -> Bool {
        let expected = authenticationCode(key: key, message: message)
        guard tag.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<tag.count {
            difference |= tag[index] ^ expected[index]
        }
        return difference == 0
    }
}

/// A device-local HMAC key. The raw bytes are deliberately not printable and
/// not Codable; integrations load them from pairing state or the platform
/// credential store. Test fixtures may construct deterministic keys.
public struct SyncProofKey: Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    /// Requires at least 256 bits of key material. Longer keys up to the HMAC
    /// block size are accepted unchanged; longer values are hashed by HMAC.
    public init(rawRepresentation: Data) throws {
        try self.init(rawRepresentation: [UInt8](rawRepresentation))
    }

    public init(rawRepresentation: [UInt8]) throws {
        guard rawRepresentation.count >= 32, rawRepresentation.count <= 1_024 else {
            throw SyncStoreError.invalidAuthenticationKey
        }
        bytes = rawRepresentation
    }

    public var description: String { "SyncProofKey(redacted, \(bytes.count) bytes)" }
}

/// A lowercase `hmac-sha256:<64 hex>` authentication tag. Unlike
/// `ContentDigest`, verifying this value requires the shared key; a bare
/// digest is never accepted as proof of sender identity.
public struct IncrementalAuthenticationTag: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public init(validating value: String) throws {
        let prefix = "hmac-sha256:"
        guard value.hasPrefix(prefix) else {
            throw SyncStoreError.invalidAuthenticationProof(
                "authentication tag must use the hmac-sha256: prefix"
            )
        }
        let raw = String(value.dropFirst(prefix.count)).lowercased()
        guard raw.count == 64, raw.allSatisfy({ $0.isHexDigit }) else {
            throw SyncStoreError.invalidAuthenticationProof(
                "authentication tag must contain 64 hexadecimal characters"
            )
        }
        hex = raw
    }

    init(uncheckedHex: String) {
        hex = uncheckedHex
    }

    public var description: String { "hmac-sha256:\(hex)" }

    static func compute(key: SyncProofKey, message: [UInt8]) -> IncrementalAuthenticationTag {
        let code = HMACSHA256.authenticationCode(key: key.bytes, message: message)
        var text = ""
        text.reserveCapacity(64)
        for byte in code {
            text.append(hexCharacters[Int(byte >> 4)])
            text.append(hexCharacters[Int(byte & 0x0f)])
        }
        return IncrementalAuthenticationTag(uncheckedHex: text)
    }

    func verify(key: SyncProofKey, message: [UInt8]) -> Bool {
        guard let raw = [UInt8](hex: hex) else { return false }
        return HMACSHA256.isValid(tag: raw, key: key.bytes, message: message)
    }

    private static let hexCharacters: [Character] = Array("0123456789abcdef")
}

private extension Array where Element == UInt8 {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
