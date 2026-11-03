// SPDX-License-Identifier: MPL-2.0
//
// C02 — durable task execution target, explicit migration and run pinning.
//
// Contract (IOS-D35 / G11 execution-target pinning, adapted to the Android
// all-code closure):
//   * ONE trusted target tuple is persisted per ordinary task before any
//     executable tool. The tuple carries the kind, the ACTUAL environment
//     identity, project/workspace/task ownership, the configured SSH host,
//     the shell-root and engine-owner hashes, the runtime root epoch, a
//     monotonic revision and provenance.
//   * First writer wins. Later settings/UI defaults never rewrite an
//     existing task target; changing it requires the explicit migration
//     ledger below (validate destination, show affected work, stop/drain
//     only old owned execution, reject timeout, then one CAS commit).
//   * Historical/completed/cancelled runs and their outputs keep the pin
//     they actually ran under. A late callback whose run pin/target
//     revision/root epoch no longer matches is never allowed to mutate the
//     new target.
//   * Temporary chat has no target row, no run pin and no SSH session.
//
// This file is source-only: it is not compiled or executed by the authoring
// lane. Main owns the coordinated schema registration (current registered
// 51; the declarative fragment is in the private package) and all central
// RuntimeFacade/RunContext/jobs wiring. The SQLite store below queries the
// Main-registered tables and fails closed with a typed schema error when
// they are absent; it never edits an existing migration or opens a second
// DatabaseManager.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeTools

// MARK: - Wire constants

public enum C02ExecutionTargetWire {
    /// Reserved trusted-host channel. Main owns the C ABI/bridge branch.
    public static let version = 19
    public static let schema = "floe.target/19"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 48 * 1_024
    public static let maximumIdentifierBytes = 128
    public static let maximumRemotePathBytes = 4_096
    public static let maximumCapabilityLosses = 32
    public static let hostKeyChallengeLifetime: TimeInterval = 300
}

// MARK: - Errors

public enum C02ExecutionTargetError: Error, Sendable, Equatable {
    case invalidTarget(String)
    case targetNotFound
    case targetSelectionRequired
    case targetAlreadyPinned
    case staleRevision(expected: Int64, actual: Int64)
    case environmentMissing(String)
    case environmentUnavailable(String)
    case environmentNotOwned
    case remoteHostMissing
    case remoteHostNotFound
    case remoteNotExecutionEnvironment
    case remoteExecutionNotAllowed
    case temporaryTaskRefused
    case workspaceOwnershipMismatch
    case runtimeIdentityUnavailable
    case rootEpochUnavailable
    case migrationAlreadyActive
    case migrationNotFound
    case migrationNotVerified
    case migrationCancelled
    case drainTimedOut(C02DrainReceipt)
    case runBoundToDifferentTarget
    case runTargetMissing
    case receiptUnavailable
    case schemaUnavailable
    case hostKeyApprovalRequired(C02RemoteHostKeyChallenge)
    case hostKeyChanged
    case storeCorrupted
    case cancelled

    /// Stable machine-facing reason used by the trusted-host wire. Never
    /// includes a path, command, credential or remote prose.
    public var code: String {
        switch self {
        case .invalidTarget(let reason): return "invalidTarget:\(reason)"
        case .targetNotFound: return "targetNotFound"
        case .targetSelectionRequired: return "targetSelectionRequired"
        case .targetAlreadyPinned: return "targetAlreadyPinned"
        case .staleRevision: return "staleRevision"
        case .environmentMissing: return "environmentMissing"
        case .environmentUnavailable: return "environmentUnavailable"
        case .environmentNotOwned: return "environmentNotOwned"
        case .remoteHostMissing: return "remoteHostMissing"
        case .remoteHostNotFound: return "remoteHostNotFound"
        case .remoteNotExecutionEnvironment: return "remoteNotExecutionEnvironment"
        case .remoteExecutionNotAllowed: return "remoteExecutionNotAllowed"
        case .temporaryTaskRefused: return "temporaryTaskRefused"
        case .workspaceOwnershipMismatch: return "workspaceOwnershipMismatch"
        case .runtimeIdentityUnavailable: return "runtimeIdentityUnavailable"
        case .rootEpochUnavailable: return "rootEpochUnavailable"
        case .migrationAlreadyActive: return "migrationAlreadyActive"
        case .migrationNotFound: return "migrationNotFound"
        case .migrationNotVerified: return "migrationNotVerified"
        case .migrationCancelled: return "migrationCancelled"
        case .drainTimedOut: return "drainTimedOut"
        case .runBoundToDifferentTarget: return "runBoundToDifferentTarget"
        case .runTargetMissing: return "runTargetMissing"
        case .receiptUnavailable: return "receiptUnavailable"
        case .schemaUnavailable: return "schemaUnavailable"
        case .hostKeyApprovalRequired: return "hostKeyApprovalRequired"
        case .hostKeyChanged: return "hostKeyChanged"
        case .storeCorrupted: return "storeCorrupted"
        case .cancelled: return "cancelled"
        }
    }

    /// Secret-free user-facing description. UI localises the stable code;
    /// this string is diagnostic only.
    public var message: String {
        switch self {
        case .invalidTarget(let reason): return "The execution target is invalid: \(reason)"
        case .targetNotFound: return "This task has no pinned execution target yet."
        case .targetSelectionRequired: return "Choose where this task should run before starting it."
        case .targetAlreadyPinned: return "This task already runs somewhere else. Move the task explicitly instead of changing a default."
        case .staleRevision: return "The execution target changed. Refresh and try again."
        case .environmentMissing(let id): return "The execution environment \(id) no longer exists."
        case .environmentUnavailable(let id): return "The execution environment \(id) is stopped, rebuilding or unavailable."
        case .environmentNotOwned: return "The environment belongs to another task or workspace."
        case .remoteHostMissing: return "No SSH host is selected."
        case .remoteHostNotFound: return "The configured SSH host no longer exists."
        case .remoteNotExecutionEnvironment: return "The selected host is not configured as an SSH execution environment."
        case .remoteExecutionNotAllowed: return "Remote execution is disabled for this task."
        case .temporaryTaskRefused: return "Temporary chats cannot pin an execution target or open SSH sessions."
        case .workspaceOwnershipMismatch: return "The task workspace ownership could not be verified."
        case .runtimeIdentityUnavailable: return "The runtime identity is not available yet."
        case .rootEpochUnavailable: return "The native runtime generation is not active."
        case .migrationAlreadyActive: return "Another move is already in progress for this task."
        case .migrationNotFound: return "No execution-target move is in progress."
        case .migrationNotVerified: return "The destination has not been verified for commit."
        case .migrationCancelled: return "The move was cancelled; the original target is unchanged."
        case .drainTimedOut: return "The original environment still owns running work. Nothing was switched."
        case .runBoundToDifferentTarget: return "This run is already bound to another execution target."
        case .runTargetMissing: return "This run has no execution-target pin; resume it from its original task."
        case .receiptUnavailable: return "The remote operation receipt could not be recorded, so nothing was dispatched."
        case .schemaUnavailable: return "The execution-target schema is not installed in this build."
        case .hostKeyApprovalRequired: return "Confirm the SSH host key before using this host."
        case .hostKeyChanged: return "The SSH host key changed. The stored key was left unchanged."
        case .storeCorrupted: return "The saved execution target is unreadable."
        case .cancelled: return "The operation was cancelled."
        }
    }

    public var retryable: Bool {
        switch self {
        case .staleRevision, .environmentUnavailable, .rootEpochUnavailable, .drainTimedOut:
            return true
        default:
            return false
        }
    }
}

// MARK: - Target value

public enum C02ExecutionTargetKind: String, Codable, Sendable, CaseIterable {
    case localLinux
    case ssh
}

public enum C02ExecutionTargetProvenance: String, Codable, Sendable, CaseIterable {
    /// The user explicitly chose the destination for a new task.
    case explicitUserSelection
    /// The task was explicitly moved from another target.
    case migrated
    /// One exact existing session/project environment owned by this task was
    /// adopted because it was the only candidate. Never a first-project or
    /// temporary-directory fallback.
    case adoptedExistingEnvironment
}

/// Actual remote facts frozen into the target. `runtimeGeneration` is the
/// real remote boot identity observed by the read-only probe, never a
/// fabricated counter. A changed generation makes the old pin stale.
public struct C02RemoteEnvironmentFacts: Codable, Sendable, Hashable {
    public var hostID: UUID
    public var remoteRootPath: String
    public var operatingSystem: String
    public var architecture: String
    public var runtimeGeneration: String
    public var distribution: String?
    public var hostKeyFingerprintSHA256: String?

    public init(
        hostID: UUID,
        remoteRootPath: String,
        operatingSystem: String,
        architecture: String,
        runtimeGeneration: String,
        distribution: String? = nil,
        hostKeyFingerprintSHA256: String? = nil
    ) {
        self.hostID = hostID
        self.remoteRootPath = remoteRootPath
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.runtimeGeneration = runtimeGeneration
        self.distribution = distribution
        self.hostKeyFingerprintSHA256 = hostKeyFingerprintSHA256
    }
}

/// One task's frozen execution target tuple.
public struct C02ExecutionTarget: Codable, Sendable, Hashable, Identifiable {
    public var taskID: UUID
    public var revision: Int64
    public var kind: C02ExecutionTargetKind
    /// Local container id, or the deterministic remote environment identity.
    public var environmentID: String
    /// C01 project UUID when this task belongs to a managed project.
    public var projectID: UUID?
    /// C01 workspace UUID (managed project id or private-task workspace id).
    public var workspaceID: UUID
    /// SHA256 of the trusted canonical Core workspace root. This is the
    /// shell project identity; it is NOT the workspace UUID.
    public var shellRootHash: String
    /// SHA256 of the actual Linux engine project identity. It is derived from
    /// the engine's stable project mapping, not from the environment id and
    /// not from the workspace UUID.
    public var engineOwnerHash: String
    /// Native runtime root generation captured when this target was pinned.
    /// Run pins capture their own per-execution epoch.
    public var rootEpoch: UInt64
    public var remote: C02RemoteEnvironmentFacts?
    public var provenance: C02ExecutionTargetProvenance
    public var createdAt: Date
    public var updatedAt: Date

