// FloeCore — bounded, lossless sparse rewrite for one owner-identified raw disk.
//
// SCOPE AND SAFETY CONTRACT
//
// This helper rewrites ONE regular file that a service already owns and has
// bound by device/inode. It never accepts a model-authored path, never walks a
// directory tree, never chooses a disk from a filename, and never exposes a
// generic "compress this file" tool. The caller supplies a verified root URL,
// one relative path, the exact source identity it admitted, a service-owned
// journal directory and the identity/generation of a real lifecycle
// maintenance lease.
//
// The helper preserves every logical byte and the source length. A range is
// turned into a hole only after a read proved every byte in that range is
// zero. It never modifies the source data fork in place:
//
//   1. count/hash the source and measure nonzero blocks (bounded fixed buffers),
//   2. preflight same-volume free space for clone metadata,
//   3. build a sibling APFS clone and use public F_PUNCHHOLE; unsupported
//      clone/punch fails closed, with no copy fallback in this release,
//   4. preserve metadata, fsync and fully re-read/hash the stage, comparing the
//      SHA-512 of the complete logical byte stream,
//   5. durably journal swapIntent, perform ONE same-directory
//      renameatx_np(RENAME_SWAP), fsync the directory, re-open the original
//      path and verify the staged inode/length/digest/metadata again,
//   6. only after the commit record is durable, unlink the old source inode
//      (which is now at the exact job-owned stage name) and measure the actual
//      volume delta.
//
// Every phase is crash-recoverable from the journal's exact inode bindings.
// Recovery never guesses from a filename: it observes the source and stage
// names, compares their identities to the recorded source (S) and stage (T)
// inodes, and only removes a path whose identity is proven to be this job's
// redundant copy. Unknown combinations preserve both paths and report
// `needsInspection`.
//
// WHAT THIS HELPER DOES NOT DO
//
//   * It does not acquire a lifecycle lease. `StorageSparseDiskMaintenanceFence`
//     is only a synchronous assertion hook. flock(2) or a journal alone never
//     excludes a noncooperating runtime writer; the owner service must hold a
//     real exclusive maintenance lease and must make every runtime/restore/
//     discard/migration/delete/GC path consult the durable maintenance intent.
//   * It does not decide whether a disk is useful recovery data. Discarding,
//     restoring or deleting a preserved disk remains with the owner service.
//   * It does not move data off the device or use a host tool/interpreter.
//   * It does not claim a sum of per-file savings as freed volume. The report
//     exposes the measured `st_blocks * 512` figures and the actual observed
//     `fstatfs` free-space delta separately; volume delta includes unrelated
//     system activity and is never labelled as guaranteed reclaimed bytes.
//
// Compiled with the FloeCore target (Swift 6 language mode, iOS 26+/macOS 15+).
// Darwin is required for the no-follow/openat/fclonefileat/RENAME_SWAP/
// F_PUNCHHOLE primitives used here.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A precise, non-path error. Messages deliberately avoid embedding absolute
/// paths: the private journal holds the exact identities, while UI/diagnostic
/// surfaces receive a bounded code and a sanitized description.
public enum StorageSparseDiskRewriteError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedPlatform
    case unsupportedMode(String)
    case metadataUnavailable(field: String)
    case invalidRequest(String)
    case notRegularFile
    case symbolicLink
    case hardLinked(linkCount: UInt32)
    case emptySource
    case oversizedSource(bytes: Int64, limit: Int64)
    case immutableSource
    case compressedSource
    case sourceIdentityMismatch(phase: String)
    case sourceChanged(phase: String)
    case sourceOpenFailed(errno: Int32)
    case directoryOpenFailed(errno: Int32)
    case stageCreateFailed(errno: Int32)
    case stageExists
    case stageIdentityMismatch(phase: String)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case truncateFailed(errno: Int32)
    case fsyncFailed(errno: Int32)
    case metadataFailed(field: String, errno: Int32)
    case metadataVerificationFailed(field: String)
    case xattrLimitExceeded(String)
    case insufficientSpace(required: Int64, available: Int64, phase: String)
    case insufficientReclaim(measured: Int64, minimum: Int64)
    case cloneUnavailable(errno: Int32)
    case punchUnsupported(errno: Int32)
    case punchFailed(errno: Int32)
    case swapUnsupported(errno: Int32)
    case verificationFailed(phase: String)
    case journalCorrupt(String)
    case journalConflict(String)
    case journalExists(String)
    case journalOpenFailed(errno: Int32)
    case journalWriteFailed(errno: Int32)
    case crashInjected(String)
    case injectedFailure(String)
    case cancelledAfterSwap(jobID: String)
    case recoveryRequired(jobID: String, phase: String)
    case needsInspection(String)

    /// Stable, path-free code used by service diagnostics and tests.
    public var code: String {
        switch self {
        case .unsupportedPlatform: return "unsupported-platform"
        case .unsupportedMode: return "unsupported-mode"
        case .metadataUnavailable: return "metadata-unavailable"
        case .invalidRequest: return "invalid-request"
        case .notRegularFile: return "not-regular-file"
        case .symbolicLink: return "symbolic-link"
        case .hardLinked: return "hard-linked"
        case .emptySource: return "empty-source"
        case .oversizedSource: return "oversized-source"
        case .immutableSource: return "immutable-source"
        case .compressedSource: return "compressed-source"
        case .sourceIdentityMismatch: return "source-identity-mismatch"
        case .sourceChanged: return "source-changed"
        case .sourceOpenFailed: return "source-open-failed"
        case .directoryOpenFailed: return "directory-open-failed"
        case .stageCreateFailed: return "stage-create-failed"
        case .stageExists: return "stage-exists"
        case .stageIdentityMismatch: return "stage-identity-mismatch"
        case .readFailed: return "read-failed"
        case .writeFailed: return "write-failed"
        case .truncateFailed: return "truncate-failed"
        case .fsyncFailed: return "fsync-failed"
        case .metadataFailed: return "metadata-failed"
        case .metadataVerificationFailed: return "metadata-verification-failed"
        case .xattrLimitExceeded: return "xattr-limit-exceeded"
        case .insufficientSpace: return "insufficient-space"
        case .insufficientReclaim: return "insufficient-reclaim"
        case .cloneUnavailable: return "clone-unavailable"
        case .punchUnsupported: return "punch-unsupported"
        case .punchFailed: return "punch-failed"
        case .swapUnsupported: return "swap-unsupported"
        case .verificationFailed: return "verification-failed"
        case .journalCorrupt: return "journal-corrupt"
        case .journalConflict: return "journal-conflict"
        case .journalExists: return "journal-exists"
        case .journalOpenFailed: return "journal-open-failed"
        case .journalWriteFailed: return "journal-write-failed"
        case .crashInjected: return "crash-injected"
        case .injectedFailure: return "injected-failure"
        case .cancelledAfterSwap: return "cancelled-after-swap"
        case .recoveryRequired: return "recovery-required"
        case .needsInspection: return "needs-inspection"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "This platform does not provide the native disk rewrite primitives."
        case .unsupportedMode:
            return "This disk cannot be optimized with the required clone-only method."
        case .metadataUnavailable:
            return "Required disk metadata could not be verified; the original disk was kept."
        case .hardLinked:
            return "The disk has more than one hard link, so replacing one path would break alias consistency."
        case .symbolicLink:
            return "The selected path is a symbolic link; a real regular file is required."
        case .notRegularFile:
            return "The selected path is not a regular file."
        case .emptySource:
            return "The selected disk is empty."
        case .oversizedSource:
            return "The selected disk is larger than the supported 32 GiB bound."
        case .immutableSource:
            return "The selected disk is marked immutable or append-only."
        case .compressedSource:
            return "The selected disk is stored with a compressed file flag; it is not a plain runtime disk."
        case .insufficientSpace:
            return "The volume does not have enough free space for the bounded staging file."
        case .insufficientReclaim:
            return "The staged disk has no positive measured allocation gain or is below the required minimum; the original disk was kept."
        case .cloneUnavailable:
            return "This volume cannot create an APFS clone and clone-only mode was requested."
        case .punchUnsupported:
            return "This volume cannot punch holes and clone-only mode was requested."
        case .swapUnsupported:
            return "This volume cannot atomically swap the staged disk with the original path."
        case .verificationFailed:
            return "The staged copy did not match the complete logical byte stream of the source."
        case .journalCorrupt:
            return "The recovery journal is unreadable or not the supported version."
        case .journalConflict:
            return "The recovery journal does not match the requested disk."
        case .journalExists:
            return "A journal already exists for this job identifier."
        case .crashInjected:
            return "A test crash point stopped the operation before completion."
        case .cancelledAfterSwap:
            return "The operation was cancelled after the atomic swap; run recovery to converge."
        case .recoveryRequired:
            return "The operation reached a durable state that recovery must finish."
        case .needsInspection:
            return "The on-disk identities no longer match a safe automatic action; both paths were preserved."
        default:
            return "The bounded disk rewrite stopped without claiming success (code: \(code))."
        }
    }
}

