import CryptoKit
import Foundation
import FloeCanvasCore

/// Deterministic SHA-256 over a canonical JSON encoding. The encoding sorts
/// keys so equal batches always hash equal — replay detection depends on it.
/// Generic so both `CanvasEditBatch` and `CanvasDocumentBatch` replay
/// through the same digest.
enum CanvasBatchDigest {
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }
}

/// One undo/redo unit: the full snapshot before the step plus its label.
public struct CanvasHistoryFrame: Codable, Hashable, Sendable {
    public var snapshotBefore: CanvasSnapshot
    public var label: String

    public init(snapshotBefore: CanvasSnapshot, label: String) {
        self.snapshotBefore = snapshotBefore
        self.label = label
    }
}

/// Persisted history state of one canvas: both stacks plus the applied
/// entries shown by host UI. Revisions inside `snapshotBefore` are the
/// content revisions at the time; the applied step always re-bases them
/// onto the current revision + 1.
public struct CanvasHistoryState: Codable, Hashable, Sendable {
    public var undoStack: [CanvasHistoryFrame]
    public var redoStack: [CanvasHistoryFrame]
    public var appliedEntries: [CanvasUndoEntry]

    public init(
        undoStack: [CanvasHistoryFrame] = [],
        redoStack: [CanvasHistoryFrame] = [],
        appliedEntries: [CanvasUndoEntry] = []
    ) {
        self.undoStack = undoStack
        self.redoStack = redoStack
        self.appliedEntries = appliedEntries
    }
}

/// Persistence sink the engine calls after every successful mutation.
/// Implementations must be atomic: either the whole sink call lands or the
/// previous state remains loadable. The full history state is delivered
/// with every call so sinks persist it without a second query.
public protocol CanvasPersistenceSink: Sendable {
    func didCommit(
        snapshot: CanvasSnapshot,
        receipt: CanvasCommitReceipt,
        history: CanvasHistoryState
    ) throws
    /// Called after a successful undo OR redo (both persist the same way).
    func didApplyHistory(
        snapshot: CanvasSnapshot,
        receipt: CanvasCommitReceipt,
        history: CanvasHistoryState
    ) throws
}

/// Value-owned repository core shared by the actor-isolated in-memory store
/// and the file store's document-lock transaction. All invariants (expected
/// revision, idempotent request IDs, one batch = one undo unit) live here.
public struct CanvasRepositoryEngine: Sendable {
    private var snapshot: CanvasSnapshot
    private var receiptsByRequestID: [UUID: CanvasCommitReceipt]
    /// Request IDs already consumed by OTHER canvases in the same store.
    /// Receipts are never reusable across files: a known-foreign request ID
    /// is rejected instead of being treated as new.
    private let foreignRequestIDs: Set<UUID>
    private var undoStack: [CanvasHistoryFrame] = []
    private var redoStack: [CanvasHistoryFrame] = []
    private var appliedUndoEntries: [CanvasUndoEntry] = []
    private let sink: CanvasPersistenceSink?

    public init(
        snapshot: CanvasSnapshot,
        existingReceipts: [UUID: CanvasCommitReceipt] = [:],
        foreignRequestIDs: Set<UUID> = [],
        historyState: CanvasHistoryState = CanvasHistoryState(),
        sink: CanvasPersistenceSink? = nil
    ) {
        self.snapshot = snapshot
        self.receiptsByRequestID = existingReceipts
        self.foreignRequestIDs = foreignRequestIDs
        self.undoStack = historyState.undoStack
        self.redoStack = historyState.redoStack
        self.appliedUndoEntries = historyState.appliedEntries
        self.sink = sink
    }

    private var historyState: CanvasHistoryState {
        CanvasHistoryState(
            undoStack: undoStack,
            redoStack: redoStack,
            appliedEntries: appliedUndoEntries
        )
    }

    public func load() -> CanvasSnapshot { snapshot }

    /// Post-mutation state for persistence pipelines.
    public func snapshotForPersistence() -> CanvasSnapshot { snapshot }

    public func historyForPersistence() -> CanvasHistoryState { historyState }
    public func receiptsForPersistence() -> [UUID: CanvasCommitReceipt] { receiptsByRequestID }

    public mutating func commit(
        _ batch: CanvasEditBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) throws -> CanvasCommitReceipt {
        let batchHash = try CanvasBatchDigest.hash(batch)
        return try commitMutation(
            batchHash: batchHash,
            canvasID: canvasID,
            expectedRevision: expectedRevision,
            requestID: requestID,
            label: batchLabel(batch)
        ) { current in
            try CanvasEditEngine.apply(batch, to: current).snapshot
        }
    }

