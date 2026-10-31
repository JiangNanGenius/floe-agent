//
//  CADNamedVersionStore.swift
//  FloeCADKit
//
//  Storage for user-named design versions. One checkpoint is a complete,
//  verified copy of the committed package payload:
//
//    <name>.floecad/
//      manifest.json          current commit
//      document.json          current commit
//      blobs/                 meshes, B-reps, images, preview
//      previous/              the store's one-step recovery copy
//      versions/
//        <uuid>/
//          version.json       small metadata record (name is display-only)
//          manifest.json      the checkpoint's exact committed manifest
//          document.json      the checkpoint's exact committed records
//          blobs/             every blob the manifest/document claim
//
//  A checkpoint is verified with the SAME `FileCADDocumentStore` read path as
//  an ordinary open (manifest, document, blob digests, preview digest, content
//  digest, model digest). Nothing is ever reconstructed from the current
//  in-memory document, so the checkpoint is stable even if a later edit is
//  unsaved. The UUID directory means user names never become filesystem paths.
//

import Foundation

/// Exact committed state of one package (current or checkpoint). Sendable so
/// comparison/read work can run off the main actor without touching a live
/// `FloeCADDocument`.
nonisolated struct CADNamedVersionState: Sendable {
    var manifest: CADManifest
    var document: CADDocumentRecord
    /// Exact committed `document.json` bytes (restore commit source).
    var documentData: Data
    var blobs: [String: Data]
    var thumbnail: Data?
    /// Exact canonical model digest computed from the bytes on disk.
    var modelSHA256: String
    /// True when the format assessment says an older writer must not rewrite
    /// this package. Compare is still allowed; restore refuses.
    var isOpaqueForWrite: Bool
}

nonisolated struct CADNamedVersionPackage: Sendable {
    var record: CADNamedVersionRecord
    var state: CADNamedVersionState

    var manifest: CADManifest { state.manifest }
    var document: CADDocumentRecord { state.document }
    var blobs: [String: Data] { state.blobs }
    var thumbnail: Data? { state.thumbnail }
    var modelSHA256: String { state.modelSHA256 }
}

nonisolated struct CADNamedVersionCreateOutcome: Sendable {
    var summary: CADNamedVersionSummary
    var revision: Int
    var contentSHA256: String
    var modelSHA256: String
    /// True when this creation raised the package from a legacy floor to the
    /// coordinated named-version floor with an exact revision commit.
    var advancedFormatFloor: Bool
}

