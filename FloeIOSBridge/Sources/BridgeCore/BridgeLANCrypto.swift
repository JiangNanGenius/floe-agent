import CryptoKit
import Foundation
import Security

/// Bounded limits shared by the LAN control envelope, HTTP framing and result
/// retrieval. These are prototype budgets, not product defaults.
public struct BridgeLANLimits: Sendable {
    public var maxEnvelopeBytes: Int
    public var maxCiphertextBytes: Int
    public var maxResponseBytes: Int
    public var maxRequestHeadBytes: Int
    public var maxRequestBodyBytes: Int
    public var maxArtifactBytes: Int
    public var timestampWindow: TimeInterval
    public var nonceCapacity: Int
    public var commandTTL: TimeInterval
    public var maxCommandRecords: Int
    public var maxConnections: Int
    public var requestTimeout: TimeInterval

    public init(
        maxEnvelopeBytes: Int = 65_536,
        maxCiphertextBytes: Int = 49_152,
        maxResponseBytes: Int = 12 * 1_024 * 1_024,
        maxRequestHeadBytes: Int = 16_384,
        maxRequestBodyBytes: Int = 65_536,
        maxArtifactBytes: Int = 6 * 1_024 * 1_024,
        timestampWindow: TimeInterval = 120,
        nonceCapacity: Int = 4_096,
        commandTTL: TimeInterval = 900,
        maxCommandRecords: Int = 256,
        maxConnections: Int = 8,
        requestTimeout: TimeInterval = 5
    ) {
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.maxCiphertextBytes = maxCiphertextBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxRequestHeadBytes = maxRequestHeadBytes
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxArtifactBytes = maxArtifactBytes
        self.timestampWindow = timestampWindow
        self.nonceCapacity = nonceCapacity
        self.commandTTL = commandTTL
        self.maxCommandRecords = maxCommandRecords
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
    }

    public static let `default` = BridgeLANLimits()
}

/// Wire-compatible v1 envelope primitives for the pinned OpenMinis/iCTRL
/// contract (`c1e4268859ba858d1579f7b846a56cb40641b7f6`).
///
/// The construction is intentionally the upstream one: HMAC-SHA256 provides
/// every key, the request and response use direction-separated labels, the
/// stream cipher is an HMAC counter-mode keystream, and the tag binds
/// `"v1" || tok_4B || be64(ts) || nonce || ct`. This file is an independent
/// Swift adaptation of `iCTRLKit/SecureEnvelope.swift`; see
/// `ThirdParty/PATCHES.md` and the retained Apache-2.0 NOTICE.
///
/// This is a *transport* primitive only. The 32-byte key is provisioned
/// separately and is never the legacy diagnostics bearer token.
public enum BridgeLANCrypto {
    public static let labelMac = "ictrl-v1|mac"
    public static let labelEncRequest = "ictrl-v1|enc-req"
    public static let labelEncResponse = "ictrl-v1|enc-resp"
    public static let timestampWindow: TimeInterval = 120
    public static let nonceByteCount = 16
    public static let tagByteCount = 32
    public static let keyByteCount = 32

    public struct Failure: Error, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct ParsedEnvelope: Sendable {
        public let tokId: String
        public let timestamp: Int
        public let nonceHex: String
        public let nonce: Data
        public let ciphertext: Data
        public let tag: Data
        public let tokenIDBytes: Data
    }

    // MARK: - Primitives

