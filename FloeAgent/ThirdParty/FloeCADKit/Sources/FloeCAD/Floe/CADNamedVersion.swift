//
//  CADNamedVersion.swift
//  FloeCADKit
//
//  User-named design versions (E34). A named version is an explicit,
//  whole-document checkpoint stored inside the existing `.floecad` package.
//  It is NOT the in-memory undo stack, NOT the single `previous/` recovery
//  copy written by each commit, and NOT an automatic copy of every edit.
//
//  The stable record and result types live here so the workbench UI, the
//  bridge and `cad.document` all describe the same operation with the same
//  vocabulary. Storage and diff logic stay in `CADNamedVersionStore` and
//  `CADNamedVersionComparison`; they reuse the document package, manifest,
//  content/model digests and revision CAS rather than introducing a second
//  document or version service.
//

import Foundation

public nonisolated enum CADNamedVersionError: Error, LocalizedError, Equatable, Sendable {
    case invalidName(String)
    case duplicateName(String)
    case limitReached(Int)
    case notFound(UUID)
    case corrupt(UUID, String)
    case incompatible(UUID, String)
    case revisionMismatch(expected: Int, actual: Int)
    case contentMismatch(expected: String, actual: String)
    case documentBusy(String)
    case readOnly
    case closed
    case saveFailed(String)
    case restoreRefused(String)
    case invalidAction(String)
    case ioFailure(String)
    /// The checkpoint was verified and the package format floor was committed,
    /// but making the checkpoint visible failed. The associated identity is the
    /// committed package identity (the caller must adopt it) and the pending
    /// checkpoint bytes are retained under `versions/.pending-<id>` for
    /// explicit recovery. No success is ever reported without a visible
    /// checkpoint.
    case promotionFailed(id: UUID,
                         revision: Int,
                         contentSHA256: String,
                         modelSHA256: String,
                         underlying: String)
    /// A retained post-format-floor checkpoint cannot be recovered right now
    /// (missing/damaged recovery record, or the document format floor was not
    /// committed). The hidden bytes are left untouched; the visible document
    /// and every visible version are unchanged.
    case recoveryUnavailable(String)
    /// A visible checkpoint already occupies the retained checkpoint's
    /// identity. Recovery refuses rather than overwriting it.
    case recoveryCollision(UUID)
    /// A comparison page/detail was requested with identity pins that no longer
    /// match the stored version or the current committed document. The caller
    /// must start the comparison again instead of mixing revisions.
    case comparisonStale

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return FloeCADStrings.format("cad.versions.error.invalidName",
                                         "That version name can't be used: %@", reason)
        case .duplicateName(let name):
            return FloeCADStrings.format("cad.versions.error.duplicateName",
                                         "A version named “%@” already exists.", name)
        case .limitReached(let limit):
            return FloeCADStrings.format("cad.versions.error.limit",
                                         "This document already has the maximum of %d named versions. Delete one first.",
                                         limit)
        case .notFound:
            return FloeCADStrings.text("cad.versions.error.notFound",
                                       "That version is no longer in this document.")
        case .corrupt(_, let detail):
            return FloeCADStrings.format("cad.versions.error.corrupt",
                                         "This version checkpoint is damaged (%@). The current document was not changed.",
                                         detail)
        case .incompatible(_, let detail):
            return FloeCADStrings.format("cad.versions.error.incompatible",
                                         "This version uses data this app can't restore (%@). The current document was not changed.",
                                         detail)
        case .revisionMismatch(let expected, let actual):
            return FloeCADStrings.format("cad.versions.error.revisionMismatch",
                                         "The document changed (revision %d, expected %d). Nothing was restored.",
                                         actual, expected)
        case .contentMismatch:
            return FloeCADStrings.text("cad.versions.error.contentMismatch",
                                       "The document content changed. Nothing was restored.")
        case .documentBusy(let detail):
            return FloeCADStrings.format("cad.versions.error.busy",
                                         "%@ Finish it first, then try again.", detail)
        case .readOnly:
            return FloeCADStrings.text("cad.versions.error.readOnly",
                                       "This CAD document is read-only, so versions can be viewed but not changed.")
        case .closed:
            return FloeCADStrings.text("cad.versions.error.closed",
                                       "This CAD document is closed.")
        case .saveFailed(let detail):
            return FloeCADStrings.format("cad.versions.error.saveFailed",
                                         "The restore could not be committed: %@ The current document was kept.",
                                         detail)
        case .restoreRefused(let detail):
            return detail
        case .invalidAction(let detail):
            return detail
        case .ioFailure(let detail):
            return FloeCADStrings.format("cad.versions.error.io",
                                         "The version store could not be read or written: %@", detail)
        case .promotionFailed(_, _, _, _, let detail):
            return FloeCADStrings.format("cad.versions.error.promotionRetained",
                                         "The version was not published (%@). The document format was updated safely and the checkpoint was kept for recovery.",
                                         detail)
        case .recoveryUnavailable(let detail):
            return FloeCADStrings.format("cad.versions.error.recoveryUnavailable",
                                         "This recovery checkpoint can't be used (%@). The document and other versions were not changed.",
                                         detail)
        case .recoveryCollision:
            return FloeCADStrings.text("cad.versions.error.recoveryCollision",
                                       "A version with this identity already exists. Nothing was overwritten.")
        case .comparisonStale:
            return FloeCADStrings.text("cad.versions.error.compareStale",
                                       "The document or version changed since the first page. Start the comparison again; no mixed revision was returned.")
        }
    }
}