/// The exact file instance a service admitted. `ctime` is recorded for the
/// pre-swap identity check; it is not compared after a rename because rename
/// itself updates ctime. `matchesStable` is the post-swap identity test.
public struct StorageSparseDiskIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var sizeBytes: Int64
    public var linkCount: UInt32
    public var mode: UInt32
    public var ownerUID: UInt32
    public var ownerGID: UInt32
    public var fileFlags: UInt32
    public var modificationSeconds: Int64
    public var modificationNanoseconds: Int64
    public var changeSeconds: Int64
    public var changeNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        sizeBytes: Int64,
        linkCount: UInt32,
        mode: UInt32,
        ownerUID: UInt32,
        ownerGID: UInt32,
        fileFlags: UInt32,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.linkCount = linkCount
        self.mode = mode
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
        self.fileFlags = fileFlags
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    /// Device/inode/link-count identity. Used only to prove that a job-owned
    /// stage path still names the exact inode this job created; mtime and size
    /// legitimately change while staging writes or punching. It must never be
    /// used to accept a source after an interruption.
    public func matchesInode(_ other: StorageSparseDiskIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && linkCount == other.linkCount
    }

    /// Identity fields that survive a same-directory rename. Used only after
    /// the atomic swap, where ctime legitimately changes.
    public func matchesStable(_ other: StorageSparseDiskIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && sizeBytes == other.sizeBytes
            && linkCount == other.linkCount
            && mode == other.mode
            && ownerUID == other.ownerUID
            && ownerGID == other.ownerGID
            && fileFlags == other.fileFlags
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
    }

    /// Full identity used while the original path has not been renamed.
    public func matchesFully(_ other: StorageSparseDiskIdentity) -> Bool {
        matchesStable(other)
            && changeSeconds == other.changeSeconds
            && changeNanoseconds == other.changeNanoseconds
    }
}

