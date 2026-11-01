// SPDX-License-Identifier: MPL-2.0
//
// C05 VNC — Android host authority for real RFB screen sessions.
//
// RoyalVNCKit/FloeVNC own the protocol, authentication, encodings and
// framebuffer. This file owns Android product semantics:
//   * profile -> explicit VNC endpoint -> VNC credential -> real RFB;
//   * optional SSH tunnel through the EXISTING C05 SSH domain;
//   * two independent sessions, explicit owner/native-epoch fencing;
//   * bounded immutable frame leases handed to the JNI binary lane
//     (never base64/JSON framebuffer bodies);
//   * input and close/recovery that never replay queued input into a newer
//     session or epoch.
//
// It is NOT a model tool and NOT a BridgeV3 command. The only callers are the
// trusted App host (`floe.vnc/11`) and the trusted frame JNI ABI.

import Foundation
import FloeCore
import FloeSSH
import FloeVNC

// MARK: - Wire identity

public enum C05VNCWire {
    public static let version = 11
    public static let schema = "floe.vnc/11"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumProfiles = 64
    public static let maximumEndpointsPerProfile = 8
    public static let maximumSessions = 2
    public static let maximumInputEvents = 32
    public static let maximumTextBytes = 4_096
    public static let maximumCredentialBytes = 40 * 1_024
    public static let maximumPasswordBytes = 1_024
    public static let maximumFrameLeases = 8
    public static let maximumFrameMetadataBytes = 4_096
    public static let vncCredentialPrefix = "floe.vnc."
    public static let modelTools = false
}

// MARK: - Value surface

public struct C05VNCStatusFailure: Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let category: String
    public let stage: String

    public init(code: String, message: String, retryable: Bool, category: String, stage: String) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.category = category
        self.stage = stage
    }
}

public struct C05VNCSessionSnapshot: Sendable, Equatable {
    public let id: UUID
    public let profileID: UUID
    public let endpointID: UUID
    public let displayName: String
    public let host: String
    public let port: Int
    public let transport: String
    public let state: String
    public let width: Int
    public let height: Int
    public let frameRevision: UInt64
    public let frameBytes: Int
    public let sshSessionID: UUID?
    public let tunnelID: UUID?
    public let createdAt: Date
    public let lastActivityAt: Date
    public let failure: C05VNCStatusFailure?
}

public struct C05VNCShutdownReport: Sendable, Equatable {
    public let sessionID: UUID
    public let closed: Bool
    public let complete: Bool
    public let closedTunnel: Bool
    public let closedSSHSession: Bool
}

public struct C05VNCRootStopReport: Sendable, Equatable {
    public let drained: Bool
    public let closedSessions: Int
    public let closedTunnels: Int
    public let closedSSHSessions: Int
}

public struct C05VNCEndpointDraft: Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var transport: String
    public var host: String
    public var port: Int
    public var passwordRef: SecretReference?

    public init(
        id: UUID = UUID(),
        displayName: String,
        transport: String,
        host: String,
        port: Int,
        passwordRef: SecretReference? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.host = host
        self.port = port
        self.passwordRef = passwordRef
    }
}

public struct C05VNCProfileDraft: Sendable, Equatable {
    public var id: UUID?
    public var displayName: String
    public var deviceKind: String
    public var endpoints: [C05VNCEndpointDraft]

    public init(id: UUID?, displayName: String, deviceKind: String, endpoints: [C05VNCEndpointDraft]) {
        self.id = id
        self.displayName = displayName
        self.deviceKind = deviceKind
        self.endpoints = endpoints
    }
}

public struct C05VNCInputAcceptance: Sendable, Equatable {
    public let accepted: Int
}

public struct C05VNCCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let credentialGatewayReady: Bool
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
    public let modelTools: Bool
}

// MARK: - SSH seam

