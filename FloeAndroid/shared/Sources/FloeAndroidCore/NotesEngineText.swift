// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native authority — staged large-text writes.
//
// The bridge request bound is 64 KiB, but a legitimate paste or text import
// can be much larger. This lane stages the exact UTF-8 bytes in a
// service-owned file, then commits ONE ordinary NoteEditBatch (or one
// document create) so the user gets one undoable transaction. It never
// truncates: commit requires the exact declared byte count and strict UTF-8.
import Foundation
import FloeNotes

struct NotesTextStage {
    let mode: String
    let documentID: UUID?
    let pageID: UUID?
    let elementID: UUID?
    let expectedRevision: Int?
    let baseRevision: Int?
    let title: String
    let notebookID: UUID?
    let newDocumentID: UUID?
    let frame: NoteRect?
    let textFormat: String?
    let fontSize: Double
    let requestID: String?
    let expectedBytes: Int64
    let url: URL
    var handle: FileHandle?
    var receivedBytes: Int64
    let createdAt: Date
    var committedResult: Data?
}

extension NotesEngine {
    static let maximumStagedTextBytes: Int64 = 2_097_152
    private static let maximumTextStages = 16
    private static let committedStageLifetime: TimeInterval = 600

    func textStageBegin(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let mode = try payload.string("mode")
        guard ["appendBlock", "replaceElement", "newDocument"].contains(mode) else {
            throw NotesDomainError.invalidPayload("unknownTextWriteMode")
        }
        let expected = try payload.int64("byteCount")
        guard expected > 0, expected <= Self.maximumStagedTextBytes else {
            throw NotesDomainError.invalidPayload("textSize")
        }
        let title = try payload.stringOrNil("title") ?? "Text"
        guard title.utf8.count <= 512 else {
            throw NotesDomainError.invalidPayload("titleTooLong")
        }
        let textFormat = try payload.stringOrNil("textFormat")
        if let textFormat, !["plain", "markdown"].contains(textFormat) {
            throw NotesDomainError.invalidPayload("unknownTextFormat")
        }
        let fontSize = try payload.doubleOrNil("fontSize") ?? 16
        guard fontSize.isFinite, (1...512).contains(fontSize) else {
            throw NotesDomainError.invalidPayload("invalidFontSize")
        }
        let frame = try payload.decodeOrNil(NoteRect.self, key: "frame")
        if let frame, !frame.isValid {
            throw NotesDomainError.invalidPayload("invalidFrame")
        }
        let notebookID = try payload.uuidOrNil("notebookID")
        let requestID = try payload.stringOrNil("requestID")

        let documentID: UUID?
        let pageID: UUID?
        let elementID: UUID?
        let expectedRevision: Int?
        let baseRevision: Int?
        let newDocumentID: UUID?
        let store = try requireStore()

        switch mode {
        case "appendBlock":
            documentID = try payload.uuid("documentID")
            pageID = try payload.uuid("pageID")
            elementID = nil
            expectedRevision = try payload.int("expectedRevision")
            baseRevision = try payload.intOrNil("baseRevision")
            newDocumentID = nil
            let resolvedDocumentID = try requireValue(documentID)
            let resolvedPageID = try requireValue(pageID)
            let document = try await store.document(resolvedDocumentID)
            guard document.deletedAt == nil else { throw NoteError.notFound }
            guard document.pages.contains(where: { $0.id == resolvedPageID }) else { throw NoteError.notFound }
        case "replaceElement":
            documentID = try payload.uuid("documentID")
            pageID = try payload.uuid("pageID")
            elementID = try payload.uuid("elementID")
            expectedRevision = try payload.int("expectedRevision")
            baseRevision = try payload.intOrNil("baseRevision")
            newDocumentID = nil
            guard let lookupRevision = baseRevision ?? expectedRevision,
                  lookupRevision >= 0 else {
                throw NotesDomainError.invalidPayload("invalidExpectedRevision")
            }
            let resolvedDocumentID = try requireValue(documentID)
            let resolvedPageID = try requireValue(pageID)
            let resolvedElementID = try requireValue(elementID)
            guard let snapshot = try await store.editingSnapshot(resolvedDocumentID,
                                                                 revision: lookupRevision),
                  snapshot.deletedAt == nil,
                  let page = snapshot.pages.first(where: { $0.id == resolvedPageID }),
                  let element = page.elements.first(where: { $0.id == resolvedElementID }),
                  element.kind == .text else {
                throw NoteError.notFound
            }
            guard element.textSourceID == nil else {
                throw NoteError.invalidOperation("formattedTextRequiresLayout")
            }
        case "newDocument":
            documentID = nil
            pageID = nil
            elementID = nil
            expectedRevision = nil
            baseRevision = nil
            newDocumentID = try payload.uuidOrNil("newDocumentID")
        default:
            throw NotesDomainError.invalidPayload("unknownTextWriteMode")
        }
        if let expectedRevision, expectedRevision < 0 {
            throw NotesDomainError.invalidPayload("invalidExpectedRevision")
        }
        if let baseRevision, baseRevision < 0 {
            throw NotesDomainError.invalidPayload("invalidBaseRevision")
        }

        pruneTextStages()
        guard textStages.count < Self.maximumTextStages else {
            throw NotesDomainError.busy
        }
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let stageID = UUID().uuidString
        let url = incomingRoot.appendingPathComponent(".text-\(stageID).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NotesDomainError.storageUnavailable
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            textStages[stageID] = NotesTextStage(
                mode: mode, documentID: documentID, pageID: pageID,
                elementID: elementID, expectedRevision: expectedRevision,
                baseRevision: baseRevision, title: title, notebookID: notebookID,
                newDocumentID: newDocumentID, frame: frame, textFormat: textFormat,
                fontSize: fontSize, requestID: requestID, expectedBytes: expected,
                url: url, handle: handle, receivedBytes: 0, createdAt: Date(),
                committedResult: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw NotesDomainError.storageUnavailable
        }
        return success(["stageID": stageID,
                        "chunkBytes": NotesWire.maximumChunkBytes,
                        "totalBytes": expected,
                        "mode": mode])
    }

    func textStageAppend(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = textStages[stageID], stage.committedResult == nil else {
            throw NotesDomainError.stageNotFound
        }
        if stage.handle == nil {
            do {
                let reopened = try FileHandle(forWritingTo: stage.url)
                try reopened.seek(toOffset: UInt64(stage.receivedBytes))
                stage.handle = reopened
                textStages[stageID] = stage
            } catch {
                throw NotesDomainError.storageUnavailable
            }
        }
        guard let handle = stage.handle else {
            throw NotesDomainError.stageNotFound
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
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw NotesDomainError.storageUnavailable
        }
        stage.receivedBytes += Int64(data.count)
        textStages[stageID] = stage
        return success(["stageID": stageID,
                        "receivedBytes": stage.receivedBytes,
                        "totalBytes": stage.expectedBytes])
    }

    func textStageCommit(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = textStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        if let committed = stage.committedResult {
            return committed
        }
        // Do not close the writer before the completeness check: an
        // incomplete commit is recoverable by appending the remaining bytes.
        guard stage.receivedBytes == stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("incompleteImport")
        }
        if let handle = stage.handle {
            try? handle.close()
            stage.handle = nil
            textStages[stageID] = stage
        }
        let data: Data
        do {
            data = try Data(contentsOf: stage.url)
        } catch {
            throw NotesDomainError.storageUnavailable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NotesDomainError.invalidPayload("textIsNotUTF8")
        }
        let store = try requireStore()

        let result: Data
        switch stage.mode {
        case "newDocument":
            let id = stage.newDocumentID ?? UUID()
            if let existing = try? await store.document(id) {
                result = try successEncoded("document", existing)
            } else {
                var document = NoteDocument(id: id, kind: .notebook,
                                            notebookID: stage.notebookID, title: stage.title)
                var page = document.pages[0]
                var element = NoteElement(kind: .text,
                                          frame: stage.frame ?? NoteRect(x: 64, y: 64,
                                                                        width: 640, height: 400),
                                          text: text, fontSize: stage.fontSize)
                element.textFormat = stage.textFormat
                page.elements = [element]
                document.pages[0] = page
                let stored = try await store.create(document)
                recordChange(kind: "document.created", documentID: stored.id,
                             revision: stored.revision)
                result = try successEncoded("document", stored)
            }
        case "appendBlock":
            guard let documentID = stage.documentID, let pageID = stage.pageID,
                  let expectedRevision = stage.expectedRevision else {
                throw NotesDomainError.invalidPayload("stageIdentity")
            }
            var element = NoteElement(kind: .text,
                                      frame: stage.frame ?? NoteRect(x: 64, y: 64,
                                                                    width: 640, height: 400),
                                      text: text, fontSize: stage.fontSize)
            element.textFormat = stage.textFormat
            result = try await applyStagedEdit(
                .upsertElement(pageID: pageID, element: element),
                documentID: documentID, expectedRevision: expectedRevision,
                baseRevision: stage.baseRevision, title: stage.title,
                requestID: stage.requestID)
        case "replaceElement":
            guard let documentID = stage.documentID, let pageID = stage.pageID,
                  let elementID = stage.elementID,
                  let expectedRevision = stage.expectedRevision else {
                throw NotesDomainError.invalidPayload("stageIdentity")
            }
            let lookupRevision = stage.baseRevision ?? expectedRevision
            guard lookupRevision >= 0 else {
                throw NotesDomainError.invalidPayload("invalidExpectedRevision")
            }
            guard let snapshot = try await store.editingSnapshot(documentID, revision: lookupRevision),
                  snapshot.deletedAt == nil,
                  let page = snapshot.pages.first(where: { $0.id == pageID }),
                  var element = page.elements.first(where: { $0.id == elementID }),
                  element.kind == .text else {
                throw NoteError.notFound
            }
            guard element.textSourceID == nil else {
                throw NoteError.invalidOperation("formattedTextRequiresLayout")
            }
            element.text = text
            if let frame = stage.frame { element.frame = frame }
            result = try await applyStagedEdit(
                .upsertElement(pageID: pageID, element: element),
                documentID: documentID, expectedRevision: expectedRevision,
                baseRevision: stage.baseRevision, title: stage.title,
                requestID: stage.requestID)
        default:
            throw NotesDomainError.invalidPayload("unknownTextWriteMode")
        }

        try? FileManager.default.removeItem(at: stage.url)
        stage.handle = nil
        stage.committedResult = result
        textStages[stageID] = stage
        return result
    }

