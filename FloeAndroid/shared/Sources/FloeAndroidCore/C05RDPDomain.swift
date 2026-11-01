// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP — Android host authority for real RDP screen sessions.
//
// FreeRDP (through FloeRDP/FloeRDPNative) owns the protocol, TLS/certificate
// handshake, authentication, capabilities and framebuffer. This file owns
// Android product semantics:
//   * an RDP endpoint attached to an ORIGINAL `RemoteHostProfile` identity;
//   * explicit certificate trust, with no first-use success and no silent
//     downgrade of a changed fingerprint;
//   * two independent sessions, explicit owner/native-epoch fencing;
//   * bounded immutable frame leases handed to the JNI binary lane (never
//     base64/JSON framebuffer bodies);
//   * input and close/reset that never replay queued input into a newer
//     session or epoch.
//
// It is NOT a BridgeV3 command. The only callers are the trusted App host
// (`floe.rdp/17`), the ordinary remote-desktop model tools and the trusted
// frame JNI ABI.
//
// Profile persistence: the original FloeSSH `RemoteHostProfile` shape is the
// only host/profile registry. It has no RDP endpoint field and FloeSSH is an
// independently owned lane, so this file keeps NARROW non-secret RDP endpoint
// metadata (host/port/username/domain/credential reference/approved
// fingerprint) keyed by the ORIGINAL profile UUID in the App-owned runtime
// root. It is not a profile list, a credential store or a session registry;
// deleting the original profile/credential is still the authority.

import Foundation
import FloeCore
import FloeSSH
import FloeRDP

// MARK: - Wire identity

public enum C05RDPWire {
    public static let version = 17
    public static let schema = "floe.rdp/17"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumProfiles = 64
    public static let maximumEndpointsPerProfile = 4
    public static let maximumSessions = 2
    public static let maximumInputEvents = 32
    public static let maximumTextBytes = 4_096
    public static let maximumCredentialBytes = 40 * 1_024
    public static let maximumPasswordBytes = 1_024
    public static let maximumFrameLeases = 8
    public static let maximumFrameMetadataBytes = 4_096
    public static let challengeLifetime: TimeInterval = 300
    public static let rdpCredentialPrefix = "floe.rdp."
    public static let modelTools = true
    public static let supportedTransports = ["direct"]
}

// MARK: - Errors

public enum C05RDPErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeUnavailable
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case invalidOwner
    case invalidProfile
    case profileNotFound
    case profileLimit
    case profileBusy
    case endpointNotFound
    case endpointLimit
    case credentialMissing
    case credentialInvalid
    case gatewayUnavailable
    case authenticationFailed
    case certificateConfirmationRequired
    case certificateMismatch
    case certificateExpired
    case connectionRefused
    case hostNotFound
    case timedOut
    case networkUnreachable
    case transportFailed
    case protocolIncompatible
    case sessionNotFound
    case sessionLimit
    case sessionUnavailable
    case inputInvalid
    case cleanupIncomplete
    case cancelled
    case timeout
    case internalFailure
}

public struct C05RDPError: Error, Sendable, Equatable {
    public let code: C05RDPErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let category: String?
    public let stage: String?
    public let challenge: C05RDPCertificatePrompt?

    public init(
        _ code: C05RDPErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        category: String? = nil,
        stage: String? = nil,
        challenge: C05RDPCertificatePrompt? = nil
    ) {
        self.code = code
        self.reason = reason ?? code.rawValue
        self.retryable = retryable
        self.detail = detail
        self.category = category
        self.stage = stage
        self.challenge = challenge
    }
}

// MARK: - Value surface

public struct C05RDPCertificatePrompt: Sendable, Equatable {
    public let profileID: UUID
    public let endpointID: UUID
    public let host: String
    public let port: Int
    public let fingerprintSHA256: String
    public let subject: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let kind: RDPCertificateChallengeKind
    public let reason: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        profileID: UUID,
        endpointID: UUID,
        host: String,
        port: Int,
        fingerprintSHA256: String,
        subject: String,
        notBefore: Date?,
        notAfter: Date?,
        kind: RDPCertificateChallengeKind,
        reason: String,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.profileID = profileID
        self.endpointID = endpointID
        self.host = host
        self.port = port
        self.fingerprintSHA256 = fingerprintSHA256
        self.subject = subject
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.kind = kind
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct C05RDPFailureStatus: Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let category: String
    public let stage: String
    public let fingerprintSHA256: String?

    public init(
        code: String,
        message: String,
        retryable: Bool,
        category: String,
        stage: String,
        fingerprintSHA256: String? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.category = category
        self.stage = stage
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

public struct C05RDPSessionSnapshot: Sendable, Equatable {
    public let id: UUID
    public let profileID: UUID
    public let endpointID: UUID
    public let displayName: String
    public let host: String
    public let port: Int
    public let username: String
    public let domain: String
    public let state: String
    public let width: Int
    public let height: Int
    public let frameRevision: UInt64
    public let frameBytes: Int
    public let approvedFingerprintSHA256: String?
    public let certificateChallenge: C05RDPCertificatePrompt?
    public let createdAt: Date
    public let lastActivityAt: Date
    public let failure: C05RDPFailureStatus?
}

public struct C05RDPShutdownReport: Sendable, Equatable {
    public let sessionID: UUID
    public let closed: Bool
    public let complete: Bool
}

public struct C05RDPRootStopReport: Sendable, Equatable {
    public let drained: Bool
    public let closedSessions: Int
}

public struct C05RDPInputAcceptance: Sendable, Equatable {
    public let accepted: Int
}

public struct C05RDPCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let credentialGatewayReady: Bool
    public let runtimeVersion: String
    public let maximumSessions: Int
    public let maximumProfiles: Int
    public let maximumEndpointsPerProfile: Int
    public let maximumInputEvents: Int
    public let maximumTextBytes: Int
    public let maximumCredentialBytes: Int
    public let maximumFrameBytes: Int
    public let maximumLeases: Int
    public let pixelFormat: String
    public let supportsDirect: Bool
    public let supportsSSHTunnel: Bool
    public let supportsPointer: Bool
    public let supportsKeyboard: Bool
    public let supportsWheel: Bool
    public let supportsCertificateTrust: Bool
    public let modelTools: Bool
}

public struct C05RDPEndpointDraft: Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String
    public var passwordRef: SecretReference?

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 3389,
        username: String,
        domain: String = "",
        passwordRef: SecretReference? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.passwordRef = passwordRef
    }
}

