// FloeIOSAutomation — injected opaque pairing-credential contract.
//
// The generic Skill configuration / secret-store lane owns persistence. This
// module only defines the scoped handle, the opaque secret payload and the
// locked/missing behaviour. The Floe client never writes pairing key bytes to
// Skill files, logs, arguments, job records or tool output.

import Foundation

public struct IOSBridgePairingHandle: RawRepresentable, Hashable, Sendable, Codable,
                                      CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked value: String) {
        self.rawValue = value
    }

    /// One local connection profile. A multi-profile installation can derive
    /// its own scoped handle with `skillConnection(profileID:)`.
    public static let localDefault = IOSBridgePairingHandle(unchecked: "ios-bridge.local.v1")

    /// Namespaced handle for the generic Skill secret store. The profile
    /// identifier must already be stable, local, and owned by the installer;
    /// it must never be a model-supplied path or arbitrary string.
    public static func skillConnection(profileID: String) -> IOSBridgePairingHandle? {
        guard (1...64).contains(profileID.utf8.count),
              profileID.utf8.allSatisfy({ byte in
                  (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                      || byte == 0x2E || byte == 0x5F || byte == 0x2D
              }) else {
            return nil
        }
        return IOSBridgePairingHandle(rawValue: "skill.ios-automation.\(profileID)")
    }

    public var description: String { "IOSBridgePairingHandle(\(rawValue))" }

    private static func isValid(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (0x21...0x7E).contains(byte)
        }
    }
}

public enum IOSBridgeCredentialAvailability: Sendable, Equatable {
    case available
    case missing
    /// The credential exists but cannot be accessed until the device is
    /// unlocked. This must never trigger deletion or re-pairing.
    case locked(reason: String)
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public enum IOSBridgePairingStoreError: Error, Equatable, Sendable {
    case locked
    case missing
    case unavailable(String)
    case corrupt
    case verificationFailed
}

public protocol IOSBridgePairingStore: Sendable {
    func availability(for handle: IOSBridgePairingHandle) async -> IOSBridgeCredentialAvailability

    /// Loads the complete secret record. Implementations must never log it or
    /// return it to model-visible output.
    func load(_ handle: IOSBridgePairingHandle) async throws -> IOSBridgePairingRecord

    /// Atomically replaces the record for `handle`. If this throws, the
    /// previous record must remain intact.
    func save(_ record: IOSBridgePairingRecord, for handle: IOSBridgePairingHandle) async throws

    func delete(_ handle: IOSBridgePairingHandle) async throws
}

public struct IOSBridgePairingSummary: Sendable, Equatable, CustomStringConvertible {
    public let clientName: String
    public let tokenID: String
    public let grantedAt: Date
    public let lastVerifiedAt: Date
    public let expiresAt: Date
    public let protocolVersion: Int

