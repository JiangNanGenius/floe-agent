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
    private(set) var recentDocumentIDs: [UUID] = []
    private(set) var notebooks: [Notebook] = []
    private(set) var document: NoteDocument?
    private(set) var tabs = NoteWorkspaceTabs()
    private(set) var isSwitchingDocument = false
    @ObservationIgnored private var tabDefaults: UserDefaults?
    @ObservationIgnored private var editorStates: [UUID: NoteWorkspaceTabs.EditorState] = [:]
    @ObservationIgnored private var leaveGuards: [UUID: @MainActor () async -> Bool] = [:]
    private static let tabsKey = "notes.workspace.tabs.v1"

    init(tabDefaults: UserDefaults? = nil) {
        self.tabDefaults = tabDefaults
        if let data = tabDefaults?.data(forKey: Self.tabsKey),
           let restored = try? JSONDecoder().decode(NoteWorkspaceTabs.self, from: data) {
            tabs = restored
            editorStates = restored.editors
        }
    }

    func editorState(for id: UUID) -> NoteWorkspaceTabs.EditorState { editorStates[id] ?? .init() }
    func rememberEditor(_ state: NoteWorkspaceTabs.EditorState, for id: UUID) {
        editorStates[id] = state
    }
    func registerLeaveGuard(for id: UUID, action: @escaping @MainActor () async -> Bool) { leaveGuards[id] = action }
    func removeLeaveGuard(for id: UUID) { leaveGuards.removeValue(forKey: id) }

    func persistTabs() {
        for (id, state) in editorStates { tabs.updateEditor(state, for: id) }
        let available = Set(documents.filter { $0.deletedAt == nil }.map(\.id))
        tabs.prune(availableIDs: available)
        editorStates = editorStates.filter { available.contains($0.key) }
        if let data = try? JSONEncoder().encode(tabs) { tabDefaults?.set(data, forKey: Self.tabsKey) }
    }

    private(set) var pendingWrites = 0
    private(set) var canUndo = false
    private(set) var canRedo = false
    var requestedPageID: UUID?
    var errorMessage: String?
    var editConflicts: [NoteEditConflict] = []
    private(set) var unsavedDocumentIDs: Set<UUID> = []
    private(set) var recoverableInkDocumentIDs: Set<UUID> = []
    private struct InkKey: Hashable { let documentID: UUID; let pageID: UUID }
    @ObservationIgnored private var pendingInk: [InkKey: NoteInkDraft] = [:]
    @ObservationIgnored private var scheduledInk: Set<InkKey> = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var needsStoreRefresh = false
    private(set) var indexingDocumentID: UUID?

    func open(using existingStore: NotesStore? = nil) async {
        guard store == nil else { return }
        do {
            if let existingStore { store = existingStore }
            else { store = try await NotesRepository.shared.store() }
            if let store {
                // Subscribe before the first read so a tool commit during opening is not lost.
                let changes = await store.changes()
                observation = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }
                        self.needsStoreRefresh = true
                        self.refreshFromStoreIfIdle()
                    }
                }
                try await reload()
                // Deferred collection failures remain retryable on next open;
                // readable documents have already loaded independently.
                do { _ = try await store.collectDeletedResources() }
                catch { errorMessage = "未能回收已删除附件，可重新打开手记重试：" + error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    deinit { observation?.cancel(); indexing?.cancel(); refresh?.cancel() }

    /// Tool commits are independent of the editor write queue. Coalesce notifications,
    /// but retain one while local ink is saving instead of dropping the update.
    private func refreshFromStoreIfIdle() {
        guard pendingWrites == 0, needsStoreRefresh, refresh == nil else { return }
        refresh = Task { [weak self] in
            guard let self else { return }
            defer { self.refresh = nil }
            while self.needsStoreRefresh && self.pendingWrites == 0 && !Task.isCancelled {
                self.needsStoreRefresh = false
                do { try await self.reload() }
                catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func finishWrite() {
        pendingWrites -= 1
        refreshFromStoreIfIdle()
    }

    func hasPendingInk(documentID: UUID, pageID: UUID) -> Bool {
        pendingInk[InkKey(documentID: documentID, pageID: pageID)] != nil
    }

    func reload() async throws {
        guard let store else { return }
        documents = try await store.documents(includeTrash: true)
        editConflicts = try await store.conflictReviews()
        notebooks = try await store.notebooks()
        recentDocumentIDs = try await store.recentDocuments().map(\.id)
        startOfficeIndexing()
        let recovery = try inkRecoveryRoot()
        let folders = (try? FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recoverableInkDocumentIDs = Set(folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  files.contains(where: { ["drawing", "inkdraft"].contains($0.pathExtension) }) else { return nil }
            return id
        })
        if let id = document?.id { document = documents.first { $0.id == id && $0.deletedAt == nil } }
        if let id = document?.id { tabs.open(id) }
        persistTabs()
        if let id = document?.id {
            let history = try await store.historyState(id)
            canUndo = history.canUndo; canRedo = history.canRedo
        } else { canUndo = false; canRedo = false }
    }

    private func startOfficeIndexing() {
        guard indexing == nil, let store,
              documents.contains(where: { $0.deletedAt == nil && (($0.kind == .office && $0.officeResourceID != nil && $0.officeTextResourceID != $0.officeResourceID) || $0.pages.contains { $0.needsVisualIndex && $0.ocrSourceKey != $0.visualIndexKey }) }) else { return }
        indexing = Task { [weak self] in
            guard let self else { return }
            defer {
                self.indexing = nil; self.indexingDocumentID = nil
                if !Task.isCancelled { Task { try? await self.reload() } }
            }
            for document in self.documents where document.deletedAt == nil {
                for page in document.pages where page.needsVisualIndex && page.ocrSourceKey != page.visualIndexKey {
                    guard !Task.isCancelled else { return }
                    self.indexingDocumentID = document.id
                    let key = page.visualIndexKey
                    do {
                        let text = try await NoteFileImporter.visualSearchText(page: page, store: store)
                        try Task.checkCancellation()
                        try await store.cachePageOCR(documentID: document.id, pageID: page.id, sourceKey: key, text: text, error: nil)
                    } catch is CancellationError { return }
                    catch { try? await store.cachePageOCR(documentID: document.id, pageID: page.id, sourceKey: key, text: nil, error: error.localizedDescription) }
                }
            }
            for document in self.documents where document.deletedAt == nil && document.kind == .office {
                guard !Task.isCancelled else { return }
                guard let resource = document.officeResourceID,
                      document.officeTextResourceID != resource else { continue }
                self.indexingDocumentID = document.id
                do {
                    let source = try await store.resourceURL(resource)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-index-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let file = directory.appendingPathComponent("document").appendingPathExtension((document.officeFileName as NSString?)?.pathExtension ?? "")
                    // Immutable resources allow a cheap hard link; fallback is a bounded source copy.
                    do { try FileManager.default.linkItem(at: source, to: file) }
                    catch { try FileManager.default.copyItem(at: source, to: file) }
                    let text = try await NoteFileImporter.officeSearchText(url: file)
                    try Task.checkCancellation()
                    try await store.cacheOfficeText(documentID: document.id, resourceID: resource, text: text, error: nil)
                } catch is CancellationError { return }
                catch {
                    try? await store.cacheOfficeText(documentID: document.id, resourceID: resource, text: nil, error: error.localizedDescription)
                }
            }
        }
    }

    func rebuildSearchIndex(documentID: UUID) {
        enqueue { [self] in
            guard let store else { return }
            try await store.resetSearchIndex(documentID: documentID)
            try await reload()
        }
    }

    @discardableResult
    func select(_ value: NoteDocument?) async -> Bool {
        guard !isSwitchingDocument else { return false }
        if document?.id == value?.id { return true }
        isSwitchingDocument = true
        defer { isSwitchingDocument = false }
        await tail?.value
        guard pendingWrites == 0 else { errorMessage = "正在保存，请稍后切换文档。"; return false }
        if let current = document?.id {
            guard !unsavedDocumentIDs.contains(current) else {
                errorMessage = "当前文档尚未保存，请先重试保存，再切换或关闭标签。"
                return false
            }
            if let save = leaveGuards[current], !(await save()) { return false }
        }
        let target = value.flatMap { selected in documents.first { $0.id == selected.id && $0.deletedAt == nil } }
        if value != nil && target == nil { errorMessage = "此文档已被删除。"; return false }
        do {
            if let id = target?.id, let store { try await store.markOpened(id) }
            document = target
            requestedPageID = nil
            try await reload()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func closeTab(_ id: UUID) async {
        guard !isSwitchingDocument else { return }
        var updated = tabs
        updated.close(id)
        if document?.id == id {
            let next = updated.selectedID.flatMap { id in documents.first { $0.id == id && $0.deletedAt == nil } }
            guard await select(next) else { return }
        }
        tabs.close(id)
        persistTabs()
    }

    @discardableResult
    func openSource(_ source: NoteSourceReference) async -> Bool {
        guard source.space == .notes, let store else { errorMessage = "此引用不属于手记。"; return false }
        do {
            let value = try await store.document(source.documentID)
            guard value.deletedAt == nil else { throw NoteError.invalidOperation("引用资料在回收站中，请先恢复。") }
            if let pageID = source.pageID, !value.pages.contains(where: { $0.id == pageID }) {
                throw NoteError.invalidOperation("引用页面已被删除，可以在源手记中撤销相应删除操作。")
            }
            await select(value)
            requestedPageID = source.pageID
            return document?.id == value.id
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func create(kind: NoteDocument.Kind, title: String, notebookID: UUID?) {
        enqueue { [self] in
            guard let store else { return }
            var value = NoteDocument(kind: kind, notebookID: notebookID, title: title)
            if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.title = kind == .mindMap ? "未命名导图" : "未命名手记"
                if !value.nodes.isEmpty { value.nodes[0].title = value.title }
            }
            showCreatedDocument(try await store.create(value))
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

    func renameNotebook(_ id: UUID, title: String) {
        enqueue { [self] in
            guard let store else { return }
            try await store.renameNotebook(id, title: title)
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
            showCreatedDocument(try await store.create(value))
            try await reload()
        }
    }

    func apply(_ edits: [NoteEdit], title: String, documentID: UUID) {
        let baseline = documents.first { $0.id == documentID }
        enqueue { [self] in
            guard let baseline else { throw NoteError.notFound }
            _ = try await commitPreservingConflict(.init(documentID: documentID, expectedRevision: baseline.revision, title: title, edits: edits), base: baseline)
            try await reload()
        }
    }

    private func commitPreservingConflict(_ batch: NoteEditBatch, base: NoteDocument) async throws -> NoteDocument {
        guard let store else { throw NoteError.resourceUnavailable }
        do { return try await store.applyRebased(batch, base: base) }
        catch NoteError.conflict {
            try await preserveEditConflict(batch, base: base)
            throw NoteError.invalidOperation(String(localized: "edit.conflict.notesPreserved"))
        }
    }

    private func preserveEditConflict(_ batch: NoteEditBatch, base: NoteDocument) async throws {
        guard let store else { throw NoteError.resourceUnavailable }
        // The copy owns durable resources independently of the original and chat.
        var draft = base
        for edit in batch.edits { try edit.apply(to: &draft) }
        draft.id = UUID()
        draft.title += " · " + String(localized: "edit.conflict.notesCopy")
        let copy = try await store.create(draft)
        let current = try await store.document(base.id)
        try await store.saveConflictReview(NoteEditConflict(current: current, copy: copy, edits: batch.edits, title: batch.title))
        try await reload()
    }

    func resolveEditConflict(_ review: NoteEditConflict, useMine: Bool) async {
        guard let store else { return }
        errorMessage = nil
        do {
            if useMine {
                guard try await store.document(review.copy.id).revision == review.copy.revision else {
                    throw NoteError.invalidOperation(String(localized: "edit.conflict.notesCopyChanged"))
                }
                _ = try await store.apply(.init(documentID: review.current.id, expectedRevision: review.current.revision,
                                               title: review.title, edits: review.edits), reviewedRecovery: (id: review.copy.id, revision: review.copy.revision), resolvingConflictID: review.id)
            } else {
                try await store.keepBothConflictVersions(review.id)
            }
            try await reload()
        } catch NoteError.conflict {
            do {
                let latest = try await store.document(review.current.id)
                try await store.saveConflictReview(NoteEditConflict(id: review.id, current: latest, copy: review.copy, edits: review.edits, title: review.title))
                try await reload()
                errorMessage = String(localized: "edit.conflict.notesReviewUpdated")
            } catch { errorMessage = error.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveDrawing(_ data: Data, pageID: UUID, base: NoteDocument) {
        let key = InkKey(documentID: base.id, pageID: pageID)
        // Coalesced strokes still derive from the first uncommitted canvas.
        let baseline = pendingInk[key]?.base ?? base
        pendingInk[key] = NoteInkDraft(base: baseline, pageID: pageID, drawing: data)
        unsavedDocumentIDs.insert(base.id)
        scheduleInk(key)
    }

    private func inkRecoveryRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/InkRecovery", isDirectory: true)
    }

    func recoverInk(documentID: UUID) {
        enqueue { [self] in
            guard let store else { throw NoteError.resourceUnavailable }
            let folder = try inkRecoveryRoot().appendingPathComponent(documentID.uuidString, isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "inkdraft" {
                let draft = try JSONDecoder().decode(NoteInkDraft.self, from: Data(contentsOf: url))
                guard draft.base.id == documentID, draft.base.pages.contains(where: { $0.id == draft.pageID }) else { throw NoteError.conflict }
                _ = try PKDrawing(data: draft.drawing)
                guard !hasPendingInk(documentID: documentID, pageID: draft.pageID) else { continue }
                saveDrawing(draft.drawing, pageID: draft.pageID, base: draft.base)
            }
            // Older recovery files have no baseline. Preserve as a separate
            // reviewable document; never assign today's revision to old ink.
            for url in files where url.pathExtension == "drawing" {
                guard let pageID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                let data = try Data(contentsOf: url)
                _ = try PKDrawing(data: data)
                var base = try await store.document(documentID)
                if !base.pages.contains(where: { $0.id == pageID }) {
                    var restoredPage = NotePage(); restoredPage.id = pageID
                    base.pages.append(restoredPage)
                }
                let resource = try await store.importResource(from: url, mediaType: "application/vnd.apple.pencilkit")
                try await preserveEditConflict(.init(documentID: documentID, expectedRevision: base.revision,
                    title: "恢复笔迹", edits: [.drawing(pageID: pageID, resourceID: resource)]), base: base)
                try FileManager.default.removeItem(at: url)
                errorMessage = String(localized: "edit.conflict.notesPreserved")
            }
            try await reload()
        }
    }

    func retrySaving() {
        for key in pendingInk.keys { scheduleInk(key) }
    }

    private func scheduleInk(_ key: InkKey) {
        guard scheduledInk.insert(key).inserted else { return }
        enqueue { [self] in
            defer { scheduledInk.remove(key) }
            guard let store else { throw NoteError.resourceUnavailable }
            while let draft = pendingInk[key] {
                let folder = try inkRecoveryRoot().appendingPathComponent(key.documentID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let recovery = folder.appendingPathComponent("\(key.pageID.uuidString).inkdraft")
                // One atomic envelope retains both bytes and their true baseline.
                try JSONEncoder().encode(draft).write(to: recovery, options: .atomic)
                let staging = folder.appendingPathComponent("\(UUID().uuidString).ink-staging")
                try draft.drawing.write(to: staging, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staging) }
                let resource = try await store.importResource(from: staging, mediaType: "application/vnd.apple.pencilkit")
                let batch = NoteEditBatch(documentID: key.documentID, expectedRevision: draft.base.revision,
                    title: "书写", edits: [.drawing(pageID: key.pageID, resourceID: resource)])
                do {
                    let saved = try await store.applyRebased(batch, base: draft.base)
                    // Newer queued strokes include this accepted local drawing.
                    // Only advance to our own acknowledged commit, never a new disk read.
                    if pendingInk[key]?.drawing != draft.drawing { pendingInk[key]?.base = saved }
                } catch NoteError.conflict {
                    try await preserveEditConflict(batch, base: draft.base)
                    errorMessage = String(localized: "edit.conflict.notesPreserved")
                }
                if pendingInk[key]?.drawing == draft.drawing { pendingInk.removeValue(forKey: key) }
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
        defer { finishWrite() }
        guard let base = try await store.editingSnapshot(documentID, revision: expectedRevision) else { throw NoteError.conflict }
        let result = try await commitPreservingConflict(.init(documentID: documentID, expectedRevision: expectedRevision, title: "编辑内容", edits: edits), base: base)
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

    func permanentlyDelete(_ value: NoteDocument) {
        enqueue { [self] in
            guard let store else { return }
            try await store.permanentlyDelete(value.id, expectedRevision: value.revision)
            if document?.id == value.id { document = nil }
            try await reload()
            _ = try await store.collectDeletedResources()
        }
    }

    func importArchive(_ url: URL, notebookID: UUID?) {
        enqueue { [self] in
            guard let store else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try await NotesArchive.importDocuments(from: url, notebookID: notebookID, store: store)
            showCreatedDocument(try await store.createBundle(values).first)
            try await reload()
        }
    }

    func importDocument(_ value: NoteDocument) {
        enqueue { [self] in
            guard let store else { return }
            showCreatedDocument(try await store.create(value))
            try await reload()
        }
    }

    /// A prepared workspace archive may contain linked maps. Commit its
    /// documents together after the picker has released its presentation.
    func importDocuments(_ values: [NoteDocument]) {
        enqueue { [self] in
            guard let store else { return }
            showCreatedDocument(try await store.createBundle(values).first)
            try await reload()
        }
    }

    private func showCreatedDocument(_ value: NoteDocument?) {
        // Office recovery can create another document while its editor is open.
        // Keep that editor mounted; switching to the new tab runs its save guard.
        if let current = document, current.kind == .office, let value {
            tabs.open(value.id)
            tabs.open(current.id)
        } else { document = value }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = tail
        pendingWrites += 1
        tail = Task { [self] in
            await previous?.value
            defer { finishWrite() }
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
