import Foundation
import FloeCore

/// Caller-owned reference evidence. Absence, incompleteness or expiry is unknown,
/// never proof that an environment is unused. This is not a maintenance lock.
public struct LegacyRecoveryReferenceSnapshot: Sendable {
    public let capturedAt: Date
    public let isComplete: Bool
    public let referencedEnvironmentIDs: Set<String>
    public let activeEnvironmentIDs: Set<String>

    public init(capturedAt: Date, isComplete: Bool,
                referencedEnvironmentIDs: Set<String>, activeEnvironmentIDs: Set<String>) {
        self.capturedAt = capturedAt
        self.isComplete = isComplete
        self.referencedEnvironmentIDs = Set(referencedEnvironmentIDs.map { $0.lowercased() })
        self.activeEnvironmentIDs = Set(activeEnvironmentIDs.map { $0.lowercased() })
    }
}

public struct LegacyRecoveryInventoryLimits: Sendable {
    public let maximumDirectoryEntries: Int
    public let maximumRecords: Int
    public let maximumSidecarReads: Int
    public let maximumSidecarBytes: Int
    public let maximumTotalSidecarBytes: Int
    public let maximumDuration: TimeInterval
    public let maximumReferenceAge: TimeInterval

    public init(maximumDirectoryEntries: Int = 256, maximumRecords: Int = 64,
                maximumSidecarReads: Int = 384, maximumSidecarBytes: Int = 16_384,
                maximumTotalSidecarBytes: Int = 512 * 1024,
                maximumDuration: TimeInterval = 5, maximumReferenceAge: TimeInterval = 30) {
        self.maximumDirectoryEntries = max(1, min(maximumDirectoryEntries, 4096))
        self.maximumRecords = max(1, min(maximumRecords, 256))
        self.maximumSidecarReads = max(1, min(maximumSidecarReads, 2048))
        self.maximumSidecarBytes = max(64, min(maximumSidecarBytes, 65_536))
        self.maximumTotalSidecarBytes = max(64, min(maximumTotalSidecarBytes, 2 * 1024 * 1024))
        self.maximumDuration = maximumDuration.isFinite ? max(0.001, min(maximumDuration, 30)) : 5
        self.maximumReferenceAge = maximumReferenceAge.isFinite
            ? max(0.001, min(maximumReferenceAge, 60)) : 30
    }
}

public struct LegacyRecoveryInventoryRequest: Sendable {
    /// Trusted App-resolved legacy root. Never supplied by a model or sidecar.
    /// It must already exist; fixed OS ancestors may be POSIX aliases. Only
    /// this authorized anchor is canonicalized, never its controlled children.
    public let legacyRoot: URL
    public let currentReferences: LegacyRecoveryReferenceSnapshot?
    public let limits: LegacyRecoveryInventoryLimits
    public init(legacyRoot: URL, currentReferences: LegacyRecoveryReferenceSnapshot?,
                limits: LegacyRecoveryInventoryLimits = .init()) {
        self.legacyRoot = legacyRoot
        self.currentReferences = currentReferences
        self.limits = limits
    }
}

public struct LegacyRecoveryTimestamp: Codable, Equatable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int64
}

/// Exact observed inode metadata. This may be compared again INSIDE a real
/// owner barrier; it never guarantees that an inode stayed idle after the scan.
public struct LegacyRecoveryFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let logicalBytes: Int64
    public let allocatedBytes: Int64?
    public let linkCount: UInt64
    public let mode: UInt32
    public let modification: LegacyRecoveryTimestamp
    public let change: LegacyRecoveryTimestamp
}

public enum LegacyRecoveryObservationState: String, Codable, Sendable {
    case present, missing, notRequested, symlinkOrUnsafePath, notRegularFile, tooLarge
    case unreadable, changedDuringRead, malformed, budgetExceeded
}

public struct LegacyRecoverySidecarObservation: Codable, Sendable {
    public var state: LegacyRecoveryObservationState
    public var identity: LegacyRecoveryFileIdentity?
    /// Digest only of a bounded metadata sidecar, never of disk.img.
    public var sha256: String?
}

public enum LegacyRecoveryReferenceState: String, Codable, Sendable {
    case unknown, active, referenced, unreferenced
}
public enum LegacyRecoveryBaseComparison: String, Codable, Sendable {
    case matches, differs, unknown
}
public enum LegacyRecoveryHoldPathState: String, Codable, Sendable {
    case noReadableMarker, exactPhysicalLocation, differentLocationHasDisk
    case differentLocationMissingDisk, differentLocationUnmeasured, unsafe
}
public enum LegacyRecoveryAttributePresence: String, Codable, Sendable {
    case present, absent, unknown
}

public enum LegacyRecoveryPlanningBlocker: String, Codable, Sendable, Hashable {
    case unsupportedDirectory, diskUnavailable, diskChanged, linkedDisk
    case runtimeMetadataUnavailable, runtimeIdentityMismatch
    case environmentMetadataUnavailable, environmentIdentityMismatch
    case unreadableRepairMarker, repairIdentityMismatch, unsafeRepairPath
    case generationUnmeasured, currentReferencesUnknown, currentReferenceExists
    case currentReferenceActive, inventoryIncomplete
}

