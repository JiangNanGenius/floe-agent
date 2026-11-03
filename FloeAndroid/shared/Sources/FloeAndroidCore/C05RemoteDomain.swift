// SPDX-License-Identifier: MPL-2.0
//
// C05 — real SSH remote-host domain for the Android host channel.
//
// This file is the Swift authority for host profiles, credentials,
// host-key trust, live sessions, PTYs, bounded exec runs and loopback
// tunnels. It is NOT a model tool and NOT a V3 command: the only caller is
// the trusted App host over `floe.remote/9`.
//
// Reuse boundaries:
//  * transport/profile/fingerprint/exec/forwarding primitives are the
//    Android port of the fixed public FloeSSH donor (Citadel + SwiftNIO);
//  * host/profile/known-host rows use the EXISTING FloePersistence
//    `hosts`/`known_hosts` schema. No new table, column or migration is
//    introduced here;
//  * secrets are resolved and written only through the EXISTING
//    SecretGatewayRegistry/MailboxSecretGateway approved credential store;
//  * live session state is RAM-only. A lost transport is reported as
//    `.unknown` (never "stopped"/"paused") and every local listener is
//    removed when that loss is observed.
//
// Bounds are explicit and constant: 4 sessions, 4 PTYs and 4 exec channels
// per session, 8 tunnels per session, 256 KiB PTY/exec rings, 256 KiB of
// queued input per PTY. These are remote-network resources; they do not
// raise or replace the local Linux engine's own session limits.

import Foundation
import FloeCore
import FloePersistence
import FloeSSH

// MARK: - Wire identity

public enum C05RemoteWire {
    public static let version = 9
    public static let schema = "floe.remote/9"
    /// `floe_bridge_exchange` rejects requests above 65,536 bytes.
    public static let maximumRequestBytes = 65_536
    /// Responses may carry one bounded PTY/exec page plus metadata.
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumProfiles = 64
    public static let maximumSessions = 4
    public static let maximumPTYsPerSession = 4
    public static let maximumExecsPerSession = 4
    public static let maximumTunnelsPerSession = 8
    public static let maximumPTYBytes = 256 * 1_024
    public static let maximumExecBytes = 256 * 1_024
    public static let maximumInputBytes = 256 * 1_024
    public static let maximumInputPackets = 128
    public static let maximumReadBytes = 64 * 1_024
    public static let maximumWriteBytes = 64 * 1_024
    public static let maximumCommandBytes = 8 * 1_024
    public static let maximumSecretBytes = 40 * 1_024
    public static let maximumJumpHops = RemoteHostProfile.maxJumpHops
    public static let challengeLifetime: TimeInterval = 300
    public static let modelTools = false
}

// MARK: - Errors

public enum C05RemoteErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case responseTooLarge
    case invalidOwner
    case invalidProfile
    case profileNotFound
    case profileLimit
    case profileBusy
    case credentialMissing
    case credentialInvalid
    case gatewayUnavailable
    case authenticationFailed
    case hostKeyChallenge
    case hostKeyChanged
    case challengeNotFound
    case challengeExpired
    case challengeMismatch
    case confirmationRequired
    case connectionRefused
    case hostNotFound
    case timedOut
    case networkUnreachable
    case transportFailed
    case protocolIncompatible
    case sessionNotFound
    case sessionLimit
    case sessionUnavailable
    case ptyNotFound
    case ptyLimit
    case execNotFound
    case execLimit
    case execBusy
    case tunnelNotFound
    case tunnelLimit
    case invalidTarget
    case cleanupIncomplete
    case cancelled
    case timeout
    case busy
    case internalFailure
}

public struct C05RemoteError: Error, Sendable, Equatable {
    public let code: C05RemoteErrorCode
    /// Bounded machine-facing reason code. Never prose copied from a remote
    /// service and never a secret.
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let challenge: C05HostKeyChallenge?
    public let category: String?
    public let stage: String?

    public init(
        _ code: C05RemoteErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        challenge: C05HostKeyChallenge? = nil,
        category: String? = nil,
        stage: String? = nil
    ) {
        self.code = code
        self.reason = String((reason ?? code.rawValue).prefix(120))
        self.retryable = retryable
        self.detail = detail.map { String(SecretRedactor.redact($0).prefix(240)) }
        self.challenge = challenge
        self.category = category
        self.stage = stage
    }
}

// MARK: - Owners and challenges

public struct C05RemoteOwner: Sendable, Equatable {
    /// Opaque per-App-controller token. It is a fence, never a grant.
    public let token: String
    public let nativeEpoch: UInt64
    public let taskID: UUID?
    public let temporary: Bool

    public init(token: String, nativeEpoch: UInt64, taskID: UUID? = nil, temporary: Bool = false) {
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.temporary = temporary
    }

    public func validate() throws {
        guard (8...128).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05RemoteError(.invalidOwner, "invalidOwnerToken")
        }
        guard nativeEpoch > 0 else {
            throw C05RemoteError(.invalidOwner, "invalidNativeEpoch")
        }
        if temporary && taskID != nil {
            throw C05RemoteError(.invalidOwner, "temporaryOwnerHasTask")
        }
    }
}

public enum C05HostKeyChallengeKind: String, Sendable, Equatable {
    case firstUse
    case changed
}

public struct C05HostKeyChallenge: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let profileID: UUID
    public let address: String
    public let port: Int
    public let keyType: String
    public let fingerprintSHA256: String
    public let expectedFingerprintSHA256: String?
    public let kind: C05HostKeyChallengeKind
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID,
        profileID: UUID,
        address: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String,
        expectedFingerprintSHA256: String?,
        kind: C05HostKeyChallengeKind,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.address = address
        self.port = port
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.expectedFingerprintSHA256 = expectedFingerprintSHA256
        self.kind = kind
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct C05HostKeyApproval: Sendable, Equatable {
    public let trusted: Bool
    public let changed: Bool
    public let challengeID: UUID
    public let fingerprintSHA256: String?

    public init(trusted: Bool, changed: Bool, challengeID: UUID, fingerprintSHA256: String?) {
        self.trusted = trusted
        self.changed = changed
        self.challengeID = challengeID
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

// MARK: - Profile value surface

public struct C05CredentialReference: Sendable, Equatable {
    public let keychainAccount: String
    public let synchronizable: Bool

    public init(keychainAccount: String, synchronizable: Bool) {
        self.keychainAccount = keychainAccount
        self.synchronizable = synchronizable
    }
}

public struct C05AuthSummary: Sendable, Equatable {
    public let kind: String
    public let keyType: String?
    public let credential: C05CredentialReference?

    public init(kind: String, keyType: String?, credential: C05CredentialReference?) {
        self.kind = kind
        self.keyType = keyType
        self.credential = credential
    }
}

public struct C05JumpSummary: Sendable, Equatable {
    public let address: String
    public let port: Int
    public let user: String
    public let auth: C05AuthSummary

    public init(address: String, port: Int, user: String, auth: C05AuthSummary) {
        self.address = address
        self.port = port
        self.user = user
        self.auth = auth
    }
}

public struct C05VNCEndpointSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let transport: String
    public let host: String
    public let port: Int
    public let passwordRef: C05CredentialReference?

    public init(
        id: UUID, displayName: String, transport: String, host: String, port: Int,
        passwordRef: C05CredentialReference?
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.host = host
        self.port = port
        self.passwordRef = passwordRef
    }
}

public struct C05AuxConnectionSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let kind: String
    public let host: String?
    public let port: Int?
    public let bluetoothPeripheralID: UUID?
    public let bluetoothServiceUUID: String?
    public let bluetoothWriteCharacteristicUUID: String?
    public let bluetoothNotifyCharacteristicUUID: String?
}

