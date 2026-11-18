// Floe Mac M00 — private host/service control protocol.
//
// SPDX-License-Identifier: MPL-2.0
//
// This is a local-only IPC contract between the mode host and the embedded
// Bridge service. It is deliberately separate from the paired-client RPC:
// the control channel can read status, carry a user pairing decision and
// stop an idle service, but it cannot execute a terminal command or read a
// file. A control message is never produced by model text.
//
// An owning connection may also hold an update reservation: reserve closes
// new admission while the host drains its owned UI for an OTA or exit,
// cancel releases it, and commit transfers the same reservation into
// shutdown. The reservation is bound to the authenticated connection that
// created it; losing that connection releases it. Older hosts simply never
// send the new kinds; older services reject them as unsupported requests.

import CryptoKit
import Foundation

public enum BridgeControlKind: String, Codable, Sendable {
    case hello
    case status
    case pairingDecision
    case revoke
    case stop
    case claim
    case challenge
    case reserve
    case cancel
    case commit
    case event
    case reply
}

public struct BridgeControlConsent: Codable, Sendable, Equatable {
    /// Stable identity for one pairing attempt (clientID + attempt nonce).
    public var attemptID: String
    public var clientID: String
    public var displayName: String
    public var verification: String
    public var receivedAt: String

    public init(attemptID: String = "", clientID: String, displayName: String,
                verification: String, receivedAt: String) {
        self.attemptID = attemptID
        self.clientID = clientID
        self.displayName = displayName
        self.verification = verification
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID, clientID, displayName, verification, receivedAt
    }

    /// Older helpers did not carry an attempt identity. Decode it as empty so
    /// a new host can still show and exactly match by client+fingerprint.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID) ?? ""
        clientID = try container.decode(String.self, forKey: .clientID)
        displayName = try container.decode(String.self, forKey: .displayName)
        verification = try container.decode(String.self, forKey: .verification)
        receivedAt = try container.decode(String.self, forKey: .receivedAt)
    }
}

public struct BridgeControlPairedClient: Codable, Sendable, Equatable {
    public var clientID: String
    public var name: String
    public var verification: String?

    public init(clientID: String, name: String, verification: String?) {
        self.clientID = clientID
        self.name = name
        self.verification = verification
    }
}

/// Authenticated update reservation exposed in status. The token is an
/// opaque, unguessable string: only the connection that created the
/// reservation may cancel or commit it, and only while it still owns the
/// service. A host that sees a reservation it does not own must wait for the
/// owner to finish, take ownership (which releases a superseded owner's
/// reservation), or stop the service once it is idle.
public struct BridgeControlUpdateReservation: Codable, Sendable, Equatable {
    public var token: String
    public var reservedAt: String
    public var reason: String

    public init(token: String, reservedAt: String, reason: String) {
        self.token = token
        self.reservedAt = reservedAt
        self.reason = reason
    }
}

public struct BridgeControlStatus: Codable, Sendable, Equatable {
    public var schema: String
    public var state: String
    public var port: Int?
    public var pid: Int32
    public var parentPID: Int32
    public var storageRoot: String
    public var workerHome: String
    public var controlSocket: String
    public var identitySource: String
    public var identityPublicKeyBase64: String?
    public var identityFingerprintSHA256: String?
    public var version: String?
    public var build: String?
    public var bundleIdentifier: String?
    public var bundlePath: String
    public var listenerScope: String
    public var activeTaskIDs: [String]
    public var unknownTaskIDs: [String]
    public var pairedClients: [BridgeControlPairedClient]
    public var capabilities: [String]
    public var activityCount: Int
    /// Kept for older hosts: the oldest current request, if any.
    public var consent: BridgeControlConsent?
    /// Every current request in bounded order. New hosts use this list.
    public var pendingConsents: [BridgeControlConsent]
    /// Monotonic revision of the pending-pairing list. A host must ignore an
    /// older revision even if it arrives after a newer one.
    public var pairingRevision: UInt64
    public var hostClaimed: Bool
    public var storeLockPath: String?
    public var storeLockExclusive: Bool
    public var orphaned: Bool
    public var startedAt: String?
    public var screenCaptureAllowed: Bool
    public var accessibilityAllowed: Bool
    public var message: String?
    /// Current authenticated update reservation, if any. Absent on older
    /// services and whenever no reservation exists.
    public var updateReservation: BridgeControlUpdateReservation?
    /// Nil means an older helper did not report its admission gate. A caller
    /// must not infer that an uncertain reservation has been released.
    public var admissionClosed: Bool?