public enum StorageSparseDiskRewriteMode: String, Codable, Sendable, Equatable {
    /// Use clone + hole punching only. Unsupported primitives fail closed;
    /// this release never replaces a disk by copying its data into a new inode.
    case automatic
    /// Require clone + punch; fail closed if either primitive is unavailable.
    case cloneAndPunch
    /// Historical source compatibility only. Requests are rejected before
    /// journal/stage creation: copying cannot prove metadata/COW preservation.
    case sparseCopy
}

/// Caller-owned admission for one disk. The helper does not infer any of these
/// values and does not accept an identity captured by a different path.
public struct StorageSparseDiskRewriteRequest: Sendable {
    public var rootURL: URL
    public var relativePath: String
    public var expectedSource: StorageSparseDiskIdentity
    public var journalDirectoryURL: URL
    public var jobID: String
    public var maintenanceLeaseID: String
    public var holdGeneration: Int64
    public var jobGeneration: UInt64
    public var mode: StorageSparseDiskRewriteMode
    /// Fixed read buffer; clamped to 64 KiB...4 MiB and required to be a
    /// multiple of `zeroProbeBytes`.
    public var chunkBytes: Int
    /// Zero-detection granularity; clamped to 4 KiB...1 MiB.
    public var zeroProbeBytes: Int
    /// Same-volume free-space reserve for clone/punch metadata work.
    /// Defaults to 64 MiB. This is not a promised reclaim amount.
    public var safetyMarginBytes: Int64
    /// Optional stricter pre-swap gate on signed source-minus-stage allocation.
    /// Every request requires strictly positive gain, including nil or zero.
    public var minimumReclaimBytes: Int64?
    /// Historical compatibility flag. It cannot enable copying in this release;
    /// automatic and cloneAndPunch both require clone + punch even when true.
    public var allowSparseCopyFallback: Bool