public struct C05HostSummary: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let address: String
    public let port: Int
    public let user: String
    public let auth: C05AuthSummary
    public let deviceKind: String
    public let isRemoteExecutionEnvironment: Bool
    public let hostKeyPolicy: String
    public let pinnedFingerprintSHA256: String?
    public let allowsLegacyAlgorithms: Bool
    public let jumpHopCount: Int
    public let vncEndpointCount: Int
    public let auxiliaryConnectionCount: Int
}

public struct C05HostDetail: Sendable, Equatable {
    public let summary: C05HostSummary
    public let jumpChain: [C05JumpSummary]
    public let vncEndpoints: [C05VNCEndpointSummary]
    public let auxiliaryConnections: [C05AuxConnectionSummary]
}

public struct C05HostList: Sendable, Equatable {
    public let hosts: [C05HostSummary]
    public let unreadableProfileIDs: [UUID]
}

// MARK: - Live value surface

public enum C05RemoteSessionState: String, Sendable, Equatable {
    case connected
    case closing
    case unknown
    case closed
}

public enum C05PTYState: String, Sendable, Equatable {
    case running
    case closing
    case closed
    case unknown
}

public enum C05ExecState: String, Sendable, Equatable {
    case running
    case cancelling
    case exited
    case cancelled
    case unknown
}

public enum C05TunnelState: String, Sendable, Equatable {
    case open
    case closing
    case closed
    case unknown
}

public struct C05RemoteSessionSnapshot: Sendable, Equatable {
    public let id: UUID
    public let profileID: UUID
    public let displayName: String
    public let address: String
    public let port: Int
    public let user: String
    public let state: C05RemoteSessionState
    public let transportConnected: Bool
    public let createdAt: Date
    public let lastActivityAt: Date
    public let ptyCount: Int
    public let execCount: Int
    public let tunnelCount: Int
}

public struct C05PTYSnapshot: Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let state: C05PTYState
    public let columns: Int
    public let rows: Int
    public let totalBytes: Int64
    public let rolledOverBytes: Int64
}

public struct C05PTYRead: Sendable, Equatable {
    public let ptyID: UUID
    public let state: C05PTYState
    public let chunks: [Data]
    public let nextCursor: Int64
    public let lostBytes: Int64
    public let totalBytes: Int64
    public let rolledOverBytes: Int64
}

public struct C05ExecChunk: Sendable, Equatable {
    public let channel: String
    public let data: Data
}

public struct C05ExecSnapshot: Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let state: C05ExecState
    public let stdoutBytes: Int64
    public let stderrBytes: Int64
    public let rolledOverBytes: Int64
    public let exitCode: Int32?
    public let remoteOutcomeUnknown: Bool
}

public struct C05ExecRead: Sendable, Equatable {
    public let execID: UUID
    public let snapshot: C05ExecSnapshot
    public let chunks: [C05ExecChunk]
    public let nextCursor: Int64
    public let lostBytes: Int64
}

public struct C05TunnelSnapshot: Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let targetHost: String
    public let targetPort: Int
    public let localHost: String
    public let localPort: UInt16?
    public let state: C05TunnelState
    public let acceptedConnections: Int
    public let activeConnections: Int
    public let bytesToRemote: Int64
    public let bytesFromRemote: Int64
    public let lastErrorCode: String?
}

public struct C05ShutdownReport: Sendable, Equatable {
    public let complete: Bool
    public let sessionID: UUID
    public let closedPTYs: Int
    public let closedExecs: Int
    public let closedTunnels: Int
}

public struct C05RootStopReport: Sendable, Equatable {
    public let drained: Bool
    public let closedSessions: Int
    public let closedPTYs: Int
    public let closedExecs: Int
    public let closedTunnels: Int
}

public struct C05ProfileDeleteReport: Sendable, Equatable {
    public let deleted: Bool
    public let closedSessions: Int
    public let closedTunnels: Int
}

public struct C05RemoteCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let credentialGatewayReady: Bool
    public let maximumProfiles: Int
    public let maximumSessions: Int
    public let maximumPTYsPerSession: Int
    public let maximumExecsPerSession: Int
    public let maximumTunnelsPerSession: Int
    public let maximumJumpHops: Int
    public let supportsPTY: Bool
    public let supportsExec: Bool
    public let supportsTunnels: Bool
    public let supportsLegacyAlgorithms: Bool
    public let modelTools: Bool
}

// MARK: - Persistence seam

/// The narrow persistence surface C05 needs. `RemoteHostStore` conforms
/// directly; focused tests use an in-memory actor.
public protocol C05RemoteHostStoring: Sendable {
    func hosts() async throws -> [RemoteHostStore.StoredHost]
    func host(id: UUID) async throws -> RemoteHostStore.StoredHost?
    func saveHost(_ host: RemoteHostStore.StoredHost) async throws
    func deleteHost(id: UUID) async throws
    func knownHost(address: String, port: Int, keyType: String) async throws -> KnownHostRecord?
    func trust(_ record: KnownHostRecord) async throws
    func touch(id: UUID, at date: Date) async throws
}

extension RemoteHostStore: C05RemoteHostStoring {}

// MARK: - Production wiring

enum C05ProductionWiring {
    static func readiness() -> (ready: Bool, epoch: UInt64?) {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return (false, nil)
        }
        return (true, composition.epoch)
    }

    static func store(epoch: UInt64) throws -> RemoteHostStore {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C05RemoteError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C05RemoteError(.staleEpoch, "staleNativeEpoch")
        }
        return RemoteHostStore(database: composition.cluster.database)
    }

    static func connector(epoch: UInt64) throws -> SSHConnectionService {
        SSHConnectionService(hostStore: try store(epoch: epoch))
    }

    static func opaque(_ reference: SecretReference) -> String {
        SecretGatewayNaming.opaqueReference(for: reference)
    }

    static func readCredential(_ reference: SecretReference) async throws -> Data {
        guard SecretGatewayRegistry.shared.isRegistered else {
            // SSHConnectionService preserves SSHConnectionError across its
            // transport normalization; a raw C05 error would be misclassified
            // as a generic transport failure.
            throw SSHConnectionError.invalidCredential
        }
        do {
            guard let data = try await SecretGatewayRegistry.shared.read(
                reference: opaque(reference)
            ) else {
                throw SSHConnectionError.invalidCredential
            }
            return data
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.invalidCredential
        }
    }

    static func writeCredential(_ opaqueReference: String, _ value: Data) async throws {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C05RemoteError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        try await SecretGatewayRegistry.shared.write(reference: opaqueReference, value: value)
    }

    static func readOpaque(_ opaqueReference: String) async throws -> Data? {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C05RemoteError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        return try await SecretGatewayRegistry.shared.read(reference: opaqueReference)
    }

    static func deleteOpaque(_ opaqueReference: String) async throws {
        guard SecretGatewayRegistry.shared.isRegistered else {
            throw C05RemoteError(.gatewayUnavailable, "credentialGatewayUnavailable")
        }
        try await SecretGatewayRegistry.shared.delete(reference: opaqueReference)
    }
}

// MARK: - Byte ring

/// Bounded byte ring shared by PTYs and exec channels. Chunks are never
/// split: a read returns whole chunks, so a UTF-8 sequence is never cut by
/// the ring (the SSH/NIO layer may still split a code point, exactly as a
/// real PTY can; the terminal emulator is the UTF-8 boundary).
final class C05ByteRing: @unchecked Sendable {
    struct Chunk: Sendable, Equatable {
        let channel: String
        let data: Data
        let start: Int64
    }

    private let lock = NSLock()
    private let capacity: Int
    private let maximumChunks: Int
    private var chunks: [Chunk] = []
    private var bufferedBytes = 0
    private var totalBytes: Int64 = 0
    private var droppedBytes: Int64 = 0

    init(capacity: Int, maximumChunks: Int) {
        self.capacity = max(1, capacity)
        self.maximumChunks = max(1, maximumChunks)
    }

    func append(_ data: Data, channel: String = "stdout") {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let chunk = Chunk(channel: channel, data: data, start: totalBytes)
        chunks.append(chunk)
        bufferedBytes += data.count
        totalBytes += Int64(data.count)
        trimLocked()
    }