nonisolated struct CADNamedVersionStore {
    static let maximumVersions = 50
    static let maximumRecordBytes = 512 * 1024
    static let maximumRecoveryMarkerBytes = CADNamedVersionRecoveryMarker.maximumBytes

    let packageURL: URL
    let fileManager: FileManager

    init(packageURL: URL, fileManager: FileManager = .default) {
        self.packageURL = packageURL
        self.fileManager = fileManager
    }

    var versionsURL: URL {
        packageURL.appendingPathComponent("versions", isDirectory: true)
    }

    // MARK: - List

    /// Read-only listing. A corrupt/unreadable checkpoint is reported as an
    /// unusable row instead of disappearing or failing the whole list.
    func list() throws -> [CADNamedVersionSummary] {
        try requireVersionsRootSafe()
        guard fileManager.fileExists(atPath: versionsURL.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        var rows: [CADNamedVersionSummary] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            do {
                let record = try readRecord(in: entry, id: id)
                rows.append(record.summary())
            } catch {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? Date(timeIntervalSince1970: 0)
                let bytes = directoryByteCount(entry)
                rows.append(CADNamedVersionSummary(
                    id: id, name: "", createdAt: created, sourceRevision: 0,
                    contentSHA256: "", modelSHA256: nil, schemaVersion: 0,
                    appBuild: "", counts: [:], byteCount: bytes,
                    isRecovery: false, isUsable: false,
                    issue: issueText(error)))
            }
        }
        return rows.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Create

    /// Snapshot the CURRENT COMMITTED package. The caller flushes pending
    /// edits first and pins the expected revision/content; the revision guard
    /// refuses a stale snapshot rather than mixing two generations.
    ///
    /// A package that does not yet carry named versions is first raised to the
    /// coordinated named-version schema floor by an exact revision commit of
    /// the same payload. The checkpoint is staged as a HIDDEN pending entry and
    /// becomes visible only after that floor commit succeeds, so an ordinary
    /// still-legacy package cannot be left schema1/5 with visible checkpoints
    /// that a released writer would delete on its next save. A failure before
    /// promotion removes the pending entry and leaves the old floor/revision.
    ///
    /// `owner` is the REAL open document's store when this mutation belongs to
    /// a live document. It contributes only its existing lock/revoked fence:
    /// staging, the format-floor commit and the final promotion all run inside
    /// that owner lease, so closing the document can never allow a late
    /// checkpoint commit or promotion. A nil owner keeps the standalone
    /// verified-store APIs usable without an open document.
    func create(name rawName: String,
                expectedRevision: Int,
                expectedContentSHA256: String,
                isRecovery: Bool = false,
                note: String? = nil,
                parentVersionID: UUID? = nil,
                restoredFromVersionID: UUID? = nil,
                owner: FileCADDocumentStore? = nil) async throws -> CADNamedVersionCreateOutcome {
        let name = try CADNamedVersionName.validated(rawName)
        try requireVersionsRootSafe()
        try Task.checkCancellation()
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        // Gate first, then the owner's own lock (never the reverse). The
        // owner check is a cheap preflight; the staging/commit sections below
        // re-check it atomically because a close can race this call.
        try requireOwnerWritable(owner)

        let sourceStore = FileCADDocumentStore(packageURL: packageURL, fileManager: fileManager)
        let verified: VerifiedPackage
        do {
            verified = try sourceStore.verifiedPackage(at: packageURL)
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        guard verified.manifest.revision == expectedRevision else {
            throw CADNamedVersionError.revisionMismatch(expected: expectedRevision,
                                                        actual: verified.manifest.revision)
        }
        guard verified.manifest.contentSHA256 == expectedContentSHA256 else {
            throw CADNamedVersionError.contentMismatch(expected: expectedContentSHA256,
                                                       actual: verified.manifest.contentSHA256)
        }

        let existing = try list()
        if !isRecovery,
           existing.contains(where: {
               $0.isUsable && $0.name.precomposedStringWithCanonicalMapping
                   .caseInsensitiveCompare(name) == .orderedSame
           }) {
            throw CADNamedVersionError.duplicateName(name)
        }
        // A restore's safety checkpoint must not be blocked by the user-version
        // cap. It is a recovery row, clearly marked, and can be deleted like
        // any other checkpoint; ordinary user versions stay capped.
        guard isRecovery || existing.count < Self.maximumVersions else {
            throw CADNamedVersionError.limitReached(Self.maximumVersions)
        }

        let id = UUID()
        let finalURL = versionsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let pending = pendingURL(for: id)
        // Set only when this call has already committed the package format
        // floor. From that point the promoted bytes or the retained hidden
        // pending checkpoint must match the committed identity; the generic
        // cleanup below must not delete them.
        var retainPending = false
        do {
            // Stage the complete checkpoint under the REAL owner's lifetime
            // lease. close() takes the same owner lock, so it either waits for
            // this synchronous section or the lease refuses before a checkpoint
            // file is written. The lease is released before the DEBUG await
            // below; it is never held across that suspension.
            let staged = try withOwnerWriteLease(owner) {
                () -> (record: CADNamedVersionRecord, needsFormatFloorCommit: Bool) in
                try Task.checkCancellation()
                try fileManager.createDirectory(at: versionsURL, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)
                try Task.checkCancellation()
                let byteCount = try copyCommittedPayload(from: packageURL, to: pending)
                let record = CADNamedVersionRecord(
                    recordVersion: CADNamedVersionRecord.currentRecordVersion,
                    id: id,
                    name: name,
                    createdAt: Date(),
                    sourceRevision: verified.manifest.revision,
                    contentSHA256: verified.manifest.contentSHA256,
                    modelSHA256: verified.modelSHA256,
                    schemaVersion: verified.manifest.schemaVersion,
                    appBuild: verified.manifest.appBuild,
                    counts: verified.manifest.counts,
                    byteCount: byteCount,
                    isRecovery: isRecovery,
                    note: note,
                    parentVersionID: parentVersionID,
                    restoredFromVersionID: restoredFromVersionID)
                let recordData = try Self.encoder().encode(record)
                guard recordData.count <= Self.maximumRecordBytes else {
                    throw CADNamedVersionError.ioFailure("version metadata is too large")
                }
                try recordData.write(to: pending.appendingPathComponent("version.json"),
                                     options: .atomic)

                // Re-open the staged checkpoint through the exact same
                // verification path an open/restore uses. This proves the copy
                // is complete before it becomes visible.
                let stagedStore = FileCADDocumentStore(packageURL: pending,
                                                       fileManager: fileManager)
                let staged = try stagedStore.verifiedPackage(at: pending)
                guard staged.manifest.revision == record.sourceRevision,
                      staged.manifest.contentSHA256 == record.contentSHA256,
                      staged.manifest.schemaVersion == record.schemaVersion else {
                    throw CADNamedVersionError.ioFailure(
                        "the staged checkpoint changed identity while it was copied")
                }
                if let recordedModel = record.modelSHA256, let stagedModel = staged.modelSHA256,
                   recordedModel != stagedModel {
                    throw CADNamedVersionError.ioFailure(
                        "the staged checkpoint model digest does not match")
                }

                let needsFormatFloorCommit = verified.manifest.schemaVersion
                    < CADDocumentFormat.namedVersionFormatVersion
                // Write the retained-recovery marker BEFORE the format-floor
                // commit. If the process crashes during/after that commit, the
                // complete staged bytes and this marker survive; the current
                // package manifest (not the marker) proves whether the floor was
                // committed. If the commit never lands, the package stays legacy
                // and recovery is not offered. A running create holds the package
                // gate, so this live staging is never listable/promotable/deletable
                // by another in-process caller.
                if needsFormatFloorCommit {
                    let marker = CADNamedVersionRecoveryMarker(
                        markerVersion: CADNamedVersionRecoveryMarker.currentMarkerVersion,
                        id: id,
                        state: .postFormatFloorRecovery,
                        name: record.name,
                        createdAt: record.createdAt,
                        isRecovery: record.isRecovery,
                        requiredFormatVersion: CADDocumentFormat.namedVersionFormatVersion)
                    try writeRecoveryMarker(marker, in: pending)
                }
                return (record, needsFormatFloorCommit)
            }
            let record = staged.record

            #if DEBUG
            if let hook = CADNamedVersionWorkHooks.afterCheckpointStaged { await hook() }
            #endif
            // The async seam must not become a checkpoint window. A real close
            // that happened while this task was suspended refuses here, BEFORE
            // the floor commit or the already-floor promotion. Only this
            // call's hidden pending entry is removed by the catch below.
            try requireOwnerWritable(owner)
            // This is the last safe cancellation boundary before any commit.
            // The floor commit and the promotion are synchronous below; once
            // the commit starts the checkpoint must be finished or retained
            // truthfully instead of leaving a raised floor with stale caller
            // identity.
            try Task.checkCancellation()

            // The format-floor commit and the final promotion are one
            // synchronous owner-lease transaction. A close that is already
            // waiting for the owner lock therefore observes the ACTUAL
            // committed state: either both the floor and the visible checkpoint
            // landed, or neither started. It can never observe a raised floor
            // with an unpublished checkpoint, or a promotion after release.
            let committed = try withOwnerWriteLease(owner) {
                () -> (advancedFormatFloor: Bool, outcome: CADSaveOutcome) in
                var advancedFloor = false
                var revision = verified.manifest.revision
                var contentSHA = verified.manifest.contentSHA256
                var modelSHA = verified.modelSHA256 ?? ""
                var floorReceipt: CADSaveOutcome?
                if staged.needsFormatFloorCommit {
                    var bumped = verified.manifest
                    bumped.schemaVersion = CADDocumentFormat.namedVersionFormatVersion
                    let receipt = try sourceStore.performExactRestore(
                        sourceManifest: bumped,
                        document: verified.document,
                        documentData: verified.documentData,
                        blobs: verified.blobs,
                        thumbnail: verified.thumbnail,
                        expectedRevision: verified.manifest.revision,
                        packageGateAlreadyHeld: true)
                    advancedFloor = true
                    revision = receipt.revision
                    contentSHA = receipt.contentSHA256
                    modelSHA = receipt.modelSHA256
                    floorReceipt = receipt
                }

                // Final promotion of the verified pending checkpoint. If a
                // floor commit already happened in this call, do NOT check
                // cancellation any more: the package identity is committed, so
                // either the visible rename must complete or the complete
                // pending bytes must be retained and the committed identity
                // reported. Deleting the pending entry here would permanently
                // lose a checkpoint that the caller cannot distinguish from a
                // safe pre-commit refusal.
                do {
                    try CADDocumentFaultInjection.beforeNamedVersionPromotion?()
                    guard fileManager.fileExists(atPath: pending.path) else {
                        throw CADNamedVersionError.ioFailure(
                            "the staged checkpoint was not preserved across the format-floor commit")
                    }
                    guard !fileManager.fileExists(atPath: finalURL.path) else {
                        throw CADNamedVersionError.ioFailure("version identity collision")
                    }
                    try fileManager.moveItem(at: pending, to: finalURL)
                    // The checkpoint is visible now; the recovery marker has
                    // done its job. A failed removal leaves an ignored extra
                    // file (the verifier only reads the
                    // manifest/document/blobs), never a second version or a
                    // recovery row.
                    try? fileManager.removeItem(
                        at: finalURL.appendingPathComponent(CADNamedVersionRecoveryMarker.fileName))
                } catch {
                    guard let receipt = floorReceipt else { throw error }
                    retainPending = true
                    throw CADNamedVersionError.promotionFailed(
                        id: id,
                        revision: receipt.revision,
                        contentSHA256: receipt.contentSHA256,
                        modelSHA256: receipt.modelSHA256,
                        underlying: error.localizedDescription)
                }
                return (advancedFloor,
                        CADSaveOutcome(revision: revision,
                                       contentSHA256: contentSHA,
                                       modelSHA256: modelSHA,
                                       error: nil))
            }
            return CADNamedVersionCreateOutcome(
                summary: record.summary(),
                revision: committed.outcome.revision,
                contentSHA256: committed.outcome.contentSHA256,
                modelSHA256: committed.outcome.modelSHA256,
                advancedFormatFloor: committed.advancedFormatFloor)
        } catch is CancellationError {
            removeOwnedPending(pending)
            throw CancellationError()
        } catch let error as CADNamedVersionError {
            // A promotion failure after the format-floor commit keeps the
            // complete, already-verified pending checkpoint for explicit
            // recovery. Every other failure removes ONLY this call's owned
            // pending directory; the nonempty `versions/` parent and every
            // other checkpoint/recovery/unknown retained entry are untouched.
            if !retainPending { removeOwnedPending(pending) }
            throw error
        } catch {
            removeOwnedPending(pending)
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
    }

    /// The hidden staging path for one checkpoint id. Only this exact UUID
    /// path is ever removed by create's cleanup.
    func pendingURL(for id: UUID) -> URL {
        versionsURL.appendingPathComponent(".pending-\(id.uuidString)", isDirectory: true)
    }

    /// Remove only the caller-owned pending directory. Never removes the
    /// `versions/` parent (which may contain other versions, recovery rows or
    /// entries this build does not understand) and never touches the visible
    /// checkpoint path.
    private func removeOwnedPending(_ pending: URL) {
        guard fileManager.fileExists(atPath: pending.path),
              isNotSymbolicLink(pending) else { return }
        try? fileManager.removeItem(at: pending)
    }

    /// Preflight the real open document's existing owner fence. Nil keeps the
    /// standalone store/test APIs usable; it never infers an owner from the
    /// package path.
    private func requireOwnerWritable(_ owner: FileCADDocumentStore?) throws {
        guard let owner else { return }
        do {
            try owner.requireActiveOwnerWriteLease()
        } catch {
            throw CADNamedVersionError.closed
        }
    }

    /// Run one synchronous mutation while the real open document is still the
    /// active owner. The owner lock is the existing `FileCADDocumentStore`
    /// lock, so a close cannot interleave with this body; never pass a body
    /// that awaits. The fresh commit store inside `create` keeps its own lock,
    /// preserving gate -> owner -> commit-store order without recursion.
    private func withOwnerWriteLease<T>(_ owner: FileCADDocumentStore?,
                                        _ body: () throws -> T) throws -> T {
        guard let owner else { return try body() }
        do {
            return try owner.withActiveOwnerWriteLease(body)
        } catch CADDocumentOwnerWriteLeaseError.revoked {
            throw CADNamedVersionError.closed
        }
    }

    // MARK: - Load

    /// Verify one checkpoint and return its exact records. Compare/restore use
    /// this; a failure NEVER falls back to the current package.
    func load(_ id: UUID) throws -> CADNamedVersionPackage {
        try requireVersionsRootSafe()
        let directory = versionsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        return try loadPackage(at: directory, id: id)
    }

    // MARK: - Retained post-format-floor recovery

    /// Read-only listing of hidden checkpoints that were staged for a package
    /// format-floor commit. The current package manifest must already be at the
    /// named-version floor; ordinary/live staging on a legacy package is not a
    /// completed recovery and is never offered. The package gate serializes
    /// this read against create/promote/delete, so a running create cannot be
    /// observed as recoverable work by another caller.
    func recoverableCheckpoints() throws -> [CADNamedVersionRecoverySummary] {
        try requireVersionsRootSafe()
        #if DEBUG
        CADNamedVersionWorkHooks.beforeRecoveryListGate?()
        #endif
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        guard fileManager.fileExists(atPath: versionsURL.path) else { return [] }
        guard try currentPackageSchemaVersion()
                >= CADDocumentFormat.namedVersionFormatVersion else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                            .creationDateKey],
                options: [])
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        var rows: [CADNamedVersionRecoverySummary] = []
        let prefix = ".pending-"
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix(prefix),
                  let id = UUID(uuidString:
                                    String(entry.lastPathComponent.dropFirst(prefix.count)))
            else { continue }
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            // No marker means ordinary staging (or an entry this build does
            // not understand). It is never user-recoverable work.
            guard markerFileExists(in: entry) else { continue }
            let bytes = directoryByteCount(entry)
            do {
                let marker = try readRecoveryMarker(in: entry, id: id)
                let package = try loadPackage(at: entry, id: id)
                rows.append(CADNamedVersionRecoverySummary(
                    id: package.record.id,
                    name: package.record.name,
                    createdAt: package.record.createdAt,
                    sourceRevision: package.record.sourceRevision,
                    contentSHA256: package.record.contentSHA256,
                    modelSHA256: package.record.modelSHA256 ?? package.state.modelSHA256,
                    schemaVersion: package.record.schemaVersion,
                    counts: package.record.counts,
                    byteCount: package.record.byteCount ?? bytes,
                    isRecovery: package.record.isRecovery,
                    isUsable: true,
                    issue: nil,
                    requiredFormatVersion: marker.requiredFormatVersion))
            } catch {
                // Marker present but damaged: expose an unusable row so the
                // user can delete it, never a completed/recoverable claim.
                let marker = try? readRecoveryMarker(in: entry, id: id)
                let record = try? readRecord(in: entry, id: id)
                let created = record?.createdAt
                    ?? marker?.createdAt
                    ?? (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? Date(timeIntervalSince1970: 0)
                rows.append(CADNamedVersionRecoverySummary(
                    id: id,
                    name: record?.name ?? marker?.name ?? "",
                    createdAt: created,
                    sourceRevision: record?.sourceRevision ?? 0,
                    contentSHA256: record?.contentSHA256 ?? "",
                    modelSHA256: record?.modelSHA256,
                    schemaVersion: record?.schemaVersion ?? 0,
                    counts: record?.counts ?? [:],
                    byteCount: record?.byteCount ?? bytes,
                    isRecovery: record?.isRecovery ?? marker?.isRecovery ?? false,
                    isUsable: false,
                    issue: issueText(error),
                    requiredFormatVersion: marker?.requiredFormatVersion
                        ?? CADDocumentFormat.namedVersionFormatVersion))
            }
        }
        return rows.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Load the retained, hidden checkpoint bytes from a create whose final
    /// promotion failed AFTER the package format floor was committed. These
    /// bytes are a complete, verified checkpoint; they are deliberately not
    /// listed as a version and never reported as successfully created until
    /// `promoteRetainedPendingCheckpoint` makes them visible.
    func loadRetainedPendingCheckpoint(_ id: UUID) throws -> CADNamedVersionPackage {
        try requireVersionsRootSafe()
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        return try loadRetainedPendingCheckpointLocked(id)
    }

    private func loadRetainedPendingCheckpointLocked(_ id: UUID) throws
    -> CADNamedVersionPackage {
        let pending = pendingURL(for: id)
        _ = try readRecoveryMarker(in: pending, id: id)
        guard try currentPackageSchemaVersion()
                >= CADDocumentFormat.namedVersionFormatVersion else {
            throw CADNamedVersionError.recoveryUnavailable(
                "the document format was not updated")
        }
        return try loadPackage(at: pending, id: id)
    }

    /// Make a retained post-commit pending checkpoint visible. This is the
    /// explicit recovery route for `CADNamedVersionError.promotionFailed`; it
    /// re-verifies the hidden checkpoint and the committed package floor first,
    /// refuses an identity/name/cap collision instead of overwriting a visible
    /// version, and never touches the current document bytes.
    func promoteRetainedPendingCheckpoint(_ id: UUID,
                                          owner: FileCADDocumentStore? = nil
    ) throws -> CADNamedVersionPackage {
        try requireVersionsRootSafe()
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        try requireOwnerWritable(owner)
        let pending = pendingURL(for: id)
        let finalURL = versionsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let package = try loadRetainedPendingCheckpointLocked(id)
        let existing = try list()
        if !package.record.isRecovery,
           existing.contains(where: {
               $0.isUsable && $0.name.precomposedStringWithCanonicalMapping
                   .caseInsensitiveCompare(package.record.name) == .orderedSame
           }) {
            throw CADNamedVersionError.duplicateName(package.record.name)
        }
        guard package.record.isRecovery || existing.count < Self.maximumVersions else {
            throw CADNamedVersionError.limitReached(Self.maximumVersions)
        }
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw CADNamedVersionError.recoveryCollision(id)
        }
        try Task.checkCancellation()
        do {
            // The rename and its marker cleanup are one atomic owner-lease
            // phase: a close either prevents the visible promotion entirely or
            // waits until the visible checkpoint is complete.
            try withOwnerWriteLease(owner) {
                try CADDocumentFaultInjection.beforeNamedVersionPromotion?()
                try fileManager.moveItem(at: pending, to: finalURL)
                try? fileManager.removeItem(
                    at: finalURL.appendingPathComponent(
                        CADNamedVersionRecoveryMarker.fileName))
            }
        } catch let error as CADNamedVersionError {
            throw error
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        return try loadPackage(at: finalURL, id: id)
    }

    /// Delete exactly one retained recovery checkpoint. A live staging entry has
    /// no recovery marker and is refused. The visible package, `previous/`,
    /// every visible version and external project files are untouched.
    func discardRetainedPendingCheckpoint(_ id: UUID,
                                          owner: FileCADDocumentStore? = nil
    ) throws -> CADNamedVersionDeleteResult {
        try requireVersionsRootSafe()
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        // A public discard cancelled while it was waiting for package ownership
        // must refuse before touching any bytes. Genuine create/restore
        // cleanup uses `delete(honorCancellation: false)` instead.
        try Task.checkCancellation()
        try requireOwnerWritable(owner)
        let pending = pendingURL(for: id)
        guard fileManager.fileExists(atPath: pending.path),
              isNotSymbolicLink(pending),
              markerFileExists(in: pending) else {
            throw CADNamedVersionError.notFound(id)
        }
        // A damaged marker still identifies retained bytes that may be deleted;
        // a missing marker is indistinguishable from live staging and is
        // refused above.
        let marker = try? readRecoveryMarker(in: pending, id: id)
        let name = (try? readRecord(in: pending, id: id))?.name
            ?? marker?.name ?? ""
        let trash = versionsURL.appendingPathComponent(
            ".trash-\(id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        var cleanupIssue: String?
        do {
            try withOwnerWriteLease(owner) {
                try fileManager.moveItem(at: pending, to: trash)
                do {
                    try fileManager.removeItem(at: trash)
                } catch {
                    cleanupIssue = error.localizedDescription
                }
            }
        } catch let error as CADNamedVersionError {
            throw error
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        return CADNamedVersionDeleteResult(id: id, name: name, deleted: true,
                                           cleanupIssue: cleanupIssue)
    }

    private func markerFileExists(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(CADNamedVersionRecoveryMarker.fileName)
        guard let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func writeRecoveryMarker(_ marker: CADNamedVersionRecoveryMarker,
                                     in directory: URL) throws {
        let data: Data
        do {
            data = try Self.encoder().encode(marker)
        } catch {
            throw CADNamedVersionError.ioFailure(
                "the recovery record could not be encoded")
        }
        guard data.count <= Self.maximumRecoveryMarkerBytes else {
            throw CADNamedVersionError.ioFailure("the recovery record is too large")
        }
        do {
            try data.write(to: directory.appendingPathComponent(
                                CADNamedVersionRecoveryMarker.fileName),
                           options: .atomic)
        } catch {
            throw CADNamedVersionError.ioFailure(
                "the recovery record could not be written: \(error.localizedDescription)")
        }
    }

    private func readRecoveryMarker(in directory: URL, id: UUID) throws
    -> CADNamedVersionRecoveryMarker {
        guard fileManager.fileExists(atPath: directory.path),
              isNotSymbolicLink(directory) else {
            throw CADNamedVersionError.notFound(id)
        }
        let url = directory.appendingPathComponent(CADNamedVersionRecoveryMarker.fileName)
        guard let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumRecoveryMarkerBytes else {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record is missing or damaged")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record is unreadable")
        }
        let marker: CADNamedVersionRecoveryMarker
        do { marker = try Self.decoder().decode(CADNamedVersionRecoveryMarker.self,
                                                from: data) }
        catch {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record is not valid JSON")
        }
        guard marker.markerVersion > 0 else {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record has no version")
        }
        guard marker.markerVersion <= CADNamedVersionRecoveryMarker.currentMarkerVersion else {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record is from a newer app")
        }
        guard marker.id == id, marker.state == .postFormatFloorRecovery else {
            throw CADNamedVersionError.recoveryUnavailable(
                "the recovery record does not match this checkpoint")
        }
        return marker
    }

    /// The current committed package floor. Recovery is only a post-commit
    /// state; a legacy/incomplete package must never offer hidden bytes as a
    /// completed recoverable checkpoint.
    private func currentPackageSchemaVersion() throws -> Int {
        let url = packageURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw CADNamedVersionError.ioFailure(
                "the current document manifest is unreadable")
        }
        do {
            return try JSONDecoder().decode(CADManifest.self, from: data).schemaVersion
        } catch {
            throw CADNamedVersionError.ioFailure(
                "the current document manifest is unreadable")
        }
    }

    private func loadPackage(at directory: URL,
                             id: UUID) throws -> CADNamedVersionPackage {
        guard fileManager.fileExists(atPath: directory.path),
              isNotSymbolicLink(directory) else {
            throw CADNamedVersionError.notFound(id)
        }
        let record: CADNamedVersionRecord
        do {
            record = try readRecord(in: directory, id: id)
        } catch let error as CADNamedVersionError {
            throw error
        } catch {
            throw CADNamedVersionError.corrupt(id, issueText(error))
        }
        guard record.recordVersion <= CADNamedVersionRecord.currentRecordVersion else {
            throw CADNamedVersionError.incompatible(
                id, "version record \(record.recordVersion) is newer than this app")
        }
        guard record.schemaVersion <= Project.currentFormatVersion else {
            throw CADNamedVersionError.incompatible(
                id, "format \(record.schemaVersion) is newer than this app")
        }
        let store = FileCADDocumentStore(packageURL: directory, fileManager: fileManager)
        let verified: VerifiedPackage
        do {
            verified = try store.verifiedPackage(at: directory)
        } catch {
            throw CADNamedVersionError.corrupt(id, issueText(error))
        }
        guard verified.manifest.schemaVersion <= Project.currentFormatVersion else {
            throw CADNamedVersionError.incompatible(
                id, "format \(verified.manifest.schemaVersion) is newer than this app")
        }
        guard verified.manifest.revision == record.sourceRevision,
              verified.manifest.contentSHA256 == record.contentSHA256,
              verified.manifest.schemaVersion == record.schemaVersion else {
            throw CADNamedVersionError.corrupt(
                id, "checkpoint manifest no longer matches its version record")
        }
        let actualModel: String
        do {
            actualModel = try FileCADDocumentStore.modelDigest(
                name: verified.manifest.name,
                unit: verified.manifest.unit,
                tolerance: verified.manifest.tolerance,
                document: verified.document,
                blobs: verified.blobs)
        } catch {
            throw CADNamedVersionError.corrupt(id, "checkpoint model cannot be canonicalized")
        }
        if record.modelSHA256 != nil, verified.modelSHA256 == nil {
            throw CADNamedVersionError.corrupt(
                id, "checkpoint model identity cannot be verified by this app")
        }
        if let recordedModel = record.modelSHA256, recordedModel != actualModel {
            throw CADNamedVersionError.corrupt(id, "checkpoint model digest mismatch")
        }
        if let declaredModel = verified.modelSHA256, declaredModel != actualModel {
            throw CADNamedVersionError.corrupt(id, "checkpoint manifest model digest mismatch")
        }
        // A checkpoint written before the additive model identity existed (or
        // one with records this build cannot canonicalize) is compared by its
        // EXACT content digest instead of a reconstructed semantic digest.
        // New checkpoints always carry record.modelSHA256.
        let comparableModel = record.modelSHA256 ?? verified.modelSHA256
            ?? "content:\(verified.manifest.contentSHA256)"
        let state = CADNamedVersionState(
            manifest: verified.manifest, document: verified.document,
            documentData: verified.documentData,
            blobs: verified.blobs, thumbnail: verified.thumbnail,
            modelSHA256: comparableModel,
            isOpaqueForWrite: verified.formatAssessment.isOpaqueReadOnly)
        return CADNamedVersionPackage(record: record, state: state)
    }

    // MARK: - Delete

    /// Delete exactly one checkpoint directory. The package, `previous/`, other
    /// versions and external project files are untouched. The directory is
    /// first moved out of the visible list, then removed; a cleanup failure is
    /// reported instead of leaving a half-visible checkpoint.
    ///
    /// `owner` fences the public mutation against the real open document's
    /// close/revoke. `honorCancellation` stays true for the public path so a
    /// delete/discard cancelled while waiting on `CADPackageGate` refuses before
    /// moving any bytes. The failed-restore cleanup is the single internal
    /// caller that passes `false`: its provisional recovery checkpoint must
    /// still be removed when the user task was cancelled.
    func delete(_ id: UUID,
                owner: FileCADDocumentStore? = nil,
                honorCancellation: Bool = true) throws -> CADNamedVersionDeleteResult {
        try requireVersionsRootSafe()
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        if honorCancellation { try Task.checkCancellation() }
        try requireOwnerWritable(owner)
        let directory = versionsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              isNotSymbolicLink(directory) else {
            throw CADNamedVersionError.notFound(id)
        }
        let record = try? readRecord(in: directory, id: id)
        let name = record?.name ?? ""
        let trash = versionsURL.appendingPathComponent(
            ".trash-\(id.uuidString)-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true)
        var cleanupIssue: String?
        do {
            try withOwnerWriteLease(owner) {
                try fileManager.moveItem(at: directory, to: trash)
                do {
                    try fileManager.removeItem(at: trash)
                } catch {
                    cleanupIssue = error.localizedDescription
                }
            }
        } catch let error as CADNamedVersionError {
            throw error
        } catch {
            throw CADNamedVersionError.ioFailure(error.localizedDescription)
        }
        return CADNamedVersionDeleteResult(id: id, name: name, deleted: true,
                                           cleanupIssue: cleanupIssue)
    }

    // MARK: - Verification seam

    /// The store's private verified-package value is exposed internally (one
    /// access change in `FileCADDocumentStore`) so this checkpoint reader uses
    /// the SAME digest/blob validation as an ordinary open, not a second
    /// simplified verifier.
    typealias VerifiedPackage = FileCADDocumentStore.CADVerifiedPackage

    // MARK: - Package copy

    /// Copy only the committed payload (`manifest.json`, `document.json`,
    /// `blobs/`) — never `previous/`, `versions/`, staging or unrelated
    /// sibling files. Symlinks and paths escaping the source package are
    /// refused, matching the reader's blob rules.
    private func copyCommittedPayload(from source: URL, to destination: URL) throws -> Int {
        var total = 0
        for leaf in ["manifest.json", "document.json"] {
            let from = source.appendingPathComponent(leaf)
            let to = destination.appendingPathComponent(leaf)
            total += try copyRegularFile(from: from, to: to)
        }
        let sourceBlobs = source.appendingPathComponent("blobs", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceBlobs.path) else { return total }
        let root = source.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let enumerator = fileManager.enumerator(
            at: sourceBlobs,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }
        ) else {
            throw CADNamedVersionError.ioFailure("the blobs directory is unreadable")
        }
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                  file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) else {
                throw CADNamedVersionError.ioFailure(
                    "a blob path is not a package-owned regular file")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw CADNamedVersionError.ioFailure("a blob is not a regular file")
            }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.count))
            guard relative.hasPrefix("blobs/"),
                  !relative.split(separator: "/").contains("..") else {
                throw CADNamedVersionError.ioFailure("a blob path escapes the package")
            }
            let to = destination.appendingPathComponent(relative)
            total += try copyRegularFile(from: file, to: to)
        }
        return total
    }

    @discardableResult
    private func copyRegularFile(from source: URL, to destination: URL) throws -> Int {
        try Task.checkCancellation()
        let values = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CADNamedVersionError.ioFailure(
                "\(source.lastPathComponent) is not a regular package file")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            throw CADNamedVersionError.ioFailure("checkpoint staging collision")
        }
        try fileManager.copyItem(at: source, to: destination)
        try Task.checkCancellation()
        return values.fileSize ?? 0
    }

    private func directoryByteCount(_ directory: URL) -> Int? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var total = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    // MARK: - Record

    private func readRecord(in directory: URL, id: UUID) throws -> CADNamedVersionRecord {
        let url = directory.appendingPathComponent("version.json")
        guard let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumRecordBytes else {
            throw CADNamedVersionError.corrupt(id, "version metadata is missing or too large")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CADNamedVersionError.corrupt(id, "version metadata is unreadable") }
        let record: CADNamedVersionRecord
        do {
            record = try Self.decoder().decode(CADNamedVersionRecord.self, from: data)
        } catch {
            throw CADNamedVersionError.corrupt(id, "version metadata is not valid JSON")
        }
        guard record.id == id else {
            throw CADNamedVersionError.corrupt(id, "version metadata names a different id")
        }
        guard record.recordVersion > 0 else {
            throw CADNamedVersionError.corrupt(id, "version metadata has no record version")
        }
        guard record.recordVersion <= CADNamedVersionRecord.currentRecordVersion else {
            throw CADNamedVersionError.incompatible(
                id, "version record \(record.recordVersion) is newer than this app")
        }
        // Enforce the same metadata rules on read as on create. This never
        // feeds a filesystem path (the directory is the UUID), but keeps
        // tampered display names from masquerading as path-like values.
        do {
            _ = try CADNamedVersionName.validated(record.name)
        } catch {
            throw CADNamedVersionError.corrupt(id, "version metadata has an invalid name")
        }
        return record
    }

    private func requireVersionsRootSafe() throws {
        if fileManager.fileExists(atPath: versionsURL.path), !isNotSymbolicLink(versionsURL) {
            throw CADNamedVersionError.ioFailure(
                "the versions directory is a symbolic link and was left untouched")
        }
    }

    private func isNotSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private func issueText(_ error: Error) -> String {
        if let named = error as? CADNamedVersionError {
            return named.errorDescription ?? "version checkpoint error"
        }
        if let store = error as? CADDocumentStoreError {
            return store.errorDescription ?? "version checkpoint error"
        }
        return error.localizedDescription
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
