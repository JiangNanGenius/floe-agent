// FloeExecution — legacy recovery-domain maintenance authority.
//
// This is the ONE bounded ownership/exclusion primitive for the trusted legacy
// recovery domain (the old `<Application Support>/Floe/Runtime/v2` tree). It is
// deliberately not a generic "lock any path" platform and it never chooses a
// path from model/tool input: the native owner resolves the legacy root, and a
// maintenance target is only a relative path inside `recovery/`.
//
// Semantics proven here:
//  * every cooperating runtime/store path takes a SHARED use claim before it
//    opens, captures, restores, discards or deletes bytes of the domain;
//  * maintenance takes the ONE EXCLUSIVE claim and holds it across all staging,
//    verification, commit and recovery IO;
//  * the maintenance intent is made durable BEFORE the first await, so a
//    pending/new start or a second store instance can never slip into the gap;
//  * an interrupted/corrupt intent never expires by TTL and keeps the domain
//    closed until the owning service proves convergence through a recovery
//    handler;
//  * unknown or untracked owners fail closed: evidence must be complete and
//    quiescent, a stale lease sidecar or an unexplained `runtime/vm` directory
//    is an owner trace, never "idle";
//  * flock(2) is an ADDITIONAL cross-process exclusion for cooperating
//    instances. It is not lifecycle proof by itself and never substitutes for
//    the evidence checks or the durable intent.
//
// The current resident ARM64 machine lives in a different, composed runtime path
// (`artifactRoot/LinuxGuest/ResidentARM64/...`). This authority never stops it;
// a coordinator registered for the legacy domain does not match the resident or
// production `arm64-v1` store, so operations there are untouched.

import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

public enum RuntimeV2MaintenanceError: Error, LocalizedError, Equatable, Sendable {
    case invalidDomain(String)
    case invalidRequest(String)
    case invalidTarget(String)
    case maintenanceActive(String)
    case ownerEvidenceIncomplete([String])
    case recoveryPending(String)
    case crossProcessOwner(String)
    case targetMissing(String)
    case targetIdentityMismatch(String)
    case claimInvalidated(String)
    case claimNotCommitEligible(String)
    case claimAlreadyCommitted
    case intentPersistenceFailed(String)
    case recoveryHandlerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDomain(let reason):
            return "the trusted legacy recovery domain is invalid: \(reason)"
        case .invalidRequest(let reason):
            return "the maintenance request is invalid: \(reason)"
        case .invalidTarget(let reason):
            return "the maintenance target is outside the one allowed recovery domain: \(reason)"
        case .maintenanceActive(let reason):
            return "legacy recovery storage is already in use: \(reason); nothing was changed"
        case .ownerEvidenceIncomplete(let blockers):
            return "legacy recovery ownership could not be proven: \(blockers.joined(separator: ",")); nothing was changed"
        case .recoveryPending(let reason):
            return "legacy recovery maintenance is awaiting convergence: \(reason); no new access is allowed"
        case .crossProcessOwner(let reason):
            return "another cooperating process holds the legacy recovery domain: \(reason); nothing was changed"
        case .targetMissing(let reason):
            return "the maintenance target is missing or unreadable: \(reason); nothing was changed"
        case .targetIdentityMismatch(let reason):
            return "the maintenance target identity changed: \(reason); the operation must re-preflight"
        case .claimInvalidated(let reason):
            return "the maintenance claim is no longer valid: \(reason); no commit may proceed"
        case .claimNotCommitEligible(let reason):
            return "the maintenance claim cannot commit in its current state: \(reason)"
        case .claimAlreadyCommitted:
            return "the maintenance claim has already committed"
        case .intentPersistenceFailed(let reason):
            return "the durable maintenance intent could not be written: \(reason); nothing was opened"
        case .recoveryHandlerUnavailable(let reason):
            return "interrupted legacy recovery maintenance cannot converge without its owning recovery handler: \(reason)"
        }
    }
}

// MARK: - Domain and identities

/// One trusted legacy recovery domain, resolved by the native owner. The root is
/// fixed for the process lifetime; `recovery/` is the only area a maintenance
/// target may name.
public struct RuntimeV2MaintenanceDomain: Sendable, Hashable {
    public let root: URL
    public let recoveryDirectory: URL
    /// Path-derived lookup hint. Cross-launch recovery uses durable physical
    /// identity; an App container rename does not create a new domain.
    public let domainKey: String

    public init(trustedLegacyRoot: URL, fileManager: FileManager = .default) throws {
        let resolved: URL
        if Self.trustedLegacyRoot().map({ RuntimeV2RecoveryAdmission.key($0) })
            == RuntimeV2RecoveryAdmission.key(trustedLegacyRoot) {
            resolved = URL(fileURLWithPath: RuntimeV2RecoveryAdmission.key(trustedLegacyRoot), isDirectory: true)
        } else {
            // Other owners (resident16) retain their original path identity.
            resolved = trustedLegacyRoot.standardizedFileURL.resolvingSymlinksInPath()
        }
        var isDirectory: ObjCBool = false
        guard resolved.path != "/",
              fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RuntimeV2MaintenanceError.invalidDomain("the trusted legacy root does not exist")
        }
        self.root = resolved
        self.recoveryDirectory = resolved.appendingPathComponent("recovery", isDirectory: true)
        self.domainKey = FloeDigest.sha256Hex(Data(resolved.path.utf8))
    }

    /// The ONE legacy root this build may resolve without any model/tool input.
    /// It is the old Runtime v2 tree, never the production `arm64-v1` root and
    /// never the resident ARM64 directory.
    public static func trustedLegacyRoot(fileManager: FileManager = .default) -> URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return support
            .appendingPathComponent("Floe", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    /// A path is historical metadata, never an alternate IO root. A missing
    /// old container may be accepted only with its durable device/inode pair.
    /// An existing different path, a copied root or an unreadable path refuses.
    func matchesRecordedRoot(_ recorded: String, device: UInt64?, inode: UInt64?) -> Bool {
        guard let device, let inode, device != 0, inode != 0,
              recorded.hasPrefix("/"), recorded.utf8.count <= 4_096,
              !recorded.utf8.contains(0),
              !recorded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let canonical = root.path.withCString({ realpath($0, nil) }) else { return false }
        defer { free(canonical) }
        if let old = recorded.withCString({ realpath($0, nil) }) {
            defer { free(old) }
            guard strcmp(old, canonical) == 0 else { return false }
        } else if errno != ENOENT { return false }
        let fd = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var opened = stat(); var named = stat()
        guard fstat(fd, &opened) == 0, lstat(canonical, &named) == 0,
              opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(opened.st_dev)) == device, UInt64(opened.st_ino) == inode,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              let after = root.path.withCString({ realpath($0, nil) }) else { return false }
        defer { free(after) }
        return strcmp(canonical, after) == 0
            && (try? RuntimeV2DiskIdentity.read(at: root)).map { $0.device == device && $0.inode == inode } == true
    }

    /// Only the App-owned sibling authority directory is searched. Old path
    /// hashes remain indexes; a unique durable physical identity chooses the
    /// SAME state/lock and history. No record is rewritten or copied.
    public func authorityStateDirectory() throws -> URL {
        try RuntimeV2MaintenanceCoordinator.authorityStateDirectory(for: self)
    }

    public var environmentTracesDirectory: URL {
        root.appendingPathComponent("environments", isDirectory: true)
    }

    public var runtimeWorkingDirectory: URL {
        root.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("vm", isDirectory: true)
    }

    public var lockStateKey: String { domainKey }

    /// A maintenance target is a single relative path inside `recovery/`.
    /// Absolute paths, traversal, empty components and every prefix outside the
    /// recovery tree are refused before any disk access.
    @discardableResult
    public func validateTargetRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), relativePath.utf8.count <= 1_024 else {
            throw RuntimeV2MaintenanceError.invalidTarget("the path is empty, absolute or too long")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }),
              String(components[0]) == "recovery" else {
            throw RuntimeV2MaintenanceError.invalidTarget("only a relative path under recovery/ is allowed")
        }
        return relativePath
    }

    /// True when the legacy root carries an environment directory or lease
    /// trace for this id. This is a conservative attribution helper, not a live
    /// owner proof.
    public func ownsEnvironmentTrace(_ environmentID: String, fileManager: FileManager = .default) -> Bool {
        guard (try? RuntimeV2Identifier.validate(environmentID, kind: .environment)) != nil else { return false }
        let directory = environmentTracesDirectory.appendingPathComponent(environmentID, isDirectory: true)
        let lease = directory.appendingPathComponent("lease.json")
        return fileManager.fileExists(atPath: directory.path)
            || fileManager.fileExists(atPath: lease.path)
    }
}

/// File-instance identity used for the exact target and the domain root. A
/// path swapped by temp+rename is a DIFFERENT inode, which is what lets a claim
/// detect identity replacement across an await/commit.
public struct RuntimeV2DiskIdentity: Codable, Sendable, Equatable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var linkCount: UInt64
    public var mode: UInt32
    public var modificationSeconds: Int64
    public var modificationNanoseconds: Int64
    public var changeSeconds: Int64
    public var changeNanoseconds: Int64

    public init(
        device: UInt64, inode: UInt64, size: Int64, linkCount: UInt64, mode: UInt32,
        modificationSeconds: Int64, modificationNanoseconds: Int64,
        changeSeconds: Int64, changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.linkCount = linkCount
        self.mode = mode
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    public var isRegularFile: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFREG) }

    public static func read(at url: URL) throws -> RuntimeV2DiskIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw RuntimeV2MaintenanceError.targetMissing("stat failed")
        }
#if canImport(Darwin)
        let modification = info.st_mtimespec
        let change = info.st_ctimespec
