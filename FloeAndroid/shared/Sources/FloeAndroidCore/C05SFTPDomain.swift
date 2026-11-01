// SPDX-License-Identifier: MPL-2.0
//
// C05 — real SFTP remote-directory and owned file-transfer domain.
//
// This is the Swift authority for browsing a paired SSH host's filesystem,
// downloading a remote file into a REAL task/project workspace file through
// the existing `WorkspaceFileService` transaction ladder, and uploading an
// App-owned source through a verified remote staging file.
//
// Reuse boundaries:
//  * transport is the existing FloeSSH Citadel/SwiftNIO connection service,
//    host-key store and approved credential gateway; there is no second SSH
//    implementation and no second known-host/credential store;
//  * destination/source paths are validated as owned workspace-relative
//    paths and committed by the existing `WorkspaceFileService`
//    `importUserFile` / `replaceBinaryFile` CAS paths;
//  * remote path strings are untrusted input. They are lexically validated,
//    canonicalized by the server, and never mapped onto the local
//    filesystem;
//  * live lanes/transfers are RAM-only. A lost transport is reported as
//    `.unknown`; every staged file is removed and an existing destination is
//    left untouched.
//
// The host channel `floe.sftp/18` is host-only (no BridgeV3 command, no
// guest/local permission and no model path authority). Model tools that use
// this domain are compiled separately and must pass the ordinary task
// context/approval path.

import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeSSH
import FloeWorkspace
import FloeAndroidWorkspaceTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Wire

public enum C05SFTPWire {
    public static let version = 18
    public static let schema = "floe.sftp/18"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 256 * 1_024
    public static let maximumLanes = 8
    public static let maximumTransfersPerLane = 4
    public static let maximumTransfers = 16
    public static let maximumPathBytes = 4_096
    public static let maximumNameBytes = 255
    public static let maximumDirectoryEntries = 1_000
    public static let maximumPageEntries = 200
    public static let maximumChunkBytes = 32 * 1_024
    public static let maximumReadBytes = 64 * 1_024
    public static let maximumDownloadBytes = 256 * 1_024 * 1_024
    public static let maximumUploadBytes = 256 * 1_024 * 1_024
    public static let maximumLocalVerifyBytes = 256 * 1_024 * 1_024
    public static let maximumRemoteHashBytes = 64 * 1_024 * 1_024
    public static let maximumProjects = 64
    public static let listingCacheLifetime: TimeInterval = 5
    public static let maximumCachedListings = 8
    public static let modelTools = false
}

// MARK: - Errors

public enum C05SFTPErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case invalidOwner
    case invalidProfile
    case profileNotFound
    case credentialMissing
    case credentialInvalid
    case gatewayUnavailable
    case authenticationFailed
    case hostKeyChallenge
    case hostKeyChanged
    case challengeNotFound
    case challengeExpired
    case challengeMismatch
    case connectionRefused
    case hostNotFound
    case timedOut
    case networkUnreachable
    case transportFailed
    case protocolIncompatible
    case unsupportedByServer
    case laneNotFound
    case laneLimit
    case laneUnavailable
    case busy
    case invalidPath
    case pathNotFound
    case permissionDenied
    case destinationExists
    case destinationMissing
    case destinationUnavailable
    case revisionRequired
    case revisionMismatch
    case revisionUnverifiable
    case localConflict
    case transferNotFound
    case transferLimit
    case transferBusy
    case transferMismatch
    case fileTooLarge
    case emptyFile
    case checksumMismatch
    case sizeMismatch
    case remoteFailure
    case cleanupIncomplete
    case cancelled
    case timeout
    case internalFailure
}

public struct C05SFTPError: Error, Sendable, Equatable {
    public let code: C05SFTPErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let challenge: C05HostKeyChallenge?
    /// A recoverable remote backup retained by an uncertain overwrite. It is
    /// a validated remote path, never a local path or secret.
    public let retainedPath: String?

    public init(
        _ code: C05SFTPErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        challenge: C05HostKeyChallenge? = nil,
        retainedPath: String? = nil
    ) {
        self.code = code
        self.reason = String((reason ?? code.rawValue).prefix(120))
        self.retryable = retryable
        self.detail = detail.map { String(SecretRedactor.redact($0).prefix(240)) }
        self.challenge = challenge
        self.retainedPath = retainedPath.map { String($0.prefix(4_096)) }
    }
}

extension C05SFTPError: LocalizedError {
    public var errorDescription: String? {
        detail ?? reason
    }
}

// MARK: - Owned targets

public enum C05SFTPTargetKind: String, Codable, Sendable, Equatable {
    case task
    case project
    case environment
}

/// An explicit App-owned workspace destination/source. The remote path is
/// never translated into a local path; only `relativePath` names a file in
/// the resolved owned root.
public struct C05SFTPOwnedTarget: Sendable, Equatable {
    public let kind: C05SFTPTargetKind
    public let taskID: UUID?
    public let projectID: UUID?
    public let environmentID: String?
    public let relativePath: String

    public init(
        kind: C05SFTPTargetKind,
        taskID: UUID? = nil,
        projectID: UUID? = nil,
        environmentID: String? = nil,
        relativePath: String
    ) {
        self.kind = kind
        self.taskID = taskID
        self.projectID = projectID
        self.environmentID = environmentID
        self.relativePath = relativePath
    }

    public func validate() throws {
        switch kind {
        case .task:
            guard taskID != nil, projectID == nil, environmentID == nil else {
                throw C05SFTPError(.invalidRequest, "invalidTaskTarget")
            }
        case .project:
            guard projectID != nil, taskID == nil, environmentID == nil else {
                throw C05SFTPError(.invalidRequest, "invalidProjectTarget")
            }
        case .environment:
            guard let environmentID, !environmentID.isEmpty,
                  environmentID.utf8.count <= 128,
                  taskID == nil, projectID == nil else {
                throw C05SFTPError(.invalidRequest, "invalidEnvironmentTarget")
            }
        }
        do {
            _ = try WorkspaceRelativePath.validate(relativePath, budgets: .defaults)
        } catch {
            throw C05SFTPError(.invalidPath, "invalidWorkspacePath")
        }
    }
}

public struct C05SFTPOwnedAccess: Sendable {
    public let fileService: WorkspaceFileService
    public let relativePath: String

    public init(fileService: WorkspaceFileService, relativePath: String) {
        self.fileService = fileService
        self.relativePath = relativePath
    }
}

public protocol C05SFTPOwnedRootResolving: Sendable {
    func resolve(
        target: C05SFTPOwnedTarget,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPOwnedAccess
}

// MARK: - Host/project projections

public struct C05SFTPHostOption: Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let address: String
    public let port: Int
    public let user: String
    public let hostKeyKnown: Bool
}

public struct C05SFTPProjectOption: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let revision: String
    public let rootState: String
}

public struct C05SFTPEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let bytes: Int64
    public let modifiedAt: Date?
    public let permissions: UInt32?
    /// Cheap, stable metadata revision (`sftp1:size:mtime:permissions`).
    /// It is NOT a content hash; content-addressed revisions are produced by
    /// `remoteRevision` only when the bounded hash is affordable.
    public let revision: String
}

public struct C05SFTPEntryPage: Sendable, Equatable {
    public let path: String
    public let canonicalPath: String
    public let entries: [C05SFTPEntry]
    public let nextOffset: Int
    public let truncated: Bool
    public let totalEntries: Int
}

public struct C05SFTPLocalRevision: Sendable, Equatable {
    public let exists: Bool
    public let bytes: Int64
    public let sha256: String?
    public let revision: String?
    public let modifiedAt: Date?
}

// MARK: - Lane/transfer projections

public enum C05SFTPLaneState: String, Sendable, Equatable {
    case connected
    case closing
    case unknown
    case closed
}

public struct C05SFTPLaneSnapshot: Sendable, Equatable {
    public let id: UUID
    public let profileID: UUID
    public let displayName: String
    public let address: String
    public let port: Int
    public let user: String
    public let state: C05SFTPLaneState
    public let transportConnected: Bool
    public let homePath: String
    public let createdAt: Date
    public let lastActivityAt: Date
    public let activeTransfers: Int
}

public enum C05SFTPTransferKind: String, Sendable, Equatable {
    case download
    case upload
}

public enum C05SFTPTransferState: String, Sendable, Equatable {
    case running
    case completing
    case completed
    case failed
    case cancelled
}

public struct C05SFTPTransferSnapshot: Sendable, Equatable {
    public let id: UUID
    public let laneID: UUID
    public let kind: C05SFTPTransferKind
    public let remotePath: String
    public let displayName: String
    public let state: C05SFTPTransferState
    public let bytesDone: Int64
    public let totalBytes: Int64
    public let sha256: String?
    public let destination: C05SFTPOwnedTarget?
    public let errorCode: String?
    public let errorReason: String?
    public let createdAt: Date
    public let completedAt: Date?
}

public struct C05SFTPCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let credentialGatewayReady: Bool
    public let maximumLanes: Int
    public let maximumTransfersPerLane: Int
    public let maximumPageEntries: Int
    public let maximumChunkBytes: Int
    public let maximumDownloadBytes: Int
    public let maximumUploadBytes: Int
    public let supportsList: Bool
    public let supportsStat: Bool
    public let supportsRead: Bool
    public let supportsUpload: Bool
    public let supportsDownload: Bool
    public let supportsRemoteHash: Bool
    public let modelTools: Bool
}

public struct C05SFTPRootStopReport: Sendable, Equatable {
    public let drained: Bool
    public let closedLanes: Int
    public let closedTransfers: Int
    public let removedStagingFiles: Int
}

// MARK: - Production root resolution

/// Resolves an explicit task/project (and optionally environment) owner to
/// the SAME guarded workspace service used by ordinary file tools. No first
/// project, temporary directory or bookmark reinterpretation is possible.
public struct C05SFTPProductionRoots: C05SFTPOwnedRootResolving {
    public init() {}

    public func resolve(
        target: C05SFTPOwnedTarget,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPOwnedAccess {
        try target.validate()
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C05SFTPError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == owner.nativeEpoch else {
            throw C05SFTPError(.staleEpoch, "staleNativeEpoch")
        }
        let rootPath = composition.cluster.identity.root.path
        let rootURL: URL
        switch target.kind {
        case .task:
            guard let taskID = target.taskID else {
                throw C05SFTPError(.invalidRequest, "missingTaskID")
            }
            guard let workspaceID = try await composition.cluster.workspaceStore
                    .workspaceID(conversationID: taskID),
                  let record = try await composition.cluster.workspaceStore
                    .workspace(id: workspaceID),
                  let canonical = C01ProjectRootLayout.canonicalRootPath(
                    rootPath: rootPath, record: record, conversationID: taskID) else {
                throw C05SFTPError(.destinationUnavailable, "taskWorkspaceUnavailable")
            }
            if record.kind == .project {
                guard C01ProjectRootLayout.inspectProjectDirectory(
                    rootPath: rootPath, projectID: record.id) == .available else {
                    throw C05SFTPError(.destinationUnavailable, "projectRootUnsafe")
                }
            } else {
                guard WorkspaceNoFollow.kind(canonical) == .directory,
                      let metadata = WorkspaceNoFollow.metadata(canonical),
                      (metadata.mode & 0o7777) == 0o700 else {
                    throw C05SFTPError(.destinationUnavailable, "taskRootUnsafe")
                }
            }
            rootURL = URL(fileURLWithPath: canonical, isDirectory: true)
        case .project:
            guard let projectID = target.projectID else {
                throw C05SFTPError(.invalidRequest, "missingProjectID")
            }
            let detail: C01ProjectDetail
            do {
                detail = try await composition.projectLibrary.get(projectID: projectID)
            } catch {
                throw C05SFTPError(.destinationUnavailable, "projectUnavailable")
            }
            guard detail.rootState == .available else {
                throw C05SFTPError(.destinationUnavailable, "projectRootUnsafe")
            }
            let canonical = C01ProjectRootLayout.projectDirectory(
                rootPath: rootPath, projectID: projectID)
            rootURL = URL(fileURLWithPath: canonical, isDirectory: true)
        case .environment:
            throw C05SFTPError(
                .destinationUnavailable,
                "environmentFileTargetRequiresExplicitResolver",
                retryable: false
            )
        }
        guard WorkspaceNoFollow.kind(rootURL.path) == .directory else {
            throw C05SFTPError(.destinationUnavailable, "ownedRootUnavailable")
        }
        let guardResolver = WorkspacePathGuard(rootURL: rootURL)
        return C05SFTPOwnedAccess(
            fileService: WorkspaceFileService(guard: guardResolver),
            relativePath: target.relativePath
        )
    }
}

/// Example/test seam for environments; production composition does not
/// currently expose an environment file root to this domain, so the default
/// verifier fails closed rather than guessing a directory.
public struct C05SFTPEnvironmentRoots: C05SFTPOwnedRootResolving {
    public typealias RootProvider = @Sendable (String) async throws -> URL?
    private let provider: RootProvider