/// One user-named (or safety recovery) checkpoint as shown in the workbench.
/// `isUsable == false` means the checkpoint directory is present but its
/// record/package failed verification; compare/restore then return an
/// actionable `corrupt`/`incompatible` error and never touch the current
/// document.
public nonisolated struct CADNamedVersionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var sourceRevision: Int
    public var contentSHA256: String
    public var modelSHA256: String?
    public var schemaVersion: Int
    public var appBuild: String
    public var counts: [String: Int]
    public var byteCount: Int?
    public var isRecovery: Bool
    public var isUsable: Bool
    public var issue: String?
    /// Set on a checkpoint that was explicitly created as the restored branch
    /// of a named version. Nil for ordinary versions/recovery rows.
    public var parentVersionID: UUID?
    public var restoredFromVersionID: UUID?

    public init(id: UUID, name: String, createdAt: Date, sourceRevision: Int,
                contentSHA256: String, modelSHA256: String?, schemaVersion: Int,
                appBuild: String, counts: [String: Int], byteCount: Int?,
                isRecovery: Bool = false, isUsable: Bool = true, issue: String? = nil,
                parentVersionID: UUID? = nil, restoredFromVersionID: UUID? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sourceRevision = sourceRevision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.schemaVersion = schemaVersion
        self.appBuild = appBuild
        self.counts = counts
        self.byteCount = byteCount
        self.isRecovery = isRecovery
        self.isUsable = isUsable
        self.issue = issue
        self.parentVersionID = parentVersionID
        self.restoredFromVersionID = restoredFromVersionID
    }
}

public nonisolated struct CADNamedVersionCreateResult: Codable, Sendable, Equatable {
    public var version: CADNamedVersionSummary
    /// True when the current unsaved edits had to be committed first so the
    /// checkpoint is a stable whole-document state.
    public var savedCurrentDocument: Bool
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String

    public init(version: CADNamedVersionSummary, savedCurrentDocument: Bool,
                revision: Int, contentSHA256: String, modelSHA256: String) {
        self.version = version
        self.savedCurrentDocument = savedCurrentDocument
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
    }
}

public nonisolated struct CADNamedVersionDeleteResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// The checkpoint directory was removed. The current document package and
    /// every other version are untouched.
    public var deleted: Bool
    /// A failure to free the moved-aside directory after the version already
    /// left the visible list. Nil means complete cleanup.
    public var cleanupIssue: String?

    public init(id: UUID, name: String, deleted: Bool, cleanupIssue: String? = nil) {
        self.id = id
        self.name = name
        self.deleted = deleted
        self.cleanupIssue = cleanupIssue
    }
}

// MARK: - Retained post-format-floor recovery

/// Marker stored inside `versions/.pending-<id>/recovery.json` for a checkpoint
/// whose create entered the package format-floor commit. The marker exists
/// BEFORE that commit so a crash during or after the commit cannot lose the
/// fact that a complete checkpoint was staged; it deliberately does not claim
/// the commit happened. The package manifest is the authority: recovery is only
/// offered once the visible package is at the named-version floor, and every
/// retry re-verifies the hidden checkpoint through the same loader as a normal
/// checkpoint. A running create holds the package gate, so its live staging
/// cannot be listed, promoted or deleted by another in-process caller.
nonisolated struct CADNamedVersionRecoveryMarker: Codable, Sendable, Equatable {
    static let currentMarkerVersion = 1
    static let fileName = "recovery.json"
    static let maximumBytes = 64 * 1024

    enum State: String, Codable, Sendable {
        case postFormatFloorRecovery
    }

    var markerVersion: Int
    var id: UUID
    var state: State
    var name: String
    var createdAt: Date
    var isRecovery: Bool
    /// The package format floor this checkpoint needs before it can become a
    /// visible version. Informational; recovery always re-reads the current
    /// manifest instead of trusting the marker.
    var requiredFormatVersion: Int
}

/// One retained checkpoint that is NOT a visible version yet. `isUsable` is
/// true only when the hidden record and package verify exactly. The bytes are
/// never presented as a created version and never replace/overwrite a visible
/// one; the caller must explicitly recover (promote) or delete them.
public nonisolated struct CADNamedVersionRecoverySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var sourceRevision: Int
    public var contentSHA256: String
    public var modelSHA256: String?
    public var schemaVersion: Int
    public var counts: [String: Int]
    public var byteCount: Int?
    public var isRecovery: Bool
    public var isUsable: Bool
    public var issue: String?
    /// True only for verified bytes retained after the package format-floor
    /// commit. This is never a claim of a visible, completed version.
    public var retainedAfterFormatFloor: Bool
    public var requiredFormatVersion: Int

    public init(id: UUID, name: String, createdAt: Date, sourceRevision: Int,
                contentSHA256: String, modelSHA256: String?, schemaVersion: Int,
                counts: [String: Int], byteCount: Int?, isRecovery: Bool,
                isUsable: Bool, issue: String?,
                retainedAfterFormatFloor: Bool = true,
                requiredFormatVersion: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sourceRevision = sourceRevision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.schemaVersion = schemaVersion
        self.counts = counts
        self.byteCount = byteCount
        self.isRecovery = isRecovery
        self.isUsable = isUsable
        self.issue = issue
        self.retainedAfterFormatFloor = retainedAfterFormatFloor
        self.requiredFormatVersion = requiredFormatVersion
    }
}

public nonisolated struct CADNamedVersionRecoveryResult: Codable, Sendable, Equatable {
    /// The now-visible checkpoint. It is returned only after the retained
    /// directory was renamed and re-opened through the normal verifier.
    public var version: CADNamedVersionSummary
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String

    public init(version: CADNamedVersionSummary, revision: Int,
                contentSHA256: String, modelSHA256: String) {
        self.version = version
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
    }
}

public nonisolated struct CADNamedVersionReference: Codable, Sendable, Equatable {
    /// "version" or "current".
    public var kind: String
    public var versionID: UUID?
    public var name: String
    public var revision: Int
    public var contentSHA256: String
    /// Canonical semantic identity computed from the actual manifest metadata
    /// + document records + blobs (preview excluded), even when the historical
    /// manifest did not declare `modelSHA256`.
    public var modelSHA256: String
    public var schemaVersion: Int
    public var isRecovery: Bool

    public init(kind: String, versionID: UUID?, name: String, revision: Int,
                contentSHA256: String, modelSHA256: String, schemaVersion: Int,
                isRecovery: Bool = false) {
        self.kind = kind
        self.versionID = versionID
        self.name = name
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.schemaVersion = schemaVersion
        self.isRecovery = isRecovery
    }
}

