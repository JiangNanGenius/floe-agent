// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeNotes
import FloeDocuments
import PencilKit

import FloeCore
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
    /// Office documents created in this app run open once directly in the
    /// editor. A document merely opened from the library follows its
    /// remembered entry count (preview on the first entry, editor from the
    /// second).
    @ObservationIgnored private var editorOnNextOpen: Set<UUID> = []
    /// A typed, one-shot navigation request produced by a search result. It
    /// carries the exact page/element/node and UTF-16 range; the editor consumes
    /// it (scroll + highlight), and `requestedPageID` remains only for the
    /// source-reference path.
    struct NoteSearchFocus: Equatable {
        let documentID: UUID
        let pageID: UUID?
        let elementID: UUID?
        let nodeID: UUID?
        let utf16Offset: Int?
        let utf16Length: Int?
        let sourceKind: String
        /// Distinguishes repeated requests for the same range so the editor can
        /// re-run the scroll exactly once per tap.
        let requestID: UUID

        init(match: NoteTextSearch.Match, requestID: UUID = UUID()) {
            self.documentID = match.documentID
            self.pageID = match.pageID
            self.elementID = match.elementID
            self.nodeID = match.nodeID
            self.utf16Offset = match.utf16Offset
            self.utf16Length = match.utf16Length
            self.sourceKind = match.sourceKind
            self.requestID = requestID
        }
    }

    @ObservationIgnored private var searchFocusRequestID = UUID()
    var searchFocus: NoteSearchFocus?

    /// Resolves the first exact match for `query` in `document` through the
    /// same pure helper `notes.search` uses and publishes it for the editor.
    /// Returns false when the query only matches the title/tags or nothing.
    @discardableResult
    func requestSearchFocus(in document: NoteDocument, query: String) -> Bool {
        guard let match = NoteTextSearch.firstMatch(in: document, query: query) else {
            searchFocus = nil
            return false
        }
        searchFocusRequestID = UUID()
        searchFocus = NoteSearchFocus(match: match, requestID: searchFocusRequestID)
        return true
    }

    func clearSearchFocus() { searchFocus = nil }

    var requestedPageID: UUID?
    var errorMessage: String?
    var editConflicts: [NoteEditConflict] = []
    private(set) var unsavedDocumentIDs: Set<UUID> = []
    private(set) var recoverableInkDocumentIDs: Set<UUID> = []
    private struct InkKey: Hashable { let documentID: UUID; let pageID: UUID }
    /// Origin of an ink report, captured by the Pencil coordinator when the
    /// report originates: which canvas lineage, which generation that canvas
    /// had actually adopted, and the per-canvas report sequence. Recovery
    /// replays and legacy callers pass nil and can never adopt an ack.
    struct InkProvenance: Hashable, Sendable {
        let lineage: UUID
        let generation: UInt64
        let sequence: UInt64
    }
    /// Producer-isolated pending slot: each (page, canvas lineage, canvas
    /// generation) owns its queue entry, so one producer can never overwrite
    /// another producer's queued strokes or advance its baseline.
    private struct PendingKey: Hashable {
        let documentID: UUID
        let pageID: UUID
        let lineage: UUID?
        let generation: UInt64
        init(documentID: UUID, pageID: UUID, provenance: InkProvenance?) {
            self.documentID = documentID; self.pageID = pageID
            self.lineage = provenance?.lineage
            self.generation = provenance?.generation ?? 0
        }
        var pageKey: InkKey { InkKey(documentID: documentID, pageID: pageID) }
    }
    /// One acknowledgement per (document, page): the snapshot our own last
    /// successful ink commit returned for that page, the content-addressed
    /// drawing resource it installed, and the canvas lineage AND generation
    /// that submitted it. The generation retires with every canvas reload, so
    /// a token that survives an undo/reload can never cross the
    /// synchronization fence on identity alone. It is consulted only through
    /// `inkBaseline`, which re-verifies lineage, generation, and the live
    /// store page before adoption.
    private struct AcknowledgedInk {
        let base: NoteDocument
        let resourceID: UUID
        let producerLineage: UUID
        let producerGeneration: UInt64
        /// Report sequence that produced this acknowledgement; coalescing
        /// and success advancement must stay strictly monotonic within the
        /// producer's generation.
        let producerSequence: UInt64
    }
    @ObservationIgnored private var pendingInk: [PendingKey: NoteInkDraft] = [:]
    @ObservationIgnored private var scheduledInk: Set<PendingKey> = []
    // Retain the report high-water mark after a queue slot drains, so an old
    // callback cannot re-enter later and consume a newer commit receipt.
    @ObservationIgnored private var latestInkSequence: [PendingKey: UInt64] = [:]
    @ObservationIgnored private var acknowledgedInkBase: [InkKey: AcknowledgedInk] = [:]
    /// The ink resource each mounted canvas was verified to display, keyed by
    /// (document, page), with the canvas lineage and the generation that
    /// adoption established. Registration happens only when the Pencil
    /// coordinator confirms the actual byte adoption.
    @ObservationIgnored private var canvasInkResource: [InkKey: (lineage: UUID, generation: UInt64, resourceID: UUID?)] = [:]
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
                catch { errorMessage = FloeL10n.l("notes.notes_session.deleted_attachments_could_not_be_reclaimed") + error.localizedDescription }
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
        pendingInk.keys.contains { $0.documentID == documentID && $0.pageID == pageID }
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
                        let text = try await NoteFileImporter.visualSearchText(page: page, store: store, textSources: document.textSources ?? [:])
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
                    let leasedScratch = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "notes")
                    let directory = leasedScratch.url
                    defer {
                        try? FileManager.default.removeItem(at: directory)
                        leasedScratch.lease.release()
                    }
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
        guard pendingWrites == 0 else { errorMessage = FloeL10n.l("notes.notes_session.saving_switch_documents_shortly"); return false }
        if let current = document?.id {
            guard !unsavedDocumentIDs.contains(current) else {
                errorMessage = FloeL10n.l("notes.notes_session.the_current_document_is_not_saved")
                return false
            }
            if let save = leaveGuards[current], !(await save()) { return false }
        }
        let target = value.flatMap { selected in documents.first { $0.id == selected.id && $0.deletedAt == nil } }
        if value != nil && target == nil { errorMessage = FloeL10n.l("notes.notes_session.this_document_was_deleted"); return false }
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
        guard source.space == .notes, let store else { errorMessage = FloeL10n.l("notes.notes_session.this_reference_does_not_belong_to"); return false }
        do {
            let value = try await store.document(source.documentID)
            guard value.deletedAt == nil else { throw NoteError.invalidOperation(FloeL10n.l("notes.notes_session.the_cited_material_is_in_trash")) }
            if let pageID = source.pageID, !value.pages.contains(where: { $0.id == pageID }) {
                throw NoteError.invalidOperation(FloeL10n.l("notes.notes_session.the_cited_page_was_deleted_you"))
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
                value.title = kind == .mindMap ? FloeL10n.l("notes.notes_session.untitled_mind_map") : FloeL10n.l("notes.notes_session.untitled_note")
                if !value.nodes.isEmpty { value.nodes[0].title = value.title }
            }
            showCreatedDocument(try await store.create(value), editorOnFirstOpen: kind == .office)
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
            let leasedOffice = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "notes")
            let folder = leasedOffice.url
            defer {
                try? FileManager.default.removeItem(at: folder)
                leasedOffice.lease.release()
            }
            let safeName = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let file = folder.appendingPathComponent(safeName).appendingPathExtension(fileExtension)
            try await Task.detached(priority: .userInitiated) {
                switch fileExtension {
                case "docx": try OfficeDocumentBuilder.createWord(at: file, title: title, paragraphs: [""])
                case "xlsx": try OfficeDocumentBuilder.createWorkbook(at: file, sheets: [.init(name: "Sheet1", rows: [[]])])
                case "pptx": try OfficeDocumentBuilder.createPresentation(at: file, title: title, slides: [.init(title: title)])
                default: throw NoteError.invalidOperation(FloeL10n.l("notes.notes_session.this_office_format_is_not_supported"))
                }
            }.value
            let value = try await NoteFileImporter.importFile(file, notebookID: notebookID, store: store)
            // The file was authored in this app run: first entry goes straight
            // to the editor, unlike an imported existing document.
            showCreatedDocument(try await store.create(value), editorOnFirstOpen: true)
            try await reload()
        }
    }

    func apply(_ edits: [NoteEdit], title: String, base: NoteDocument) {
        enqueue { [self] in
            _ = try await commitPreservingConflict(.init(documentID: base.id, expectedRevision: base.revision, title: title, edits: edits), base: base)
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

    /// True when `document` still holds exactly the content-addressed drawing
    /// bytes this preservation tried to keep, for every drawing edit in the
    /// batch. Non-drawing batches never match here.
    private func preservationStillMatches(_ batch: NoteEditBatch, document: NoteDocument) -> Bool {
        var sawDrawing = false
        for edit in batch.edits {
            guard case .drawing(let pageID, let resourceID) = edit, let resourceID else { continue }
            sawDrawing = true
            guard document.pages.first(where: { $0.id == pageID })?.drawingResourceID == resourceID else { return false }
        }
        return sawDrawing
    }

    private func preserveEditConflict(_ batch: NoteEditBatch, base: NoteDocument) async throws {
        guard let store else { throw NoteError.resourceUnavailable }
        // Identical failed preservation reuses its existing unresolved review
        // instead of minting another copy: same original document, same edit
        // contents, and a copy that is still present, untrashed, unedited, and
        // still holds the same preserved bytes. Only the review's current
        // snapshot refreshes; its id, copy, edits and title are retained, and
        // no review or document is ever deleted or replaced here.
        let reviews = try await store.conflictReviews()
        for review in reviews where review.current.id == batch.documentID && review.edits == batch.edits {
            guard let copy = try? await store.document(review.copy.id),
                  copy.deletedAt == nil, copy.revision == review.copy.revision,
                  preservationStillMatches(batch, document: copy) else { continue }
            let latest = try await store.document(base.id)
            try await store.saveConflictReview(NoteEditConflict(id: review.id, current: latest,
                copy: review.copy, edits: review.edits, title: review.title))
            try await reload()
            return
        }
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

    /// Records that the canvas identified by `canvasLineage` has advanced to
    /// `canvasGeneration` and the Pencil coordinator confirmed it actually
    /// displays the ink stored at `drawingResourceID` for this page. The
    /// editor calls this only from the confirmed byte adoption, after the
    /// loading task re-verified the live page still holds that resource.
    /// Registration is in-memory only; it retires every previous generation
    /// of that canvas, so a stale callback holding an older generation can
    /// neither coalesce onto pending ink nor consume an acknowledgement.
    func noteInkCanvasSynced(documentID: UUID, pageID: UUID, canvasLineage: UUID, canvasGeneration: UInt64, drawingResourceID: UUID?) {
        canvasInkResource[InkKey(documentID: documentID, pageID: pageID)] =
            (lineage: canvasLineage, generation: canvasGeneration, resourceID: drawingResourceID)
    }

    func saveDrawing(_ data: Data, pageID: UUID, base: NoteDocument, provenance: InkProvenance? = nil) {
        let key = PendingKey(documentID: base.id, pageID: pageID, provenance: provenance)
        if let sequence = provenance?.sequence {
            if let latest = latestInkSequence[key], sequence <= latest { return }
            latestInkSequence[key] = sequence
        }
        if let pending = pendingInk[key] {
            // Same producer, same generation: only this producer's FINAL,
            // monotonically NEWER report may replace the queued item, so an
            // obsolete callback (seq 1 after seq 2) can never overwrite the
            // newer canvas bytes. The first uncommitted baseline is retained
            // and ack adoption is resolved inside the serialized tail.
            if let sequence = provenance?.sequence, let queued = pending.canvasSequence, queued >= sequence {
                return
            }
            pendingInk[key] = NoteInkDraft(base: pending.base, pageID: pageID, drawing: data,
                                           canvasLineage: provenance?.lineage, canvasGeneration: provenance?.generation,
                                           canvasSequence: provenance?.sequence)
            unsavedDocumentIDs.insert(base.id)
            scheduleInk(key)
            return
        }
        // Synchronous by contract: this only enqueues the raw caller base and
        // its provenance in report order. Validation against the live store
        // happens in `acknowledgedBaseIfValid` within the serialized tail,
        // before the recovery envelope is fixed.
        pendingInk[key] = NoteInkDraft(base: base, pageID: pageID, drawing: data,
                                       canvasLineage: provenance?.lineage, canvasGeneration: provenance?.generation,
                                       canvasSequence: provenance?.sequence)
        unsavedDocumentIDs.insert(base.id)
        scheduleInk(key)
    }

    /// Effective baseline for one queued draft, resolved inside the
    /// serialized tail BEFORE its recovery envelope is written. Our last
    /// acknowledged commit for this exact page may serve as the base only
    /// under all of these guards:
    /// - the draft carries provenance and names the acknowledged producer at
    ///   the SAME generation, or a canvas that registered this exact resource
    ///   at the SAME (latest) generation — never an arbitrary old snapshot, a
    ///   retired editor, a generation retired by reload/undo, or a
    ///   document-wide maximum revision;
    /// - same document and the page still exists in both snapshots;
    /// - the awaited live store page still holds the acknowledged bytes, so
    ///   an external same-page edit, an undo rewind, or a reload from another
    ///   lineage fences adoption closed instead of trusting the ack.
    /// Recovery replays carry no provenance and never adopt one.
    private func acknowledgedBaseIfValid(for pageKey: InkKey, draft: NoteInkDraft) async -> NoteDocument {
        guard let provenance = draft.canvasLineage.map({ lineage in
            (lineage: lineage, generation: draft.canvasGeneration ?? 0)
        }),
              let ack = acknowledgedInkBase[pageKey],
              ack.base.id == draft.base.id,
              let acknowledgedPage = ack.base.pages.first(where: { $0.id == pageKey.pageID }),
              acknowledgedPage.drawingResourceID == ack.resourceID,
              draft.base.pages.contains(where: { $0.id == pageKey.pageID }),
              let store
        else { return draft.base }
        // Check the mounted-generation fence after the actor read: a reload
        // can register a different generation while that read is suspended.
        guard let current = try? await store.document(draft.base.id),
              current.deletedAt == nil,
              current.revision >= ack.base.revision,
              current.pages.first(where: { $0.id == pageKey.pageID })?.drawingResourceID == ack.resourceID
        else { return draft.base }
        let lineageMatches: Bool
        if ack.producerLineage == provenance.lineage, ack.producerGeneration == provenance.generation {
            guard let sequence = draft.canvasSequence, sequence > ack.producerSequence else { return draft.base }
            // The producing canvas must still be the mounted one at THIS
            // generation: any later registered generation (reload, undo
            // rewind, remount) retires the ack's producer authority, and the
            // same-producer shortcut may not bypass that fence. A canvas that
            // never adopted a load (no registration) keeps producer authority.
            if let registered = canvasInkResource[pageKey] {
                lineageMatches = registered.lineage == provenance.lineage
                    && registered.generation == provenance.generation
            } else {
                lineageMatches = true
            }
        } else if let synced = canvasInkResource[pageKey],
                  synced.lineage == provenance.lineage, synced.generation == provenance.generation {
            lineageMatches = synced.resourceID == ack.resourceID
        } else {
            lineageMatches = false
        }
        guard lineageMatches else { return draft.base }
        return ack.base.revision > draft.base.revision ? ack.base : draft.base
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
                // Replay each envelope independently from its original disk
                // base. No live-canvas receipt is adopted and no producer's
                // envelope is replaced by another replay's temporary slot.
                let staging = folder.appendingPathComponent("\(UUID().uuidString).ink-staging")
                defer { try? FileManager.default.removeItem(at: staging) }
                try draft.drawing.write(to: staging, options: .atomic)
                let resource = try await store.importResource(from: staging, mediaType: "application/vnd.apple.pencilkit")
                let batch = NoteEditBatch(documentID: documentID, expectedRevision: draft.base.revision,
                    title: FloeL10n.l("notes.notes_session.writing"), edits: [.drawing(pageID: draft.pageID, resourceID: resource)])
                do {
                    _ = try await store.applyRebased(batch, base: draft.base)
                } catch NoteError.conflict {
                    try await preserveEditConflict(batch, base: draft.base)
                    errorMessage = String(localized: "edit.conflict.notesPreserved")
                }
                // A failed commit or failed preservation throws before here,
                // retaining exactly this envelope for a later recovery.
                try FileManager.default.removeItem(at: url)
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
                    title: FloeL10n.l("notes.notes_document_editor.restore_strokes"), edits: [.drawing(pageID: pageID, resourceID: resource)]), base: base)
                try FileManager.default.removeItem(at: url)
                errorMessage = String(localized: "edit.conflict.notesPreserved")
            }
            try await reload()
        }
    }

    func retrySaving() {
        for key in pendingInk.keys { scheduleInk(key) }
    }

    private func scheduleInk(_ key: PendingKey) {
        guard scheduledInk.insert(key).inserted else { return }
        enqueue { [self] in
            defer { scheduledInk.remove(key) }
            guard let store else { throw NoteError.resourceUnavailable }
            while let draft = pendingInk[key] {
                // Resolve the effective baseline inside the serialized tail,
                // before the recovery envelope is fixed: adopt our own
                // acknowledged commit only under the full guard set and
                // against the live store state at commit time. The envelope
                // therefore always carries the baseline the commit used.
                let effectiveBase = await acknowledgedBaseIfValid(for: key.pageKey, draft: draft)
                let committedDraft = NoteInkDraft(base: effectiveBase, pageID: draft.pageID, drawing: draft.drawing,
                                                  canvasLineage: draft.canvasLineage, canvasGeneration: draft.canvasGeneration,
                                                  canvasSequence: draft.canvasSequence)
                let folder = try inkRecoveryRoot().appendingPathComponent(key.documentID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let recoveryName: String
                if let lineage = key.lineage {
                    recoveryName = "\(key.pageID.uuidString).\(lineage.uuidString).\(key.generation).inkdraft"
                } else {
                    recoveryName = "\(key.pageID.uuidString).inkdraft"
                }
                let recovery = folder.appendingPathComponent(recoveryName)
                // One atomic envelope retains both bytes and their true baseline.
                try JSONEncoder().encode(committedDraft).write(to: recovery, options: .atomic)
                let staging = folder.appendingPathComponent("\(UUID().uuidString).ink-staging")
                try committedDraft.drawing.write(to: staging, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staging) }
                let resource = try await store.importResource(from: staging, mediaType: "application/vnd.apple.pencilkit")
                let batch = NoteEditBatch(documentID: key.documentID, expectedRevision: effectiveBase.revision,
                    title: FloeL10n.l("notes.notes_session.writing"), edits: [.drawing(pageID: key.pageID, resourceID: resource)])
                do {
                    let saved = try await store.applyRebased(batch, base: effectiveBase)
                    // This page's own acknowledged baseline advances to our
                    // commit only, bound to the producer lineage and
                    // generation that submitted it. A recovery replay (no
                    // provenance) never records one, and a satisfied replay
                    // that returned the current document only counts when the
                    // page still holds the resource this batch installed.
                    if let producerLineage = draft.canvasLineage, let producerGeneration = draft.canvasGeneration,
                       let page = saved.pages.first(where: { $0.id == key.pageID }),
                       page.drawingResourceID == resource {
                        acknowledgedInkBase[key.pageKey] = AcknowledgedInk(base: saved, resourceID: resource,
                            producerLineage: producerLineage, producerGeneration: producerGeneration,
                            producerSequence: draft.canvasSequence ?? 0)
                    }
                    // Newer queued strokes include this accepted local
                    // drawing. This slot belongs to exactly one producer and
                    // generation; its replacement carried a strictly newer
                    // report sequence, and only that newer-sequence final
                    // item may advance to our own commit — never a disk read.
                    if let queued = pendingInk[key], queued.drawing != draft.drawing,
                       draft.canvasSequence == nil
                        || (queued.canvasSequence ?? 0) > (draft.canvasSequence ?? 0) {
                        pendingInk[key]?.base = saved
                    }
                } catch NoteError.conflict {
                    // Preserve exactly what this batch attempted: the copy
                    // builds on the effective (possibly adopted) base.
                    try await preserveEditConflict(batch, base: effectiveBase)
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
        let result = try await commitPreservingConflict(.init(documentID: documentID, expectedRevision: expectedRevision, title: FloeL10n.l("notes.notes_session.edit_content"), edits: edits), base: base)
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

    /// True once for a document created in this app run, so the newly created
    /// Office document opens straight in the editor while a document the user
    /// re-opens later follows the entry-count rule (first entry previews,
    /// later entries edit).
    func consumeEditorOnNextOpen(documentID: UUID) -> Bool {
        editorOnNextOpen.remove(documentID) != nil
    }

    /// - Parameter editorOnFirstOpen: true only for a document authored in
    ///   this app run (`create` / `createOffice`). Imported documents pass the
    ///   default false: their first entry stays the safe read-only preview and
    ///   only the entry-count rule promotes them to the editor later.
    private func showCreatedDocument(_ value: NoteDocument?, editorOnFirstOpen: Bool = false) {
        if editorOnFirstOpen, let value, value.kind == .office { editorOnNextOpen.insert(value.id) }
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
