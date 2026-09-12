import Foundation
import Crypto
import CryptoKit
import Security
import FloeCore

/// Compact OpenPGP implementation covering the verification surface Debian
/// repositories require: v4/v5/v6 public keys, v4/v6 signatures, RSA
/// (PKCS#1 v1.5), Ed25519 and ECDSA P-256/P-384, armored and binary
/// keyrings, clearsigned `InRelease` and detached `Release.gpg`.
public enum OpenPGP {
    // MARK: - Packet framing

    public struct RawPacket: Sendable {
        public var tag: Int
        public var body: Data
    }

    public static func packets(in data: Data) throws -> [RawPacket] {
        var packets: [RawPacket] = []
        var offset = 0
        while offset < data.count {
            let first = data[offset]
            guard first & 0x80 != 0 else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
            let isNewFormat = first & 0x40 != 0
            let tag: Int
            var bodyLength: Int
            if isNewFormat {
                tag = Int(first & 0x3F)
                offset += 1
                guard offset < data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                let lengthByte = data[offset]
                offset += 1
                if lengthByte < 192 {
                    bodyLength = Int(lengthByte)
                } else if lengthByte < 224 {
                    guard offset < data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                    bodyLength = ((Int(lengthByte) - 192) << 8) + Int(data[offset]) + 192
                    offset += 1
                } else if lengthByte == 255 {
                    guard offset + 4 <= data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                    bodyLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                    offset += 4
                } else {
                    // Partial body lengths are not used in key/signature
                    // packets we consume; skip the remainder defensively.
                    throw FloeError.validationFailed("Partial OpenPGP packets are unsupported")
                }
            } else {
                tag = Int((first >> 2) & 0x0F)
                let lengthType = Int(first & 0x03)
                offset += 1
                switch lengthType {
                case 0:
                    guard offset < data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                    bodyLength = Int(data[offset])
                    offset += 1
                case 1:
                    guard offset + 2 <= data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                    bodyLength = Int(data[offset]) << 8 | Int(data[offset + 1])
                    offset += 2
                case 2:
                    guard offset + 4 <= data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
                    bodyLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                    offset += 4
                default:
                    bodyLength = data.count - offset
                }
            }
            guard bodyLength >= 0, offset + bodyLength <= data.count else { throw FloeError.validationFailed("Malformed OpenPGP packet") }
            packets.append(RawPacket(tag: tag, body: data.subdata(in: offset..<(offset + bodyLength))))
            offset += bodyLength
        }
        return packets
    }

    // MARK: - Public keys