    public init(
        rootURL: URL,
        relativePath: String,
        expectedSource: StorageSparseDiskIdentity,
        journalDirectoryURL: URL,
        jobID: String,
        maintenanceLeaseID: String,
        holdGeneration: Int64,
        jobGeneration: UInt64,
        mode: StorageSparseDiskRewriteMode = .automatic,
        chunkBytes: Int = 1_048_576,
        zeroProbeBytes: Int = 65_536,
        safetyMarginBytes: Int64 = 64 * 1_024 * 1_024,
        minimumReclaimBytes: Int64? = nil,
        allowSparseCopyFallback: Bool = false
    ) {
        self.rootURL = rootURL
        self.relativePath = relativePath
        self.expectedSource = expectedSource
        self.journalDirectoryURL = journalDirectoryURL
        self.jobID = jobID
        self.maintenanceLeaseID = maintenanceLeaseID
        self.holdGeneration = holdGeneration
        self.jobGeneration = jobGeneration
        self.mode = mode
        self.chunkBytes = chunkBytes
        self.zeroProbeBytes = zeroProbeBytes
        self.safetyMarginBytes = safetyMarginBytes
        self.minimumReclaimBytes = minimumReclaimBytes
        self.allowSparseCopyFallback = allowSparseCopyFallback
    }
}

/// A synchronous assertion hook supplied by the real lifecycle owner. It must
/// prove that the exact environment/disk maintenance lease and hold/job
/// generation are still exclusive. It is deliberately NOT a lock: a correct
/// implementation also prevents every noncooperating writer from starting.
public struct StorageSparseDiskMaintenanceFence: Sendable {
    public let leaseID: String
    public let generation: UInt64
    public let assertExclusive: @Sendable () throws -> Void

    public init(
        leaseID: String,
        generation: UInt64,
        assertExclusive: @escaping @Sendable () throws -> Void
    ) {
        self.leaseID = leaseID
        self.generation = generation
        self.assertExclusive = assertExclusive
    }
}

public struct StorageSparseDiskRewriteProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case counting
        case staging
        case verifying
        case committing
        case retiring
    }

    public var phase: Phase
    public var processedBytes: Int64
    public var totalBytes: Int64

    public init(phase: Phase, processedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}

public enum StorageSparseDiskProtectionVerification: String, Sendable, Equatable {
    case verified
    case notVerified
}

public struct StorageSparseDiskInspection: Sendable, Equatable {
    public var identity: StorageSparseDiskIdentity
    public var allocatedBytes: Int64
    public var volumeAvailableBytes: Int64
    public var protectionClass: Int32?
    public var protectionClassVerification: StorageSparseDiskProtectionVerification {
        protectionClass == nil ? .notVerified : .verified
    }
    public var supportsFileCloning: Bool
    public var supportsSparseFiles: Bool
    public var supportsZeroRuns: Bool