    /// Returns whole chunks after `cursor` up to `maxBytes`. If the cursor
    /// points at data already rolled over, `lostBytes` reports the exact
    /// number of bytes the caller missed and `nextCursor` skips them.
    func read(cursor: Int64, maxBytes: Int) -> (chunks: [Chunk], nextCursor: Int64, lostBytes: Int64, totalBytes: Int64, rolledOverBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let requested = max(0, cursor)
        let bufferedStart = chunks.first?.start ?? totalBytes
        let lost = requested < bufferedStart ? bufferedStart - requested : 0
        var position = requested + lost
        var accepted: [Chunk] = []
        var acceptedBytes = 0
        let budget = max(1, min(maxBytes, C05RemoteWire.maximumReadBytes))
        for chunk in chunks {
            let end = chunk.start + Int64(chunk.data.count)
            guard end > position else { continue }
            if !accepted.isEmpty && acceptedBytes + chunk.data.count > budget { break }
            accepted.append(chunk)
            acceptedBytes += chunk.data.count
            position = end
            if acceptedBytes >= budget { break }
        }
        if let last = accepted.last {
            position = last.start + Int64(last.data.count)
        } else {
            position = max(position, bufferedStart)
        }
        if position > totalBytes { position = totalBytes }
        return (accepted, position, lost, totalBytes, droppedBytes)
    }

    var snapshot: (totalBytes: Int64, rolledOverBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (totalBytes, droppedBytes)
    }

    private func trimLocked() {
        while bufferedBytes > capacity || chunks.count > maximumChunks {
            guard !chunks.isEmpty else { break }
            let removed = chunks.removeFirst()
            bufferedBytes -= removed.data.count
            droppedBytes += Int64(removed.data.count)
        }
    }
}

// MARK: - PTY ownership

final class C05PTY: @unchecked Sendable {
    let id: UUID
    let sessionID: UUID
    let ring: C05ByteRing
    private let handle: any SSHSessionPTY
    private let stateLock = NSLock()
    private var state: C05PTYState = .running
    private var pump: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private let columns: Int
    private let rows: Int

    init(sessionID: UUID, handle: any SSHSessionPTY, columns: Int, rows: Int) {
        self.id = UUID()
        self.sessionID = sessionID
        self.handle = handle
        self.columns = columns
        self.rows = rows
        self.ring = C05ByteRing(
            capacity: C05RemoteWire.maximumPTYBytes,
            maximumChunks: 128
        )
        startPump()
    }

    private func startPump() {
        let handle = self.handle
        let ring = self.ring
        pump = Task { [weak self] in
            do {
                for try await data in handle.output {
                    ring.append(data)
                }
                self?.finish(.closed)
            } catch {
                self?.finish(.unknown)
            }
        }
    }

    private func finish(_ next: C05PTYState) {
        stateLock.lock()
        if state == .running || state == .closing {
            // A stream error after an explicit close is the expected channel
            // teardown, not an unknown remote fate.
            state = state == .closing ? .closed : next
        }
        stateLock.unlock()
    }

    var currentState: C05PTYState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    func write(_ data: Data) async throws {
        do {
            try await handle.write(data)
        } catch {
            finish(.unknown)
            throw error
        }
    }

    func resize(columns: Int, rows: Int) async throws {
        do {
            try await handle.resize(columns: columns, rows: rows)
        } catch {
            finish(.unknown)
            throw error
        }
    }

    /// Starts close exactly once. The actual channel teardown is awaited by
    /// `awaitClosed` (or by the owning session after the transport closes).
    func beginClose() {
        stateLock.lock()
        guard state == .running else { stateLock.unlock(); return }
        state = .closing
        stateLock.unlock()
        closeTask = Task { [handle] in
            await handle.close()
        }
    }

    func awaitClosed(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentState == .closed || currentState == .unknown { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return currentState == .closed || currentState == .unknown
    }

    var snapshot: C05PTYSnapshot {
        let values = ring.snapshot
        return C05PTYSnapshot(
            id: id,
            sessionID: sessionID,
            state: currentState,
            columns: columns,
            rows: rows,
            totalBytes: values.totalBytes,
            rolledOverBytes: values.rolledOverBytes
        )
    }
}

// MARK: - Exec ownership

final class C05Exec: @unchecked Sendable {
    let id: UUID
    let sessionID: UUID
    let ring: C05ByteRing
    private let handle: any SSHSessionExec
    private let stateLock = NSLock()
    private var state: C05ExecState = .running
    private var exitCode: Int32?
    private var pump: Task<Void, Never>?
    private var stdoutBytes: Int64 = 0
    private var stderrBytes: Int64 = 0
    private var exitObserved = false

    init(sessionID: UUID, handle: any SSHSessionExec) {
        self.id = UUID()
        self.sessionID = sessionID
        self.handle = handle
        self.ring = C05ByteRing(
            capacity: C05RemoteWire.maximumExecBytes,
            maximumChunks: 256
        )
        startPump()
    }

    private func startPump() {
        let handle = self.handle
        let ring = self.ring
        pump = Task { [weak self] in
            do {
                for try await event in handle.events {
                    switch event {
                    case .stdout(let data):
                        self?.note("stdout", data, ring: ring)
                    case .stderr(let data):
                        self?.note("stderr", data, ring: ring)
                    case .exited(let code):
                        self?.noteExit(code)
                        self?.finish(.exited, exitCode: code)
                    }
                }
                self?.streamEnded()
            } catch {
                self?.streamFailed()
            }
        }
    }

    private func note(_ channel: String, _ data: Data, ring: C05ByteRing) {
        stateLock.lock()
        if channel == "stdout" { stdoutBytes += Int64(data.count) } else { stderrBytes += Int64(data.count) }
        stateLock.unlock()
        ring.append(data, channel: channel)
    }

    private func noteExit(_ code: Int32) {
        stateLock.lock()
        exitObserved = true
        exitCode = code
        stateLock.unlock()
    }

    private func streamEnded() {
        stateLock.lock()
        if state == .cancelling && !exitObserved {
            state = .cancelled
        } else if state == .running || state == .cancelling {
            state = .exited
            if exitCode == nil { exitCode = 0 }
        }
        stateLock.unlock()
    }

    private func streamFailed() {
        stateLock.lock()
        state = state == .cancelling ? .cancelled : .unknown
        stateLock.unlock()
    }

    private func finish(_ next: C05ExecState, exitCode: Int32?) {
        stateLock.lock()
        if state == .running || state == .cancelling {
            state = next
            if let exitCode { self.exitCode = exitCode }
        }
        stateLock.unlock()
    }

    var currentState: C05ExecState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    func cancel() {
        stateLock.lock()
        if state == .running { state = .cancelling }
        stateLock.unlock()
        handle.cancel()
    }

    func awaitFinished(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = currentState
            if value != .running && value != .cancelling { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return currentState != .running && currentState != .cancelling
    }

    var snapshot: C05ExecSnapshot {
        stateLock.lock()
        let state = self.state
        let exitCode = self.exitCode
        let stdout = self.stdoutBytes
        let stderr = self.stderrBytes
        stateLock.unlock()
        return C05ExecSnapshot(
            id: id,
            sessionID: sessionID,
            state: state,
            stdoutBytes: stdout,
            stderrBytes: stderr,
            rolledOverBytes: ring.snapshot.rolledOverBytes,
            exitCode: exitCode,
            remoteOutcomeUnknown: state == .cancelled || state == .unknown
        )
    }
}

// MARK: - Tunnel ownership

final class C05Tunnel: @unchecked Sendable {
    let id: UUID
    let sessionID: UUID
    let targetHost: String
    let targetPort: Int
    private let forwarder: LoopbackSSHForwarder
    private let stateLock = NSLock()
    private var state: C05TunnelState = .open
    private var closeTask: Task<Void, Never>?

