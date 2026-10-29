// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native authority — immutable resource and portable archive
// transfer. Every binary enters through a service-owned staging file, is
// copied into the store's content-addressed Resources directory by the real
// NotesStore import path, and is exposed back only as bounded chunks.
import Foundation
import FloeNotes

extension NotesEngine {
    // MARK: - Resource import / read

    func resourceImportBegin(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let fileName = try Self.sanitizedFileName(payload.string("fileName"))
        let mediaType = try payload.string("mediaType")
        guard mediaType.utf8.count <= 256 else {
            throw NotesDomainError.invalidPayload("mediaTypeTooLong")
        }
        let expected = try payload.int64("byteCount")
        guard expected > 0, expected <= NotesWire.maximumResourceBytes else {
            throw NotesDomainError.invalidPayload("resourceSize")
        }
        // Optional assistant ownership pair. Both or neither: a stage owned by
        // one conversation/document is the capability that lets a later
        // assistant edit reference the imported resource.
        let ownerConversationID = try payload.uuidOrNil("conversationID")
        let ownerDocumentID = try payload.uuidOrNil("documentID")
        guard (ownerConversationID == nil) == (ownerDocumentID == nil) else {
            throw NotesDomainError.invalidPayload("resourceOwnerPair")
        }
        if let ownerConversationID, let ownerDocumentID {
            try await requireStore().authorize(conversationID: ownerConversationID,
                                               documentID: ownerDocumentID, editing: true)
        }
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let stageID = UUID().uuidString
        let url = incomingRoot.appendingPathComponent(".import-\(stageID).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NotesDomainError.storageUnavailable
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            importStages[stageID] = ResourceImportStage(
                id: UUID(uuidString: stageID) ?? UUID(), fileName: fileName,
                mediaType: mediaType, expectedBytes: expected, url: url,
                handle: handle, receivedBytes: 0,
                ownerConversationID: ownerConversationID,
                ownerDocumentID: ownerDocumentID)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw NotesDomainError.storageUnavailable
        }
        return success(["stageID": stageID,
                        "chunkBytes": NotesWire.maximumChunkBytes,
                        "totalBytes": expected])
    }

    func resourceImportAppend(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = importStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        if stage.handle == nil {
            do {
                let reopened = try FileHandle(forWritingTo: stage.url)
                try reopened.seek(toOffset: UInt64(stage.receivedBytes))
                stage.handle = reopened
                importStages[stageID] = stage
            } catch {
                throw NotesDomainError.storageUnavailable
            }
        }
        guard let handle = stage.handle else {
            throw NotesDomainError.stageNotFound
        }
        let encoded = try payload.string("dataBase64")
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
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
        importStages[stageID] = stage
        return success(["stageID": stageID,
                        "receivedBytes": stage.receivedBytes,
                        "totalBytes": stage.expectedBytes])
    }