public nonisolated struct CADNamedVersionDifference: Codable, Sendable, Equatable {
    /// metadata | geometry | sketches | planes | axes | images | symbols |
    /// features | parameters | variables | materials | assembly | drawings |
    /// presentation | animation | scripts | preview
    public var section: String
    /// added | removed | modified
    public var change: String
    public var identifier: String
    public var name: String
    /// Actual stored values/keys that differ (never an imagined visual diff).
    public var detail: String

    public init(section: String, change: String, identifier: String,
                name: String, detail: String) {
        self.section = section
        self.change = change
        self.identifier = identifier
        self.name = name
        self.detail = detail
    }
}

public nonisolated struct CADNamedVersionComparison: Codable, Sendable, Equatable {
    public var from: CADNamedVersionReference
    public var to: CADNamedVersionReference
    /// Canonical whole-model identity comparison (preview excluded).
    public var identical: Bool
    /// Byte-level content identity comparison (preview included).
    public var contentIdentical: Bool
    public var revisionChanged: Bool
    public var changedSections: [String]
    public var differences: [CADNamedVersionDifference]
    /// True when this page omitted later differences. `totalDifferences` and
    /// `nextOffset` describe the exact continuation; the caller can fetch every
    /// remaining difference through the same `compare` action.
    public var truncated: Bool
    /// The exact total number of differences in this pinned comparison (not
    /// merely the number in this page).
    public var totalDifferences: Int
    /// Start offset for the next page, or nil when this page reached the end.
    public var nextOffset: Int?
    /// The comparison reads the last COMMITTED current document. Unsaved
    /// edits are deliberately not included because compare never writes.
    public var currentHasUnsavedChanges: Bool
    public var note: String?

    public init(from: CADNamedVersionReference, to: CADNamedVersionReference,
                identical: Bool, contentIdentical: Bool, revisionChanged: Bool,
                changedSections: [String], differences: [CADNamedVersionDifference],
                truncated: Bool, currentHasUnsavedChanges: Bool, note: String?,
                totalDifferences: Int = 0, nextOffset: Int? = nil) {
        self.from = from
        self.to = to
        self.identical = identical
        self.contentIdentical = contentIdentical
        self.revisionChanged = revisionChanged
        self.changedSections = changedSections
        self.differences = differences
        self.truncated = truncated
        self.totalDifferences = totalDifferences
        self.nextOffset = nextOffset
        self.currentHasUnsavedChanges = currentHasUnsavedChanges
        self.note = note
    }
}

/// Stable identity pins for a comparison page or record-detail page. The
/// client copies the `from`/`to` references from the first response; every
/// continuation must match them exactly or the service refuses with
/// `comparisonStale` instead of mixing a changed current revision.
public nonisolated struct CADNamedVersionComparisonPins: Codable, Sendable, Equatable {
    public var from: CADNamedVersionReference
    public var to: CADNamedVersionReference

    public init(from: CADNamedVersionReference, to: CADNamedVersionReference) {
        self.from = from
        self.to = to
    }

    public func validate(from actualFrom: CADNamedVersionReference,
                         to actualTo: CADNamedVersionReference) throws {
        guard actualFrom == from, actualTo == to else {
            throw CADNamedVersionError.comparisonStale
        }
    }
}