/// The VNC domain reuses the real C05 SSH transport and its loopback
/// tunnel/listener lifecycle. Tests inject an in-memory fake; production is
/// the same `C05RemoteDomain.shared` the SSH UI uses.
public protocol C05VNCSSHBridging: Sendable {
    func connect(profileID: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot
    func sessionStatus(id: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot
    func openTunnel(
        sessionID: UUID,
        targetHost: String,
        targetPort: Int,
        owner: C05RemoteOwner
    ) async throws -> C05TunnelSnapshot
    func closeTunnel(tunnelID: UUID, owner: C05RemoteOwner) async throws -> C05TunnelSnapshot
    func closeSession(
        id: UUID,
        owner: C05RemoteOwner,
        force: Bool
    ) async throws -> C05ShutdownReport
    func profileDetail(id: UUID, owner: C05RemoteOwner) async throws -> C05HostDetail
    func saveProfile(_ profile: RemoteHostProfile, owner: C05RemoteOwner) async throws -> C05HostDetail
    func rootStop(expectedEpoch: UInt64) async -> C05RootStopReport
}

extension C05RemoteDomain: C05VNCSSHBridging {}

// MARK: - Frame broker

/// Process-local frame lease table for the trusted JNI lane. It is not a
/// second root/session registry: every entry is a real `VNCFloeSession`
/// owned by `C05VNCDomain`, fenced by the exact native epoch and owner token,
/// and released on close/rootStop. The JNI caller never supplies a path,
/// pointer, digest or framing decision.
internal final class C05VNCFrameBroker: @unchecked Sendable {
    static let shared = C05VNCFrameBroker()

    enum BrokerError: Error, Sendable, Equatable {
        case staleEpoch
        case unknownSession
        case unknownLease
        case leaseLimit
        case noFrame
        case invalidOffset
        case bufferTooSmall
    }

    private struct Entry {
        let ownerToken: String
        let epoch: UInt64
        let session: any VNCFloeSessionDriving
    }

    private struct LeaseEntry {
        let epoch: UInt64
        let session: any VNCFloeSessionDriving
        let lease: VNCFloeFrameLease
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var leases: [String: LeaseEntry] = [:]
    private var closedThroughEpoch: UInt64 = 0

    @discardableResult
    func register(
        sessionID: UUID,
        ownerToken: String,
        epoch: UInt64,
        session: any VNCFloeSessionDriving
    ) -> Bool {
        lock.lock()
        if epoch <= closedThroughEpoch {
            lock.unlock()
            return false
        }
        entries[sessionID] = Entry(ownerToken: ownerToken, epoch: epoch, session: session)
        lock.unlock()
        return true
    }

    func unregister(sessionID: UUID) {
        lock.lock()
        guard let entry = entries.removeValue(forKey: sessionID) else {
            lock.unlock()
            return
        }
        let toRelease = leases.filter { $0.value.session === entry.session }
        for (key, _) in toRelease {
            leases.removeValue(forKey: key)
        }
        lock.unlock()
        for (_, value) in toRelease {
            value.session.releaseFrame(value.lease.id)
        }
    }

    func acquire(
        epoch: UInt64,
        ownerToken: String,
        sessionID: UUID
    ) throws -> (leaseID: String, frame: VNCFloeFrame) {
        lock.lock()
        guard epoch > closedThroughEpoch else {
            lock.unlock()
            throw BrokerError.staleEpoch
        }
        guard let entry = entries[sessionID],
              entry.epoch == epoch,
              entry.ownerToken == ownerToken else {
            lock.unlock()
            throw BrokerError.unknownSession
        }
        guard leases.count < C05VNCWire.maximumFrameLeases else {
            lock.unlock()
            throw BrokerError.leaseLimit
        }
        lock.unlock()

        let lease: VNCFloeFrameLease
        do {
            lease = try entry.session.acquireFrame()
        } catch let failure as VNCFloeFailure {
            if failure.category == .frameUnavailable { throw BrokerError.noFrame }
            if failure.category == .frameLeaseLimit { throw BrokerError.leaseLimit }
            if failure.category == .notConnected { throw BrokerError.unknownSession }
            throw BrokerError.noFrame
        } catch {
            throw BrokerError.noFrame
        }

        lock.lock()
        guard epoch > closedThroughEpoch,
              let current = entries[sessionID],
              current.epoch == epoch,
              current.ownerToken == ownerToken else {
            lock.unlock()
            entry.session.releaseFrame(lease.id)
            throw BrokerError.staleEpoch
        }
        let leaseID = UUID().uuidString
        leases[leaseID] = LeaseEntry(epoch: epoch, session: entry.session, lease: lease)
        lock.unlock()
        return (leaseID, lease.frame)
    }

    func read(epoch: UInt64, leaseID: String, offset: Int, capacity: Int) throws -> Data {
        lock.lock()
        guard epoch > closedThroughEpoch else {
            lock.unlock()
            throw BrokerError.staleEpoch
        }
        guard let entry = leases[leaseID], entry.epoch == epoch else {
            lock.unlock()
            throw BrokerError.unknownLease
        }
        let data = entry.lease.frame.data
        lock.unlock()

        guard offset >= 0, offset <= data.count else { throw BrokerError.invalidOffset }
        guard capacity > 0, capacity <= 65_536 else { throw BrokerError.bufferTooSmall }
        let end = min(data.count, offset + capacity)
        guard end > offset else { return Data() }
        return data.subdata(in: offset..<end)
    }

    func release(epoch: UInt64, leaseID: String) {
        lock.lock()
        guard epoch > closedThroughEpoch,
              let entry = leases.removeValue(forKey: leaseID) else {
            lock.unlock()
            return
        }
        lock.unlock()
        entry.session.releaseFrame(entry.lease.id)
    }

    @discardableResult
    func rootStop(expectedEpoch: UInt64) -> Int {
        lock.lock()
        closedThroughEpoch = max(closedThroughEpoch, expectedEpoch)
        let ownedLeases = leases
        leases.removeAll()
        let ownedEntries = entries
        entries.removeAll()
        lock.unlock()
        for (_, value) in ownedLeases {
            value.session.releaseFrame(value.lease.id)
        }
        for (_, entry) in ownedEntries {
            entry.session.releaseAllInput()
        }
        return ownedEntries.count
    }
}

// MARK: - Session record

private final class C05VNCRecord: @unchecked Sendable {
    let id: UUID
    let profileID: UUID
    let endpointID: UUID
    let displayName: String
    let host: String
    let port: Int
    let transport: String
    let owner: C05RemoteOwner
    let session: any VNCFloeSessionDriving
    let createdAt: Date
    var sshSessionID: UUID?
    var ownsSSHSession: Bool
    var tunnelID: UUID?
    var vncClosed: Bool
    var lastActivityAt: Date

    init(
        id: UUID,
        profileID: UUID,
        endpointID: UUID,
        displayName: String,
        host: String,
        port: Int,
        transport: String,
        owner: C05RemoteOwner,
        session: any VNCFloeSessionDriving,
        sshSessionID: UUID?,
        ownsSSHSession: Bool,
        tunnelID: UUID?
    ) {
        self.id = id
        self.profileID = profileID
        self.endpointID = endpointID
        self.displayName = displayName
        self.host = host
        self.port = port
        self.transport = transport
        self.owner = owner
        self.session = session
        self.createdAt = Date()
        self.sshSessionID = sshSessionID
        self.ownsSSHSession = ownsSSHSession
        self.tunnelID = tunnelID
        self.vncClosed = false
        self.lastActivityAt = Date()
    }
}

// MARK: - Domain

public actor C05VNCDomain {
    public static let shared = C05VNCDomain(
        ssh: C05RemoteDomain.shared,
        readiness: { C05ProductionWiring.readiness() },
        credentialReader: { reference in
            try await C05ProductionWiring.readOpaque(reference)
        },
        credentialWriter: { reference, value in
            try await C05ProductionWiring.writeCredential(reference, value)
        },
        credentialDeleter: { reference in
            try await C05ProductionWiring.deleteOpaque(reference)
        },
        credentialGatewayReady: { SecretGatewayRegistry.shared.isRegistered }
    )

    public typealias SessionFactory = @Sendable (String, UInt16, String?) -> any VNCFloeSessionDriving

    private let ssh: any C05VNCSSHBridging
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let credentialReader: @Sendable (String) async throws -> Data?
    private let credentialWriter: @Sendable (String, Data) async throws -> Void
    private let credentialDeleter: @Sendable (String) async throws -> Void
    private let credentialGatewayReady: @Sendable () -> Bool
    private let sessionFactory: SessionFactory

    private var sessions: [UUID: C05VNCRecord] = [:]
    private var closedThroughEpoch: UInt64 = 0

    public init(
        ssh: any C05VNCSSHBridging,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        credentialReader: @escaping @Sendable (String) async throws -> Data?,
        credentialWriter: @escaping @Sendable (String, Data) async throws -> Void,
        credentialDeleter: @escaping @Sendable (String) async throws -> Void,
        credentialGatewayReady: @escaping @Sendable () -> Bool = { false },
        sessionFactory: @escaping SessionFactory = { host, port, password in
            VNCFloeSession(host: host, port: port, password: password)
        }
    ) {
        self.ssh = ssh
        self.readiness = readiness
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.credentialDeleter = credentialDeleter
        self.credentialGatewayReady = credentialGatewayReady
        self.sessionFactory = sessionFactory
    }

    // MARK: Capabilities

    public func capabilities() -> C05VNCCapabilities {
        let current = readiness()
        return C05VNCCapabilities(
            coreReady: current.ready,
            epoch: current.epoch,
            credentialGatewayReady: credentialGatewayReady(),
            maximumSessions: C05VNCWire.maximumSessions,
            maximumProfiles: C05VNCWire.maximumProfiles,
            maximumEndpointsPerProfile: C05VNCWire.maximumEndpointsPerProfile,
            maximumInputEvents: C05VNCWire.maximumInputEvents,
            maximumTextBytes: C05VNCWire.maximumTextBytes,
            maximumCredentialBytes: C05VNCWire.maximumCredentialBytes,
            maximumFrameBytes: VNCFloeFrameBounds.maximumBytes,
            maximumLeases: C05VNCWire.maximumFrameLeases,
            pixelFormat: VNCFloeFrame.pixelFormat,
            supportsDirect: true,
            supportsSSHTunnel: true,
            supportsPointer: true,
            supportsKeyboard: true,
            supportsWheel: true,
            modelTools: false
        )
    }

    // MARK: Profiles (VNC-only)

    /// Creates or replaces a VNC-only host profile. It deliberately carries
    /// no fake SSH user/address/credential and sets
    /// `isRemoteExecutionEnvironment = false`.
    public func saveVNCOnlyProfile(
        _ draft: C05VNCProfileDraft,
        owner: C05RemoteOwner
    ) async throws -> C05HostDetail {
        try requireOwner(owner)
        let profileName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(profileName.utf8.count), !profileName.isEmpty else {
            throw C05RemoteError(.invalidProfile, "invalidDisplayName")
        }
        guard (1...C05VNCWire.maximumEndpointsPerProfile).contains(draft.endpoints.count) else {
            throw C05RemoteError(.invalidProfile, "invalidVNCEndpoints")
        }
        let deviceKind = RemoteDeviceKind(rawValue: draft.deviceKind) ?? .unspecified
        let endpoints = try draft.endpoints.map { endpoint -> VNCEndpoint in
            guard let transport = VNCTransport(rawValue: endpoint.transport) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCTransport")
            }
            guard transport == .direct else {
                throw C05RemoteError(.invalidProfile, "sshTunnelRequiresSSH")
            }
            let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host == endpoint.host, !host.isEmpty, host.utf8.count <= 255,
                  !host.unicodeScalars.contains(where: {
                      $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCHost")
            }
            guard (1...65535).contains(endpoint.port) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCPort")
            }
            let displayName = endpoint.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(displayName.utf8.count) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCDisplayName")
            }
            if let ref = endpoint.passwordRef {
                try Self.validateVNCReference(ref)
            }
            return VNCEndpoint(
                id: endpoint.id,
                displayName: displayName,
                transport: transport,
                host: host,
                port: endpoint.port,
                passwordRef: endpoint.passwordRef
            )
        }
        let profile = RemoteHostProfile(
            id: draft.id ?? UUID(),
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
            vncEndpoints: endpoints,
            auxiliaryConnections: []
        )
        do {
            try profile.validate()
        } catch {
            throw C05RemoteError(.invalidProfile, "invalidProfile")
        }
        return try await ssh.saveProfile(profile, owner: owner)
    }

    // MARK: Credentials (VNC namespace only)

    public func saveCredential(
        account: String,
        synchronizable: Bool,
        secret: Data,
        owner: C05RemoteOwner
    ) async throws -> C05CredentialReference {
        try requireOwner(owner)
        let reference = try Self.validatedVNCReference(
            account: account,
            synchronizable: synchronizable
        )
        guard !secret.isEmpty, secret.count <= C05VNCWire.maximumCredentialBytes else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialSize")
        }
        var mutable = secret
        defer { mutable.resetBytes(in: 0..<mutable.count) }
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        do {
            try await credentialWriter(opaque, mutable)
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.gatewayUnavailable, "credentialWriteFailed", retryable: true)
        }
        return C05CredentialReference(
            keychainAccount: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
    }

