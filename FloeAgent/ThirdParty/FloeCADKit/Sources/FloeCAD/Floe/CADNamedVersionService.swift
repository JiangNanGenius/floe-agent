//
//  CADNamedVersionService.swift
//  FloeCADKit
//
//  Public operations for user-named design versions. This is the ONE version
//  surface used by the workbench UI, the App bridge and the existing
//  `cad.document` typed action — there is no second document or parallel
//  persistence path.
//
//  Semantics:
//    * create  — explicit checkpoint of the current COMMITTED whole document;
//                pending edits are settled through the ordinary save kernel
//                first, so a checkpoint is never a half-applied state.
//    * list    — read-only; corrupt/incompatible checkpoints are reported.
//    * compare — read-only; exact stored-record/digest differences only.
//    * restore — revision/CAS-checked ordinary commit through the same save
//                kernel. The pre-restore state is saved as a recovery
//                checkpoint, Undo starts a new boundary, and a refused/failed
//                commit restores the exact in-memory state while the disk
//                package is untouched.
//    * delete  — removes only one checkpoint directory; never the document,
//                its `previous/` recovery copy, other versions, or external
//                project files.
//

import Foundation

@MainActor
final class CADNamedVersionService {
    private let document: FloeCADDocument

    init(document: FloeCADDocument) {
        self.document = document
    }

    private var store: CADNamedVersionStore {
        CADNamedVersionStore(packageURL: document.url)
    }

    // MARK: - List

    func list() async throws -> [CADNamedVersionSummary] {
        try requireOpen()
        let url = document.url
        return try await Self.ownedDetached {
            let rows = try CADNamedVersionStore(packageURL: url).list()
            #if DEBUG
            if let hook = CADNamedVersionWorkHooks.afterListLoaded { await hook() }
            #endif
            try Task.checkCancellation()
            return rows
        }
    }

    /// Read-only listing of checkpoints retained after the format-floor commit
    /// but never published. These are NOT visible versions and are never
    /// reported as created work; the caller can explicitly recover or delete
    /// one. A live staging create holds the same package gate, so it can never
    /// appear here while it is running.
    func recoveries() async throws -> [CADNamedVersionRecoverySummary] {
        try requireOpen()
        let url = document.url
        return try await Self.ownedDetached {
            let rows = try CADNamedVersionStore(packageURL: url).recoverableCheckpoints()
            try Task.checkCancellation()
            return rows
        }
    }

    // MARK: - Create

    func create(name: String,
                parentVersionID: UUID? = nil,
                restoredFromVersionID: UUID? = nil) async throws -> CADNamedVersionCreateResult {
        try requireWritable()
        let revisionBefore = document.revision
        // The existing identity-pin preparation is the right settle for a
        // checkpoint: wait out a writer, commit real pending edits, and drop a
        // redundant clean debounce. It never substitutes a second save path.
        let settle: AnimationIdentitySettleResult
        do {
            settle = try await document.session.settleSaveStateBeforeIdentityPin(
                expectingChangeCount: document.liveChangeCount)
        } catch is CancellationError {
            throw CADNamedVersionError.restoreRefused(
                FloeCADStrings.text("cad.versions.error.cancelled",
                                    "Creating the version was cancelled."))
        } catch {
            throw CADNamedVersionError.saveFailed(error.localizedDescription)
        }
        switch settle {
        case .ready:
            break
        case .sourceChanged:
            throw CADNamedVersionError.documentBusy(
                FloeCADStrings.text("cad.versions.busy.changed",
                                    "The document changed while the version was being prepared."))
        case .saveFailed(let detail):
            throw CADNamedVersionError.saveFailed(detail)
        }
        // The settle above awaited. Refuse a checkpoint whose document was
        // closed or whose real store was revoked while it was suspended; the
        // store-level owner lease below is the final atomic check.
        try requireWritableAndOwnerActive()

        do {
            try Task.checkCancellation()
        } catch {
            throw CADNamedVersionError.restoreRefused(
                FloeCADStrings.text("cad.versions.error.cancelled",
                                    "Creating the version was cancelled."))
        }
        let url = document.url
        let owner = document.store
        let savedCurrent = document.revision > revisionBefore
        var lastError: Error?
        // A cooperative save may land between the settle await and the
        // detached snapshot. Re-pin once and retry that exact race; a constant
        // editor keeps failing closed rather than mixing generations.
        for _ in 0..<2 {
            let revision = document.revision
            let content = document.contentSHA256
            do {
                let created = try await Self.ownedDetached {
                    try await CADNamedVersionStore(packageURL: url).create(
                        name: name,
                        expectedRevision: revision,
                        expectedContentSHA256: content,
                        parentVersionID: parentVersionID,
                        restoredFromVersionID: restoredFromVersionID,
                        owner: owner)
                }
                if created.advancedFormatFloor {
                    // A close may have been waiting for an already-entered
                    // floor commit. The store finished that synchronous phase
                    // honestly; adopting its exact receipt keeps this live
                    // facade's identity equal to the real committed state.
                    adoptCommittedFloor(revision: created.revision,
                                        contentSHA256: created.contentSHA256,
                                        modelSHA256: created.modelSHA256)
                }
                document.project.hasNamedVersions = true
                document.project.formatVersion = max(
                    document.project.formatVersion, created.summary.schemaVersion)
                return CADNamedVersionCreateResult(
                    version: created.summary,
                    savedCurrentDocument: savedCurrent
                        || created.summary.sourceRevision > revisionBefore,
                    revision: created.revision,
                    contentSHA256: created.contentSHA256,
                    modelSHA256: created.modelSHA256)
            } catch CADNamedVersionError.revisionMismatch(let expected, let actual)
                        where actual > expected {
                lastError = CADNamedVersionError.revisionMismatch(expected: expected, actual: actual)
                continue
            } catch CADNamedVersionError.contentMismatch(_, _) {
                lastError = CADNamedVersionError.contentMismatch(
                    expected: content, actual: document.contentSHA256)
                continue
            } catch is CancellationError {
                throw CADNamedVersionError.restoreRefused(
                    FloeCADStrings.text("cad.versions.error.cancelled",
                                        "Creating the version was cancelled."))
            } catch let error as CADNamedVersionError {
                // A promotion failure after the format-floor commit carries
                // the committed identity. Adopt it before reporting so this
                // open document can save normally and reopen truthfully; the
                // hidden pending checkpoint bytes remain recoverable.
                if case .promotionFailed(_, let committedRevision, let committedContent,
                                         let committedModel, _) = error {
                    adoptCommittedFloor(revision: committedRevision,
                                        contentSHA256: committedContent,
                                        modelSHA256: committedModel)
                }
                throw error
            } catch {
                throw error
            }
        }
        throw lastError ?? CADNamedVersionError.saveFailed(
            FloeCADStrings.text("cad.versions.error.raced",
                                "The document kept changing. The version was not created."))
    }