    public init(
        identity: StorageSparseDiskIdentity,
        allocatedBytes: Int64,
        volumeAvailableBytes: Int64,
        protectionClass: Int32?,
        supportsFileCloning: Bool,
        supportsSparseFiles: Bool,
        supportsZeroRuns: Bool
    ) {
        self.identity = identity
        self.allocatedBytes = allocatedBytes
        self.volumeAvailableBytes = volumeAvailableBytes
        self.protectionClass = protectionClass
        self.supportsFileCloning = supportsFileCloning
        self.supportsSparseFiles = supportsSparseFiles
        self.supportsZeroRuns = supportsZeroRuns
    }
}

/// Measured results of one completed rewrite. Allocation figures are
/// `st_blocks * 512` for the exact inode. `volumeAvailableDeltaBytes` is the
/// separately observed `fstatfs` difference (`after - before`); positive means
/// more free space was observed, but unrelated system activity is included and
/// this is never presented as a sum of guaranteed reclaimed bytes.
public struct StorageSparseDiskRewriteReport: Sendable, Equatable {
    public var jobID: String
    public var relativePath: String
    public var modeUsed: StorageSparseDiskRewriteMode
    public var fallbackReason: String?
    public var logicalBytes: Int64
    public var sourceAllocatedBytesBefore: Int64
    public var stageAllocatedBytesAtVerification: Int64
    public var retiredSourceAllocatedBytesBeforeUnlink: Int64?
    public var volumeAvailableBytesBefore: Int64
    public var volumeAvailableBytesAtCommit: Int64
    public var volumeAvailableBytesAfter: Int64
    public var volumeAvailableDeltaBytes: Int64
    public var sourceDigestSHA512: String
    public var stageDigestSHA512: String
    public var nonzeroBytes: Int64
    public var zeroBytes: Int64
    public var punchedBytes: Int64
    public var skippedXattrNames: [String]
    public var protectionClassPreserved: Bool
    public var protectionClassVerification: StorageSparseDiskProtectionVerification {
        protectionClassPreserved ? .verified : .notVerified
    }
    public var stageRetired: Bool
    public var journalPhase: String

    public init(
        jobID: String,
        relativePath: String,
        modeUsed: StorageSparseDiskRewriteMode,
        fallbackReason: String?,
        logicalBytes: Int64,
        sourceAllocatedBytesBefore: Int64,
        stageAllocatedBytesAtVerification: Int64,
        retiredSourceAllocatedBytesBeforeUnlink: Int64?,
        volumeAvailableBytesBefore: Int64,
        volumeAvailableBytesAtCommit: Int64,
        volumeAvailableBytesAfter: Int64,
        volumeAvailableDeltaBytes: Int64,
        sourceDigestSHA512: String,
        stageDigestSHA512: String,
        nonzeroBytes: Int64,
        zeroBytes: Int64,
        punchedBytes: Int64,
        skippedXattrNames: [String],
        protectionClassPreserved: Bool,
        stageRetired: Bool,
        journalPhase: String
    ) {
        self.jobID = jobID
        self.relativePath = relativePath
        self.modeUsed = modeUsed
        self.fallbackReason = fallbackReason
        self.logicalBytes = logicalBytes
        self.sourceAllocatedBytesBefore = sourceAllocatedBytesBefore
        self.stageAllocatedBytesAtVerification = stageAllocatedBytesAtVerification
        self.retiredSourceAllocatedBytesBeforeUnlink = retiredSourceAllocatedBytesBeforeUnlink
        self.volumeAvailableBytesBefore = volumeAvailableBytesBefore
        self.volumeAvailableBytesAtCommit = volumeAvailableBytesAtCommit
        self.volumeAvailableBytesAfter = volumeAvailableBytesAfter
        self.volumeAvailableDeltaBytes = volumeAvailableDeltaBytes
        self.sourceDigestSHA512 = sourceDigestSHA512
        self.stageDigestSHA512 = stageDigestSHA512
        self.nonzeroBytes = nonzeroBytes
        self.zeroBytes = zeroBytes
        self.punchedBytes = punchedBytes
        self.skippedXattrNames = skippedXattrNames
        self.protectionClassPreserved = protectionClassPreserved
        self.stageRetired = stageRetired
        self.journalPhase = journalPhase
    }
}

