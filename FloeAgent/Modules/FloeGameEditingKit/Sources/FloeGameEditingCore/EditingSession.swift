// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A project-bound editing session. AI and manual edits go through the same
/// byte-level edit machinery, so they share one repository, one expected
/// revision, one undo/redo stack and one diff history.
@MainActor
public final class GameEditingSession: ObservableObject {
    public let repository: FileGameProjectRepository
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let adapter: any GameEditingAdapter
    public private(set) var baseProject: GameStoredProject
    public private(set) var expectedRevision: String

    @Published public private(set) var documents: [GameRelativePath: EditingDocument] = [:]
    @Published public private(set) var removedPaths: Set<GameRelativePath> = []
    @Published public private(set) var history: [GameEditRecord] = []
    @Published public private(set) var pendingDraft: DraftSummary?
    @Published public private(set) var conflict: GameProjectError?
    @Published public private(set) var fileConflicts: [GameRelativePath: FileRebaseConflict] = [:]
    @Published public private(set) var diagnostics: [GameEditDiagnostic] = []
    /// One mutation may suspend in the repository. Another mutation must not
    /// change these buffers until it resumes, especially while saving.
    @Published public private(set) var isBusy = false

    private var undoStack: [SessionEdit] = []
    private var redoStack: [SessionEdit] = []
    private var sequence = 0
    private let draftStore: EditingDraftStore
    private static let historyLimit = 200
    /// Shared by image and structured editors. Clamped to keep encoded
    /// recovery metadata below its existing 32 MiB reader limit.
    public let maximumUndoBytes: Int

    /// Host hook for full project/archive imports into this existing
    /// project. The component's own import covers single assets only.
    public var projectImportHost: (any GameProjectImportHost)?

    public init(repository: FileGameProjectRepository, repositoryDirectory: URL,
                projectID: UUID, owner: GameProjectOwner,
                adapter: any GameEditingAdapter, baseProject: GameStoredProject,
                maximumUndoBytes: Int = 16 * 1_024 * 1_024) {
        self.repository = repository
        self.projectID = projectID
        self.owner = owner
        self.adapter = adapter
        self.baseProject = baseProject
        self.expectedRevision = baseProject.revision
        self.maximumUndoBytes = max(1, min(16 * 1_024 * 1_024, maximumUndoBytes))
        self.draftStore = EditingDraftStore(repositoryDirectory: repositoryDirectory)
    }

    public static func open(repository: FileGameProjectRepository, projectID: UUID, owner: GameProjectOwner,
                            adapter: any GameEditingAdapter,
                            maximumUndoBytes: Int = 16 * 1_024 * 1_024) async throws -> GameEditingSession {
        let stored = try await repository.open(projectID, owner: owner)
        let directory = await repository.directory
        let session = GameEditingSession(repository: repository, repositoryDirectory: directory,
                                         projectID: projectID, owner: owner,
                                         adapter: adapter, baseProject: stored, maximumUndoBytes: maximumUndoBytes)
        session.detectDraft()
        return session
    }

    // MARK: - Queries