    init(sessionID: UUID, targetHost: String, targetPort: Int, forwarder: LoopbackSSHForwarder) {
        self.id = UUID()
        self.sessionID = sessionID
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.forwarder = forwarder
    }

    func beginClose() {
        stateLock.lock()
        guard state == .open || state == .unknown else { stateLock.unlock(); return }
        state = .closing
        stateLock.unlock()
        closeTask = Task { [forwarder] in
            await forwarder.close()
        }
    }

    func close() async {
        beginClose()
        _ = await closeTask?.value
        stateLock.withLock { state = .closed }
    }

    var snapshot: C05TunnelSnapshot {
        let live = forwarder.snapshot
        stateLock.lock()
        if state == .open && !live.isListening {
            state = .unknown
        }
        let current = state
        stateLock.unlock()
        return C05TunnelSnapshot(
            id: id,
            sessionID: sessionID,
            targetHost: targetHost,
            targetPort: targetPort,
            localHost: "127.0.0.1",
            localPort: live.endpoint?.port,
            state: current,
            acceptedConnections: live.acceptedConnections,
            activeConnections: live.activeConnections,
            bytesToRemote: live.bytesToRemote,
            bytesFromRemote: live.bytesFromRemote,
            lastErrorCode: live.lastErrorCode
        )
    }
}

// MARK: - Session ownership

final class C05RemoteSession: @unchecked Sendable {
    let id: UUID
    let profileID: UUID
    let displayName: String
    let address: String
    let port: Int
    let user: String
    let owner: C05RemoteOwner
    let transport: any SSHSessionTransport
    let createdAt: Date
    private let stateLock = NSLock()
    private var state: C05RemoteSessionState = .connected
    private var lastActivityAt: Date
    var ptys: [UUID: C05PTY] = [:]
    var execs: [UUID: C05Exec] = [:]
    var tunnels: [UUID: C05Tunnel] = [:]

    init(
        profileID: UUID,
        displayName: String,
        address: String,
        port: Int,
        user: String,
        owner: C05RemoteOwner,
        transport: any SSHSessionTransport,
        now: Date
    ) {
        self.id = UUID()
        self.profileID = profileID
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.owner = owner
        self.transport = transport
        self.createdAt = now
        self.lastActivityAt = now
    }

    func touch(_ now: Date = Date()) {
        stateLock.lock(); lastActivityAt = now; stateLock.unlock()
    }

    var currentState: C05RemoteSessionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    func setState(_ next: C05RemoteSessionState) {
        stateLock.lock(); state = next; stateLock.unlock()
    }

    var snapshot: C05RemoteSessionSnapshot {
        stateLock.lock()
        let state = self.state
        let activity = self.lastActivityAt
        stateLock.unlock()
        return C05RemoteSessionSnapshot(
            id: id,
            profileID: profileID,
            displayName: displayName,
            address: address,
            port: port,
            user: user,
            state: state,
            transportConnected: transport.isConnected,
            createdAt: createdAt,
            lastActivityAt: activity,
            ptyCount: ptys.count,
            execCount: execs.count,
            tunnelCount: tunnels.count
        )
    }
}

// MARK: - The domain

public actor C05RemoteDomain {
    public static let shared = C05RemoteDomain(
        storeProvider: { epoch -> any C05RemoteHostStoring in
            try C05ProductionWiring.store(epoch: epoch)
        },
        connectorFactory: { epoch -> any SSHTransportConnecting in
            try C05ProductionWiring.connector(epoch: epoch)
        },
        readiness: { C05ProductionWiring.readiness() },
        credentialResolver: { reference in try await C05ProductionWiring.readCredential(reference) },
        credentialWriter: { reference, value in
            try await C05ProductionWiring.writeCredential(reference, value)
        },
        credentialReader: { reference in try await C05ProductionWiring.readOpaque(reference) },
        credentialDeleter: { reference in try await C05ProductionWiring.deleteOpaque(reference) },
        credentialReady: { SecretGatewayRegistry.shared.isRegistered }
    )

    private let storeProvider: @Sendable (UInt64) async throws -> any C05RemoteHostStoring
    private let connectorFactory: @Sendable (UInt64) async throws -> any SSHTransportConnecting
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let credentialResolver: SSHCredentialResolver
    private let credentialWriter: @Sendable (String, Data) async throws -> Void
    private let credentialReader: @Sendable (String) async throws -> Data?
    private let credentialDeleter: @Sendable (String) async throws -> Void
    private let credentialReady: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let forwarderFactory: @Sendable (any SSHSessionTransport, String, Int) async throws -> LoopbackSSHForwarder

    private struct PendingChallenge: Sendable {
        let challenge: C05HostKeyChallenge
        let ownerToken: String
        let epoch: UInt64
    }

    private var sessions: [UUID: C05RemoteSession] = [:]
    private var challenges: [UUID: PendingChallenge] = [:]
    private var closedThroughEpoch: UInt64 = 0

    public init(
        storeProvider: @escaping @Sendable (UInt64) async throws -> any C05RemoteHostStoring,
        connectorFactory: @escaping @Sendable (UInt64) async throws -> any SSHTransportConnecting,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        credentialResolver: @escaping SSHCredentialResolver,
        credentialWriter: @escaping @Sendable (String, Data) async throws -> Void,
        credentialReader: @escaping @Sendable (String) async throws -> Data?,
        credentialDeleter: @escaping @Sendable (String) async throws -> Void,
        credentialReady: @escaping @Sendable () -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date() },
        forwarderFactory: @escaping @Sendable (any SSHSessionTransport, String, Int) async throws -> LoopbackSSHForwarder = { transport, host, port in
            try await LoopbackSSHForwarder.start(session: transport, targetHost: host, targetPort: port)
        }
    ) {
        self.storeProvider = storeProvider
        self.connectorFactory = connectorFactory
        self.readiness = readiness
        self.credentialResolver = credentialResolver
        self.credentialWriter = credentialWriter
        self.credentialReader = credentialReader
        self.credentialDeleter = credentialDeleter
        self.credentialReady = credentialReady
        self.now = now
        self.forwarderFactory = forwarderFactory
    }

    // MARK: Capabilities

    public func capabilities() -> C05RemoteCapabilities {
        let ready = readiness()
        return C05RemoteCapabilities(
            coreReady: ready.ready,
            epoch: ready.epoch,
            credentialGatewayReady: credentialReady(),
            maximumProfiles: C05RemoteWire.maximumProfiles,
            maximumSessions: C05RemoteWire.maximumSessions,
            maximumPTYsPerSession: C05RemoteWire.maximumPTYsPerSession,
            maximumExecsPerSession: C05RemoteWire.maximumExecsPerSession,
            maximumTunnelsPerSession: C05RemoteWire.maximumTunnelsPerSession,
            maximumJumpHops: C05RemoteWire.maximumJumpHops,
            supportsPTY: true,
            supportsExec: true,
            supportsTunnels: true,
            supportsLegacyAlgorithms: true,
            modelTools: false
        )
    }

    // MARK: Profiles

    public func listProfiles(owner: C05RemoteOwner) async throws -> C05HostList {
        try requireOwner(owner)
        let stores = try await stores(epoch: owner.nativeEpoch)
        let rows = try await stores.hosts()
        var hosts: [C05HostSummary] = []
        var unreadable: [UUID] = []
        for row in rows.prefix(C05RemoteWire.maximumProfiles) {
            do {
                let profile = try RemoteHostProfile(stored: row)
                hosts.append(summary(for: profile))
            } catch {
                unreadable.append(row.id)
            }
        }
        return C05HostList(hosts: hosts, unreadableProfileIDs: unreadable)
    }

    public func profileDetail(id: UUID, owner: C05RemoteOwner) async throws -> C05HostDetail {
        try requireOwner(owner)
        let stores = try await stores(epoch: owner.nativeEpoch)
        guard let row = try await stores.host(id: id) else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        let profile: RemoteHostProfile
        do {
            profile = try RemoteHostProfile(stored: row)
        } catch {
            throw C05RemoteError(.invalidProfile, "invalidStoredProfile")
        }
        return detail(for: profile)
    }