    public init(provider: @escaping RootProvider) {
        self.provider = provider
    }

    public func resolve(
        target: C05SFTPOwnedTarget,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPOwnedAccess {
        guard target.kind == .environment else {
            return try await C05SFTPProductionRoots().resolve(target: target, owner: owner)
        }
        try target.validate()
        guard let identifier = target.environmentID,
              let root = try await provider(identifier),
              WorkspaceNoFollow.kind(root.path) == .directory else {
            throw C05SFTPError(.destinationUnavailable, "environmentRootUnavailable")
        }
        return C05SFTPOwnedAccess(
            fileService: WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root)
            ),
            relativePath: target.relativePath
        )
    }
}

// MARK: - Production wiring

enum C05SFTPProductionWiring {
    static func readiness() -> (ready: Bool, epoch: UInt64?) {
        C05ProductionWiring.readiness()
    }

    static func store(epoch: UInt64) throws -> RemoteHostStore {
        try C05ProductionWiring.store(epoch: epoch)
    }

    static func connector(epoch: UInt64) throws -> SSHConnectionService {
        try C05ProductionWiring.connector(epoch: epoch)
    }

    static func credential(_ reference: SecretReference) async throws -> Data {
        try await C05ProductionWiring.readCredential(reference)
    }

    static func credentialGatewayReady() -> Bool {
        SecretGatewayRegistry.shared.isRegistered
    }
}

// MARK: - Path grammar

enum C05SFTPPath {
    static func remote(
        _ raw: String,
        home: String,
        allowEmpty: Bool = false
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw, trimmed.utf8.count <= C05SFTPWire.maximumPathBytes,
              !trimmed.contains("\0"), !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05SFTPError(.invalidPath, "invalidRemotePath")
        }
        if trimmed.isEmpty {
            guard allowEmpty else { throw C05SFTPError(.invalidPath, "emptyRemotePath") }
            return try canonicalAbsolute(home)
        }
        let absolute: String
        if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            absolute = home.hasSuffix("/") ? home + trimmed : home + "/" + trimmed
        }
        return try canonicalAbsolute(absolute)
    }

    static func canonicalAbsolute(_ value: String) throws -> String {
        guard value.hasPrefix("/"), value.utf8.count <= C05SFTPWire.maximumPathBytes,
              !value.contains("\0"), !value.contains("\\") else {
            throw C05SFTPError(.invalidPath, "invalidAbsolutePath")
        }
        var components: [String] = []
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(component)
            guard part != ".", !part.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) else {
                throw C05SFTPError(.invalidPath, "invalidPathComponent")
            }
            guard part != ".." else {
                throw C05SFTPError(.invalidPath, "remoteParentTraversalRefused")
            }
            guard part.utf8.count <= C05SFTPWire.maximumNameBytes else {
                throw C05SFTPError(.invalidPath, "remotePathComponentTooLong")
            }
            components.append(part)
        }
        guard !components.isEmpty else { return "/" }
        return "/" + components.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func joined(parent: String, name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    static func displayName(_ path: String) -> String {
        let value = name(path)
        return value.isEmpty ? "file" : String(value.prefix(120))
    }
}

// MARK: - Live lane

private struct C05SFTPCachedListing {
    let entries: [C05SFTPEntry]
    let fetchedAt: Date
    let canonicalPath: String
    let truncated: Bool
}

private final class C05SFTPTransfer: @unchecked Sendable {
    let id = UUID()
    let laneID: UUID
    let kind: C05SFTPTransferKind
    let remotePath: String
    let displayName: String
    let owner: C05RemoteOwner
    let destination: C05SFTPOwnedTarget?
    let createdAt: Date
    private let lock = NSLock()
    private var state: C05SFTPTransferState = .running
    private var bytesDone: Int64 = 0
    private var totalBytes: Int64
    private var sha256: String?
    private var errorCode: String?
    private var errorReason: String?
    private var completedAt: Date?
    private var cancelRequested = false
    var stagingURL: URL?
    var remoteTempPath: String?
    var expectedRevision: String?
    var readHandle: (any SSHSFTPReadHandle)?
    var writeHandle: (any SSHSFTPWriteHandle)?
    var task: Task<Void, Never>?

    init(
        laneID: UUID,
        kind: C05SFTPTransferKind,
        remotePath: String,
        displayName: String,
        owner: C05RemoteOwner,
        destination: C05SFTPOwnedTarget?,
        totalBytes: Int64,
        createdAt: Date
    ) {
        self.laneID = laneID
        self.kind = kind
        self.remotePath = remotePath
        self.displayName = displayName
        self.owner = owner
        self.destination = destination
        self.totalBytes = totalBytes
        self.createdAt = createdAt
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelRequested
    }

    var currentState: C05SFTPTransferState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    var currentBytes: Int64 {
        lock.lock(); defer { lock.unlock() }; return bytesDone
    }

    func requestCancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
    }

    func advance(to value: Int64) {
        lock.lock(); bytesDone = value; lock.unlock()
    }

    func complete(sha256: String?) {
        lock.lock()
        state = .completed
        self.sha256 = sha256
        completedAt = Date()
        lock.unlock()
    }

    func fail(code: C05SFTPErrorCode, reason: String) {
        lock.lock()
        if state == .running || state == .completing {
            state = .failed
            errorCode = code.rawValue
            errorReason = String(reason.prefix(160))
            completedAt = Date()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if state == .running || state == .completing {
            state = .cancelled
            errorCode = C05SFTPErrorCode.cancelled.rawValue
            errorReason = "cancelled"
            completedAt = Date()
        }
        lock.unlock()
    }

    func markCompleting() {
        lock.lock()
        if state == .running { state = .completing }
        lock.unlock()
    }

    var snapshot: C05SFTPTransferSnapshot {
        lock.lock()
        let value = C05SFTPTransferSnapshot(
            id: id,
            laneID: laneID,
            kind: kind,
            remotePath: remotePath,
            displayName: displayName,
            state: state,
            bytesDone: bytesDone,
            totalBytes: totalBytes,
            sha256: sha256,
            destination: destination,
            errorCode: errorCode,
            errorReason: errorReason,
            createdAt: createdAt,
            completedAt: completedAt
        )
        lock.unlock()
        return value
    }
}

private final class C05SFTPLane: @unchecked Sendable {
    let id = UUID()
    let profileID: UUID
    let displayName: String
    let address: String
    let port: Int
    let user: String
    let owner: C05RemoteOwner
    let transport: any SSHSessionTransport
    let channel: any SSHSFTPChannel
    let homePath: String
    let createdAt: Date
    private let lock = NSLock()
    private var state: C05SFTPLaneState = .connected
    private var lastActivityAt: Date
    var transfers: [UUID: C05SFTPTransfer] = [:]
    var listings: [String: C05SFTPCachedListing] = [:]
    var listingOrder: [String] = []
    var readCachePath: String?
    var readCacheHandle: (any SSHSFTPReadHandle)?

    init(
        profileID: UUID,
        displayName: String,
        address: String,
        port: Int,
        user: String,
        owner: C05RemoteOwner,
        transport: any SSHSessionTransport,
        channel: any SSHSFTPChannel,
        homePath: String,
        now: Date
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.owner = owner
        self.transport = transport
        self.channel = channel
        self.homePath = homePath
        self.createdAt = now
        self.lastActivityAt = now
    }

    func touch(_ now: Date = Date()) {
        lock.lock(); lastActivityAt = now; lock.unlock()
    }

    var currentState: C05SFTPLaneState {
        lock.lock(); defer { lock.unlock() }; return state
    }

    func setState(_ value: C05SFTPLaneState) {
        lock.lock(); state = value; lock.unlock()
    }

    var snapshot: C05SFTPLaneSnapshot {
        lock.lock()
        let value = C05SFTPLaneSnapshot(
            id: id,
            profileID: profileID,
            displayName: displayName,
            address: address,
            port: port,
            user: user,
            state: state,
            transportConnected: transport.isConnected && channel.isActive,
            homePath: homePath,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            activeTransfers: transfers.values.filter {
                $0.currentState == .running || $0.currentState == .completing
            }.count
        )
        lock.unlock()
        return value
    }
}

// MARK: - Domain

