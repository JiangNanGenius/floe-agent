// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native authority — one engine owns one real FloeNotes store.
//
// Authority boundaries:
//   * The store root is derived from the accepted runtime generation root
//     (`<root>/FloeAgent/Notes`) and never from a request.
//   * The engine performs no chat/conversation writes. Assistant grants live
//     only inside the Notes database; deleting a chat cannot address this DB.
//   * No Kotlin notes database and no in-memory production fallback exists.
//   * Binary resources and archives are staged in the service-owned root and
//     transferred in explicit bounded chunks.
import Foundation
import Crypto
import FloeCore
import FloeNotes

struct NotesChange: Sendable {
    let sequence: UInt64
    let kind: String
    let documentID: UUID?
    let revision: Int?
}

struct NoteDocumentSummary: Encodable {
    let id: UUID
    let kind: NoteDocument.Kind
    let notebookID: UUID?
    let title: String
    let revision: Int
    let pageCount: Int
    let nodeCount: Int
    let tags: [String]
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let coverResourceID: UUID?
    let coverRevision: Int?
    let officeFileName: String?
    let engineeringFileName: String?
    let preview: String
}

struct ResourceImportStage {
    let id: UUID
    let fileName: String
    let mediaType: String
    let expectedBytes: Int64
    let url: URL
    var handle: FileHandle?
    var receivedBytes: Int64
}