    public func saveProfile(_ profile: RemoteHostProfile, owner: C05RemoteOwner) async throws -> C05HostDetail {
        try requireOwner(owner)
        do {
            try profile.validate()
        } catch {
            throw C05RemoteError(.invalidProfile, "invalidProfile", detail: error.localizedDescription)
        }
        if case .pinned(let fingerprint) = profile.hostKeyPolicy,
           !SSHHostKeyFingerprint.isValid(fingerprint) {
            throw C05RemoteError(.invalidProfile, "invalidPinnedFingerprint")
        }
        let stores = try await stores(epoch: owner.nativeEpoch)
        if try await stores.host(id: profile.id) == nil,
           try await stores.hosts().count >= C05RemoteWire.maximumProfiles {
            throw C05RemoteError(.profileLimit, "profileLimitReached")
        }
        try await verifyCredentials(profile: profile)
        try await stores.saveHost(profile.storedHost())
        return detail(for: profile)
    }

    public func deleteProfile(id: UUID, owner: C05RemoteOwner) async throws -> C05ProfileDeleteReport {
        try requireOwner(owner)
        let stores = try await stores(epoch: owner.nativeEpoch)
        guard let row = try await stores.host(id: id) else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        var closedSessions = 0
        var closedTunnels = 0
        let ids = sessions.filter { $0.value.profileID == id }.map { $0.key }
        for sessionID in ids {
            let report = await shutdownSession(id: sessionID)
            guard report.complete else {
                throw C05RemoteError(.cleanupIncomplete, "profileSessionCleanupIncomplete", retryable: true)
            }
            closedSessions += 1
            closedTunnels += report.closedTunnels
        }
        // Best-effort removal of this profile's own credential references
        // after the row is gone. A gateway refusal must not resurrect the
        // deleted profile; the App's privacy clear remains the global sweep.
        if let profile = try? RemoteHostProfile(stored: row) {
            var references: [SecretReference] = []
            if let reference = profile.auth.secretReference { references.append(reference) }
            references.append(contentsOf: profile.jumpChain.compactMap { $0.auth.secretReference })
            for reference in references {
                try? await credentialDeleter(
                    SecretGatewayNaming.opaqueReference(for: reference))
            }
        }
        try await stores.deleteHost(id: id)
        challenges = challenges.filter { $0.value.challenge.profileID != id }
        return C05ProfileDeleteReport(
            deleted: true,
            closedSessions: closedSessions,
            closedTunnels: closedTunnels
        )
    }

    // MARK: Credentials