    public var id: UUID { taskID }
    public var remoteHostID: UUID? { remote?.hostID }
    public var remoteRootPath: String? { remote?.remoteRootPath }

    public init(
        taskID: UUID,
        revision: Int64,
        kind: C02ExecutionTargetKind,
        environmentID: String,
        projectID: UUID?,
        workspaceID: UUID,
        shellRootHash: String,
        engineOwnerHash: String,
        rootEpoch: UInt64,
        remote: C02RemoteEnvironmentFacts?,
        provenance: C02ExecutionTargetProvenance,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.taskID = taskID
        self.revision = revision
        self.kind = kind
        self.environmentID = environmentID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.shellRootHash = shellRootHash
        self.engineOwnerHash = engineOwnerHash
        self.rootEpoch = rootEpoch
        self.remote = remote
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard revision > 0, revision < Int64.max else {
            throw C02ExecutionTargetError.invalidTarget("revision")
        }
        guard Self.isValidIdentifier(environmentID) else {
            throw C02ExecutionTargetError.invalidTarget("environmentID")
        }
        guard Self.isSHA256(shellRootHash), Self.isSHA256(engineOwnerHash) else {
            throw C02ExecutionTargetError.invalidTarget("identityHash")
        }
        guard rootEpoch > 0, rootEpoch <= UInt64(Int64.max) else {
            throw C02ExecutionTargetError.invalidTarget("rootEpoch")
        }
        switch kind {
        case .localLinux:
            guard remote == nil else {
                throw C02ExecutionTargetError.invalidTarget("localTargetHasRemoteFacts")
            }
        case .ssh:
            guard let remote else {
                throw C02ExecutionTargetError.invalidTarget("sshTargetMissingRemoteFacts")
            }
            guard Self.isValidRemoteRoot(remote.remoteRootPath) else {
                throw C02ExecutionTargetError.invalidTarget("remoteRootPath")
            }
            guard remote.operatingSystem == "linux" || remote.operatingSystem == "macos" else {
                throw C02ExecutionTargetError.invalidTarget("remoteOperatingSystem")
            }
            guard !remote.architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  remote.architecture.utf8.count <= 64 else {
                throw C02ExecutionTargetError.invalidTarget("remoteArchitecture")
            }
            guard !remote.runtimeGeneration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  remote.runtimeGeneration.utf8.count <= 256 else {
                throw C02ExecutionTargetError.invalidTarget("remoteGeneration")
            }
            if let fingerprint = remote.hostKeyFingerprintSHA256 {
                guard SSHHostKeyFingerprint.normalize(fingerprint).utf8.count >= 32 else {
                    throw C02ExecutionTargetError.invalidTarget("hostKeyFingerprint")
                }
            }
        }
    }

    /// Identity fields are immutable across revisions. Only `revision`,
    /// `provenance`, `updatedAt` and remote generation evidence may advance.
    public func sameStableIdentity(as other: C02ExecutionTarget) -> Bool {
        taskID == other.taskID
            && kind == other.kind
            && environmentID == other.environmentID
            && projectID == other.projectID
            && workspaceID == other.workspaceID
            && shellRootHash == other.shellRootHash
            && engineOwnerHash == other.engineOwnerHash
            && remote?.hostID == other.remote?.hostID
            && remote?.remoteRootPath == other.remote?.remoteRootPath
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    public static func isValidRemoteRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= C02ExecutionTargetWire.maximumRemotePathBytes,
              !path.contains("\0"), !path.contains("//") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return false }
        return true
    }

    public static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Deterministic remote environment identity. This is an execution identity,
/// not a local FloeEnvironments container: it is derived from the exact host
/// and remote task root and can never collide with a local container id.
public enum C02RemoteEnvironmentID {
    public static func make(hostID: UUID, remoteRootPath: String) -> String {
        let digest = FloeDigest.sha256Hex(Data(remoteRootPath.utf8))
        return "ssh-" + hostID.uuidString.lowercased() + "-" + String(digest.prefix(16))
    }

    public static func defaultTaskRoot(home: String, taskID: UUID) -> String? {
        guard C02ExecutionTarget.isValidRemoteRoot(home) else { return nil }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return trimmed + "/.floe/tasks/" + taskID.uuidString.lowercased()
    }
}

// MARK: - Selection / options

public struct C02ExecutionTargetSelection: Sendable, Equatable, Codable {
    public var kind: C02ExecutionTargetKind
    public var environmentID: String?
    public var remoteHostID: UUID?
    /// Must be true for a first-run selection. A system default is not an
    /// explicit target choice and is refused by `initialize`.
    public var explicitUserChoice: Bool

    public init(
        kind: C02ExecutionTargetKind,
        environmentID: String? = nil,
        remoteHostID: UUID? = nil,
        explicitUserChoice: Bool
    ) {
        self.kind = kind
        self.environmentID = environmentID
        self.remoteHostID = remoteHostID
        self.explicitUserChoice = explicitUserChoice
    }

    public func matches(_ target: C02ExecutionTarget) -> Bool {
        guard kind == target.kind else { return false }
        switch kind {
        case .localLinux:
            return environmentID == target.environmentID
        case .ssh:
            return remoteHostID == target.remoteHostID
        }
    }
}

public struct C02LocalEnvironmentOption: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String?
    public var kind: String
    public var state: String
    public var requiresRebuild: Bool

    public init(id: String, name: String?, kind: String, state: String, requiresRebuild: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.requiresRebuild = requiresRebuild
    }
}

public struct C02RemoteHostOption: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var operatingSystemHint: String?
    public var isExecutionEnvironment: Bool
    public var sshConfigured: Bool

    public init(
        id: UUID,
        displayName: String,
        operatingSystemHint: String? = nil,
        isExecutionEnvironment: Bool,
        sshConfigured: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.operatingSystemHint = operatingSystemHint
        self.isExecutionEnvironment = isExecutionEnvironment
        self.sshConfigured = sshConfigured
    }
}

public struct C02ExecutionTargetOptions: Sendable, Equatable, Codable {
    public var taskID: UUID
    public var current: C02ExecutionTarget?
    public var activeMigration: C02TargetMigration?
    public var localEnvironments: [C02LocalEnvironmentOption]
    public var remoteHosts: [C02RemoteHostOption]
    public var remoteExecutionAllowed: Bool
    /// False when no local environment is both owned by this task and
    /// qualified; the UI shows preparation guidance instead of inventing one.
    public var hasUsableLocalEnvironment: Bool
    public var canCreateInitialTarget: Bool

    public init(
        taskID: UUID,
        current: C02ExecutionTarget?,
        activeMigration: C02TargetMigration?,
        localEnvironments: [C02LocalEnvironmentOption],
        remoteHosts: [C02RemoteHostOption],
        remoteExecutionAllowed: Bool,
        hasUsableLocalEnvironment: Bool,
        canCreateInitialTarget: Bool
    ) {
        self.taskID = taskID
        self.current = current
        self.activeMigration = activeMigration
        self.localEnvironments = localEnvironments
        self.remoteHosts = remoteHosts
        self.remoteExecutionAllowed = remoteExecutionAllowed
        self.hasUsableLocalEnvironment = hasUsableLocalEnvironment
        self.canCreateInitialTarget = canCreateInitialTarget
    }
}

// MARK: - Ownership / policy / environment providers

/// Workspace/task ownership + the three distinct runtime identities. A
/// production provider resolves these from the C01 workspace row, the
/// trusted storage root, the real Linux shell project mapping and the live
/// native root epoch. No provider may substitute the workspace UUID,
/// environment id or shell hash for one another.
public struct C02TargetOwnership: Sendable, Equatable {
    public var taskID: UUID
    public var projectID: UUID?
    public var workspaceID: UUID
    public var workspaceRoot: URL
    public var shellRootHash: String
    public var engineOwnerHash: String
    public var rootEpoch: UInt64

    public init(
        taskID: UUID,
        projectID: UUID?,
        workspaceID: UUID,
        workspaceRoot: URL,
        shellRootHash: String,
        engineOwnerHash: String,
        rootEpoch: UInt64
    ) {
        self.taskID = taskID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.workspaceRoot = workspaceRoot
        self.shellRootHash = shellRootHash
        self.engineOwnerHash = engineOwnerHash
        self.rootEpoch = rootEpoch
    }
}

public protocol C02ExecutionTargetOwnershipProviding: Sendable {
    func ownership(taskID: UUID) async throws -> C02TargetOwnership?
}

public struct C02TargetTaskPolicy: Sendable, Equatable {
    public var isTemporary: Bool
    public var isOrdinary: Bool
    public var remoteExecutionAllowed: Bool

    public init(isTemporary: Bool, isOrdinary: Bool, remoteExecutionAllowed: Bool) {
        self.isTemporary = isTemporary
        self.isOrdinary = isOrdinary
        self.remoteExecutionAllowed = remoteExecutionAllowed
    }
}

public protocol C02ExecutionTargetPolicyProviding: Sendable {
    func policy(taskID: UUID) async throws -> C02TargetTaskPolicy
}

public struct C02LocalEnvironmentFacts: Sendable, Equatable {
    public var id: String
    public var name: String?
    public var kind: String
    public var state: String
    public var requiresRebuild: Bool
    public var executionBackend: String?
    public var ownerID: String?

    public init(
        id: String,
        name: String?,
        kind: String,
        state: String,
        requiresRebuild: Bool,
        executionBackend: String?,
        ownerID: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.requiresRebuild = requiresRebuild
        self.executionBackend = executionBackend
        self.ownerID = ownerID
    }

    public func isQualified(ownership: C02TargetOwnership) -> Bool {
        guard state == "active", !requiresRebuild,
              executionBackend == "linuxPRoot" else { return false }
        switch kind {
        case "session":
            return ownerID?.lowercased() == ownership.taskID.uuidString.lowercased()
        case "project":
            return ownerID?.lowercased() == ownership.workspaceID.uuidString.lowercased()
        default:
            return false
        }
    }
}

public struct C02RemoteHostSummary: Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var address: String
    public var port: Int
    public var user: String
    public var isExecutionEnvironment: Bool
    public var sshConfigured: Bool
    public var hostKeyPinnedFingerprint: String?

    public init(
        id: UUID,
        displayName: String,
        address: String,
        port: Int,
        user: String,
        isExecutionEnvironment: Bool,
        sshConfigured: Bool,
        hostKeyPinnedFingerprint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.isExecutionEnvironment = isExecutionEnvironment
        self.sshConfigured = sshConfigured
        self.hostKeyPinnedFingerprint = hostKeyPinnedFingerprint
    }
}