    // MARK: - Compare

    /// Exact stored-state comparison. `against` nil compares with the last
    /// committed current document; no write or save occurs. `offset`/`limit`
    /// page the SAME deterministic difference list; a continuation request
    /// (offset > 0) must supply the `pins` copied from the first response.
    func compare(versionID: UUID, against otherVersionID: UUID? = nil,
                 offset: Int = 0, limit: Int = CADNamedVersionComparisonBuilder.maximumDifferences,
                 pins: CADNamedVersionComparisonPins? = nil) async throws
    -> CADNamedVersionComparison {
        try requireOpen()
        if offset > 0, pins == nil {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.text("cad.versions.error.comparePinsRequired",
                                    "Fetching a later comparison page requires the identity pins from the first page."))
        }
        let url = document.url
        let package = try await Self.loadCheckpointDetached(url: url, versionID: versionID)
        try Task.checkCancellation()
        let versionReference = reference(for: package)
        let targetState: CADNamedVersionState
        let targetReference: CADNamedVersionReference
        let hasUnsavedChanges: Bool
        if let otherVersionID {
            let other = try await Self.loadCheckpointDetached(url: url,
                                                              versionID: otherVersionID)
            try Task.checkCancellation()
            targetState = other.state
            targetReference = reference(for: other)
            hasUnsavedChanges = false
        } else {
            targetState = try await readCurrentState()
            targetReference = CADNamedVersionReference(
                kind: "current", versionID: nil,
                name: targetState.manifest.name,
                revision: targetState.manifest.revision,
                contentSHA256: targetState.manifest.contentSHA256,
                modelSHA256: targetState.modelSHA256,
                schemaVersion: targetState.manifest.schemaVersion)
            hasUnsavedChanges = document.hasUnsavedChanges
        }
        if let pins {
            try pins.validate(from: versionReference, to: targetReference)
        }
        try Task.checkCancellation()
        return CADNamedVersionComparisonBuilder.compare(
            from: package.state, fromReference: versionReference,
            to: targetState, toReference: targetReference,
            currentHasUnsavedChanges: hasUnsavedChanges,
            offset: offset, limit: limit)
    }

    /// Read-only exact saved-record detail for one difference identifier. The
    /// record values come from the verified package/current state, so a caller
    /// can fetch every actual field value that the bounded summary detail
    /// omitted. `chunkOffset`/`chunkLimit` page the exact pretty-printed JSON
    /// in byte-bounded chunks; later pages require the same identity pins as
    /// the first call.
    func recordDetail(versionID: UUID, against otherVersionID: UUID? = nil,
                      section: String, identifier: String,
                      chunkOffset: Int = 0, chunkLimit: Int = 16,
                      pins: CADNamedVersionComparisonPins? = nil) async throws
    -> CADNamedVersionRecordDetail {
        try requireOpen()
        let normalizedSection = section.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSection.isEmpty, !normalizedIdentifier.isEmpty else {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.text("cad.versions.error.recordTarget",
                                    "A record detail request requires section and identifier."))
        }
        if chunkOffset > 0, pins == nil {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.text("cad.versions.error.recordPinsRequired",
                                    "Fetching a later record page requires the identity pins from the first page."))
        }
        let url = document.url
        let package = try await Self.loadCheckpointDetached(url: url, versionID: versionID)
        try Task.checkCancellation()
        let versionReference = reference(for: package)
        let targetState: CADNamedVersionState
        let targetReference: CADNamedVersionReference
        if let otherVersionID {
            let other = try await Self.loadCheckpointDetached(url: url,
                                                              versionID: otherVersionID)
            try Task.checkCancellation()
            targetState = other.state
            targetReference = reference(for: other)
        } else {
            targetState = try await readCurrentState()
            targetReference = CADNamedVersionReference(
                kind: "current", versionID: nil,
                name: targetState.manifest.name,
                revision: targetState.manifest.revision,
                contentSHA256: targetState.manifest.contentSHA256,
                modelSHA256: targetState.modelSHA256,
                schemaVersion: targetState.manifest.schemaVersion)
        }
        if let pins {
            try pins.validate(from: versionReference, to: targetReference)
        }
        let access = CADNamedVersionComparisonBuilder.recordAccess(
            section: normalizedSection, identifier: normalizedIdentifier,
            from: package.state, to: targetState)
        let boundedOffset = max(0, chunkOffset)
        let boundedLimit = min(max(1, chunkLimit),
                               CADNamedVersionComparisonBuilder.maximumRecordChunkLimit)
        return CADNamedVersionRecordDetail(
            from: versionReference, to: targetReference,
            section: normalizedSection, identifier: normalizedIdentifier,
            name: access.name, change: access.change,
            fromRecord: Self.recordSide(access.from, chunkOffset: boundedOffset,
                                        chunkLimit: boundedLimit),
            toRecord: Self.recordSide(access.to, chunkOffset: boundedOffset,
                                      chunkLimit: boundedLimit),
            note: access.note,
            chunkOffset: boundedOffset, chunkLimit: boundedLimit)
    }

    /// Serialize one exact record value as deterministic pretty JSON and page
    /// it in byte-bounded UTF-8 chunks. The digest covers the WHOLE value, so
    /// concatenating all pages can be verified without trusting the page
    /// boundaries. A single very large embedded string is split at Unicode
    /// scalar boundaries rather than returned as an unbounded line.
    ///
    /// The scan is bounded: it walks the serialized bytes once, counts every
    /// chunk, but materializes at most one `maximumRecordChunkBytes` chunk at
    /// a time and retains only the requested page (at most the caller's
    /// bounded `chunkLimit`). It never builds an array of every chunk for the
    /// whole record, so a record with thousands of pages cannot be held in
    /// RAM merely to fetch one page.
    private static func recordSide(
        _ value: Any?, chunkOffset: Int, chunkLimit: Int
    ) -> CADNamedVersionRecordSide {
        guard let value else {
            return CADNamedVersionRecordSide(
                present: false, chunks: [], sha256: nil, chunkCount: 0,
                chunkOffset: chunkOffset, nextChunkOffset: nil, byteCount: 0)
        }
        let object: Any = JSONSerialization.isValidJSONObject(value)
            ? value : ["value": value]
        guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return CADNamedVersionRecordSide(
                present: false, chunks: [], sha256: nil, chunkCount: 0,
                chunkOffset: chunkOffset, nextChunkOffset: nil, byteCount: 0)
        }
        let maximumChunkBytes = CADNamedVersionComparisonBuilder.maximumRecordChunkBytes
        let pageStart = max(0, chunkOffset)
        let pageLimit = min(max(1, chunkLimit),
                            CADNamedVersionComparisonBuilder.maximumRecordChunkLimit)
        let pageEnd = pageStart > Int.max - pageLimit ? Int.max : pageStart + pageLimit
        var page: [String] = []
        var currentChunk = ""
        var chunkIndex = 0
        var cursor = data.startIndex
        while cursor < data.endIndex {
            var end = data.index(cursor, offsetBy: maximumChunkBytes,
                                 limitedBy: data.endIndex) ?? data.endIndex
            // Back up to the start of a Unicode scalar that crosses the
            // candidate boundary. UTF-8 continuation bytes are 10xxxxxx and a
            // scalar is at most four bytes, so this shifts by at most three.
            while end > cursor, end < data.endIndex,
                  (data[end] & 0b1100_0000) == 0b1000_0000 {
                end = data.index(before: end)
            }
            if end == cursor {
                // Defensive only: JSONSerialization returns valid UTF-8, so a
                // 512-byte window can never end inside a scalar longer than
                // the window. Never emit an empty chunk (which would loop).
                var forward = data.index(cursor, offsetBy: maximumChunkBytes,
                                         limitedBy: data.endIndex) ?? data.endIndex
                while forward < data.endIndex,
                      (data[forward] & 0b1100_0000) == 0b1000_0000 {
                    forward = data.index(after: forward)
                }
                end = forward
            }
            currentChunk = String(decoding: data[cursor..<end], as: UTF8.self)
            if chunkIndex >= pageStart, chunkIndex < pageEnd {
                page.append(currentChunk)
            }
            chunkIndex += 1
            cursor = end
        }
        // An out-of-range offset is clamped to the truthful end (no invented
        // chunk); the whole-value digest and counts remain available.
        let start = min(pageStart, chunkIndex)
        let end = min(pageEnd, chunkIndex)
        let next = end < chunkIndex ? end : nil
        return CADNamedVersionRecordSide(
            present: true, chunks: page, sha256: FileCADDocumentStore.sha256(data),
            chunkCount: chunkIndex, chunkOffset: start, nextChunkOffset: next,
            byteCount: data.count)
    }

    // MARK: - Restore

    func restore(versionID: UUID,
                 expectedRevision: Int? = nil,
                 expectedContentSHA256: String? = nil,
                 createBranch: Bool = false,
                 branchName: String? = nil) async throws
    -> CADNamedVersionRestoreResult {
        try requireWritable()
        if let expectedRevision, expectedRevision != document.revision {
            throw CADNamedVersionError.revisionMismatch(
                expected: expectedRevision, actual: document.revision)
        }
        if let expectedContentSHA256, expectedContentSHA256 != document.contentSHA256 {
            throw CADNamedVersionError.contentMismatch(
                expected: expectedContentSHA256, actual: document.contentSHA256)
        }
        try Task.checkCancellation()
        let admittedRevision = document.revision
        let admittedContent = document.contentSHA256
        let admittedChangeCount = document.liveChangeCount
        let url = document.url
        let owner = document.store
        let package = try await Self.loadCheckpointDetached(url: url, versionID: versionID)
        #if DEBUG
        await CADNamedVersionTestHooks.afterCheckpointLoad?()
        #endif
        // The checkpoint load awaited. A close that happened meanwhile (or a
        // revoked real store) must refuse before this restore creates a safety
        // checkpoint or replaces the in-memory graph.
        try requireWritableAndOwnerActive()
        try Task.checkCancellation()
        guard document.liveChangeCount == admittedChangeCount,
              document.revision == admittedRevision,
              document.contentSHA256 == admittedContent else {
            if document.revision != admittedRevision {
                throw CADNamedVersionError.revisionMismatch(
                    expected: admittedRevision, actual: document.revision)
            }
            throw CADNamedVersionError.documentBusy(
                FloeCADStrings.text("cad.versions.busy.changedDuringLoad",
                                    "The document changed while the version was being read. Nothing was restored; try again."))
        }
        guard package.manifest.schemaVersion <= Project.currentFormatVersion else {
            throw CADNamedVersionError.incompatible(
                versionID, "format \(package.manifest.schemaVersion) is newer than this app")
        }
        guard !package.state.isOpaqueForWrite else {
            throw CADNamedVersionError.incompatible(
                versionID, "the checkpoint contains newer association semantics")
        }

        // Identical content needs no commit, no recovery copy and no undo
        // boundary. The comparison is exact content identity.
        let metadataMatches = package.manifest.name == document.project.name
            && package.manifest.unit == document.project.unitRaw
            && package.manifest.tolerance == document.project.tolerance
        let floorIsSafe = !document.project.hasNamedVersions
            || document.project.formatVersion >= CADDocumentFormat.namedVersionFormatVersion
        if package.manifest.contentSHA256 == document.contentSHA256,
           metadataMatches, !document.hasUnsavedChanges, floorIsSafe {
            let summary = document.summary()
            return CADNamedVersionRestoreResult(
                version: package.record.summary(),
                recoveryVersion: nil,
                alreadyCurrent: true,
                previousRevision: document.revision,
                previousContentSHA256: document.contentSHA256,
                revision: document.revision,
                contentSHA256: document.contentSHA256,
                modelSHA256: document.modelSHA256,
                undoBoundaryReset: false,
                bodyCount: summary.bodyCount,
                featureCount: summary.featureCount)
        }

        guard document.session.beginNamedVersionRestore() else {
            throw CADNamedVersionError.documentBusy(
                document.session.writeBlock?.message
                    ?? FloeCADStrings.text("cad.versions.busy.restore",
                                           "Another edit is in progress."))
        }
        defer { document.session.endNamedVersionRestore() }

        let settleError = await document.session.settleForNamedVersionRestore()
        if let settleError {
            throw CADNamedVersionError.saveFailed(settleError)
        }
        // Settling may have awaited a save. Do not start the safety checkpoint
        // for a document that was closed in the meantime.
        try requireWritableAndOwnerActive()
        try Task.checkCancellation()
        if let expectedRevision, expectedRevision != document.revision {
            throw CADNamedVersionError.revisionMismatch(
                expected: expectedRevision, actual: document.revision)
        }
        if let expectedContentSHA256, expectedContentSHA256 != document.contentSHA256 {
            throw CADNamedVersionError.contentMismatch(
                expected: expectedContentSHA256, actual: document.contentSHA256)
        }
        var previousRevision = document.revision
        var previousContent = document.contentSHA256

        // Preserve the exact pre-restore COMMITTED state as a recoverable
        // checkpoint. It is created before the commit so it survives even if
        // later saves rotate `previous/`; on a refused/cancelled restore it is
        // removed after the current document is proven untouched.
        let recoveryName = Self.recoveryName(for: package.record.name)
        var recovery: CADNamedVersionSummary?
        var rollback: DocumentSession.NamedVersionRestoreRollback?
        do {
            let recoveryBaseRevision = previousRevision
            let recoveryBaseContent = previousContent
            let createdRecovery: CADNamedVersionCreateOutcome
            do {
                createdRecovery = try await Self.ownedDetached {
                    try await CADNamedVersionStore(packageURL: url).create(
                        name: recoveryName,
                        expectedRevision: recoveryBaseRevision,
                        expectedContentSHA256: recoveryBaseContent,
                        isRecovery: true,
                        note: "Automatic copy of the committed document before restoring \(package.record.name).",
                        owner: owner)
                }
            } catch let error as CADNamedVersionError {
                if case .promotionFailed(_, let committedRevision, let committedContent,
                                         let committedModel, _) = error {
                    // The recovery checkpoint's floor commit landed but its
                    // promotion failed. Adopt the committed identity before
                    // surfacing the refusal so this document can still save
                    // and reopen; the hidden checkpoint bytes stay retained.
                    adoptCommittedFloor(revision: committedRevision,
                                        contentSHA256: committedContent,
                                        modelSHA256: committedModel)
                }
                throw error
            }
            recovery = createdRecovery.summary
            if createdRecovery.advancedFormatFloor {
                // Migration of a pre-floor package: the recovery checkpoint
                // creation raised the package floor with a new revision. Adopt
                // that identity before the exact restore uses it as its CAS
                // base; the document bytes/model are unchanged.
                adoptCommittedFloor(revision: createdRecovery.revision,
                                    contentSHA256: createdRecovery.contentSHA256,
                                    modelSHA256: createdRecovery.modelSHA256)
                previousRevision = createdRecovery.revision
                previousContent = createdRecovery.contentSHA256
            }
            try Task.checkCancellation()
            #if DEBUG
            try await CADNamedVersionTestHooks.beforeRestoreCommit?()
            #endif
            // The restore commit boundary: a cancellation or a real close that
            // arrived while the async hook was suspended must refuse BEFORE any
            // in-memory replacement or disk commit. The provisional recovery
            // checkpoint is still removed by the outer catch.
            try requireWritableAndOwnerActive()
            try Task.checkCancellation()
            guard document.revision == previousRevision,
                  document.contentSHA256 == previousContent else {
                throw CADNamedVersionError.revisionMismatch(
                    expected: previousRevision, actual: document.revision)
            }
            rollback = document.session.captureNamedVersionRestoreRollback()
            let project = FileCADDocumentStore(packageURL: document.url)
                .makeProject(manifest: package.manifest,
                             document: package.document,
                             blobs: package.blobs,
                             thumbnail: package.thumbnail)
            project.hasOpaqueAssociations = package.state.isOpaqueForWrite
            try document.session.applyNamedVersionProjectForRestore(project)
            // The in-memory graph is replaced now. Revalidate the real owner
            // before the exact commit: if the document was closed, the outer
            // catch restores the captured rollback and the store's own revoke
            // fence refuses the commit.
            try requireWritableAndOwnerActive()
            // Commit the checkpoint's EXACT document.json/blobs with a new
            // revision. A normal session save re-encodes decoded records and
            // can change their byte-level model identity; this store path
            // keeps the verified checkpoint digests intact.
            try Task.checkCancellation()
            guard document.revision == previousRevision,
                  document.contentSHA256 == previousContent else {
                throw CADNamedVersionError.revisionMismatch(
                    expected: previousRevision, actual: document.revision)
            }
            let store = document.store
            let exactBaseRevision = previousRevision
            let outcome: CADSaveOutcome
            do {
                // Last precommit cancellation boundary. The exact commit is
                // synchronous once entered; a cancellation after this point
                // may be reported as a completed restore, never as a success
                // without the committed graph.
                outcome = try await Self.ownedDetached {
                    try Task.checkCancellation()
                    return try store.performExactRestore(
                        sourceManifest: package.manifest,
                        document: package.document,
                        documentData: package.state.documentData,
                        blobs: package.blobs,
                        thumbnail: package.thumbnail,
                        expectedRevision: exactBaseRevision)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CADNamedVersionError.saveFailed(error.localizedDescription)
            }
            guard outcome.succeeded else {
                throw CADNamedVersionError.saveFailed(
                    outcome.error ?? FloeCADStrings.text("cad.versions.error.unknownSave",
                                                        "the commit was refused"))
            }
            document.session.adoptExactRestoredIdentity(outcome)
            document.adoptRestoredDocumentName(package.manifest.name)
            document.project.formatVersion = max(
                document.project.formatVersion, document.store.schemaVersion)
            document.project.hasNamedVersions = true
            var branchVersion: CADNamedVersionSummary?
            var branchIssue: String?
            if createBranch {
                do {
                    let rows = try await list()
                    let requested = branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = Self.uniqueBranchName(
                        (requested?.isEmpty == false ? requested! : "Branch — \(package.record.name)"),
                        existing: rows)
                    let branch = try await create(
                        name: name,
                        parentVersionID: package.record.id,
                        restoredFromVersionID: package.record.id)
                    branchVersion = branch.version
                } catch {
                    // The in-place restore is already durable; report the
                    // branch-checkpoint failure instead of pretending it
                    // exists or rolling back the restored document.
                    branchIssue = error.localizedDescription
                }
            }
            let summary = document.summary()
            return CADNamedVersionRestoreResult(
                version: package.record.summary(),
                recoveryVersion: recovery,
                alreadyCurrent: false,
                previousRevision: previousRevision,
                previousContentSHA256: previousContent,
                revision: outcome.revision,
                contentSHA256: outcome.contentSHA256,
                modelSHA256: outcome.modelSHA256,
                undoBoundaryReset: true,
                bodyCount: summary.bodyCount,
                featureCount: summary.featureCount,
                branchVersion: branchVersion,
                branchIssue: branchIssue)
        } catch {
            if let rollback {
                document.session.restoreAfterFailedNamedVersionRestore(rollback)
            }
            if let recovery {
                await removeRecoveryAfterFailedRestore(recovery.id)
            }
            throw error
        }
    }

    // MARK: - Delete

    func delete(versionID: UUID) async throws -> CADNamedVersionDeleteResult {
        try requireWritable()
        let url = document.url
        let owner = document.store
        return try await Self.ownedDetached {
            // The public path honors cancellation while waiting on the package
            // gate, and the real owner lease refuses a close/revoke before any
            // byte is moved.
            try CADNamedVersionStore(packageURL: url)
                .delete(versionID, owner: owner)
        }
    }

    /// Publish one retained post-format-floor checkpoint as a visible version.
    /// This is the same native version service used by the versions panel and
    /// `cad.document`; it re-verifies the hidden bytes and the committed
    /// package floor, refuses collisions, and only reports success after the
    /// visible checkpoint can be loaded again.
    func recoverRetainedVersion(_ id: UUID) async throws -> CADNamedVersionRecoveryResult {
        try requireWritable()
        let url = document.url
        let owner = document.store
        let package = try await Self.ownedDetached {
            try CADNamedVersionStore(packageURL: url)
                .promoteRetainedPendingCheckpoint(id, owner: owner)
        }
        // Promotion only renames verified hidden bytes; it never rewrites the
        // current manifest. Keep the open document's product floor coherent so
        // an ordinary save cannot fall back to a legacy floor while the new
        // visible checkpoint exists.
        document.project.hasNamedVersions = true
        document.project.formatVersion = max(
            document.project.formatVersion,
            CADDocumentFormat.namedVersionFormatVersion,
            package.manifest.schemaVersion)
        return CADNamedVersionRecoveryResult(
            version: package.record.summary(),
            revision: package.manifest.revision,
            contentSHA256: package.manifest.contentSHA256,
            modelSHA256: package.state.modelSHA256)
    }

    /// Delete exactly one retained recovery checkpoint. The current document,
    /// `previous/`, every visible version and external project files are
    /// untouched. A live staging entry without a recovery marker is refused by
    /// the store.
    func discardRetainedRecovery(_ id: UUID) async throws -> CADNamedVersionDeleteResult {
        try requireWritable()
        let url = document.url
        let owner = document.store
        return try await Self.ownedDetached {
            try CADNamedVersionStore(packageURL: url)
                .discardRetainedPendingCheckpoint(id, owner: owner)
        }
    }

    // MARK: - JSON action surface (bridge)

    func handle(action rawAction: String, args: [String: Any]) async throws -> String {
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        func jsonObject<T: Encodable>(_ value: T) throws -> Any {
            let data = try encoder.encode(value)
            return try JSONSerialization.jsonObject(with: data)
        }
        var object: [String: Any] = ["ok": true, "action": action]
        switch action {
        case "list":
            object["versions"] = try jsonObject(try await list())
            object["recoveries"] = try jsonObject(try await recoveries())
            object["revision"] = document.revision
            object["content_sha256"] = document.contentSHA256
            object["has_unsaved_changes"] = document.hasUnsavedChanges
        case "recoveries":
            object["recoveries"] = try jsonObject(try await recoveries())
            object["revision"] = document.revision
            object["content_sha256"] = document.contentSHA256
        case "create":
            guard let name = args["name"] as? String else {
                throw CADNamedVersionError.invalidName(
                    FloeCADStrings.text("cad.versions.error.missingName",
                                        "Provide a name for the new version."))
            }
            object["result"] = try jsonObject(try await create(name: name))
        case "compare":
            let id = try uuidArgument("version_id", in: args)
            let other = try optionalUUIDArgument("against_version_id", in: args)
            let offset = max(0, optionalIntArgument("offset", in: args) ?? 0)
            let limit = optionalIntArgument("limit", in: args)
                ?? CADNamedVersionComparisonBuilder.maximumDifferences
            let pins = try comparisonPins(from: args)
            object["comparison"] = try jsonObject(try await compare(
                versionID: id, against: other, offset: offset, limit: limit, pins: pins))
        case "restore":
            let id = try uuidArgument("version_id", in: args)
            let revision = optionalIntArgument("expected_revision", in: args)
            let content = (args["expected_content_sha256"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let createBranch = (args["create_branch"] as? Bool) ?? true
            let branchName = (args["branch_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            object["result"] = try jsonObject(try await restore(
                versionID: id,
                expectedRevision: revision,
                expectedContentSHA256: (content?.isEmpty ?? true) ? nil : content,
                createBranch: createBranch,
                branchName: (branchName?.isEmpty ?? true) ? nil : branchName))
        case "delete":
            let id = try uuidArgument("version_id", in: args)
            object["result"] = try jsonObject(try await delete(versionID: id))
        case "record":
            let id = try uuidArgument("version_id", in: args)
            let other = try optionalUUIDArgument("against_version_id", in: args)
            let section = try requiredStringArgument("section", in: args)
            let identifier = try requiredStringArgument("identifier", in: args)
            let offset = max(0, optionalIntArgument("chunk_offset", in: args) ?? 0)
            let limit = optionalIntArgument("chunk_limit", in: args) ?? 16
            let pins = try comparisonPins(from: args)
            object["record"] = try jsonObject(try await recordDetail(
                versionID: id, against: other, section: section,
                identifier: identifier, chunkOffset: offset, chunkLimit: limit,
                pins: pins))
        case "recover":
            let id = try uuidArgument("version_id", in: args)
            object["result"] = try jsonObject(try await recoverRetainedVersion(id))
        case "discard_recovery":
            let id = try uuidArgument("version_id", in: args)
            object["result"] = try jsonObject(try await discardRetainedRecovery(id))
        default:
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.format("cad.versions.error.unknownAction",
                                      "versions payload.action must be list|create|compare|restore|delete|recoveries|recover|discard_recovery|record (got '%@').",
                                      rawAction))
        }
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
    }

    // MARK: - Helpers

    /// Owned detached checkpoint work.
    ///
    /// `Task.detached { ... }.value` does NOT inherit the caller's
    /// cancellation: cancelling the user's task would leave a checkpoint copy,
    /// floor commit or restore commit running unattended. This helper keeps a
    /// parent-child link for cancellation only — the child is detached so the
    /// file I/O never runs on the main actor, but a parent cancellation cancels
    /// the child, which checks `Task.isCancelled` at the safe stage boundaries.
    /// After an atomic commit has been entered the child deliberately finishes
    /// and reports the committed result.
    nonisolated private static func ownedDetached<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() })
    }

    nonisolated private static func loadCheckpointDetached(
        url: URL, versionID: UUID
    ) async throws -> CADNamedVersionPackage {
        try await ownedDetached {
            let package = try CADNamedVersionStore(packageURL: url).load(versionID)
            #if DEBUG
            if let hook = CADNamedVersionWorkHooks.afterCheckpointLoaded { await hook() }
            #endif
            try Task.checkCancellation()
            return package
        }
    }

    /// Adopt the exact identity produced by a cooperating checkpoint store's
    /// format-floor/exact commit. The document bytes/model are unchanged; the
    /// open document's store, session and platform floor must advance so a
    /// later ordinary save uses the new revision instead of failing stale.
    private func adoptCommittedFloor(revision: Int, contentSHA256: String,
                                     modelSHA256: String) {
        let receipt = CADSaveOutcome(revision: revision,
                                     contentSHA256: contentSHA256,
                                     modelSHA256: modelSHA256,
                                     error: nil)
        document.store.adoptExternalCommittedIdentity(
            receipt, schemaVersion: CADDocumentFormat.namedVersionFormatVersion)
        document.session.adoptExternalStoreIdentity(receipt)
        document.project.formatVersion = max(
            document.project.formatVersion, CADDocumentFormat.namedVersionFormatVersion)
        document.project.hasNamedVersions = true
    }

    private func requireOpen() throws {
        guard !document.isClosed else { throw CADNamedVersionError.closed }
    }

    private func requireWritable() throws {
        try requireOpen()
        guard !document.isReadOnly else { throw CADNamedVersionError.readOnly }
    }

    /// A post-await lifetime re-check against the REAL open document's store.
    /// `isClosed` catches the normal MainActor close; the store lease catches a
    /// store that was revoked independently. Both are synchronous and run on
    /// the main actor; the atomic mutation boundary re-checks the same lease
    /// inside the store.
    private func requireWritableAndOwnerActive() throws {
        try requireWritable()
        do {
            try document.store.requireActiveOwnerWriteLease()
        } catch {
            throw CADNamedVersionError.closed
        }
    }

    private func reference(for package: CADNamedVersionPackage) -> CADNamedVersionReference {
        CADNamedVersionReference(
            kind: "version", versionID: package.record.id,
            name: package.record.name,
            revision: package.manifest.revision,
            contentSHA256: package.manifest.contentSHA256,
            modelSHA256: package.state.modelSHA256,
            schemaVersion: package.manifest.schemaVersion,
            isRecovery: package.record.isRecovery)
    }

    private func readCurrentState() async throws -> CADNamedVersionState {
        let url = document.url
        return try await Self.ownedDetached {
            try Task.checkCancellation()
            CADPackageGate.acquire(url)
            defer { CADPackageGate.release(url) }
            let store = FileCADDocumentStore(packageURL: url)
            let verified: FileCADDocumentStore.CADVerifiedPackage
            do {
                verified = try store.verifiedPackage(at: url)
            } catch {
                throw CADNamedVersionError.ioFailure(error.localizedDescription)
            }
            try Task.checkCancellation()
            // Without a verifiable canonical model identity, use the exact
            // content digest as the comparison identity rather than a
            // reconstructed digest that might ignore unknown fields.
            let model = verified.modelSHA256
                ?? "content:\(verified.manifest.contentSHA256)"
            return CADNamedVersionState(
                manifest: verified.manifest, document: verified.document,
                documentData: verified.documentData,
                blobs: verified.blobs, thumbnail: verified.thumbnail,
                modelSHA256: model,
                isOpaqueForWrite: verified.formatAssessment.isOpaqueReadOnly)
        }
    }

    private func removeRecoveryAfterFailedRestore(_ id: UUID) async {
        let url = document.url
        // Cleanup must finish even when the caller's task is being cancelled
        // OR the document was closed while the restore failed: the provisional
        // recovery checkpoint must not remain visible after a refused/cancelled
        // restore. This is the ONLY internal non-cancellable, owner-free delete
        // path; it removes exactly this call's recovery checkpoint id and never
        // touches visible versions, the current package or a foreign entry.
        _ = try? await Self.ownedDetached {
            try CADNamedVersionStore(packageURL: url)
                .delete(id, honorCancellation: false)
        }
    }

    static func uniqueBranchName(_ raw: String, existing: [CADNamedVersionSummary]) -> String {
        let base = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CADNamedVersionName.maximumLength))
        var candidate = base
        var index = 2
        func taken(_ value: String) -> Bool {
            existing.contains {
                $0.isUsable && $0.name.precomposedStringWithCanonicalMapping
                    .caseInsensitiveCompare(value.precomposedStringWithCanonicalMapping) == .orderedSame
            }
        }
        while taken(candidate) {
            let suffix = " \(index)"
            candidate = String(base.prefix(max(1, CADNamedVersionName.maximumLength - suffix.count))) + suffix
            index += 1
            if index > 99 { break }
        }
        return candidate.isEmpty ? "Branch" : candidate
    }

    static func recoveryName(for target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "version" : trimmed
        let prefix = "Before restore — "
        let maximum = CADNamedVersionName.maximumLength
        let available = max(1, maximum - prefix.count)
        return prefix + String(base.prefix(available))
    }

    private func comparisonPins(from args: [String: Any]) throws
    -> CADNamedVersionComparisonPins? {
        guard let raw = args["identity"] else { return nil }
        guard let object = raw as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.text("cad.versions.error.compareIdentity",
                                    "identity must be the from/to object returned by the first comparison page."))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys])
            return try JSONDecoder().decode(CADNamedVersionComparisonPins.self,
                                            from: data)
        } catch {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.text("cad.versions.error.compareIdentity",
                                    "identity must be the from/to object returned by the first comparison page."))
        }
    }

    private func requiredStringArgument(_ key: String,
                                        in args: [String: Any]) throws -> String {
        guard let value = args[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.format("cad.versions.error.missingArgument",
                                      "versions record requires %@ (a stored string).", key))
        }
        return value
    }

    private func uuidArgument(_ key: String, in args: [String: Any]) throws -> UUID {
        guard let raw = args[key] as? String,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CADNamedVersionError.invalidAction(
                FloeCADStrings.format("cad.versions.error.missingID",
                                      "versions requires %@ (a version UUID).", key))
        }
        return id
    }

    private func optionalUUIDArgument(_ key: String, in args: [String: Any]) throws -> UUID? {
        guard let raw = args[key] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try uuidArgument(key, in: args)
    }

    private func optionalIntArgument(_ key: String, in args: [String: Any]) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        if let value = args[key] as? String, let parsed = Int(value) { return parsed }
        return nil
    }
}