    public func saveCredential(
        account: String,
        synchronizable: Bool,
        secret: Data,
        owner: C05RemoteOwner
    ) async throws -> C05CredentialReference {
        try requireOwner(owner)
        let reference = try validatedReference(account: account, synchronizable: synchronizable)
        guard !secret.isEmpty, secret.count <= C05RemoteWire.maximumSecretBytes else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialSize")
        }
        let opaque = SecretGatewayNaming.opaqueReference(for: reference)
        do {
            try await credentialWriter(opaque, secret)
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
        let value = try validatedReference(
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
        let value = try validatedReference(
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

    // MARK: Host keys

    public func listHostKeyChallenges(owner: C05RemoteOwner) throws -> [C05HostKeyChallenge] {
        try requireOwner(owner)
        purgeExpiredChallenges()
        return challenges.values
            .filter { $0.ownerToken == owner.token && $0.epoch == owner.nativeEpoch }
            .map(\.challenge)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func approveHostKey(
        id: UUID,
        accept: Bool,
        replaceChanged: Bool,
        expectedFingerprint: String?,
        owner: C05RemoteOwner
    ) async throws -> C05HostKeyApproval {
        try requireOwner(owner)
        purgeExpiredChallenges()
        guard let pending = challenges[id],
              pending.ownerToken == owner.token,
              pending.epoch == owner.nativeEpoch else {
            throw C05RemoteError(.challengeNotFound, "hostKeyChallengeNotFound")
        }
        if now() >= pending.challenge.expiresAt {
            challenges.removeValue(forKey: id)
            throw C05RemoteError(.challengeExpired, "hostKeyChallengeExpired")
        }
        guard accept else {
            challenges.removeValue(forKey: id)
            return C05HostKeyApproval(
                trusted: false,
                changed: pending.challenge.kind == .changed,
                challengeID: id,
                fingerprintSHA256: nil
            )
        }
        if pending.challenge.kind == .changed {
            guard replaceChanged else {
                throw C05RemoteError(.confirmationRequired, "replaceChangedKeyNotConfirmed")
            }
            if let expectedFingerprint {
                guard SSHHostKeyFingerprint.normalize(expectedFingerprint)
                        == SSHHostKeyFingerprint.normalize(
                            pending.challenge.expectedFingerprintSHA256 ?? "") else {
                    throw C05RemoteError(.challengeMismatch, "expectedFingerprintMismatch")
                }
            }
        }

        let stores = try await stores(epoch: owner.nativeEpoch)
        try await stores.trust(KnownHostRecord(
            hostID: pending.challenge.profileID,
            address: pending.challenge.address,
            port: pending.challenge.port,
            keyType: pending.challenge.keyType,
            fingerprintSHA256: pending.challenge.fingerprintSHA256
        ))

        // A pinned profile must stay coherent after an explicit replacement.
        if pending.challenge.kind == .changed,
           let row = try await stores.host(id: pending.challenge.profileID) {
            var profile = try? RemoteHostProfile(stored: row)
            if let policy = profile?.hostKeyPolicy, case .pinned = policy {
                profile?.hostKeyPolicy = .pinned(
                    fingerprintSHA256: SSHHostKeyFingerprint.normalize(
                        pending.challenge.fingerprintSHA256))
                if let profile { try await stores.saveHost(profile.storedHost()) }
            }
        }
        challenges.removeValue(forKey: id)
        return C05HostKeyApproval(
            trusted: true,
            changed: pending.challenge.kind == .changed,
            challengeID: id,
            fingerprintSHA256: pending.challenge.fingerprintSHA256
        )
    }

    // MARK: Connect / sessions

    public func connect(profileID: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot {
        try requireOwner(owner)
        guard owner.nativeEpoch > closedThroughEpoch else {
            throw C05RemoteError(.staleEpoch, "connectionEpochRetired")
        }
        let stores = try await stores(epoch: owner.nativeEpoch)
        guard let row = try await stores.host(id: profileID) else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        let profile: RemoteHostProfile
        do {
            profile = try RemoteHostProfile(stored: row)
            try profile.validate()
        } catch {
            throw C05RemoteError(.invalidProfile, "invalidProfile")
        }
        guard profile.auth != .none else {
            throw C05RemoteError(.invalidProfile, "sshNotConfigured")
        }
        // Global cap: one trusted host lane cannot amplify remote channels
        // beyond the declared bound. PTY/exec/tunnel counts are separately
        // bounded per session.
        guard sessions.count < C05RemoteWire.maximumSessions else {
            throw C05RemoteError(.sessionLimit, "sessionLimitReached")
        }
        let connector = try await connectorFactory(owner.nativeEpoch)
        let decision: HostKeyDecisionHandler = { challenge in
            _ = await self.recordChallenge(
                challenge,
                expected: nil,
                kind: .firstUse,
                owner: owner
            )
            return false
        }
        do {
            let transport = try await connector.connectTransport(
                profile: profile,
                credentialResolver: credentialResolver,
                hostKeyDecision: decision
            )
            // A cancelled bridge request or a retired native generation must
            // never leave an unowned live SSH client behind.
            let current = readiness()
            if Task.isCancelled || !current.ready || current.epoch != owner.nativeEpoch
                || owner.nativeEpoch <= closedThroughEpoch {
                await transport.close()
                throw C05RemoteError(.staleEpoch, "connectionEpochRetired", retryable: true)
            }
            let session = C05RemoteSession(
                profileID: profile.id,
                displayName: profile.displayName,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                owner: owner,
                transport: transport,
                now: now()
            )
            sessions[session.id] = session
            return session.snapshot
        } catch let error as SSHConnectionError {
            switch error {
            case .hostKeyRejected(let challenge):
                let recorded = await recordChallenge(
                    challenge,
                    expected: nil,
                    kind: .firstUse,
                    owner: owner
                )
                throw C05RemoteError(
                    .hostKeyChallenge,
                    "hostKeyConfirmationRequired",
                    retryable: false,
                    detail: error.errorDescription,
                    challenge: recorded
                )
            case .hostKeyChanged(let expected, let received, let challenge):
                let recorded = await recordChallenge(
                    challenge,
                    expected: expected,
                    kind: .changed,
                    owner: owner
                )
                throw C05RemoteError(
                    .hostKeyChanged,
                    "hostKeyChanged",
                    retryable: false,
                    detail: "expected and received fingerprints differ",
                    challenge: recorded,
                    category: error.category.rawValue,
                    stage: error.stage.rawValue
                )
            default:
                throw mapped(error)
            }
        } catch let error as C05RemoteError {
            throw error
        } catch is CancellationError {
            throw C05RemoteError(.cancelled, "cancelled", retryable: true)
        } catch {
            throw C05RemoteError(
                .transportFailed,
                "transportFailed",
                retryable: true,
                detail: error.localizedDescription
            )
        }
    }

    public func listSessions(owner: C05RemoteOwner) throws -> [C05RemoteSessionSnapshot] {
        try requireOwner(owner)
        return sessions.values
            .filter { $0.owner.token == owner.token && $0.owner.nativeEpoch == owner.nativeEpoch }
            .map(\.snapshot)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func sessionStatus(id: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot {
        try requireOwner(owner)
        guard let session = sessions[id], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        if session.currentState == .connected && !session.transport.isConnected {
            await degradeSession(session)
        }
        return session.snapshot
    }

    public func closeSession(id: UUID, owner: C05RemoteOwner, force: Bool = false) async throws -> C05ShutdownReport {
        try requireOwner(owner)
        guard let session = sessions[id] else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        if !force && !sameOwner(session, owner) {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        return await shutdownSession(id: id)
    }

    public func cancelAll(owner: C05RemoteOwner) async throws -> C05RootStopReport {
        try requireOwner(owner)
        let ids = sessions.filter { sameOwner($0.value, owner) }.map { $0.key }
        return await drainSessions(ids: ids)
    }

    /// Root retirement is not owner-scoped: every live remote resource must
    /// be fenced before the old native generation goes away.
    public func rootStop(expectedEpoch: UInt64) async -> C05RootStopReport {
        closedThroughEpoch = max(closedThroughEpoch, expectedEpoch)
        challenges.removeAll()
        return await drainSessions(ids: Array(sessions.keys))
    }

    // MARK: PTY

    public func openPTY(
        sessionID: UUID,
        term: String?,
        columns: Int,
        rows: Int,
        owner: C05RemoteOwner
    ) async throws -> C05PTYSnapshot {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        guard session.currentState == .connected, session.transport.isConnected else {
            throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
        }
        guard session.ptys.count < C05RemoteWire.maximumPTYsPerSession else {
            throw C05RemoteError(.ptyLimit, "ptyLimitReached")
        }
        let appliedColumns = min(500, max(20, columns))
        let appliedRows = min(200, max(5, rows))
        let termName = try validatedTerm(term)
        do {
            let handle = try await session.transport.openPTY(
                term: termName,
                columns: appliedColumns,
                rows: appliedRows
            )
            if Task.isCancelled {
                await handle.close()
                throw C05RemoteError(.cancelled, "cancelled", retryable: true)
            }
            guard sessions[sessionID] === session, session.currentState == .connected else {
                await handle.close()
                throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
            }
            let pty = C05PTY(
                sessionID: sessionID,
                handle: handle,
                columns: appliedColumns,
                rows: appliedRows
            )
            session.ptys[pty.id] = pty
            session.touch(now())
            return pty.snapshot
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.transportFailed, "ptyOpenFailed", retryable: true, detail: error.localizedDescription)
        }
    }

    public func readPTY(
        ptyID: UUID,
        cursor: Int64,
        maxBytes: Int,
        owner: C05RemoteOwner
    ) async throws -> C05PTYRead {
        try requireOwner(owner)
        guard let (session, pty) = findPTY(ptyID), sameOwner(session, owner) else {
            throw C05RemoteError(.ptyNotFound, "ptyNotFound")
        }
        if session.currentState == .connected && !session.transport.isConnected {
            await degradeSession(session)
        }
        let read = pty.ring.read(
            cursor: cursor,
            maxBytes: min(C05RemoteWire.maximumReadBytes, max(1, maxBytes))
        )
        session.touch(now())
        return C05PTYRead(
            ptyID: ptyID,
            state: pty.currentState,
            chunks: read.chunks.map(\.data),
            nextCursor: read.nextCursor,
            lostBytes: read.lostBytes,
            totalBytes: read.totalBytes,
            rolledOverBytes: read.rolledOverBytes
        )
    }

    public func writePTY(
        ptyID: UUID,
        data: Data,
        owner: C05RemoteOwner
    ) async throws -> Int {
        try requireOwner(owner)
        guard let (session, pty) = findPTY(ptyID), sameOwner(session, owner) else {
            throw C05RemoteError(.ptyNotFound, "ptyNotFound")
        }
        guard data.count <= C05RemoteWire.maximumWriteBytes else {
            throw C05RemoteError(.invalidRequest, "ptyWriteTooLarge")
        }
        do {
            try await pty.write(data)
            session.touch(now())
            return data.count
        } catch {
            throw C05RemoteError(.transportFailed, "ptyWriteFailed", retryable: true)
        }
    }

    public func resizePTY(
        ptyID: UUID,
        columns: Int,
        rows: Int,
        owner: C05RemoteOwner
    ) async throws -> C05PTYSnapshot {
        try requireOwner(owner)
        guard let (session, pty) = findPTY(ptyID), sameOwner(session, owner) else {
            throw C05RemoteError(.ptyNotFound, "ptyNotFound")
        }
        guard (20...500).contains(columns), (5...200).contains(rows) else {
            throw C05RemoteError(.invalidRequest, "invalidPTYSize")
        }
        do {
            try await pty.resize(columns: columns, rows: rows)
            session.touch(now())
            return pty.snapshot
        } catch {
            throw C05RemoteError(.transportFailed, "ptyResizeFailed", retryable: true)
        }
    }

    public func closePTY(ptyID: UUID, owner: C05RemoteOwner) async throws -> C05ShutdownReport {
        try requireOwner(owner)
        guard let (session, pty) = findPTY(ptyID), sameOwner(session, owner) else {
            throw C05RemoteError(.ptyNotFound, "ptyNotFound")
        }
        pty.beginClose()
        let joined = await pty.awaitClosed(timeout: 4)
        session.ptys.removeValue(forKey: ptyID)
        session.touch(now())
        return C05ShutdownReport(
            complete: joined,
            sessionID: session.id,
            closedPTYs: 1,
            closedExecs: 0,
            closedTunnels: 0
        )
    }

    public func listPTYs(sessionID: UUID, owner: C05RemoteOwner) throws -> [C05PTYSnapshot] {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        return session.ptys.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: Exec

    public func startExec(
        sessionID: UUID,
        command: String,
        owner: C05RemoteOwner
    ) async throws -> C05ExecSnapshot {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        guard session.currentState == .connected, session.transport.isConnected else {
            throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
        }
        guard session.execs.count < C05RemoteWire.maximumExecsPerSession else {
            throw C05RemoteError(.execLimit, "execLimitReached")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= C05RemoteWire.maximumCommandBytes else {
            throw C05RemoteError(.invalidRequest, "invalidCommand")
        }
        do {
            let handle = try await session.transport.openExec(command)
            if Task.isCancelled {
                handle.cancel()
                throw C05RemoteError(.cancelled, "cancelled", retryable: true)
            }
            guard sessions[sessionID] === session, session.currentState == .connected else {
                handle.cancel()
                throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
            }
            let exec = C05Exec(sessionID: sessionID, handle: handle)
            session.execs[exec.id] = exec
            session.touch(now())
            return exec.snapshot
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.transportFailed, "execOpenFailed", retryable: true)
        }
    }

    public func readExec(
        execID: UUID,
        cursor: Int64,
        maxBytes: Int,
        owner: C05RemoteOwner
    ) async throws -> C05ExecRead {
        try requireOwner(owner)
        guard let (session, exec) = findExec(execID), sameOwner(session, owner) else {
            throw C05RemoteError(.execNotFound, "execNotFound")
        }
        let read = exec.ring.read(
            cursor: cursor,
            maxBytes: min(C05RemoteWire.maximumReadBytes, max(1, maxBytes))
        )
        session.touch(now())
        return C05ExecRead(
            execID: execID,
            snapshot: exec.snapshot,
            chunks: read.chunks.map { C05ExecChunk(channel: $0.channel, data: $0.data) },
            nextCursor: read.nextCursor,
            lostBytes: read.lostBytes
        )
    }

    public func cancelExec(execID: UUID, owner: C05RemoteOwner) async throws -> C05ExecSnapshot {
        try requireOwner(owner)
        guard let (session, exec) = findExec(execID), sameOwner(session, owner) else {
            throw C05RemoteError(.execNotFound, "execNotFound")
        }
        exec.cancel()
        _ = await exec.awaitFinished(timeout: 3)
        session.touch(now())
        return exec.snapshot
    }

    public func releaseExec(execID: UUID, owner: C05RemoteOwner) async throws -> Bool {
        try requireOwner(owner)
        guard let (session, exec) = findExec(execID), sameOwner(session, owner) else {
            throw C05RemoteError(.execNotFound, "execNotFound")
        }
        let state = exec.currentState
        guard state != .running && state != .cancelling else {
            throw C05RemoteError(.execBusy, "execStillRunning")
        }
        session.execs.removeValue(forKey: execID)
        return true
    }

    public func listExecs(sessionID: UUID, owner: C05RemoteOwner) throws -> [C05ExecSnapshot] {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        return session.execs.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: Tunnels

    public func openTunnel(
        sessionID: UUID,
        targetHost: String,
        targetPort: Int,
        owner: C05RemoteOwner
    ) async throws -> C05TunnelSnapshot {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        guard session.currentState == .connected, session.transport.isConnected else {
            throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
        }
        guard session.tunnels.count < C05RemoteWire.maximumTunnelsPerSession else {
            throw C05RemoteError(.tunnelLimit, "tunnelLimitReached")
        }
        let host = try validatedTargetHost(targetHost)
        guard (1...65535).contains(targetPort) else {
            throw C05RemoteError(.invalidTarget, "invalidTargetPort")
        }
        do {
            let forwarder = try await forwarderFactory(session.transport, host, targetPort)
            if Task.isCancelled {
                await forwarder.close()
                throw C05RemoteError(.cancelled, "cancelled", retryable: true)
            }
            guard sessions[sessionID] === session, session.currentState == .connected else {
                await forwarder.close()
                throw C05RemoteError(.sessionUnavailable, "sessionNotConnected")
            }
            let tunnel = C05Tunnel(
                sessionID: sessionID,
                targetHost: host,
                targetPort: targetPort,
                forwarder: forwarder
            )
            session.tunnels[tunnel.id] = tunnel
            session.touch(now())
            return tunnel.snapshot
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.transportFailed, "tunnelOpenFailed", retryable: true)
        }
    }

    public func listTunnels(sessionID: UUID, owner: C05RemoteOwner) throws -> [C05TunnelSnapshot] {
        try requireOwner(owner)
        guard let session = sessions[sessionID], sameOwner(session, owner) else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        return session.tunnels.values.map(\.snapshot).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func tunnelStatus(tunnelID: UUID, owner: C05RemoteOwner) throws -> C05TunnelSnapshot {
        try requireOwner(owner)
        guard let (_, tunnel) = findTunnel(tunnelID), let session = sessions[tunnel.sessionID],
              sameOwner(session, owner) else {
            throw C05RemoteError(.tunnelNotFound, "tunnelNotFound")
        }
        return tunnel.snapshot
    }

    public func closeTunnel(tunnelID: UUID, owner: C05RemoteOwner) async throws -> C05TunnelSnapshot {
        try requireOwner(owner)
        guard let (session, tunnel) = findTunnel(tunnelID), sameOwner(session, owner) else {
            throw C05RemoteError(.tunnelNotFound, "tunnelNotFound")
        }
        await tunnel.close()
        session.tunnels.removeValue(forKey: tunnelID)
        session.touch(now())
        return tunnel.snapshot
    }

    // MARK: - Internal lifecycle

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

    private func stores(epoch: UInt64) async throws -> any C05RemoteHostStoring {
        try await storeProvider(epoch)
    }

    private func sameOwner(_ session: C05RemoteSession, _ owner: C05RemoteOwner) -> Bool {
        session.owner.token == owner.token && session.owner.nativeEpoch == owner.nativeEpoch
    }

    private func findPTY(_ id: UUID) -> (C05RemoteSession, C05PTY)? {
        for session in sessions.values {
            if let pty = session.ptys[id] { return (session, pty) }
        }
        return nil
    }

    private func findExec(_ id: UUID) -> (C05RemoteSession, C05Exec)? {
        for session in sessions.values {
            if let exec = session.execs[id] { return (session, exec) }
        }
        return nil
    }

    private func findTunnel(_ id: UUID) -> (C05RemoteSession, C05Tunnel)? {
        for session in sessions.values {
            if let tunnel = session.tunnels[id] { return (session, tunnel) }
        }
        return nil
    }

    private func recordChallenge(
        _ challenge: HostKeyChallenge,
        expected: String?,
        kind: C05HostKeyChallengeKind,
        owner: C05RemoteOwner
    ) async -> C05HostKeyChallenge {
        purgeExpiredChallenges()
        if let existing = challenges.values.first(where: {
            $0.challenge.profileID == challenge.hostID
                && $0.challenge.address == challenge.address
                && $0.challenge.port == challenge.port
                && $0.challenge.keyType == challenge.keyType
                && SSHHostKeyFingerprint.normalize($0.challenge.fingerprintSHA256)
                    == SSHHostKeyFingerprint.normalize(challenge.fingerprintSHA256)
                && $0.challenge.kind == kind
        }) {
            return existing.challenge
        }
        while challenges.count >= 16 {
            guard let oldest = challenges.values.min(by: { $0.challenge.createdAt < $1.challenge.createdAt }) else { break }
            challenges.removeValue(forKey: oldest.challenge.id)
        }
        let created = now()
        let value = C05HostKeyChallenge(
            id: UUID(),
            profileID: challenge.hostID,
            address: challenge.address,
            port: challenge.port,
            keyType: challenge.keyType,
            fingerprintSHA256: challenge.fingerprintSHA256,
            expectedFingerprintSHA256: expected,
            kind: kind,
            createdAt: created,
            expiresAt: created.addingTimeInterval(C05RemoteWire.challengeLifetime)
        )
        challenges[value.id] = PendingChallenge(
            challenge: value,
            ownerToken: owner.token,
            epoch: owner.nativeEpoch
        )
        return value
    }

    private func purgeExpiredChallenges() {
        let current = now()
        challenges = challenges.filter { $0.value.challenge.expiresAt > current }
    }

    private func verifyCredentials(profile: RemoteHostProfile) async throws {
        var references: [SecretReference] = []
        if let reference = profile.auth.secretReference { references.append(reference) }
        references.append(contentsOf: profile.jumpChain.compactMap { $0.auth.secretReference })
        for reference in references {
            _ = try validatedReference(
                account: reference.keychainAccount,
                synchronizable: reference.synchronizable
            )
            let opaque = SecretGatewayNaming.opaqueReference(for: reference)
            do {
                guard try await credentialReader(opaque) != nil else {
                    throw C05RemoteError(.credentialMissing, "credentialMissing")
                }
            } catch let error as C05RemoteError {
                throw error
            } catch {
                throw C05RemoteError(.gatewayUnavailable, "credentialReadFailed", retryable: true)
            }
        }
    }

    private func mapped(_ error: SSHConnectionError) -> C05RemoteError {
        let code: C05RemoteErrorCode
        switch error {
        case .sshNotConfigured: code = .invalidProfile
        case .invalidCredential: code = .credentialMissing
        case .authenticationFailed: code = .authenticationFailed
        case .connectionRefused: code = .connectionRefused
        case .hostNotFound: code = .hostNotFound
        case .timedOut: code = .timedOut
        case .networkUnreachable: code = .networkUnreachable
        case .invalidHostKey, .unsupportedKeyType(_): code = .protocolIncompatible
        case .hostKeyRejected(_): code = .hostKeyChallenge
        case .hostKeyChanged(_, _, _): code = .hostKeyChanged
        case .transport: code = .transportFailed
        }
        return C05RemoteError(
            code,
            code.rawValue,
            retryable: error.retryable,
            detail: error.errorDescription,
            category: error.category.rawValue,
            stage: error.stage.rawValue
        )
    }

    private func degradeSession(_ session: C05RemoteSession) async {
        session.setState(.unknown)
        for tunnel in session.tunnels.values {
            _ = await awaitVoid(timeout: 2) { await tunnel.close() }
        }
    }

    private func shutdownSession(id: UUID) async -> C05ShutdownReport {
        guard let session = sessions.removeValue(forKey: id) else {
            return C05ShutdownReport(
                complete: true,
                sessionID: id,
                closedPTYs: 0,
                closedExecs: 0,
                closedTunnels: 0
            )
        }
        session.setState(.closing)
        let ptys = Array(session.ptys.values)
        let execs = Array(session.execs.values)
        let tunnels = Array(session.tunnels.values)
        for pty in ptys { pty.beginClose() }
        for exec in execs { exec.cancel() }
        for tunnel in tunnels { tunnel.beginClose() }

        var complete = true
        if !(await awaitVoid(timeout: 5) { await session.transport.close() }) {
            complete = false
        }
        for pty in ptys {
            if !(await pty.awaitClosed(timeout: 3)) { complete = false }
        }
        for exec in execs {
            if !(await exec.awaitFinished(timeout: 3)) { complete = false }
        }
        for tunnel in tunnels {
            let closed = await awaitVoid(timeout: 3) { await tunnel.close() }
            if !closed { complete = false }
        }
        session.ptys.removeAll()
        session.execs.removeAll()
        session.tunnels.removeAll()
        if complete {
            session.setState(.closed)
        } else {
            // Keep the exact incomplete owner so a retry can close the
            // remaining listener/channel instead of falsely reporting a
            // drained root.
            session.setState(.closing)
            sessions[id] = session
        }
        return C05ShutdownReport(
            complete: complete,
            sessionID: id,
            closedPTYs: ptys.count,
            closedExecs: execs.count,
            closedTunnels: tunnels.count
        )
    }

    private func drainSessions(ids: [UUID]) async -> C05RootStopReport {
        var complete = true
        var closedSessions = 0
        var closedPTYs = 0
        var closedExecs = 0
        var closedTunnels = 0
        for id in ids {
            let report = await shutdownSession(id: id)
            closedSessions += 1
            closedPTYs += report.closedPTYs
            closedExecs += report.closedExecs
            closedTunnels += report.closedTunnels
            if !report.complete { complete = false }
        }
        return C05RootStopReport(
            drained: complete,
            closedSessions: closedSessions,
            closedPTYs: closedPTYs,
            closedExecs: closedExecs,
            closedTunnels: closedTunnels
        )
    }

    private func awaitVoid(timeout: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0.05, timeout)))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Value helpers

    private func validatedReference(account: String, synchronizable: Bool) throws -> SecretReference {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == account,
              (1...80).contains(account.utf8.count),
              account.hasPrefix("floe.ssh."),
              account.unicodeScalars.allSatisfy({
                  $0.value < 128 && !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialAccount")
        }
        return SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    private func validatedTerm(_ value: String?) throws -> String {
        let term = value ?? "xterm-256color"
        guard (1...32).contains(term.utf8.count),
              term.unicodeScalars.allSatisfy({
                  $0.value < 128 && (CharacterSet.alphanumerics.contains($0)
                      || $0.value == 46 || $0.value == 95 || $0.value == 45)
              }) else {
            throw C05RemoteError(.invalidRequest, "invalidTerminalType")
        }
        return term
    }

    private func validatedTargetHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host == value, !host.isEmpty, host.utf8.count <= 255,
              !host.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05RemoteError(.invalidTarget, "invalidTunnelTarget")
        }
        return host
    }

    private func summary(for profile: RemoteHostProfile) -> C05HostSummary {
        let pinned: String?
        if case .pinned(let fingerprint) = profile.hostKeyPolicy {
            pinned = SSHHostKeyFingerprint.normalize(fingerprint)
        } else {
            pinned = nil
        }
        return C05HostSummary(
            id: profile.id,
            displayName: profile.displayName,
            address: profile.address,
            port: profile.port,
            user: profile.user,
            auth: authSummary(profile.auth),
            deviceKind: profile.deviceKind.rawValue,
            isRemoteExecutionEnvironment: profile.isRemoteExecutionEnvironment,
            hostKeyPolicy: policyString(profile.hostKeyPolicy),
            pinnedFingerprintSHA256: pinned,
            allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
            jumpHopCount: profile.jumpChain.count,
            vncEndpointCount: profile.vncEndpoints.count,
            auxiliaryConnectionCount: profile.auxiliaryConnections.count
        )
    }

    private func detail(for profile: RemoteHostProfile) -> C05HostDetail {
        C05HostDetail(
            summary: summary(for: profile),
            jumpChain: profile.jumpChain.map {
                C05JumpSummary(
                    address: $0.address,
                    port: $0.port,
                    user: $0.user,
                    auth: authSummary($0.auth)
                )
            },
            vncEndpoints: profile.vncEndpoints.map {
                C05VNCEndpointSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    transport: $0.transport.rawValue,
                    host: $0.host,
                    port: $0.port,
                    passwordRef: $0.passwordRef.map {
                        C05CredentialReference(
                            keychainAccount: $0.keychainAccount,
                            synchronizable: $0.synchronizable
                        )
                    }
                )
            },
            auxiliaryConnections: profile.auxiliaryConnections.map {
                C05AuxConnectionSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    kind: $0.kind.rawValue,
                    host: $0.host,
                    port: $0.port,
                    bluetoothPeripheralID: $0.bluetoothPeripheralID,
                    bluetoothServiceUUID: $0.bluetoothServiceUUID,
                    bluetoothWriteCharacteristicUUID: $0.bluetoothWriteCharacteristicUUID,
                    bluetoothNotifyCharacteristicUUID: $0.bluetoothNotifyCharacteristicUUID
                )
            }
        )
    }

    private func authSummary(_ auth: SSHAuthMethod) -> C05AuthSummary {
        C05AuthSummary(
            kind: auth.kind,
            keyType: auth.keyType?.rawValue,
            credential: auth.secretReference.map {
                C05CredentialReference(
                    keychainAccount: $0.keychainAccount,
                    synchronizable: $0.synchronizable
                )
            }
        )
    }

    private func policyString(_ policy: HostKeyPolicy) -> String {
        switch policy {
        case .trustOnFirstUse: "trustOnFirstUse"
        case .pinned: "pinned"
        }
    }
}