    public static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func tagMatches(_ tag: Data, message: Data, key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message,
                                               using: SymmetricKey(data: key))
    }

    /// PRF-CTR: keystream_i = HMAC-SHA256(key, nonce || be32(i)).
    public static func keystreamXOR(key: Data, nonce: Data, data: Data) -> Data {
        var output = Data(count: data.count)
        let dataBytes = [UInt8](data)
        var offset = 0
        var counter: UInt32 = 0
        while offset < dataBytes.count {
            var be = counter.bigEndian
            let counterBytes = Data(bytes: &be, count: 4)
            let block = hmac(key, nonce + counterBytes)
            let blockBytes = [UInt8](block)
            let end = min(dataBytes.count, offset + blockBytes.count)
            for index in offset..<end {
                output[index] = dataBytes[index] ^ blockBytes[index - offset]
            }
            offset = end
            counter &+= 1
        }
        return output
    }

    public static func be64(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }

    /// The non-secret lookup handle: first 4 bytes of SHA-256(K), lowercase hex.
    public static func tokenId(for key: Data) -> String {
        hexLowercase(Data(SHA256.hash(data: key)).prefix(4))
    }

    public static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    public static func hexLowercase(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Strict lowercase hex with an exact byte count. Uppercase, odd lengths and
    /// non-hex characters are rejected rather than normalized.
    public static func strictHex(_ value: String, byteCount: Int) -> Data? {
        guard value.count == byteCount * 2, value == value.lowercased() else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - Envelope shape

    public static func looksLikeEnvelope(_ object: [String: Any]) -> Bool {
        (object["v"] as? Int) == 1 && object["tok"] is String && object["ct"] is String
    }

    public static func parse(_ object: [String: Any],
                             limits: BridgeLANLimits = .default) throws -> ParsedEnvelope {
        guard let tokId = object["tok"] as? String,
              let timestamp = integer(object["ts"]), timestamp >= 0,
              let nonceHex = object["nonce"] as? String,
              let ciphertextB64 = object["ct"] as? String,
              let tagHex = object["tag"] as? String,
              let nonce = strictHex(nonceHex, byteCount: nonceByteCount),
              let tokenIDBytes = strictHex(tokId, byteCount: 4),
              let tag = strictHex(tagHex, byteCount: tagByteCount) else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope fields")
        }
        guard tokId.count == 8, nonceHex.count == 32, tagHex.count == 64 else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope fields")
        }
        guard ciphertextB64.utf8.count <= limits.maxCiphertextBytes * 2,
              let ciphertext = Data(base64Encoded: ciphertextB64, options: []),
              ciphertext.count <= limits.maxCiphertextBytes,
              ciphertext.base64EncodedString() == ciphertextB64 else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope body")
        }
        return ParsedEnvelope(
            tokId: tokId,
            timestamp: timestamp,
            nonceHex: nonceHex,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            tokenIDBytes: tokenIDBytes
        )
    }

    // MARK: - Open / seal

    /// Verifies the tag before decrypting. A bad tag never yields plaintext and
    /// never consumes a replay slot.
    public static func open(_ parsed: ParsedEnvelope, key: Data) throws -> Data {
        guard key.count == keyByteCount else {
            throw Failure(code: "auth_failed", message: "Authentication failed.")
        }
        let kMac = hmac(key, Data(labelMac.utf8) + parsed.nonce)
        let signed = Data("v1".utf8) + parsed.tokenIDBytes
            + be64(UInt64(parsed.timestamp)) + parsed.nonce + parsed.ciphertext
        guard tagMatches(parsed.tag, message: signed, key: kMac) else {
            throw Failure(code: "auth_failed", message: "Authentication failed.")
        }
        let kEncRequest = hmac(key, Data(labelEncRequest.utf8) + parsed.nonce)
        return keystreamXOR(key: kEncRequest, nonce: parsed.nonce, data: parsed.ciphertext)
    }

    /// Encrypts a response under the same nonce with the response-direction key.
    public static func sealResponse(_ plaintext: Data,
                                    key: Data,
                                    nonce: Data,
                                    nonceHex: String) -> Data {
        let kMac = hmac(key, Data(labelMac.utf8) + nonce)
        let kEncResponse = hmac(key, Data(labelEncResponse.utf8) + nonce)
        let ciphertext = keystreamXOR(key: kEncResponse, nonce: nonce, data: plaintext)
        let tag = hmac(kMac, Data("resp".utf8) + nonce + ciphertext)
        let envelope: [String: Any] = [
            "v": 1,
            "nonce": nonceHex,
            "ct": ciphertext.base64EncodedString(),
            "tag": hexLowercase(tag),
        ]
        return (try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
    }

    /// Request-direction sealer used by the host qualification and the reference
    /// controller. Production host code only opens requests.
    public static func sealRequest(_ plaintext: Data,
                                   key: Data,
                                   nonce: Data,
                                   timestamp: Int) -> [String: Any] {
        let tokenID = Data(SHA256.hash(data: key)).prefix(4)
        let nonceHex = hexLowercase(nonce)
        let kMac = hmac(key, Data(labelMac.utf8) + nonce)
        let kEncRequest = hmac(key, Data(labelEncRequest.utf8) + nonce)
        let ciphertext = keystreamXOR(key: kEncRequest, nonce: nonce, data: plaintext)
        let tag = hmac(kMac, Data("v1".utf8) + tokenID
            + be64(UInt64(timestamp)) + nonce + ciphertext)
        return [
            "v": 1,
            "tok": hexLowercase(tokenID),
            "ts": timestamp,
            "nonce": nonceHex,
            "ct": ciphertext.base64EncodedString(),
            "tag": hexLowercase(tag),
        ]
    }

    /// Verifies and decrypts a response envelope. Used by the reference
    /// controller checks; it follows the same tag construction as upstream.
    public static func openResponse(_ object: [String: Any],
                                    key: Data,
                                    expectedNonceHex: String) throws -> Data {
        guard integer(object["v"]) == 1,
              let nonceHex = object["nonce"] as? String,
              nonceHex == expectedNonceHex,
              let ciphertextB64 = object["ct"] as? String,
              let tagHex = object["tag"] as? String,
              let nonce = strictHex(nonceHex, byteCount: nonceByteCount),
              let ciphertext = Data(base64Encoded: ciphertextB64, options: []),
              let tag = strictHex(tagHex, byteCount: tagByteCount) else {
            throw Failure(code: "bad_response", message: "Malformed response envelope")
        }
        let kMac = hmac(key, Data(labelMac.utf8) + nonce)
        guard tagMatches(tag, message: Data("resp".utf8) + nonce + ciphertext, key: kMac) else {
            throw Failure(code: "bad_response", message: "Response authentication failed.")
        }
        let kEncResponse = hmac(key, Data(labelEncResponse.utf8) + nonce)
        return keystreamXOR(key: kEncResponse, nonce: nonce, data: ciphertext)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        let int64 = number.int64Value
        guard int64 >= 0, int64 <= Int64(Int32.max) else { return nil }
        return Int(int64)
    }
}

/// Canonical 32-byte control-key encoding. This is deliberately a separate
/// type from the legacy install/read-only token; the two derivations never
/// share material.
public enum BridgeLANControlKey {
    public static let byteCount = 32
    public static let canonicalLength = 43

    public static func isCanonical(_ value: String) -> Bool {
        decode(value) != nil
    }

    public static func decode(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count == canonicalLength else { return nil }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F:
                continue
            default:
                return nil
            }
        }
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded, options: []),
              data.count == byteCount else {
            return nil
        }
        return encode(data) == value ? data : nil
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fingerprint(_ key: Data) -> String {
        BridgeLANCrypto.tokenId(for: key)
    }
}