public protocol C02ExecutionTargetEnvironmentProviding: Sendable {
    func localEnvironments(taskID: UUID, ownership: C02TargetOwnership) async throws -> [C02LocalEnvironmentFacts]
    func validateLocal(
        environmentID: String,
        taskID: UUID,
        ownership: C02TargetOwnership
    ) async throws -> C02LocalEnvironmentFacts
    func remoteHosts(taskID: UUID) async throws -> [C02RemoteHostSummary]
    func validateRemoteHost(hostID: UUID, taskID: UUID) async throws -> C02RemoteHostSummary
}

/// Read-only probe used during explicit migration checks. Implemented by the
/// real SSH adapter; it never executes model commands.
public protocol C02RemoteTargetProbing: Sendable {
    func probeRemote(
        hostID: UUID,
        taskID: UUID,
        expectedFingerprint: String?
    ) async throws -> C02RemoteEnvironmentFacts
}

public protocol C02RemoteHostTrusting: Sendable {
    func trust(
        hostID: UUID,
        address: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String
    ) async throws
}

// MARK: - Owned work drain

public struct C02OwnedWorkSummary: Sendable, Hashable, Codable {
    public var liveRuns: Int
    public var liveChildRuns: Int
    public var activeJobs: Int
    public var shellSessions: Int
    public var managedServices: Int
    public var unknownOutcomes: Int
    public var files: Int
    public var bytes: Int64

    public init(
        liveRuns: Int = 0,
        liveChildRuns: Int = 0,
        activeJobs: Int = 0,
        shellSessions: Int = 0,
        managedServices: Int = 0,
        unknownOutcomes: Int = 0,
        files: Int = 0,
        bytes: Int64 = 0
    ) {
        self.liveRuns = liveRuns
        self.liveChildRuns = liveChildRuns
        self.activeJobs = activeJobs
        self.shellSessions = shellSessions
        self.managedServices = managedServices
        self.unknownOutcomes = unknownOutcomes
        self.files = files
        self.bytes = bytes
    }

    public var hasLiveWork: Bool {
        liveRuns + liveChildRuns + activeJobs + shellSessions + managedServices + unknownOutcomes > 0
    }
}

public struct C02OwnedWorkFence: Sendable, Equatable {
    public var id: UUID
    public var taskID: UUID
    public var environmentID: String
    public var targetRevision: Int64
    public var rootEpoch: UInt64
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        environmentID: String,
        targetRevision: Int64,
        rootEpoch: UInt64,
        createdAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.environmentID = environmentID
        self.targetRevision = targetRevision
        self.rootEpoch = rootEpoch
        self.createdAt = createdAt
    }
}

public struct C02DrainReceipt: Sendable, Hashable, Codable {
    public var complete: Bool
    public var timedOut: Bool
    public var stoppedRuns: Int
    public var stoppedJobs: Int
    public var closedSessions: Int
    public var closedServices: Int
    public var unknownOutcomes: Int
    public var detailCode: String?

    public init(
        complete: Bool,
        timedOut: Bool,
        stoppedRuns: Int = 0,
        stoppedJobs: Int = 0,
        closedSessions: Int = 0,
        closedServices: Int = 0,
        unknownOutcomes: Int = 0,
        detailCode: String? = nil
    ) {
        self.complete = complete
        self.timedOut = timedOut
        self.stoppedRuns = stoppedRuns
        self.stoppedJobs = stoppedJobs
        self.closedSessions = closedSessions
        self.closedServices = closedServices
        self.unknownOutcomes = unknownOutcomes
        self.detailCode = detailCode
    }
}

public protocol C02ExecutionTargetDraining: Sendable {
    func preview(taskID: UUID, environmentID: String, targetRevision: Int64) async throws -> C02OwnedWorkSummary
    func fence(
        taskID: UUID,
        environmentID: String,
        targetRevision: Int64,
        rootEpoch: UInt64
    ) async throws -> C02OwnedWorkFence
    /// Stops/checkpoints/drains ONLY the old owned work. Returning a receipt
    /// with `timedOut`/`complete == false` is mandatory on timeout.
    func drain(_ fence: C02OwnedWorkFence, timeout: Duration) async throws -> C02DrainReceipt
    func release(_ fence: C02OwnedWorkFence) async
    /// Closes model-owned SSH sessions for the old target. The host UI lane
    /// is not touched. Called before commit.
    func closeRemoteSessions(taskID: UUID, targetRevision: Int64, rootEpoch: UInt64) async
}

// MARK: - Migration values

public struct C02TargetMigration: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case checking
        case draining
        case verified
        case committed
        case completed
        case failed
        case cancelled

        public var isTerminal: Bool { self == .completed || self == .cancelled }
        public var isCommitted: Bool { self == .committed || self == .completed }
    }

    public var id: UUID
    public var taskID: UUID
    public var source: C02ExecutionTarget
    public var destination: C02ExecutionTarget
    public var phase: Phase
    public var revision: Int64
    public var cancellationRequested: Bool
    public var affectedWork: C02OwnedWorkSummary
    public var drainReceipt: C02DrainReceipt?
    public var failureCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        source: C02ExecutionTarget,
        destination: C02ExecutionTarget,
        phase: Phase = .checking,
        revision: Int64 = 1,
        cancellationRequested: Bool = false,
        affectedWork: C02OwnedWorkSummary = C02OwnedWorkSummary(),
        drainReceipt: C02DrainReceipt? = nil,
        failureCode: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.source = source
        self.destination = destination
        self.phase = phase
        self.revision = revision
        self.cancellationRequested = cancellationRequested
        self.affectedWork = affectedWork
        self.drainReceipt = drainReceipt
        self.failureCode = failureCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard taskID == source.taskID, taskID == destination.taskID else {
            throw C02ExecutionTargetError.invalidTarget("migrationTask")
        }
        guard source.revision > 0, destination.revision > source.revision else {
            throw C02ExecutionTargetError.invalidTarget("migrationRevisions")
        }
        try source.validate()
        try destination.validate()
        guard !source.sameStableIdentity(as: destination) else {
            throw C02ExecutionTargetError.invalidTarget("migrationSourceEqualsDestination")
        }
    }
}

public struct C02MigrationPreview: Sendable, Equatable {
    public var taskID: UUID
    public var source: C02ExecutionTarget
    public var destination: C02ExecutionTarget
    public var affectedWork: C02OwnedWorkSummary
    /// True when the old target still owns live work. The move can only
    /// proceed through the explicit drain gate.
    public var requiresDrain: Bool
    public var remoteHostKeyChallenge: C02RemoteHostKeyChallenge?
    public var canCommit: Bool
    public var generatedAt: Date
    public var expiresAt: Date

    public init(
        taskID: UUID,
        source: C02ExecutionTarget,
        destination: C02ExecutionTarget,
        affectedWork: C02OwnedWorkSummary,
        requiresDrain: Bool,
        remoteHostKeyChallenge: C02RemoteHostKeyChallenge?,
        canCommit: Bool,
        generatedAt: Date,
        expiresAt: Date
    ) {
        self.taskID = taskID
        self.source = source
        self.destination = destination
        self.affectedWork = affectedWork
        self.requiresDrain = requiresDrain
        self.remoteHostKeyChallenge = remoteHostKeyChallenge
        self.canCommit = canCommit
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Host-key challenge / approval

public struct C02RemoteHostKeyChallenge: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case firstUse
        case changed
    }

    public var id: UUID
    public var taskID: UUID
    public var hostID: UUID
    public var address: String
    public var port: Int
    public var keyType: String
    public var fingerprintSHA256: String
    public var expectedFingerprintSHA256: String?
    public var kind: Kind
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        hostID: UUID,
        address: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String,
        expectedFingerprintSHA256: String?,
        kind: Kind,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.hostID = hostID
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

public struct C02HostKeyApproval: Sendable, Equatable, Codable {
    public var trusted: Bool
    public var changed: Bool
    public var challengeID: UUID
    public var fingerprintSHA256: String?

    public init(trusted: Bool, changed: Bool, challengeID: UUID, fingerprintSHA256: String?) {
        self.trusted = trusted
        self.changed = changed
        self.challengeID = challengeID
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

// MARK: - Run pin / receipt

public struct C02RunTargetPin: Sendable, Equatable, Codable {
    public var runID: UUID
    public var taskID: UUID
    public var targetRevision: Int64
    public var environmentID: String
    public var shellRootHash: String
    public var engineOwnerHash: String
    /// Execution-generation fence. A late callback from an earlier epoch is
    /// never accepted against a newer pin.
    public var rootEpoch: UInt64
    public var pinnedAt: Date

    public init(
        runID: UUID,
        taskID: UUID,
        targetRevision: Int64,
        environmentID: String,
        shellRootHash: String,
        engineOwnerHash: String,
        rootEpoch: UInt64,
        pinnedAt: Date
    ) {
        self.runID = runID
        self.taskID = taskID
        self.targetRevision = targetRevision
        self.environmentID = environmentID
        self.shellRootHash = shellRootHash
        self.engineOwnerHash = engineOwnerHash
        self.rootEpoch = rootEpoch
        self.pinnedAt = pinnedAt
    }

    public func matches(_ target: C02ExecutionTarget) -> Bool {
        targetRevision == target.revision
            && taskID == target.taskID
            && environmentID == target.environmentID
            && shellRootHash == target.shellRootHash
            && engineOwnerHash == target.engineOwnerHash
    }
}

public struct C02RemoteCommandReceipt: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case dispatched
        case notStarted
        case exited
        case cancelled
        case timedOut
        case outcomeUnknown
    }

    public var operationID: String
    public var taskID: UUID
    public var runID: UUID?
    public var toolCallID: String?
    public var targetRevision: Int64
    public var rootEpoch: UInt64
    public var hostID: UUID
    public var commandSHA256: String
    public var state: State
    public var exitCode: Int32?
    public var startedAt: Date
    public var updatedAt: Date
    public var detailCode: String?

