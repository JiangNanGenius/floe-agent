import Foundation

/// Handle proving that a client observed a particular committed revision.
/// Value type: the store is the authority; a handle alone grants nothing.
public struct MusicSessionHandle: Sendable, Hashable {
    public let sessionID: MusicSessionID
    public let ownerToken: String
    /// Revision this session last reconciled with (its snapshot base).
    public let baseRevision: Int64

    public init(sessionID: MusicSessionID = MusicSessionID(), ownerToken: String,
                baseRevision: Int64) {
        self.sessionID = sessionID
        self.ownerToken = ownerToken
        self.baseRevision = baseRevision
    }
}

public enum MusicSessionState: String, Sendable, Codable, Hashable {
    /// May commit against its base revision.
    case active
    /// Temporarily fenced: commits are rejected until reactivated; used when
    /// the owning surface (AI, render, recording) is backgrounded.
    case inactive
    /// Permanently dead: commits always fail; distinct from inactive.
    case closed
}

public struct MusicStoreConfig: Sendable, Hashable {
    public var maxUndoDepth: Int
    public var maxRedoDepth: Int
    public init(maxUndoDepth: Int = 128, maxRedoDepth: Int = 128) {
        self.maxUndoDepth = max(1, maxUndoDepth)
        self.maxRedoDepth = max(1, maxRedoDepth)
    }
}