public struct C05RDPProfileDraft: Sendable, Equatable {
    public var id: UUID?
    public var displayName: String
    public var deviceKind: String
    public var endpoints: [C05RDPEndpointDraft]

    public init(
        id: UUID?,
        displayName: String,
        deviceKind: String,
        endpoints: [C05RDPEndpointDraft]
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceKind = deviceKind
        self.endpoints = endpoints
    }
}

public struct C05RDPEndpointSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let port: Int
    public let username: String
    public let domain: String
    public let hasPassword: Bool
    public let approvedFingerprintSHA256: String?
    public let passwordRef: C05CredentialReference?
}

public struct C05RDPHostSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let deviceKind: String
    public let isRemoteExecutionEnvironment: Bool
    public let endpointCount: Int
}

public struct C05RDPHostDetail: Sendable, Equatable {
    public let summary: C05RDPHostSummary
    public let endpoints: [C05RDPEndpointSummary]
}

public struct C05RDPTrustReport: Sendable, Equatable {
    public let profileID: UUID
    public let endpointID: UUID
    public let fingerprintSHA256: String
    public let approved: Bool
}

// MARK: - Stored endpoint metadata

public struct C05RDPStoredEndpoint: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String
    public var passwordRef: SecretReference?
    public var approvedFingerprintSHA256: String?

    public init(
        profileID: UUID,
        id: UUID,
        displayName: String,
        host: String,
        port: Int,
        username: String,
        domain: String,
        passwordRef: SecretReference?,
        approvedFingerprintSHA256: String?
    ) {
        self.profileID = profileID
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.passwordRef = passwordRef
        self.approvedFingerprintSHA256 = approvedFingerprintSHA256
    }
}

/// Narrow, non-secret JSON store keyed by the ORIGINAL profile UUID.
/// It persists only RDP endpoint metadata; credential bodies remain in the
/// approved secret gateway and live sessions remain RAM-only in the domain.
public struct C05RDPProfileStore: Sendable {
    public static let maximumBytes = 256 * 1_024

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Document: Codable {
        var version: Int
        var endpoints: [C05RDPStoredEndpoint]
    }

    public func load() throws -> [C05RDPStoredEndpoint] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try? manager.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue, size <= Self.maximumBytes else {
            throw C05RDPError(.invalidProfile, "rdpStoreTooLarge")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw C05RDPError(.invalidProfile, "rdpStoreUnreadable")
        }
        guard data.count <= Self.maximumBytes else {
            throw C05RDPError(.invalidProfile, "rdpStoreTooLarge")
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1,
                  document.endpoints.count <= C05RDPWire.maximumProfiles * C05RDPWire.maximumEndpointsPerProfile else {
                throw C05RDPError(.invalidProfile, "rdpStoreInvalid")
            }
            return document.endpoints
        } catch let error as C05RDPError {
            throw error
        } catch {
            throw C05RDPError(.invalidProfile, "rdpStoreInvalid")
        }
    }

    public func save(_ endpoints: [C05RDPStoredEndpoint]) throws {
        guard endpoints.count <= C05RDPWire.maximumProfiles * C05RDPWire.maximumEndpointsPerProfile else {
            throw C05RDPError(.profileLimit, "rdpEndpointLimit")
        }
        let document = Document(version: 1, endpoints: endpoints)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw C05RDPError(.invalidProfile, "rdpStoreEncodeFailed")
        }
        guard data.count <= Self.maximumBytes else {
            throw C05RDPError(.profileLimit, "rdpStoreTooLarge")
        }
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw C05RDPError(.internalFailure, "rdpStoreWriteFailed", retryable: true)
        }
    }
}

// MARK: - Profile seam

public protocol C05RDPProfileBridging: Sendable {
    func listProfiles(owner: C05RemoteOwner) async throws -> C05HostList
    func profileDetail(id: UUID, owner: C05RemoteOwner) async throws -> C05HostDetail
    func saveProfile(_ profile: RemoteHostProfile, owner: C05RemoteOwner) async throws -> C05HostDetail
    func deleteProfile(id: UUID, owner: C05RemoteOwner) async throws -> C05ProfileDeleteReport
    func rootStop(expectedEpoch: UInt64) async -> C05RootStopReport
}

extension C05RemoteDomain: C05RDPProfileBridging {}

// MARK: - Frame broker

/// Process-local frame lease table for the trusted JNI lane. It is not a
/// second session registry: every entry is a real `RDPFloeSessionDriving`
/// owned by `C05RDPDomain`, fenced by the exact native epoch and owner token,
/// and released on close/rootStop. The JNI caller never supplies a path,
/// pointer, digest or framing decision.
final class C05RDPFrameBroker: @unchecked Sendable {
    static let shared = C05RDPFrameBroker()

    enum BrokerError: Error, Sendable, Equatable {
        case staleEpoch
        case unknownSession
        case unknownLease
        case notConnected
        case noFrame
        case invalidOffset
        case bufferTooSmall
        case leaseLimit
    }

    struct Acquired {
        let leaseID: String
        let frame: RDPFloeFrame
    }

    private struct Registration {
        let sessionID: UUID
        let ownerToken: String
        let epoch: UInt64
        let session: any RDPFloeSessionDriving
    }