    /// P0.1 document transactions ride the SAME pipeline: one CAS check,
    /// one idempotency domain, one undo unit per batch, one persistence
    /// rollback boundary. No second store.
    public mutating func commitDocument(
        _ batch: CanvasDocumentBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) throws -> CanvasCommitReceipt {
        let batchHash = try CanvasBatchDigest.hash(batch)
        return try commitMutation(
            batchHash: batchHash,
            canvasID: canvasID,
            expectedRevision: expectedRevision,
            requestID: requestID,
            label: documentBatchLabel(batch)
        ) { current in
            try CanvasDocumentEditEngine.apply(batch, to: current).snapshot
        }
    }

    /// Shared mutation core for `commit` and `commitDocument`.
    private mutating func commitMutation(
        batchHash: String,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID,
        label: String,
        apply: (CanvasSnapshot) throws -> CanvasSnapshot
    ) throws -> CanvasCommitReceipt {
        guard canvasID == snapshot.id else {
            throw CanvasKitError.missingEntity("canvas \(canvasID)")
        }

        // Idempotency: same request ID + same bytes replays the original
        // receipt without a second mutation; same ID + different bytes is a
        // hard rejection; IDs already consumed by another canvas are never
        // reusable here.
        if let existing = receiptsByRequestID[requestID] {
            if existing.batchHash == batchHash {
                return existing
            }
            throw CanvasKitError.requestIDConflict(requestID: requestID)
        }
        if foreignRequestIDs.contains(requestID) {
            throw CanvasKitError.requestIDConflict(requestID: requestID)
        }

        guard expectedRevision == snapshot.revision else {
            throw CanvasKitError.revisionConflict(
                expected: expectedRevision, current: snapshot.revision)
        }

        let previous = snapshot
        var next = try apply(previous)
        next.revision = previous.revision + 1
        next.updatedAt = Date()

        let receipt = CanvasCommitReceipt(
            requestID: requestID,
            canvasID: canvasID,
            previousRevision: previous.revision,
            revision: next.revision,
            batchHash: batchHash
        )
        snapshot = next
        undoStack.append(CanvasHistoryFrame(snapshotBefore: previous, label: label))
        redoStack.removeAll()
        receiptsByRequestID[requestID] = receipt
        if let sink {
            // Best-effort persistence: a sink failure rolls the in-memory
            // state back so memory and disk never disagree silently.
            do {
                try sink.didCommit(
                    snapshot: next, receipt: receipt,
                    history: historyState)
            } catch {
                snapshot = previous
                undoStack.removeLast()
                receiptsByRequestID[requestID] = nil
                throw CanvasKitError.io("commit persistence failed: \(error)")
            }
        }
        return receipt
    }