    public struct PublicKey: Sendable {
        public var version: Int
        public var algorithm: Int
        public var creationTime: Date?
        public var fingerprint: String
        public var keyID: String
        public var isSubkey: Bool
        public var canSign: Bool
        public var rsaModulus: Data?
        public var rsaExponent: Int?
        public var ed25519Point: Data?
        public var ecPointData: Data?
        public var ecCurveOID: [UInt8]?
        public var expiresAt: Date?
        public var revoked: Bool

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() > expiresAt
        }
    }

    public static func parsePublicKey(_ body: Data, isSubkey: Bool = false) throws -> PublicKey {
        var reader = Reader(body)
        let version = try reader.byte()
        let creationTime = Date(timeIntervalSince1970: TimeInterval(try reader.uint32()))
        let algorithm = try reader.byte()
        var rsaModulus: Data?
        var rsaExponent: Int?
        var ed25519Point: Data?
        var ecPointData: Data?
        var ecCurveOID: [UInt8]?
        switch algorithm {
        case 1, 2, 3: // RSA
            rsaModulus = try mpi(&reader)
            let exponent = try mpi(&reader)
            rsaExponent = exponent.isEmpty ? 65537 : Int(exponent.reduce(0) { ($0 << 8) | Int($1) })
        case 22: // EdDSA legacy
            // OID length + OID (Ed25519: 2B 06 01 04 01 DA 47 0F 01)
            let oidLength = try reader.byte()
            ecCurveOID = Array(try reader.bytes(count: Int(oidLength)))
            let point = try mpi(&reader)
            guard ecCurveOID == [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01], point.count == 33, point.first == 0x40 else {
                throw FloeError.validationFailed("Unsupported OpenPGP EdDSA key")
            }
            ed25519Point = Data(point.dropFirst())
        case 19: // ECDSA
            let oidLength = try reader.byte()
            ecCurveOID = Array(try reader.bytes(count: Int(oidLength)))
            ecPointData = try mpi(&reader)
        default:
            break
        }
        let fingerprintData = body.prefix(reader.offset)
        let fingerprint: String
        if version >= 5 {
            var material = Data([0x9A])
            material.append(contentsOf: UInt32(body.count).bigEndianBytes)
            material.append(body)
            fingerprint = SHA256.hash(data: material).hexString
        } else {
            var material = Data([0x99])
            material.append(contentsOf: UInt16(body.count).bigEndianBytes)
            material.append(body)
            fingerprint = Insecure.SHA1.hash(data: material).hexString
        }
        return PublicKey(
            version: Int(version),
            algorithm: Int(algorithm),
            creationTime: creationTime,
            fingerprint: fingerprint,
            keyID: String(fingerprint.suffix(16)).uppercased(),
            isSubkey: isSubkey,
            canSign: [1, 3, 22, 19].contains(Int(algorithm)),
            rsaModulus: rsaModulus,
            rsaExponent: rsaExponent,
            ed25519Point: ed25519Point,
            ecPointData: ecPointData,
            ecCurveOID: ecCurveOID,
            revoked: false
        )
    }

    private static func mpi(_ reader: inout Reader) throws -> Data {
        let bitCount = try reader.uint16()
        let byteCount = Int((Int(bitCount) + 7) / 8)
        return try reader.bytes(count: byteCount)
    }

    // MARK: - Signatures

    public struct Signature: Sendable {
        public var version: Int
        public var signatureType: Int
        public var publicKeyAlgorithm: Int
        public var hashAlgorithm: Int
        public var hashedPortion: Data
        public var unhashedPortion: Data
        public var issuerKeyID: String?
        public var issuerFingerprint: String?
        public var signatureMaterial: Data
        public var creationTime: Date?
    }

    public static func parseSignature(_ body: Data) throws -> Signature {
        var reader = Reader(body)
        let version = try reader.byte()
        guard version == 4 else {
            throw FloeError.validationFailed("unsupported signature version \(version)")
        }
        var signatureType: UInt8 = 0
        var publicKeyAlgorithm: UInt8 = 0
        var hashAlgorithm: UInt8 = 0
        if version == 4 {
            signatureType = try reader.byte()
            publicKeyAlgorithm = try reader.byte()
            hashAlgorithm = try reader.byte()
        } else {
            signatureType = try reader.byte()
            publicKeyAlgorithm = try reader.byte()
            hashAlgorithm = try reader.byte()
        }
        let hashedLength = Int(try reader.uint16())
        let hashedStart = reader.offset
        _ = try reader.bytes(count: hashedLength)
        // The hashed portion starts at the version octet (RFC 4880 §5.2.4).
        let hashedPortion = body.subdata(in: 0..<(hashedStart + hashedLength))
        let unhashedLength = Int(try reader.uint16())
        let unhashedPortion = try reader.bytes(count: unhashedLength)
        let left16 = try reader.bytes(count: 2)
        let material = try reader.rest()
        var issuer: String?
        var fingerprint: String?
        var creation: Date?
        parseSubpackets(hashedPortion.dropFirst(hashedStart), issuer: &issuer, fingerprint: &fingerprint, creation: &creation)
        _ = left16
        return Signature(
            version: Int(version),
            signatureType: Int(signatureType),
            publicKeyAlgorithm: Int(publicKeyAlgorithm),
            hashAlgorithm: Int(hashAlgorithm),
            hashedPortion: Data(hashedPortion),
            unhashedPortion: unhashedPortion,
            issuerKeyID: issuer,
            issuerFingerprint: fingerprint,
            signatureMaterial: material,
            creationTime: creation
        )
    }

    /// Walks signature subpackets inside the hashed portion.
    private static func parseSubpackets(
        _ data: Data,
        issuer: inout String?,
        fingerprint: inout String?,
        creation: inout Date?
    ) {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let lengthByte = bytes[offset]
            offset += 1
            var length = 0
            if lengthByte < 192 {
                length = Int(lengthByte)
            } else if lengthByte < 255 {
                guard offset < bytes.count else { return }
                length = ((Int(lengthByte) - 192) << 8) + Int(bytes[offset]) + 192
                offset += 1
            } else {
                guard offset + 4 <= bytes.count else { return }
                length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
            }
            guard length > 1, offset + length <= bytes.count else { return }
            let type = bytes[offset] & 0x7F
            let subpacket = Data(bytes[(offset + 1)..<(offset + length)])
            offset += length
            switch type {
            case 2: // signature creation time
                if subpacket.count >= 4 {
                    let seconds = subpacket.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
                    creation = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            case 16: // issuer key ID
                issuer = subpacket.map { String(format: "%02X", $0) }.joined()
            case 33: // issuer fingerprint
                if subpacket.count > 1 {
                    fingerprint = subpacket.dropFirst().map { String(format: "%02X", $0) }.joined()
                    issuer = String((fingerprint ?? "").suffix(16))
                }
            default:
                break
            }
        }
    }

    // MARK: - Keyrings

    public struct Key: Sendable {
        public var primary: PublicKey
        public var subkeys: [PublicKey]
        public var userIDs: [String]
        public var revoked: Bool

        public var signingKey: PublicKey? {
            if primary.canSign, !primary.isExpired { return primary }
            return subkeys.first { $0.canSign && !$0.isExpired }
        }
    }

    public static func parseKeyring(_ data: Data) throws -> [Key] {
        let decoded = try decodeIfArmored(data)
        let packets = try packets(in: decoded)
        var keys: [Key] = []
        var currentPrimary: PublicKey?
        var currentSubkeys: [PublicKey] = []
        var currentUserIDs: [String] = []
        var revoked = false
        func flush() {
            if let primary = currentPrimary {
                keys.append(Key(primary: primary, subkeys: currentSubkeys, userIDs: currentUserIDs, revoked: revoked))
            }
            currentPrimary = nil
            currentSubkeys = []
            currentUserIDs = []
            revoked = false
        }
        for packet in packets {
            switch packet.tag {
            case 6: // public key
                flush()
                currentPrimary = try? parsePublicKey(packet.body)
            case 14: // public subkey
                if let subkey = try? parsePublicKey(packet.body, isSubkey: true) {
                    currentSubkeys.append(subkey)
                }
            case 13: // user ID
                if let text = String(data: packet.body, encoding: .utf8) {
                    currentUserIDs.append(text)
                }
            case 2: // signature packet
                if let signature = try? parseSignature(packet.body), signature.signatureType == 0x20 {
                    revoked = true
                }
            default:
                break
            }
        }
        flush()
        return keys
    }

    public static func armoredKeys(in directory: URL) -> [Key] {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var keys: [Key] = []
        for file in files where ["gpg", "asc", "key"].contains(file.pathExtension.lowercased()) {
            guard let data = try? Data(floeContentsOf: file) else { continue }
            keys.append(contentsOf: (try? parseKeyring(data)) ?? [])
        }
        return keys
    }

    // MARK: - Armor and clearsign

    public struct ClearsignedDocument: Sendable {
        public var text: Data
        public var signaturePacket: Data
    }

    public static func decodeIfArmored(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN PGP") else {
            return data
        }
        var inBody = false
        var base64 = ""
        var crcLine: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN PGP") { inBody = true; continue }
            if trimmed.hasPrefix("-----END PGP") { break }
            if trimmed.hasPrefix("=") { crcLine = String(trimmed.dropFirst()); continue }
            if inBody {
                if trimmed.isEmpty && base64.isEmpty { continue }
                base64 += trimmed
            }
        }
        _ = crcLine
        guard let decoded = Data(base64Encoded: base64) else {
            throw FloeError.validationFailed("invalid armored payload")
        }
        return decoded
    }

    public static func parseClearsigned(_ data: Data) throws -> ClearsignedDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FloeError.validationFailed("clearsigned document is not UTF-8")
        }
        var payloadLines: [String] = []
        var signatureBase64 = ""
        var inSignature = false
        var inPayload = false
        var payloadHeaders = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("-----BEGIN PGP SIGNED MESSAGE-----") { payloadHeaders = true; continue }
            if line.hasPrefix("-----BEGIN PGP SIGNATURE-----") { inSignature = true; inPayload = false; continue }
            if line.hasPrefix("-----END PGP SIGNATURE-----") { inSignature = false; continue }
            if payloadHeaders {
                if line.isEmpty { payloadHeaders = false; inPayload = true }
                continue
            }
            if inSignature {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("=") || trimmed.contains(":") { continue }
                signatureBase64 += trimmed
                continue
            }
            if inPayload {
                // Ignore the armor headers (Hash:) that precede the payload.
                // Dash-unescape per RFC 4880 §7.1.
                var content = line
                if content.hasPrefix("- ") { content.removeFirst(2) }
                while content.last == " " || content.last == "\t" { content.removeLast() }
                payloadLines.append(content)
            }
        }
        while let last = payloadLines.last, last.isEmpty { payloadLines.removeLast() }
        let canonical = payloadLines.map { $0.replacingOccurrences(of: "\r\n", with: "\n") }
            .joined(separator: "\n")
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            throw FloeError.validationFailed("invalid clearsigned signature payload")
        }
        guard let signaturePacket = try packets(in: signatureData).first(where: { $0.tag == 2 }) else {
            throw FloeError.validationFailed("no signature packet in clearsigned document")
        }
        return ClearsignedDocument(
            text: Data(canonical.utf8),
            signaturePacket: signaturePacket.body
        )
    }

    // MARK: - Verification

    public enum VerifyError: Error, CustomStringConvertible {
        case noKey(String)
        case unsupportedAlgorithm(Int)
        case invalidSignature
        case hashAlgorithm(Int)

        public var description: String {
            switch self {
            case .noKey(let id): return "no trusted key for \(id)"
            case .unsupportedAlgorithm(let id): return "unsupported key algorithm \(id)"
            case .invalidSignature: return "signature verification failed"
            case .hashAlgorithm(let id): return "unsupported hash algorithm \(id)"
            }
        }
    }

    /// Verifies a signature over `data`. `data` is the exact signed payload;
    /// for clearsigned documents pass the dash-unescaped canonical text.
    public static func verify(signaturePacketBody: Data, over data: Data, keys: [Key]) throws {
        let signature = try parseSignature(signaturePacketBody)
        let issuer = signature.issuerKeyID ?? signature.issuerFingerprint.map { String($0.suffix(16)) }
        let candidateKeys = keys.compactMap { key -> PublicKey? in
            let candidates = [key.primary] + key.subkeys
            if let issuer {
                return candidates.first {
                    $0.keyID == issuer || $0.fingerprint.hasSuffix(issuer.uppercased())
                }
            }
            return key.signingKey
        }
        guard !candidateKeys.isEmpty else {
            throw VerifyError.noKey(issuer ?? "unknown")
        }
        for key in candidateKeys where !key.isExpired && !key.revoked {
            if try verify(signature: signature, over: data, key: key) { return }
        }
        throw VerifyError.invalidSignature
    }

    private static func verify(signature: Signature, over data: Data, key: PublicKey) throws -> Bool {
        guard signature.publicKeyAlgorithm == key.algorithm || ([1, 3].contains(signature.publicKeyAlgorithm) && [1, 3].contains(key.algorithm)),
              [0, 1].contains(signature.signatureType) else { return false }
        let digest = try digestForSignature(signature, over: data, key: key)
        switch key.algorithm {
        case 1, 2, 3:
            guard let modulus = key.rsaModulus, let exponent = key.rsaExponent else { return false }
            var der = Data()
            der.append(0x30)
            let parts = rsaKeyParts(modulus: modulus, exponent: exponent)
            der.append(contentsOf: lengthBytes(parts.count))
            der.append(contentsOf: parts)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: modulus.count * 8
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
                return false
            }
            let algorithm: SecKeyAlgorithm = signature.hashAlgorithm == 8 ? .rsaSignatureDigestPKCS1v15SHA256
                : signature.hashAlgorithm == 9 ? .rsaSignatureDigestPKCS1v15SHA384
                : .rsaSignatureDigestPKCS1v15SHA512
            var signatureReader = Reader(signature.signatureMaterial)
            let rsaSignature = normalizedRSASignature(try mpi(&signatureReader), modulusSize: modulus.count)
            return SecKeyVerifySignature(secKey, algorithm, digest as CFData, rsaSignature as CFData, &error)
        case 22:
            guard let point = key.ed25519Point, point.count == 32 else { return false }
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: point) else { return false }
            let rawSignature = try ed25519Signature(from: signature.signatureMaterial)
            return publicKey.isValidSignature(rawSignature, for: digest)
        case 19:
            guard let point = key.ecPointData, let oid = key.ecCurveOID else { return false }
            let keyType: CFString = oid.last == 0x08 ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeECSECPrimeRandom
            var uncompressed = Data([0x04])
            if point.count == 65 || point.count == 97 { uncompressed = point }
            else { uncompressed.append(point) }
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: keyType,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(uncompressed as CFData, attributes as CFDictionary, &error) else {
                return false
            }
            guard let derSignature = ecdsaDER(from: signature.signatureMaterial) else { return false }
            let algorithm: SecKeyAlgorithm = oid.last == 0x08
                ? (signature.hashAlgorithm == 8 ? .ecdsaSignatureDigestX962SHA256 : .ecdsaSignatureDigestX962SHA384)
                : (signature.hashAlgorithm == 8 ? .ecdsaSignatureDigestX962SHA256 : .ecdsaSignatureDigestX962SHA384)
            return SecKeyVerifySignature(secKey, algorithm, digest as CFData, derSignature as CFData, &error)
        default:
            throw VerifyError.unsupportedAlgorithm(key.algorithm)
        }
    }

    /// Builds the OpenPGP hash: data || hashed portion || v4 trailer.
    private static func digestForSignature(_ signature: Signature, over data: Data, key: PublicKey) throws -> Data {
        var material = data
        if signature.signatureType == 1 {
            guard let text = String(data: data, encoding: .utf8) else { throw VerifyError.invalidSignature }
            material = Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
        }
        // hashedPortion already includes version/algos/length prefix.
        material.append(signature.hashedPortion)
        let trailerLength = signature.hashedPortion.count
        if signature.version == 4 {
            material.append(contentsOf: [0x04, 0xFF])
            material.append(contentsOf: UInt32(trailerLength).bigEndianBytes)
        } else {
            material.append(contentsOf: [UInt8(signature.version), 0xFF])
            material.append(contentsOf: UInt64(trailerLength).bigEndianBytes)
        }
        switch signature.hashAlgorithm {
        case 8: return Data(SHA256.hash(data: material))
        case 9: return Data(SHA384.hash(data: material))
        case 10: return Data(SHA512.hash(data: material))
        default: throw VerifyError.hashAlgorithm(signature.hashAlgorithm)
        }
    }

    private static func normalizedRSASignature(_ material: Data, modulusSize: Int) -> Data {
        var value = material
        while value.first == 0x00, value.count > modulusSize { value.removeFirst() }
        if value.count < modulusSize {
            value = Data(repeating: 0, count: modulusSize - value.count) + value
        }
        return value
    }

    /// Converts OpenPGP EdDSA (two MPIs) to the 64-byte Ed25519 form.
    private static func ed25519Signature(from material: Data) throws -> Data {
        var reader = Reader(material)
        let r = try mpi(&reader)
        let s = try mpi(&reader)
        func padded(_ data: Data) -> Data {
            if data.count >= 32 { return data.suffix(32) }
            return Data(repeating: 0, count: 32 - data.count) + data
        }
        return padded(r) + padded(s)
    }

    private static func ecdsaDER(from material: Data) -> Data? {
        guard var reader = try? Reader(material) else { return nil }
        guard let r = try? mpi(&reader), let s = try? mpi(&reader) else { return nil }
        func integer(_ data: Data) -> Data {
            var value = data
            while value.first == 0x00, value.count > 1 { value.removeFirst() }
            if let first = value.first, first & 0x80 != 0 {
                value = Data([0x00]) + value
            }
            return value
        }
        let rEncoded = integer(r)
        let sEncoded = integer(s)
        var der = Data()
        der.append(0x02)
        der.append(contentsOf: lengthBytes(rEncoded.count))
        der.append(rEncoded)
        der.append(0x02)
        der.append(contentsOf: lengthBytes(sEncoded.count))
        der.append(sEncoded)
        var sequence = Data([0x30])
        sequence.append(contentsOf: lengthBytes(der.count))
        sequence.append(der)
        return sequence
    }

    private static func rsaKeyParts(modulus: Data, exponent: Int) -> Data {
        func integer(_ data: Data) -> Data {
            var value = data
            while value.first == 0x00, value.count > 1 { value.removeFirst() }
            if let first = value.first, first & 0x80 != 0 {
                value = Data([0x00]) + value
            }
            return value
        }
        var modulusData = integer(modulus)
        var exponentData = Data()
        var value = exponent
        while value > 0 {
            exponentData.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        exponentData = integer(exponentData)
        var sequence = Data()
        sequence.append(0x02)
        sequence.append(contentsOf: lengthBytes(modulusData.count))
        sequence.append(modulusData)
        sequence.append(0x02)
        sequence.append(contentsOf: lengthBytes(exponentData.count))
        sequence.append(exponentData)
        var outer = Data([0x30])
        outer.append(contentsOf: lengthBytes(sequence.count))
        outer.append(sequence)
        modulusData.removeAll()
        return outer
    }

    private static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}

// MARK: - Helpers

struct Reader {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw FloeError.validationFailed("unexpected end of packet") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint16() throws -> UInt16 {
        let bytes = try self.bytes(count: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    mutating func uint32() throws -> UInt32 {
        let bytes = try self.bytes(count: 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func bytes(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw FloeError.validationFailed("truncated packet")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func rest() throws -> Data {
        let remaining = data.subdata(in: offset..<data.count)
        offset = data.count
        return remaining
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        (0..<8).reversed().map { UInt8((self >> (UInt64($0) * 8)) & 0xFF) }
    }
}