@MainActor
public extension FloeCADDocument {
    /// Read-only list of named versions plus unusable rows. Never writes.
    func namedVersions() async throws -> [CADNamedVersionSummary] {
        try await CADNamedVersionService(document: self).list()
    }

    /// Explicit checkpoint of the current whole document. Pending edits are
    /// committed through the ordinary save kernel first.
    @discardableResult
    func createNamedVersion(name: String) async throws -> CADNamedVersionCreateResult {
        try await CADNamedVersionService(document: self).create(name: name)
    }

    /// Exact stored-state comparison. `against` nil compares with the last
    /// committed current document; no write or save occurs. `offset`/`limit`
    /// page the same deterministic comparison and `pins` (from the first page)
    /// refuse a changed current revision instead of mixing it.
    func compareNamedVersion(_ id: UUID,
                             against otherVersionID: UUID? = nil,
                             offset: Int = 0,
                             limit: Int = CADNamedVersionComparison.defaultPageLimit,
                             pins: CADNamedVersionComparisonPins? = nil) async throws
    -> CADNamedVersionComparison {
        try await CADNamedVersionService(document: self).compare(
            versionID: id, against: otherVersionID, offset: offset, limit: limit,
            pins: pins)
    }

    /// Exact saved-record detail for one comparison identifier. Large records
    /// are paged in byte-bounded pretty-printed JSON chunks; the returned
    /// digest covers the whole value, and later pages require the same identity
    /// pins.
    func namedVersionRecordDetail(_ id: UUID,
                                  against otherVersionID: UUID? = nil,
                                  section: String,
                                  identifier: String,
                                  chunkOffset: Int = 0,
                                  chunkLimit: Int = 16,
                                  pins: CADNamedVersionComparisonPins? = nil) async throws
    -> CADNamedVersionRecordDetail {
        try await CADNamedVersionService(document: self).recordDetail(
            versionID: id, against: otherVersionID, section: section,
            identifier: identifier, chunkOffset: chunkOffset,
            chunkLimit: chunkLimit, pins: pins)
    }