/// The single music truth.
///
/// An actor owning the committed `MusicDocument`, bounded undo/redo mementos
/// and the session registry. Every mutation path is:
/// fence (session + base revision) → draft → whole-document validation →
/// persistence → swap. A failed batch changes nothing.
public actor MusicProjectStore {
    public private(set) var document: MusicDocument
    private let repository: any MusicRepository
    private let config: MusicStoreConfig
    private var undoStack: [MusicDocument] = []
    private var redoStack: [MusicDocument] = []
    private var sessions: [MusicSessionID: (ownerToken: String, state: MusicSessionState)] = [:]
    private var pendingWrites: [MusicSessionID: MusicCommitFence] = [:]
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    // Actor isolation alone does not serialize mutations across repository awaits.
    private func acquireMutation() async {
        if !mutationInFlight { mutationInFlight = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationInFlight = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    public init(document: MusicDocument, repository: any MusicRepository,
                config: MusicStoreConfig = MusicStoreConfig()) async throws {
        try document.validate()
        self.document = document
        self.repository = repository
        self.config = MusicStoreConfig(maxUndoDepth: config.maxUndoDepth, maxRedoDepth: config.maxRedoDepth)
        _ = try await repository.save(document: document, expectedRevision: nil)
    }

    private init(restoring document: MusicDocument, repository: any MusicRepository,
                 config: MusicStoreConfig) throws {
        try document.validate()
        self.document = document
        self.repository = repository
        self.config = MusicStoreConfig(maxUndoDepth: config.maxUndoDepth, maxRedoDepth: config.maxRedoDepth)
    }

    /// Open an existing committed document without attempting a create-only save.
    public static func open(projectID: MusicProjectID, repository: any MusicRepository,
                            config: MusicStoreConfig = MusicStoreConfig()) async throws -> MusicProjectStore {
        let document = try await repository.load(projectID: projectID)
        guard document.id == projectID else { throw MusicError.invalidBatch(reason: "repository returned another project") }
        return try MusicProjectStore(restoring: document, repository: repository, config: config)
    }

    // MARK: - Sessions

    /// Open a session fenced at the current committed revision. Late updates
    /// (AI, render, recording) hold a session and must commit against its
    /// base; if the store moved on, the commit fails `.staleRevision`.
    public func beginSession(ownerToken: String) -> MusicSessionHandle {
        let id = MusicSessionID()
        sessions[id] = (ownerToken: ownerToken, state: .active)
        return MusicSessionHandle(sessionID: id, ownerToken: ownerToken,
                                  baseRevision: document.revision)
    }

    public func sessionState(_ handle: MusicSessionHandle) -> MusicSessionState? {
        sessions[handle.sessionID]?.state
    }

    /// Temporarily fence a session (e.g. its owning surface went inactive).
    public func markInactive(_ handle: MusicSessionHandle) throws {
        try mutateSession(handle, expectedOwner: handle.ownerToken) { $0 = .inactive }
    }

    public func reactivate(_ handle: MusicSessionHandle) throws {
        try mutateSession(handle, expectedOwner: handle.ownerToken) { state in
            if state != .closed { state = .active }
        }
    }

    /// Permanently close a session. Closed is terminal and distinct from
    /// inactive: even a correct owner token can never commit again.
    public func close(_ handle: MusicSessionHandle) throws {
        guard let record = sessions[handle.sessionID], record.ownerToken == handle.ownerToken else {
            throw MusicError.staleOwner(session: handle.sessionID.rawValue)
        }
        pendingWrites[handle.sessionID]?.invalidate()
        sessions[handle.sessionID] = (ownerToken: record.ownerToken, state: .closed)
    }

    private func mutateSession(_ handle: MusicSessionHandle,
                               expectedOwner: String,
                               _ change: (inout MusicSessionState) -> Void) throws {
        guard let record = sessions[handle.sessionID] else {
            throw MusicError.staleOwner(session: handle.sessionID.rawValue)
        }
        guard record.ownerToken == expectedOwner else {
            throw MusicError.staleOwner(session: handle.sessionID.rawValue)
        }
        guard record.state != .closed else {
            throw MusicError.sessionClosed(session: handle.sessionID.rawValue)
        }
        var state = record.state
        change(&state)
        if state != .active { pendingWrites[handle.sessionID]?.invalidate() }
        sessions[handle.sessionID] = (ownerToken: record.ownerToken, state: state)
    }

    private func fence(_ handle: MusicSessionHandle, baseRevision: Int64) throws {
        guard let record = sessions[handle.sessionID] else {
            throw MusicError.staleOwner(session: handle.sessionID.rawValue)
        }
        switch record.state {
        case .closed:
            throw MusicError.sessionClosed(session: handle.sessionID.rawValue)
        case .inactive:
            throw MusicError.staleOwner(session: "\(handle.sessionID.rawValue) is inactive")
        case .active:
            break
        }
        guard record.ownerToken == handle.ownerToken else {
            throw MusicError.staleOwner(session: handle.sessionID.rawValue)
        }
        guard handle.baseRevision == baseRevision else {
            throw MusicError.staleRevision(expected: handle.baseRevision, actual: document.revision)
        }
        guard baseRevision == document.revision else {
            throw MusicError.staleRevision(expected: baseRevision, actual: document.revision)
        }
    }

    // MARK: - Commit / undo / redo

    /// Commit a batch. Atomic: the batch applies to a private draft, the
    /// draft is fully validated and persisted, and only then swapped in.
    /// Revision advances exactly once per committed batch (undo/redo too), so
    /// a revision number never aliases two document states.
    @discardableResult
    public func commit(_ batch: MusicEditBatch, as handle: MusicSessionHandle) async throws -> MusicDocument {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        try fence(handle, baseRevision: batch.baseRevision)
        var draft = document
        for op in batch.ops {
            try draft.apply(op)
        }
        draft.revision = try advancedRevision(document.revision)
        draft.updatedAt = Date()
        try draft.validate()
        try await persist(draft, as: handle)
        undoStack.append(document)
        if undoStack.count > config.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        document = draft
        return draft
    }

    /// Bounded undo. Advances revision exactly once (see `commit`).
    @discardableResult
    public func undo(_ handle: MusicSessionHandle) async throws -> MusicDocument {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        try fence(handle, baseRevision: handle.baseRevision)
        guard let previous = undoStack.last else {
            throw MusicError.invalidBatch(reason: "nothing to undo")
        }
        var draft = previous
        draft.revision = try advancedRevision(document.revision)
        draft.updatedAt = Date()
        try draft.validate()
        try await persist(draft, as: handle)
        undoStack.removeLast()
        redoStack.append(document)
        if redoStack.count > config.maxRedoDepth { redoStack.removeFirst() }
        document = draft
        return draft
    }

    /// Bounded redo. Advances revision exactly once.
    @discardableResult
    public func redo(_ handle: MusicSessionHandle) async throws -> MusicDocument {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        try fence(handle, baseRevision: handle.baseRevision)
        guard let next = redoStack.last else {
            throw MusicError.invalidBatch(reason: "nothing to redo")
        }
        var draft = next
        draft.revision = try advancedRevision(document.revision)
        draft.updatedAt = Date()
        try draft.validate()
        try await persist(draft, as: handle)
        redoStack.removeLast()
        undoStack.append(document)
        if undoStack.count > config.maxUndoDepth { undoStack.removeFirst() }
        document = draft
        return draft
    }

    private func persist(_ draft: MusicDocument, as handle: MusicSessionHandle) async throws {
        let commitFence = MusicCommitFence(document: draft, sessionID: handle.sessionID)
        pendingWrites[handle.sessionID] = commitFence
        defer { pendingWrites.removeValue(forKey: handle.sessionID) }
        _ = try await repository.save(document: draft, expectedRevision: document.revision, fence: commitFence)
    }

    private func advancedRevision(_ revision: Int64) throws -> Int64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        if overflow {
            throw MusicError.invalidBatch(reason: "revision counter overflow")
        }
        return next
    }

    /// Render/preview entrypoint: the committed document, revalidated, as an
    /// immutable snapshot. Runtime consumers must treat it as read-only.
    public func currentSnapshot() throws -> MusicDocument {
        try document.validate()
        return document
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoDepth: Int { undoStack.count }
    public var redoDepth: Int { redoStack.count }
}