#elseif canImport(Glibc)
        let modification = info.st_mtim
        let change = info.st_ctim
#endif
        return RuntimeV2DiskIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            linkCount: UInt64(info.st_nlink),
            mode: UInt32(info.st_mode),
            modificationSeconds: Int64(modification.tv_sec),
            modificationNanoseconds: Int64(modification.tv_nsec),
            changeSeconds: Int64(change.tv_sec),
            changeNanoseconds: Int64(change.tv_nsec)
        )
    }
}

/// Stable dev/inode identity of the authority lock file. Replacing the lock
/// entry (a temp+rename by a non-cooperator or an operator repair) invalidates
/// every claim that was opened on the old description.
public struct RuntimeV2MaintenanceLockIdentity: Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
}

// MARK: - Evidence

/// A complete snapshot of every owner class relevant to the fixed domain.
/// `isComplete == false`, a non-empty blocker list, or any quiescence blocker
/// denies exclusive acquisition. There is no "unknown means empty".
public struct RuntimeV2MaintenanceOwnerEvidence: Sendable, Equatable {
    public struct Registry: Sendable, Equatable {
        public var usesResidentMachine: Bool
        public var startingEnvironments: [String]
        public var activeSessions: [String]
        public var quarantinedEnvironments: [String]
        public var teardownsInFlight: [String]
        public var pendingStops: [String]
        public var sharedStarts: [String]
        public var lifecycleTransactions: [String]
        public var lifecycleLocks: [String]
        public var unknownOwnerState: Bool
        public var isComplete: Bool

        public init(
            usesResidentMachine: Bool = false,
            startingEnvironments: [String] = [],
            activeSessions: [String] = [],
            quarantinedEnvironments: [String] = [],
            teardownsInFlight: [String] = [],
            pendingStops: [String] = [],
            sharedStarts: [String] = [],
            lifecycleTransactions: [String] = [],
            lifecycleLocks: [String] = [],
            unknownOwnerState: Bool = false,
            isComplete: Bool = true
        ) {
            self.usesResidentMachine = usesResidentMachine
            self.startingEnvironments = startingEnvironments
            self.activeSessions = activeSessions
            self.quarantinedEnvironments = quarantinedEnvironments
            self.teardownsInFlight = teardownsInFlight
            self.pendingStops = pendingStops
            self.sharedStarts = sharedStarts
            self.lifecycleTransactions = lifecycleTransactions
            self.lifecycleLocks = lifecycleLocks
            self.unknownOwnerState = unknownOwnerState
            self.isComplete = isComplete
        }
    }

    public struct Integrator: Sendable, Equatable {
        public var storeRootPath: String?
        public var heldLeaseEnvironments: [String]
        public var leaseRegistryEnvironments: [String]
        public var queuedAdmissions: Int
        public var preparationActive: Bool
        public var isComplete: Bool
        public var blockers: [String]

        public init(
            storeRootPath: String? = nil,
            heldLeaseEnvironments: [String] = [],
            leaseRegistryEnvironments: [String] = [],
            queuedAdmissions: Int = 0,
            preparationActive: Bool = false,
            isComplete: Bool = true,
            blockers: [String] = []
        ) {
            self.storeRootPath = storeRootPath
            self.heldLeaseEnvironments = heldLeaseEnvironments
            self.leaseRegistryEnvironments = leaseRegistryEnvironments
            self.queuedAdmissions = queuedAdmissions
            self.preparationActive = preparationActive
            self.isComplete = isComplete
            self.blockers = blockers
        }
    }

    public struct References: Sendable, Equatable {
        public var isComplete: Bool
        public var blockers: [String]
        public var activeEnvironmentIDs: [String]
        public var unknownEnvironmentIDs: [String]
        public var unattributedActiveCount: Int
        public var unattributedLiveUnknownCount: Int
        public var unattributedIdleUnknownCount: Int
        public var retainedCount: Int
        public var fingerprint: String

        public init(
            isComplete: Bool = false,
            blockers: [String] = [],
            activeEnvironmentIDs: [String] = [],
            unknownEnvironmentIDs: [String] = [],
            unattributedActiveCount: Int = 0,
            unattributedLiveUnknownCount: Int = 0,
            unattributedIdleUnknownCount: Int = 0,
            retainedCount: Int = 0,
            fingerprint: String = ""
        ) {
            self.isComplete = isComplete
            self.blockers = blockers
            self.activeEnvironmentIDs = activeEnvironmentIDs
            self.unknownEnvironmentIDs = unknownEnvironmentIDs
            self.unattributedActiveCount = unattributedActiveCount
            self.unattributedLiveUnknownCount = unattributedLiveUnknownCount
            self.unattributedIdleUnknownCount = unattributedIdleUnknownCount
            self.retainedCount = retainedCount
            self.fingerprint = fingerprint
        }
    }

    public struct Filesystem: Sendable, Equatable {
        public var leaseEnvironmentIDs: [String]
        public var runtimeWorkingDirectoryIDs: [String]
        public var unreadableEntries: Bool
        /// The legacy registry database exists but no integrator covering THIS
        /// root supplied its `leases` rows. Sidecar scans alone are then not a
        /// complete owner set.
        public var leaseRegistryUnmeasured: Bool
        /// Populated only by the bounded READONLY legacy registry projection.
        public var legacyRegistryFingerprint: String?
        public var isComplete: Bool

        public init(
            leaseEnvironmentIDs: [String] = [],
            runtimeWorkingDirectoryIDs: [String] = [],
            unreadableEntries: Bool = false,
            leaseRegistryUnmeasured: Bool = false,
            legacyRegistryFingerprint: String? = nil,
            isComplete: Bool = true
        ) {
            self.leaseEnvironmentIDs = leaseEnvironmentIDs
            self.runtimeWorkingDirectoryIDs = runtimeWorkingDirectoryIDs
            self.unreadableEntries = unreadableEntries
            self.leaseRegistryUnmeasured = leaseRegistryUnmeasured
            self.legacyRegistryFingerprint = legacyRegistryFingerprint
            self.isComplete = isComplete
        }
    }

    public var capturedAt: Date
    public var isComplete: Bool
    public var blockers: [String]
    public var registry: Registry
    public var integrator: Integrator
    public var references: References
    public var filesystem: Filesystem
    public var startupRecoveryActive: Bool

    public init(
        capturedAt: Date = Date(),
        isComplete: Bool = false,
        blockers: [String] = [],
        registry: Registry = Registry(),
        integrator: Integrator = Integrator(),
        references: References = References(),
        filesystem: Filesystem = Filesystem(),
        startupRecoveryActive: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.isComplete = isComplete
        self.blockers = blockers
        self.registry = registry
        self.integrator = integrator
        self.references = references
        self.filesystem = filesystem
        self.startupRecoveryActive = startupRecoveryActive
    }

    /// Every reason this snapshot cannot authorize exclusive maintenance.
    /// The list is deterministic and contains fixed codes plus internal
    /// environment identifiers only (never conversation text or paths).
    public func quiescenceBlockers(domain: RuntimeV2MaintenanceDomain) -> [String] {
        var reasons: [String] = []
        if !isComplete { reasons.append("owner_evidence_incomplete") }
        reasons.append(contentsOf: blockers)
        if startupRecoveryActive { reasons.append("startup_recovery_active") }

        let registry = self.registry
        if registry.usesResidentMachine {
            // The resident ARM64 machine runs on its own composed path and is
            // not an owner of the legacy recovery domain. It must never be
            // stopped or counted as activity for this domain.
        } else {
            if !registry.isComplete { reasons.append("registry_evidence_incomplete") }
            if registry.unknownOwnerState { reasons.append("registry_owner_state_unknown") }
            reasons.append(contentsOf: registry.startingEnvironments.map { "registry_starting:\($0)" })
            reasons.append(contentsOf: registry.activeSessions.map { "registry_session:\($0)" })
            reasons.append(contentsOf: registry.quarantinedEnvironments.map { "registry_quarantined:\($0)" })
            reasons.append(contentsOf: registry.teardownsInFlight.map { "registry_teardown:\($0)" })
            reasons.append(contentsOf: registry.pendingStops.map { "registry_pending_stop:\($0)" })
            reasons.append(contentsOf: registry.sharedStarts.map { "registry_shared_start:\($0)" })
            reasons.append(contentsOf: registry.lifecycleTransactions.map { "registry_lifecycle_transaction:\($0)" })
            reasons.append(contentsOf: registry.lifecycleLocks.map { "registry_lifecycle_lock:\($0)" })
        }

        let integrator = self.integrator
        let integratorRoot = integrator.storeRootPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        if integratorRoot == nil {
            reasons.append("integrator_scope_unknown")
        } else if integratorRoot == domain.root.path {
            if !integrator.isComplete { reasons.append("integrator_evidence_incomplete") }
            reasons.append(contentsOf: integrator.blockers)
            reasons.append(contentsOf: integrator.heldLeaseEnvironments.map { "integrator_held_lease:\($0)" })
            reasons.append(contentsOf: integrator.leaseRegistryEnvironments.map { "integrator_registry_lease:\($0)" })
            if integrator.queuedAdmissions > 0 {
                reasons.append("integrator_queued_admissions:\(integrator.queuedAdmissions)")
            }
            if integrator.preparationActive { reasons.append("integrator_preparation_active") }
        }
        // A different store root is a different domain. It is not evidence
        // about the legacy recovery bytes and must not block them.

        let references = self.references
        if !references.isComplete { reasons.append("reference_projection_incomplete") }
        reasons.append(contentsOf: references.blockers)
        if references.unattributedActiveCount > 0 {
            reasons.append("reference_active_unattributed:\(references.unattributedActiveCount)")
        }
        if references.unattributedLiveUnknownCount > 0 {
            reasons.append("reference_live_unknown_unattributed:\(references.unattributedLiveUnknownCount)")
        }
        // Idle unattributed unknowns (a resumable unpinned run) are surfaced by
        // the projection but do not by themselves hold a disk open. The domain
        // barrier still blocks any future start that would need it.
        for environmentID in references.activeEnvironmentIDs where domain.ownsEnvironmentTrace(environmentID) {
            reasons.append("reference_active_environment:\(environmentID)")
        }
        for environmentID in references.unknownEnvironmentIDs where domain.ownsEnvironmentTrace(environmentID) {
            reasons.append("reference_unknown_environment:\(environmentID)")
        }

        let filesystem = self.filesystem
        if !filesystem.isComplete || filesystem.unreadableEntries {
            reasons.append("filesystem_evidence_incomplete")
        }
        if filesystem.leaseRegistryUnmeasured {
            reasons.append("filesystem_lease_registry_unmeasured")
        }
        reasons.append(contentsOf: filesystem.leaseEnvironmentIDs.map { "filesystem_lease_trace:\($0)" })
        reasons.append(contentsOf: filesystem.runtimeWorkingDirectoryIDs.map { "filesystem_runtime_trace:\($0)" })

        return Array(Set(reasons)).sorted()
    }