    public init(
        operationID: String,
        taskID: UUID,
        runID: UUID?,
        toolCallID: String?,
        targetRevision: Int64,
        rootEpoch: UInt64,
        hostID: UUID,
        commandSHA256: String,
        state: State,
        exitCode: Int32? = nil,
        startedAt: Date,
        updatedAt: Date,
        detailCode: String? = nil
    ) {
        self.operationID = operationID
        self.taskID = taskID
        self.runID = runID
        self.toolCallID = toolCallID
        self.targetRevision = targetRevision
        self.rootEpoch = rootEpoch
        self.hostID = hostID
        self.commandSHA256 = commandSHA256
        self.state = state
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.detailCode = detailCode
    }

    public static func isValidOperationID(_ value: String) -> Bool {
        guard (8...256).contains(value.utf8.count), !value.contains("\0") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Schema (declarative; Main registers it once)

public enum C02ExecutionTargetSchema {
    /// Exact additive statements for Main's coordinated next schema
    /// registration. This fragment does not edit DatabaseManager, V50/V51 or
    /// any existing migration. `PRAGMA user_version` is deliberately absent;
    /// Main pairs it with the coordinated version when registering.
    public static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS task_execution_targets (
            conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            revision INTEGER NOT NULL CHECK(revision > 0),
            kind TEXT NOT NULL CHECK(kind IN ('localLinux','ssh')),
            environment_id TEXT NOT NULL,
            project_id TEXT,
            workspace_id TEXT NOT NULL,
            shell_root_hash TEXT NOT NULL,
            engine_owner_hash TEXT NOT NULL,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            remote_host_id TEXT,
            remote_root_path TEXT,
            remote_os TEXT,
            remote_architecture TEXT,
            remote_generation TEXT,
            provenance TEXT NOT NULL,
            body_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK (
                (kind = 'ssh' AND remote_host_id IS NOT NULL
                    AND remote_root_path IS NOT NULL
                    AND remote_generation IS NOT NULL AND length(remote_generation) > 0)
                OR
                (kind = 'localLinux' AND remote_host_id IS NULL
                    AND remote_root_path IS NULL AND remote_generation IS NULL)
            )
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS task_execution_targets_workspace
        ON task_execution_targets(workspace_id)
        """,
        """
        CREATE INDEX IF NOT EXISTS task_execution_targets_remote_host
        ON task_execution_targets(remote_host_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS task_execution_target_migrations (
            id TEXT PRIMARY KEY NOT NULL,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            phase TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            source_revision INTEGER NOT NULL,
            body_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS task_execution_target_migration_active
        ON task_execution_target_migrations(conversation_id)
        WHERE phase NOT IN ('completed', 'cancelled', 'failed')
        """,
        """
        CREATE INDEX IF NOT EXISTS task_execution_target_migration_status
        ON task_execution_target_migrations(conversation_id, phase, revision)
        """,
        """
        CREATE TABLE IF NOT EXISTS task_run_execution_targets (
            run_id TEXT PRIMARY KEY NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            target_revision INTEGER NOT NULL CHECK(target_revision > 0),
            environment_id TEXT NOT NULL,
            shell_root_hash TEXT NOT NULL,
            engine_owner_hash TEXT NOT NULL,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            body_json TEXT NOT NULL,
            pinned_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS task_run_execution_targets_task
        ON task_run_execution_targets(conversation_id, target_revision)
        """,
        """
        CREATE TABLE IF NOT EXISTS task_remote_command_receipts (
            operation_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            run_id TEXT,
            tool_call_id TEXT,
            target_revision INTEGER NOT NULL CHECK(target_revision > 0),
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            host_id TEXT NOT NULL,
            command_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('dispatched','notStarted','exited','cancelled','timedOut','outcomeUnknown')),
            exit_code INTEGER,
            started_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            detail_code TEXT,
            body_json TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS task_remote_command_receipts_task
        ON task_remote_command_receipts(task_id, updated_at)
        """,
    ]
}

// MARK: - Store

public protocol C02ExecutionTargetStoring: Sendable {
    func target(taskID: UUID) async throws -> C02ExecutionTarget?
    func insertInitial(_ target: C02ExecutionTarget) async throws -> C02ExecutionTarget
    func activeMigration(taskID: UUID) async throws -> C02TargetMigration?
    func latestMigration(taskID: UUID) async throws -> C02TargetMigration?
    func beginMigration(_ migration: C02TargetMigration) async throws
    func updateMigration(
        _ migration: C02TargetMigration,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration
    func requestMigrationCancellation(
        taskID: UUID,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration?
    func commitMigration(
        _ migration: C02TargetMigration
    ) async throws -> C02MigrationCommit
    func finishMigration(
        _ migration: C02TargetMigration,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration
    func pinRun(_ pin: C02RunTargetPin) async throws -> C02RunTargetPin
    func runPin(runID: UUID) async throws -> C02RunTargetPin?
    func receipt(operationID: String) async throws -> C02RemoteCommandReceipt?
    func recordReceipt(_ receipt: C02RemoteCommandReceipt) async throws -> C02RemoteCommandReceipt
}

public struct C02MigrationCommit: Sendable, Equatable {
    public var target: C02ExecutionTarget
    public var migration: C02TargetMigration

    public init(target: C02ExecutionTarget, migration: C02TargetMigration) {
        self.target = target
        self.migration = migration
    }
}

public struct C02SQLiteExecutionTargetStore: C02ExecutionTargetStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func target(taskID: UUID) async throws -> C02ExecutionTarget? {
        try await database.reader { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_targets WHERE conversation_id = ?",
                arguments: [taskID.uuidString]
            ) else { return nil }
            return try Self.decode(C02ExecutionTarget.self, body)
        }
    }

    public func insertInitial(_ target: C02ExecutionTarget) async throws -> C02ExecutionTarget {
        try target.validate()
        guard target.revision == 1 else {
            throw C02ExecutionTargetError.invalidTarget("initialRevision")
        }
        return try await database.writer { db in
            try Self.requireSchema(db)
            let body = try Self.encode(target)
            let remote = target.remote
            try db.execute(sql: """
                INSERT INTO task_execution_targets (
                    conversation_id, revision, kind, environment_id, project_id,
                    workspace_id, shell_root_hash, engine_owner_hash, root_epoch,
                    remote_host_id, remote_root_path, remote_os,
                    remote_architecture, remote_generation, provenance,
                    body_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(conversation_id) DO NOTHING
                """, arguments: [
                    target.taskID.uuidString, target.revision, target.kind.rawValue,
                    target.environmentID, target.projectID?.uuidString,
                    target.workspaceID.uuidString, target.shellRootHash,
                    target.engineOwnerHash, Int64(target.rootEpoch),
                    remote?.hostID.uuidString, remote?.remoteRootPath,
                    remote?.operatingSystem, remote?.architecture,
                    remote?.runtimeGeneration, target.provenance.rawValue,
                    body, Self.iso(target.createdAt), Self.iso(target.updatedAt),
                ])
            guard let savedBody = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_targets WHERE conversation_id = ?",
                arguments: [target.taskID.uuidString]
            ) else {
                throw C02ExecutionTargetError.storeCorrupted
            }
            return try Self.decode(C02ExecutionTarget.self, savedBody)
        }
    }

    public func activeMigration(taskID: UUID) async throws -> C02TargetMigration? {
        try await migrationWhere(
            taskID: taskID,
            sqlSuffix: "AND phase NOT IN ('completed','cancelled','failed')"
        )
    }

    public func latestMigration(taskID: UUID) async throws -> C02TargetMigration? {
        try await migrationWhere(taskID: taskID, sqlSuffix: "")
    }

    private func migrationWhere(taskID: UUID, sqlSuffix: String) async throws -> C02TargetMigration? {
        try await database.reader { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(db, sql: """
                SELECT body_json FROM task_execution_target_migrations
                WHERE conversation_id = ? \(sqlSuffix)
                ORDER BY updated_at DESC, revision DESC LIMIT 1
                """, arguments: [taskID.uuidString]) else { return nil }
            return try Self.decode(C02TargetMigration.self, body)
        }
    }

    public func beginMigration(_ migration: C02TargetMigration) async throws {
        try migration.validate()
        guard migration.phase == .checking, migration.revision == 1,
              !migration.cancellationRequested,
              migration.drainReceipt == nil,
              migration.failureCode == nil else {
            throw C02ExecutionTargetError.invalidTarget("newMigrationState")
        }
        do {
            try await database.writer { db in
                try Self.requireSchema(db)
                guard let currentBody = try String.fetchOne(
                    db,
                    sql: "SELECT body_json FROM task_execution_targets WHERE conversation_id = ?",
                    arguments: [migration.taskID.uuidString]
                ) else {
                    throw C02ExecutionTargetError.targetNotFound
                }
                let current = try Self.decode(C02ExecutionTarget.self, currentBody)
                guard current.revision == migration.source.revision,
                      current.sameStableIdentity(as: migration.source) else {
                    throw C02ExecutionTargetError.staleRevision(
                        expected: migration.source.revision, actual: current.revision)
                }
                try db.execute(sql: """
                    INSERT INTO task_execution_target_migrations (
                        id, conversation_id, phase, revision, source_revision,
                        body_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        migration.id.uuidString, migration.taskID.uuidString,
                        migration.phase.rawValue, migration.revision,
                        migration.source.revision, try Self.encode(migration),
                        Self.iso(migration.createdAt), Self.iso(migration.updatedAt),
                    ])
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
    }

    public func updateMigration(
        _ migration: C02TargetMigration,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration {
        try migration.validate()
        guard expectedRevision > 0, migration.revision == expectedRevision else {
            throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: migration.revision)
        }
        return try await database.writer { db in
            try Self.requireSchema(db)
            guard let previousBody = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_target_migrations WHERE id = ? AND revision = ?",
                arguments: [migration.id.uuidString, expectedRevision]
            ) else {
                throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: 0)
            }
            let previous = try Self.decode(C02TargetMigration.self, previousBody)
            guard previous.taskID == migration.taskID,
                  previous.source.sameStableIdentity(as: migration.source),
                  previous.source.revision == migration.source.revision,
                  previous.destination.sameStableIdentity(as: migration.destination),
                  previous.destination.revision == migration.destination.revision else {
                throw C02ExecutionTargetError.invalidTarget("migrationIdentityChanged")
            }
            guard previous.phase != .committed, previous.phase != .completed,
                  previous.phase != .cancelled, previous.phase != .failed else {
                throw C02ExecutionTargetError.migrationNotVerified
            }
            guard Self.allowedTransition(from: previous.phase, to: migration.phase) else {
                throw C02ExecutionTargetError.invalidTarget("migrationPhase")
            }
            if previous.cancellationRequested || migration.cancellationRequested {
                guard migration.phase == .cancelled || migration.phase == .failed else {
                    throw C02ExecutionTargetError.migrationCancelled
                }
            }
            // A user stop is durable and cannot be cleared by a stale writer.
            var next = migration
            next.cancellationRequested = previous.cancellationRequested || migration.cancellationRequested
            next.revision = expectedRevision + 1
            next.updatedAt = Date()
            try db.execute(sql: """
                UPDATE task_execution_target_migrations
                SET phase = ?, revision = ?, body_json = ?, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [
                    next.phase.rawValue, next.revision, try Self.encode(next),
                    Self.iso(next.updatedAt), next.id.uuidString, expectedRevision,
                ])
            guard db.changesCount == 1 else {
                throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: 0)
            }
            return next
        }
    }

    public func requestMigrationCancellation(
        taskID: UUID,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration? {
        try await database.writer { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: """
                    SELECT body_json FROM task_execution_target_migrations
                    WHERE conversation_id = ? AND phase NOT IN ('completed','cancelled','committed','failed')
                    """,
                arguments: [taskID.uuidString]
            ) else { return nil }
            var migration = try Self.decode(C02TargetMigration.self, body)
            guard migration.revision == expectedRevision else {
                throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: migration.revision)
            }
            if migration.cancellationRequested { return migration }
            migration.cancellationRequested = true
            migration.revision += 1
            migration.updatedAt = Date()
            try db.execute(sql: """
                UPDATE task_execution_target_migrations
                SET revision = ?, body_json = ?, updated_at = ?
                WHERE id = ? AND revision = ? AND phase NOT IN ('completed','cancelled','committed','failed')
                """, arguments: [
                    migration.revision, try Self.encode(migration),
                    Self.iso(migration.updatedAt), migration.id.uuidString, expectedRevision,
                ])
            guard db.changesCount == 1 else {
                throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: 0)
            }
            return migration
        }
    }

    public func commitMigration(
        _ migration: C02TargetMigration
    ) async throws -> C02MigrationCommit {
        try migration.validate()
        return try await database.writer { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_target_migrations WHERE id = ?",
                arguments: [migration.id.uuidString]
            ) else {
                throw C02ExecutionTargetError.migrationNotFound
            }
            var saved = try Self.decode(C02TargetMigration.self, body)
            guard saved.phase == .verified, saved.revision == migration.revision,
                  !saved.cancellationRequested,
                  saved.source.sameStableIdentity(as: migration.source),
                  saved.destination.sameStableIdentity(as: migration.destination) else {
                throw C02ExecutionTargetError.migrationNotVerified
            }
            guard let currentBody = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_targets WHERE conversation_id = ?",
                arguments: [saved.taskID.uuidString]
            ) else {
                throw C02ExecutionTargetError.targetNotFound
            }
            var current = try Self.decode(C02ExecutionTarget.self, currentBody)
            guard current.revision == saved.source.revision,
                  current.sameStableIdentity(as: saved.source) else {
                throw C02ExecutionTargetError.staleRevision(
                    expected: saved.source.revision, actual: current.revision)
            }
            let now = Date()
            var committedTarget = saved.destination
            committedTarget.revision = current.revision + 1
            committedTarget.provenance = .migrated
            committedTarget.createdAt = current.createdAt
            committedTarget.updatedAt = now
            try committedTarget.validate()
            try db.execute(sql: """
                UPDATE task_execution_targets
                SET revision = ?, body_json = ?, provenance = ?, updated_at = ?
                WHERE conversation_id = ? AND revision = ?
                """, arguments: [
                    committedTarget.revision, try Self.encode(committedTarget),
                    committedTarget.provenance.rawValue, Self.iso(now),
                    committedTarget.taskID.uuidString, current.revision,
                ])
            guard db.changesCount == 1 else {
                throw C02ExecutionTargetError.staleRevision(
                    expected: current.revision, actual: 0)
            }
            // Nonterminal runs move with the task. Historical completed and
            // cancelled runs keep their original pins and remain readable.
            // Each body is a C02RunTargetPin (never the target JSON).
            let runIDStrings = try String.fetchAll(db, sql: """
                SELECT id FROM runs
                WHERE conversation_id = ?
                  AND state NOT IN ('completed','failed','cancelled','checkpointed','interrupted')
                """, arguments: [committedTarget.taskID.uuidString])
            for runIDString in runIDStrings {
                guard let runID = UUID(uuidString: runIDString) else {
                    throw C02ExecutionTargetError.storeCorrupted
                }
                let pin = C02RunTargetPin(
                    runID: runID,
                    taskID: committedTarget.taskID,
                    targetRevision: committedTarget.revision,
                    environmentID: committedTarget.environmentID,
                    shellRootHash: committedTarget.shellRootHash,
                    engineOwnerHash: committedTarget.engineOwnerHash,
                    rootEpoch: committedTarget.rootEpoch,
                    pinnedAt: now
                )
                try db.execute(sql: """
                    INSERT INTO task_run_execution_targets (
                        run_id, conversation_id, target_revision, environment_id,
                        shell_root_hash, engine_owner_hash, root_epoch, body_json, pinned_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO UPDATE SET
                        target_revision = excluded.target_revision,
                        environment_id = excluded.environment_id,
                        shell_root_hash = excluded.shell_root_hash,
                        engine_owner_hash = excluded.engine_owner_hash,
                        root_epoch = excluded.root_epoch,
                        body_json = excluded.body_json,
                        pinned_at = excluded.pinned_at
                    """, arguments: [
                        runID.uuidString, committedTarget.taskID.uuidString,
                        committedTarget.revision, committedTarget.environmentID,
                        committedTarget.shellRootHash, committedTarget.engineOwnerHash,
                        Int64(committedTarget.rootEpoch), try Self.encode(pin),
                        Self.iso(now),
                    ])
            }
            saved.phase = .committed
            saved.revision += 1
            saved.updatedAt = now
            saved.failureCode = nil
            if saved.revision >= Int64.max - 1 {
                throw C02ExecutionTargetError.invalidTarget("migrationRevision")
            }
            try db.execute(sql: """
                UPDATE task_execution_target_migrations
                SET phase = ?, revision = ?, body_json = ?, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [
                    saved.phase.rawValue, saved.revision, try Self.encode(saved),
                    Self.iso(now), saved.id.uuidString, migration.revision,
                ])
            guard db.changesCount == 1 else {
                throw C02ExecutionTargetError.staleRevision(
                    expected: migration.revision, actual: 0)
            }
            return C02MigrationCommit(target: committedTarget, migration: saved)
        }
    }

    public func finishMigration(
        _ migration: C02TargetMigration,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration {
        try await database.writer { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_execution_target_migrations WHERE id = ?",
                arguments: [migration.id.uuidString]
            ) else {
                throw C02ExecutionTargetError.migrationNotFound
            }
            var saved = try Self.decode(C02TargetMigration.self, body)
            if saved.phase == .completed { return saved }
            guard saved.phase == .committed, saved.revision == expectedRevision,
                  saved.revision < Int64.max else {
                throw C02ExecutionTargetError.migrationNotVerified
            }
            saved.phase = .completed
            saved.revision += 1
            saved.updatedAt = Date()
            saved.failureCode = nil
            try db.execute(sql: """
                UPDATE task_execution_target_migrations
                SET phase = ?, revision = ?, body_json = ?, updated_at = ?
                WHERE id = ? AND revision = ?
                """, arguments: [
                    saved.phase.rawValue, saved.revision, try Self.encode(saved),
                    Self.iso(saved.updatedAt), saved.id.uuidString, expectedRevision,
                ])
            guard db.changesCount == 1 else {
                throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: 0)
            }
            return saved
        }
    }

    public func pinRun(_ pin: C02RunTargetPin) async throws -> C02RunTargetPin {
        guard pin.targetRevision > 0, pin.rootEpoch > 0,
              C02ExecutionTarget.isSHA256(pin.shellRootHash),
              C02ExecutionTarget.isSHA256(pin.engineOwnerHash),
              C02ExecutionTarget.isValidIdentifier(pin.environmentID) else {
            throw C02ExecutionTargetError.invalidTarget("runPin")
        }
        return try await database.writer { db in
            try Self.requireSchema(db)
            guard try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM runs WHERE id = ?",
                arguments: [pin.runID.uuidString]
            ) == pin.taskID.uuidString else {
                throw C02ExecutionTargetError.runTargetMissing
            }
            if let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_run_execution_targets WHERE run_id = ?",
                arguments: [pin.runID.uuidString]
            ) {
                var existing = try Self.decode(C02RunTargetPin.self, body)
                guard existing.taskID == pin.taskID,
                      existing.targetRevision == pin.targetRevision,
                      existing.environmentID == pin.environmentID,
                      existing.shellRootHash == pin.shellRootHash,
                      existing.engineOwnerHash == pin.engineOwnerHash else {
                    throw C02ExecutionTargetError.runBoundToDifferentTarget
                }
                if existing.rootEpoch == pin.rootEpoch { return existing }
                // A resumed run may execute in a newer native generation.
                // The target revision is unchanged; only the execution fence
                // advances, so callbacks from the old epoch are rejected.
                existing.rootEpoch = pin.rootEpoch
                existing.pinnedAt = Date()
                try db.execute(sql: """
                    UPDATE task_run_execution_targets
                    SET root_epoch = ?, body_json = ?, pinned_at = ?
                    WHERE run_id = ?
                    """, arguments: [
                        Int64(existing.rootEpoch), try Self.encode(existing),
                        Self.iso(existing.pinnedAt), existing.runID.uuidString,
                    ])
                guard db.changesCount == 1 else {
                    throw C02ExecutionTargetError.staleRevision(expected: 0, actual: 0)
                }
                return existing
            }
            try db.execute(sql: """
                INSERT INTO task_run_execution_targets (
                    run_id, conversation_id, target_revision, environment_id,
                    shell_root_hash, engine_owner_hash, root_epoch, body_json, pinned_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    pin.runID.uuidString, pin.taskID.uuidString, pin.targetRevision,
                    pin.environmentID, pin.shellRootHash, pin.engineOwnerHash,
                    Int64(pin.rootEpoch), try Self.encode(pin), Self.iso(pin.pinnedAt),
                ])
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_run_execution_targets WHERE run_id = ?",
                arguments: [pin.runID.uuidString]
            ) else { throw C02ExecutionTargetError.storeCorrupted }
            return try Self.decode(C02RunTargetPin.self, body)
        }
    }

    public func runPin(runID: UUID) async throws -> C02RunTargetPin? {
        try await database.reader { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_run_execution_targets WHERE run_id = ?",
                arguments: [runID.uuidString]
            ) else { return nil }
            return try Self.decode(C02RunTargetPin.self, body)
        }
    }

    public func receipt(operationID: String) async throws -> C02RemoteCommandReceipt? {
        try await database.reader { db in
            try Self.requireSchema(db)
            guard let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_remote_command_receipts WHERE operation_id = ?",
                arguments: [operationID]
            ) else { return nil }
            return try Self.decode(C02RemoteCommandReceipt.self, body)
        }
    }

    public func recordReceipt(_ receipt: C02RemoteCommandReceipt) async throws -> C02RemoteCommandReceipt {
        guard C02RemoteCommandReceipt.isValidOperationID(receipt.operationID),
              receipt.targetRevision > 0, receipt.rootEpoch > 0,
              C02ExecutionTarget.isSHA256(receipt.commandSHA256) else {
            throw C02ExecutionTargetError.invalidTarget("receipt")
        }
        return try await database.writer { db in
            try Self.requireSchema(db)
            if let body = try String.fetchOne(
                db,
                sql: "SELECT body_json FROM task_remote_command_receipts WHERE operation_id = ?",
                arguments: [receipt.operationID]
            ) {
                let existing = try Self.decode(C02RemoteCommandReceipt.self, body)
                if existing == receipt { return existing }
                guard existing.state == .dispatched,
                      existing.taskID == receipt.taskID,
                      existing.targetRevision == receipt.targetRevision,
                      existing.rootEpoch == receipt.rootEpoch,
                      existing.hostID == receipt.hostID,
                      existing.commandSHA256 == receipt.commandSHA256,
                      receipt.state != .dispatched else {
                    throw C02ExecutionTargetError.storeCorrupted
                }
                try db.execute(sql: """
                    UPDATE task_remote_command_receipts
                    SET state = ?, exit_code = ?, updated_at = ?, detail_code = ?
                    WHERE operation_id = ? AND state = 'dispatched'
                    """, arguments: [
                        receipt.state.rawValue,
                        receipt.exitCode.map { Int64($0) },
                        Self.iso(receipt.updatedAt), receipt.detailCode,
                        receipt.operationID,
                    ])
                guard db.changesCount == 1 else {
                    throw C02ExecutionTargetError.storeCorrupted
                }
                return receipt
            }
            try db.execute(sql: """
                INSERT INTO task_remote_command_receipts (
                    operation_id, task_id, run_id, tool_call_id, target_revision,
                    root_epoch, host_id, command_sha256, state, exit_code,
                    started_at, updated_at, detail_code, body_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receipt.operationID, receipt.taskID.uuidString,
                    receipt.runID?.uuidString, receipt.toolCallID,
                    receipt.targetRevision, Int64(receipt.rootEpoch),
                    receipt.hostID.uuidString, receipt.commandSHA256,
                    receipt.state.rawValue, receipt.exitCode.map { Int64($0) },
                    Self.iso(receipt.startedAt), Self.iso(receipt.updatedAt),
                    receipt.detailCode, try Self.encode(receipt),
                ])
            return receipt
        }
    }

    // MARK: SQL helpers

    private static func requireSchema(_ db: Database) throws {
        guard try db.tableExists("task_execution_targets"),
              try db.tableExists("task_execution_target_migrations"),
              try db.tableExists("task_run_execution_targets"),
              try db.tableExists("task_remote_command_receipts") else {
            throw C02ExecutionTargetError.schemaUnavailable
        }
    }

    private static func allowedTransition(
        from: C02TargetMigration.Phase,
        to: C02TargetMigration.Phase
    ) -> Bool {
        switch (from, to) {
        case (.checking, .draining), (.checking, .failed), (.checking, .cancelled):
            return true
        case (.draining, .verified), (.draining, .failed), (.draining, .cancelled):
            return true
        case (.verified, .failed), (.verified, .cancelled):
            return true
        default:
            return false
        }
    }

    fileprivate static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    fileprivate static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: Data(value.utf8))
        } catch {
            throw C02ExecutionTargetError.storeCorrupted
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Domain

public struct C02ResolvedExecutionTarget: Sendable, Equatable {
    public var target: C02ExecutionTarget
    public var pin: C02RunTargetPin
    public var targetRevision: Int64 { target.revision }
    public var rootEpoch: UInt64 { pin.rootEpoch }

    public init(target: C02ExecutionTarget, pin: C02RunTargetPin) {
        self.target = target
        self.pin = pin
    }
}

public actor C02ExecutionTargetDomain {
    private let epoch: UInt64
    private let store: any C02ExecutionTargetStoring
    private let ownership: any C02ExecutionTargetOwnershipProviding
    private let policy: any C02ExecutionTargetPolicyProviding
    private let environments: any C02ExecutionTargetEnvironmentProviding
    private let remoteProbe: any C02RemoteTargetProbing
    private let remoteTrust: any C02RemoteHostTrusting
    private let drain: any C02ExecutionTargetDraining
    private let now: @Sendable () -> Date
    /// Live native-generation readback. nil keeps the authored tests'
    /// explicit epoch; production supplies G02NativeRootEpoch.readback().
    private let liveEpoch: (@Sendable () -> UInt64?)?
    private var pendingHostKeyChallenges: [UUID: C02RemoteHostKeyChallenge] = [:]

    public init(
        epoch: UInt64,
        store: any C02ExecutionTargetStoring,
        ownership: any C02ExecutionTargetOwnershipProviding,
        policy: any C02ExecutionTargetPolicyProviding,
        environments: any C02ExecutionTargetEnvironmentProviding,
        remoteProbe: any C02RemoteTargetProbing,
        remoteTrust: any C02RemoteHostTrusting,
        drain: any C02ExecutionTargetDraining,
        liveEpoch: (@Sendable () -> UInt64?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.epoch = epoch
        self.store = store
        self.ownership = ownership
        self.policy = policy
        self.environments = environments
        self.remoteProbe = remoteProbe
        self.remoteTrust = remoteTrust
        self.drain = drain
        self.liveEpoch = liveEpoch
        self.now = now
    }

    // MARK: Options

    public func options(taskID: UUID) async throws -> C02ExecutionTargetOptions {
        guard epoch > 0 else { throw C02ExecutionTargetError.rootEpochUnavailable }
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary else { throw C02ExecutionTargetError.temporaryTaskRefused }
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard ownership.rootEpoch == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        let current = try await store.target(taskID: taskID)
        let migration = try await store.activeMigration(taskID: taskID)
        let localFacts = try await environments.localEnvironments(
            taskID: taskID, ownership: ownership)
        let remote = try await environments.remoteHosts(taskID: taskID)
        let localOptions = localFacts.map {
            C02LocalEnvironmentOption(
                id: $0.id, name: $0.name, kind: $0.kind,
                state: $0.state, requiresRebuild: $0.requiresRebuild)
        }
        let usable = localFacts.contains { $0.isQualified(ownership: ownership) }
        return C02ExecutionTargetOptions(
            taskID: taskID,
            current: current,
            activeMigration: migration,
            localEnvironments: localOptions,
            remoteHosts: remote.map {
                C02RemoteHostOption(
                    id: $0.id, displayName: $0.displayName,
                    operatingSystemHint: nil,
                    isExecutionEnvironment: $0.isExecutionEnvironment,
                    sshConfigured: $0.sshConfigured)
            },
            remoteExecutionAllowed: policy.remoteExecutionAllowed,
            hasUsableLocalEnvironment: usable,
            canCreateInitialTarget: current == nil && migration == nil && (usable || policy.remoteExecutionAllowed)
        )
    }

    // MARK: Initial resolution / run pin

    /// Resolves the exact target for this task and pins `runID`. Existing
    /// pins always beat later UI/global defaults.
    public func resolveForRun(
        taskID: UUID,
        runID: UUID,
        selection: C02ExecutionTargetSelection? = nil
    ) async throws -> C02ResolvedExecutionTarget {
        try await requireLiveEpoch()
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary else { throw C02ExecutionTargetError.temporaryTaskRefused }
        guard policy.isOrdinary else { throw C02ExecutionTargetError.temporaryTaskRefused }
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard ownership.rootEpoch == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        if let migration = try await store.activeMigration(taskID: taskID),
           !migration.phase.isCommitted {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        guard let target = try await store.target(taskID: taskID) else {
            guard let selection, selection.explicitUserChoice else {
                throw C02ExecutionTargetError.targetSelectionRequired
            }
            let created = try await createTarget(
                taskID: taskID,
                selection: selection,
                ownership: ownership,
                policy: policy,
                provenance: .explicitUserSelection
            )
            return try await pin(target: created, runID: runID, ownership: ownership)
        }
        try await validateExistingTarget(target, ownership: ownership)
        if let selection, !selection.matches(target) {
            throw C02ExecutionTargetError.targetAlreadyPinned
        }
        return try await pin(target: target, runID: runID, ownership: ownership)
    }

    /// Host-only adoption of an environment already owned by this task/project.
    /// This never creates a container or probes a remote host. A stored target
    /// always wins; ordinary chat can continue when no unambiguous local exists.
    public func resolveUsingExistingEnvironment(
        taskID: UUID, runID: UUID, preferredEnvironmentID: String? = nil
    ) async throws -> C02ResolvedExecutionTarget? {
        try await requireLiveEpoch()
        if try await store.target(taskID: taskID) != nil {
            return try await resolveForRun(taskID: taskID, runID: runID)
        }
        let taskPolicy = try await policy.policy(taskID: taskID)
        guard !taskPolicy.isTemporary, taskPolicy.isOrdinary else {
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        guard let owner = try await ownership.ownership(taskID: taskID), owner.rootEpoch == epoch else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        if let migration = try await store.activeMigration(taskID: taskID), !migration.phase.isCommitted {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        let available = try await environments.localEnvironments(taskID: taskID, ownership: owner)
            .filter { $0.isQualified(ownership: owner) }
        let matches: [C02LocalEnvironmentFacts]
        if let preferredEnvironmentID {
            matches = available.filter { $0.id == preferredEnvironmentID }
        } else {
            let sessions = available.filter { $0.kind == "session" }
            matches = sessions.isEmpty ? available.filter { $0.kind == "project" } : sessions
        }
        guard matches.count == 1, let environment = matches.first else { return nil }
        let target = try await createTarget(taskID: taskID,
            selection: C02ExecutionTargetSelection(kind: .localLinux,
                environmentID: environment.id, remoteHostID: nil, explicitUserChoice: false),
            ownership: owner, policy: taskPolicy, provenance: .adoptedExistingEnvironment)
        // insertInitial is first-writer-wins, including a concurrent explicit
        // selection. Validate and pin that actual winner, never our draft.
        try await validateExistingTarget(target, ownership: owner)
        return try await pin(target: target, runID: runID, ownership: owner)
    }

    public func hasUsableLocalEnvironment(taskID: UUID) async throws -> Bool {
        try await requireLiveEpoch()
        guard let owner = try await ownership.ownership(taskID: taskID), owner.rootEpoch == epoch else { return false }
        return try await environments.localEnvironments(taskID: taskID, ownership: owner)
            .contains { $0.isQualified(ownership: owner) }
    }

    /// First-run explicit target creation without a run. The UI calls this
    /// before the first send; execution still resolves through `resolveForRun`.
    public func initialize(
        taskID: UUID,
        selection: C02ExecutionTargetSelection
    ) async throws -> C02ExecutionTarget {
        try await requireLiveEpoch()
        guard selection.explicitUserChoice else {
            throw C02ExecutionTargetError.targetSelectionRequired
        }
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary, policy.isOrdinary else {
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard ownership.rootEpoch == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        if try await store.activeMigration(taskID: taskID) != nil {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        if let existing = try await store.target(taskID: taskID) {
            try await validateExistingTarget(existing, ownership: ownership)
            guard selection.matches(existing) else {
                throw C02ExecutionTargetError.targetAlreadyPinned
            }
            return existing
        }
        return try await createTarget(
            taskID: taskID,
            selection: selection,
            ownership: ownership,
            policy: policy,
            provenance: .explicitUserSelection
        )
    }

    public func pin(
        taskID: UUID,
        runID: UUID
    ) async throws -> C02ResolvedExecutionTarget {
        try await requireLiveEpoch()
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard ownership.rootEpoch == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        guard let target = try await store.target(taskID: taskID) else {
            throw C02ExecutionTargetError.targetNotFound
        }
        try await validateExistingTarget(target, ownership: ownership)
        return try await pin(target: target, runID: runID, ownership: ownership)
    }

    public func validateRunCompletion(
        runID: UUID,
        targetRevision: Int64,
        rootEpoch: UInt64
    ) async throws -> Bool {
        guard let pin = try await store.runPin(runID: runID) else { return false }
        return pin.targetRevision == targetRevision && pin.rootEpoch == rootEpoch
    }

    // MARK: Migration

    public func previewMigration(
        taskID: UUID,
        expectedRevision: Int64,
        destination selection: C02ExecutionTargetSelection
    ) async throws -> C02MigrationPreview {
        try await requireLiveEpoch()
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard let source = try await store.target(taskID: taskID) else {
            throw C02ExecutionTargetError.targetNotFound
        }
        guard source.revision == expectedRevision else {
            throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: source.revision)
        }
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary, policy.isOrdinary else {
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        if try await store.activeMigration(taskID: taskID) != nil {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        var challenge: C02RemoteHostKeyChallenge?
        let destinationTarget: C02ExecutionTarget
        do {
            destinationTarget = try await makeTarget(
                taskID: taskID,
                selection: selection,
                ownership: ownership,
                policy: policy,
                provenance: .migrated,
                revision: source.revision + 1
            )
        } catch let error as C02ExecutionTargetError {
            if case .hostKeyApprovalRequired(let pending) = error {
                challenge = pending
                storeChallenge(pending)
                throw error
            }
            throw error
        }
        guard !source.sameStableIdentity(as: destinationTarget) else {
            throw C02ExecutionTargetError.invalidTarget("sameDestination")
        }
        let affected = try await drain.preview(
            taskID: taskID,
            environmentID: source.environmentID,
            targetRevision: source.revision
        )
        let at = now()
        return C02MigrationPreview(
            taskID: taskID,
            source: source,
            destination: destinationTarget,
            affectedWork: affected,
            requiresDrain: affected.hasLiveWork,
            remoteHostKeyChallenge: challenge,
            canCommit: challenge == nil,
            generatedAt: at,
            expiresAt: at.addingTimeInterval(60)
        )
    }

    /// One explicit CAS move. New target effects before commit are limited to
    /// read-only destination validation; the old target is fenced and
    /// drained, and a timeout writes no target change.
    public func beginMigration(
        taskID: UUID,
        expectedRevision: Int64,
        destination selection: C02ExecutionTargetSelection,
        drainTimeout: Duration = .seconds(30)
    ) async throws -> C02MigrationCommit {
        try await requireLiveEpoch()
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        guard let source = try await store.target(taskID: taskID) else {
            throw C02ExecutionTargetError.targetNotFound
        }
        guard source.revision == expectedRevision else {
            throw C02ExecutionTargetError.staleRevision(expected: expectedRevision, actual: source.revision)
        }
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary, policy.isOrdinary else {
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        if try await store.activeMigration(taskID: taskID) != nil {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        let destinationTarget = try await makeTarget(
            taskID: taskID,
            selection: selection,
            ownership: ownership,
            policy: policy,
            provenance: .migrated,
            revision: source.revision + 1
        )
        guard !source.sameStableIdentity(as: destinationTarget) else {
            throw C02ExecutionTargetError.invalidTarget("sameDestination")
        }
        let affected = try await drain.preview(
            taskID: taskID,
            environmentID: source.environmentID,
            targetRevision: source.revision
        )
        let at = now()
        var migration = C02TargetMigration(
            taskID: taskID,
            source: source,
            destination: destinationTarget,
            affectedWork: affected,
            createdAt: at,
            updatedAt: at
        )
        try await store.beginMigration(migration)
        let fence: C02OwnedWorkFence
        do {
            fence = try await drain.fence(
                taskID: taskID,
                environmentID: source.environmentID,
                targetRevision: source.revision,
                rootEpoch: ownership.rootEpoch
            )
        } catch {
            migration.phase = .failed
            migration.failureCode = "fenceUnavailable"
            _ = try? await store.updateMigration(migration, expectedRevision: migration.revision)
            throw C02ExecutionTargetError.drainTimedOut(
                C02DrainReceipt(complete: false, timedOut: false, detailCode: "fenceUnavailable"))
        }
        var releaseFence = true
        defer { if releaseFence { Task { await drain.release(fence) } } }

        migration.affectedWork = affected
        migration.phase = .draining
        migration = try await store.updateMigration(migration, expectedRevision: migration.revision)
        let receipt: C02DrainReceipt
        do {
            receipt = try await drain.drain(fence, timeout: drainTimeout)
        } catch {
            migration.phase = .failed
            migration.failureCode = "drainFailed"
            migration.updatedAt = now()
            _ = try? await store.updateMigration(migration, expectedRevision: migration.revision)
            throw C02ExecutionTargetError.drainTimedOut(
                C02DrainReceipt(complete: false, timedOut: false, detailCode: "drainFailed"))
        }
        guard receipt.complete, !receipt.timedOut else {
            migration.phase = .failed
            migration.failureCode = receipt.timedOut ? "drainTimedOut" : "drainIncomplete"
            migration.drainReceipt = receipt
            migration.updatedAt = now()
            _ = try? await store.updateMigration(migration, expectedRevision: migration.revision)
            throw C02ExecutionTargetError.drainTimedOut(receipt)
        }
        if let latest = try await store.activeMigration(taskID: taskID),
           latest.id == migration.id {
            migration = latest
        }
        if migration.cancellationRequested {
            migration.phase = .cancelled
            migration.drainReceipt = receipt
            _ = try? await store.updateMigration(migration, expectedRevision: migration.revision)
            throw C02ExecutionTargetError.migrationCancelled
        }
        await drain.closeRemoteSessions(
            taskID: taskID,
            targetRevision: source.revision,
            rootEpoch: ownership.rootEpoch
        )
        migration.drainReceipt = receipt
        migration.phase = .verified
        migration = try await store.updateMigration(migration, expectedRevision: migration.revision)
        try await requireLiveEpoch()
        let commit: C02MigrationCommit
        do {
            commit = try await store.commitMigration(migration)
        } catch {
            migration.phase = .failed
            migration.failureCode = "commitFailed"
            migration.updatedAt = now()
            _ = try? await store.updateMigration(migration, expectedRevision: migration.revision)
            throw error
        }
        releaseFence = false
        await drain.release(fence)
        return commit
    }

    public func completeMigration(
        _ migration: C02TargetMigration
    ) async throws -> C02TargetMigration {
        try await store.finishMigration(migration, expectedRevision: migration.revision)
    }

    public func migrationStatus(taskID: UUID) async throws -> C02TargetMigration? {
        if let active = try await store.activeMigration(taskID: taskID) {
            return active
        }
        return try await store.latestMigration(taskID: taskID)
    }

    public func cancelMigration(
        taskID: UUID,
        expectedRevision: Int64
    ) async throws -> C02TargetMigration? {
        guard let migration = try await store.requestMigrationCancellation(
            taskID: taskID, expectedRevision: expectedRevision) else {
            throw C02ExecutionTargetError.migrationNotFound
        }
        // A committed move cannot be rolled back to the old target silently.
        if migration.phase.isCommitted { return migration }
        var next = migration
        next.phase = .cancelled
        next.updatedAt = now()
        return try await store.updateMigration(next, expectedRevision: migration.revision)
    }

    // MARK: Host-key approval

    /// Records a challenge observed during an actual execution attempt so
    /// the trusted UI can approve it and retry. It never trusts the key.
    public func recordRemoteHostKeyChallenge(_ challenge: C02RemoteHostKeyChallenge) {
        guard challenge.taskID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            return
        }
        storeChallenge(challenge)
    }

    public func approveHostKey(
        taskID: UUID,
        challengeID: UUID,
        accept: Bool,
        replaceChanged: Bool,
        expectedFingerprint: String?
    ) async throws -> C02HostKeyApproval {
        purgeExpiredChallenges()
        guard let challenge = pendingHostKeyChallenges[challengeID],
              challenge.taskID == taskID else {
            throw C02ExecutionTargetError.invalidTarget("hostKeyChallengeNotFound")
        }
        guard now() < challenge.expiresAt else {
            pendingHostKeyChallenges.removeValue(forKey: challengeID)
            throw C02ExecutionTargetError.hostKeyApprovalRequired(challenge)
        }
        guard accept else {
            pendingHostKeyChallenges.removeValue(forKey: challengeID)
            return C02HostKeyApproval(
                trusted: false, changed: challenge.kind == .changed,
                challengeID: challengeID, fingerprintSHA256: nil)
        }
        if challenge.kind == .changed {
            guard replaceChanged else {
                throw C02ExecutionTargetError.hostKeyApprovalRequired(challenge)
            }
            if let expectedFingerprint,
               SSHHostKeyFingerprint.normalize(expectedFingerprint)
                != SSHHostKeyFingerprint.normalize(challenge.expectedFingerprintSHA256 ?? "") {
                throw C02ExecutionTargetError.invalidTarget("expectedFingerprintMismatch")
            }
        }
        try await remoteTrust.trust(
            hostID: challenge.hostID,
            address: challenge.address,
            port: challenge.port,
            keyType: challenge.keyType,
            fingerprintSHA256: challenge.fingerprintSHA256
        )
        pendingHostKeyChallenges.removeValue(forKey: challengeID)
        return C02HostKeyApproval(
            trusted: true, changed: challenge.kind == .changed,
            challengeID: challengeID, fingerprintSHA256: challenge.fingerprintSHA256)
    }

    // MARK: Execution authorization

    public func authorizeSSHExecution(
        taskID: UUID,
        runID: UUID,
        sessionID: String? = nil,
        sessionOwnerToken: String? = nil
    ) async throws -> C02SSHExecutionAuthorization {
        try await requireLiveEpoch()
        let policy = try await policy.policy(taskID: taskID)
        guard !policy.isTemporary, policy.isOrdinary else {
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        guard policy.remoteExecutionAllowed else {
            throw C02ExecutionTargetError.remoteExecutionNotAllowed
        }
        guard let ownership = try await ownership.ownership(taskID: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        if let migration = try await store.activeMigration(taskID: taskID),
           !migration.phase.isCommitted {
            throw C02ExecutionTargetError.migrationAlreadyActive
        }
        guard let target = try await store.target(taskID: taskID), target.kind == .ssh,
              let remote = target.remote else {
            throw C02ExecutionTargetError.remoteHostMissing
        }
        try await validateExistingTarget(target, ownership: ownership)
        let host = try await environments.validateRemoteHost(
            hostID: remote.hostID, taskID: taskID)
        guard host.isExecutionEnvironment else {
            throw C02ExecutionTargetError.remoteNotExecutionEnvironment
        }
        guard host.sshConfigured else {
            throw C02ExecutionTargetError.remoteHostMissing
        }
        let pin = try await store.pinRun(C02RunTargetPin(
            runID: runID,
            taskID: taskID,
            targetRevision: target.revision,
            environmentID: target.environmentID,
            shellRootHash: target.shellRootHash,
            engineOwnerHash: target.engineOwnerHash,
            rootEpoch: ownership.rootEpoch,
            pinnedAt: now()
        ))
        return C02SSHExecutionAuthorization(
            taskID: taskID,
            runID: runID,
            target: target,
            targetRevision: target.revision,
            rootEpoch: pin.rootEpoch,
            ownerToken: "task-\(taskID.uuidString.lowercased())-rev-\(target.revision)-epoch-\(ownership.rootEpoch)",
            sessionID: sessionID,
            sessionOwnerToken: sessionOwnerToken,
            approvedHostKeyFingerprint: remote.hostKeyFingerprintSHA256,
            permissionGrantID: UUID(),
            issuedAt: now(),
            expiresAt: now().addingTimeInterval(60)
        )
    }

    public func executionTarget(taskID: UUID) async throws -> C02ExecutionTarget? {
        try await store.target(taskID: taskID)
    }

    public func runTargetPin(runID: UUID) async throws -> C02RunTargetPin? {
        try await store.runPin(runID: runID)
    }

    // MARK: Private

    private func requireLiveEpoch() async throws {
        guard epoch > 0 else { throw C02ExecutionTargetError.rootEpochUnavailable }
        if let liveEpoch, liveEpoch() != epoch {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
    }

    private func pin(
        target: C02ExecutionTarget,
        runID: UUID,
        ownership: C02TargetOwnership
    ) async throws -> C02ResolvedExecutionTarget {
        let pin = try await store.pinRun(C02RunTargetPin(
            runID: runID,
            taskID: target.taskID,
            targetRevision: target.revision,
            environmentID: target.environmentID,
            shellRootHash: target.shellRootHash,
            engineOwnerHash: target.engineOwnerHash,
            rootEpoch: ownership.rootEpoch,
            pinnedAt: now()
        ))
        return C02ResolvedExecutionTarget(target: target, pin: pin)
    }

    private func validateExistingTarget(
        _ target: C02ExecutionTarget,
        ownership: C02TargetOwnership
    ) async throws {
        try target.validate()
        guard target.taskID == ownership.taskID,
              target.workspaceID == ownership.workspaceID,
              target.projectID == ownership.projectID,
              target.shellRootHash == ownership.shellRootHash,
              target.engineOwnerHash == ownership.engineOwnerHash else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        switch target.kind {
        case .localLinux:
            let facts = try await environments.validateLocal(
                environmentID: target.environmentID,
                taskID: target.taskID,
                ownership: ownership)
            guard facts.isQualified(ownership: ownership) else {
                throw C02ExecutionTargetError.environmentUnavailable(target.environmentID)
            }
        case .ssh:
            let host = try await environments.validateRemoteHost(
                hostID: target.remoteHostID ?? UUID(), taskID: target.taskID)
            guard host.isExecutionEnvironment else {
                throw C02ExecutionTargetError.remoteNotExecutionEnvironment
            }
            guard host.sshConfigured else {
                throw C02ExecutionTargetError.remoteHostMissing
            }
        }
    }

    private func createTarget(
        taskID: UUID,
        selection: C02ExecutionTargetSelection,
        ownership: C02TargetOwnership,
        policy: C02TargetTaskPolicy,
        provenance: C02ExecutionTargetProvenance
    ) async throws -> C02ExecutionTarget {
        let target = try await makeTarget(
            taskID: taskID,
            selection: selection,
            ownership: ownership,
            policy: policy,
            provenance: provenance,
            revision: 1
        )
        return try await store.insertInitial(target)
    }

    private func makeTarget(
        taskID: UUID,
        selection: C02ExecutionTargetSelection,
        ownership: C02TargetOwnership,
        policy: C02TargetTaskPolicy,
        provenance: C02ExecutionTargetProvenance,
        revision: Int64
    ) async throws -> C02ExecutionTarget {
        let at = now()
        switch selection.kind {
        case .localLinux:
            guard let environmentID = selection.environmentID else {
                throw C02ExecutionTargetError.environmentMissing("none")
            }
            let facts = try await environments.validateLocal(
                environmentID: environmentID,
                taskID: taskID,
                ownership: ownership
            )
            guard facts.isQualified(ownership: ownership) else {
                throw C02ExecutionTargetError.environmentUnavailable(environmentID)
            }
            let target = C02ExecutionTarget(
                taskID: taskID,
                revision: revision,
                kind: .localLinux,
                environmentID: facts.id,
                projectID: ownership.projectID,
                workspaceID: ownership.workspaceID,
                shellRootHash: ownership.shellRootHash,
                engineOwnerHash: ownership.engineOwnerHash,
                rootEpoch: ownership.rootEpoch,
                remote: nil,
                provenance: provenance,
                createdAt: at,
                updatedAt: at
            )
            try target.validate()
            return target
        case .ssh:
            guard policy.remoteExecutionAllowed else {
                throw C02ExecutionTargetError.remoteExecutionNotAllowed
            }
            guard let hostID = selection.remoteHostID else {
                throw C02ExecutionTargetError.remoteHostMissing
            }
            let host = try await environments.validateRemoteHost(
                hostID: hostID, taskID: taskID)
            guard host.isExecutionEnvironment else {
                throw C02ExecutionTargetError.remoteNotExecutionEnvironment
            }
            guard host.sshConfigured else {
                throw C02ExecutionTargetError.remoteHostMissing
            }
            let facts: C02RemoteEnvironmentFacts
            do {
                facts = try await remoteProbe.probeRemote(
                    hostID: hostID,
                    taskID: taskID,
                    expectedFingerprint: host.hostKeyPinnedFingerprint
                )
            } catch let error as C02ExecutionTargetError {
                if case .hostKeyApprovalRequired(let challenge) = error {
                    storeChallenge(challenge)
                }
                throw error
            }
            let remoteTarget = C02ExecutionTarget(
                taskID: taskID,
                revision: revision,
                kind: .ssh,
                environmentID: C02RemoteEnvironmentID.make(
                    hostID: hostID, remoteRootPath: facts.remoteRootPath),
                projectID: ownership.projectID,
                workspaceID: ownership.workspaceID,
                shellRootHash: ownership.shellRootHash,
                engineOwnerHash: ownership.engineOwnerHash,
                rootEpoch: ownership.rootEpoch,
                remote: facts,
                provenance: provenance,
                createdAt: at,
                updatedAt: at
            )
            try remoteTarget.validate()
            return remoteTarget
        }
    }

    private func storeChallenge(_ challenge: C02RemoteHostKeyChallenge) {
        purgeExpiredChallenges()
        pendingHostKeyChallenges[challenge.id] = challenge
    }

    private func purgeExpiredChallenges() {
        let current = now()
        pendingHostKeyChallenges = pendingHostKeyChallenges.filter {
            $0.value.expiresAt > current
        }
    }
}