    /// Restore a checkpoint through the current ownership/revision CAS. The
    /// pre-restore committed state is preserved as a recovery version.
    @discardableResult
    func restoreNamedVersion(_ id: UUID,
                             expectedRevision: Int? = nil,
                             expectedContentSHA256: String? = nil,
                             createBranch: Bool = false,
                             branchName: String? = nil) async throws
    -> CADNamedVersionRestoreResult {
        try await CADNamedVersionService(document: self).restore(
            versionID: id,
            expectedRevision: expectedRevision,
            expectedContentSHA256: expectedContentSHA256,
            createBranch: createBranch,
            branchName: branchName)
    }

    /// Remove one checkpoint. The document package, `previous/` and external
    /// project files are untouched.
    @discardableResult
    func deleteNamedVersion(_ id: UUID) async throws -> CADNamedVersionDeleteResult {
        try await CADNamedVersionService(document: self).delete(versionID: id)
    }

    /// Read-only list of checkpoints retained after a committed package floor
    /// but never published. These are not versions and are not reported as
    /// created work; the native panel and typed tool offer recovery/deletion.
    func namedVersionRecoveries() async throws -> [CADNamedVersionRecoverySummary] {
        try await CADNamedVersionService(document: self).recoveries()
    }

    /// Publish one retained recovery checkpoint through the ordinary native
    /// version service. Success means the checkpoint is visible and reloadable,
    /// not merely that the error was dismissed.
    @discardableResult
    func recoverNamedVersion(_ id: UUID) async throws -> CADNamedVersionRecoveryResult {
        try await CADNamedVersionService(document: self).recoverRetainedVersion(id)
    }

    /// Delete only one retained recovery checkpoint; visible versions and the
    /// current document are untouched.
    @discardableResult
    func discardNamedVersionRecovery(_ id: UUID) async throws -> CADNamedVersionDeleteResult {
        try await CADNamedVersionService(document: self).discardRetainedRecovery(id)
    }

    /// JSON action surface shared by the App bridge and `cad.document`.
    /// `args` uses `action` plus name/version_id/against_version_id/
    /// expected_revision/expected_content_sha256. Every call still goes
    /// through this document's own ownership, permissions and revision CAS.
    func handleNamedVersionAction(_ action: String,
                                  args: [String: Any]) async throws -> String {
        try await CADNamedVersionService(document: self).handle(action: action, args: args)
    }
}
