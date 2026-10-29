// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native authority — staged whole-plan edit batches.
//
// The 64 KiB bridge is a transport bound, not an editing-grammar bound: a
// page-aware paste/import can legitimately contain many elements and pages.
// This route stages a closed serialized `[NoteEdit]` array in bounded chunks,
// then commits it through the SAME `NotesEngine.applyEditBatch` /
// `NotesStore.apply` transaction as `document.apply` — one revision, one undo
// group, one durable `edit_receipts` row for the whole user intent.
//
// The staged bytes are only the edit array. Document identity, revision,
// receipt id, conversation scope and conflict-resolution fields are captured
// once at `batch.stageBegin` and never re-read from append/commit payloads, so
// a caller cannot retarget a live stage. Parsing is strict and complete: no
// truncation, no partial application and no per-chunk document revision.
import Foundation
import FloeNotes

/// One service-owned edit-batch staging file. `rootPath` pins the stage to the
/// accepted Notes root that created it; the engine instance is root-bound, but
/// the recorded path makes a cross-root/retired-stage mistake a typed error
/// instead of a write into a stale temp file.
struct NotesEditBatchStage {
    let stageID: String
    let rootPath: String
    let documentID: UUID
    let expectedRevision: Int
    let baseRevision: Int?
    let title: String
    let requestID: String?
    let conversationID: UUID?
    let resolvingConflictID: UUID?
    let reviewedCopyID: UUID?
    let reviewedCopyRevision: Int?
    let expectedBytes: Int64
    let url: URL
    var handle: FileHandle?
    var receivedBytes: Int64
    let createdAt: Date
    var committedResult: Data?
}

extension NotesEngine {
    /// Maximum serialized edit batch a caller may stage. A 2 MiB text import
    /// JSON-escapes into a few MiB of elements/geometry; 8 MiB keeps a useful
    /// multi-page plan bounded well below the 16 MiB response cap. Above this
    /// bound the native service returns typed `requestTooLarge`; it never
    /// truncates or silently commits a smaller prefix.
    static let maximumStagedEditBatchBytes: Int64 = 8_388_608
    private static let maximumEditBatchStages = 8
    private static let editBatchStageLifetime: TimeInterval = 600

    func editBatchStageBegin(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let documentID = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        guard expectedRevision >= 0 else {
            throw NotesDomainError.invalidPayload("invalidExpectedRevision")
        }
        let baseRevision = try payload.intOrNil("baseRevision")
        if let baseRevision, baseRevision < 0 {
            throw NotesDomainError.invalidPayload("invalidBaseRevision")
        }
        let byteCount = try payload.int64("byteCount")
        guard byteCount > 0 else {
            throw NotesDomainError.invalidPayload("editBatchSize")
        }
        guard byteCount <= Self.maximumStagedEditBatchBytes else {
            throw NotesDomainError.requestTooLarge
        }
        let title = try payload.stringOrNil("title") ?? "Notes edit"
        guard !title.isEmpty, title.utf8.count <= 512 else {
            throw NotesDomainError.invalidPayload("invalidTitle")
        }
        // A whole-plan stage must carry the durable receipt identity: an
        // uncertain retry is reconciled by that exact id, never as a new
        // intent. The Kotlin adapter always supplies one.
        let requestID = try payload.string("requestID")
        guard requestID.utf8.count <= 256 else {
            throw NotesDomainError.invalidPayload("invalidRequestID")
        }
        let conversationID = try payload.uuidOrNil("conversationID")
        let resolvingConflictID = try payload.uuidOrNil("resolvingConflictID")
        let reviewedCopyID = try payload.uuidOrNil("reviewedCopyID")
        let reviewedCopyRevision = try payload.intOrNil("reviewedCopyRevision")
        // Fail fast on authority shapes that `document.apply` also refuses;
        // the commit repeats these checks so a changed code path cannot bypass
        // them.
        guard resolvingConflictID == nil && reviewedCopyID == nil && reviewedCopyRevision == nil
            || resolvingConflictID != nil && reviewedCopyID != nil && reviewedCopyRevision != nil else {
            throw NotesDomainError.invalidPayload("conflictResolutionIncomplete")
        }
        let hasConflictResolution = resolvingConflictID != nil
        if hasConflictResolution, conversationID != nil {
            throw NotesDomainError.invalidPayload("conflictResolutionUiOnly")
        }
        if baseRevision != nil, conversationID != nil {
            throw NotesDomainError.invalidPayload("rebaseIsUiOnly")
        }
        if baseRevision != nil, hasConflictResolution {
            throw NotesDomainError.invalidPayload("conflictResolutionUiOnly")
        }
        let store = try requireStore()
        // Early existence/deletion check only; the expected revision is
        // revalidated against the live store inside the commit transaction.
        let document = try await store.document(documentID)
        guard document.deletedAt == nil else { throw NoteError.notFound }

        pruneEditBatchStages()
        guard editBatchStages.count < Self.maximumEditBatchStages else {
            throw NotesDomainError.busy
        }
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let stageID = UUID().uuidString
        let url = incomingRoot.appendingPathComponent(".editbatch-\(stageID).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NotesDomainError.storageUnavailable
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            editBatchStages[stageID] = NotesEditBatchStage(
                stageID: stageID,
                rootPath: incomingRoot.standardizedFileURL.path,
                documentID: documentID,
                expectedRevision: expectedRevision,
                baseRevision: baseRevision,
                title: title,
                requestID: requestID,
                conversationID: conversationID,
                resolvingConflictID: resolvingConflictID,
                reviewedCopyID: reviewedCopyID,
                reviewedCopyRevision: reviewedCopyRevision,
                expectedBytes: byteCount,
                url: url,
                handle: handle,
                receivedBytes: 0,
                createdAt: Date(),
                committedResult: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw NotesDomainError.storageUnavailable
        }
        return success(["stageID": stageID,
                        "chunkBytes": NotesWire.maximumChunkBytes,
                        "totalBytes": byteCount,
                        "documentID": documentID.uuidString])
    }

    func editBatchStageAppend(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        let offset = try payload.int64("offset")
        guard var stage = editBatchStages[stageID], stage.committedResult == nil else {
            throw NotesDomainError.stageNotFound
        }
        guard stage.rootPath == incomingRoot.standardizedFileURL.path else {
            throw NotesDomainError.stageNotFound
        }
        // Exact offset, not "whatever arrived": a retried/reordered chunk can
        // never duplicate or skip bytes in the staged plan.
        guard offset == stage.receivedBytes else {
            throw NotesDomainError.invalidPayload("stageOffsetMismatch")
        }
        guard let data = Data(base64Encoded: try payload.string("dataBase64")),
              !data.isEmpty else {
            throw NotesDomainError.invalidPayload("invalidBase64")
        }
        guard data.count <= NotesWire.maximumChunkBytes else {
            throw NotesDomainError.requestTooLarge
        }
        guard stage.receivedBytes + Int64(data.count) <= stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("stageOverflow")
        }
        if stage.handle == nil {
            do {
                let reopened = try FileHandle(forWritingTo: stage.url)
                try reopened.seek(toOffset: UInt64(stage.receivedBytes))
                stage.handle = reopened
                editBatchStages[stageID] = stage
            } catch {
                throw NotesDomainError.storageUnavailable
            }
        }
        guard let handle = stage.handle else {
            throw NotesDomainError.stageNotFound
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw NotesDomainError.storageUnavailable
        }
        stage.receivedBytes += Int64(data.count)
        editBatchStages[stageID] = stage
        return success(["stageID": stageID,
                        "receivedBytes": stage.receivedBytes,
                        "totalBytes": stage.expectedBytes])
    }