public actor C05SFTPDomain {
    public static let shared = C05SFTPDomain(
        storeProvider: { epoch in try C05SFTPProductionWiring.store(epoch: epoch) },
        connectorFactory: { epoch in try C05SFTPProductionWiring.connector(epoch: epoch) },
        readiness: { C05SFTPProductionWiring.readiness() },
        credentialResolver: { reference in
            try await C05SFTPProductionWiring.credential(reference)
        },
        credentialReady: { C05SFTPProductionWiring.credentialGatewayReady() },
        rootResolver: C05SFTPProductionRoots()
    )

    private struct PendingChallenge: Sendable {
        let challenge: C05HostKeyChallenge
        let ownerToken: String
        let epoch: UInt64
    }

    private let storeProvider: @Sendable (UInt64) async throws -> any C05RemoteHostStoring
    private let connectorFactory: @Sendable (UInt64) async throws -> any SSHTransportConnecting
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let credentialResolver: SSHCredentialResolver
    private let credentialReady: @Sendable () -> Bool
    private let rootResolver: any C05SFTPOwnedRootResolving
    private let now: @Sendable () -> Date

    private var lanes: [UUID: C05SFTPLane] = [:]
    private var challenges: [UUID: PendingChallenge] = [:]
    private var closedThroughEpoch: UInt64 = 0
    private let stagingRoot: URL

    public init(
        storeProvider: @escaping @Sendable (UInt64) async throws -> any C05RemoteHostStoring,
        connectorFactory: @escaping @Sendable (UInt64) async throws -> any SSHTransportConnecting,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        credentialResolver: @escaping SSHCredentialResolver,
        credentialReady: @escaping @Sendable () -> Bool = { false },
        rootResolver: any C05SFTPOwnedRootResolving = C05SFTPProductionRoots(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeProvider = storeProvider
        self.connectorFactory = connectorFactory
        self.readiness = readiness
        self.credentialResolver = credentialResolver
        self.credentialReady = credentialReady
        self.rootResolver = rootResolver
        self.now = now
        self.stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("C05SFTPStaging", isDirectory: true)
    }

    // MARK: Capabilities

    public func capabilities() -> C05SFTPCapabilities {
        let ready = readiness()
        return C05SFTPCapabilities(
            coreReady: ready.ready,
            epoch: ready.epoch,
            credentialGatewayReady: credentialReady(),
            maximumLanes: C05SFTPWire.maximumLanes,
            maximumTransfersPerLane: C05SFTPWire.maximumTransfersPerLane,
            maximumPageEntries: C05SFTPWire.maximumPageEntries,
            maximumChunkBytes: C05SFTPWire.maximumChunkBytes,
            maximumDownloadBytes: C05SFTPWire.maximumDownloadBytes,
            maximumUploadBytes: C05SFTPWire.maximumUploadBytes,
            supportsList: true,
            supportsStat: true,
            supportsRead: true,
            supportsUpload: true,
            supportsDownload: true,
            supportsRemoteHash: true,
            modelTools: C05SFTPWire.modelTools
        )
    }

    public func currentEpoch() -> UInt64? {
        readiness().epoch
    }

    // MARK: Hosts / projects

    public func listHosts(owner: C05RemoteOwner) async throws -> [C05SFTPHostOption] {
        try requireOwner(owner)
        let stores = try await stores(epoch: owner.nativeEpoch)
        let rows = try await stores.hosts()
        var values: [C05SFTPHostOption] = []
        for row in rows.prefix(C05SFTPWire.maximumProjects) {
            guard let profile = try? RemoteHostProfile(stored: row),
                  profile.auth != .none else { continue }
            values.append(C05SFTPHostOption(
                id: profile.id,
                displayName: profile.displayName,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                hostKeyKnown: {
                    if case .pinned = profile.hostKeyPolicy { return true }
                    return false
                }()
            ))
        }
        return values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    public func listProjects(owner: C05RemoteOwner) async throws -> [C05SFTPProjectOption] {
        try requireOwner(owner)
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == owner.nativeEpoch else {
            throw C05SFTPError(.staleEpoch, "staleNativeEpoch")
        }
        let rows: [C01ProjectRow]
        do {
            rows = try await composition.projectLibrary.list(limit: C05SFTPWire.maximumProjects)
        } catch {
            throw C05SFTPError(.destinationUnavailable, "projectLibraryUnavailable", retryable: true)
        }
        let rootPath = composition.cluster.identity.root.path
        return rows.map { row in
            let state = C01ProjectRootLayout.inspectProjectDirectory(
                rootPath: rootPath, projectID: row.id)
            return C05SFTPProjectOption(
                id: row.id,
                name: row.name,
                revision: row.revision,
                rootState: {
                    switch state {
                    case .available: "available"
                    case .missing: "missing"
                    case .unsafe: "unsafe"
                    }
                }()
            )
        }
    }

    // MARK: Connect

    public func connect(profileID: UUID, owner: C05RemoteOwner) async throws -> C05SFTPLaneSnapshot {
        try requireOwner(owner)
        guard lanes.count < C05SFTPWire.maximumLanes else {
            throw C05SFTPError(.laneLimit, "sftpLaneLimitReached")
        }
        let stores = try await stores(epoch: owner.nativeEpoch)
        guard let row = try await stores.host(id: profileID) else {
            throw C05SFTPError(.profileNotFound, "profileNotFound")
        }
        let profile: RemoteHostProfile
        do {
            profile = try RemoteHostProfile(stored: row)
            try profile.validate()
        } catch {
            throw C05SFTPError(.invalidProfile, "invalidProfile")
        }
        guard profile.auth != .none else {
            throw C05SFTPError(.invalidProfile, "sshNotConfigured")
        }
        let connector = try await connectorFactory(owner.nativeEpoch)
        let decision: HostKeyDecisionHandler = { challenge in
            _ = await self.recordChallenge(
                challenge, expected: nil, kind: .firstUse, owner: owner)
            return false
        }
        do {
            let transport = try await connector.connectTransport(
                profile: profile,
                credentialResolver: credentialResolver,
                hostKeyDecision: decision
            )
            return try await finishConnect(
                profile: profile,
                transport: transport,
                owner: owner
            )
        } catch let error as SSHConnectionError {
            switch error {
            case .hostKeyRejected(let challenge):
                let recorded = await recordChallenge(
                    challenge, expected: nil, kind: .firstUse, owner: owner)
                throw C05SFTPError(
                    .hostKeyChallenge, "hostKeyConfirmationRequired",
                    retryable: false, detail: error.errorDescription,
                    challenge: recorded)
            case .hostKeyChanged(let expected, _, let challenge):
                let recorded = await recordChallenge(
                    challenge, expected: expected, kind: .changed, owner: owner)
                throw C05SFTPError(
                    .hostKeyChanged, "hostKeyChanged", retryable: false,
                    detail: "expected and received fingerprints differ",
                    challenge: recorded)
            default:
                throw mapped(error)
            }
        } catch let error as C05SFTPError {
            throw error
        } catch is CancellationError {
            throw C05SFTPError(.cancelled, "cancelled", retryable: true)
        } catch {
            throw C05SFTPError(
                .transportFailed, "transportFailed", retryable: true,
                detail: error.localizedDescription)
        }
    }

    /// Network-mount seam: opens a lane with the mount-owner's approved
    /// credential lease. The mount adapter is the only caller; no model or
    /// bridge request can use this shape.
    public func openMountLane(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPLaneSnapshot {
        try requireOwner(owner)
        guard lanes.count < C05SFTPWire.maximumLanes else {
            throw C05SFTPError(.laneLimit, "sftpLaneLimitReached")
        }
        let connector = try await connectorFactory(owner.nativeEpoch)
        do {
            let transport = try await connector.connectTransport(
                profile: profile,
                credentialResolver: credentialResolver,
                hostKeyDecision: hostKeyDecision
            )
            return try await finishConnect(
                profile: profile, transport: transport, owner: owner)
        } catch let error as SSHConnectionError {
            switch error {
            case .hostKeyRejected(let challenge):
                let recorded = await recordChallenge(
                    challenge, expected: nil, kind: .firstUse, owner: owner)
                throw C05SFTPError(
                    .hostKeyChallenge, "hostKeyConfirmationRequired",
                    retryable: false, detail: "Trust this SSH host in Remote hosts first.",
                    challenge: recorded)
            case .hostKeyChanged(let expected, _, let challenge):
                let recorded = await recordChallenge(
                    challenge, expected: expected, kind: .changed, owner: owner)
                throw C05SFTPError(
                    .hostKeyChanged, "hostKeyChanged", retryable: false,
                    detail: "Trust this SSH host again in Remote hosts first.",
                    challenge: recorded)
            default:
                throw mapped(error)
            }
        } catch let error as C05SFTPError {
            throw error
        } catch {
            throw C05SFTPError(.transportFailed, "sftpMountConnectFailed", retryable: true)
        }
    }

    private func finishConnect(
        profile: RemoteHostProfile,
        transport: any SSHSessionTransport,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPLaneSnapshot {
        var channel: (any SSHSFTPChannel)?
        do {
            guard let provider = transport as? SSHSFTPTransportProviding else {
                throw C05SFTPError(.unsupportedByServer, "sftpUnsupportedByTransport")
            }
            let opened = try await provider.openSFTPChannel()
            channel = opened
            guard !Task.isCancelled else {
                await opened.close()
                await transport.close()
                throw C05SFTPError(.cancelled, "cancelled", retryable: true)
            }
            let current = readiness()
            guard current.ready, current.epoch == owner.nativeEpoch,
                  owner.nativeEpoch > closedThroughEpoch else {
                await opened.close()
                await transport.close()
                throw C05SFTPError(.staleEpoch, "connectionEpochRetired", retryable: true)
            }
            let home = try await opened.canonicalPath(".")
            let lane = C05SFTPLane(
                profileID: profile.id,
                displayName: profile.displayName,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                owner: owner,
                transport: transport,
                channel: opened,
                homePath: home,
                now: now()
            )
            lanes[lane.id] = lane
            return lane.snapshot
        } catch {
            if let channel { await channel.close() }
            await transport.close()
            throw error
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
            throw C05SFTPError(.challengeNotFound, "hostKeyChallengeNotFound")
        }
        if now() >= pending.challenge.expiresAt {
            challenges.removeValue(forKey: id)
            throw C05SFTPError(.challengeExpired, "hostKeyChallengeExpired")
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
                throw C05SFTPError(.invalidRequest, "replaceChangedKeyNotConfirmed")
            }
            if let expectedFingerprint {
                guard SSHHostKeyFingerprint.normalize(expectedFingerprint)
                        == SSHHostKeyFingerprint.normalize(
                            pending.challenge.expectedFingerprintSHA256 ?? "") else {
                    throw C05SFTPError(.challengeMismatch, "expectedFingerprintMismatch")
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
        if pending.challenge.kind == .changed,
           let row = try await stores.host(id: pending.challenge.profileID),
           var profile = try? RemoteHostProfile(stored: row),
           case .pinned = profile.hostKeyPolicy {
            profile.hostKeyPolicy = .pinned(
                fingerprintSHA256: SSHHostKeyFingerprint.normalize(
                    pending.challenge.fingerprintSHA256))
            try await stores.saveHost(profile.storedHost())
        }
        challenges.removeValue(forKey: id)
        return C05HostKeyApproval(
            trusted: true,
            changed: pending.challenge.kind == .changed,
            challengeID: id,
            fingerprintSHA256: pending.challenge.fingerprintSHA256
        )
    }

    // MARK: Browse

    public func list(
        laneID: UUID,
        path: String,
        offset: Int,
        limit: Int,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPEntryPage {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard lane.currentState == .connected,
              lane.transport.isConnected, lane.channel.isActive else {
            lane.setState(.unknown)
            throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
        }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath, allowEmpty: true)
        let boundedLimit = min(C05SFTPWire.maximumPageEntries, max(1, limit))
        let boundedOffset = min(10_000, max(0, offset))
        let listing = try await listingFor(lane: lane, path: normalized)
        let page = Array(listing.entries.dropFirst(boundedOffset).prefix(boundedLimit))
        let next = min(listing.entries.count, boundedOffset + page.count)
        lane.touch(now())
        return C05SFTPEntryPage(
            path: normalized,
            canonicalPath: listing.canonicalPath,
            entries: page,
            nextOffset: next,
            truncated: next < listing.entries.count || listing.truncated,
            totalEntries: listing.entries.count
        )
    }

    public func laneStatus(
        laneID: UUID,
        owner: C05RemoteOwner
    ) throws -> C05SFTPLaneSnapshot {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        return lane.snapshot
    }

    public func stat(
        laneID: UUID,
        path: String,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPEntry {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard lane.currentState == .connected,
              lane.transport.isConnected, lane.channel.isActive else {
            lane.setState(.unknown)
            throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
        }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        let attributes = try await mapRemote {
            try await lane.channel.stat(path: normalized)
        }
        lane.touch(now())
        return entry(path: normalized, name: C05SFTPPath.name(normalized), attributes: attributes)
    }

    public func readChunk(
        laneID: UUID,
        path: String,
        offset: Int64,
        maxBytes: Int,
        owner: C05RemoteOwner
    ) async throws -> Data {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard offset >= 0 else { throw C05SFTPError(.invalidRequest, "invalidOffset") }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        let bounded = min(C05SFTPWire.maximumReadBytes, max(1, maxBytes))
        let data = try await readFromLane(lane, path: normalized, offset: UInt64(offset), maxBytes: bounded)
        lane.touch(now())
        return data
    }

    /// Adapter-only read path: one dedicated remote handle per call, so
    /// concurrent mounts/import operations can never exchange another
    /// operation's cached handle or offset.
    public func readChunkDirect(
        laneID: UUID,
        path: String,
        offset: Int64,
        maxBytes: Int,
        owner: C05RemoteOwner
    ) async throws -> Data {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard offset >= 0 else { throw C05SFTPError(.invalidRequest, "invalidOffset") }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        let bounded = min(C05SFTPWire.maximumReadBytes, max(1, maxBytes))
        let handle = try await mapRemote {
            try await lane.channel.openRead(path: normalized)
        }
        do {
            var result = Data()
            var cursor = UInt64(offset)
            while result.count < bounded {
                let want = min(C05SFTPWire.maximumChunkBytes, bounded - result.count)
                let chunk = try await mapRemote {
                    try await handle.read(at: cursor, maxBytes: want)
                }
                if chunk.isEmpty { break }
                result.append(chunk)
                cursor += UInt64(chunk.count)
            }
            await handle.close()
            lane.touch(now())
            return result
        } catch {
            await handle.close()
            throw error
        }
    }

    public func remoteRevision(
        laneID: UUID,
        path: String,
        hashContent: Bool,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPEntry {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        let attributes = try await mapRemote {
            try await lane.channel.stat(path: normalized)
        }
        guard !attributes.isDirectory else {
            return entry(path: normalized, name: C05SFTPPath.name(normalized), attributes: attributes)
        }
        if hashContent, attributes.size <= Int64(C05SFTPWire.maximumRemoteHashBytes) {
            let digest = try await hashRemote(lane, path: normalized, size: attributes.size)
            return C05SFTPEntry(
                name: C05SFTPPath.name(normalized),
                path: normalized,
                isDirectory: false,
                isSymbolicLink: attributes.isSymbolicLink,
                bytes: attributes.size,
                modifiedAt: attributes.modifiedAt,
                permissions: attributes.permissions,
                revision: "sha256:\(digest)"
            )
        }
        return entry(path: normalized, name: C05SFTPPath.name(normalized), attributes: attributes)
    }

    public func makeDirectory(
        laneID: UUID,
        path: String,
        owner: C05RemoteOwner
    ) async throws {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        try await mapRemote { try await lane.channel.createDirectory(path: normalized) }
        invalidateListing(lane, path: C05SFTPPath.parent(normalized))
        lane.touch(now())
    }

    // MARK: Local destination revision

    public func destinationRevision(
        target: C05SFTPOwnedTarget,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPLocalRevision {
        try requireOwner(owner)
        let access = try await rootResolver.resolve(target: target, owner: owner)
        return try localRevision(access)
    }

    // MARK: Download

    public func startDownload(
        laneID: UUID,
        remotePath: String,
        destination: C05SFTPOwnedTarget,
        overwrite: Bool,
        expectedRevision: String?,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard lane.currentState == .connected,
              lane.transport.isConnected, lane.channel.isActive else {
            lane.setState(.unknown)
            throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
        }
        guard lane.transfers.count < C05SFTPWire.maximumTransfersPerLane,
              lanes.values.reduce(0, { $0 + $1.transfers.count }) < C05SFTPWire.maximumTransfers else {
            throw C05SFTPError(.transferLimit, "sftpTransferLimitReached")
        }
        let normalized = try C05SFTPPath.remote(remotePath, home: lane.homePath)
        let attributes = try await mapRemote { try await lane.channel.stat(path: normalized) }
        guard !attributes.isDirectory else {
            throw C05SFTPError(.invalidPath, "remotePathIsDirectory")
        }
        guard attributes.size <= Int64(C05SFTPWire.maximumDownloadBytes) else {
            throw C05SFTPError(.fileTooLarge, "downloadExceedsLimit")
        }
        let access = try await rootResolver.resolve(target: destination, owner: owner)
        let local = try localRevision(access)
        try validateOverwritePolicy(
            exists: local.exists,
            overwrite: overwrite,
            expectedRevision: expectedRevision,
            actualRevision: local.revision
        )
        let stage = try createStagingFile()
        let transfer = C05SFTPTransfer(
            laneID: laneID,
            kind: .download,
            remotePath: normalized,
            displayName: C05SFTPPath.displayName(normalized),
            owner: owner,
            destination: destination,
            totalBytes: attributes.size,
            createdAt: now()
        )
        transfer.stagingURL = stage
        lane.transfers[transfer.id] = transfer
        lane.touch(now())
        transfer.task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(
                transferID: transfer.id,
                laneID: laneID,
                access: access,
                expectedRevision: expectedRevision,
                overwrite: overwrite
            )
        }
        return transfer.snapshot
    }

    private func runDownload(
        transferID: UUID,
        laneID: UUID,
        access: C05SFTPOwnedAccess,
        expectedRevision: String?,
        overwrite: Bool
    ) async {
        guard let transfer = transfer(in: laneID, id: transferID),
              let stage = transfer.stagingURL else { return }
        var handle: FileHandle?
        var read: (any SSHSFTPReadHandle)?
        do {
            handle = try openStagingForWriting(stage)
            guard let writer = handle else {
                throw C05SFTPError(.internalFailure, "stagingFileHandleMissing")
            }
            guard let lane = lanes[laneID], lane.channel.isActive else {
                throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
            }
            read = try await mapRemote {
                try await lane.channel.openRead(path: transfer.remotePath)
            }
            var offset: UInt64 = 0
            var hasher = SHA256()
            let total = UInt64(max(Int64(0), transfer.snapshot.totalBytes))
            while offset < total {
                if Task.isCancelled || transfer.isCancelled { throw C05SFTPError.cancelled }
                guard let lane = lanes[laneID], lane.channel.isActive else {
                    throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
                }
                let page = min(
                    C05SFTPWire.maximumReadBytes,
                    Int(min(Int64(total - offset), Int64(C05SFTPWire.maximumReadBytes)))
                )
                guard let reader = read else {
                    throw C05SFTPError(.remoteFailure, "sftpReadHandleUnavailable")
                }
                let chunk = try await mapRemote {
                    try await reader.read(at: offset, maxBytes: page)
                }
                if chunk.isEmpty {
                    throw C05SFTPError(.sizeMismatch, "downloadEndedEarly")
                }
                guard offset + UInt64(chunk.count) <= total else {
                    throw C05SFTPError(.sizeMismatch, "downloadExceededRemoteSize")
                }
                try writer.write(contentsOf: chunk)
                hasher.update(data: chunk)
                offset += UInt64(chunk.count)
                transfer.advance(to: Int64(offset))
            }
            try writer.synchronize()
            try writer.close()
            handle = nil
            await read?.close()
            read = nil
            guard offset == total else {
                throw C05SFTPError(.sizeMismatch, "downloadSizeMismatch")
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let stageDigest = try FloeDigest.sha256Hex(
                ofFileAt: stage, isCancelled: { transfer.isCancelled })
            guard stageDigest == digest else {
                throw C05SFTPError(.checksumMismatch, "downloadStagingChanged")
            }
            let bytes = try fileSize(stage)
            guard bytes == Int64(total) else {
                throw C05SFTPError(.sizeMismatch, "downloadStagingSizeMismatch")
            }
            transfer.markCompleting()
            let outcome = try commitDownload(
                access: access,
                staging: stage,
                expectedRevision: expectedRevision,
                overwrite: overwrite,
                digest: digest,
                bytes: Int(total)
            )
            try? FileManager.default.removeItem(at: stage)
            transfer.stagingURL = nil
            guard outcome.sha256.lowercased() == digest else {
                throw C05SFTPError(.checksumMismatch, "downloadCommitDigestMismatch")
            }
            transfer.complete(sha256: outcome.sha256)
        } catch let error as C05SFTPError {
            if error.code == .cancelled || transfer.isCancelled {
                transfer.cancel()
            } else {
                transfer.fail(code: error.code, reason: error.reason)
            }
            try? handle?.close()
            await read?.close()
            try? FileManager.default.removeItem(at: stage)
            transfer.stagingURL = nil
        } catch {
            transfer.fail(
                code: error is CancellationError ? .cancelled : .internalFailure,
                reason: error is CancellationError ? "cancelled" : "downloadFailed")
            try? handle?.close()
            await read?.close()
            try? FileManager.default.removeItem(at: stage)
            transfer.stagingURL = nil
        }
    }

    // MARK: Upload

    public func startUpload(
        laneID: UUID,
        remotePath: String,
        displayName: String,
        totalBytes: Int64,
        sha256: String?,
        overwrite: Bool,
        expectedRevision: String?,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard lane.currentState == .connected,
              lane.transport.isConnected, lane.channel.isActive else {
            lane.setState(.unknown)
            throw C05SFTPError(.laneUnavailable, "sftpLaneNotConnected")
        }
        guard lane.transfers.count < C05SFTPWire.maximumTransfersPerLane,
              lanes.values.reduce(0, { $0 + $1.transfers.count }) < C05SFTPWire.maximumTransfers else {
            throw C05SFTPError(.transferLimit, "sftpTransferLimitReached")
        }
        guard totalBytes >= 0, totalBytes <= Int64(C05SFTPWire.maximumUploadBytes) else {
            throw C05SFTPError(.fileTooLarge, "uploadExceedsLimit")
        }
        if let sha256 {
            guard isValidSHA256(sha256) else {
                throw C05SFTPError(.invalidRequest, "invalidUploadSHA256")
            }
        }
        let normalized = try C05SFTPPath.remote(remotePath, home: lane.homePath)
        guard normalized != "/" else {
            throw C05SFTPError(.invalidPath, "remoteRootIsNotAFile")
        }
        let existing: SSHSFTPAttributes?
        do {
            existing = try await lane.channel.stat(path: normalized)
        } catch let error as SSHSFTPError {
            if error == .notFound {
                existing = nil
            } else {
                throw map(error)
            }
        }
        let actualRevision: String?
        if let existing {
            guard !existing.isDirectory else {
                throw C05SFTPError(.invalidPath, "remotePathIsDirectory")
            }
            actualRevision = cheapRevision(existing)
        } else {
            actualRevision = nil
        }
        try validateOverwritePolicy(
            exists: existing != nil,
            overwrite: overwrite,
            expectedRevision: expectedRevision,
            actualRevision: actualRevision
        )
        if existing != nil {
            guard let expectedRevision, expectedRevision.lowercased().hasPrefix("sha256:") else {
                throw C05SFTPError(.revisionUnverifiable, "remoteOverwriteRequiresContentRevision")
            }
            let hash = try await hashRemote(lane, path: normalized, size: existing?.size ?? 0)
            guard "sha256:\(hash)" == expectedRevision.lowercased() else {
                throw C05SFTPError(.revisionMismatch, "remoteRevisionMismatch")
            }
        }
        let tempPath = try uniqueRemoteTempPath(near: normalized, lane: lane)
        let writeHandle = try await mapRemote {
            try await lane.channel.openWrite(path: tempPath, createNew: true)
        }
        let transfer = C05SFTPTransfer(
            laneID: laneID,
            kind: .upload,
            remotePath: normalized,
            displayName: String(displayName.prefix(120)),
            owner: owner,
            destination: nil,
            totalBytes: totalBytes,
            createdAt: now()
        )
        transfer.remoteTempPath = tempPath
        transfer.expectedRevision = expectedRevision
        transfer.writeHandle = writeHandle
        lane.transfers[transfer.id] = transfer
        lane.touch(now())
        return transfer.snapshot
    }

    public func writeUpload(
        transferID: UUID,
        offset: Int64,
        data: Data,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let (lane, transfer) = findTransfer(transferID), sameOwner(lane, owner),
              transfer.kind == .upload, transfer.owner.token == owner.token else {
            throw C05SFTPError(.transferNotFound, "sftpUploadTransferNotFound")
        }
        guard transfer.currentState == .running else {
            throw C05SFTPError(.busy, "sftpUploadNotRunning")
        }
        guard offset >= 0, offset == transfer.currentBytes else {
            throw C05SFTPError(.transferMismatch, "sftpUploadOffsetMismatch")
        }
        guard !data.isEmpty, data.count <= C05SFTPWire.maximumChunkBytes else {
            throw C05SFTPError(.invalidRequest, "invalidUploadChunk")
        }
        guard offset + Int64(data.count) <= transfer.snapshot.totalBytes else {
            throw C05SFTPError(.sizeMismatch, "uploadExceededDeclaredSize")
        }
        guard let handle = transfer.writeHandle else {
            throw C05SFTPError(.transferNotFound, "sftpUploadHandleMissing")
        }
        do {
            try await handle.write(data, at: UInt64(offset))
            transfer.advance(to: offset + Int64(data.count))
            lane.touch(now())
            return transfer.snapshot
        } catch let error as SSHSFTPError {
            transfer.fail(code: mapCode(error), reason: "uploadWriteFailed")
            throw map(error)
        } catch {
            transfer.fail(code: .internalFailure, reason: "uploadWriteFailed")
            throw C05SFTPError(.transportFailed, "uploadWriteFailed", retryable: true)
        }
    }

    public func finishUpload(
        transferID: UUID,
        declaredSHA256: String?,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let (lane, transfer) = findTransfer(transferID), sameOwner(lane, owner),
              transfer.kind == .upload else {
            throw C05SFTPError(.transferNotFound, "sftpUploadTransferNotFound")
        }
        guard transfer.currentState == .running else {
            throw C05SFTPError(.busy, "sftpUploadNotRunning")
        }
        guard transfer.currentBytes == transfer.snapshot.totalBytes else {
            throw C05SFTPError(.sizeMismatch, "uploadIncomplete")
        }
        guard let tempPath = transfer.remoteTempPath else {
            throw C05SFTPError(.transferNotFound, "sftpUploadTempMissing")
        }
        if let declaredSHA256, !isValidSHA256(declaredSHA256) {
            throw C05SFTPError(.invalidRequest, "invalidUploadSHA256")
        }
        transfer.markCompleting()
        do {
            try await transfer.writeHandle?.close()
            transfer.writeHandle = nil
            let tempAttributes = try await mapRemote {
                try await lane.channel.stat(path: tempPath)
            }
            guard !tempAttributes.isDirectory, tempAttributes.size == transfer.snapshot.totalBytes else {
                throw C05SFTPError(.sizeMismatch, "uploadTempSizeMismatch")
            }
            let observed = try await hashRemote(
                lane, path: tempPath, size: tempAttributes.size)
            if let declaredSHA256,
               observed.lowercased() != declaredSHA256.replacingOccurrences(
                    of: "sha256:", with: "", options: [.caseInsensitive, .anchored]).lowercased() {
                throw C05SFTPError(.checksumMismatch, "uploadChecksumMismatch")
            }
            try await commitUpload(
                lane: lane,
                tempPath: tempPath,
                destination: transfer.remotePath,
                expectedRevision: transfer.expectedRevision,
                destinationExisted: try await remoteExists(lane, path: transfer.remotePath),
                uploadedSHA256: observed
            )
            transfer.remoteTempPath = nil
            transfer.complete(sha256: observed)
            lane.touch(now())
            return transfer.snapshot
        } catch let error as C05SFTPError {
            transfer.fail(code: error.code, reason: error.reason)
            await discardUploadTemp(lane, path: tempPath)
            transfer.remoteTempPath = nil
            throw error
        } catch {
            transfer.fail(code: .internalFailure, reason: "uploadFinishFailed")
            await discardUploadTemp(lane, path: tempPath)
            transfer.remoteTempPath = nil
            throw C05SFTPError(.transportFailed, "uploadFinishFailed", retryable: true)
        }
    }

    public func cancelTransfer(
        transferID: UUID,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let (lane, transfer) = findTransfer(transferID), sameOwner(lane, owner) else {
            throw C05SFTPError(.transferNotFound, "sftpTransferNotFound")
        }
        transfer.requestCancel()
        switch transfer.kind {
        case .download:
            transfer.task?.cancel()
            if let stage = transfer.stagingURL {
                try? FileManager.default.removeItem(at: stage)
                transfer.stagingURL = nil
            }
            transfer.cancel()
        case .upload:
            if transfer.currentState == .running {
                try? await transfer.writeHandle?.close()
                transfer.writeHandle = nil
                if let temp = transfer.remoteTempPath {
                    await discardUploadTemp(lane, path: temp)
                    transfer.remoteTempPath = nil
                }
            }
            transfer.cancel()
        }
        lane.touch(now())
        return transfer.snapshot
    }

    public func transferStatus(
        transferID: UUID,
        owner: C05RemoteOwner
    ) throws -> C05SFTPTransferSnapshot {
        try requireOwner(owner)
        guard let (_, transfer) = findTransfer(transferID),
              transfer.owner.token == owner.token,
              transfer.owner.nativeEpoch == owner.nativeEpoch else {
            throw C05SFTPError(.transferNotFound, "sftpTransferNotFound")
        }
        return transfer.snapshot
    }

    public func listTransfers(
        laneID: UUID,
        owner: C05RemoteOwner
    ) throws -> [C05SFTPTransferSnapshot] {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        return lane.transfers.values.map(\.snapshot).sorted { $0.createdAt < $1.createdAt }
    }

    public func releaseTransfer(
        transferID: UUID,
        owner: C05RemoteOwner
    ) async throws -> Bool {
        try requireOwner(owner)
        guard let (lane, transfer) = findTransfer(transferID), sameOwner(lane, owner) else {
            throw C05SFTPError(.transferNotFound, "sftpTransferNotFound")
        }
        guard transfer.currentState != .running,
              transfer.currentState != .completing else {
            throw C05SFTPError(.transferBusy, "sftpTransferStillRunning")
        }
        if let stage = transfer.stagingURL {
            try? FileManager.default.removeItem(at: stage)
        }
        lane.transfers.removeValue(forKey: transferID)
        return true
    }

    // MARK: Lane close / root stop

    public func disconnect(laneID: UUID, owner: C05RemoteOwner) async throws -> C05SFTPRootStopReport {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        return await closeLane(lane, force: false)
    }

    public func cancelAll(owner: C05RemoteOwner) async throws -> C05SFTPRootStopReport {
        try requireOwner(owner)
        let owned = lanes.values.filter { sameOwner($0, owner) }
        var closed = 0
        var transfers = 0
        var staging = 0
        var drained = true
        for lane in owned {
            let report = await closeLane(lane, force: true)
            closed += report.closedLanes
            transfers += report.closedTransfers
            staging += report.removedStagingFiles
            if !report.drained { drained = false }
        }
        return C05SFTPRootStopReport(
            drained: drained,
            closedLanes: closed,
            closedTransfers: transfers,
            removedStagingFiles: staging
        )
    }

    public func rootStop(expectedEpoch: UInt64) async -> C05SFTPRootStopReport {
        closedThroughEpoch = max(closedThroughEpoch, expectedEpoch)
        challenges.removeAll()
        let all = Array(lanes.values)
        var closed = 0
        var transfers = 0
        var staging = 0
        var drained = true
        for lane in all {
            let report = await closeLane(lane, force: true)
            closed += report.closedLanes
            transfers += report.closedTransfers
            staging += report.removedStagingFiles
            if !report.drained { drained = false }
        }
        return C05SFTPRootStopReport(
            drained: drained,
            closedLanes: closed,
            closedTransfers: transfers,
            removedStagingFiles: staging
        )
    }

    private func closeLane(_ lane: C05SFTPLane, force: Bool) async -> C05SFTPRootStopReport {
        if !force && lane.currentState == .closed {
            return C05SFTPRootStopReport(
                drained: true, closedLanes: 0, closedTransfers: 0, removedStagingFiles: 0)
        }
        lane.setState(.closing)
        let transfers = Array(lane.transfers.values)
        for transfer in transfers {
            transfer.requestCancel()
            transfer.task?.cancel()
            try? await transfer.writeHandle?.close()
            transfer.writeHandle = nil
            if let stage = transfer.stagingURL {
                try? FileManager.default.removeItem(at: stage)
                transfer.stagingURL = nil
            }
            if let temp = transfer.remoteTempPath, lane.channel.isActive {
                try? await lane.channel.removeFile(path: temp)
                transfer.remoteTempPath = nil
            }
            transfer.cancel()
        }
        await lane.readCacheHandle?.close()
        lane.readCacheHandle = nil
        lane.readCachePath = nil
        await lane.channel.close()
        await lane.transport.close()
        lane.setState(.closed)
        lanes.removeValue(forKey: lane.id)
        return C05SFTPRootStopReport(
            drained: true,
            closedLanes: 1,
            closedTransfers: transfers.count,
            removedStagingFiles: transfers.filter { $0.kind == .download && $0.stagingURL == nil }.count
        )
    }

    // MARK: Internal helpers

    private func requireOwner(_ owner: C05RemoteOwner) throws {
        try owner.validate()
        let current = readiness()
        guard current.ready else {
            throw C05SFTPError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard current.epoch == owner.nativeEpoch else {
            throw C05SFTPError(.staleEpoch, "staleNativeEpoch")
        }
        guard owner.nativeEpoch > closedThroughEpoch else {
            throw C05SFTPError(.staleEpoch, "connectionEpochRetired")
        }
    }

    private func stores(epoch: UInt64) async throws -> any C05RemoteHostStoring {
        try await storeProvider(epoch)
    }

    private func sameOwner(_ lane: C05SFTPLane, _ owner: C05RemoteOwner) -> Bool {
        lane.owner.token == owner.token && lane.owner.nativeEpoch == owner.nativeEpoch
    }

    private func transfer(in laneID: UUID, id: UUID) -> C05SFTPTransfer? {
        lanes[laneID]?.transfers[id]
    }

    private func findTransfer(_ id: UUID) -> (C05SFTPLane, C05SFTPTransfer)? {
        for lane in lanes.values {
            if let transfer = lane.transfers[id] { return (lane, transfer) }
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
            guard let oldest = challenges.values.min(by: {
                $0.challenge.createdAt < $1.challenge.createdAt
            }) else { break }
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
            expiresAt: created.addingTimeInterval(300)
        )
        challenges[value.id] = PendingChallenge(
            challenge: value, ownerToken: owner.token, epoch: owner.nativeEpoch)
        return value
    }

    private func purgeExpiredChallenges() {
        let current = now()
        challenges = challenges.filter { $0.value.challenge.expiresAt > current }
    }

    private func mapped(_ error: SSHConnectionError) -> C05SFTPError {
        let code: C05SFTPErrorCode
        switch error {
        case .sshNotConfigured: code = .invalidProfile
        case .invalidCredential: code = .credentialMissing
        case .authenticationFailed: code = .authenticationFailed
        case .connectionRefused: code = .connectionRefused
        case .hostNotFound: code = .hostNotFound
        case .timedOut: code = .timedOut
        case .networkUnreachable: code = .networkUnreachable
        case .invalidHostKey, .unsupportedKeyType: code = .protocolIncompatible
        case .hostKeyRejected: code = .hostKeyChallenge
        case .hostKeyChanged: code = .hostKeyChanged
        case .transport: code = .transportFailed
        }
        return C05SFTPError(
            code, code.rawValue, retryable: error.retryable,
            detail: error.errorDescription)
    }

    private func map(_ error: SSHSFTPError) -> C05SFTPError {
        C05SFTPError(mapCode(error), mapCode(error).rawValue, retryable: {
            switch error {
            case .connectionLost, .timeout, .transport, .notConnected: true
            default: false
            }
        }(), detail: error.errorDescription)
    }

    private func mapCode(_ error: SSHSFTPError) -> C05SFTPErrorCode {
        switch error {
        case .notConnected, .connectionLost: return .laneUnavailable
        case .unsupportedByServer: return .unsupportedByServer
        case .invalidPath: return .invalidPath
        case .notFound: return .pathNotFound
        case .permissionDenied: return .permissionDenied
        case .alreadyExists: return .destinationExists
        case .isDirectory, .notDirectory: return .invalidPath
        case .fileHandleInvalid: return .remoteFailure
        case .protocolFailure: return .remoteFailure
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        case .transport: return .transportFailed
        case .status: return .remoteFailure
        }
    }

    private func mapRemote<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as SSHSFTPError {
            throw map(error)
        } catch is CancellationError {
            throw C05SFTPError(.cancelled, "cancelled", retryable: true)
        } catch {
            throw C05SFTPError(.remoteFailure, "remoteOperationFailed", retryable: true)
        }
    }

    private func entry(
        path: String,
        name: String,
        attributes: SSHSFTPAttributes
    ) -> C05SFTPEntry {
        C05SFTPEntry(
            name: String(name.prefix(C05SFTPWire.maximumNameBytes)),
            path: path,
            isDirectory: attributes.isDirectory,
            isSymbolicLink: attributes.isSymbolicLink,
            bytes: max(0, attributes.size),
            modifiedAt: attributes.modifiedAt,
            permissions: attributes.permissions,
            revision: attributes.isDirectory ? "dir" : cheapRevision(attributes)
        )
    }

    private func cheapRevision(_ attributes: SSHSFTPAttributes) -> String {
        let mtime = Int64(attributes.modifiedAt?.timeIntervalSince1970 ?? 0)
        let mode = Int64(attributes.permissions ?? 0)
        return "sftp1:\(attributes.size):\(mtime):\(mode)"
    }

    private func listingFor(
        lane: C05SFTPLane,
        path: String
    ) async throws -> C05SFTPCachedListing {
        if let cached = lane.listings[path],
           now().timeIntervalSince(cached.fetchedAt) <= C05SFTPWire.listingCacheLifetime {
            return cached
        }
        let canonical = (try? await lane.channel.canonicalPath(path)) ?? path
        let raw = try await mapRemote {
            try await lane.channel.listDirectory(
                at: path,
                maxEntries: C05SFTPWire.maximumDirectoryEntries
            )
        }
        var entries: [C05SFTPEntry] = []
        entries.reserveCapacity(min(raw.count, C05SFTPWire.maximumDirectoryEntries))
        for item in raw {
            guard entries.count < C05SFTPWire.maximumDirectoryEntries else { break }
            guard item.name != ".", item.name != "..", !item.name.isEmpty,
                  !item.name.contains("/"), !item.name.contains("\0"),
                  item.name.utf8.count <= C05SFTPWire.maximumNameBytes,
                  !item.name.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { continue }
            entries.append(entry(
                path: C05SFTPPath.joined(parent: path, name: item.name),
                name: item.name,
                attributes: item.attributes
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let listing = C05SFTPCachedListing(
            entries: entries,
            fetchedAt: now(),
            canonicalPath: canonical,
            truncated: raw.count > C05SFTPWire.maximumDirectoryEntries
        )
        lane.listings[path] = listing
        lane.listingOrder.removeAll { $0 == path }
        lane.listingOrder.append(path)
        while lane.listingOrder.count > C05SFTPWire.maximumCachedListings {
            let evicted = lane.listingOrder.removeFirst()
            lane.listings.removeValue(forKey: evicted)
        }
        return listing
    }

    private func invalidateListing(_ lane: C05SFTPLane, path: String) {
        lane.listings.removeValue(forKey: path)
        lane.listingOrder.removeAll { $0 == path }
    }

    private func readFromLane(
        _ lane: C05SFTPLane,
        path: String,
        offset: UInt64,
        maxBytes: Int
    ) async throws -> Data {
        var handle = lane.readCacheHandle
        if lane.readCachePath != path || handle == nil {
            await handle?.close()
            handle = try await mapRemote {
                try await lane.channel.openRead(path: path)
            }
            lane.readCacheHandle = handle
            lane.readCachePath = path
        }
        guard let handle else {
            throw C05SFTPError(.remoteFailure, "sftpReadHandleUnavailable")
        }
        var result = Data()
        var cursor = offset
        while result.count < maxBytes {
            let want = min(C05SFTPWire.maximumChunkBytes, maxBytes - result.count)
            let chunk = try await mapRemote {
                try await handle.read(at: cursor, maxBytes: want)
            }
            if chunk.isEmpty { break }
            result.append(chunk)
            cursor += UInt64(chunk.count)
        }
        return result
    }

    private func hashRemote(
        _ lane: C05SFTPLane,
        path: String,
        size: Int64
    ) async throws -> String {
        guard size >= 0, size <= Int64(C05SFTPWire.maximumRemoteHashBytes) else {
            throw C05SFTPError(.revisionUnverifiable, "remoteFileTooLargeForHash")
        }
        let handle = try await mapRemote {
            try await lane.channel.openRead(path: path)
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        do {
            while offset < UInt64(size) {
                let want = min(
                    C05SFTPWire.maximumChunkBytes,
                    Int(UInt64(size) - offset)
                )
                let chunk = try await mapRemote {
                    try await handle.read(at: offset, maxBytes: want)
                }
                if chunk.isEmpty { throw C05SFTPError(.sizeMismatch, "remoteHashEndedEarly") }
                hasher.update(data: chunk)
                offset += UInt64(chunk.count)
            }
            await handle.close()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            await handle.close()
            throw error
        }
    }

    private func remoteExists(_ lane: C05SFTPLane, path: String) async throws -> Bool {
        do {
            _ = try await lane.channel.stat(path: path)
            return true
        } catch let error as SSHSFTPError where error == .notFound {
            return false
        } catch let error as SSHSFTPError {
            throw map(error)
        }
    }

    private func uniqueRemoteTempPath(near path: String, lane: C05SFTPLane) throws -> String {
        let parent = C05SFTPPath.parent(path)
        let name = C05SFTPPath.name(path)
        let base = String(name.prefix(80)).replacingOccurrences(of: ".", with: "_")
        return C05SFTPPath.joined(
            parent: parent,
            name: ".floe-sftp-\(base)-\(UUID().uuidString.lowercased())"
        )
    }

    private func discardUploadTemp(_ lane: C05SFTPLane, path: String) async {
        guard lane.channel.isActive else { return }
        try? await lane.channel.removeFile(path: path)
        invalidateListing(lane, path: C05SFTPPath.parent(path))
    }

    private func isValidSHA256(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(
            of: "sha256:", with: "", options: [.caseInsensitive, .anchored])
        return normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func createStagingFile() throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: stagingRoot.path) {
            let values = try stagingRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw C05SFTPError(.destinationUnavailable, "stagingRootIsSymlink")
            }
        } else {
            try manager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let url = stagingRoot.appendingPathComponent(
            "download-\(UUID().uuidString.lowercased())", isDirectory: false)
        guard manager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw C05SFTPError(.internalFailure, "stagingFileCreateFailed")
        }
        return url
    }

    private func openStagingForWriting(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            throw C05SFTPError(.destinationUnavailable, "stagingFileUnavailable")
        }
    }

    private func localRevision(_ access: C05SFTPOwnedAccess) throws -> C05SFTPLocalRevision {
        let resolved = try access.fileService.guardResolver.resolve(access.relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return C05SFTPLocalRevision(
                exists: false, bytes: 0, sha256: nil, revision: nil, modifiedAt: nil)
        }
        guard !isDirectory.boolValue else {
            throw C05SFTPError(.invalidPath, "destinationIsDirectory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw C05SFTPError(.invalidPath, "destinationIsNotRegularFile")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Int64(C05SFTPWire.maximumLocalVerifyBytes) else {
            throw C05SFTPError(.fileTooLarge, "destinationTooLargeToVerify")
        }
        let digest: String
        do {
            digest = try FloeDigest.sha256Hex(ofFileAt: resolved)
        } catch {
            throw C05SFTPError(.localConflict, "destinationDigestFailed")
        }
        return C05SFTPLocalRevision(
            exists: true,
            bytes: size,
            sha256: digest,
            revision: "sha256:\(digest)",
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private func validateOverwritePolicy(
        exists: Bool,
        overwrite: Bool,
        expectedRevision: String?,
        actualRevision: String?
    ) throws {
        if exists {
            guard overwrite else {
                throw C05SFTPError(.destinationExists, "destinationExists")
            }
            guard let expectedRevision else {
                throw C05SFTPError(.revisionRequired, "destinationRevisionRequired")
            }
            guard let actualRevision else {
                throw C05SFTPError(.revisionUnverifiable, "destinationRevisionUnverifiable")
            }
            guard expectedRevision.lowercased() == actualRevision.lowercased() else {
                throw C05SFTPError(.revisionMismatch, "destinationRevisionMismatch")
            }
        } else if expectedRevision != nil {
            throw C05SFTPError(.revisionMismatch, "destinationMissing")
        }
    }

    private func commitDownload(
        access: C05SFTPOwnedAccess,
        staging: URL,
        expectedRevision: String?,
        overwrite: Bool,
        digest: String,
        bytes: Int
    ) throws -> WriteOutcome {
        let service = access.fileService
        let exists: Bool
        do {
            let resolved = try service.guardResolver.resolve(access.relativePath)
            exists = FileManager.default.fileExists(atPath: resolved.path)
        } catch {
            throw C05SFTPError(.destinationUnavailable, "destinationUnavailable")
        }
        if !exists {
            if bytes == 0 {
                do {
                    return try service.createBinaryFile(
                        access.relativePath, data: Data(), overwrite: false)
                } catch {
                    throw C05SFTPError(.localConflict, "emptyDestinationCreateFailed")
                }
            }
            do {
                return try service.importUserFile(
                    from: staging,
                    to: access.relativePath,
                    expectedSHA256: digest
                )
            } catch {
                throw C05SFTPError(.localConflict, "destinationCommitFailed")
            }
        }
        guard overwrite, let expectedRevision else {
            throw C05SFTPError(.destinationExists, "destinationExists")
        }
        let original = try localRevision(access)
        guard let originalDigest = original.sha256,
              "sha256:\(originalDigest)".lowercased() == expectedRevision.lowercased() else {
            throw C05SFTPError(.revisionMismatch, "destinationRevisionMismatch")
        }
        if bytes == 0 {
            do {
                return try service.writeFile(
                    access.relativePath,
                    content: "",
                    expectedSHA256: originalDigest
                )
            } catch {
                throw C05SFTPError(.localConflict, "emptyDestinationReplaceFailed")
            }
        }
        do {
            return try service.replaceBinaryFile(
                access.relativePath,
                from: staging,
                expectedOriginalSHA256: originalDigest,
                expectedSourceSHA256: digest,
                expectedSourceBytes: bytes
            )
        } catch {
            throw C05SFTPError(.localConflict, "destinationReplaceFailed")
        }
    }

    private func commitUpload(
        lane: C05SFTPLane,
        tempPath: String,
        destination: String,
        expectedRevision: String?,
        destinationExisted: Bool,
        uploadedSHA256: String
    ) async throws {
        let uploaded = normalizeSHA(uploadedSHA256)
        guard !uploaded.isEmpty else {
            throw C05SFTPError(.invalidRequest, "invalidUploadSHA256")
        }

        // Revalidate immediately before any move. This is the strongest
        // content check SFTP v3 can offer: the rename itself is not a
        // content CAS, so every state-changing step is followed by an
        // actual stat/hash and an uncertain outcome preserves both sides.
        if destinationExisted {
            guard let expectedRevision,
                  expectedRevision.lowercased().hasPrefix("sha256:") else {
                throw C05SFTPError(.revisionRequired, "remoteDestinationRevisionRequired")
            }
            let attributes: SSHSFTPAttributes
            do {
                attributes = try await lane.channel.stat(path: destination)
            } catch let error as SSHSFTPError where error == .notFound {
                throw C05SFTPError(.revisionMismatch, "remoteDestinationMissing")
            }
            guard !attributes.isDirectory else {
                throw C05SFTPError(.invalidPath, "remotePathIsDirectory")
            }
            let digest = try await hashRemote(
                lane, path: destination, size: attributes.size)
            guard "sha256:\(digest)".lowercased() == expectedRevision.lowercased() else {
                throw C05SFTPError(.revisionMismatch, "remoteDestinationChanged")
            }
        } else if try await remoteExists(lane, path: destination) {
            // A destination appeared after start; never overwrite it.
            throw C05SFTPError(.destinationExists, "remoteDestinationExists")
        }

        var backupPath: String?
        if destinationExisted {
            let backup = try await uniqueRemoteBackupPath(near: destination, lane: lane)
            do {
                try await lane.channel.rename(from: destination, to: backup)
                backupPath = backup
            } catch {
                // Rename outcome may be unknown. Preserve every side that
                // still exists; never guess that the original moved.
                let destinationStillThere = try await remoteExists(lane, path: destination)
                let backupExists = try await remoteExists(lane, path: backup)
                if destinationStillThere && !backupExists {
                    throw C05SFTPError(
                        .remoteFailure, "remoteBackupRenameFailed",
                        detail: "the original destination was preserved in place")
                }
                if backupExists && destinationStillThere {
                    throw C05SFTPError(
                        .remoteFailure, "remoteCommitUncertain",
                        detail: "destination and backup both exist; nothing was overwritten",
                        retainedPath: backup)
                }
                if backupExists {
                    backupPath = backup
                } else {
                    throw C05SFTPError(
                        .remoteFailure, "remoteCommitUncertain",
                        detail: destinationStillThere
                            ? "destination still exists; backup state unknown"
                            : "destination/backup state unknown; nothing was overwritten")
                }
            }

            guard let retained = backupPath else {
                throw C05SFTPError(.remoteFailure, "remoteBackupUnverified")
            }
            let movedAttributes: SSHSFTPAttributes
            do {
                movedAttributes = try await lane.channel.stat(path: retained)
            } catch {
                throw C05SFTPError(
                    .remoteFailure, "remoteBackupUnverified",
                    detail: "the original is retained as a recovery copy",
                    retainedPath: retained)
            }
            guard !movedAttributes.isDirectory else {
                throw C05SFTPError(
                    .remoteFailure, "remoteBackupUnverified",
                    detail: "the recovery path is not a regular file",
                    retainedPath: retained)
            }
            guard let expectedRevision else {
                throw C05SFTPError(.revisionRequired, "remoteDestinationRevisionRequired")
            }
            let movedDigest = try await hashRemote(
                lane, path: retained, size: movedAttributes.size)
            guard "sha256:\(movedDigest)".lowercased()
                    == expectedRevision.lowercased() else {
                // The original changed between the preflight hash and the
                // rename. It is safely at `retained`; do not auto-restore
                // because SFTP v3 rename could overwrite a new destination.
                throw C05SFTPError(
                    .revisionMismatch, "remoteDestinationChangedDuringCommit",
                    detail: "the changed original is retained as a recovery copy",
                    retainedPath: retained)
            }
        }

        // Re-check immediately before the final rename. SFTP v3 rename is
        // not an exclusive create/replace; if a destination appeared after
        // the backup move, do not overwrite it.
        if try await remoteExists(lane, path: destination) {
            throw C05SFTPError(
                .remoteFailure, "remoteCommitUncertain",
                detail: "a destination appeared before the final rename; nothing was overwritten",
                retainedPath: backupPath)
        }

        do {
            try await lane.channel.rename(from: tempPath, to: destination)
        } catch {
            let destinationExistsNow = try await remoteExists(lane, path: destination)
            let tempStillThere = try await remoteExists(lane, path: tempPath)
            if destinationExistsNow && !tempStillThere {
                // The rename may have succeeded before the error. Verify
                // actual destination bytes; only then treat it as success.
                if let attributes = try? await lane.channel.stat(path: destination),
                   !attributes.isDirectory,
                   let digest = try? await hashRemote(
                        lane, path: destination, size: attributes.size),
                   digest.lowercased() == uploaded {
                    if let retained = backupPath {
                        try? await lane.channel.removeFile(path: retained)
                    }
                    invalidateListing(lane, path: C05SFTPPath.parent(destination))
                    return
                }
                throw C05SFTPError(
                    .remoteFailure, "remoteCommitUncertain",
                    detail: "destination exists but does not match the uploaded bytes",
                    retainedPath: backupPath)
            }
            if !destinationExistsNow && tempStillThere {
                throw C05SFTPError(
                    .remoteFailure, "remoteCommitRenameFailed",
                    detail: "the verified remote temp and original recovery copy were preserved",
                    retainedPath: backupPath)
            }
            throw C05SFTPError(
                .remoteFailure, "remoteCommitUncertain",
                detail: "destination/temp state is unknown; existing files were preserved",
                retainedPath: backupPath)
        }

        // Rename returned success, but a concurrent writer can still have
        // changed the destination. Verify actual bytes before deleting the
        // recoverable original.
        let attributes: SSHSFTPAttributes
        do {
            attributes = try await lane.channel.stat(path: destination)
        } catch {
            throw C05SFTPError(
                .remoteFailure, "remoteCommitUnverified",
                detail: "destination read-back failed; recovery copy retained",
                retainedPath: backupPath)
        }
        guard !attributes.isDirectory else {
            throw C05SFTPError(
                .remoteFailure, "remoteCommitUnverified",
                detail: "destination is not a regular file",
                retainedPath: backupPath)
        }
        let digest = try await hashRemote(
            lane, path: destination, size: attributes.size)
        guard digest.lowercased() == uploaded else {
            throw C05SFTPError(
                .remoteFailure, "remoteCommitChangedAfterRename",
                detail: "a newer destination was preserved; recovery copy retained",
                retainedPath: backupPath)
        }
        if let retained = backupPath {
            try? await lane.channel.removeFile(path: retained)
        }
        invalidateListing(lane, path: C05SFTPPath.parent(destination))
    }

    private func uniqueRemoteBackupPath(
        near destination: String,
        lane: C05SFTPLane
    ) async throws -> String {
        let parent = C05SFTPPath.parent(destination)
        let name = C05SFTPPath.name(destination)
        let base = String(name.prefix(80)).replacingOccurrences(of: ".", with: "_")
        for _ in 0..<4 {
            let candidate = C05SFTPPath.joined(
                parent: parent,
                name: ".floe-backup-\(base)-\(UUID().uuidString.lowercased())")
            if !(try await remoteExists(lane, path: candidate)) {
                return candidate
            }
        }
        throw C05SFTPError(.remoteFailure, "remoteBackupPathUnavailable")
    }

    private func normalizeSHA(_ value: String) -> String {
        value.replacingOccurrences(
            of: "sha256:", with: "", options: [.caseInsensitive, .anchored])
            .lowercased()
    }
}

// MARK: - Internal whole-body / mutation seam (mount adapter only)

extension C05SFTPDomain {
    func uploadData(
        laneID: UUID,
        remotePath: String,
        data: Data,
        expectedRevision: String?,
        overwrite: Bool,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPEntry {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        guard data.count <= C05SFTPWire.maximumUploadBytes else {
            throw C05SFTPError(.fileTooLarge, "uploadExceedsLimit")
        }
        let normalized = try C05SFTPPath.remote(remotePath, home: lane.homePath)
        let existing: SSHSFTPAttributes?
        do {
            existing = try await lane.channel.stat(path: normalized)
        } catch let error as SSHSFTPError {
            if error == .notFound {
                existing = nil
            } else {
                throw map(error)
            }
        }
        let actual: String?
        if let existing {
            guard !existing.isDirectory else {
                throw C05SFTPError(.invalidPath, "remotePathIsDirectory")
            }
            guard existing.size <= Int64(C05SFTPWire.maximumRemoteHashBytes) else {
                throw C05SFTPError(.revisionUnverifiable, "remoteFileTooLargeForCAS")
            }
            if existing.size <= Int64(C05SFTPWire.maximumRemoteHashBytes) {
                let digest = try await hashRemote(
                    lane, path: normalized, size: existing.size)
                actual = "sha256:\(digest)"
            } else {
                actual = cheapRevision(existing)
            }
        } else {
            actual = nil
        }
        try validateOverwritePolicy(
            exists: existing != nil,
            overwrite: overwrite,
            expectedRevision: expectedRevision,
            actualRevision: actual
        )
        let temp = try uniqueRemoteTempPath(near: normalized, lane: lane)
        let handle = try await mapRemote {
            try await lane.channel.openWrite(path: temp, createNew: true)
        }
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + C05SFTPWire.maximumChunkBytes, data.count)
                try await handle.write(data.subdata(in: offset..<end), at: UInt64(offset))
                offset = end
            }
            try await handle.close()
            let tempAttributes = try await mapRemote {
                try await lane.channel.stat(path: temp)
            }
            guard tempAttributes.size == Int64(data.count) else {
                throw C05SFTPError(.sizeMismatch, "uploadTempSizeMismatch")
            }
            let digest = try await hashRemote(lane, path: temp, size: tempAttributes.size)
            guard digest == FloeDigest.sha256Hex(data) else {
                throw C05SFTPError(.checksumMismatch, "uploadChecksumMismatch")
            }
            try await commitUpload(
                lane: lane,
                tempPath: temp,
                destination: normalized,
                expectedRevision: existing == nil ? nil : actual,
                destinationExisted: existing != nil,
                uploadedSHA256: digest
            )
            lane.touch(now())
            return C05SFTPEntry(
                name: C05SFTPPath.name(normalized),
                path: normalized,
                isDirectory: false,
                isSymbolicLink: false,
                bytes: Int64(data.count),
                modifiedAt: now(),
                permissions: nil,
                revision: "sha256:\(digest)"
            )
        } catch {
            try? await handle.close()
            try? await lane.channel.removeFile(path: temp)
            throw error
        }
    }

    func removeRemote(
        laneID: UUID,
        path: String,
        expectedRevision: String?,
        owner: C05RemoteOwner
    ) async throws {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        let normalized = try C05SFTPPath.remote(path, home: lane.homePath)
        let attributes = try await mapRemote {
            try await lane.channel.stat(path: normalized)
        }
        if !attributes.isDirectory, let expectedRevision {
            let digest = try await hashRemote(
                lane, path: normalized, size: attributes.size)
            let actual = "sha256:\(digest)"
            guard expectedRevision.lowercased() == actual.lowercased() else {
                throw C05SFTPError(.revisionMismatch, "remoteRevisionMismatch")
            }
        }
        if attributes.isDirectory {
            try await mapRemote { try await lane.channel.removeDirectory(path: normalized) }
        } else {
            try await mapRemote { try await lane.channel.removeFile(path: normalized) }
        }
        invalidateListing(lane, path: C05SFTPPath.parent(normalized))
        lane.touch(now())
    }

    func renameRemote(
        laneID: UUID,
        from: String,
        to: String,
        owner: C05RemoteOwner
    ) async throws {
        try requireOwner(owner)
        guard let lane = lanes[laneID], sameOwner(lane, owner) else {
            throw C05SFTPError(.laneNotFound, "sftpLaneNotFound")
        }
        let source = try C05SFTPPath.remote(from, home: lane.homePath)
        let destination = try C05SFTPPath.remote(to, home: lane.homePath)
        guard source != destination else { return }
        if try await remoteExists(lane, path: destination) {
            throw C05SFTPError(.destinationExists, "remoteDestinationExists")
        }
        try await mapRemote {
            try await lane.channel.rename(from: source, to: destination)
        }
        invalidateListing(lane, path: C05SFTPPath.parent(source))
        invalidateListing(lane, path: C05SFTPPath.parent(destination))
        lane.touch(now())
    }
}

// MARK: - Workspace mount adapter (WSF-NETWORK-MOUNT)

/// Adapts the C05 SFTP lane to the existing file-workbench network mount
/// contract. The mount's approved credential lease is the only credential
/// source; the known-host chain and Citadel transport are the same C05
/// services used by the Remote screen. No local path ever represents a
/// remote path.
public final class C05SFTPWorkspaceMountAdapter: WorkspaceMountAdapter, @unchecked Sendable {
    private let mount: NetworkWorkspaceMount
    private let credentialResolver: NetworkCredentialResolver
    private let session = C05SFTPMountSession()

    public init(
        mount: NetworkWorkspaceMount,
        credentialResolver: @escaping NetworkCredentialResolver
    ) throws {
        guard mount.transport == .sftp else {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration", retryable: false,
                safeDetail: "The SFTP adapter requires an SFTP mount.")
        }
        guard mount.endpoint.scheme?.lowercased() == "sftp",
              let host = mount.endpoint.host, !host.isEmpty,
              mount.endpoint.user == nil, mount.endpoint.password == nil else {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration", retryable: false,
                safeDetail: "Use sftp://host[:port] without embedded credentials.")
        }
        guard !mount.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration", retryable: false,
                safeDetail: "An SSH user name is required.")
        }
        guard mount.credentialRef != nil else {
            throw NetworkWorkspaceError(
                code: .credentialMissing, stage: "credentials", retryable: false,
                safeDetail: "Save an SSH password for this mount.")
        }
        self.mount = mount
        self.credentialResolver = credentialResolver
    }

    deinit {
        let session = self.session
        Task { await session.close() }
    }

    public func list(path: String) async throws -> [NetworkWorkspaceEntry] {
        let context = try await context()
        let remote: String
        do {
            remote = try context.remote(path)
        } catch let error as C05SFTPError {
            throw Self.networkError(error)
        } catch {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration",
                retryable: false, safeDetail: "The remote path is not valid.")
        }
        var offset = 0
        var collected: [C05SFTPEntry] = []
        // The domain page is 200 entries; the file-workbench contract can
        // accept up to 1,000. Page explicitly instead of silently showing a
        // truncated folder.
        while collected.count < C05SFTPWire.maximumDirectoryEntries {
            let page = try await map {
                try await C05SFTPDomain.shared.list(
                    laneID: context.laneID,
                    path: remote,
                    offset: offset,
                    limit: 200,
                    owner: context.owner
                )
            }
            collected.append(contentsOf: page.entries)
            if page.entries.isEmpty || page.nextOffset <= offset ||
                page.nextOffset >= page.totalEntries || !page.truncated {
                break
            }
            offset = page.nextOffset
        }
        return collected.prefix(C05SFTPWire.maximumDirectoryEntries).map { entry in
            NetworkWorkspaceEntry(
                name: entry.name,
                path: Self.mountRelative(entry.path, base: context.base),
                isDirectory: entry.isDirectory,
                byteCount: entry.bytes,
                modifiedAt: entry.modifiedAt,
                entityTag: entry.revision
            )
        }
    }

    public func read(path: String, offset: Int, limit: Int?) async throws -> Data {
        let context = try await context()
        let bounded = min(C05SFTPWire.maximumReadBytes, max(1, limit ?? C05SFTPWire.maximumChunkBytes))
        return try await map {
            try await C05SFTPDomain.shared.readChunkDirect(
                laneID: context.laneID,
                path: try context.remote(path),
                offset: Int64(max(0, offset)),
                maxBytes: bounded,
                owner: context.owner
            )
        }
    }

    public func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata {
        let context = try await context()
        let entry = try await map {
            try await C05SFTPDomain.shared.remoteRevision(
                laneID: context.laneID,
                path: try context.remote(path),
                hashContent: true,
                owner: context.owner
            )
        }
        return NetworkWorkspaceFileMetadata(
            path: Self.mountRelative(entry.path, base: context.base),
            isDirectory: entry.isDirectory,
            byteCount: entry.bytes,
            modifiedAt: entry.modifiedAt,
            entityTag: entry.revision
        )
    }

    public func write(path: String, data: Data, expectedEntityTag: String?) async throws -> NetworkWorkspaceFileMetadata {
        guard !data.isEmpty else {
            throw NetworkWorkspaceError(
                code: .unsupported, stage: "write", retryable: false,
                safeDetail: "Empty SFTP writes are refused.")
        }
        let context = try await context()
        let remote: String
        do {
            remote = try context.remote(path)
        } catch let error as C05SFTPError {
            throw Self.networkError(error)
        } catch {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration",
                retryable: false, safeDetail: "The remote path is not valid.")
        }
        var expected = expectedEntityTag
        if expected == nil {
            let exists = try await map {
                try await remoteExists(remote, context: context)
            }
            if exists {
                throw NetworkWorkspaceError(
                    code: .conflict, stage: "write", retryable: false,
                    safeDetail: "The remote file already exists; a revision is required.")
            }
        } else if expected?.lowercased().hasPrefix("sha256:") != true {
            let current = try await map {
                try await C05SFTPDomain.shared.remoteRevision(
                    laneID: context.laneID, path: remote, hashContent: true, owner: context.owner)
            }
            expected = current.revision
        }
        let entry = try await map {
            try await C05SFTPDomain.shared.uploadData(
                laneID: context.laneID,
                remotePath: remote,
                data: data,
                expectedRevision: expected,
                overwrite: expected != nil,
                owner: context.owner
            )
        }
        return NetworkWorkspaceFileMetadata(
            path: Self.mountRelative(entry.path, base: context.base),
            isDirectory: false,
            byteCount: entry.bytes,
            modifiedAt: entry.modifiedAt,
            entityTag: entry.revision
        )
    }

    public func createDirectory(path: String) async throws {
        let context = try await context()
        try await map {
            try await C05SFTPDomain.shared.makeDirectory(
                laneID: context.laneID,
                path: try context.remote(path),
                owner: context.owner
            )
        }
    }

    public func move(from: String, to: String, expectedEntityTag: String?) async throws {
        let context = try await context()
        let source: String
        let destination: String
        do {
            source = try context.remote(from)
            destination = try context.remote(to)
        } catch let error as C05SFTPError {
            throw Self.networkError(error)
        } catch {
            throw NetworkWorkspaceError(
                code: .invalidConfiguration, stage: "configuration",
                retryable: false, safeDetail: "The remote path is not valid.")
        }
        if let expectedEntityTag {
            let current = try await map {
                try await C05SFTPDomain.shared.remoteRevision(
                    laneID: context.laneID, path: source, hashContent: true, owner: context.owner)
            }
            guard current.revision.lowercased() == expectedEntityTag.lowercased() else {
                throw NetworkWorkspaceError(
                    code: .conflict, stage: "move", retryable: false,
                    safeDetail: "The remote source changed.")
            }
        }
        try await map {
            try await C05SFTPDomain.shared.renameRemote(
                laneID: context.laneID,
                from: source,
                to: destination,
                owner: context.owner
            )
        }
    }

    public func delete(path: String, expectedEntityTag: String?) async throws {
        let context = try await context()
        try await map {
            try await C05SFTPDomain.shared.removeRemote(
                laneID: context.laneID,
                path: try context.remote(path),
                expectedRevision: expectedEntityTag,
                owner: context.owner
            )
        }
    }

    public func close() async {
        await session.close()
    }

    private struct Context {
        let laneID: UUID
        let owner: C05RemoteOwner
        let base: String

        func remote(_ relative: String) throws -> String {
            try C05SFTPPath.remote(relative, home: base, allowEmpty: true)
        }
    }

    private func context() async throws -> Context {
        let value = try await map {
            try await session.ensure(
                mount: mount,
                credentialResolver: credentialResolver
            )
        }
        return Context(laneID: value.laneID, owner: value.owner, base: value.base)
    }

    private func remoteExists(_ path: String, context: Context) async throws -> Bool {
        do {
            _ = try await C05SFTPDomain.shared.stat(
                laneID: context.laneID, path: path, owner: context.owner)
            return true
        } catch let error as C05SFTPError where error.code == .pathNotFound {
            return false
        }
    }

    private func map<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as C05SFTPError {
            throw Self.networkError(error)
        } catch is CancellationError {
            throw NetworkWorkspaceError(
                code: .unsupported, stage: "transport", retryable: true,
                safeDetail: "The SFTP operation was cancelled.")
        } catch {
            throw NetworkWorkspaceError(
                code: .protocolFailure, stage: "transport", retryable: true,
                safeDetail: "The SFTP operation failed.")
        }
    }

    private static func networkError(_ error: C05SFTPError) -> NetworkWorkspaceError {
        let code: NetworkWorkspaceErrorCode
        switch error.code {
        case .credentialMissing, .credentialInvalid, .gatewayUnavailable:
            code = .credentialMissing
        case .authenticationFailed, .hostKeyChallenge, .hostKeyChanged:
            code = .authenticationFailed
        case .hostNotFound, .networkUnreachable, .connectionRefused:
            code = .networkUnreachable
        case .timedOut, .timeout:
            code = .timedOut
        case .pathNotFound, .laneNotFound:
            code = .notFound
        case .destinationExists, .revisionMismatch, .revisionRequired, .localConflict:
            code = .conflict
        case .permissionDenied:
            code = .remoteRejected
        case .invalidPath, .invalidRequest:
            code = .invalidConfiguration
        case .unsupportedByServer, .unsupportedOperation:
            code = .unsupported
        case .cancelled:
            code = .unsupported
        default:
            code = .protocolFailure
        }
        var detail = error.detail ?? error.reason
        if let retained = error.retainedPath {
            detail += " Recovery copy retained at \(retained)."
        }
        return NetworkWorkspaceError(
            code: code,
            stage: "sftp",
            retryable: error.retryable,
            safeDetail: String(detail.prefix(512))
        )
    }

    private static func mountRelative(_ absolute: String, base: String) -> String {
        if absolute == base { return "" }
        if base == "/" { return String(absolute.dropFirst()) }
        if absolute.hasPrefix(base + "/") {
            return String(absolute.dropFirst(base.count + 1))
        }
        return absolute
    }
}

private actor C05SFTPMountSession {
    struct Value: Sendable {
        let laneID: UUID
        let owner: C05RemoteOwner
        let base: String
    }

    private var laneID: UUID?
    private var owner: C05RemoteOwner?
    private var base: String = "/"

    func ensure(
        mount: NetworkWorkspaceMount,
        credentialResolver: @escaping NetworkCredentialResolver
    ) async throws -> Value {
        if let laneID, let owner,
           await laneIsConnected(laneID, owner: owner) {
            return Value(laneID: laneID, owner: owner, base: base)
        }
        await close()
        let ready = C05SFTPProductionWiring.readiness()
        guard ready.ready, let epoch = ready.epoch else {
            throw C05SFTPError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard let host = mount.endpoint.host else {
            throw C05SFTPError(.invalidProfile, "missingSFTPHost")
        }
        let port = mount.endpoint.port ?? 22
        guard (1...65535).contains(port) else {
            throw C05SFTPError(.invalidProfile, "invalidSFTPPort")
        }
        let reference = SecretReference(
            keychainAccount: "floe.sftp.mount", synchronizable: false)
        let profile = RemoteHostProfile(
            id: mount.id,
            displayName: mount.name,
            address: host,
            port: port,
            user: mount.username,
            auth: .password(reference),
            hostKeyPolicy: .trustOnFirstUse
        )
        let secretRef = mount.credentialRef
        let resolver: SSHCredentialResolver = { _ in
            guard let secretRef else {
                throw C05SFTPError(.credentialMissing, "mountCredentialMissing")
            }
            do {
                return try await credentialResolver(secretRef)
            } catch {
                throw C05SFTPError(.credentialMissing, "mountCredentialUnavailable")
            }
        }
        let owner = C05RemoteOwner(
            token: "mount-\(mount.id.uuidString.lowercased())",
            nativeEpoch: epoch,
            taskID: nil,
            temporary: false
        )
        let snapshot = try await C05SFTPDomain.shared.openMountLane(
            profile: profile,
            credentialResolver: resolver,
            hostKeyDecision: { _ in false },
            owner: owner
        )
        let base: String
        do {
            base = try C05SFTPPath.remote(
                mount.rootPath, home: snapshot.homePath, allowEmpty: true)
        } catch {
            _ = try? await C05SFTPDomain.shared.disconnect(
                laneID: snapshot.id, owner: owner)
            throw error
        }
        self.laneID = snapshot.id
        self.owner = owner
        self.base = base
        return Value(laneID: snapshot.id, owner: owner, base: base)
    }

    func close() async {
        guard let laneID, let owner else {
            self.laneID = nil
            self.owner = nil
            return
        }
        self.laneID = nil
        self.owner = nil
        _ = try? await C05SFTPDomain.shared.disconnect(laneID: laneID, owner: owner)
    }

    private func laneIsConnected(_ laneID: UUID, owner: C05RemoteOwner) async -> Bool {
        guard let snapshot = try? await C05SFTPDomain.shared.laneStatus(
            laneID: laneID, owner: owner) else {
            return false
        }
        return snapshot.state == .connected && snapshot.transportConnected
    }
}