/// One side of an exact stored-record access. `chunks` is a byte-bounded page
/// of the pretty-printed JSON value; joining every page's chunks with an empty
/// separator reconstructs the exact value whose UTF-8 SHA-256 is `sha256`.
/// Missing/removed sides have `present == false`.
public nonisolated struct CADNamedVersionRecordSide: Codable, Sendable, Equatable {
    public var present: Bool
    public var chunks: [String]
    public var sha256: String?
    public var chunkCount: Int
    public var chunkOffset: Int
    public var nextChunkOffset: Int?
    public var byteCount: Int

    public init(present: Bool, chunks: [String], sha256: String?, chunkCount: Int,
                chunkOffset: Int, nextChunkOffset: Int?, byteCount: Int) {
        self.present = present
        self.chunks = chunks
        self.sha256 = sha256
        self.chunkCount = chunkCount
        self.chunkOffset = chunkOffset
        self.nextChunkOffset = nextChunkOffset
        self.byteCount = byteCount
    }
}

/// Exact saved-record detail for one comparison record. This is read-only and
/// derived from the verified package/current state; it never rewrites either.
/// Use `chunkOffset`/`chunkLimit` to page a large record's bounded JSON chunks.
public nonisolated struct CADNamedVersionRecordDetail: Codable, Sendable, Equatable {
    public var from: CADNamedVersionReference
    public var to: CADNamedVersionReference
    public var section: String
    public var identifier: String
    public var name: String
    /// added | removed | modified | unchanged | section
    public var change: String
    public var fromRecord: CADNamedVersionRecordSide
    public var toRecord: CADNamedVersionRecordSide
    public var note: String?
    public var chunkOffset: Int
    public var chunkLimit: Int

    public init(from: CADNamedVersionReference, to: CADNamedVersionReference,
                section: String, identifier: String, name: String, change: String,
                fromRecord: CADNamedVersionRecordSide,
                toRecord: CADNamedVersionRecordSide, note: String?,
                chunkOffset: Int, chunkLimit: Int) {
        self.from = from
        self.to = to
        self.section = section
        self.identifier = identifier
        self.name = name
        self.change = change
        self.fromRecord = fromRecord
        self.toRecord = toRecord
        self.note = note
        self.chunkOffset = chunkOffset
        self.chunkLimit = chunkLimit
    }
}

public nonisolated struct CADNamedVersionRestoreResult: Codable, Sendable, Equatable {
    public var version: CADNamedVersionSummary
    /// Safety checkpoint made from the exact committed document immediately
    /// before the restore. Nil when the restore was already current.
    public var recoveryVersion: CADNamedVersionSummary?
    public var alreadyCurrent: Bool
    public var previousRevision: Int
    public var previousContentSHA256: String
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String
    /// Restoring starts a new undo boundary; ordinary Undo cannot cross it.
    public var undoBoundaryReset: Bool
    public var bodyCount: Int
    public var featureCount: Int
    /// Explicit restored-branch checkpoint when the caller requested one.
    public var branchVersion: CADNamedVersionSummary?
    public var branchIssue: String?

    public init(version: CADNamedVersionSummary, recoveryVersion: CADNamedVersionSummary?,
                alreadyCurrent: Bool, previousRevision: Int, previousContentSHA256: String,
                revision: Int, contentSHA256: String, modelSHA256: String,
                undoBoundaryReset: Bool, bodyCount: Int, featureCount: Int,
                branchVersion: CADNamedVersionSummary? = nil,
                branchIssue: String? = nil) {
        self.version = version
        self.recoveryVersion = recoveryVersion
        self.alreadyCurrent = alreadyCurrent
        self.previousRevision = previousRevision
        self.previousContentSHA256 = previousContentSHA256
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.undoBoundaryReset = undoBoundaryReset
        self.bodyCount = bodyCount
        self.featureCount = featureCount
        self.branchVersion = branchVersion
        self.branchIssue = branchIssue
    }
}

#if DEBUG
/// Deterministic test seams for the restore admission/cancellation boundary.
/// They never replace the store, session fence, CAS or production checks.
@MainActor
enum CADNamedVersionTestHooks {
    static var afterCheckpointLoad: (() async -> Void)?
    static var beforeRestoreCommit: (() async throws -> Void)?
}