public struct StorageSparseDiskRecoveryReport: Sendable, Equatable {
    public enum Resolution: String, Sendable, Equatable {
        case noJournal
        case abortedBeforeSwap
        case rolledBack
        case committed
        case alreadyCommitted
        case needsInspection
    }

    public var jobID: String
    public var resolution: Resolution
    public var phase: String
    public var stageRemoved: Bool
    public var sourceIdentityVerified: Bool
    public var detail: String

    public init(
        jobID: String,
        resolution: Resolution,
        phase: String,
        stageRemoved: Bool,
        sourceIdentityVerified: Bool,
        detail: String
    ) {
        self.jobID = jobID
        self.resolution = resolution
        self.phase = phase
        self.stageRemoved = stageRemoved
        self.sourceIdentityVerified = sourceIdentityVerified
        self.detail = detail
    }
}

/// Explicit native caller proof for a root renamed since a schema2 journal.
/// It never replaces parent/source/stage identities or the maintenance fence.
public struct StorageSparseDiskRecoveryRootBinding: Sendable, Equatable {
    public let recordedRootPath: String
    public let device: UInt64
    public let inode: UInt64
    public init(recordedRootPath: String, device: UInt64, inode: UInt64) {
        self.recordedRootPath = recordedRootPath; self.device = device; self.inode = inode
    }
}

/// Narrow public entry point. Root/service integration must create the
/// maintenance lease and durable intent before calling `rewrite`, and must
/// call `recover` from the same service-owned lifecycle before any other
/// restore/discard/delete/GC action can touch the disk.
public enum StorageSparseDiskRewrite {
    /// Hard upper bound for one logical file (32 GiB).
    public static let maximumSourceBytes: Int64 = 32 * 1_024 * 1_024 * 1_024

    /// Read-only admission. Opens the exact relative path with O_NOFOLLOW,
    /// rejects hard links/immutable/compressed shapes, and returns the identity
    /// the caller must bind into its lease and journal.
    public static func inspectSource(
        rootURL: URL,
        relativePath: String
    ) throws -> StorageSparseDiskInspection {
        #if canImport(Darwin)
        let rootFD = try StorageSparseDiskPOSIX.openDirectory(rootURL)
        defer { close(rootFD) }
        let resolved = try StorageSparseDiskPOSIX.openParent(rootFD: rootFD, relativePath: relativePath)
        defer {
            if resolved.ownsDirectory { close(resolved.directoryFD) }
        }
        let sourceFD = try StorageSparseDiskPOSIX.openRegular(
            parentFD: resolved.directoryFD,
            leaf: resolved.leaf,
            flags: O_RDONLY,
            purpose: .source
        )
        defer { close(sourceFD) }
        let identity = try StorageSparseDiskPOSIX.identity(of: sourceFD)
        try StorageSparseDiskPOSIX.validateSourceShape(identity)
        let allocated = try StorageSparseDiskPOSIX.allocatedBytes(of: sourceFD)
        let volume = try StorageSparseDiskPOSIX.volumeSpace(directoryFD: resolved.directoryFD)
        let protection = try StorageSparseDiskPOSIX.readProtectionClass(fd: sourceFD)
        let capabilities = StorageSparseDiskPOSIX.volumeCapabilities(
            rootURL: rootURL,
            relativePath: relativePath
        )
        return StorageSparseDiskInspection(
            identity: identity,
            allocatedBytes: allocated,
            volumeAvailableBytes: volume.availableBytes,
            protectionClass: protection,
            supportsFileCloning: capabilities.cloning,
            supportsSparseFiles: capabilities.sparse,
            supportsZeroRuns: capabilities.zeroRuns
        )
        #else
        _ = rootURL
        _ = relativePath
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }

    /// Execute one bounded rewrite. Throws without a success claim on any
    /// failure; the journal and the report are the only evidence of what
    /// happened. The source is never removed before a durable commit record.
    public static func rewrite(
        _ request: StorageSparseDiskRewriteRequest,
        fence: StorageSparseDiskMaintenanceFence,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil
    ) throws -> StorageSparseDiskRewriteReport {
        #if canImport(Darwin)
        return try _rewrite(
            request,
            fence: fence,
            hooks: StorageSparseDiskRewrite.TestHooks(),
            isCancelled: isCancelled,
            progress: progress
        )
        #else
        _ = request
        _ = fence
        _ = isCancelled
        _ = progress
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }

    /// Converge one journaled job. Only exact inode bindings trigger cleanup.
    /// Unknown/document mismatches are preserved and reported.
    public static func recover(
        rootURL: URL,
        relativePath: String,
        journalDirectoryURL: URL,
        jobID: String,
        fence: StorageSparseDiskMaintenanceFence,
        recordedRootBinding: StorageSparseDiskRecoveryRootBinding? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> StorageSparseDiskRecoveryReport {
        #if canImport(Darwin)
        return try StorageSparseDiskRewriteRecovery.recover(
            rootURL: rootURL,
            relativePath: relativePath,
            journalDirectoryURL: journalDirectoryURL,
            jobID: jobID,
            fence: fence,
            recordedRootBinding: recordedRootBinding,
            isCancelled: isCancelled
        )
        #else
        _ = rootURL
        _ = relativePath
        _ = journalDirectoryURL
        _ = jobID
        _ = fence
        _ = recordedRootBinding
        _ = isCancelled
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }

    // MARK: - Internal test seams

    /// Internal crash points. Every point is called only after the journal for
    /// that phase has been written and fsynced (or, for `.afterSwap`, after the
    /// swap while the durable journal still says `swapIntent`).
    enum CrashPoint: String, Sendable, Equatable {
        case afterIntent
        case afterCounting
        case afterStageCreated
        case afterStaging
        case afterVerified
        case afterSwapIntent
        case afterSwap
        case afterSwappedJournal
        case afterCommitJournal
        case beforeRetire
        case afterRetire

        static let all: [CrashPoint] = [
            .afterIntent,
            .afterCounting,
            .afterStageCreated,
            .afterStaging,
            .afterVerified,
            .afterSwapIntent,
            .afterSwap,
            .afterSwappedJournal,
            .afterCommitJournal,
            .beforeRetire,
            .afterRetire
        ]
    }

    /// Deterministic seams used only by the focused synthetic tests. They can
    /// force clone/punch/swap unavailability, inject a write failure, fake the
    /// same-volume free-space answer, mutate the source after counting, or
    /// stop at a durable phase. Production calls the empty initializer.
    struct TestHooks: Sendable {
        var crashAt: (@Sendable (CrashPoint) throws -> Void)?
        var afterCounting: (@Sendable () -> Void)?
        var beforeWrite: (@Sendable (Int64, Int) throws -> Void)?
        var beforePunch: (@Sendable (Int64, Int64) throws -> Void)?
        var availableBytesOverride: (@Sendable (Int32) -> Int64?)?
        var forceCloneFailure: Bool = false
        var forcePunchUnsupported: Bool = false
        var forceSwapUnsupported: Bool = false
        /// Failure-only metadata seam; cannot bypass production validation.
        var metadataReadFault: (@Sendable (String) throws -> Void)?
    }

    static func _rewrite(
        _ request: StorageSparseDiskRewriteRequest,
        fence: StorageSparseDiskMaintenanceFence,
        hooks: TestHooks,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil
    ) throws -> StorageSparseDiskRewriteReport {
        #if canImport(Darwin)
        return try StorageSparseDiskRewriteEngine.perform(
            request,
            fence: fence,
            hooks: hooks,
            isCancelled: isCancelled,
            progress: progress
        )
        #else
        _ = request
        _ = fence
        _ = hooks
        _ = isCancelled
        _ = progress
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }
}