    public func isQuiescent(domain: RuntimeV2MaintenanceDomain) -> Bool {
        quiescenceBlockers(domain: domain).isEmpty
    }

    /// Stable digest of the evidence that authorized one intent. Never contains
    /// chat text, titles, credentials or payloads.
    public func fingerprint(domain: RuntimeV2MaintenanceDomain) -> String {
        var parts: [String] = []
        parts.append("complete=\(isComplete)")
        parts.append("blockers=\(blockers.sorted().joined(separator: ","))")
        parts.append("startup=\(startupRecoveryActive)")
        parts.append("resident=\(registry.usesResidentMachine)")
        parts.append("registry_ok=\(registry.isComplete)")
        parts.append("registry_unknown=\(registry.unknownOwnerState)")
        parts.append("starting=\(registry.startingEnvironments.sorted().joined(separator: ","))")
        parts.append("sessions=\(registry.activeSessions.sorted().joined(separator: ","))")
        parts.append("quarantined=\(registry.quarantinedEnvironments.sorted().joined(separator: ","))")
        parts.append("teardown=\(registry.teardownsInFlight.sorted().joined(separator: ","))")
        parts.append("pending_stop=\(registry.pendingStops.sorted().joined(separator: ","))")
        parts.append("shared_starts=\(registry.sharedStarts.sorted().joined(separator: ","))")
        parts.append("transactions=\(registry.lifecycleTransactions.sorted().joined(separator: ","))")
        parts.append("locks=\(registry.lifecycleLocks.sorted().joined(separator: ","))")
        parts.append("store_root=\(integrator.storeRootPath ?? "unknown")")
        parts.append("held=\(integrator.heldLeaseEnvironments.sorted().joined(separator: ","))")
        parts.append("registry_leases=\(integrator.leaseRegistryEnvironments.sorted().joined(separator: ","))")
        parts.append("queued=\(integrator.queuedAdmissions)")
        parts.append("preparing=\(integrator.preparationActive)")
        parts.append("integrator_complete=\(integrator.isComplete)")
        parts.append("integrator_blockers=\(integrator.blockers.sorted().joined(separator: ","))")
        parts.append("refs_complete=\(references.isComplete)")
        parts.append("refs_blockers=\(references.blockers.sorted().joined(separator: ","))")
        parts.append("refs_active=\(references.activeEnvironmentIDs.sorted().joined(separator: ","))")
        parts.append("refs_unknown=\(references.unknownEnvironmentIDs.sorted().joined(separator: ","))")
        parts.append("refs_unattributed_active=\(references.unattributedActiveCount)")
        parts.append("refs_unattributed_live_unknown=\(references.unattributedLiveUnknownCount)")
        parts.append("refs_unattributed_idle_unknown=\(references.unattributedIdleUnknownCount)")
        parts.append("refs_retained=\(references.retainedCount)")
        parts.append("refs_fingerprint=\(references.fingerprint)")
        parts.append("fs_leases=\(filesystem.leaseEnvironmentIDs.sorted().joined(separator: ","))")
        parts.append("fs_runtime=\(filesystem.runtimeWorkingDirectoryIDs.sorted().joined(separator: ","))")
        parts.append("fs_unreadable=\(filesystem.unreadableEntries)")
        parts.append("fs_lease_registry_unmeasured=\(filesystem.leaseRegistryUnmeasured)")
        parts.append("fs_legacy_registry=\(filesystem.legacyRegistryFingerprint ?? "unknown")")
        parts.append("fs_complete=\(filesystem.isComplete)")
        parts.append("domain=\(domain.domainKey)")
        parts.append("quiescence=\(quiescenceBlockers(domain: domain).joined(separator: ","))")
        return FloeDigest.sha256Hex(Data(parts.joined(separator: "\n").utf8))
    }
}

public typealias RuntimeV2MaintenanceEvidenceProvider =
    @Sendable () async -> RuntimeV2MaintenanceOwnerEvidence

// MARK: - Durable intent

public struct RuntimeV2MaintenanceIntentRecord: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case preparing
        case active
        case committing
        case committed
        case recovering
        case resolved
        case aborted

        public var isBlocking: Bool {
            switch self {
            case .preparing, .active, .committing, .committed, .recovering: return true
            case .resolved, .aborted: return false
            }
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var intentID: String
    public var holdGeneration: UInt64
    public var phase: Phase
    public var owner: String
    public var reason: String
    public var createdAt: Date
    public var updatedAt: Date
    public var domainRoot: String
    public var domainDevice: UInt64?
    public var domainInode: UInt64?
    public var targetRelativePath: String?
    public var targetIdentity: RuntimeV2DiskIdentity?
    public var evidenceFingerprint: String?
    public var referenceFingerprint: String?
    public var note: String?

    public init(
        intentID: String, holdGeneration: UInt64, phase: Phase, owner: String,
        reason: String, createdAt: Date, updatedAt: Date, domainRoot: String,
        domainDevice: UInt64? = nil, domainInode: UInt64? = nil,
        targetRelativePath: String? = nil, targetIdentity: RuntimeV2DiskIdentity? = nil,
        evidenceFingerprint: String? = nil, referenceFingerprint: String? = nil,
        note: String? = nil
    ) {
        self.version = Self.currentVersion
        self.intentID = intentID
        self.holdGeneration = holdGeneration
        self.phase = phase
        self.owner = owner
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.domainRoot = domainRoot
        self.domainDevice = domainDevice
        self.domainInode = domainInode
        self.targetRelativePath = targetRelativePath
        self.targetIdentity = targetIdentity
        self.evidenceFingerprint = evidenceFingerprint
        self.referenceFingerprint = referenceFingerprint
        self.note = note
    }
}

public enum RuntimeV2MaintenanceRecoveryOutcome: Sendable, Equatable {
    /// The interrupted operation is fully settled: committed bytes verified, or
    /// the pre-commit stage was removed/rolled back, with no unknown worker or
    /// fd left. Only then may the domain reopen.
    case resolved
    case unresolved(String)
}

public typealias RuntimeV2MaintenanceRecoveryHandler =
    @Sendable (RuntimeV2MaintenanceIntentRecord) async -> RuntimeV2MaintenanceRecoveryOutcome

public struct RuntimeV2MaintenanceRecoveryReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case notNeeded
        case resolved
        case blocked
    }

    public var outcome: Outcome
    public var intentID: String?
    public var reason: String?

    public init(outcome: Outcome, intentID: String? = nil, reason: String? = nil) {
        self.outcome = outcome
        self.intentID = intentID
        self.reason = reason
    }
}

public struct RuntimeV2MaintenanceState: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case open
        case maintenancePending
        case maintenanceActive
        case recoveryPending
    }

    public var phase: Phase
    public var sharedUseCount: Int
    public var holdGeneration: UInt64
    public var intentID: String?
    public var recoveryReason: String?

    public init(
        phase: Phase, sharedUseCount: Int = 0, holdGeneration: UInt64 = 0,
        intentID: String? = nil, recoveryReason: String? = nil
    ) {
        self.phase = phase
        self.sharedUseCount = sharedUseCount
        self.holdGeneration = holdGeneration
        self.intentID = intentID
        self.recoveryReason = recoveryReason
    }
}

// MARK: - Requests

public struct RuntimeV2MaintenanceRequest: Sendable, Equatable {
    /// Trusted internal owner label (for example `legacy-recovery-maintenance`).
    public var owner: String
    /// Fixed internal reason code. Never user/chat content.
    public var reason: String
    /// Layout-relative target inside `recovery/`. Nil for a domain-level intent.
    public var targetRelativePath: String?
    /// Exact preflight identity the caller observed. Read back and compared
    /// before the intent becomes active.
    public var targetIdentity: RuntimeV2DiskIdentity?

    public init(
        owner: String, reason: String,
        targetRelativePath: String? = nil,
        targetIdentity: RuntimeV2DiskIdentity? = nil
    ) {
        self.owner = owner
        self.reason = reason
        self.targetRelativePath = targetRelativePath
        self.targetIdentity = targetIdentity
    }

    public func validate() throws {
        guard !owner.isEmpty, owner.utf8.count <= 128,
              !reason.isEmpty, reason.utf8.count <= 256,
              !owner.contains(where: { $0.isNewline }),
              !reason.contains(where: { $0.isNewline }) else {
            throw RuntimeV2MaintenanceError.invalidRequest("owner/reason must be bounded single-line labels")
        }
        guard (targetRelativePath == nil) == (targetIdentity == nil) else {
            throw RuntimeV2MaintenanceError.invalidRequest("a target path and its identity must be supplied together")
        }
    }
}