/// Bounded async seams INSIDE detached checkpoint work. A detached task does
/// not inherit the caller's cancellation; these let a test suspend the owned
/// child at a safe stage, cancel the real parent task, and then prove the
/// child observes cancellation before any publish/commit boundary. They never
/// replace file I/O, verification, the package gate or the revision CAS.
nonisolated enum CADNamedVersionWorkHooks {
    /// Fired after a checkpoint has been copied and verified in its hidden
    /// pending directory, before the format-floor commit or final promotion.
    nonisolated(unsafe) static var afterCheckpointStaged: (@Sendable () async -> Void)?
    /// Fired after a checkpoint package has been fully loaded/verified during
    /// a detached compare/restore read, before the service uses it.
    nonisolated(unsafe) static var afterCheckpointLoaded: (@Sendable () async -> Void)?
    /// Fired after a read-only list has been built, before it is returned.
    nonisolated(unsafe) static var afterListLoaded: (@Sendable () async -> Void)?
    /// Fired by the retained-recovery listing immediately before it waits on
    /// the package gate. A test can prove the listing reached the gate while a
    /// live create still owns it; it is a scheduling observation only.
    nonisolated(unsafe) static var beforeRecoveryListGate: (@Sendable () -> Void)?
}
#endif

// MARK: - Stored record

/// `version.json` inside one checkpoint directory. This is deliberately a
/// small, additive record: old CAD packages have no `versions/` directory and
/// open unchanged; a future record version is refused by compare/restore while
/// still being listed as unusable, never silently overwritten.
nonisolated struct CADNamedVersionRecord: Codable, Sendable, Equatable {
    static let currentRecordVersion = 1

    var recordVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var sourceRevision: Int
    var contentSHA256: String
    var modelSHA256: String?
    var schemaVersion: Int
    var appBuild: String
    var counts: [String: Int]
    var byteCount: Int?
    var isRecovery: Bool
    var note: String?
    var parentVersionID: UUID? = nil
    var restoredFromVersionID: UUID? = nil

    func summary(isUsable: Bool = true, issue: String? = nil) -> CADNamedVersionSummary {
        CADNamedVersionSummary(
            id: id, name: name, createdAt: createdAt,
            sourceRevision: sourceRevision, contentSHA256: contentSHA256,
            modelSHA256: modelSHA256, schemaVersion: schemaVersion,
            appBuild: appBuild, counts: counts, byteCount: byteCount,
            isRecovery: isRecovery, isUsable: isUsable, issue: issue,
            parentVersionID: parentVersionID,
            restoredFromVersionID: restoredFromVersionID)
    }
}

// MARK: - Name rules

/// Version names are display metadata only and are NEVER used as path
/// components: the on-disk directory is the version UUID. These checks keep
/// the metadata free of path separators, control/invisible characters and
/// ambiguous traversal spellings anyway, so a future export/listing cannot
/// turn a name into a path.
nonisolated enum CADNamedVersionName {
    static let maximumLength = 120

    /// Returns the trimmed name, or throws a localized validation error.
    static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.text("cad.versions.error.emptyName",
                                    "Enter a name for this version."))
        }
        guard trimmed.count <= maximumLength else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.format("cad.versions.error.nameTooLong",
                                      "Use at most %d characters.", maximumLength))
        }
        guard trimmed != ".", trimmed != ".." else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.text("cad.versions.error.reservedName",
                                    "That name is reserved."))
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.text("cad.versions.error.separator",
                                    "Names can't contain / or \\."))
        }
        guard !trimmed.contains("\0") else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.text("cad.versions.error.control",
                                    "Names can't contain control characters."))
        }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
        }) else {
            throw CADNamedVersionError.invalidName(
                FloeCADStrings.text("cad.versions.error.control",
                                    "Names can't contain control characters."))
        }
        return trimmed.precomposedStringWithCanonicalMapping
    }
}