    public init(
        schema: String = "floe-mac-bridge-control-status-v1",
        state: String,
        port: Int? = nil,
        pid: Int32,
        parentPID: Int32,
        storageRoot: String,
        workerHome: String,
        controlSocket: String,
        identitySource: String,
        identityPublicKeyBase64: String? = nil,
        identityFingerprintSHA256: String? = nil,
        version: String? = nil,
        build: String? = nil,
        bundleIdentifier: String? = nil,
        bundlePath: String = "",
        listenerScope: String = "127.0.0.1",
        activeTaskIDs: [String] = [],
        unknownTaskIDs: [String] = [],
        pairedClients: [BridgeControlPairedClient] = [],
        capabilities: [String] = [],
        activityCount: Int = 0,
        consent: BridgeControlConsent? = nil,
        pendingConsents: [BridgeControlConsent] = [],
        pairingRevision: UInt64 = 0,
        hostClaimed: Bool = false,
        storeLockPath: String? = nil,
        storeLockExclusive: Bool = false,
        orphaned: Bool = false,
        startedAt: String? = nil,
        screenCaptureAllowed: Bool = false,
        accessibilityAllowed: Bool = false,
        message: String? = nil,
        updateReservation: BridgeControlUpdateReservation? = nil,
        admissionClosed: Bool? = nil
    ) {
        self.schema = schema
        self.state = state
        self.port = port
        self.pid = pid
        self.parentPID = parentPID
        self.storageRoot = storageRoot
        self.workerHome = workerHome
        self.controlSocket = controlSocket
        self.identitySource = identitySource
        self.identityPublicKeyBase64 = identityPublicKeyBase64
        self.identityFingerprintSHA256 = identityFingerprintSHA256
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.listenerScope = listenerScope
        self.activeTaskIDs = activeTaskIDs
        self.unknownTaskIDs = unknownTaskIDs
        self.pairedClients = pairedClients
        self.capabilities = capabilities
        self.activityCount = activityCount
        self.consent = consent
        self.pendingConsents = pendingConsents
        self.pairingRevision = pairingRevision
        self.hostClaimed = hostClaimed
        self.storeLockPath = storeLockPath
        self.storeLockExclusive = storeLockExclusive
        self.orphaned = orphaned
        self.startedAt = startedAt
        self.screenCaptureAllowed = screenCaptureAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.message = message
        self.updateReservation = updateReservation
        self.admissionClosed = admissionClosed
    }

    private enum CodingKeys: String, CodingKey {
        case schema, state, port, pid, parentPID, storageRoot, workerHome, controlSocket
        case identitySource, identityPublicKeyBase64, identityFingerprintSHA256
        case version, build, bundleIdentifier, bundlePath, listenerScope
        case activeTaskIDs, unknownTaskIDs, pairedClients, capabilities, activityCount
        case consent, pendingConsents, pairingRevision, hostClaimed
        case storeLockPath, storeLockExclusive, orphaned, startedAt
        case screenCaptureAllowed, accessibilityAllowed, message
        case updateReservation, admissionClosed
    }

    /// Additive decoding: an older helper status without the ordered consent
    /// list or ownership fields remains readable. Missing arrays are empty and
    /// missing counters are zero, never an inferred request from old text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
            ?? "floe-mac-bridge-control-status-v1"
        state = try container.decode(String.self, forKey: .state)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        pid = try container.decode(Int32.self, forKey: .pid)
        parentPID = try container.decodeIfPresent(Int32.self, forKey: .parentPID) ?? 0
        storageRoot = try container.decodeIfPresent(String.self, forKey: .storageRoot) ?? ""
        workerHome = try container.decodeIfPresent(String.self, forKey: .workerHome) ?? ""
        controlSocket = try container.decodeIfPresent(String.self, forKey: .controlSocket) ?? ""
        identitySource = try container.decodeIfPresent(String.self, forKey: .identitySource) ?? "unknown"
        identityPublicKeyBase64 = try container.decodeIfPresent(String.self, forKey: .identityPublicKeyBase64)
        identityFingerprintSHA256 = try container.decodeIfPresent(String.self, forKey: .identityFingerprintSHA256)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        build = try container.decodeIfPresent(String.self, forKey: .build)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath) ?? ""
        listenerScope = try container.decodeIfPresent(String.self, forKey: .listenerScope) ?? "127.0.0.1"
        activeTaskIDs = try container.decodeIfPresent([String].self, forKey: .activeTaskIDs) ?? []
        unknownTaskIDs = try container.decodeIfPresent([String].self, forKey: .unknownTaskIDs) ?? []
        pairedClients = try container.decodeIfPresent([BridgeControlPairedClient].self, forKey: .pairedClients) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        activityCount = try container.decodeIfPresent(Int.self, forKey: .activityCount) ?? 0
        consent = try container.decodeIfPresent(BridgeControlConsent.self, forKey: .consent)
        pendingConsents = try container.decodeIfPresent([BridgeControlConsent].self, forKey: .pendingConsents) ?? []
        pairingRevision = try container.decodeIfPresent(UInt64.self, forKey: .pairingRevision) ?? 0
        hostClaimed = try container.decodeIfPresent(Bool.self, forKey: .hostClaimed) ?? false
        storeLockPath = try container.decodeIfPresent(String.self, forKey: .storeLockPath)
        storeLockExclusive = try container.decodeIfPresent(Bool.self, forKey: .storeLockExclusive) ?? false
        orphaned = try container.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        screenCaptureAllowed = try container.decodeIfPresent(Bool.self, forKey: .screenCaptureAllowed) ?? false
        accessibilityAllowed = try container.decodeIfPresent(Bool.self, forKey: .accessibilityAllowed) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message)
        updateReservation = try container.decodeIfPresent(BridgeControlUpdateReservation.self, forKey: .updateReservation)
        admissionClosed = try container.decodeIfPresent(Bool.self, forKey: .admissionClosed)
    }
}