// MARK: - Claims

/// A counted SHARED use of the domain. Hold it for the complete lifetime of the
/// operation that can open/capture/move the domain bytes; release only after
/// the last native worker/fd of that operation is confirmed closed. Dropping the
/// last reference is treated as an abandoned-but-finished use: the flock fd is
/// closed immediately and the coordinator drops the count asynchronously. It
/// never grants exclusive maintenance while a strongly-held claim exists.
public final class RuntimeV2MaintenanceSharedUse: @unchecked Sendable {
    public let token: String
    public let owner: String
    public let purpose: String

    private let lock = NSLock()
    private let coordinator: RuntimeV2MaintenanceCoordinator
    private let lockURL: URL
    private let lockIdentity: RuntimeV2MaintenanceLockIdentity
    private var descriptor: Int32
    private var released = false

    init(
        token: String, owner: String, purpose: String,
        descriptor: Int32, lockURL: URL,
        lockIdentity: RuntimeV2MaintenanceLockIdentity,
        coordinator: RuntimeV2MaintenanceCoordinator
    ) {
        self.token = token
        self.owner = owner
        self.purpose = purpose
        self.descriptor = descriptor
        self.lockURL = lockURL
        self.lockIdentity = lockIdentity
        self.coordinator = coordinator
    }

    deinit {
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
        let coordinator = self.coordinator
        let token = self.token
        Task { await coordinator.abandonSharedUse(token: token) }
    }

    private func takeDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return -1 }
        released = true
        let fd = descriptor
        descriptor = -1
        return fd
    }

    public func validate() async throws {
        let active = lock.withLock { !released && descriptor >= 0 }
        guard active else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the shared use claim was released")
        }
        guard RuntimeV2MaintenanceCoordinator.lockFileIdentity(at: lockURL) == lockIdentity else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the domain lock entry was replaced")
        }
        try await coordinator.validateSharedUse(token: token)
    }

    public func release() async {
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
        await coordinator.releaseSharedUse(token: token)
    }
}

/// The ONE EXCLUSIVE maintenance claim. It is valid only while the durable
/// intent is active/committing, the flock description still owns the exact lock
/// inode, and the coordinator token/epoch is current. Losing it never opens the
/// domain: the durable intent stays blocking until recovery converges.
public final class RuntimeV2MaintenanceClaim: @unchecked Sendable {
    public let intentID: String
    public let holdGeneration: UInt64
    public let targetRelativePath: String?
    /// Complete App DB reference-projection fingerprint frozen at acquisition.
    /// Recompute the projection after every await and compare before commit;
    /// a new binding/migration/job generation invalidates this claim.
    public let referenceFingerprint: String?

    private let lock = NSLock()
    private let coordinator: RuntimeV2MaintenanceCoordinator
    private let lockURL: URL
    private let lockIdentity: RuntimeV2MaintenanceLockIdentity
    private var descriptor: Int32
    private var targetIdentity: RuntimeV2DiskIdentity?
    private var released = false

    init(
        intentID: String, holdGeneration: UInt64, targetRelativePath: String?,
        targetIdentity: RuntimeV2DiskIdentity?, referenceFingerprint: String?,
        descriptor: Int32, lockURL: URL,
        lockIdentity: RuntimeV2MaintenanceLockIdentity,
        coordinator: RuntimeV2MaintenanceCoordinator
    ) {
        self.intentID = intentID
        self.holdGeneration = holdGeneration
        self.targetRelativePath = targetRelativePath
        self.targetIdentity = targetIdentity
        self.referenceFingerprint = referenceFingerprint
        self.descriptor = descriptor
        self.lockURL = lockURL
        self.lockIdentity = lockIdentity
        self.coordinator = coordinator
    }

    deinit {
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
        let coordinator = self.coordinator
        let intentID = self.intentID
        Task { await coordinator.abandonExclusiveClaim(intentID: intentID) }
    }

    private func takeDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return -1 }
        released = true
        let fd = descriptor
        descriptor = -1
        return fd
    }

    private func readDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return released ? -1 : descriptor
    }

    public func currentTargetIdentity() -> RuntimeV2DiskIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return targetIdentity
    }

    public func validate() async throws {
        guard readDescriptor() >= 0 else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim was released")
        }
        guard RuntimeV2MaintenanceCoordinator.lockFileIdentity(at: lockURL) == lockIdentity else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the domain lock entry was replaced")
        }
        try await coordinator.validateExclusiveClaim(intentID: intentID)
    }

    /// Re-stat the exact target and compare it with the identity frozen at
    /// acquisition. Call before every byte operation and again before commit.
    public func validateTargetIdentity() throws {
        guard let path = targetRelativePath else { return }
        guard let expected = currentTargetIdentity() else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("no target identity was recorded")
        }
        let resolved = try coordinator.resolveTarget(path: path)
        let observed = try RuntimeV2DiskIdentity.read(at: resolved)
        guard observed == expected else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("the target inode/size/mtime changed")
        }
    }

    /// Revalidate the complete App DB reference projection inside the barrier.
    /// The caller collects a fresh projection and passes its fingerprint. A
    /// changed binding/migration/job generation refuses the commit; the caller
    /// may re-preflight. An empty/unavailable projection must never be passed
    /// as a matching value.
    public func validateReferenceFingerprint(_ current: String) throws {
        guard !current.isEmpty else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the reference projection is unavailable")
        }
        guard let expected = referenceFingerprint else {
            throw RuntimeV2MaintenanceError.claimInvalidated("no reference projection was frozen for this claim")
        }
        guard current == expected else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the environment reference projection changed")
        }
    }

    public func markCommitting() async throws {
        try await coordinator.markExclusiveCommitting(intentID: intentID)
    }

    /// Record the post-swap target identity while still in the committing
    /// phase. The helper must call this with the exact path it committed.
    public func recordTargetIdentityAfterCommit() async throws -> RuntimeV2DiskIdentity {
        let identity = try await coordinator.recordExclusiveTargetIdentityAfterCommit(intentID: intentID)
        lock.withLock { targetIdentity = identity }
        return identity
    }

    /// Complete a committing operation: durable `committed` then `resolved`,
    /// then the flock/state are released. Idempotent when the durable phase is
    /// already `committed` but `resolved` still needs writing.
    public func commitAndRelease() async throws {
        try await coordinator.commitExclusive(intentID: intentID)
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
        await coordinator.finishReleasedExclusive(intentID: intentID)
    }

    public func handoffToRecovery() async {
        await coordinator.abandonExclusiveClaim(intentID: intentID)
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
    }

    /// Abort a claim that has NOT entered the committing phase. Once bytes may
    /// have moved, only recovery/commit may settle the intent.
    public func abortAndRelease(reason: String) async throws {
        try await coordinator.abortExclusive(intentID: intentID, reason: reason)
        let fd = takeDescriptor()
        if fd >= 0 { _ = close(fd) }
    }
}

// MARK: - Coordinator

