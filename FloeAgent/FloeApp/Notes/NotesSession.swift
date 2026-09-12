// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeNotes
import FloeDocuments
import PencilKit

@MainActor @Observable
final class NotesSession {
    private(set) var store: NotesStore?
    private(set) var documents: [NoteDocument] = []
    private(set) var notebooks: [Notebook] = []
    private(set) var document: NoteDocument?
    private(set) var pendingWrites = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var errorMessage: String?
    private(set) var unsavedDocumentIDs: Set<UUID> = []
    private(set) var recoverableInkDocumentIDs: Set<UUID> = []
    private struct InkKey: Hashable { let documentID: UUID; let pageID: UUID }
    @ObservationIgnored private var pendingInk: [InkKey: Data] = [:]
    @ObservationIgnored private var scheduledInk: Set<InkKey> = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?

    func open() async {
        guard store == nil else { return }
        do {
            store = try await NotesRepository.shared.store()
            try await reload()
            if let store {
                observation = Task { [weak self] in
                    for await _ in await store.changes() {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        if self.pendingWrites == 0 {
                            do { try await self.reload() } catch { self.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    deinit { observation?.cancel() }

    func reload() async throws {
        guard let store else { return }
        documents = try await store.documents(includeTrash: true)
        notebooks = try await store.notebooks()
        let recovery = try inkRecoveryRoot()
        let folders = (try? FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recoverableInkDocumentIDs = Set(folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.pathExtension == "drawing" }) else { return nil }
            return id
        })
        if let id = document?.id { document = documents.first { $0.id == id } }
        if let id = document?.id {
            let history = try await store.historyState(id)
            canUndo = history.canUndo; canRedo = history.canRedo
        } else { canUndo = false; canRedo = false }
    }

    func select(_ value: NoteDocument?) async {
        await tail?.value
        document = value.flatMap { selected in documents.first { $0.id == selected.id } }
        do { try await reload() } catch { errorMessage = error.localizedDescription }
    }

    func create(kind: NoteDocument.Kind, title: String, notebookID: UUID?) {
        enqueue { [self] in
            guard let store else { return }
            var value = NoteDocument(kind: kind, notebookID: notebookID, title: title)
            if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.title = kind == .mindMap ? "未命名导图" : "未命名手记"
                if !value.nodes.isEmpty { value.nodes[0].title = value.title }
            }
            document = try await store.create(value)
            try await reload()
        }
    }

    func createNotebook(_ title: String) {
        enqueue { [self] in
            guard let store else { return }
            try await store.createNotebook(title: title)
            try await reload()
        }
    }

    func createOffice(extension fileExtension: String, title: String, notebookID: UUID?) {
        enqueue { [self] in
            guard let store else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-office-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let safeName = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let file = folder.appendingPathComponent(safeName).appendingPathExtension(fileExtension)
            try await Task.detached(priority: .userInitiated) {
                switch fileExtension {
                case "docx": try OfficeDocumentBuilder.createWord(at: file, title: title, paragraphs: [""])
                case "xlsx": try OfficeDocumentBuilder.createWorkbook(at: file, sheets: [.init(name: "Sheet1", rows: [[]])])
                case "pptx": try OfficeDocumentBuilder.createPresentation(at: file, title: title, slides: [.init(title: title)])
                default: throw NoteError.invalidOperation("不支持此 Office 格式。")
                }
            }.value
            let value = try await NoteFileImporter.importFile(file, notebookID: notebookID, store: store)
            document = try await store.create(value)
            try await reload()
        }
    }

    func apply(_ edits: [NoteEdit], title: String, documentID: UUID) {
        enqueue { [self] in
            guard let store, let value = documents.first(where: { $0.id == documentID }) else { throw NoteError.notFound }
            _ = try await store.apply(.init(documentID: documentID, expectedRevision: value.revision, title: title, edits: edits))
            try await reload()
        }
    }

    func saveDrawing(_ data: Data, pageID: UUID, documentID: UUID) {
        let key = InkKey(documentID: documentID, pageID: pageID)
        pendingInk[key] = data
        unsavedDocumentIDs.insert(documentID)
        scheduleInk(key)
    }

    private func inkRecoveryRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/InkRecovery", isDirectory: true)
    }

    func recoverInk(documentID: UUID) {
        guard let document = documents.first(where: { $0.id == documentID && $0.deletedAt == nil }) else { return }
        do {
            let folder = try inkRecoveryRoot().appendingPathComponent(documentID.uuidString, isDirectory: true)
            for page in document.pages {
                let url = folder.appendingPathComponent("\(page.id.uuidString).drawing")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try Data(contentsOf: url)
                _ = try PKDrawing(data: data)
                saveDrawing(data, pageID: page.id, documentID: documentID)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retrySaving() {
        for key in pendingInk.keys { scheduleInk(key) }
    }

    private func scheduleInk(_ key: InkKey) {
        guard scheduledInk.insert(key).inserted else { return }
        enqueue { [self] in
            defer { scheduledInk.remove(key) }
            guard let store else { throw NoteError.resourceUnavailable }
            while let data = pendingInk[key] {
                let value = try await store.document(key.documentID)
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
                    .appendingPathComponent("FloeAgent/Notes/InkRecovery/\(key.documentID.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let recovery = folder.appendingPathComponent("\(key.pageID.uuidString).drawing")
                // Keep a durable recovery copy until the document transaction succeeds.
                try data.write(to: recovery, options: .atomic)
                let resource = try await store.importResource(from: recovery, mediaType: "application/vnd.apple.pencilkit")
                _ = try await store.apply(.init(documentID: key.documentID, expectedRevision: value.revision,
                                               title: "书写", edits: [.drawing(pageID: key.pageID, resourceID: resource)]))
                if pendingInk[key] == data { pendingInk.removeValue(forKey: key) }
                if pendingInk[key] == nil { try? FileManager.default.removeItem(at: recovery) }
            }
            if !pendingInk.keys.contains(where: { $0.documentID == key.documentID }) { unsavedDocumentIDs.remove(key.documentID) }
            try await reload()
        }
    }

    func undo(redo: Bool = false) {
        guard let id = document?.id else { return }
        enqueue { [self] in
            guard let store, let value = documents.first(where: { $0.id == id }) else { throw NoteError.notFound }
            _ = try await store.undo(id, expectedRevision: value.revision, redo: redo)
            try await reload()
        }
    }

    func commit(_ edits: [NoteEdit], documentID: UUID, expectedRevision: Int) async throws -> NoteDocument {
        guard pendingWrites == 0, let store else { throw NoteError.conflict }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let result = try await store.apply(.init(documentID: documentID, expectedRevision: expectedRevision, title: "编辑内容", edits: edits))
        try await reload()
        return result
    }

    func trash(_ value: NoteDocument, restore: Bool = false) {
        enqueue { [self] in
            guard let store else { return }
            _ = try await store.setTrashed(value.id, expectedRevision: value.revision, trashed: !restore)
            if !restore && document?.id == value.id { document = nil }
            try await reload()
        }
    }

    func importDocument(_ value: NoteDocument) {
        enqueue { [self] in
            guard let store else { return }
            document = try await store.create(value)
            try await reload()
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = tail
        pendingWrites += 1
        tail = Task { [self] in
            await previous?.value
            defer { pendingWrites -= 1 }
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