    private struct Lease {
        let id: String
        let sessionID: UUID
        let epoch: UInt64
        let frame: RDPFloeFrame
    }

    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]
    private var leases: [String: Lease] = [:]
    private var highestRetiredEpoch: UInt64 = 0

    func register(
        sessionID: UUID,
        ownerToken: String,
        epoch: UInt64,
        session: any RDPFloeSessionDriving
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch > highestRetiredEpoch else { return false }
        registrations[sessionID] = Registration(
            sessionID: sessionID,
            ownerToken: ownerToken,
            epoch: epoch,
            session: session
        )
        return true
    }

    func unregister(sessionID: UUID) {
        lock.lock()
        registrations.removeValue(forKey: sessionID)
        leases = leases.filter { $0.value.sessionID != sessionID }
        lock.unlock()
    }

    func acquire(epoch: UInt64, ownerToken: String, sessionID: UUID) throws -> Acquired {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > highestRetiredEpoch else { throw BrokerError.staleEpoch }
        guard let registration = registrations[sessionID],
              registration.epoch == epoch,
              registration.ownerToken == ownerToken else {
            throw BrokerError.unknownSession
        }
        guard registration.session.isConnected else { throw BrokerError.notConnected }
        guard leases.count < C05RDPWire.maximumFrameLeases else { throw BrokerError.leaseLimit }
        let lease: RDPFloeFrameLease
        do {
            lease = try registration.session.acquireFrame()
        } catch {
            throw BrokerError.noFrame
        }
        let id = lease.id.uuidString
        leases[id] = Lease(id: id, sessionID: sessionID, epoch: epoch, frame: lease.frame)
        return Acquired(leaseID: id, frame: lease.frame)
    }

    func read(epoch: UInt64, leaseID: String, offset: Int, capacity: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > highestRetiredEpoch else { throw BrokerError.staleEpoch }
        guard let lease = leases[leaseID], lease.epoch == epoch else {
            throw BrokerError.unknownLease
        }
        guard offset >= 0, offset <= lease.frame.data.count else {
            throw BrokerError.invalidOffset
        }
        guard capacity > 0, capacity <= 65_536 else { throw BrokerError.invalidOffset }
        let end = min(lease.frame.data.count, offset + capacity)
        guard end >= offset else { throw BrokerError.invalidOffset }
        return lease.frame.data.subdata(in: offset..<end)
    }

    func release(epoch: UInt64, leaseID: String) {
        lock.lock()
        if let lease = leases[leaseID], lease.epoch == epoch {
            leases.removeValue(forKey: leaseID)
        }
        lock.unlock()
    }

    func rootStop(expectedEpoch: UInt64) {
        lock.lock()
        highestRetiredEpoch = max(highestRetiredEpoch, expectedEpoch)
        registrations = registrations.filter { $0.value.epoch > expectedEpoch }
        leases = leases.filter { $0.value.epoch > expectedEpoch }
        lock.unlock()
    }
}

// MARK: - Session factory

public typealias C05RDPSessionFactory = @Sendable (
    _ host: String,
    _ port: UInt16,
    _ username: String,
    _ password: String,
    _ domain: String,
    _ approvedFingerprint: String?,
    _ width: UInt32,
    _ height: UInt32
) throws -> any RDPFloeSessionDriving

// MARK: - Domain

