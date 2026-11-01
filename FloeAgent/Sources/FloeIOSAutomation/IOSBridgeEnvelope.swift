// FloeIOSAutomation — wire-compatible v1 envelope primitives for the released
// Floe iOS Bridge (source commit 3aed149658b83637b8085557c2c86275c7c585e3).
//
// The construction is fixed by the shipped v1 clients:
//
//     K          = 32-byte pairing key
//     tok        = first 4 bytes of SHA-256(K), 8 lowercase hex characters
//     nonce      = 16 random bytes per request, never reused
//     ts         = unix seconds, accepted within +/-120 s
//     K_enc_req  = HMAC(K, "ictrl-v1|enc-req"  || nonce)
//     K_enc_resp = HMAC(K, "ictrl-v1|enc-resp" || nonce)
//     K_mac      = HMAC(K, "ictrl-v1|mac"      || nonce)
//     keystream  = HMAC(Kx, nonce || be32(0)) || HMAC(Kx, nonce || be32(1)) ...
//     ct         = plaintext XOR keystream(K_enc_req)
//     tag        = HMAC(K_mac, "v1" || tok_4B || be64(ts) || nonce || ct)
//
// Responses are sealed under the same nonce with the response direction and
// tagged over "resp" || nonce || ct. X25519 is used only during pairing:
//
//     kWrap    = HMAC(shared, "ictrl-pair" || clientPub || devicePub)
//     pad      = HMAC(kWrap, "ictrl-wrap")
//     token_ct = K XOR pad
//
// This is a PRF counter keystream, not AES-GCM. Do not replace it with a new
// construction without versioning the wire protocol.

import CryptoKit
import Foundation

public enum IOSBridgeEnvelope {
    public static let labelMac = "ictrl-v1|mac"
    public static let labelEncRequest = "ictrl-v1|enc-req"
    public static let labelEncResponse = "ictrl-v1|enc-resp"
    public static let labelPair = "ictrl-pair"
    public static let labelWrap = "ictrl-wrap"

    public static let keyByteCount = 32
    public static let nonceByteCount = 16
    public static let tagByteCount = 32
    public static let tokenIDByteCount = 4

    public struct Failure: Error, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct ParsedRequest: Sendable, Equatable {
        public let tokenID: String
        public let timestamp: Int
        public let nonceHex: String
        public let nonce: Data
        public let ciphertext: Data
        public let tag: Data
        public let tokenIDBytes: Data
    }

    // MARK: - Primitive helpers