public actor RuntimeV2MaintenanceCoordinator {
    public let domain: RuntimeV2MaintenanceDomain
    public let stateDirectory: URL
    public let lockURL: URL
    public let intentURL: URL
    nonisolated let historyLayout: RuntimeV2MaintenanceHistoryLayout?
    public nonisolated let storageDirectories: [URL]

    private struct SharedRecord {
        var owner: String
        var purpose: String
        var descriptor: Int32
        var lockIdentity: RuntimeV2MaintenanceLockIdentity
        var historyLocks: RuntimeV2MaintenanceHistoryLocks? = nil
    }

    private struct ExclusiveRecord {
        var intentID: String
        var holdGeneration: UInt64
        var epoch: UInt64
        var descriptor: Int32
        var lockIdentity: RuntimeV2MaintenanceLockIdentity
        var targetRelativePath: String?
        var targetIdentity: RuntimeV2DiskIdentity?
        var phase: RuntimeV2MaintenanceIntentRecord.Phase
        var record: RuntimeV2MaintenanceIntentRecord
        var historyLocks: RuntimeV2MaintenanceHistoryLocks? = nil
        var completedHistoryLookupClaimed = false
    }

    private let fileManager: FileManager
    private var evidenceProvider: RuntimeV2MaintenanceEvidenceProvider
    private var recoveryHandler: RuntimeV2MaintenanceRecoveryHandler?
    private var shared: [String: SharedRecord] = [:]
    private var exclusive: ExclusiveRecord?
    private var intentInstalling = false
    private var preparingHistoryLocks: RuntimeV2MaintenanceHistoryLocks?
    private var recoveryPending = false
    private var recoveryReason: String?
    private var requiredIntentDirectories: Set<URL> = []
    private struct RecoveryValidation {
        let record: RuntimeV2MaintenanceIntentRecord
        let descriptor: Int32
        let lockIdentity: RuntimeV2MaintenanceLockIdentity
        let directory: URL
        let intentIdentity: RuntimeV2DiskIdentity
        let historyLocks: RuntimeV2MaintenanceHistoryLocks?
        var storageContextClaimed = false
    }
    private var recoveryValidation: RecoveryValidation?
    private var holdGeneration: UInt64
    private var epoch: UInt64 = 1

    public init(
        domain: RuntimeV2MaintenanceDomain,
        stateDirectory: URL,
        evidenceProvider: @escaping RuntimeV2MaintenanceEvidenceProvider,
        recoveryHandler: RuntimeV2MaintenanceRecoveryHandler? = nil,
        historyLayout: RuntimeV2MaintenanceHistoryLayout? = nil,
        fileManager: FileManager = .default
    ) throws {
        let protectedLayout: RuntimeV2MaintenanceHistoryLayout?
        if let historyLayout {
            guard historyLayout.domain == domain, historyLayout.primaryDirectory == stateDirectory.standardizedFileURL else {
                throw RuntimeV2MaintenanceError.invalidDomain("native history layout differs from the coordinator")
            }
            protectedLayout = try historyLayout.prepareNativeDirectories()
        } else { protectedLayout = nil }
        self.domain = domain
        self.historyLayout = protectedLayout
        self.storageDirectories = protectedLayout?.directories ?? [stateDirectory.standardizedFileURL]
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.lockURL = protectedLayout?.anchor ?? stateDirectory.standardizedFileURL.appendingPathComponent("maintenance.lock")
        self.intentURL = stateDirectory.standardizedFileURL.appendingPathComponent("intent.json")
        self.fileManager = fileManager
        self.evidenceProvider = evidenceProvider
        self.recoveryHandler = recoveryHandler
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? (stateDirectory as NSURL).setResourceValue(values.isExcludedFromBackup, forKey: .isExcludedFromBackupKey)
        self.holdGeneration = 0
        // ALL durable histories close the gate immediately. Counts and old
        // path indexes cannot waive a corrupt/mismatched/pending record.
        for directory in self.storageDirectories {
            let url = directory.appendingPathComponent("intent.json")
            self.holdGeneration = max(self.holdGeneration, Self.readHoldGeneration(intentURL: url))
            if let value = Self.readIntent(intentURL: url) {
                self.requiredIntentDirectories.insert(directory)
                switch value {
                case .record(let record):
                    if !domain.matchesRecordedRoot(record.domainRoot, device: record.domainDevice, inode: record.domainInode) {
                        self.recoveryPending = true; self.recoveryReason = "durable history physical identity differs or is unknown"
                    } else if record.phase.isBlocking {
                        self.recoveryPending = true; self.recoveryReason = "durable history requires native convergence"
                    }
                case .corrupt:
                    self.recoveryPending = true; self.recoveryReason = "durable history is unreadable"
                }
            }
        }
    }

    public func installEvidenceProvider(_ provider: @escaping RuntimeV2MaintenanceEvidenceProvider) {
        evidenceProvider = provider
    }

    public func installRecoveryHandler(_ handler: RuntimeV2MaintenanceRecoveryHandler?) {
        recoveryHandler = handler
    }

    public func state() -> RuntimeV2MaintenanceState {
        if recoveryPending {
            return RuntimeV2MaintenanceState(
                phase: .recoveryPending, sharedUseCount: shared.count,
                holdGeneration: holdGeneration, intentID: exclusive?.intentID,
                recoveryReason: recoveryReason
            )
        }
        if exclusive != nil {
            return RuntimeV2MaintenanceState(
                phase: .maintenanceActive, sharedUseCount: shared.count,
                holdGeneration: holdGeneration, intentID: exclusive?.intentID
            )
        }
        if intentInstalling {
            return RuntimeV2MaintenanceState(
                phase: .maintenancePending, sharedUseCount: shared.count,
                holdGeneration: holdGeneration
            )
        }
        return RuntimeV2MaintenanceState(
            phase: .open, sharedUseCount: shared.count, holdGeneration: holdGeneration
        )
    }

    public func ownsEnvironmentTrace(_ environmentID: String) -> Bool {
        domain.ownsEnvironmentTrace(environmentID, fileManager: fileManager)
    }

    // MARK: recovery

    /// Converge a crash-interrupted/durable intent. Without an installed
    /// recovery handler the domain stays closed FOREVER — there is no TTL and
    /// no "stale enough" default. The handler must prove the operation's final
    /// state; a mere elapsed-time answer is not accepted by this contract.
    private struct PendingHistory {
        let directory: URL
        let record: RuntimeV2MaintenanceIntentRecord
    }

    private func pendingHistories() throws -> [PendingHistory] {
        var pending: [PendingHistory] = []
        var ids = Set<String>(), targets = Set<String>()
        for directory in storageDirectories {
            guard let value = Self.readIntent(intentURL: directory.appendingPathComponent("intent.json")) else {
                guard !requiredIntentDirectories.contains(directory) else {
                    throw RuntimeV2MaintenanceError.recoveryPending("a retained historical intent disappeared")
                }
                continue
            }
            guard case .record(let record) = value,
                  domain.matchesRecordedRoot(record.domainRoot, device: record.domainDevice, inode: record.domainInode),
                  ids.insert(record.intentID).inserted else {
                throw RuntimeV2MaintenanceError.recoveryPending("a history is corrupt, duplicated or has unknown physical identity")
            }
            if record.phase.isBlocking {
                if let target = record.targetRelativePath, !targets.insert(target).inserted {
                    throw RuntimeV2MaintenanceError.recoveryPending("pending histories overlap the same target")
                }
                pending.append(PendingHistory(directory: directory, record: record))
            }
        }
        return pending.sorted { $0.directory.path < $1.directory.path }
    }

    public func recoverIfNeeded() async -> RuntimeV2MaintenanceRecoveryReport {
        guard exclusive == nil, recoveryValidation == nil, !intentInstalling, shared.isEmpty else {
            return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: "a live claim is still installed")
        }
        let pending: [PendingHistory]
        do { pending = try pendingHistories() }
        catch {
            recoveryPending = true; recoveryReason = "durable histories cannot be verified"
            return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: recoveryReason)
        }
        guard let first = pending.first else {
            if historyLayout != nil {
                do {
                    let probe = try openLock(operation: LOCK_SH)
                    defer { _ = close(probe.descriptor); withExtendedLifetime(probe.historyLocks) {} }
                    guard try pendingHistories().isEmpty else {
                        throw RuntimeV2MaintenanceError.recoveryPending("history changed while checking terminal state")
                    }
                    try probe.historyLocks?.validate()
                } catch {
                    recoveryPending = true; recoveryReason = "native history membership or terminal state is unverified"
                    return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: recoveryReason)
                }
            }
            recoveryPending = false; recoveryReason = nil
            RuntimeV2RecoveryAdmission.gate(domain.root)?.confirmNoBlockingIntent()
            return RuntimeV2MaintenanceRecoveryReport(outcome: .notNeeded)
        }
        recoveryPending = true
        var activeID = first.record.intentID
        let opened: OpenedLock
        do {
            try RuntimeV2RecoveryAdmission.gate(domain.root)?.beginExclusive(activeID, recovery: true)
            opened = try openLock(operation: LOCK_EX)
        } catch {
            RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(activeID, converged: false)
            return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: "a native history lock is busy or changed")
        }
        var allConverged = false
        defer {
            recoveryValidation = nil
            _ = close(opened.descriptor)
            // No between-job reopen. The cohort retains every namespace until
            // this complete pass exits; any unresolved history stays blocking.
            withExtendedLifetime(opened.historyLocks) {
                RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(activeID, converged: allConverged)
            }
        }
        guard let recoveryHandler else {
            return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: "no trusted recovery handler is installed")
        }
        do {
            let locked = try pendingHistories()
            guard locked.count == pending.count,
                  try zip(locked, pending).allSatisfy({ left, right in
                      guard left.directory == right.directory else { return false }
                      return try Self.intentEncoder.encode(left.record) == Self.intentEncoder.encode(right.record)
                  }) else {
                throw RuntimeV2MaintenanceError.recoveryPending("history changed before all locks were held")
            }
            var handlersConverged = true
            for job in pending {
                if Task.isCancelled { handlersConverged = false; break }
                try opened.historyLocks?.validate()
                try RuntimeV2RecoveryAdmission.gate(domain.root)?.advanceRecoveryIntent(from: activeID, to: job.record.intentID)
                activeID = job.record.intentID
                let intentIdentity = try RuntimeV2DiskIdentity.read(at: job.directory.appendingPathComponent("intent.json"))
                guard intentIdentity.isRegularFile, intentIdentity.linkCount == 1 else {
                    throw RuntimeV2MaintenanceError.recoveryPending("historical intent shape changed")
                }
                recoveryValidation = RecoveryValidation(record: job.record, descriptor: opened.descriptor,
                    lockIdentity: opened.identity, directory: job.directory, intentIdentity: intentIdentity,
                    historyLocks: opened.historyLocks)
                switch await recoveryHandler(job.record) {
                case .resolved:
                    guard historyLayout == nil || recoveryValidation?.storageContextClaimed == true else {
                        FloeLogger(category: .tools).error("legacyHistoryRecovery code=storage_context_unclaimed rootCheck=verified")
                        handlersConverged = false
                        recoveryValidation = nil
                        continue
                    }
                    try validateRecoverySession(intentID: job.record.intentID, holdGeneration: job.record.holdGeneration)
                    guard let current = try Self.readHistoryIntent(directory: job.directory),
                          try Self.intentEncoder.encode(current) == Self.intentEncoder.encode(job.record) else {
                        throw RuntimeV2MaintenanceError.recoveryPending("historical intent CAS changed")
                    }
                    var resolved = job.record
                    resolved.phase = .resolved; resolved.updatedAt = Date()
                    resolved.note = job.record.note ?? "interrupted maintenance converged under the native all-history barrier"
                    try persistIntent(resolved, in: job.directory)
                case .unresolved:
                    handlersConverged = false
                    try validateRecoverySession(intentID: job.record.intentID, holdGeneration: job.record.holdGeneration)
                    FloeLogger(category: .tools).error("legacyHistoryRecovery code=handler_unresolved rootCheck=verified")
                    // Other distinct pending targets may still converge. This
                    // failure remains intact and the global gate never opens.
                    break
                }
                recoveryValidation = nil
            }
            let remaining = try pendingHistories()
            try opened.historyLocks?.validate()
            allConverged = remaining.isEmpty && handlersConverged
            recoveryPending = !allConverged
            recoveryReason = allConverged ? nil : "one or more native histories still require convergence"
            if allConverged { epoch &+= 1 }
            return RuntimeV2MaintenanceRecoveryReport(outcome: allConverged ? .resolved : .blocked,
                intentID: pending.count == 1 ? first.record.intentID : nil, reason: recoveryReason)
        } catch {
            recoveryPending = true; recoveryReason = "history lock, identity or durable resolution could not be verified"
            return RuntimeV2MaintenanceRecoveryReport(outcome: .blocked, reason: recoveryReason)
        }
    }

    /// Native storage routing is valid ONLY under the actual held session.
    public func recoveryStorageDirectory(intentID: String, holdGeneration: UInt64) throws -> URL {
        try validateRecoverySession(intentID: intentID, holdGeneration: holdGeneration)
        guard var active = recoveryValidation else { throw RuntimeV2MaintenanceError.claimInvalidated("no recovery context") }
        active.storageContextClaimed = true; recoveryValidation = active
        return active.directory
    }

    /// A list of protected provenance contexts, not an arbitrary-path API.
    public func completedStorageDirectories(intentID: String, holdGeneration: UInt64) throws -> [URL] {
        try validateExclusiveClaim(intentID: intentID)
        guard var active = exclusive, active.holdGeneration == holdGeneration else {
            throw RuntimeV2MaintenanceError.claimInvalidated("history lookup generation differs")
        }
        active.completedHistoryLookupClaimed = true; exclusive = active
        return storageDirectories
    }

    /// An evidence collector can inspect only the intent currently protected by
    /// this actor's admission/lock. It cannot use a cached record to authorize IO.
    public func nativeClosureIntent() throws -> RuntimeV2MaintenanceIntentRecord {
        if let validation = recoveryValidation { return validation.record }
        if let exclusive { return exclusive.record }
        guard intentInstalling, let value = Self.readIntent(intentURL: intentURL),
              case .record(let record) = value, record.phase == .preparing else {
            throw RuntimeV2MaintenanceError.claimInvalidated("no held native closure intent")
        }
        try preparingHistoryLocks?.validate()
        return record
    }

    public func isNativeRecoverySession(intentID: String) -> Bool {
        recoveryValidation?.record.intentID == intentID
    }

    /// Only the actor's actual held recovery lock can validate this session.
    /// A durable marker, dead pid, TTL or caller assertion cannot manufacture it.
    public func validateRecoverySession(intentID: String, holdGeneration: UInt64) throws {
        try recoveryValidation?.historyLocks?.validate()
        guard let validation = recoveryValidation,
              validation.record.intentID == intentID,
              validation.record.holdGeneration == holdGeneration,
              fcntl(validation.descriptor, F_GETFD, 0) != -1,
              Self.lockFileIdentity(at: lockURL) == validation.lockIdentity,
              (try? RuntimeV2DiskIdentity.read(at: validation.directory.appendingPathComponent("intent.json"))) == validation.intentIdentity,
              domain.matchesRecordedRoot(validation.record.domainRoot,
                  device: validation.record.domainDevice, inode: validation.record.domainInode) else {
            throw RuntimeV2MaintenanceError.claimInvalidated("recovery authority is not held")
        }
    }

    // MARK: shared use

    public func acquireSharedUse(
        owner: String, purpose: String
    ) async throws -> RuntimeV2MaintenanceSharedUse {
        guard !owner.isEmpty, owner.utf8.count <= 128,
              !purpose.isEmpty, purpose.utf8.count <= 128,
              !owner.contains(where: { $0.isNewline }),
              !purpose.contains(where: { $0.isNewline }) else {
            throw RuntimeV2MaintenanceError.invalidRequest("shared use owner/purpose must be bounded labels")
        }
        if intentInstalling {
            throw RuntimeV2MaintenanceError.maintenanceActive("a maintenance intent is being installed")
        }
        if let exclusive {
            throw RuntimeV2MaintenanceError.maintenanceActive("maintenance \(exclusive.intentID) holds the domain")
        }
        if recoveryPending {
            throw RuntimeV2MaintenanceError.recoveryPending(recoveryReason ?? "the domain is awaiting convergence")
        }
        if let blocking = blockingIntentOnDisk() {
            recoveryPending = true
            recoveryReason = blocking
            throw RuntimeV2MaintenanceError.recoveryPending(blocking)
        }
        if let gate = RuntimeV2RecoveryAdmission.gate(domain.root), !gate.snapshot().coverageComplete {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["native_owner_close_unproven"])
        }
        let token = UUID().uuidString
        let opened = try openLock(operation: LOCK_SH)
        shared[token] = SharedRecord(
            owner: owner, purpose: purpose,
            descriptor: opened.descriptor, lockIdentity: opened.identity, historyLocks: opened.historyLocks
        )
        return RuntimeV2MaintenanceSharedUse(
            token: token, owner: owner, purpose: purpose,
            descriptor: opened.descriptor, lockURL: lockURL,
            lockIdentity: opened.identity, coordinator: self
        )
    }

    func validateSharedUse(token: String) throws {
        try shared[token]?.historyLocks?.validate()
        guard let record = shared[token] else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the shared use token is no longer active")
        }
        guard fcntl(record.descriptor, F_GETFD, 0) != -1 else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the shared use descriptor is closed")
        }
        guard Self.lockFileIdentity(at: lockURL) == record.lockIdentity else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the domain lock entry was replaced")
        }
    }

    func releaseSharedUse(token: String) {
        shared.removeValue(forKey: token)
    }

    func abandonSharedUse(token: String) {
        shared.removeValue(forKey: token)
    }

    // MARK: exclusive maintenance

    public func acquireExclusiveMaintenance(
        _ request: RuntimeV2MaintenanceRequest
    ) async throws -> RuntimeV2MaintenanceClaim {
        try request.validate()
        if exclusive != nil {
            throw RuntimeV2MaintenanceError.maintenanceActive("maintenance is already active")
        }
        if intentInstalling {
            throw RuntimeV2MaintenanceError.maintenanceActive("a maintenance intent is already being installed")
        }
        if recoveryPending {
            throw RuntimeV2MaintenanceError.recoveryPending(recoveryReason ?? "the domain is awaiting convergence")
        }
        if let blocking = blockingIntentOnDisk() {
            recoveryPending = true
            recoveryReason = blocking
            throw RuntimeV2MaintenanceError.recoveryPending(blocking)
        }
        guard shared.isEmpty else {
            throw RuntimeV2MaintenanceError.maintenanceActive("shared use is active")
        }

        let targetPath: String?
        let requestedIdentity: RuntimeV2DiskIdentity?
        if let path = request.targetRelativePath {
            targetPath = try domain.validateTargetRelativePath(path)
            let resolved = try resolveTarget(path: path)
            guard fileManager.fileExists(atPath: resolved.path) else {
                throw RuntimeV2MaintenanceError.targetMissing("the target does not exist")
            }
            let observed = try RuntimeV2DiskIdentity.read(at: resolved)
            guard observed.isRegularFile else {
                throw RuntimeV2MaintenanceError.invalidTarget("the target is not a regular file")
            }
            if let expected = request.targetIdentity, expected != observed {
                throw RuntimeV2MaintenanceError.targetIdentityMismatch("preflight identity does not match the target")
            }
            requestedIdentity = observed
        } else {
            targetPath = nil
            requestedIdentity = nil
        }

        let intentID = UUID().uuidString
        guard holdGeneration < UInt64.max else {
            throw RuntimeV2MaintenanceError.invalidRequest("maintenance generation exhausted")
        }
        let generation = holdGeneration + 1
        let now = Date()
        var record = RuntimeV2MaintenanceIntentRecord(
            intentID: intentID, holdGeneration: generation, phase: .preparing,
            owner: request.owner, reason: request.reason,
            createdAt: now, updatedAt: now, domainRoot: domain.root.path,
            targetRelativePath: targetPath, targetIdentity: requestedIdentity
        )

        let initialDomainIdentity = try RuntimeV2DiskIdentity.read(at: domain.root)
        record.domainDevice = initialDomainIdentity.device
        record.domainInode = initialDomainIdentity.inode
        try RuntimeV2RecoveryAdmission.gate(domain.root)?.beginExclusive(intentID, recovery: false)

        // Reserve the exclusive flock BEFORE the durable preparing intent and
        // before any await. A recovery in another process can therefore never
        // mistake a live preflight for a crashed one, and a cooperating shared
        // opener is already excluded by the file lock. The durable intent is
        // still written before the first await.
        intentInstalling = true
        let opened: OpenedLock
        do {
            opened = try openLock(operation: LOCK_EX)
        } catch {
            intentInstalling = false
            RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: true)
            throw error
        }
        do {
            try persistIntent(record)
        } catch {
            _ = close(opened.descriptor)
            intentInstalling = false
            RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: false)
            recoveryPending = true
            recoveryReason = "preparing intent persistence is uncertain"
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("preparing intent")
        }

        preparingHistoryLocks = opened.historyLocks
        defer { preparingHistoryLocks = nil }
        do {
            let evidence = await evidenceProvider()
            try opened.historyLocks?.validate()
            var blockers = evidence.quiescenceBlockers(domain: domain)
            if evidence.references.fingerprint.isEmpty {
                blockers.append("reference_fingerprint_missing")
            }
            guard evidence.isComplete, blockers.isEmpty else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(blockers)
            }
            // The target may have been replaced while evidence was collected.
            if let targetPath, let requestedIdentity {
                let resolved = try resolveTarget(path: targetPath)
                let observed = try RuntimeV2DiskIdentity.read(at: resolved)
                guard observed == requestedIdentity else {
                    throw RuntimeV2MaintenanceError.targetIdentityMismatch("the target changed during preflight")
                }
            }
            let domainIdentity = try RuntimeV2DiskIdentity.read(at: domain.root)
            guard (domainIdentity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) else {
                throw RuntimeV2MaintenanceError.invalidDomain("the trusted root is not a directory")
            }
            guard shared.isEmpty else {
                throw RuntimeV2MaintenanceError.maintenanceActive("a shared use appeared during preflight")
            }
            record.phase = .active
            record.updatedAt = Date()
            record.domainDevice = domainIdentity.device
            record.domainInode = domainIdentity.inode
            record.evidenceFingerprint = evidence.fingerprint(domain: domain)
            record.referenceFingerprint = evidence.references.fingerprint
            do {
                try persistIntent(record)
            } catch {
                throw RuntimeV2MaintenanceError.intentPersistenceFailed("active intent")
            }
            exclusive = ExclusiveRecord(
                intentID: intentID, holdGeneration: generation, epoch: epoch,
                descriptor: opened.descriptor, lockIdentity: opened.identity,
                targetRelativePath: targetPath, targetIdentity: requestedIdentity,
                phase: .active, record: record, historyLocks: opened.historyLocks
            )
            holdGeneration = generation
            epoch &+= 1
            intentInstalling = false
            return RuntimeV2MaintenanceClaim(
                intentID: intentID, holdGeneration: generation,
                targetRelativePath: targetPath, targetIdentity: requestedIdentity,
                referenceFingerprint: evidence.references.fingerprint,
                descriptor: opened.descriptor, lockURL: lockURL,
                lockIdentity: opened.identity, coordinator: self
            )
        } catch {
            intentInstalling = false
            var aborted = record
            aborted.phase = .aborted
            aborted.updatedAt = Date()
            aborted.note = "preflight failed before any byte operation"
            var abortedPersisted = false
            do { try persistIntent(aborted); abortedPersisted = true }
            catch { recoveryPending = true; recoveryReason = "preflight abort could not be persisted" }
            _ = close(opened.descriptor)
            RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: abortedPersisted)
            epoch &+= 1
            throw error
        }
    }

    func validateExclusiveClaim(intentID: String) throws {
        try exclusive?.historyLocks?.validate()
        guard let record = exclusive, record.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim is no longer installed")
        }
        guard record.phase == .active || record.phase == .committing else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the intent is \(record.phase.rawValue)")
        }
        guard fcntl(record.descriptor, F_GETFD, 0) != -1 else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive descriptor is closed")
        }
        guard Self.lockFileIdentity(at: lockURL) == record.lockIdentity else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the domain lock entry was replaced")
        }
        guard let expectedDevice = record.record.domainDevice,
              let expectedInode = record.record.domainInode,
              let domainIdentity = try? RuntimeV2DiskIdentity.read(at: domain.root),
              domainIdentity.device == expectedDevice,
              domainIdentity.inode == expectedInode else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the trusted domain root identity changed")
        }
    }

    nonisolated func resolveTarget(path: String) throws -> URL {
        let validated = try domain.validateTargetRelativePath(path)
        let resolvedRoot = domain.root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = domain.root.appendingPathComponent(validated)
        let expected = resolvedRoot.appendingPathComponent(validated).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == expected.path else {
            throw RuntimeV2MaintenanceError.invalidTarget("the target escapes the trusted domain through a symlink")
        }
        return resolved
    }

    func markExclusiveCommitting(intentID: String) throws {
        try validateExclusiveClaim(intentID: intentID)
        guard var record = exclusive, record.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim is no longer installed")
        }
        guard historyLayout == nil || record.completedHistoryLookupClaimed else {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("protected history lookup was not performed")
        }
        guard record.phase == .active || record.phase == .committing else {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("the intent is \(record.phase.rawValue)")
        }
        record.record.phase = .committing
        record.record.updatedAt = Date()
        record.phase = .committing
        do { try persistIntent(record.record) } catch {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("committing intent")
        }
        exclusive = record
    }

    func recordExclusiveTargetIdentityAfterCommit(intentID: String) async throws -> RuntimeV2DiskIdentity {
        guard var record = exclusive, record.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim is no longer installed")
        }
        guard record.phase == .committing else {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("the intent must enter committing first")
        }
        guard let path = record.targetRelativePath else {
            throw RuntimeV2MaintenanceError.invalidTarget("no target path was recorded")
        }
        let resolved = try resolveTarget(path: path)
        let identity = try RuntimeV2DiskIdentity.read(at: resolved)
        record.targetIdentity = identity
        record.record.targetIdentity = identity
        record.record.updatedAt = Date()
        do { try persistIntent(record.record) } catch {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("post-commit identity")
        }
        exclusive = record
        return identity
    }

    func commitExclusive(intentID: String) throws {
        guard var record = exclusive, record.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim is no longer installed")
        }
        guard record.phase == .committing || record.phase == .committed else {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("the intent must enter committing first")
        }
        if record.phase == .active {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("the intent must enter committing first")
        }
        if record.phase == .committing {
            record.record.phase = .committed
            record.record.updatedAt = Date()
            do { try persistIntent(record.record) } catch {
                throw RuntimeV2MaintenanceError.intentPersistenceFailed("committed intent")
            }
            record.phase = .committed
            exclusive = record
        }
        guard let committed = exclusive, committed.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim disappeared")
        }
        record = committed
        record.record.phase = .resolved
        record.record.updatedAt = Date()
        do { try persistIntent(record.record) } catch {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("resolved intent")
        }
        record.phase = .resolved
        exclusive = record
    }

    func finishReleasedExclusive(intentID: String) async {
        guard exclusive?.intentID == intentID else { return }
        exclusive = nil
        recoveryPending = false
        recoveryReason = nil
        RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: true)
        epoch &+= 1
    }

    func abortExclusive(intentID: String, reason: String) throws {
        guard let record = exclusive, record.intentID == intentID else {
            throw RuntimeV2MaintenanceError.claimInvalidated("the exclusive claim is no longer installed")
        }
        guard record.phase == .active else {
            throw RuntimeV2MaintenanceError.claimNotCommitEligible("the intent cannot abort after committing began")
        }
        var aborted = record.record
        aborted.phase = .aborted
        aborted.updatedAt = Date()
        aborted.note = String(reason.prefix(256))
        do { try persistIntent(aborted) } catch {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("aborted intent")
        }
        exclusive = nil
        recoveryPending = false
        recoveryReason = nil
        RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: true)
        epoch &+= 1
    }

    /// Called from a dropped claim: the durable intent becomes `recovering` and
    /// the domain stays closed until the trusted recovery handler converges.
    func abandonExclusiveClaim(intentID: String) async {
        guard let record = exclusive, record.intentID == intentID else { return }
        var recovering = record.record
        recovering.phase = .recovering
        recovering.updatedAt = Date()
        recovering.note = "the exclusive claim was dropped before a durable terminal state"
        try? persistIntent(recovering)
        exclusive = nil
        recoveryPending = true
        recoveryReason = "intent \(intentID) was dropped without a terminal state"
        RuntimeV2RecoveryAdmission.gate(domain.root)?.endExclusive(intentID, converged: false)
        epoch &+= 1
    }

    // MARK: file helpers

    private struct OpenedLock {
        var descriptor: Int32
        var identity: RuntimeV2MaintenanceLockIdentity
        var historyLocks: RuntimeV2MaintenanceHistoryLocks? = nil
    }

    private func openLock(operation: Int32) throws -> OpenedLock {
        if let historyLayout {
            let locks = try RuntimeV2MaintenanceHistoryLocks.acquire(historyLayout, operation: operation)
            let fd = try locks.duplicateAnchor()
            guard let identity = Self.lockFileIdentity(at: lockURL) else {
                close(fd); throw RuntimeV2MaintenanceError.crossProcessOwner("group anchor identity unavailable")
            }
            return OpenedLock(descriptor: fd, identity: identity, historyLocks: locks)
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw RuntimeV2MaintenanceError.crossProcessOwner("the domain lock could not be opened")
        }
        guard flock(descriptor, operation | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw RuntimeV2MaintenanceError.crossProcessOwner("a cooperating process holds the domain")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            _ = close(descriptor)
            throw RuntimeV2MaintenanceError.crossProcessOwner("the domain lock identity is unreadable")
        }
        return OpenedLock(
            descriptor: descriptor,
            identity: RuntimeV2MaintenanceLockIdentity(
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino)
            )
        )
    }

    static func lockFileIdentity(at url: URL) -> RuntimeV2MaintenanceLockIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return RuntimeV2MaintenanceLockIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    private func blockingIntentOnDisk() -> String? {
        do { return try pendingHistories().isEmpty ? nil : "durable histories still require convergence" }
        catch { return "durable histories are unreadable or have unknown physical identity" }
    }

    nonisolated static func readHistoryIntent(directory: URL) throws -> RuntimeV2MaintenanceIntentRecord? {
        guard let value = readIntent(intentURL: directory.appendingPathComponent("intent.json")) else { return nil }
        guard case .record(let record) = value else {
            throw RuntimeV2MaintenanceError.recoveryPending("historical intent is unreadable")
        }
        return record
    }

    /// Bootstrap reads through the already verified namespace descriptor. A
    /// missing intent is the only reason to classify a namespace as intentless;
    /// FileManager.fileExists also returns false when an existing file cannot
    /// be inspected, which previously sent that case down the wrong path.
    nonisolated static func readHistoryIntent(directoryFD: Int32) throws -> RuntimeV2MaintenanceIntentRecord? {
        let fd = openat(directoryFD, "intent.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                posixErrno: errno, stage: .intentOpen)
        }
        defer { close(fd) }
        var before = stat(), named = stat(), after = stat(), finalNamed = stat()
        guard fstat(fd, &before) == 0,
              fstatat(directoryFD, "intent.json", &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                posixErrno: errno, stage: .intentStat)
        }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 1 << 20,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                stage: .intentStat)
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        let expected = bytes.count
        while offset < expected {
            let count = bytes.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: offset), expected - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                    posixErrno: count < 0 ? errno : nil, stage: .intentRead)
            }
            offset += count
        }
        guard fstat(fd, &after) == 0,
              fstatat(directoryFD, "intent.json", &finalNamed, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                posixErrno: errno, stage: .intentStat)
        }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_dev == finalNamed.st_dev, before.st_ino == finalNamed.st_ino else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                stage: .intentChanged)
        }
        #if canImport(Darwin)
        guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                stage: .intentChanged)
        }
        #else
        guard before.st_mtim.tv_sec == after.st_mtim.tv_sec,
              before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
              before.st_ctim.tv_sec == after.st_ctim.tv_sec,
              before.st_ctim.tv_nsec == after.st_ctim.tv_nsec else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                stage: .intentChanged)
        }
        #endif
        guard let record = try? intentDecoder.decode(RuntimeV2MaintenanceIntentRecord.self, from: Data(bytes)),
              record.version == RuntimeV2MaintenanceIntentRecord.currentVersion else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historyUnreadable, rootCheck: .verified,
                stage: .intentPayload)
        }
        return record
    }

    /// Bounded, readonly discovery before any legacy owner is constructed.
    /// A different/copy identity or ambiguous history blocks instead of opening
    /// a fresh empty authority namespace under the new container UUID.
    nonisolated static func authorityStateDirectory(for domain: RuntimeV2MaintenanceDomain) throws -> URL {
        let parent = domain.root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority", isDirectory: true)
        let fresh = parent.appendingPathComponent(domain.domainKey, isDirectory: true)
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return fresh }
        guard fd >= 0 else { throw RuntimeV2MaintenanceError.invalidDomain("authority directory unavailable") }
        var parentIdentity = stat()
        guard fstat(fd, &parentIdentity) == 0 else { close(fd); throw RuntimeV2MaintenanceError.invalidDomain("authority parent identity unavailable") }
        guard let stream = fdopendir(fd) else { close(fd); throw RuntimeV2MaintenanceError.invalidDomain("authority enumeration unavailable") }
        defer { closedir(stream) }
        var matches: [URL] = []; var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw RuntimeV2MaintenanceError.invalidDomain("authority enumeration changed") }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 128, name.utf8.count == 64,
                  name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RuntimeV2MaintenanceError.invalidDomain("authority directory shape or budget unknown")
            }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw RuntimeV2MaintenanceError.invalidDomain("authority entry is not a real directory") }
            defer { close(child) }
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            let record = readIntent(intentURL: directory.appendingPathComponent("intent.json"))
            if let record {
                guard case .record(let intent) = record,
                      domain.matchesRecordedRoot(intent.domainRoot, device: intent.domainDevice, inode: intent.domainInode) else {
                    throw RuntimeV2MaintenanceError.invalidDomain("retained authority has unknown or different physical identity")
                }
                matches.append(directory)
            } else {
                // Only an empty directory / old admission lock has no journal
                // ownership to recover. Any other content remains protected.
                let duplicate = dup(child)
                guard duplicate >= 0, let children = fdopendir(duplicate) else {
                    if duplicate >= 0 { close(duplicate) }
                    throw RuntimeV2MaintenanceError.invalidDomain("authority contents unavailable")
                }
                defer { closedir(children) }
                var entries = 0
                while true {
                    errno = 0
                    guard let item = readdir(children) else {
                        guard errno == 0 else { throw RuntimeV2MaintenanceError.invalidDomain("authority contents changed") }
                        break
                    }
                    let value = withUnsafePointer(to: item.pointee.d_name) {
                        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                    }
                    if value == "." || value == ".." { continue }
                    entries += 1
                    var info = stat()
                    guard entries <= 1, value == "admission.lock",
                          fstatat(child, value, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                        throw RuntimeV2MaintenanceError.invalidDomain("authority history lacks its durable identity")
                    }
                }
            }
            var opened = stat(); var named = stat()
            guard fstat(child, &opened) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                throw RuntimeV2MaintenanceError.invalidDomain("authority entry changed during discovery")
            }
        }
        var parentNamed = stat()
        guard lstat(parent.path, &parentNamed) == 0, parentNamed.st_mode & S_IFMT == S_IFDIR,
              parentNamed.st_dev == parentIdentity.st_dev, parentNamed.st_ino == parentIdentity.st_ino else {
            throw RuntimeV2MaintenanceError.invalidDomain("authority parent changed during discovery")
        }
        guard matches.count <= 1 else {
            throw RuntimeV2MaintenanceBootstrapFailure(.historiesAmbiguous, rootCheck: .verified, histories: matches.count)
        }
        return matches.first ?? fresh
    }

    private enum IntentReadState {
        case record(RuntimeV2MaintenanceIntentRecord)
        case corrupt
    }

    private static func readIntent(intentURL: URL) -> IntentReadState? {
        guard FileManager.default.fileExists(atPath: intentURL.path) else { return nil }
        guard let data = Self.readBoundedIntentData(intentURL),
              let record = try? Self.intentDecoder.decode(RuntimeV2MaintenanceIntentRecord.self, from: data),
              record.version == RuntimeV2MaintenanceIntentRecord.currentVersion else {
            return .corrupt
        }
        return .record(record)
    }

    private static func readBoundedIntentData(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var before = stat(); var after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= 1 << 20,
              let named = try? RuntimeV2DiskIdentity.read(at: url),
              named.device == UInt64(bitPattern: Int64(before.st_dev)), named.inode == UInt64(before.st_ino) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)); var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let result = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return nil }; offset += result
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, (try? RuntimeV2DiskIdentity.read(at: url)) == named else { return nil }
        return Data(bytes)
    }

    private static func readHoldGeneration(intentURL: URL) -> UInt64 {
        guard let state = readIntent(intentURL: intentURL) else { return 0 }
        if case .record(let record) = state { return record.holdGeneration }
        return 0
    }

    private func persistIntent(_ record: RuntimeV2MaintenanceIntentRecord, in storageDirectory: URL? = nil) throws {
        let destination = storageDirectory ?? stateDirectory
        guard storageDirectories.contains(destination) else {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("unprotected native history context")
        }
        let intentURL = destination.appendingPathComponent("intent.json")
        let data: Data
        do {
            data = try Self.intentEncoder.encode(record)
        } catch {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("encoding")
        }
        guard data.count <= 1 << 20 else {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("record exceeds the bound")
        }
        let temporary = destination.appendingPathComponent(".intent-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard descriptor >= 0 else {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("temporary open")
        }
        var wroteAll = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    wroteAll = false
                    return
                }
                offset += written
            }
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            _ = close(descriptor)
            _ = unlink(temporary.path)
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("write/fsync")
        }
        _ = close(descriptor)
        guard rename(temporary.path, intentURL.path) == 0 else {
            _ = unlink(temporary.path)
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("rename")
        }
        guard Self.fsyncDirectory(destination) else {
            throw RuntimeV2MaintenanceError.intentPersistenceFailed("directory fsync")
        }
        requiredIntentDirectories.insert(destination)
    }

    private static func fsyncDirectory(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        let result = fsync(descriptor)
        _ = close(descriptor)
        return result == 0
    }

    private static let intentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let intentDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Process-wide coordinator registry