actor NotesEngine {
    let root: URL
    let resourcesRoot: URL
    let incomingRoot: URL
    let exportsRoot: URL
    var store: NotesStore?

    private(set) var changeSequence: UInt64 = 0
    private var changeLog: [NotesChange] = []
    private let maximumChangeLog = 512

    private var idempotency: [String: Data] = [:]
    private var idempotencyOrder: [String] = []
    private var idempotencyBytes = 0
    private let maximumIdempotencyEntries = 256
    private let maximumIdempotencyBytes = 33_554_432
    private let maximumIdempotentResultBytes = 8_388_608

    var importStages: [String: ResourceImportStage] = [:]
    var archiveImportStages: [String: ResourceImportStage] = [:]
    var archiveExports: [String: (url: URL, byteCount: Int64)] = [:]
    var textStages: [String: NotesTextStage] = [:]

    private let proposalStore: NoteProposalStore

    init(root: URL) throws {
        let standardized = root.standardizedFileURL
        self.root = standardized
        self.resourcesRoot = standardized.appendingPathComponent("Resources", isDirectory: true)
        self.incomingRoot = standardized.appendingPathComponent("Incoming", isDirectory: true)
        self.exportsRoot = standardized.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        self.proposalStore = NoteProposalStore(root: standardized.appendingPathComponent("Proposals", isDirectory: true))
        self.store = try NotesStore(root: standardized)
        Self.cleanupStaging(incomingRoot)
        Self.cleanupStaging(exportsRoot)
    }

    /// Drops the owned store and removes only this process's incomplete
    /// staging files. Durable documents/resources remain untouched.
    func retire() {
        for (_, stage) in importStages { try? stage.handle?.close(); try? FileManager.default.removeItem(at: stage.url) }
        for (_, stage) in archiveImportStages { try? stage.handle?.close(); try? FileManager.default.removeItem(at: stage.url) }
        for (_, stage) in textStages {
            try? stage.handle?.close()
            try? FileManager.default.removeItem(at: stage.url)
        }
        for (_, exported) in archiveExports { try? FileManager.default.removeItem(at: exported.url) }
        importStages.removeAll()
        archiveImportStages.removeAll()
        textStages.removeAll()
        archiveExports.removeAll()
        store = nil
    }

    func isOpen() -> Bool { store != nil }

    private static func cleanupStaging(_ directory: URL) {
        let cutoff = Date().addingTimeInterval(-86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return }
        for entry in entries.prefix(1_000) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func requireStore() throws -> NotesStore {
        guard let store else { throw NotesDomainError.storageUnavailable }
        return store
    }

    func success(_ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["ok"] = true
        return NotesWire.data(from: object)
    }

    func successEncoded<T: Encodable>(_ key: String, _ value: T,
                                              extra: [String: Any] = [:]) throws -> Data {
        let object = try encodedJSONValue(value)
        var fields = extra
        fields[key] = object
        return success(fields)
    }

    func recordChange(kind: String, documentID: UUID? = nil, revision: Int? = nil) {
        changeSequence &+= 1
        changeLog.append(NotesChange(sequence: changeSequence, kind: kind,
                                     documentID: documentID, revision: revision))
        if changeLog.count > maximumChangeLog {
            changeLog.removeFirst(changeLog.count - maximumChangeLog)
        }
    }

    private func cache(_ data: Data, key: String) {
        guard data.count <= maximumIdempotentResultBytes else { return }
        if let previous = idempotency.removeValue(forKey: key) {
            idempotencyBytes -= previous.count
            idempotencyOrder.removeAll { $0 == key }
        }
        idempotency[key] = data
        idempotencyOrder.append(key)
        idempotencyBytes += data.count
        while idempotencyOrder.count > maximumIdempotencyEntries
            || idempotencyBytes > maximumIdempotencyBytes {
            guard let oldest = idempotencyOrder.first else { break }
            idempotencyOrder.removeFirst()
            if let removed = idempotency.removeValue(forKey: oldest) {
                idempotencyBytes -= removed.count
            }
        }
    }

    private static let mutatingActions: Set<String> = [
        "notebook.create", "notebook.rename", "notebook.delete",
        "document.create", "document.duplicate", "document.saveMessage",
        "document.createLinkedMindMap", "document.apply", "document.undo",
        "document.setTrashed", "document.permanentlyDelete", "document.markOpened",
        "document.setFavorite", "document.setTags", "document.coverApply",
        "document.cacheOfficePreview", "resource.importCommit",
        "resource.discardUnreferenced", "resources.collectDeleted",
        "assistant.grantAccess", "assistant.revokeAccess", "assistant.setFocus",
        "assistant.bind", "archive.importCommit",
        "text.stageBegin", "text.stageAppend", "text.stageCommit", "text.stageAbort",
    ]

    func perform(requestID: String, action: String, payload: NotesJSONValue?) async throws -> Data {
        let cacheKey = "\(action)#\(requestID)"
        if Self.mutatingActions.contains(action), let cached = idempotency[cacheKey] {
            return cached
        }
        let result: Data
        switch action {
        case "library.summary":
            result = try await librarySummary()
        case "poll":
            result = try poll(payload)
        case "notebook.list":
            result = try await notebookList()
        case "notebook.create":
            result = try await notebookCreate(payload)
        case "notebook.rename":
            result = try await notebookRename(payload)
        case "notebook.delete":
            result = try await notebookDelete(payload)
        case "document.list":
            result = try await documentList(payload)
        case "document.recent":
            result = try await documentRecent(payload)
        case "document.get":
            result = try await documentGet(payload)
        case "document.summary":
            result = try await documentSummary(payload)
        case "document.create":
            result = try await documentCreate(payload)
        case "document.duplicate":
            result = try await documentDuplicate(payload)
        case "document.saveMessage":
            result = try await documentSaveMessage(payload)
        case "document.createLinkedMindMap":
            result = try await documentCreateLinkedMindMap(payload)
        case "document.apply":
            result = try await documentApply(payload)
        case "document.undo":
            result = try await documentUndo(payload)
        case "document.setTrashed":
            result = try await documentSetTrashed(payload)
        case "document.permanentlyDelete":
            result = try await documentPermanentlyDelete(payload)
        case "document.history":
            result = try await documentHistory(payload)
        case "document.markOpened":
            result = try await documentMarkOpened(payload)
        case "document.setFavorite":
            result = try await documentSetFavorite(payload)
        case "document.setTags":
            result = try await documentSetTags(payload)
        case "document.coverRead":
            result = try await documentCoverRead(payload)
        case "document.coverApply":
            result = try await documentCoverApply(payload)
        case "document.cacheOfficePreview":
            result = try await documentCacheOfficePreview(payload)
        case "document.editingSnapshot":
            result = try await documentEditingSnapshot(payload)
        case "document.pageOCRState":
            result = try await documentPageOCRState(payload)
        case "search.query":
            result = try await searchQuery(payload)
        case "text.stageBegin":
            result = try await textStageBegin(payload)
        case "text.stageAppend":
            result = try await textStageAppend(payload)
        case "text.stageCommit":
            result = try await textStageCommit(payload)
        case "text.stageAbort":
            result = try await textStageAbort(payload)
        case "resource.importBegin":
            result = try await resourceImportBegin(payload)
        case "resource.importAppend":
            result = try await resourceImportAppend(payload)
        case "resource.importCommit":
            result = try await resourceImportCommit(payload)
        case "resource.importAbort":
            result = try await resourceImportAbort(payload)
        case "resource.metadata":
            result = try await resourceMetadata(payload)
        case "resource.read":
            result = try await resourceRead(payload)
        case "resource.discardUnreferenced":
            result = try await resourceDiscard(payload)
        case "resources.collectDeleted":
            result = try await resourcesCollect(payload)
        case "assistant.grantAccess":
            result = try await assistantGrant(payload, bind: false)
        case "assistant.bind":
            result = try await assistantGrant(payload, bind: true)
        case "assistant.revokeAccess":
            result = try await assistantRevoke(payload)
        case "assistant.grants":
            result = try await assistantGrants(payload)
        case "assistant.scopedDocuments":
            result = try await assistantScopedDocuments(payload)
        case "assistant.setFocus":
            result = try await assistantSetFocus(payload)
        case "assistant.runtimeContext":
            result = try await assistantRuntimeContext(payload)
        case "archive.export":
            result = try await archiveExport(payload)
        case "archive.exportRead":
            result = try await archiveExportRead(payload)
        case "archive.exportClose":
            result = try await archiveExportClose(payload)
        case "archive.importBegin":
            result = try await archiveImportBegin(payload)
        case "archive.importAppend":
            result = try await archiveImportAppend(payload)
        case "archive.importCommit":
            result = try await archiveImportCommit(payload)
        case "archive.importAbort":
            result = try await archiveImportAbort(payload)
        case "proposal.list":
            result = try await proposalList(payload)
        default:
            throw NotesDomainError.unsupportedAction(NotesWire.bounded(action, limit: 80))
        }
        if Self.mutatingActions.contains(action) { cache(result, key: cacheKey) }
        return result
    }

    // MARK: - Library

    func encodedJSONValue<T: Encodable>(_ value: T) throws -> Any {
        let data = try NotesWire.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func librarySummary() async throws -> Data {
        let store = try requireStore()
        let notebooks = try await store.notebooks()
        let all = try await store.documents(includeTrash: true)
        let live = all.filter { $0.deletedAt == nil }
        let recent = try await store.recentDocuments(limit: 20)
        let counts: [String: Any] = [
            "documents": live.count,
            "trashed": all.count - live.count,
            "favorites": live.filter(\.isFavorite).count,
            "notebooks": notebooks.count,
            "mindMaps": live.filter { $0.kind == .mindMap }.count,
            "office": live.filter { $0.kind == .office }.count,
            "engineering": live.filter { $0.kind == .engineering }.count,
        ]
        return try successEncoded("notebooks", notebooks, extra: [
            "counts": counts,
            "recent": try encodedJSONValue(recent.map { summary($0) }),
        ])
    }

    private func notebookList() async throws -> Data {
        let notebooks = try await requireStore().notebooks()
        return try successEncoded("notebooks", notebooks)
    }

    private func notebookCreate(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let title = try payload.string("title")
        let stored = try await requireStore().createNotebook(title: title)
        recordChange(kind: "notebook.created")
        return try successEncoded("notebook", stored)
    }

    private func notebookRename(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("notebookID")
        let title = try payload.string("title")
        try await requireStore().renameNotebook(id, title: title)
        recordChange(kind: "notebook.renamed")
        return success(["notebookID": id.uuidString, "title": title])
    }

    private func notebookDelete(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("notebookID")
        try await requireStore().deleteNotebook(id)
        recordChange(kind: "notebook.deleted")
        return success(["notebookID": id.uuidString])
    }

    private func documentList(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let includeTrash = try payload.boolOrNil("includeTrash") ?? false
        let limit = min(2_000, max(1, try payload.intOrNil("limit") ?? 500))
        let all = try await requireStore().documents(includeTrash: includeTrash)
        let values = all.prefix(limit).map { summary($0) }
        return try successEncoded("documents", Array(values),
                                  extra: ["truncated": all.count > limit, "total": all.count])
    }

    private func documentRecent(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let limit = min(200, max(1, try payload.intOrNil("limit") ?? 50))
        let values = try await requireStore().recentDocuments(limit: limit)
        return try successEncoded("documents", values.map { summary($0) })
    }

    private func documentGet(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let document = try await requireStore().document(id)
        return try successEncoded("document", document)
    }

    private func documentSummary(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let document = try await requireStore().document(id)
        return try successEncoded("document", summary(document))
    }

    private func documentCreate(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let kind = try Self.kind(payload.string("kind"))
        let title = try payload.string("title")
        let notebookID = try payload.uuidOrNil("notebookID")
        let explicitID = try payload.uuidOrNil("documentID")
        if let explicitID, let existing = try? await store.document(explicitID) {
            return try successEncoded("document", existing)
        }
        var document = NoteDocument(id: explicitID ?? UUID(), kind: kind,
                                    notebookID: notebookID, title: title)
        if let resourceID = try payload.uuidOrNil("resourceID") {
            let fileName = try payload.string("fileName")
            switch kind {
            case .office:
                document.officeResourceID = resourceID
                document.officeFileName = fileName
            case .engineering:
                document.engineeringResourceID = resourceID
                document.engineeringFileName = fileName
            default:
                throw NotesDomainError.invalidPayload("resourceRequiresOfficeOrEngineering")
            }
        }
        let stored = try await store.create(document)
        recordChange(kind: "document.created", documentID: stored.id, revision: stored.revision)
        return try successEncoded("document", stored)
    }

    private func documentDuplicate(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let sourceID = try payload.uuid("documentID")
        let newID = try payload.uuidOrNil("newDocumentID") ?? UUID()
        if let existing = try? await store.document(newID) {
            return try successEncoded("document", existing)
        }
        let source = try await store.document(sourceID)
        var copy = source
        copy.id = newID
        copy.revision = 0
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        copy.deletedAt = nil
        if let title = try payload.stringOrNil("title"), !title.isEmpty { copy.title = title }
        if let notebookID = try payload.uuidOrNil("notebookID") { copy.notebookID = notebookID }
        func remapSource(_ source: NoteSourceReference?) -> NoteSourceReference? {
            guard var value = source else { return nil }
            if value.space == .notes, value.documentID == sourceID {
                value.documentID = newID
                value.revision = 1
            }
            return value
        }
        for index in copy.pages.indices {
            for elementIndex in copy.pages[index].elements.indices {
                copy.pages[index].elements[elementIndex].source =
                    remapSource(copy.pages[index].elements[elementIndex].source)
            }
        }
        for index in copy.nodes.indices {
            copy.nodes[index].source = remapSource(copy.nodes[index].source)
            if var attachments = copy.nodes[index].attachments {
                for attachmentIndex in attachments.indices {
                    attachments[attachmentIndex].source = remapSource(attachments[attachmentIndex].source)
                }
                copy.nodes[index].attachments = attachments
            }
        }
        let stored = try await store.create(copy)
        recordChange(kind: "document.created", documentID: stored.id, revision: stored.revision)
        return try successEncoded("document", stored)
    }

    private func documentSaveMessage(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let text = try payload.string("text")
        guard text.utf8.count <= 1_048_576 else {
            throw NotesDomainError.invalidPayload("messageTooLarge")
        }
        let explicitID = try payload.uuidOrNil("documentID")
        if let explicitID, let existing = try? await store.document(explicitID) {
            return try successEncoded("document", existing)
        }
        let title = try payload.stringOrNil("title") ?? "Note"
        let notebookID = try payload.uuidOrNil("notebookID")
        var document = NoteDocument(id: explicitID ?? UUID(), kind: .notebook,
                                    notebookID: notebookID, title: title)
        var page = document.pages[0]
        page.elements = [NoteElement(kind: .text,
                                     frame: NoteRect(x: 64, y: 64, width: 640, height: 400),
                                     text: text, fontSize: 16)]
        document.pages[0] = page
        let stored = try await store.create(document)
        recordChange(kind: "document.created", documentID: stored.id, revision: stored.revision)
        return try successEncoded("document", stored)
    }

    private func documentCreateLinkedMindMap(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let parentID = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let title = try payload.string("title")
        let pageID = try payload.uuidOrNil("pageID")
        let map = try await store.createLinkedMindMap(parentID: parentID,
                                                      expectedRevision: expectedRevision,
                                                      title: title, pageID: pageID)
        recordChange(kind: "document.created", documentID: map.id, revision: map.revision)
        return try successEncoded("document", map)
    }

    private func documentApply(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let store = try requireStore()
        let id = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let title = try payload.stringOrNil("title") ?? "Notes edit"
        let requestID = try payload.stringOrNil("requestID")
        if let requestID, requestID.isEmpty {
            throw NotesDomainError.invalidPayload("emptyRequestID")
        }
        let edits = try NotesEditWire.decode(payload.raw("edits"))
        let conversationID = try payload.uuidOrNil("conversationID")
        let batch = NoteEditBatch(documentID: id, expectedRevision: expectedRevision,
                                  title: title, edits: edits, requestID: requestID)
        let updated: NoteDocument
        if let baseRevision = try payload.intOrNil("baseRevision") {
            guard conversationID == nil else {
                throw NotesDomainError.invalidPayload("rebaseIsUiOnly")
            }
            guard let base = try await store.editingSnapshot(id, revision: baseRevision) else {
                throw NoteError.conflict
            }
            updated = try await store.applyRebased(batch, base: base)
        } else {
            updated = try await store.apply(batch, authorizedConversationID: conversationID)
        }
        recordChange(kind: "document.updated", documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentUndo(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let redo = try payload.boolOrNil("redo") ?? false
        let updated = try await requireStore().undo(id, expectedRevision: expectedRevision, redo: redo)
        recordChange(kind: redo ? "document.redone" : "document.undone",
                     documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentSetTrashed(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let trashed = try payload.bool("trashed")
        let updated = try await requireStore().setTrashed(id, expectedRevision: expectedRevision,
                                                          trashed: trashed)
        recordChange(kind: trashed ? "document.trashed" : "document.restored",
                     documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentPermanentlyDelete(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        try await requireStore().permanentlyDelete(id, expectedRevision: expectedRevision)
        recordChange(kind: "document.deleted", documentID: id)
        return success(["documentID": id.uuidString])
    }

    private func documentHistory(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let state = try await requireStore().historyState(id)
        return success(["canUndo": state.canUndo, "canRedo": state.canRedo])
    }

    private func documentMarkOpened(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        try await requireStore().markOpened(id)
        recordChange(kind: "document.opened", documentID: id)
        return success(["documentID": id.uuidString])
    }

    private func simpleEdit(_ id: UUID, expectedRevision: Int, title: String,
                            edit: NoteEdit, kind: String) async throws -> Data {
        let batch = NoteEditBatch(documentID: id, expectedRevision: expectedRevision,
                                  title: title, edits: [edit])
        let updated = try await requireStore().apply(batch)
        recordChange(kind: kind, documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentSetFavorite(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        return try await simpleEdit(try payload.uuid("documentID"),
                                    expectedRevision: try payload.int("expectedRevision"),
                                    title: "Favorite",
                                    edit: .favorite(try payload.bool("isFavorite")),
                                    kind: "document.updated")
    }

    private func documentSetTags(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        return try await simpleEdit(try payload.uuid("documentID"),
                                    expectedRevision: try payload.int("expectedRevision"),
                                    title: "Tags",
                                    edit: .tags(try payload.strings("tags")),
                                    kind: "document.updated")
    }

    private func documentCoverRead(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let document = try await requireStore().document(try payload.uuid("documentID"))
        let mode: String
        switch document.coverMode {
        case .automatic: mode = "automatic"
        case .custom: mode = "custom"
        }
        return success(["coverMode": mode,
                        "coverResourceID": document.coverResourceID?.uuidString ?? NSNull(),
                        "coverRevision": document.normalizedCoverRevision,
                        "contentRevision": document.revision])
    }

    private func documentCoverApply(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let expectedRevision = try payload.int("expectedRevision")
        let expectedCoverRevision = try payload.int("expectedCoverRevision")
        let commandValue = try payload.string("command")
        let command: NoteCoverCommand
        switch commandValue {
        case "useResource":
            command = .useResource(try payload.uuid("resourceID"))
        case "restoreAutomatic":
            command = .restoreAutomatic
        default:
            throw NotesDomainError.invalidPayload("unknownCoverCommand")
        }
        let updated = try await requireStore().applyCoverCommand(
            command, documentID: id, expectedRevision: expectedRevision,
            expectedCoverRevision: expectedCoverRevision)
        recordChange(kind: "document.cover", documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentCacheOfficePreview(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let updated = try await requireStore().cacheOfficePreview(
            documentID: try payload.uuid("documentID"),
            sourceResourceID: try payload.uuid("sourceResourceID"),
            previewResourceID: try payload.uuid("previewResourceID"),
            expectedRevision: try payload.int("expectedRevision"))
        recordChange(kind: "document.preview", documentID: updated.id, revision: updated.revision)
        return try successEncoded("document", updated)
    }

    private func documentEditingSnapshot(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let id = try payload.uuid("documentID")
        let revision = try payload.int("revision")
        guard let document = try await requireStore().editingSnapshot(id, revision: revision) else {
            return success(["found": false])
        }
        return try successEncoded("document", document, extra: ["found": true])
    }

    private func documentPageOCRState(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let document = try await requireStore().document(try payload.uuid("documentID"))
        let pageID = try payload.uuid("pageID")
        guard let page = document.pages.first(where: { $0.id == pageID }) else {
            throw NoteError.notFound
        }
        let key = page.visualIndexKey
        let current = page.indexedVisualText != nil
        var fields: [String: Any] = [
            "documentID": document.id.uuidString,
            "pageID": page.id.uuidString,
            "visualIndexKey": key,
            "current": current,
        ]
        if let sourceKey = page.ocrSourceKey { fields["ocrSourceKey"] = sourceKey }
        if let text = page.ocrText { fields["ocrText"] = text }
        if let error = page.ocrError { fields["ocrError"] = error }
        return success(fields)
    }

    private func searchQuery(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let query = try payload.string("query")
        let limit = min(200, max(1, try payload.intOrNil("limit") ?? 50))
        let values = try await requireStore().search(query, limit: limit)
        return try successEncoded("documents", values.map { summary($0) })
    }

    // MARK: - Assistant

    private func assistantGrant(_ payload: NotesJSONValue?, bind: Bool) async throws -> Data {
        let payload = try NotesPayload(payload)
        let conversationID = try payload.uuid("conversationID")
        let documentID = try payload.uuid("documentID")
        let canEdit = try payload.boolOrNil("canEdit") ?? false
        if bind {
            try await requireStore().bindAssistant(conversationID: conversationID,
                                                   documentID: documentID, canEdit: canEdit)
        } else {
            try await requireStore().grantAccess(conversationID: conversationID,
                                                 documentID: documentID, canEdit: canEdit)
        }
        recordChange(kind: "assistant.grant", documentID: documentID)
        return success(["conversationID": conversationID.uuidString,
                        "documentID": documentID.uuidString,
                        "canEdit": canEdit])
    }

    private func assistantRevoke(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let conversationID = try payload.uuid("conversationID")
        let documentID = try payload.uuid("documentID")
        try await requireStore().revokeAccess(conversationID: conversationID,
                                              documentID: documentID)
        recordChange(kind: "assistant.revoke", documentID: documentID)
        return success(["conversationID": conversationID.uuidString,
                        "documentID": documentID.uuidString])
    }

    private func assistantGrants(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let grants = try await requireStore().accessGrants(
            conversationID: try payload.uuid("conversationID"))
        let object = Dictionary(uniqueKeysWithValues: grants.map { ($0.key.uuidString, $0.value) })
        return success(["grants": object])
    }

    private func assistantScopedDocuments(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let values = try await requireStore().scopedDocuments(
            conversationID: try payload.uuid("conversationID"))
        return try successEncoded("documents", values.map { summary($0) })
    }

    private func assistantSetFocus(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let conversationID = try payload.uuid("conversationID")
        let documentID = try payload.uuid("documentID")
        try await requireStore().setAssistantFocus(conversationID: conversationID,
                                                   documentID: documentID,
                                                   pageID: try payload.uuidOrNil("pageID"))
        recordChange(kind: "assistant.focus", documentID: documentID)
        return success(["conversationID": conversationID.uuidString,
                        "documentID": documentID.uuidString])
    }

    private func assistantRuntimeContext(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let context = try await requireStore().assistantRuntimeContext(
            conversationID: try payload.uuid("conversationID"))
        return success(["context": context ?? NSNull()])
    }

    // MARK: - Change cursor

    private func poll(_ payload: NotesJSONValue?) throws -> Data {
        let payload = try NotesPayload(payload)
        let cursor = max(0, try payload.int64("cursor"))
        let limit = min(512, max(1, try payload.intOrNil("limit") ?? 128))
        let firstRetained = changeLog.first?.sequence ?? (changeSequence + 1)
        let ahead = cursor > Int64(changeSequence)
        let resync = ahead
            || (cursor + 1 < Int64(firstRetained) && changeSequence > 0)
        let effectiveCursor = ahead ? changeSequence : UInt64(max(0, cursor))
        let events = changeLog.filter { Int64($0.sequence) > cursor }.prefix(limit)
        let encoded = events.map { event -> [String: Any] in
            var value: [String: Any] = ["sequence": event.sequence, "kind": event.kind]
            if let id = event.documentID { value["documentID"] = id.uuidString }
            if let revision = event.revision { value["revision"] = revision }
            return value
        }
        let last = events.last?.sequence ?? effectiveCursor
        return success(["sequence": changeSequence,
                        "cursor": last,
                        "events": Array(encoded),
                        "hasMore": changeLog.contains { Int64($0.sequence) > Int64(last) },
                        "resyncRequired": resync])
    }

    private func proposalList(_ payload: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(payload)
        let documentID = try payload.uuidOrNil("documentID")
        let all: [NoteProposal]
        if let documentID {
            all = await proposalStore.pending(documentID: documentID)
        } else {
            let stored = await proposalStore.all()
            all = stored.filter(\.isPending)
        }
        let values: [[String: Any]] = all.map { proposal in
            ["id": proposal.id.uuidString,
             "documentID": proposal.documentID.uuidString,
             "baseRevision": proposal.baseRevision,
             "title": proposal.title,
             "summary": NotesWire.bounded(proposal.summary, limit: 4_096),
             "createdAt": proposal.createdAt.timeIntervalSince1970 * 1_000]
        }
        return success(["proposals": values])
    }

    // MARK: - Summary helper

    func summary(_ document: NoteDocument) -> NoteDocumentSummary {
        let searchable = document.searchableText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(searchable.prefix(240))
        return NoteDocumentSummary(
            id: document.id, kind: document.kind, notebookID: document.notebookID,
            title: document.title, revision: document.revision,
            pageCount: document.pages.count, nodeCount: document.nodes.count,
            tags: document.tags, isFavorite: document.isFavorite,
            createdAt: document.createdAt, updatedAt: document.updatedAt,
            deletedAt: document.deletedAt, coverResourceID: document.coverResourceID,
            coverRevision: document.coverRevision,
            officeFileName: document.officeFileName,
            engineeringFileName: document.engineeringFileName,
            preview: preview)
    }

    static func kind(_ raw: String) throws -> NoteDocument.Kind {
        guard let kind = NoteDocument.Kind(rawValue: raw) else {
            throw NotesDomainError.invalidPayload("unknownDocumentKind")
        }
        return kind
    }
}