    func resourceImportCommit(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = importStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        guard stage.receivedBytes == stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("incompleteImport")
        }
        if let handle = stage.handle {
            try? handle.close()
            stage.handle = nil
            importStages[stageID] = stage
        }
        let store = try requireStore()
        // A revocation that lands between staging and commit wins: no new
        // owned resource is created for a conversation that lost its grant.
        if let conversation = stage.ownerConversationID, let document = stage.ownerDocumentID {
            try await store.authorize(conversationID: conversation,
                                      documentID: document, editing: true)
        }
        do {
            let resourceID = try await store.importResource(from: stage.url,
                                                            mediaType: stage.mediaType)
            let record = try await store.resourceRecord(resourceID)
            if let conversation = stage.ownerConversationID, let document = stage.ownerDocumentID {
                recordAuthorityImport(resourceID: resourceID,
                                      conversationID: conversation, documentID: document)
            }
            try? FileManager.default.removeItem(at: stage.url)
            importStages.removeValue(forKey: stageID)
            var object: [String: Any] = [
                "resourceID": record.id.uuidString,
                "mediaType": record.mediaType,
                "byteCount": record.byteCount,
                "fileName": record.fileName,
                "sha256": record.hash,
            ]
            object["ok"] = true
            return NotesWire.data(from: object)
        } catch {
            // The staged bytes remain available for a retry. Nothing was
            // registered by a failed import; a partial CAS file is never
            // exposed because NotesStore promotes before registration.
            throw error
        }
    }

    func resourceImportAbort(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        if let stage = importStages.removeValue(forKey: stageID) {
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
        }
        return success(["stageID": stageID])
    }

    func resourceMetadata(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("resourceID")
        let record = try await requireStore().resourceRecord(id)
        return try successEncoded("resource", record)
    }

    func resourceRead(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("resourceID")
        let offset = try payload.int64("offset")
        let maxBytes = min(NotesWire.maximumReadBytes,
                           max(1, try payload.intOrNil("maxBytes") ?? NotesWire.defaultReadBytes))
        guard offset >= 0 else { throw NotesDomainError.invalidPayload("negativeOffset") }
        let store = try requireStore()
        let conversationID = try payload.uuidOrNil("conversationID")
        if let conversationID {
            let documentID = try payload.uuidOrNil("documentID")
            let owned: Set<UUID>
            if let documentID {
                owned = authorityOwnedResources(conversationID: conversationID,
                                                documentID: documentID)
            } else {
                owned = authorityOwnedResources(conversationID: conversationID)
            }
            try await store.authorizeResourceRead(
                resourceID: id, conversationID: conversationID,
                documentID: documentID, ownedByCaller: owned)
        }
        let url = try await store.resourceURL(id)
        let total = try Self.fileSize(url)
        if offset >= total {
            return success(["resourceID": id.uuidString,
                            "offset": offset, "nextOffset": total,
                            "totalBytes": total, "eof": true,
                            "dataBase64": ""])
        }
        let data = try Self.readChunk(url, offset: UInt64(offset), maxBytes: maxBytes)
        return success(["resourceID": id.uuidString,
                        "offset": offset,
                        "nextOffset": offset + Int64(data.count),
                        "totalBytes": total,
                        "eof": offset + Int64(data.count) >= total,
                        "dataBase64": data.base64EncodedString()])
    }

    func resourceDiscard(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("resourceID")
        let removed = try await requireStore().discardUnreferencedResource(id)
        if removed { recordChange(kind: "resource.discarded") }
        return success(["resourceID": id.uuidString, "removed": removed])
    }

    func resourcesCollect(_ payload: NotesJSONValue?) async throws -> Data {
        _ = try NotesPayload(payload)
        let removed = try await requireStore().collectDeletedResources()
        if removed > 0 { recordChange(kind: "resources.collected") }
        return success(["removed": removed])
    }

    // MARK: - Portable archive

    func archiveExport(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let documentID = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let document = try await store.document(documentID)
        guard document.revision == expectedRevision, document.deletedAt == nil else {
            throw NoteError.conflict
        }
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        let handle = UUID().uuidString
        let url = exportsRoot.appendingPathComponent("\(handle).floenote")
        try? FileManager.default.removeItem(at: url)
        try await NotesArchive.export(document: document, store: store, to: url)
        let size = try Self.fileSize(url)
        archiveExports[handle] = (url, size)
        return success(["handle": handle,
                        "byteCount": size,
                        "fileName": Self.archiveName(document.title)])
    }

    func archiveExportRead(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let handle = try payload.string("handle")
        guard let exported = archiveExports[handle] else {
            throw NotesDomainError.stageNotFound
        }
        let offset = try payload.int64("offset")
        let maxBytes = min(NotesWire.maximumReadBytes,
                           max(1, try payload.intOrNil("maxBytes") ?? NotesWire.defaultReadBytes))
        guard offset >= 0 else { throw NotesDomainError.invalidPayload("negativeOffset") }
        if offset >= exported.byteCount {
            return success(["handle": handle, "offset": offset,
                            "nextOffset": exported.byteCount,
                            "totalBytes": exported.byteCount,
                            "eof": true, "dataBase64": ""])
        }
        let data = try Self.readChunk(exported.url, offset: UInt64(offset), maxBytes: maxBytes)
        return success(["handle": handle,
                        "offset": offset,
                        "nextOffset": offset + Int64(data.count),
                        "totalBytes": exported.byteCount,
                        "eof": offset + Int64(data.count) >= exported.byteCount,
                        "dataBase64": data.base64EncodedString()])
    }

    func archiveExportClose(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let handle = try payload.string("handle")
        if let exported = archiveExports.removeValue(forKey: handle) {
            try? FileManager.default.removeItem(at: exported.url)
        }
        return success(["handle": handle])
    }

    func archiveImportBegin(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let expected = try payload.int64("byteCount")
        guard expected > 0, expected <= NotesWire.maximumArchiveBytes else {
            throw NotesDomainError.invalidPayload("archiveSize")
        }
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let stageID = UUID().uuidString
        let url = incomingRoot.appendingPathComponent(".archive-\(stageID).part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NotesDomainError.storageUnavailable
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            archiveImportStages[stageID] = ResourceImportStage(
                id: UUID(uuidString: stageID) ?? UUID(), fileName: "archive.floenote",
                mediaType: "application/octet-stream", expectedBytes: expected,
                url: url, handle: handle, receivedBytes: 0)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw NotesDomainError.storageUnavailable
        }
        return success(["stageID": stageID,
                        "chunkBytes": NotesWire.maximumChunkBytes,
                        "totalBytes": expected])
    }

    func archiveImportAppend(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = archiveImportStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        if stage.handle == nil {
            do {
                let reopened = try FileHandle(forWritingTo: stage.url)
                try reopened.seek(toOffset: UInt64(stage.receivedBytes))
                stage.handle = reopened
                archiveImportStages[stageID] = stage
            } catch {
                throw NotesDomainError.storageUnavailable
            }
        }
        guard let handle = stage.handle else {
            throw NotesDomainError.stageNotFound
        }
        let encoded = try payload.string("dataBase64")
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
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
        archiveImportStages[stageID] = stage
        return success(["stageID": stageID,
                        "receivedBytes": stage.receivedBytes,
                        "totalBytes": stage.expectedBytes])
    }

    func archiveImportCommit(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        guard var stage = archiveImportStages[stageID] else {
            throw NotesDomainError.stageNotFound
        }
        guard stage.receivedBytes == stage.expectedBytes else {
            throw NotesDomainError.invalidPayload("incompleteImport")
        }
        if let handle = stage.handle {
            try? handle.close()
            stage.handle = nil
            archiveImportStages[stageID] = stage
        }
        let store = try requireStore()
        do {
            let imported = try await NotesArchive.importDocuments(
                from: stage.url,
                notebookID: try payload.uuidOrNil("notebookID"),
                store: store)
            try? FileManager.default.removeItem(at: stage.url)
            archiveImportStages.removeValue(forKey: stageID)
            for document in imported {
                recordChange(kind: "document.created",
                             documentID: document.id, revision: document.revision)
            }
            return try successEncoded("documents", imported.map { summary($0) })
        } catch {
            // Keep the exact downloaded bytes for retry; nothing partial is
            // published because the importer verifies before createBundle.
            throw error
        }
    }

    func archiveImportAbort(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let stageID = try payload.string("stageID")
        if let stage = archiveImportStages.removeValue(forKey: stageID) {
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
        }
        return success(["stageID": stageID])
    }

    // MARK: - Bounded file helpers

    static func sanitizedFileName(_ raw: String) throws -> String {
        let name = (raw as NSString).lastPathComponent
        guard name == raw, !name.isEmpty, name != ".", name != "..",
              !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 255 else {
            throw NotesDomainError.invalidPayload("invalidFileName")
        }
        return name
    }

    static func archiveName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "notes" : String(trimmed.prefix(80))
        let safe = base.map { character -> Character in
            if "/\\:\0".contains(character) || character.isNewline { return "-" }
            return character
        }
        return String(safe) + ".floenote"
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw NoteError.resourceUnavailable
        }
        return Int64(size)
    }

    static func readChunk(_ url: URL, offset: UInt64, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: maxBytes), !data.isEmpty else {
            throw NoteError.resourceUnavailable
        }
        return data
    }
}