public actor C05RDPDomain {
    public static let shared = C05RDPDomain(
        profiles: C05RemoteDomain.shared,
        readiness: { C05ProductionWiring.readiness() },
        credentialReader: { reference in try await C05ProductionWiring.readOpaque(reference) },
        credentialWriter: { reference, value in
            try await C05ProductionWiring.writeCredential(reference, value)
        },
        credentialDeleter: { reference in
            try await C05ProductionWiring.deleteOpaque(reference)
        },
        credentialGatewayReady: { SecretGatewayRegistry.shared.isRegistered },
        profileStoreProvider: { epoch in
            try C05RDPProductionWiring.profileStore(epoch: epoch)
        },
        sessionFactory: C05RDPProductionWiring.defaultSessionFactory,
        runtimeVersion: C05RDPProductionWiring.runtimeVersion
    )

    private struct Record {
        let id: UUID
        let profileID: UUID
        let endpointID: UUID
        let displayName: String
        let host: String
        let port: Int
        let username: String
        let domain: String
        let owner: C05RemoteOwner
        let session: any RDPFloeSessionDriving
        let approvedFingerprintSHA256: String?
        let createdAt: Date
        var lastActivityAt: Date
    }

    private let profiles: any C05RDPProfileBridging
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let credentialReader: @Sendable (String) async throws -> Data?
    private let credentialWriter: @Sendable (String, Data) async throws -> Void
    private let credentialDeleter: @Sendable (String) async throws -> Void
    private let credentialGatewayReady: @Sendable () -> Bool
    private let profileStoreProvider: @Sendable (UInt64) throws -> C05RDPProfileStore
    private let sessionFactory: C05RDPSessionFactory
    private let runtimeVersion: @Sendable () -> String

    private var sessions: [UUID: Record] = [:]
    private var pendingChallenges: [UUID: C05RDPCertificatePrompt] = [:]
    private var closedThroughEpoch: UInt64 = 0

    public init(
        profiles: any C05RDPProfileBridging,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        credentialReader: @escaping @Sendable (String) async throws -> Data?,
        credentialWriter: @escaping @Sendable (String, Data) async throws -> Void,
        credentialDeleter: @escaping @Sendable (String) async throws -> Void,
        credentialGatewayReady: @escaping @Sendable () -> Bool = { false },
        profileStoreProvider: @escaping @Sendable (UInt64) throws -> C05RDPProfileStore,
        sessionFactory: @escaping C05RDPSessionFactory,
        runtimeVersion: @escaping @Sendable () -> String = { "unavailable" }
    ) {
        self.profiles = profiles
        self.readiness = readiness
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.credentialDeleter = credentialDeleter
        self.credentialGatewayReady = credentialGatewayReady
        self.profileStoreProvider = profileStoreProvider
        self.sessionFactory = sessionFactory
        self.runtimeVersion = runtimeVersion
    }

    // MARK: Capabilities

    public func capabilities() -> C05RDPCapabilities {
        let current = readiness()
        return C05RDPCapabilities(
            coreReady: current.ready,
            epoch: current.epoch,
            credentialGatewayReady: credentialGatewayReady(),
            runtimeVersion: runtimeVersion(),
            maximumSessions: C05RDPWire.maximumSessions,
            maximumProfiles: C05RDPWire.maximumProfiles,
            maximumEndpointsPerProfile: C05RDPWire.maximumEndpointsPerProfile,
            maximumInputEvents: C05RDPWire.maximumInputEvents,
            maximumTextBytes: C05RDPWire.maximumTextBytes,
            maximumCredentialBytes: C05RDPWire.maximumCredentialBytes,
            maximumFrameBytes: RDPFloeFrameBounds.maximumBytes,
            maximumLeases: C05RDPWire.maximumFrameLeases,
            pixelFormat: RDPFloeFrame.pixelFormat,
            supportsDirect: true,
            supportsSSHTunnel: false,
            supportsPointer: true,
            supportsKeyboard: true,
            supportsWheel: true,
            supportsCertificateTrust: true,
            modelTools: C05RDPWire.modelTools
        )
    }

    // MARK: Profiles

    public func listProfiles(owner: C05RemoteOwner) async throws -> [C05RDPHostDetail] {
        try requireOwner(owner)
        let store = try store(epoch: owner.nativeEpoch)
        let stored = try store.load()
        let grouped = Dictionary(grouping: stored, by: \.profileID)
        var result: [C05RDPHostDetail] = []
        result.reserveCapacity(min(grouped.count, C05RDPWire.maximumProfiles))
        for profileID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard result.count < C05RDPWire.maximumProfiles else { break }
            guard let detail = try? await profiles.profileDetail(id: profileID, owner: owner) else {
                continue
            }
            let endpoints = (grouped[profileID] ?? []).sorted { $0.displayName < $1.displayName }
            result.append(C05RDPHostDetail(
                summary: summary(detail, endpointCount: endpoints.count),
                endpoints: endpoints.map(endpointSummary)
            ))
        }
        return result
    }

    public func profileDetail(
        profileID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05RDPHostDetail {
        try requireOwner(owner)
        let detail: C05HostDetail
        do {
            detail = try await profiles.profileDetail(id: profileID, owner: owner)
        } catch let error as C05RemoteError {
            throw map(error)
        }
        let stored = try store(epoch: owner.nativeEpoch).load()
            .filter { $0.profileID == profileID }
            .sorted { $0.displayName < $1.displayName }
        return C05RDPHostDetail(
            summary: summary(detail, endpointCount: stored.count),
            endpoints: stored.map(endpointSummary)
        )
    }

    /// Creates or updates only RDP endpoint metadata. A new profile is an
    /// original `RemoteHostProfile` with `auth: .none` and no SSH/VNC/aux
    /// connection; an existing profile keeps every non-RDP field untouched.
    public func saveProfile(
        _ draft: C05RDPProfileDraft,
        owner: C05RemoteOwner
    ) async throws -> C05RDPHostDetail {
        try requireOwner(owner)
        let profileName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(profileName.utf8.count) else {
            throw C05RDPError(.invalidProfile, "invalidDisplayName")
        }
        guard (1...C05RDPWire.maximumEndpointsPerProfile).contains(draft.endpoints.count) else {
            throw C05RDPError(.endpointLimit, "invalidRDPEndpoints")
        }
        let deviceKind = RemoteDeviceKind(rawValue: draft.deviceKind) ?? .unspecified
        let store = try store(epoch: owner.nativeEpoch)
        var stored = try store.load()

        let profileID: UUID
        var original: C05HostDetail
        if let requested = draft.id {
            do {
                original = try await profiles.profileDetail(id: requested, owner: owner)
            } catch let error as C05RemoteError {
                throw map(error)
            }
            profileID = requested
        } else {
            let created = RemoteHostProfile(
                id: UUID(),
                displayName: profileName,
                address: "",
                port: 0,
                user: "",
                auth: .none,
                jumpChain: [],
                hostKeyPolicy: .trustOnFirstUse,
                allowsLegacyAlgorithms: false,
                deviceKind: deviceKind,
                isRemoteExecutionEnvironment: false,
                vncEndpoints: [],
                auxiliaryConnections: []
            )
            do {
                original = try await profiles.saveProfile(created, owner: owner)
            } catch let error as C05RemoteError {
                throw map(error)
            }
            profileID = created.id
        }

        var seen = Set<UUID>()
        var replacements: [C05RDPStoredEndpoint] = []
        replacements.reserveCapacity(draft.endpoints.count)
        for endpoint in draft.endpoints {
            let validated = try Self.validateEndpoint(endpoint, profileID: profileID)
            guard seen.insert(validated.id).inserted else {
                throw C05RDPError(.invalidProfile, "duplicateEndpointID")
            }
            guard !stored.contains(where: { $0.id == validated.id && $0.profileID != profileID }) else {
                throw C05RDPError(.invalidProfile, "endpointOwnedByAnotherProfile")
            }
            let previous = stored.first { $0.profileID == profileID && $0.id == validated.id }
            let sameTarget = previous?.host.caseInsensitiveCompare(validated.host) == .orderedSame
                && previous?.port == validated.port
            let pin = sameTarget ? previous?.approvedFingerprintSHA256 : nil
            replacements.append(C05RDPStoredEndpoint(
                profileID: profileID,
                id: validated.id,
                displayName: validated.displayName,
                host: validated.host,
                port: validated.port,
                username: validated.username,
                domain: validated.domain,
                passwordRef: validated.passwordRef,
                approvedFingerprintSHA256: pin
            ))
        }
        stored.removeAll { $0.profileID == profileID }
        stored.append(contentsOf: replacements)
        do {
            try store.save(stored)
        } catch {
            if draft.id == nil {
                _ = try? await profiles.deleteProfile(id: profileID, owner: owner)
            }
            throw error
        }
        return C05RDPHostDetail(
            summary: summary(original, endpointCount: replacements.count),
            endpoints: replacements.sorted { $0.displayName < $1.displayName }.map(endpointSummary)
        )
    }

    public func deleteEndpoint(
        profileID: UUID,
        endpointID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05RDPHostDetail {
        try requireOwner(owner)
        let store = try store(epoch: owner.nativeEpoch)
        var stored = try store.load()
        guard stored.contains(where: { $0.profileID == profileID && $0.id == endpointID }) else {
            throw C05RDPError(.endpointNotFound, "rdpEndpointNotFound")
        }
        stored.removeAll { $0.profileID == profileID && $0.id == endpointID }
        try store.save(stored)
        await closeSessions(profileID: profileID, endpointID: endpointID, owner: owner)
        pendingChallenges.removeValue(forKey: endpointID)
        return try await profileDetail(profileID: profileID, owner: owner)
    }

    public func deleteProfile(
        profileID: UUID,
        deleteHost: Bool,
        owner: C05RemoteOwner
    ) async throws -> C05RDPHostDetail? {
        try requireOwner(owner)
        let store = try store(epoch: owner.nativeEpoch)
        var stored = try store.load()
        stored.removeAll { $0.profileID == profileID }
        try store.save(stored)
        await closeSessions(profileID: profileID, endpointID: nil, owner: owner)
        for key in Array(pendingChallenges.keys) {
            if pendingChallenges[key]?.profileID == profileID {
                pendingChallenges.removeValue(forKey: key)
            }
        }
        guard deleteHost else { return nil }
        let detail: C05HostDetail
        do {
            detail = try await profiles.profileDetail(id: profileID, owner: owner)
        } catch let error as C05RemoteError {
            throw map(error)
        }
        guard detail.summary.auth.kind == "none",
              detail.vncEndpoints.isEmpty,
              detail.auxiliaryConnections.isEmpty else {
            return nil
        }
        _ = try? await profiles.deleteProfile(id: profileID, owner: owner)
        return nil
    }

    // MARK: Credentials (RDP namespace only)

    public func saveCredential(
        account: String,
        synchronizable: Bool,
        secret: Data,
        owner: C05RemoteOwner
    ) async throws -> C05CredentialReference {
        try requireOwner(owner)
        let reference = try Self.validatedRDPReference(
            account: account,
            synchronizable: synchronizable
        )
        guard !secret.isEmpty, secret.count <= C05RDPWire.maximumCredentialBytes else {
            throw C05RDPError(.credentialInvalid, "invalidCredentialSize")
        }
        var mutable = secret
        defer { mutable.resetBytes(in: 0..<mutable.count) }
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        do {
            try await credentialWriter(opaque, mutable)
        } catch let error as C05RemoteError {
            throw map(error)
        } catch {
            throw C05RDPError(.gatewayUnavailable, "credentialWriteFailed", retryable: true)
        }
        return C05CredentialReference(
            keychainAccount: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
    }

    public func probeCredential(_ reference: C05CredentialReference) async throws -> Bool {
        let value = try Self.validatedRDPReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
        let opaque = SecretGatewayNaming.opaqueReference(for: value)
        do {
            return try await credentialReader(opaque) != nil
        } catch let error as C05RemoteError {
            throw map(error)
        } catch {
            throw C05RDPError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
        }
    }

    public func deleteCredential(_ reference: C05CredentialReference) async throws {
        let value = try Self.validatedRDPReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
        let opaque = SecretGatewayNaming.opaqueReference(for: value)
        do {
            try await credentialDeleter(opaque)
        } catch let error as C05RemoteError {
            throw map(error)
        } catch {
            throw C05RDPError(.gatewayUnavailable, "credentialDeleteFailed", retryable: true)
        }
    }

    // MARK: Trust

    /// Approves the exact fingerprint of the most recent failed handshake for
    /// this endpoint. A missing/expired challenge, a different fingerprint or
    /// an unparsable value is refused; the App can never inject a pin that was
    /// not observed from a real server certificate.
    public func approveCertificate(
        profileID: UUID,
        endpointID: UUID,
        fingerprintSHA256: String,
        owner: C05RemoteOwner
    ) async throws -> C05RDPTrustReport {
        try requireOwner(owner)
        purgeExpiredChallenges()
        guard let normalized = RDPCertificateTrust.normalizePin(fingerprintSHA256),
              let prompt = pendingChallenges[endpointID],
              prompt.profileID == profileID,
              prompt.fingerprintSHA256 == normalized else {
            throw C05RDPError(
                .certificateMismatch,
                "certificateChallengeMismatch",
                retryable: false,
                category: "certificateTrust",
                stage: "certificate"
            )
        }
        let store = try store(epoch: owner.nativeEpoch)
        var stored = try store.load()
        guard let index = stored.firstIndex(where: {
            $0.profileID == profileID && $0.id == endpointID
        }) else {
            throw C05RDPError(.endpointNotFound, "rdpEndpointNotFound")
        }
        stored[index].approvedFingerprintSHA256 = prompt.fingerprintSHA256
        try store.save(stored)
        pendingChallenges.removeValue(forKey: endpointID)
        return C05RDPTrustReport(
            profileID: profileID,
            endpointID: endpointID,
            fingerprintSHA256: prompt.fingerprintSHA256,
            approved: true
        )
    }

    public func revokeCertificate(
        profileID: UUID,
        endpointID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05RDPTrustReport {
        try requireOwner(owner)
        let store = try store(epoch: owner.nativeEpoch)
        var stored = try store.load()
        guard let index = stored.firstIndex(where: {
            $0.profileID == profileID && $0.id == endpointID
        }) else {
            throw C05RDPError(.endpointNotFound, "rdpEndpointNotFound")
        }
        let previous = stored[index].approvedFingerprintSHA256 ?? ""
        stored[index].approvedFingerprintSHA256 = nil
        try store.save(stored)
        pendingChallenges.removeValue(forKey: endpointID)
        return C05RDPTrustReport(
            profileID: profileID,
            endpointID: endpointID,
            fingerprintSHA256: previous,
            approved: false
        )
    }

    // MARK: Connect

    public func connect(
        profileID: UUID,
        endpointID: UUID?,
        owner: C05RemoteOwner
    ) async throws -> C05RDPSessionSnapshot {
        try requireOwner(owner)
        guard sessions.count < C05RDPWire.maximumSessions else {
            throw C05RDPError(.sessionLimit, "rdpSessionLimitReached")
        }
        let store = try store(epoch: owner.nativeEpoch)
        let stored = try store.load()
        let candidates = stored.filter { $0.profileID == profileID }
        guard !candidates.isEmpty else {
            throw C05RDPError(.endpointNotFound, "rdpEndpointMissing")
        }
        let endpoint: C05RDPStoredEndpoint
        if let endpointID {
            guard let found = candidates.first(where: { $0.id == endpointID }) else {
                throw C05RDPError(.endpointNotFound, "rdpEndpointNotFound")
            }
            endpoint = found
        } else if candidates.count == 1 {
            endpoint = candidates[0]
        } else {
            throw C05RDPError(.invalidProfile, "rdpEndpointSelectionRequired")
        }
        let detail: C05HostDetail
        do {
            detail = try await profiles.profileDetail(id: profileID, owner: owner)
        } catch let error as C05RemoteError {
            throw map(error)
        }
        guard (1...65535).contains(endpoint.port) else {
            throw C05RDPError(.invalidProfile, "invalidRDPPort")
        }
        let password = try await resolvePassword(endpoint: endpoint)
        let sessionID = UUID()
        let rdp: any RDPFloeSessionDriving
        do {
            rdp = try sessionFactory(
                endpoint.host,
                UInt16(endpoint.port),
                endpoint.username,
                password,
                endpoint.domain,
                endpoint.approvedFingerprintSHA256,
                1440,
                900
            )
        } catch {
            throw C05RDPError(
                .runtimeUnavailable,
                "rdpRuntimeUnavailable",
                retryable: false,
                detail: "The Android RDP native runtime is not available in this build.",
                category: "configurationMissing",
                stage: "configuration"
            )
        }
        let record = Record(
            id: sessionID,
            profileID: profileID,
            endpointID: endpoint.id,
            displayName: endpoint.displayName,
            host: endpoint.host,
            port: endpoint.port,
            username: endpoint.username,
            domain: endpoint.domain,
            owner: owner,
            session: rdp,
            approvedFingerprintSHA256: endpoint.approvedFingerprintSHA256,
            createdAt: Date(),
            lastActivityAt: Date()
        )
        sessions[sessionID] = record
        guard C05RDPFrameBroker.shared.register(
            sessionID: sessionID,
            ownerToken: owner.token,
            epoch: owner.nativeEpoch,
            session: rdp
        ) else {
            sessions.removeValue(forKey: sessionID)
            _ = await rdp.close(timeout: 2)
            throw C05RDPError(.staleEpoch, "connectionEpochRetired", retryable: true)
        }
        rdp.connect()
        let failure = await awaitConnection(rdp)
        if let failure {
            let observedChallenge = rdp.certificateChallenge
            _ = await closeRecord(record, force: true)
            if let challenge = observedChallenge {
                let prompt = Self.prompt(
                    challenge,
                    profileID: profileID,
                    endpointID: endpoint.id,
                    createdAt: Date()
                )
                pendingChallenges[endpoint.id] = prompt
                throw C05RDPError(
                    .certificateConfirmationRequired,
                    "certificateConfirmationRequired",
                    retryable: false,
                    detail: challenge.reason,
                    category: "certificateTrust",
                    stage: "certificate",
                    challenge: prompt
                )
            }
            throw Self.map(failure)
        }
        guard sessions[sessionID] != nil else {
            throw C05RDPError(.cancelled, "rdpConnectCancelled", retryable: true)
        }
        if let challenge = rdp.certificateChallenge {
            let observedChallenge = challenge
            _ = await closeRecord(record, force: true)
            let prompt = Self.prompt(
                observedChallenge,
                profileID: profileID,
                endpointID: endpoint.id,
                createdAt: Date()
            )
            pendingChallenges[endpoint.id] = prompt
            throw C05RDPError(
                .certificateConfirmationRequired,
                "certificateConfirmationRequired",
                retryable: false,
                detail: challenge.reason,
                category: "certificateTrust",
                stage: "certificate",
                challenge: prompt
            )
        }
        pendingChallenges.removeValue(forKey: endpoint.id)
        return snapshot(record)
    }

    public func status(sessionID: UUID, owner: C05RemoteOwner) throws -> C05RDPSessionSnapshot {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RDPError(.sessionNotFound, "rdpSessionNotFound")
        }
        return snapshot(record)
    }

    public func input(
        sessionID: UUID,
        events: [RDPFloeInputEvent],
        owner: C05RemoteOwner
    ) async throws -> C05RDPInputAcceptance {
        try requireOwner(owner)
        guard var record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RDPError(.sessionNotFound, "rdpSessionNotFound")
        }
        guard !events.isEmpty, events.count <= C05RDPWire.maximumInputEvents else {
            throw C05RDPError(.inputInvalid, "rdpInputBatchTooLarge")
        }
        var textBytes = 0
        for event in events {
            if case .text(let text) = event { textBytes += text.utf8.count }
        }
        guard textBytes <= C05RDPWire.maximumTextBytes else {
            throw C05RDPError(.inputInvalid, "rdpTextTooLarge")
        }
        do {
            try record.session.send(events)
        } catch let failure as RDPFloeFailure {
            throw Self.map(failure)
        } catch {
            throw C05RDPError(.transportFailed, "rdpInputFailed", retryable: true)
        }
        record.lastActivityAt = Date()
        sessions[sessionID] = record
        return C05RDPInputAcceptance(accepted: events.count)
    }

    public func releaseAllInput(sessionID: UUID, owner: C05RemoteOwner) throws {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RDPError(.sessionNotFound, "rdpSessionNotFound")
        }
        record.session.releaseAllInput()
    }

    public func close(
        sessionID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05RDPShutdownReport {
        try requireOwner(owner)
        guard let record = sessions[sessionID] else {
            return C05RDPShutdownReport(sessionID: sessionID, closed: true, complete: true)
        }
        guard sameOwner(record, owner) else {
            throw C05RDPError(.sessionNotFound, "rdpSessionNotFound")
        }
        return await closeRecord(record, force: false)
    }

    public func reset(
        sessionID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05RDPShutdownReport {
        let endpointID = sessions[sessionID]?.endpointID
        let report = try await close(sessionID: sessionID, owner: owner)
        if let endpointID { pendingChallenges.removeValue(forKey: endpointID) }
        return report
    }

    public func rootStop(expectedEpoch: UInt64) async -> C05RDPRootStopReport {
        closedThroughEpoch = max(closedThroughEpoch, expectedEpoch)
        let records = Array(sessions.values)
        var drained = true
        for record in records {
            let report = await closeRecord(record, force: true)
            if !report.complete { drained = false }
        }
        C05RDPFrameBroker.shared.rootStop(expectedEpoch: expectedEpoch)
        pendingChallenges.removeAll()
        return C05RDPRootStopReport(drained: drained, closedSessions: records.count)
    }

    /// Model-tool seam. The caller only receives the live session when the
    /// exact owner token, session and epoch still match; no parallel handle
    /// registry is created.
    public func modelToolSession(
        sessionID: UUID,
        owner: C05RemoteOwner
    ) throws -> any RDPFloeSessionDriving {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RDPError(.sessionNotFound, "rdpSessionNotFound")
        }
        return record.session
    }

    /// Model-tool endpoint projection for the connect resolver. It contains
    /// no credential bodies and only reports the original profile identity.
    public func modelToolEndpoints(
        owner: C05RemoteOwner
    ) async throws -> [(profileID: UUID, endpoint: C05RDPStoredEndpoint)] {
        try requireOwner(owner)
        let store = try store(epoch: owner.nativeEpoch)
        return try store.load().map { ($0.profileID, $0) }
    }

    // MARK: Internal

    private func closeSessions(
        profileID: UUID,
        endpointID: UUID?,
        owner: C05RemoteOwner
    ) async {
        let matches = sessions.values.filter { record in
            record.profileID == profileID
                && (endpointID == nil || record.endpointID == endpointID)
                && sameOwner(record, owner)
        }
        for record in matches {
            _ = await closeRecord(record, force: true)
        }
    }

    private func awaitConnection(_ session: any RDPFloeSessionDriving) async -> RDPFloeFailure? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if Task.isCancelled {
                return RDPFloeFailure(
                    category: .cancelled,
                    stage: .transport,
                    retryable: true,
                    message: "The RDP connection was cancelled."
                )
            }
            switch session.currentState {
            case .connected:
                return nil
            case .failed(let failure):
                return failure
            case .disconnected:
                return RDPFloeFailure(
                    category: .closed,
                    stage: .transport,
                    retryable: true,
                    message: "The RDP connection closed before the session was ready."
                )
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return RDPFloeFailure(
            category: .timedOut,
            stage: .handshake,
            retryable: true,
            message: "RDP connection timed out."
        )
    }

    private func closeRecord(_ record: Record, force: Bool) async -> C05RDPShutdownReport {
        releaseAllInputQuietly(record)
        let closed = await record.session.close(timeout: force ? 2 : 5)
        if closed {
            sessions.removeValue(forKey: record.id)
            C05RDPFrameBroker.shared.unregister(sessionID: record.id)
        }
        return C05RDPShutdownReport(
            sessionID: record.id,
            closed: closed,
            complete: closed
        )
    }

    private func releaseAllInputQuietly(_ record: Record) {
        record.session.releaseAllInput()
    }

    private func resolvePassword(endpoint: C05RDPStoredEndpoint) async throws -> String {
        guard let reference = endpoint.passwordRef else {
            throw C05RDPError(.credentialMissing, "rdpPasswordRequired")
        }
        try Self.validateRDPReference(reference)
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        let data: Data?
        do {
            data = try await credentialReader(opaque)
        } catch let error as C05RemoteError {
            throw map(error)
        } catch {
            throw C05RDPError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
        }
        guard var data = data, !data.isEmpty, data.count <= C05RDPWire.maximumPasswordBytes else {
            throw C05RDPError(.credentialMissing, "rdpPasswordMissing", retryable: false)
        }
        defer { data.resetBytes(in: 0..<data.count) }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw C05RDPError(.credentialInvalid, "rdpPasswordNotUTF8")
        }
        return text
    }

    private func snapshot(_ record: Record) -> C05RDPSessionSnapshot {
        let state = record.session.currentState
        let failure: C05RDPFailureStatus?
        if case .failed(let value) = state {
            failure = C05RDPFailureStatus(
                code: value.category.rawValue,
                message: value.message,
                retryable: value.retryable,
                category: value.category.rawValue,
                stage: value.stage.rawValue,
                fingerprintSHA256: value.fingerprintSHA256
            )
        } else {
            failure = nil
        }
        let size = record.session.framebufferSize
        return C05RDPSessionSnapshot(
            id: record.id,
            profileID: record.profileID,
            endpointID: record.endpointID,
            displayName: record.displayName,
            host: record.host,
            port: record.port,
            username: record.username,
            domain: record.domain,
            state: Self.stateName(state),
            width: size?.width ?? 0,
            height: size?.height ?? 0,
            frameRevision: record.session.latestFrameRevision,
            frameBytes: record.session.latestFrameByteCount,
            approvedFingerprintSHA256: record.approvedFingerprintSHA256,
            certificateChallenge: record.session.certificateChallenge.map {
                Self.prompt(
                    $0,
                    profileID: record.profileID,
                    endpointID: record.endpointID,
                    createdAt: Date()
                )
            },
            createdAt: record.createdAt,
            lastActivityAt: record.lastActivityAt,
            failure: failure
        )
    }

    private static func stateName(_ state: RDPFloeState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .closing: return "closing"
        case .failed: return "failed"
        }
    }

    private func summary(_ detail: C05HostDetail, endpointCount: Int) -> C05RDPHostSummary {
        C05RDPHostSummary(
            id: detail.summary.id,
            displayName: detail.summary.displayName,
            deviceKind: detail.summary.deviceKind,
            isRemoteExecutionEnvironment: detail.summary.isRemoteExecutionEnvironment,
            endpointCount: endpointCount
        )
    }

    private func endpointSummary(_ endpoint: C05RDPStoredEndpoint) -> C05RDPEndpointSummary {
        C05RDPEndpointSummary(
            id: endpoint.id,
            displayName: endpoint.displayName,
            host: endpoint.host,
            port: endpoint.port,
            username: endpoint.username,
            domain: endpoint.domain,
            hasPassword: endpoint.passwordRef != nil,
            approvedFingerprintSHA256: endpoint.approvedFingerprintSHA256,
            passwordRef: endpoint.passwordRef.map {
                C05CredentialReference(
                    keychainAccount: $0.keychainAccount,
                    synchronizable: $0.synchronizable
                )
            }
        )
    }

    private func store(epoch: UInt64) throws -> C05RDPProfileStore {
        do {
            return try profileStoreProvider(epoch)
        } catch let error as C05RDPError {
            throw error
        } catch {
            throw C05RDPError(.coreUnavailable, "rdpStoreUnavailable", retryable: true)
        }
    }

    private func requireOwner(_ owner: C05RemoteOwner) throws {
        do {
            try owner.validate()
        } catch {
            throw C05RDPError(.invalidOwner, "invalidOwner")
        }
        guard !owner.temporary else {
            throw C05RDPError(.invalidOwner, "temporaryOwnerNotAllowed")
        }
        guard owner.nativeEpoch > closedThroughEpoch else {
            throw C05RDPError(.staleEpoch, "staleNativeEpoch", retryable: true)
        }
        let current = readiness()
        guard current.ready, current.epoch == owner.nativeEpoch else {
            throw C05RDPError(.coreUnavailable, "runtimeNotReady", retryable: true)
        }
    }

    private func sameOwner(_ record: Record, _ owner: C05RemoteOwner) -> Bool {
        record.owner.token == owner.token
            && record.owner.nativeEpoch == owner.nativeEpoch
            && record.owner.taskID == owner.taskID
    }

    private func purgeExpiredChallenges(now: Date = Date()) {
        pendingChallenges = pendingChallenges.filter { $0.value.expiresAt > now }
    }

    private static func prompt(
        _ challenge: RDPCertificateChallenge,
        profileID: UUID,
        endpointID: UUID,
        createdAt: Date
    ) -> C05RDPCertificatePrompt {
        C05RDPCertificatePrompt(
            profileID: profileID,
            endpointID: endpointID,
            host: challenge.host,
            port: challenge.port,
            fingerprintSHA256: challenge.fingerprintSHA256,
            subject: challenge.subject,
            notBefore: challenge.notBefore,
            notAfter: challenge.notAfter,
            kind: challenge.kind,
            reason: challenge.reason,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(C05RDPWire.challengeLifetime)
        )
    }

    // MARK: Validation

    private static func validateEndpoint(
        _ endpoint: C05RDPEndpointDraft,
        profileID: UUID
    ) throws -> C05RDPEndpointDraft {
        _ = profileID
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host == endpoint.host, !host.isEmpty, host.utf8.count <= 255,
              !host.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05RDPError(.invalidProfile, "invalidRDPHost")
        }
        guard (1...65535).contains(endpoint.port) else {
            throw C05RDPError(.invalidProfile, "invalidRDPPort")
        }
        let displayName = endpoint.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(displayName.utf8.count) else {
            throw C05RDPError(.invalidProfile, "invalidRDPDisplayName")
        }
        let username = endpoint.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username == endpoint.username, (1...256).contains(username.utf8.count) else {
            throw C05RDPError(.invalidProfile, "invalidRDPUsername")
        }
        let domain = endpoint.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard domain.count <= 256, !domain.unicodeScalars.contains(where: {
            $0.value == 0 || CharacterSet.newlines.contains($0)
        }) else {
            throw C05RDPError(.invalidProfile, "invalidRDPDomain")
        }
        var passwordRef: SecretReference?
        if let reference = endpoint.passwordRef {
            try validateRDPReference(reference)
            passwordRef = reference
        }
        return C05RDPEndpointDraft(
            id: endpoint.id,
            displayName: displayName,
            host: host,
            port: endpoint.port,
            username: username,
            domain: domain,
            passwordRef: passwordRef
        )
    }

    private static func validateRDPReference(_ reference: SecretReference) throws {
        let account = reference.keychainAccount
        guard account.hasPrefix(C05RDPWire.rdpCredentialPrefix),
              account.count <= 256,
              account.unicodeScalars.allSatisfy({
                  $0.value >= 33 && $0.value < 127 && $0.value != 0x2F
              }) else {
            throw C05RDPError(.credentialInvalid, "rdpCredentialNamespaceRequired")
        }
        let suffix = account.dropFirst(C05RDPWire.rdpCredentialPrefix.count)
        guard suffix.hasSuffix(".password"),
              UUID(uuidString: String(suffix.dropLast(".password".count))) != nil else {
            throw C05RDPError(.credentialInvalid, "rdpCredentialAccountShape")
        }
    }

    private static func validatedRDPReference(
        account: String,
        synchronizable: Bool
    ) throws -> SecretReference {
        let reference = SecretReference(keychainAccount: account, synchronizable: synchronizable)
        try validateRDPReference(reference)
        return reference
    }

    static func map(_ error: C05RemoteError) -> C05RDPError {
        let code: C05RDPErrorCode
        switch error.code {
        case .coreUnavailable, .runtimeNotInstalled: code = .coreUnavailable
        case .staleEpoch: code = .staleEpoch
        case .invalidRequest: code = .invalidRequest
        case .unsupportedOperation: code = .unsupportedOperation
        case .invalidOwner: code = .invalidOwner
        case .invalidProfile: code = .invalidProfile
        case .profileNotFound: code = .profileNotFound
        case .profileLimit: code = .profileLimit
        case .profileBusy: code = .profileBusy
        case .credentialMissing: code = .credentialMissing
        case .credentialInvalid: code = .credentialInvalid
        case .gatewayUnavailable: code = .gatewayUnavailable
        case .authenticationFailed: code = .authenticationFailed
        case .hostKeyChallenge, .hostKeyChanged, .challengeNotFound,
             .challengeExpired, .challengeMismatch, .confirmationRequired:
            code = .certificateConfirmationRequired
        case .connectionRefused: code = .connectionRefused
        case .hostNotFound: code = .hostNotFound
        case .timedOut, .timeout: code = .timedOut
        case .networkUnreachable: code = .networkUnreachable
        case .transportFailed: code = .transportFailed
        case .protocolIncompatible: code = .protocolIncompatible
        case .sessionNotFound: code = .sessionNotFound
        case .sessionLimit: code = .sessionLimit
        case .sessionUnavailable: code = .sessionUnavailable
        case .cancelled: code = .cancelled
        case .cleanupIncomplete: code = .cleanupIncomplete
        case .busy: code = .sessionUnavailable
        case .internalFailure: code = .internalFailure
        default: code = .internalFailure
        }
        return C05RDPError(
            code,
            error.reason,
            retryable: error.retryable,
            detail: error.detail,
            category: error.category,
            stage: error.stage
        )
    }

    static func map(_ failure: RDPFloeFailure) -> C05RDPError {
        let code: C05RDPErrorCode
        switch failure.category {
        case .configurationMissing, .runtimeUnavailable: code = .runtimeUnavailable
        case .credentialMissing, .credentialInvalid: code = .credentialMissing
        case .authenticationFailed: code = .authenticationFailed
        case .certificateRequired, .certificateRejected: code = .certificateConfirmationRequired
        case .networkUnreachable: code = .networkUnreachable
        case .connectionRefused: code = .connectionRefused
        case .timedOut: code = .timedOut
        case .handshakeFailed: code = .transportFailed
        case .protocolIncompatible: code = .protocolIncompatible
        case .framebufferTooLarge, .frameUnavailable: code = .transportFailed
        case .frameLeaseLimit: code = .sessionUnavailable
        case .notConnected: code = .sessionNotFound
        case .inputInvalid: code = .inputInvalid
        case .cancelled: code = .cancelled
        case .closed: code = .transportFailed
        }
        return C05RDPError(
            code,
            failure.category.rawValue,
            retryable: failure.retryable,
            detail: failure.message,
            category: failure.category.rawValue,
            stage: failure.stage.rawValue
        )
    }
}