public struct LegacyRecoveryReviewSnapshot: Codable, Sendable {
    public let rootIdentity: LegacyRecoveryFileIdentity
    public let directoryIdentity: LegacyRecoveryFileIdentity?
    public let diskIdentity: LegacyRecoveryFileIdentity?
    public let runtimeMetadata: LegacyRecoverySidecarObservation
    public let environmentMetadata: LegacyRecoverySidecarObservation
    public let repairMarker: LegacyRecoverySidecarObservation
    public let repairGeneration: LegacyRecoverySidecarObservation
    /// nil + .missing is observed absence; nil + another state is unknown.
    public let observedRepairGeneration: Int64?
    public let observedHoldID: String?
    public let capturedAt: Date
    public let referenceCapturedAt: Date?
}

/// INTERNAL diagnostics. Do not display/export paths, IDs or source digests in
/// ordinary UI. Use Report.summary for ordinary storage screens and feedback.
public struct LegacyRecoveryInventoryRecord: Codable, Sendable {
    public let relativeDirectory: String
    public let environmentID: String?
    public let runtimeID: String?
    public let recordedBaseImageID: String?
    public let recordedTemplateID: String?
    public let recordedTemplateVersion: Int?
    public let recordedTemplateDigest: String?
    public let recordedBootBaseDigest: String?
    public let environmentBaseDigest: String?
    public let baseComparison: LegacyRecoveryBaseComparison
    public let diskState: LegacyRecoveryObservationState
    public let privateBytes: Int64?
    public let cloneID: UInt64?
    public let cloneReferenceCount: UInt32?
    public let cloneExtendedFlags: UInt64?
    /// Presence of the backup-exclude xattr on this FD, not resolved inherited
    /// backup eligibility. Absent must not be relabelled "included in backup".
    public let backupExcludeAttribute: LegacyRecoveryAttributePresence
    public let runtimeIdentityMatchesDirectory: Bool
    public let environmentIdentityMatches: Bool
    public let repairIdentityMatches: Bool?
    /// Only a validated supported relative shape is retained. Unsafe raw path
    /// text stays in the original sidecar and is not exported here.
    public let recordedPreservedDirectory: String?
    public let holdPathState: LegacyRecoveryHoldPathState
    /// Physical file + bounded runtime identity recognized, not full disk
    /// readability or ability to restore against today's base.
    public let hasRecognizedPhysicalEvidence: Bool
    /// This bounded reader never resolves removal ownership. Supported entries
    /// remain protected even if metadata is missing/unsafe or acknowledgement
    /// history has not been inspected. Positive physical proof is separate.
    public let mustPreserveRepairEvidence: Bool
    public let repairAcknowledgementsInspected: Bool
    public var currentReferenceState: LegacyRecoveryReferenceState
    public var planningBlockers: [LegacyRecoveryPlanningBlocker]
    public let reviewSnapshot: LegacyRecoveryReviewSnapshot
    public var isReviewableForBytePreservingMaintenance: Bool { planningBlockers.isEmpty }
    /// A distinct type is deliberately not a mutation permit. Any writer must
    /// acquire its real maintenance barrier and revalidate every identity.
    public var authorizesMutation: Bool { false }
    public var permitsRecaptureAgainstCurrentBase: Bool { false }
}

/// No paths, IDs, reasons, credentials, document content or physical offsets.
public struct LegacyRecoveryInventorySummary: Codable, Sendable {
    public var recordCount = 0
    public var recognizedPhysicalEvidenceCount = 0
    public var logicalBytes: Int64 = 0
    /// Raw per-inode allocation before APFS sharing reconciliation. Non-additive
    /// estimate only; this is not reclaimable capacity or a footprint union.
    public var allocatedBytesBeforeSharingReconciliation: Int64 = 0
    public var privateBytesObserved: Int64 = 0
    public var allocationUnknownCount = 0
    public var privateUnknownCount = 0
    public var linkedDiskCount = 0
    public var currentReferenceUnknownCount = 0
    public var currentReferenceActiveCount = 0
    public var differentHoldLocationCount = 0
    public var baseDriftCount = 0
    public var reviewableCount = 0
    public var arithmeticOverflow = false
    public var isPartial = false
}

/// Internal diagnostic tokens only; no absolute path or user file name. This
/// preserves the FIRST failing root operation instead of collapsing all errno
/// sources into an empty record list. Ordinary UI still uses summary only.
public struct LegacyRecoveryRootDiagnostic: Codable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case inputValidation, posixCanonicalization, filesystemRootOpen
        case componentOpen, rootIdentity
    }
    public let stage: Stage
    public let posixErrno: Int32
    public let componentIndex: Int?
}

public struct LegacyRecoveryInventoryReport: Codable, Sendable {
    public let capturedAt: Date
    public let rootIdentity: LegacyRecoveryFileIdentity?
    public let rootDiagnostic: LegacyRecoveryRootDiagnostic?
    public let directoryEntriesVisited: Int
    public let sidecarReadsAttempted: Int
    public let sidecarBytesRead: Int
    public let diskContentBytesRead: Int
    public let stopReasons: [String]
    public let records: [LegacyRecoveryInventoryRecord]
    public let summary: LegacyRecoveryInventorySummary
}