    public var description: String {
        "IOSBridgePairingSummary(client: \(clientName), expires: \(expiresAt))"
    }
}

/// Complete pairing record. The key is an internal stored property; public
/// APIs expose only a redacted summary and the opaque store payload.
public struct IOSBridgePairingRecord: Sendable, Equatable, CustomStringConvertible,
                                     CustomDebugStringConvertible {
    public let tokenID: String
    public let clientName: String
    public let grantedAt: Date
    public let lastVerifiedAt: Date
    public let expiresAt: Date
    public let protocolVersion: Int
    let keyMaterial: Data

    public init(
        tokenID: String,
        clientName: String,
        grantedAt: Date,
        lastVerifiedAt: Date,
        expiresAt: Date,
        protocolVersion: Int,
        keyMaterial: Data
    ) throws {
        guard keyMaterial.count == IOSBridgeEnvelope.keyByteCount else {
            throw IOSBridgePairingStoreError.corrupt
        }
        guard tokenID == IOSBridgeEnvelope.tokenID(for: keyMaterial) else {
            throw IOSBridgePairingStoreError.corrupt
        }
        guard Self.isValidClientName(clientName) else {
            throw IOSBridgePairingStoreError.corrupt
        }
        guard protocolVersion == IOSBridgeProtocol.protocolVersion else {
            throw IOSBridgePairingStoreError.corrupt
        }
        guard Self.isValidDate(grantedAt),
              Self.isValidDate(lastVerifiedAt),
              Self.isValidDate(expiresAt),
              lastVerifiedAt >= grantedAt,
              expiresAt > grantedAt else {
            throw IOSBridgePairingStoreError.corrupt
        }
        self.tokenID = tokenID
        self.clientName = clientName
        self.grantedAt = grantedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.expiresAt = expiresAt
        self.protocolVersion = protocolVersion
        self.keyMaterial = keyMaterial
    }

    public var summary: IOSBridgePairingSummary {
        IOSBridgePairingSummary(
            clientName: clientName,
            tokenID: tokenID,
            grantedAt: grantedAt,
            lastVerifiedAt: lastVerifiedAt,
            expiresAt: expiresAt,
            protocolVersion: protocolVersion
        )
    }

    public var description: String { "IOSBridgePairingRecord(\(summary))" }
    public var debugDescription: String { description }

    public func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    func matchesKey(in other: IOSBridgePairingRecord) -> Bool {
        tokenID == other.tokenID
            && IOSBridgeEnvelope.constantTimeEquals(keyMaterial, other.keyMaterial)
    }

    /// Lets approved native storage distinguish a timestamp refresh from a
    /// new pairing without exporting the key material to its caller.
    public func hasSamePairingIdentity(as other: IOSBridgePairingRecord) -> Bool {
        protocolVersion == other.protocolVersion && matchesKey(in: other)
    }

    // MARK: - Opaque storage payload

    /// Versioned secret payload for an approved credential store. Treat the
    /// returned bytes as secret material: do not write them to Skill files,
    /// logs, diagnostics, job records or model-visible output.
    public func encodedSecretPayload() throws -> Data {
        let object: IOSBridgeJSONValue = .object([
            "v": .int(1),
            "token_id": .string(tokenID),
            "client_name": .string(clientName),
            "granted_at_ms": .int(Self.milliseconds(grantedAt)),
            "last_verified_at_ms": .int(Self.milliseconds(lastVerifiedAt)),
            "expires_at_ms": .int(Self.milliseconds(expiresAt)),
            "protocol_version": .int(protocolVersion),
            "key": .string(keyMaterial.base64EncodedString()),
        ])
        let data = object.canonicalData()
        guard data.count <= 16_384 else { throw IOSBridgePairingStoreError.corrupt }
        return data
    }

    public static func decodeSecretPayload(_ data: Data) throws -> IOSBridgePairingRecord {
        guard data.count > 0, data.count <= 16_384,
              let value = try? IOSBridgeJSONValue.decode(data),
              let object = value.objectValue,
              object["v"] == .int(1),
              let tokenID = object["token_id"]?.stringValue,
              let clientName = object["client_name"]?.stringValue,
              let grantedMS = object["granted_at_ms"]?.intValue,
              let lastVerifiedMS = object["last_verified_at_ms"]?.intValue,
              let expiresMS = object["expires_at_ms"]?.intValue,
              let protocolVersion = object["protocol_version"]?.intValue,
              let keyBase64 = object["key"]?.stringValue,
              let keyData = Data(base64Encoded: keyBase64, options: []),
              keyData.base64EncodedString() == keyBase64 else {
            throw IOSBridgePairingStoreError.corrupt
        }
        return try IOSBridgePairingRecord(
            tokenID: tokenID,
            clientName: clientName,
            grantedAt: date(milliseconds: grantedMS),
            lastVerifiedAt: date(milliseconds: lastVerifiedMS),
            expiresAt: date(milliseconds: expiresMS),
            protocolVersion: protocolVersion,
            keyMaterial: keyData
        )
    }

    // MARK: - Validation

    static func isValidClientName(_ value: String) -> Bool {
        guard (1...IOSBridgeProtocol.clientNameMaximumBytes).contains(value.utf8.count) else {
            return false
        }
        return !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
    }

    private static func isValidDate(_ value: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite && seconds >= 0 && seconds <= 4_102_444_800
    }

    private static func milliseconds(_ value: Date) -> Int {
        Int((value.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