/// Bounded lookup from a `RuntimeV2Store` layout root to the ONE coordinator
/// registered for that exact trusted domain. A root with no registration is not
/// a maintenance domain (production `arm64-v1` and the resident ARM64 path stay
/// exactly as they are). Direct `RuntimeV2Store(layout:)` construction cannot
/// bypass the lookup: the store resolves the coordinator per operation.
public enum RuntimeV2MaintenanceRegistry {
    private final class Table: @unchecked Sendable {
        private let lock = NSLock()
        private var coordinators: [String: RuntimeV2MaintenanceCoordinator] = [:]

        func install(_ coordinator: RuntimeV2MaintenanceCoordinator, key: String) -> RuntimeV2MaintenanceCoordinator {
            lock.lock()
            defer { lock.unlock() }
            if let existing = coordinators[key] { return existing }
            coordinators[key] = coordinator
            return coordinator
        }

        func coordinator(for key: String) -> RuntimeV2MaintenanceCoordinator? {
            lock.lock()
            defer { lock.unlock() }
            return coordinators[key]
        }

        func remove(key: String) {
            lock.lock()
            defer { lock.unlock() }
            coordinators.removeValue(forKey: key)
        }
    }

    private static let table = Table()

    public static func canonicalKey(for root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Installs the coordinator for one domain. Installing the same domain
    /// twice returns the already-installed instance rather than silently
    /// replacing a live owner.
    @discardableResult
    public static func install(_ coordinator: RuntimeV2MaintenanceCoordinator) -> RuntimeV2MaintenanceCoordinator {
        let installed = table.install(coordinator, key: canonicalKey(for: coordinator.domain.root))
        RuntimeV2RecoveryAdmission.install(
            domain: installed.domain, stateDirectory: installed.stateDirectory,
            recoveryBlocked: installed.storageDirectories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("intent.json").path) },
            historyLayout: installed.historyLayout)
        return installed
    }

    public static func coordinator(forLayoutRoot root: URL) -> RuntimeV2MaintenanceCoordinator? {
        table.coordinator(for: canonicalKey(for: root))
    }

    public static func coordinator(forDomain domain: RuntimeV2MaintenanceDomain) -> RuntimeV2MaintenanceCoordinator? {
        table.coordinator(for: canonicalKey(for: domain.root))
    }

    /// Test/lifecycle teardown only. Production keeps one registration for the
    /// process lifetime; removing a domain with live claims would not be safe.
    public static func unregister(domainRoot: URL) {
        table.remove(key: canonicalKey(for: domainRoot))
    }
}