    func editBatchStageCommit(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = editBatchStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        // A replay of an already committed stage returns the exact stored
        // result; it never applies the plan again.
        if let committed = stage.committedResult {
            return committed
        }
        guard stage.rootPath == incomingRoot.standardizedFileURL.path else {
            throw NotesDomainError.stageNotFound
        }
        // Keep the writer open on an incomplete commit: the remaining bytes
        // can still be appended and committed, so a slow upload is never
        // turned into a partial save.
        guard stage.receivedBytes == stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("incompleteEditBatch")
        }
        if let handle = stage.handle {
            try? handle.close()
            stage.handle = nil
            editBatchStages[stageID] = stage
        }
        let data: Data
        do {
            data = try Data(contentsOf: stage.url)
        } catch {
            throw NotesDomainError.storageUnavailable
        }
        guard data.count == stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("incompleteEditBatch")
        }
        // Strict, complete parse. The uploaded bytes are exactly one JSON
        // edit array; no caller-selected operation, path, store or grant
        // metadata is taken from this file.
        let decoded: NotesJSONValue
        do {
            decoded = try NotesWire.decode(NotesJSONValue.self, from: data)
        } catch {
            throw NotesDomainError.invalidPayload("editBatchNotJSON")
        }
        guard decoded.arrayValue != nil else {
            throw NotesDomainError.invalidPayload("editBatchNotArray")
        }
        // Reuses the one closed decoder (22 variants, 1...10,000 edits).
        let edits = try NotesEditWire.decode(decoded)
        // Parse and structural validation of the whole plan finishes before
        // this call; the store then applies every edit in one transaction or
        // none of them.
        let updated = try await applyEditBatch(
            documentID: stage.documentID,
            expectedRevision: stage.expectedRevision,
            title: stage.title,
            edits: edits,
            requestID: stage.requestID,
            baseRevision: stage.baseRevision,
            conversationID: stage.conversationID,
            resolvingConflictID: stage.resolvingConflictID,
            reviewedCopyID: stage.reviewedCopyID,
            reviewedCopyRevision: stage.reviewedCopyRevision)
        let result = try successEncoded("document", updated)
        try? FileManager.default.removeItem(at: stage.url)
        stage.handle = nil
        stage.committedResult = result
        editBatchStages[stageID] = stage
        return result
    }

    func editBatchStageAbort(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        if let stage = editBatchStages.removeValue(forKey: stageID) {
            try? stage.handle?.close()
            // Only this engine's own staging file; a committed stage has
            // already removed it and keeps only its in-memory replay result.
            try? FileManager.default.removeItem(at: stage.url)
        }
        return success(["stageID": stageID])
    }

    private func pruneEditBatchStages() {
        let cutoff = Date().addingTimeInterval(-Self.editBatchStageLifetime)
        for (key, stage) in Array(editBatchStages) {
            guard stage.createdAt < cutoff else { continue }
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
            editBatchStages.removeValue(forKey: key)
        }
    }
}