    func textStageAbort(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        if let stage = textStages.removeValue(forKey: stageID) {
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
        }
        return success(["stageID": stageID])
    }

    private func applyStagedEdit(_ edit: NoteEdit, documentID: UUID,
                                 expectedRevision: Int, baseRevision: Int?,
                                 title: String, requestID: String?) async throws -> Data {
        let store = try requireStore()
        let batch = NoteEditBatch(documentID: documentID,
                                  expectedRevision: expectedRevision,
                                  title: title, edits: [edit],
                                  requestID: requestID)
        let updated: NoteDocument
        if let baseRevision {
            guard let base = try await store.editingSnapshot(documentID, revision: baseRevision) else {
                throw NoteError.conflict
            }
            updated = try await store.applyRebased(batch, base: base)
        } else {
            updated = try await store.apply(batch)
        }
        recordChange(kind: "document.updated", documentID: updated.id,
                     revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func pruneTextStages() {
        let cutoff = Date().addingTimeInterval(-Self.committedStageLifetime)
        for (key, stage) in Array(textStages) {
            let removable = stage.createdAt < cutoff
            guard removable else { continue }
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
            textStages.removeValue(forKey: key)
        }
    }

    private func requireValue<T>(_ value: T?) throws -> T {
        guard let value else { throw NotesDomainError.invalidPayload("stageIdentity") }
        return value
    }
}