    public var isDirty: Bool {
        if !removedPaths.isEmpty { return true }
        return documents.values.contains { $0.isDirty }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoSummary: GameEditCopy? { undoStack.last?.summary }
    public var redoSummary: GameEditCopy? { redoStack.last?.summary }

    func beginOperation() throws {
        guard !isBusy else {
            throw GameEditIssue([GameEditDiagnostic(severity: .info,
                message: GameEditCopy("Wait for the current edit to finish.", "请等待当前编辑操作完成。"))])
        }
        isBusy = true
    }

    func endOperation() { isBusy = false }

    /// Adopt a completed host import without discarding unsaved edits. The
    /// repository retains all previous revisions; stale working edits must
    /// use the existing conflict/rebase flow instead of being overwritten.
    public func refreshAfterProjectImport() async throws {
        try beginOperation(); defer { endOperation() }
        guard !isDirty, pendingDraft == nil else { throw GameProjectError.invalidEdit }
        let current = try await repository.open(projectID, owner: owner)
        guard !isDirty, pendingDraft == nil else {
            let failure = GameProjectError.conflict(expected: expectedRevision, actual: current.revision)
            conflict = failure; throw failure
        }
        baseProject = current; expectedRevision = current.revision
        documents.removeAll(); removedPaths.removeAll()
        undoStack.removeAll(); redoStack.removeAll()
        conflict = nil; fileConflicts.removeAll(); diagnostics.removeAll()
    }

    /// Byte state of a document (edited working copy wins).
    public func documentBytes(at path: GameRelativePath) async throws -> Data {
        if let document = documents[path] { return document.currentBytes }
        guard baseProject.files.contains(where: { $0.path == path }) else {
            throw GameProjectError.unreadableFile(path.value)
        }
        return try await bytesAtSessionRevision(path)
    }

    /// An external save must not discard a gesture made against the image
    /// already displayed by this session. Read its immutable base revision;
    /// the subsequent save still uses the original CAS and requires the
    /// existing explicit conflict decision before replacing external bytes.
    private func bytesAtSessionRevision(_ path: GameRelativePath) async throws -> Data {
        let revision = expectedRevision
        do {
            return try await repository.read(projectID, owner: owner, revision: revision, path: path)
        } catch GameProjectError.conflict {
            let current = try await repository.open(projectID, owner: owner)
            return try await repository.readHistorical(projectID, owner: owner,
                expectedRevision: current.revision, historicalRevision: revision, path: path)
        }
    }

    public func documentExists(at path: GameRelativePath) -> Bool {
        if removedPaths.contains(path) { return false }
        if documents[path] != nil { return true }
        return baseProject.files.contains(where: { $0.path == path })
    }

    public func isDocumentDirty(at path: GameRelativePath) -> Bool { documents[path]?.isDirty ?? false }

    /// Base bytes at the session revision (cached per document).
    private func baseBytes(at path: GameRelativePath, document: EditingDocument?) async throws -> Data? {
        if let document { return document.baseBytes }
        guard baseProject.files.contains(where: { $0.path == path }) else { return nil }
        return try await bytesAtSessionRevision(path)
    }

    // MARK: - Core edit machinery

    /// Applies one edit: records undo/history, marks the working set dirty
    /// and persists the recovery draft. All editor families route through here.
    public func apply(_ edit: SessionEdit) async throws {
        try beginOperation(); defer { endOperation() }
        try await applyDuringOperation(edit)
    }

    /// Internal compound edits already own the session operation. Do not
    /// acquire another operation or expose this to host callers.
    func applyDuringOperation(_ edit: SessionEdit) async throws {
        try await apply(edit, recordHistory: true)
        undoStack.append(edit)
        redoStack.removeAll()
        trimUndoHistory()
        try persistDraft()
    }

    public func undo() async throws {
        try beginOperation(); defer { endOperation() }
        guard let edit = undoStack.last else { return }
        try await revert(edit)
        undoStack.removeLast()
        redoStack.append(edit)
        record(.undo, summary: edit.summary, path: edit.primaryPath, byteDelta: 0)
        try persistDraft()
    }

    public func redo() async throws {
        try beginOperation(); defer { endOperation() }
        guard let edit = redoStack.last else { return }
        try await apply(edit, recordHistory: false)
        redoStack.removeLast()
        undoStack.append(edit)
        record(.redo, summary: edit.summary, path: edit.primaryPath, byteDelta: 0)
        try persistDraft()
    }

    private func trimUndoHistory() {
        func totalBytes() -> Int {
            (undoStack + redoStack).reduce(0) { total, edit in
                let sum = total.addingReportingOverflow(edit.retainedByteCount)
                return sum.overflow ? Int.max : sum.partialValue
            }
        }
        while undoStack.count + redoStack.count > Self.historyLimit || totalBytes() > maximumUndoBytes {
            // Drop the farthest history first; the current document/draft is
            // retained independently, even when one edit exceeds the budget.
            if undoStack.count > 1 { undoStack.removeFirst() }
            else if !redoStack.isEmpty { redoStack.removeFirst() }
            else if !undoStack.isEmpty { undoStack.removeFirst() }
            else { break }
        }
    }

    /// Decode -> mutate -> encode against the current working bytes. The
    /// pre-edit bytes are always captured (from the working set or the base
    /// revision) so undo restores the exact original, not a fallback read.
    public func editDocument(at path: GameRelativePath, summary: GameEditCopy,
                             _ mutate: (Data) throws -> Data) async throws {
        try beginOperation(); defer { endOperation() }
        let current = try await documentBytes(at: path)
        let before: Data?
        if let document = documents[path] {
            before = document.currentBytes
        } else if documentExists(at: path) {
            before = current
        } else {
            before = nil
        }
        let after = try mutate(current)
        guard after != before else { return }
        try await applyDuringOperation(.update(path: path, before: before, after: after, summary: summary))
    }

    private func apply(_ edit: SessionEdit, recordHistory: Bool) async throws {
        switch edit {
        case .update(let path, _, let after, _):
            let base = try await baseBytes(at: path, document: documents[path])
            documents[path] = EditingDocument(path: path, baseBytes: base, currentBytes: after)
            removedPaths.remove(path)
        case .move(let from, let to, let before, let referenceUpdates, _):
            let originalBase = try await baseBytes(at: from, document: documents[from])
            documents[from] = originalBase.map { EditingDocument(path: from, baseBytes: $0, currentBytes: before) }
            documents[to] = EditingDocument(path: to, baseBytes: nil, currentBytes: before)
            if baseProject.files.contains(where: { $0.path == from }) { removedPaths.insert(from) }
            for update in referenceUpdates {
                let base = try await baseBytes(at: update.path, document: documents[update.path])
                documents[update.path] = EditingDocument(path: update.path, baseBytes: base, currentBytes: update.after)
            }
        case .remove(let path, _, let referenceUpdates, _):
            let originalBase = try await baseBytes(at: path, document: documents[path])
            documents[path] = originalBase.map { EditingDocument(path: path, baseBytes: $0, currentBytes: $0) }
            if baseProject.files.contains(where: { $0.path == path }) { removedPaths.insert(path) }
            for update in referenceUpdates {
                let base = try await baseBytes(at: update.path, document: documents[update.path])
                documents[update.path] = EditingDocument(path: update.path, baseBytes: base, currentBytes: update.after)
            }
        }
        guard recordHistory else { return }
        let delta: Int
        switch edit {
        case .update(_, let before, let after, _): delta = after.count - (before?.count ?? 0)
        case .move(_, _, let before, _, _): delta = before.count
        case .remove(_, let before, _, _): delta = -before.count
        }
        record(.apply, summary: edit.summary, path: edit.primaryPath, byteDelta: delta)
    }

    private func revert(_ edit: SessionEdit) async throws {
        switch edit {
        case .update(let path, let before, _, _):
            if let before {
                documents[path]?.currentBytes = before
            } else {
                documents[path] = nil
                removedPaths.remove(path)
            }
        case .move(let from, let to, let before, let referenceUpdates, _):
            documents[to] = nil
            removedPaths.remove(from)
            let base = try await baseBytes(at: from, document: nil)
            documents[from] = EditingDocument(path: from, baseBytes: base, currentBytes: before)
            for update in referenceUpdates {
                documents[update.path]?.currentBytes = update.before
            }
        case .remove(let path, let before, let referenceUpdates, _):
            removedPaths.remove(path)
            let base = try await baseBytes(at: path, document: nil)
            documents[path] = EditingDocument(path: path, baseBytes: base, currentBytes: before)
            for update in referenceUpdates {
                documents[update.path]?.currentBytes = update.before
            }
        }
    }

    private func record(_ operation: GameEditRecord.Operation, summary: GameEditCopy,
                        path: GameRelativePath?, byteDelta: Int) {
        sequence += 1
        history.append(.init(id: sequence, sequence: sequence, atUTC: Date(), operation: operation,
                             summary: summary, path: path, byteDelta: byteDelta))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    // MARK: - Save / conflict / rebase

    /// Pushes all pending edits as one atomic repository commit. Throws
    /// GameProjectError.conflict when HEAD moved; `reloadForRebase()` then
    /// reconciles file-by-file.
    @discardableResult
    public func save(title: String? = nil) async throws -> GameStoredProject {
        try beginOperation(); defer { endOperation() }
        guard fileConflicts.isEmpty else {
            throw GameEditIssue(fileConflicts.values.map {
                GameEditDiagnostic(severity: .error, message: $0.blockingCopy, path: $0.path)
            })
        }
        var changes: [GameFileChange] = []
        for path in removedPaths.sorted(by: { $0.value < $1.value }) {
            changes.append(.remove(path))
        }
        for (path, document) in documents
        where document.isDirty && !removedPaths.contains(path) {
            changes.append(.write(path, document.currentBytes))
        }
        do {
            let stored = try await repository.commit(projectID, owner: owner, expectedRevision: expectedRevision,
                                                     changes: changes, title: title)
            let previousDocuments = documents
            expectedRevision = stored.revision
            baseProject = stored
            documents = previousDocuments.reduce(into: [:]) { result, pair in
                let (path, document) = pair
                guard !removedPaths.contains(path) else { return }
                if document.isNew || document.isDirty {
                    result[path] = EditingDocument(path: path, baseBytes: document.currentBytes,
                                                   currentBytes: document.currentBytes)
                }
            }
            removedPaths.removeAll()
            conflict = nil
            try? draftStore.clear(projectID: projectID)
            pendingDraft = nil
            return stored
        } catch let error as GameProjectError {
            if case .conflict(let expected, let actual) = error {
                conflict = .conflict(expected: expected, actual: actual)
                diagnostics = [GameEditDiagnostic(severity: .warning,
                    message: GameEditCopy("The project changed elsewhere. Review conflicts before saving.",
                                          "项目在其他地方有改动，保存前请先处理冲突。"))]
            }
            throw error
        }
    }

    /// Re-reads HEAD after a conflict and carries local edits forward.
    /// Files changed externally and locally become per-file conflicts the
    /// user resolves explicitly; everything else rebases cleanly.
    public func reloadForRebase() async throws {
        try beginOperation(); defer { endOperation() }
        guard conflict != nil else { return }
        let current = try await repository.open(projectID, owner: owner)
        try await rebase(onto: current)
    }

    private func rebase(onto current: GameStoredProject) async throws {
        var resolved: [GameRelativePath: FileRebaseConflict] = [:]
        for (path, document) in documents where document.isDirty && !removedPaths.contains(path) {
            let bytes: Data?
            if current.files.contains(where: { $0.path == path }) {
                bytes = try await repository.read(projectID, owner: owner, revision: current.revision, path: path)
            } else {
                bytes = nil // removed externally
            }
            if bytes == document.baseBytes {
                documents[path]?.baseBytes = bytes // carry edits forward
            } else if let bytes, bytes == document.currentBytes {
                documents[path]?.baseBytes = bytes // identical content, clean
            } else {
                resolved[path] = FileRebaseConflict(path: path,
                    baseBytes: document.baseBytes ?? Data(),
                    theirsBytes: bytes ?? Data(),
                    mineBytes: document.currentBytes, remoteDeletion: bytes == nil)
            }
        }
        // Files removed externally while untouched locally: accept removal.
        for path in Array(removedPaths) {
            guard current.files.contains(where: { $0.path == path }) else {
                removedPaths.remove(path); documents[path] = nil
                continue
            }
            let theirs = try await repository.read(projectID, owner: owner, revision: current.revision, path: path)
            let base: Data
            if let retained = documents[path]?.baseBytes { base = retained }
            else {
                base = try await repository.readHistorical(projectID, owner: owner,
                    expectedRevision: current.revision, historicalRevision: baseProject.revision, path: path)
                documents[path] = .init(path: path, baseBytes: base, currentBytes: base)
            }
            if theirs != base {
                resolved[path] = .init(path: path, baseBytes: base, theirsBytes: theirs,
                    mineBytes: Data(), localDeletion: true)
            }
        }
        for (path, document) in documents where !document.isDirty && !removedPaths.contains(path) {
            if current.files.contains(where: { $0.path == path }) {
                let bytes = try await repository.read(projectID, owner: owner, revision: current.revision, path: path)
                documents[path] = .init(path: path, baseBytes: bytes, currentBytes: bytes)
            } else { documents[path] = nil }
        }
        expectedRevision = current.revision
        baseProject = current
        conflict = nil
        fileConflicts = resolved
        diagnostics = resolved.values.map {
                GameEditDiagnostic(severity: .error, message: $0.blockingCopy, path: $0.path)
        }
        pendingDraft = nil
        try persistDraft()
    }

    public enum ConflictResolution: Sendable {
        case keepMine
        case keepTheirs
    }

    public func resolveConflict(at path: GameRelativePath, _ resolution: ConflictResolution) throws {
        try beginOperation(); defer { endOperation() }
        guard let file = fileConflicts[path] else { return }
        switch resolution {
        case .keepMine:
            if file.localDeletion {
                removedPaths.insert(path)
                documents[path] = .init(path: path, baseBytes: file.theirsBytes, currentBytes: file.theirsBytes)
            } else {
                removedPaths.remove(path)
                documents[path] = .init(path: path, baseBytes: file.remoteDeletion ? nil : file.theirsBytes, currentBytes: file.mineBytes)
            }
        case .keepTheirs:
            removedPaths.remove(path)
            documents[path] = file.remoteDeletion ? nil : .init(path: path, baseBytes: file.theirsBytes, currentBytes: file.theirsBytes)
        }
        fileConflicts[path] = nil
        diagnostics = fileConflicts.values.map {
            GameEditDiagnostic(severity: .error, message: $0.blockingCopy, path: $0.path)
        }
        pendingDraft = nil
        try persistDraft()
    }

    // MARK: - Drafts (unsaved recovery)

    private func detectDraft() {
        do {
            guard let draft = try draftStore.loadRetained(projectID: projectID, owner: owner) else {
                return
            }
            pendingDraft = DraftSummary(baseRevision: draft.baseRevision, savedAtUTC: draft.savedAtUTC,
                                        editCount: draft.undoStack.count + draft.redoStack.count,
                                        documentCount: draft.documents.count)
            if draft.baseRevision != expectedRevision {
                diagnostics = [.init(severity: .warning, message: GameEditCopy(
                    "The project changed after this draft. Recover it to review conflicts.",
                    "项目在草稿保存后有更新，请恢复草稿并检查冲突。"))]
            }
        } catch {
            // Owner mismatch / corrupt draft: keep the draft on disk untouched.
            diagnostics = [GameEditDiagnostic(severity: .warning,
                message: GameEditCopy("Unsaved draft could not be read and was left in place.",
                                      "无法读取未保存草稿，已原样保留。"))]
        }
    }

    /// Restores working bytes, undo/redo stacks and history from the draft.
    public func recoverDraft() async throws {
        try beginOperation(); defer { endOperation() }
        guard let summary = pendingDraft else { return }
        guard let draft = try draftStore.load(projectID: projectID, owner: owner, headRevision: summary.baseRevision) else {
            pendingDraft = nil
            return
        }
        let revisions = try await repository.history(projectID, owner: owner, limit: 1_024)
        guard let head = revisions.first, let original = revisions.first(where: { $0.revision == draft.baseRevision }) else {
            throw GameProjectError.invalidEdit
        }
        var restored: [GameRelativePath: EditingDocument] = [:]
        for entry in draft.documents {
            let current = try draftStore.loadBlob(digest: entry.currentDigest, projectID: projectID)
            let base: Data?
            if let digest = entry.baseDigest {
                if try draftStore.containsBlob(digest: digest, projectID: projectID) {
                    base = try draftStore.loadBlob(digest: digest, projectID: projectID)
                } else {
                    base = try await repository.readHistorical(projectID, owner: owner,
                        expectedRevision: head.revision, historicalRevision: draft.baseRevision, path: entry.path)
                }
                guard base.map(GameDigest.sha256) == digest else { throw GameProjectError.corruptStorage }
            } else {
                base = nil
            }
            restored[entry.path] = EditingDocument(path: entry.path, baseBytes: base, currentBytes: current)
        }
        for path in draft.removedPaths where restored[path] == nil {
            let base = try await repository.readHistorical(projectID, owner: owner,
                expectedRevision: head.revision, historicalRevision: draft.baseRevision, path: path)
            restored[path] = .init(path: path, baseBytes: base, currentBytes: base)
        }
        documents = restored
        baseProject = original; expectedRevision = original.revision
        removedPaths = Set(draft.removedPaths)
        undoStack = draft.undoStack
        redoStack = draft.redoStack
        trimUndoHistory()
        history = draft.history
        sequence = history.last?.sequence ?? 0
        pendingDraft = nil
        let latest = try await repository.open(projectID, owner: owner)
        try await rebase(onto: latest)
    }

    public func discardDraft() throws {
        try beginOperation(); defer { endOperation() }
        try draftStore.clear(projectID: projectID)
        pendingDraft = nil
    }

    /// Call before leaving visual editing for the existing IDE, AI or play.
    /// The host still fences workspace/lifecycle changes and saves its own
    /// IDE buffers. This saves this session only, with the existing CAS path.
    public func prepareForHandoff() async throws -> GameStoredProject {
        guard pendingDraft == nil, conflict == nil, fileConflicts.isEmpty else {
            throw GameEditIssue([GameEditDiagnostic(severity: .warning,
                message: GameEditCopy("Recover the draft or resolve conflicts before continuing.",
                                      "请先处理草稿或文件冲突，再继续。"))])
        }
        if isDirty { return try await save() }
        try await refreshAfterProjectImport()
        return baseProject
    }

    private func persistDraft() throws {
        guard isDirty else {
            try? draftStore.clear(projectID: projectID)
            return
        }
        var entries: [EditingDraft.DraftDocument] = []
        for document in documents.values.sorted(by: { $0.path.value < $1.path.value }) {
            let digest = GameDigest.sha256(document.currentBytes)
            try draftStore.saveBlob(document.currentBytes, digest: digest, projectID: projectID)
            if let base = document.baseBytes { try draftStore.saveBlob(base, digest: GameDigest.sha256(base), projectID: projectID) }
            entries.append(.init(path: document.path,
                                 baseDigest: document.baseBytes.map { GameDigest.sha256($0) },
                                 currentDigest: digest))
        }
        let draft = EditingDraft(formatVersion: 1, projectID: projectID, owner: owner,
                                 baseRevision: expectedRevision, savedAtUTC: Date(),
                                 undoStack: undoStack, redoStack: redoStack, history: history,
                                 documents: entries, removedPaths: removedPaths.sorted { $0.value < $1.value })
        try draftStore.save(draft)
    }
}

extension FileRebaseConflict {
    public var blockingCopy: GameEditCopy {
        GameEditCopy("\"\(path.value)\" changed here and elsewhere; resolve before saving.",
                     "“\(path.value)”在本地和其他地方都有改动，保存前请先解决。")
    }
}