// MARK: - Production wiring

public enum C05RDPProductionWiring {
    public static func profileStore(epoch: UInt64) throws -> C05RDPProfileStore {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C05RDPError(.runtimeUnavailable, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C05RDPError(.staleEpoch, "staleNativeEpoch", retryable: true)
        }
        let root = URL(fileURLWithPath: composition.cluster.identity.root.path)
        return C05RDPProfileStore(
            fileURL: root
                .appendingPathComponent("Floe", isDirectory: true)
                .appendingPathComponent("RDP", isDirectory: true)
                .appendingPathComponent("endpoints-v1.json", isDirectory: false)
        )
    }

    public static let runtimeVersion: @Sendable () -> String = {
        #if os(Android)
        return RDPFloeSession.runtimeVersion
        #else
        return "unavailable"
        #endif
    }

    public static let defaultSessionFactory: C05RDPSessionFactory = { host, port, username, password, domain, fingerprint, width, height in
        #if os(Android)
        return try RDPFloeSession(
            host: host,
            port: port,
            username: username,
            password: password,
            domain: domain,
            approvedFingerprint: fingerprint,
            width: width,
            height: height
        )
        #else
        _ = (host, port, username, password, domain, fingerprint, width, height)
        throw C05RDPError(
            .runtimeUnavailable,
            "rdpRuntimeUnavailable",
            retryable: false,
            detail: "The RDP native runtime is Android-only.",
            category: "configurationMissing",
            stage: "configuration"
        )
        #endif
    }
}