public struct BridgeControlEvent: Codable, Sendable, Equatable {
    public var kind: String
    public var consent: BridgeControlConsent?
    public var consents: [BridgeControlConsent]?
    public var pairingRevision: UInt64?
    public var status: BridgeControlStatus?
    public var message: String?

    public init(kind: String, consent: BridgeControlConsent? = nil,
                consents: [BridgeControlConsent]? = nil,
                pairingRevision: UInt64? = nil,
                status: BridgeControlStatus? = nil, message: String? = nil) {
        self.kind = kind
        self.consent = consent
        self.consents = consents
        self.pairingRevision = pairingRevision
        self.status = status
        self.message = message
    }
}

public struct BridgeControlMessage: Codable, Sendable, Equatable {
    public var kind: BridgeControlKind
    public var id: UUID?
    public var replyTo: UUID?
    public var token: String?
    public var status: BridgeControlStatus?
    public var event: BridgeControlEvent?
    public var clientID: String?
    public var attemptID: String?
    public var verification: String?
    public var allow: Bool?
    public var nonce: String?
    public var reason: String?
    public var error: String?
    public var publicKeyBase64: String?
    public var signatureBase64: String?

    public init(
        kind: BridgeControlKind,
        id: UUID? = nil,
        replyTo: UUID? = nil,
        token: String? = nil,
        status: BridgeControlStatus? = nil,
        event: BridgeControlEvent? = nil,
        clientID: String? = nil,
        attemptID: String? = nil,
        verification: String? = nil,
        allow: Bool? = nil,
        nonce: String? = nil,
        reason: String? = nil,
        error: String? = nil,
        publicKeyBase64: String? = nil,
        signatureBase64: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.replyTo = replyTo
        self.token = token
        self.status = status
        self.event = event
        self.clientID = clientID
        self.attemptID = attemptID
        self.verification = verification
        self.allow = allow
        self.nonce = nonce
        self.reason = reason
        self.error = error
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
    }
}

public struct BridgeControlDiscovery: Codable, Sendable, Equatable {
    public var schema: String
    public var pid: Int32
    public var parentPID: Int32
    public var socket: String
    public var token: String
    public var storageRoot: String
    public var identityFingerprintSHA256: String?
    public var identitySource: String
    public var startedAt: String

    public init(schema: String = "floe-mac-bridge-control-discovery-v1",
                pid: Int32, parentPID: Int32, socket: String, token: String,
                storageRoot: String, identityFingerprintSHA256: String?,
                identitySource: String, startedAt: String) {
        self.schema = schema
        self.pid = pid
        self.parentPID = parentPID
        self.socket = socket
        self.token = token
        self.storageRoot = storageRoot
        self.identityFingerprintSHA256 = identityFingerprintSHA256
        self.identitySource = identitySource
        self.startedAt = startedAt
    }
}

public enum BridgeControlCodec {
    /// Bounded control frame. This is intentionally much smaller than the
    /// paired RPC frame: control messages never carry file or terminal data.
    public static let maximumFrameBytes = 512 * 1024
    public static let headerBytes = 4

    public static func encode(_ message: BridgeControlMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(message)
        guard body.count > 0, body.count <= maximumFrameBytes else {
            throw BridgeControlFailure.frameTooLarge
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: headerBytes)
        frame.append(body)
        return frame
    }

    public static func decodeBody(_ body: Data) throws -> BridgeControlMessage {
        guard body.count > 0, body.count <= maximumFrameBytes else {
            throw BridgeControlFailure.invalidFrame
        }
        return try JSONDecoder().decode(BridgeControlMessage.self, from: body)
    }

    public static func bodyLength(fromHeader header: Data) -> Int? {
        guard header.count == headerBytes else { return nil }
        let bytes = [UInt8](header)
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let length = Int(value)
        guard length > 0, length <= maximumFrameBytes else { return nil }
        return length
    }

    public static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public static func identityChallenge(_ nonce: Data) -> Data {
        Data("Floe Bridge helper identity v1\0".utf8) + nonce
    }
}

public enum BridgeControlFailure: Error, LocalizedError, Sendable {
    case frameTooLarge
    case invalidFrame
    case authentication
    case notConnected
    case timeout
    case socketPathTooLong
    case socketUnavailable
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge: "The local control message is too large."
        case .invalidFrame: "The local control frame is invalid."
        case .authentication: "The local control channel could not be authenticated."
        case .notConnected: "The embedded Bridge service is not connected."
        case .timeout: "The embedded Bridge service did not answer in time."
        case .socketPathTooLong: "The local control socket path is too long for this account."
        case .socketUnavailable: "The local control socket is unavailable."
        case .remote(let text): text
        }
    }
}