    public func probeCredential(_ reference: C05CredentialReference) async throws -> Bool {
        let value = try Self.validatedVNCReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
        let opaque = SecretGatewayNaming.opaqueReference(for: value)
        do {
            return try await credentialReader(opaque) != nil
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
        }
    }

    public func deleteCredential(_ reference: C05CredentialReference) async throws {
        let value = try Self.validatedVNCReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
        let opaque = SecretGatewayNaming.opaqueReference(for: value)
        do {
            try await credentialDeleter(opaque)
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.gatewayUnavailable, "credentialDeleteFailed", retryable: true)
        }
    }

    // MARK: Connect

    public func connect(
        profileID: UUID,
        endpointID: UUID?,
        sshSessionID: UUID?,
        owner: C05RemoteOwner
    ) async throws -> C05VNCSessionSnapshot {
        try requireOwner(owner)
        guard sessions.count < C05VNCWire.maximumSessions else {
            throw C05RemoteError(.sessionLimit, "vncSessionLimitReached")
        }
        let detail: C05HostDetail
        do {
            detail = try await ssh.profileDetail(id: profileID, owner: owner)
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        guard !detail.vncEndpoints.isEmpty else {
            throw C05RemoteError(.invalidProfile, "vncEndpointMissing")
        }
        let endpoint: C05VNCEndpointSummary
        if let endpointID {
            guard let found = detail.vncEndpoints.first(where: { $0.id == endpointID }) else {
                throw C05RemoteError(.invalidProfile, "vncEndpointNotFound")
            }
            endpoint = found
        } else {
            endpoint = detail.vncEndpoints[0]
        }
        guard let transport = VNCTransport(rawValue: endpoint.transport) else {
            throw C05RemoteError(.invalidProfile, "invalidVNCTransport")
        }
        guard (1...65535).contains(endpoint.port) else {
            throw C05RemoteError(.invalidProfile, "invalidVNCPort")
        }
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host == endpoint.host, !host.isEmpty, host.utf8.count <= 255 else {
            throw C05RemoteError(.invalidProfile, "invalidVNCHost")
        }

        let password = try await resolvePassword(endpoint: endpoint)
        var sshSession: UUID?
        var ownsSSHSession = false
        var tunnel: C05TunnelSnapshot?
        var targetHost = host
        var targetPort = endpoint.port

        switch transport {
        case .direct:
            break
        case .sshTunnel:
            let sessionID: UUID
            if let sshSessionID {
                let snapshot = try await ssh.sessionStatus(id: sshSessionID, owner: owner)
                guard snapshot.profileID == profileID else {
                    throw C05RemoteError(.invalidTarget, "sshSessionProfileMismatch")
                }
                sessionID = snapshot.id
            } else {
                do {
                    let snapshot = try await ssh.connect(profileID: profileID, owner: owner)
                    sessionID = snapshot.id
                    ownsSSHSession = true
                } catch let error as C05RemoteError where error.code == .hostKeyChallenge ||
                    error.code == .hostKeyChanged {
                    throw error
                } catch let error as C05RemoteError where error.code == .invalidProfile {
                    throw C05RemoteError(
                        .credentialMissing,
                        "sshCredentialsRequired",
                        retryable: false,
                        detail: "The VNC endpoint uses an SSH tunnel, but this host has no SSH credential.",
                        category: "configurationMissing",
                        stage: "configuration"
                    )
                } catch {
                    throw error
                }
            }
            sshSession = sessionID
            do {
                let opened = try await ssh.openTunnel(
                    sessionID: sessionID,
                    targetHost: host,
                    targetPort: endpoint.port,
                    owner: owner
                )
                guard let localPort = opened.localPort, opened.state == .open else {
                    throw C05RemoteError(.transportFailed, "vncTunnelNotReady", retryable: true)
                }
                tunnel = opened
                targetHost = opened.localHost
                targetPort = Int(localPort)
            } catch {
                if ownsSSHSession {
                    _ = try? await ssh.closeSession(id: sessionID, owner: owner, force: true)
                }
                throw error
            }
        }

        guard targetPort > 0, targetPort <= 65535 else {
            if let tunnel {
                _ = try? await ssh.closeTunnel(tunnelID: tunnel.id, owner: owner)
            }
            if ownsSSHSession, let sshSession {
                _ = try? await ssh.closeSession(id: sshSession, owner: owner, force: true)
            }
            throw C05RemoteError(.invalidTarget, "invalidVNCPort")
        }

        let sessionID = UUID()
        let vnc = sessionFactory(targetHost, UInt16(targetPort), password)
        let record = C05VNCRecord(
            id: sessionID,
            profileID: profileID,
            endpointID: endpoint.id,
            displayName: endpoint.displayName,
            host: host,
            port: endpoint.port,
            transport: transport.rawValue,
            owner: owner,
            session: vnc,
            sshSessionID: sshSession,
            ownsSSHSession: ownsSSHSession,
            tunnelID: tunnel?.id
        )
        sessions[sessionID] = record
        let registered = C05VNCFrameBroker.shared.register(
            sessionID: sessionID,
            ownerToken: owner.token,
            epoch: owner.nativeEpoch,
            session: vnc
        )
        guard registered else {
            _ = await closeRecord(record, force: true)
            throw C05RemoteError(.staleEpoch, "connectionEpochRetired", retryable: true)
        }
        vnc.connect()

        let failure = await awaitConnection(vnc)
        if let failure {
            _ = await closeRecord(record, force: true)
            throw Self.map(failure)
        }
        guard sessions[sessionID] != nil else {
            throw C05RemoteError(.cancelled, "vncConnectCancelled", retryable: true)
        }
        return snapshot(record)
    }

    // MARK: Status / input / close

    public func status(sessionID: UUID, owner: C05RemoteOwner) throws -> C05VNCSessionSnapshot {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RemoteError(.sessionNotFound, "vncSessionNotFound")
        }
        return snapshot(record)
    }

    public func input(
        sessionID: UUID,
        events: [VNCFloeInputEvent],
        owner: C05RemoteOwner
    ) async throws -> C05VNCInputAcceptance {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RemoteError(.sessionNotFound, "vncSessionNotFound")
        }
        guard events.count <= C05VNCWire.maximumInputEvents else {
            throw C05RemoteError(.invalidRequest, "vncInputBatchTooLarge")
        }
        var textBytes = 0
        for event in events {
            if case .text(let text) = event {
                textBytes += text.utf8.count
            }
        }
        guard textBytes <= C05VNCWire.maximumTextBytes else {
            throw C05RemoteError(.invalidRequest, "vncTextTooLarge")
        }
        do {
            try record.session.send(events)
        } catch let failure as VNCFloeFailure {
            throw Self.map(failure)
        } catch {
            throw C05RemoteError(.transportFailed, "vncInputFailed", retryable: true)
        }
        record.lastActivityAt = Date()
        return C05VNCInputAcceptance(accepted: events.count)
    }

    public func releaseAllInput(sessionID: UUID, owner: C05RemoteOwner) throws {
        try requireOwner(owner)
        guard let record = sessions[sessionID], sameOwner(record, owner) else {
            throw C05RemoteError(.sessionNotFound, "vncSessionNotFound")
        }
        record.session.releaseAllInput()
        record.lastActivityAt = Date()
    }

    public func close(
        sessionID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05VNCShutdownReport {
        try requireOwner(owner)
        guard let record = sessions[sessionID] else {
            return C05VNCShutdownReport(
                sessionID: sessionID,
                closed: true,
                complete: true,
                closedTunnel: true,
                closedSSHSession: true
            )
        }
        guard sameOwner(record, owner) else {
            throw C05RemoteError(.sessionNotFound, "vncSessionNotFound")
        }
        return await closeRecord(record, force: false)
    }

    public func rootStop(expectedEpoch: UInt64) async -> C05VNCRootStopReport {
        closedThroughEpoch = max(closedThroughEpoch, expectedEpoch)
        let records = Array(sessions.values)
        var drained = true
        var closedTunnels = 0
        var closedSSH = 0
        for record in records {
            let report = await closeRecord(record, force: true)
            if !report.complete { drained = false }
            if report.closedTunnel { closedTunnels += 1 }
            if report.closedSSHSession { closedSSH += 1 }
        }
        C05VNCFrameBroker.shared.rootStop(expectedEpoch: expectedEpoch)
        let sshReport = await ssh.rootStop(expectedEpoch: expectedEpoch)
        return C05VNCRootStopReport(
            drained: drained && sshReport.drained,
            closedSessions: records.count,
            closedTunnels: closedTunnels,
            closedSSHSessions: closedSSH
        )
    }

    // MARK: Internal

    private func awaitConnection(_ session: any VNCFloeSessionDriving) async -> VNCFloeFailure? {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if Task.isCancelled {
                return VNCFloeFailure(
                    category: .cancelled,
                    stage: .transport,
                    retryable: true,
                    message: "The VNC connection was cancelled."
                )
            }
            switch session.currentState {
            case .connected:
                return nil
            case .failed(let failure):
                return failure
            case .disconnected:
                return VNCFloeFailure(
                    category: .closed,
                    stage: .transport,
                    retryable: true,
                    message: "The VNC connection closed before the session was ready."
                )
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func resolvePassword(endpoint: C05VNCEndpointSummary) async throws -> String? {
        guard let reference = endpoint.passwordRef else { return nil }
        let secretReference = try Self.validatedVNCReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
        let opaque = SecretGatewayNaming.opaqueReference(for: secretReference)
        let data: Data?
        do {
            data = try await credentialReader(opaque)
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
        }
        guard var secret = data, !secret.isEmpty else {
            throw C05RemoteError(.credentialMissing, "vncPasswordMissing", retryable: false)
        }
        guard secret.count <= C05VNCWire.maximumPasswordBytes else {
            secret.resetBytes(in: 0..<secret.count)
            throw C05RemoteError(.credentialInvalid, "vncPasswordTooLarge", retryable: false)
        }
        defer { secret.resetBytes(in: 0..<secret.count) }
        guard let value = String(data: secret, encoding: .utf8), !value.isEmpty else {
            throw C05RemoteError(.credentialInvalid, "vncPasswordInvalid", retryable: false)
        }
        return value
    }

    private func snapshot(_ record: C05VNCRecord) -> C05VNCSessionSnapshot {
        let state = record.session.currentState
        let size = record.session.framebufferSize
        let stateValue: String
        var failure: C05VNCStatusFailure?
        switch state {
        case .connected:
            stateValue = "connected"
        case .connecting:
            stateValue = "connecting"
        case .closing:
            stateValue = "closing"
        case .disconnected:
            stateValue = "closed"
        case .failed(let value):
            stateValue = "failed"
            failure = C05VNCStatusFailure(
                code: Self.code(for: value).rawValue,
                message: value.message,
                retryable: value.retryable,
                category: value.category.rawValue,
                stage: value.stage.rawValue
            )
        }
        return C05VNCSessionSnapshot(
            id: record.id,
            profileID: record.profileID,
            endpointID: record.endpointID,
            displayName: record.displayName,
            host: record.host,
            port: record.port,
            transport: record.transport,
            state: stateValue,
            width: size?.0 ?? 0,
            height: size?.1 ?? 0,
            frameRevision: record.session.latestFrameRevision,
            frameBytes: record.session.latestFrameByteCount,
            sshSessionID: record.sshSessionID,
            tunnelID: record.tunnelID,
            createdAt: record.createdAt,
            lastActivityAt: record.lastActivityAt,
            failure: failure
        )
    }

    private func closeRecord(
        _ record: C05VNCRecord,
        force: Bool
    ) async -> C05VNCShutdownReport {
        if !record.vncClosed {
            // Belt-and-braces: the real VNCFloeSession.close() also releases
            // pressed input, and a test/injected session may not. This is
            // idempotent and never throws.
            record.session.releaseAllInput()
            let closed = await record.session.close(timeout: 5)
            record.vncClosed = closed
            if !closed {
                return C05VNCShutdownReport(
                    sessionID: record.id,
                    closed: false,
                    complete: false,
                    closedTunnel: false,
                    closedSSHSession: false
                )
            }
        }
        var tunnelClosed = true
        if let tunnelID = record.tunnelID {
            do {
                _ = try await ssh.closeTunnel(tunnelID: tunnelID, owner: record.owner)
                record.tunnelID = nil
            } catch let error as C05RemoteError where error.code == .tunnelNotFound {
                record.tunnelID = nil
            } catch {
                tunnelClosed = false
            }
        }
        var sshClosed = true
        if record.ownsSSHSession, let sshSessionID = record.sshSessionID {
            do {
                let report = try await ssh.closeSession(
                    id: sshSessionID,
                    owner: record.owner,
                    force: force
                )
                sshClosed = report.complete
                if report.complete {
                    record.sshSessionID = nil
                }
            } catch let error as C05RemoteError where error.code == .sessionNotFound {
                record.sshSessionID = nil
            } catch {
                sshClosed = false
            }
        }
        let complete = tunnelClosed && sshClosed
        if complete {
            C05VNCFrameBroker.shared.unregister(sessionID: record.id)
            sessions.removeValue(forKey: record.id)
        }
        return C05VNCShutdownReport(
            sessionID: record.id,
            closed: true,
            complete: complete,
            closedTunnel: tunnelClosed,
            closedSSHSession: sshClosed
        )
    }

    private func requireOwner(_ owner: C05RemoteOwner) throws {
        try owner.validate()
        let current = readiness()
        guard current.ready else {
            throw C05RemoteError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard current.epoch == owner.nativeEpoch else {
            throw C05RemoteError(.staleEpoch, "staleNativeEpoch")
        }
        guard owner.nativeEpoch > closedThroughEpoch else {
            throw C05RemoteError(.staleEpoch, "connectionEpochRetired")
        }
    }

    private func sameOwner(_ record: C05VNCRecord, _ owner: C05RemoteOwner) -> Bool {
        record.owner.token == owner.token && record.owner.nativeEpoch == owner.nativeEpoch
    }

    private static func validatedVNCReference(
        account: String,
        synchronizable: Bool
    ) throws -> SecretReference {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == account,
              (1...80).contains(account.utf8.count),
              account.hasPrefix(C05VNCWire.vncCredentialPrefix),
              account.unicodeScalars.allSatisfy({
                  $0.value < 128 && !$0.properties.isWhitespace &&
                      !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05RemoteError(.credentialInvalid, "invalidVNCReference")
        }
        return SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    private static func validateVNCReference(_ reference: SecretReference) throws {
        _ = try validatedVNCReference(
            account: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
    }

    private static func code(for failure: VNCFloeFailure) -> C05RemoteErrorCode {
        switch failure.category {
        case .configurationMissing:
            return .invalidProfile
        case .credentialMissing:
            return .credentialMissing
        case .authenticationFailed:
            return .authenticationFailed
        case .networkUnreachable:
            return .networkUnreachable
        case .connectionRefused:
            return .connectionRefused
        case .timedOut:
            return .timedOut
        case .handshakeFailed:
            return .transportFailed
        case .protocolIncompatible:
            return .protocolIncompatible
        case .framebufferTooLarge, .frameUnavailable:
            return .protocolIncompatible
        case .frameLeaseLimit:
            return .busy
        case .notConnected:
            return .sessionUnavailable
        case .inputInvalid:
            return .invalidRequest
        case .cancelled:
            return .cancelled
        case .closed:
            return .sessionNotFound
        }
    }

    private static func map(_ failure: VNCFloeFailure) -> C05RemoteError {
        C05RemoteError(
            code(for: failure),
            failure.category.rawValue,
            retryable: failure.retryable,
            detail: failure.message,
            category: failure.category.rawValue,
            stage: failure.stage.rawValue
        )
    }
}