    public static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Constant-time comparison through CryptoKit's authentication validator.
    public static func tagMatches(_ tag: Data, message: Data, key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            tag,
            authenticating: message,
            using: SymmetricKey(data: key)
        )
    }

    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    /// PRF-CTR keystream XOR. The counter is a big-endian UInt32 and the
    /// keystream is consumed in HMAC blocks.
    public static func keystreamXOR(key: Data, nonce: Data, data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        let input = [UInt8](data)
        var offset = 0
        var counter: UInt32 = 0
        while offset < input.count {
            var bigEndian = counter.bigEndian
            let counterBytes = Data(bytes: &bigEndian, count: 4)
            let block = [UInt8](hmac(key, nonce + counterBytes))
            let end = min(input.count, offset + block.count)
            for index in offset..<end {
                output[index] = input[index] ^ block[index - offset]
            }
            offset = end
            counter &+= 1
        }
        return output
    }

    public static func be64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 8)
    }

    public static func tokenID(for key: Data) -> String {
        hexLowercase(sha256(key).prefix(tokenIDByteCount))
    }

    public static func fingerprint(publicKey: Data) -> String {
        hexLowercase(sha256(publicKey).prefix(4))
    }

    public static func randomBytes(_ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }

    public static func hexLowercase(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexLowercase<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Strict lowercase hex. Uppercase, odd lengths and non-hex characters are
    /// rejected rather than normalized.
    public static func strictHex(_ value: String, byteCount: Int) -> Data? {
        guard byteCount >= 0,
              value.count == byteCount * 2,
              value == value.lowercased() else {
            return nil
        }
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

    // MARK: - Request parse / open (reference and fixture support)

    /// Parses a request envelope without authenticating it. Production client
    /// code only seals requests; this is exposed to the test target and to
    /// fixture implementations that must stand in for the Bridge host.
    static func parseRequest(
        _ value: IOSBridgeJSONValue,
        maxCiphertextBytes: Int = IOSBridgeProtocol.maxRequestBodyBytes
    ) throws -> ParsedRequest {
        guard let object = value.objectValue,
              object["v"] == .int(1),
              let tokenID = object["tok"]?.stringValue,
              let timestamp = object["ts"]?.intValue, timestamp >= 0,
              let nonceHex = object["nonce"]?.stringValue,
              let ciphertextBase64 = object["ct"]?.stringValue,
              let tagHex = object["tag"]?.stringValue,
              let nonce = strictHex(nonceHex, byteCount: nonceByteCount),
              let tokenIDBytes = strictHex(tokenID, byteCount: tokenIDByteCount),
              let tag = strictHex(tagHex, byteCount: tagByteCount) else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope fields")
        }
        guard tokenID.count == tokenIDByteCount * 2,
              nonceHex.count == nonceByteCount * 2,
              tagHex.count == tagByteCount * 2 else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope fields")
        }
        guard ciphertextBase64.utf8.count <= maxCiphertextBytes * 2,
              let ciphertext = Data(base64Encoded: ciphertextBase64, options: []),
              ciphertext.base64EncodedString() == ciphertextBase64,
              ciphertext.count <= maxCiphertextBytes else {
            throw Failure(code: "bad_envelope", message: "Malformed envelope body")
        }
        return ParsedRequest(
            tokenID: tokenID,
            timestamp: timestamp,
            nonceHex: nonceHex,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            tokenIDBytes: tokenIDBytes
        )
    }

    /// Opens and authenticates a request envelope. Used by contract fixtures;
    /// the Floe client never acts as a Bridge host.
    static func openRequest(
        _ value: IOSBridgeJSONValue,
        key: Data,
        maxCiphertextBytes: Int = IOSBridgeProtocol.maxRequestBodyBytes
    ) throws -> (plaintext: Data, parsed: ParsedRequest) {
        let parsed = try parseRequest(value, maxCiphertextBytes: maxCiphertextBytes)
        guard key.count == keyByteCount else {
            throw Failure(code: "auth_failed", message: authFailureMessage)
        }
        let keyMAC = hmac(key, Data(labelMac.utf8) + parsed.nonce)
        let signed = Data("v1".utf8) + parsed.tokenIDBytes
            + be64(UInt64(parsed.timestamp)) + parsed.nonce + parsed.ciphertext
        guard tagMatches(parsed.tag, message: signed, key: keyMAC) else {
            throw Failure(code: "auth_failed", message: authFailureMessage)
        }
        let keyEncryptionRequest = hmac(key, Data(labelEncRequest.utf8) + parsed.nonce)
        let plaintext = keystreamXOR(
            key: keyEncryptionRequest,
            nonce: parsed.nonce,
            data: parsed.ciphertext
        )
        return (plaintext, parsed)
    }

    // MARK: - Client seal / open

    /// Seals one JSON-RPC request body for the given key and nonce.
    public static func sealRequest(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        timestamp: Int
    ) throws -> IOSBridgeJSONValue {
        guard key.count == keyByteCount, nonce.count == nonceByteCount, timestamp >= 0 else {
            throw Failure(code: "bad_request", message: "Invalid request envelope parameters")
        }
        let tokenIDBytes = sha256(key).prefix(tokenIDByteCount)
        let nonceHex = hexLowercase(nonce)
        let keyMAC = hmac(key, Data(labelMac.utf8) + nonce)
        let keyEncryptionRequest = hmac(key, Data(labelEncRequest.utf8) + nonce)
        let ciphertext = keystreamXOR(
            key: keyEncryptionRequest,
            nonce: nonce,
            data: plaintext
        )
        let tag = hmac(
            keyMAC,
            Data("v1".utf8) + tokenIDBytes
                + be64(UInt64(timestamp)) + nonce + ciphertext
        )
        return .object([
            "v": .int(1),
            "tok": .string(hexLowercase(tokenIDBytes)),
            "ts": .int(timestamp),
            "nonce": .string(nonceHex),
            "ct": .string(ciphertext.base64EncodedString()),
            "tag": .string(hexLowercase(tag)),
        ])
    }

    /// Verifies a response envelope under the request nonce. A bad tag never
    /// yields plaintext. The nonce must match exactly; otherwise a valid
    /// response from another request cannot be replayed into this call.
    public static func openResponse(
        _ value: IOSBridgeJSONValue,
        key: Data,
        expectedNonceHex: String,
        maxCiphertextBytes: Int = IOSBridgeProtocol.maxJSONResponseBytes
    ) throws -> Data {
        guard let object = value.objectValue,
              object["v"] == .int(1),
              let nonceHex = object["nonce"]?.stringValue,
              nonceHex == expectedNonceHex,
              let ciphertextBase64 = object["ct"]?.stringValue,
              let tagHex = object["tag"]?.stringValue,
              let nonce = strictHex(nonceHex, byteCount: nonceByteCount),
              let ciphertext = Data(base64Encoded: ciphertextBase64, options: []),
              ciphertext.base64EncodedString() == ciphertextBase64,
              ciphertext.count <= maxCiphertextBytes,
              let tag = strictHex(tagHex, byteCount: tagByteCount) else {
            throw Failure(code: "bad_response", message: "Malformed response envelope")
        }
        guard key.count == keyByteCount else {
            throw Failure(code: "bad_response", message: "Response authentication failed.")
        }
        let keyMAC = hmac(key, Data(labelMac.utf8) + nonce)
        guard tagMatches(tag, message: Data("resp".utf8) + nonce + ciphertext, key: keyMAC) else {
            throw Failure(code: "bad_response", message: "Response authentication failed.")
        }
        let keyEncryptionResponse = hmac(key, Data(labelEncResponse.utf8) + nonce)
        return keystreamXOR(
            key: keyEncryptionResponse,
            nonce: nonce,
            data: ciphertext
        )
    }

    /// Reference response sealer used by contract fixtures and tests. The
    /// shipping client never seals responses.
    static func sealResponse(
        _ plaintext: Data,
        key: Data,
        nonce: Data
    ) throws -> IOSBridgeJSONValue {
        guard key.count == keyByteCount, nonce.count == nonceByteCount else {
            throw Failure(code: "bad_request", message: "Invalid response envelope parameters")
        }
        let nonceHex = hexLowercase(nonce)
        let keyMAC = hmac(key, Data(labelMac.utf8) + nonce)
        let keyEncryptionResponse = hmac(key, Data(labelEncResponse.utf8) + nonce)
        let ciphertext = keystreamXOR(
            key: keyEncryptionResponse,
            nonce: nonce,
            data: plaintext
        )
        let tag = hmac(keyMAC, Data("resp".utf8) + nonce + ciphertext)
        return .object([
            "v": .int(1),
            "nonce": .string(nonceHex),
            "ct": .string(ciphertext.base64EncodedString()),
            "tag": .string(hexLowercase(tag)),
        ])
    }

    // MARK: - X25519 pairing unwrap

    /// Client-side unwrap of the X25519-wrapped pairing key.
    public static func unwrapKey(
        tokenCiphertext: Data,
        sharedSecret: Data,
        clientPublicKey: Data,
        devicePublicKey: Data
    ) -> Data? {
        guard tokenCiphertext.count == keyByteCount else { return nil }
        let wrapKey = deriveWrapKey(
            sharedSecret: sharedSecret,
            clientPublicKey: clientPublicKey,
            devicePublicKey: devicePublicKey
        )
        let pad = hmac(wrapKey, Data(labelWrap.utf8))
        return Data(zip(tokenCiphertext, pad).map { $0 ^ $1 })
    }

    public static func deriveWrapKey(
        sharedSecret: Data,
        clientPublicKey: Data,
        devicePublicKey: Data
    ) -> Data {
        hmac(sharedSecret, Data(labelPair.utf8) + clientPublicKey + devicePublicKey)
    }

    public static let authFailureMessage =
        "Authentication failed. This key is not usable; pair again with owner approval. "
        + "A key is dropped after 30 days without a successful call."
}