    public mutating func undo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) throws -> CanvasCommitReceipt {
        try applyHistoryStep(
            .undo, canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    public mutating func redo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) throws -> CanvasCommitReceipt {
        try applyHistoryStep(
            .redo, canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    private enum HistoryStep: String {
        case undo, redo
    }

    /// Shared strict undo/redo: expected-revision check, request-ID
    /// idempotency (repeating a consumed request never applies the step
    /// twice), revision always increases, redo cleared by any new commit,
    /// and a persistence failure rolls everything back so the previous
    /// records remain intact.
    private mutating func applyHistoryStep(
        _ step: HistoryStep,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) throws -> CanvasCommitReceipt {
        guard canvasID == snapshot.id else {
            throw CanvasKitError.missingEntity("canvas \(canvasID)")
        }

        let batchHash = "\(step.rawValue):\(expectedRevision)"
        if let existing = receiptsByRequestID[requestID] {
            if existing.batchHash == batchHash {
                return existing
            }
            throw CanvasKitError.requestIDConflict(requestID: requestID)
        }
        if foreignRequestIDs.contains(requestID) {
            throw CanvasKitError.requestIDConflict(requestID: requestID)
        }
        guard expectedRevision == snapshot.revision else {
            throw CanvasKitError.revisionConflict(
                expected: expectedRevision, current: snapshot.revision)
        }

        let frame: CanvasHistoryFrame
        switch step {
        case .undo:
            guard let top = undoStack.popLast() else {
                throw CanvasKitError.missingEntity("nothing to undo for \(canvasID)")
            }
            frame = top
        case .redo:
            guard let top = redoStack.popLast() else {
                throw CanvasKitError.missingEntity("nothing to redo for \(canvasID)")
            }
            frame = top
        }

        let previous = snapshot
        var next = frame.snapshotBefore
        next.revision = previous.revision + 1
        next.updatedAt = Date()

        let receipt = CanvasCommitReceipt(
            requestID: requestID,
            canvasID: canvasID,
            previousRevision: previous.revision,
            revision: next.revision,
            batchHash: batchHash
        )
        snapshot = next
        receiptsByRequestID[requestID] = receipt
        switch step {
        case .undo:
            redoStack.append(CanvasHistoryFrame(snapshotBefore: previous, label: frame.label))
        case .redo:
            undoStack.append(CanvasHistoryFrame(snapshotBefore: previous, label: frame.label))
        }
        appliedUndoEntries.insert(CanvasUndoEntry(
            canvasID: canvasID,
            restoresRevision: frame.snapshotBefore.revision,
            resultingRevision: next.revision,
            label: "\(step.rawValue): \(frame.label)"
        ), at: 0)
        if let sink {
            do {
                try sink.didApplyHistory(
                    snapshot: next, receipt: receipt,
                    history: historyState)
            } catch {
                snapshot = previous
                receiptsByRequestID[requestID] = nil
                appliedUndoEntries.removeFirst()
                switch step {
                case .undo:
                    undoStack.append(frame)
                    redoStack.removeLast()
                case .redo:
                    redoStack.append(frame)
                    undoStack.removeLast()
                }
                throw CanvasKitError.io("\(step.rawValue) persistence failed: \(error)")
            }
        }
        return receipt
    }

    public func undoHistory(canvasID: UUID) -> [CanvasUndoEntry] {
        appliedUndoEntries.filter { $0.canvasID == canvasID }
    }
    public func historyAvailability(canvasID: UUID) throws -> CanvasHistoryAvailability {
        guard snapshot.id == canvasID else { throw CanvasKitError.missingEntity("canvas \(canvasID)") }
        return .init(undoCount: undoStack.count, redoCount: redoStack.count)
    }

    private func batchLabel(_ batch: CanvasEditBatch) -> String {
        guard let first = batch.operations.first else { return "empty batch" }
        switch first {
        case .insertNode: return "insert node"
        case .updateContent: return "update content"
        case .updateTitle: return "update title"
        case .move: return "move"
        case .resize: return "resize"
        case .setLocked: return "lock change"
        case .removeNode: return "remove node"
        case .insertConnection: return "connect"
        case .removeConnection: return "disconnect"
        case .setRegionCollapsed: return "region fold"
        case .setPencilDrawingData: return "pencil drawing"
        }
    }

    private func documentBatchLabel(_ batch: CanvasDocumentBatch) -> String {
        guard let first = batch.operations.first else { return "empty document batch" }
        switch first {
        case .updateCanvasMetadata: return "update canvas metadata"
        case .renameCanvas: return "rename canvas"
        case .setPageBackground: return "page background"
        case .setViewport: return "viewport"
        case .createPage: return "create page"
        case .renamePage: return "rename page"
        case .reorderPages: return "reorder pages"
        case .deletePage: return "delete page"
        case .selectPage: return "select page"
        case .createGroup: return "create group"
        case .updateGroup: return "update group"
        case .removeGroup: return "remove group"
        case .moveGroup: return "move group"
        case .createRegion: return "create region"
        case .updateRegion: return "update region"
        case .removeRegion: return "remove region"
        case .createScene: return "create scene"
        case .updateScene: return "update scene"
        case .removeScene: return "remove scene"
        case .addStroke: return "add stroke"
        case .updateStroke: return "update stroke"
        case .removeStroke: return "remove stroke"
        case .editPage: return "edit page"
        case .updateNodeSource: return "update node source"
        case .updateNodeRotation: return "update node rotation"
        case .updateNodeStyle: return "update node style"
        case .updateNodeMetadata: return "update node metadata"
        case .insertFlowGraph: return "insert flow graph"
        case .replaceFlowGraph: return "update flow graph"
        case .removeFlowGraph: return "remove flow graph"
        }
    }
}

// MARK: - In-memory qualification repository

/// Working in-memory store. CAS is implicit: replaying an identical request
/// returns the same receipt without mutation.
public actor InMemoryCanvasRepository: CanvasDocumentStore {
    private var engine: CanvasRepositoryEngine

    public init(snapshot: CanvasSnapshot) {
        self.engine = CanvasRepositoryEngine(snapshot: snapshot)
    }

    /// Test/qualification hook: an engine with an injected failing sink.
    init(snapshot: CanvasSnapshot, sink: CanvasPersistenceSink) {
        self.engine = CanvasRepositoryEngine(snapshot: snapshot, sink: sink)
    }

    public func load(canvasID: UUID) async throws -> CanvasSnapshot {
        let snapshot = engine.load()
        guard snapshot.id == canvasID else {
            throw CanvasKitError.missingEntity("canvas \(canvasID)")
        }
        return snapshot
    }

    public func commit(
        _ batch: CanvasEditBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try engine.commit(
            batch, canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    public func commitDocument(
        _ batch: CanvasDocumentBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try engine.commitDocument(
            batch, canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    public func undo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try engine.undo(
            canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    public func redo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try engine.redo(
            canvasID: canvasID,
            expectedRevision: expectedRevision, requestID: requestID)
    }

    public func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] {
        engine.undoHistory(canvasID: canvasID)
    }

    public func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability {
        try engine.historyAvailability(canvasID: canvasID)
    }
}
