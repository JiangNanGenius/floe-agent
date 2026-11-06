import Foundation
import FloeCanvasCore

// MARK: - Runtime context
//
// Every Integration callback that can trigger work carries an explicit
// context. Files, templates and imported documents never grant permissions;
// the context binds work to the actual document revision, an owning task and
// an explicit environment. Hosts must reject a context whose environment is
// empty when the operation needs an execution environment.

public struct CanvasRuntimeContext: Codable, Hashable, Sendable {
    public var canvasID: UUID
    public var pageID: UUID
    /// The exact document revision this context was issued for. Stale
    /// contexts are the host's cue to reload before applying results.
    public var revision: Int64
    /// Owning task for lifecycle/cancellation. Nil only for pure reads.
    public var owningTaskID: UUID?
    /// Explicit environment identity; empty string means "no environment"
    /// and is invalid for any operation that runs code.
    public var environmentID: String

    public init(
        canvasID: UUID,
        pageID: UUID,
        revision: Int64,
        owningTaskID: UUID? = nil,
        environmentID: String = ""
    ) {
        self.canvasID = canvasID
        self.pageID = pageID
        self.revision = revision
        self.owningTaskID = owningTaskID
        self.environmentID = environmentID
    }

    /// True when an explicit environment is bound. Operations that run code
    /// must check this and fail otherwise.
    public var hasEnvironment: Bool { !environmentID.isEmpty }
}

// MARK: - Document store (load / commit / undo)

/// Receipt for one committed batch. `requestID` makes the commit idempotent
/// across retries: replaying the same request ID with identical bytes
/// returns the original receipt without a second mutation; the same request
/// ID with different bytes is rejected.
public struct CanvasCommitReceipt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var requestID: UUID
    public var canvasID: UUID
    public var previousRevision: Int64
    public var revision: Int64
    /// Stable content hash of the committed batch; used for replay detection.
    public var batchHash: String
    /// One undo unit per batch: undoing this receipt restores the previous
    /// snapshot and itself bumps the revision.
    public var undoToken: UUID
    public var committedAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        canvasID: UUID,
        previousRevision: Int64,
        revision: Int64,
        batchHash: String,
        undoToken: UUID = UUID(),
        committedAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.canvasID = canvasID
        self.previousRevision = previousRevision
        self.revision = revision
        self.batchHash = batchHash
        self.undoToken = undoToken
        self.committedAt = committedAt
    }
}

public struct CanvasUndoEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var canvasID: UUID
    /// Snapshot revision this entry restores.
    public var restoresRevision: Int64
    /// The revision created when this undo is applied (undo always bumps).
    public var resultingRevision: Int64
    public var label: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        canvasID: UUID,
        restoresRevision: Int64,
        resultingRevision: Int64,
        label: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.canvasID = canvasID
        self.restoresRevision = restoresRevision
        self.resultingRevision = resultingRevision
        self.label = label
        self.createdAt = createdAt
    }
}

/// Document authority boundary. The production host conforms with its own
/// persistent store; the qualification repositories in this module conform
/// for tests and examples. The shape mirrors the app's existing
/// `CanvasDocumentRepository` (`project(canvasID:)` / `save(expectedRevision:)`)
/// so a thin host adapter can forward to either side.
public protocol CanvasDocumentStore: Sendable {
    func load(canvasID: UUID) async throws -> CanvasSnapshot
    /// Commits one batch. `expectedRevision` must equal the current revision;
    /// a mismatch throws `CanvasKitError.revisionConflict` and leaves the
    /// store untouched (recoverable: reload, rebase, retry).
    func commit(
        _ batch: CanvasEditBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt
    /// P0.1 additive: commits one document-level (structural) batch through
    /// the SAME CAS/idempotency/undo pipeline. Implementations must share
    /// the request-ID domain with `commit` — a request ID is unique per
    /// store, never per batch kind.
    func commitDocument(
        _ batch: CanvasDocumentBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt
    /// Strict undo: expected-revision guard plus request-ID idempotency.
    /// Repeating a consumed request ID returns the original receipt without
    /// undoing again; revisions only ever increase.
    func undo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt
    /// Strict redo: same receipts and guards as undo. Any new commit clears
    /// the redo branch.
    func redo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt
    /// History of applied undo/redo units (most recent first), for host UI.
    func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry]
    /// Authoritative available stacks; applied history is an audit log and
    /// cannot be used to infer whether another undo or redo is possible.
    func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability
}

public struct CanvasHistoryAvailability: Codable, Hashable, Sendable {
    public var undoCount: Int
    public var redoCount: Int
    public init(undoCount: Int, redoCount: Int) {
        self.undoCount = undoCount
        self.redoCount = redoCount
    }
}

public extension CanvasDocumentStore {
    func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability {
        throw CanvasKitError.missingEntity("host history availability")
    }
    /// Compatibility convenience for hosts that do not track revisions for
    /// history gestures: loads the current revision and mints a fresh
    /// request ID. Interactive hosts should prefer the strict overloads so
    /// a stale window cannot undo another session's commit.
    func undo(canvasID: UUID) async throws -> CanvasCommitReceipt {
        let snapshot = try await load(canvasID: canvasID)
        return try await undo(
            canvasID: canvasID,
            expectedRevision: snapshot.revision,
            requestID: UUID())
    }

    /// Compatibility convenience matching `undo(canvasID:)`.
    func redo(canvasID: UUID) async throws -> CanvasCommitReceipt {
        let snapshot = try await load(canvasID: canvasID)
        return try await redo(
            canvasID: canvasID,
            expectedRevision: snapshot.revision,
            requestID: UUID())
    }
}

// MARK: - Assets

/// Host asset byte store. The kit only ever passes `CanvasAssetLocator`
/// identities across boundaries; bytes move through this protocol.
public protocol CanvasAssetStore: Sendable {
    func bytes(for locator: CanvasAssetLocator) async throws -> Data
    func store(_ bytes: Data, preferredID: UUID?) async throws -> CanvasAssetLocator
}

// MARK: - Sources (read / refresh / open original)

/// Live source content descriptor returned by a refresh read.
public struct CanvasSourceContent: Hashable, Sendable {
    public var sourceID: UUID
    public var revision: Int64
    public var text: String
    public var fragment: String?
    /// Optional typed payload for structured sources (table, formula,
    /// rich text, …). Legacy text-only services leave this nil; refresh
    /// never converts structured node content to plain text.
    public var typedContent: CanvasContent?

    public init(
        sourceID: UUID,
        revision: Int64,
        text: String,
        fragment: String? = nil,
        typedContent: CanvasContent? = nil
    ) {
        self.sourceID = sourceID
        self.revision = revision
        self.text = text
        self.fragment = fragment
        self.typedContent = typedContent
    }
}

/// Explicit source service. Refresh is never automatic: the host calls
/// `refreshSource` (via `CanvasSourceRefresher`) when the user asks.
public protocol CanvasSourceService: Sendable {
    func currentRevision(sourceID: UUID) async throws -> Int64
    func read(sourceID: UUID, fragment: String?) async throws -> CanvasSourceContent
}

/// UI-only source opening, deliberately separate from the async IO service
/// and kept on the main actor: the host resolves what "the original" is
/// (note page, PDF page, web URL) and UI code never reconstructs a location
/// from stored document paths on its own.
public protocol CanvasSourceOpening: Sendable {
    @MainActor func openSource(sourceID: UUID, fragment: String?) async throws
}

// MARK: - Professional editors

/// Gateway to the host's professional editors (image/video/CAD/mind-map).
/// Open is a UI gesture; apply returns the new applied revision.
public protocol CanvasEditorGateway: Sendable {
    func openEditor(
        _ reference: CanvasEditorReference,
        context: CanvasRuntimeContext
    ) async throws
    /// Applies the child project's current draft back onto the canvas node.
    func applyEditorResult(
        _ reference: CanvasEditorReference,
        context: CanvasRuntimeContext
    ) async throws -> CanvasEditorReference
}

// MARK: - Assistant

/// A trusted, selection-aware assistant request. The gateway applies the
/// host's normal permission and conversation ownership checks; the kit does
/// not implement a parallel policy engine.
public struct CanvasAssistantRequest: Hashable, Sendable {
    public var context: CanvasRuntimeContext
    public var selectedNodeIDs: [UUID]
    public var instruction: String
    /// Explicit user choice for how results are kept (ICQA04). When nil the
    /// default policy keeps the original and opens a branch.
    public var disposition: CanvasResultDisposition?

    public init(
        context: CanvasRuntimeContext,
        selectedNodeIDs: [UUID],
        instruction: String,
        disposition: CanvasResultDisposition? = nil
    ) {
        self.context = context
        self.selectedNodeIDs = selectedNodeIDs
        self.instruction = instruction
        self.disposition = disposition
    }
}

/// How an AI-attempted new variant is kept.
public enum CanvasResultDisposition: String, Codable, Hashable, Sendable {
    /// Replace the referenced nodes in place (explicit instruction only).
    case replace
    /// Keep the original; add the new variant beside it on a new branch.
    case branch
}

public protocol CanvasAssistantGateway: Sendable {
    func perform(request: CanvasAssistantRequest) async throws -> CanvasEditBatch
}

// MARK: - Step execution (Flow runtime boundary)

/// Frozen request to execute one step (one attempt of one node) of one run.
/// The node definition travels with the request so the host never has to
/// re-derive execution semantics from canvas state that may have moved on.
public struct CanvasStepExecutionRequest: Hashable, Sendable {
    /// Immutable identity of the run this attempt belongs to.
    public var runIdentity: FlowRunIdentity
    /// Stable attempt identity. Re-submitting the same attempt (retry after
    /// a lost response) MUST reuse the host's existing work; the host must
    /// not start a second provider job for a known attempt.
    public var attemptID: UUID
    /// The frozen node definition: kind, declared ports, parameters and any
    /// script/API descriptors — exactly what the runtime resolved.
    public var node: FlowNode
    /// Resolved typed inputs for this attempt.
    public var inputs: [String: FlowValue]
    /// Resume point when continuing a paused/interrupted run.
    public var resumeCheckpoint: FlowRunCheckpoint?
    /// Trusted runtime context: actual document revision, task ownership,
    /// explicit environment.
    public var context: CanvasRuntimeContext

    public init(
        runIdentity: FlowRunIdentity,
        attemptID: UUID = UUID(),
        node: FlowNode,
        inputs: [String: FlowValue] = [:],
        resumeCheckpoint: FlowRunCheckpoint? = nil,
        context: CanvasRuntimeContext
    ) {
        self.runIdentity = runIdentity
        self.attemptID = attemptID
        self.node = node
        self.inputs = inputs
        self.resumeCheckpoint = resumeCheckpoint
        self.context = context
    }
}

public enum CanvasStepQueryStatus: String, Codable, Hashable, Sendable {
    case queued, running, succeeded, failed, cancelled
    /// Submission could not be confirmed (request lost, provider ambiguous).
    /// The result carries no outputs and callers must reconcile explicitly;
    /// neither host nor caller auto-resends an unconfirmed attempt.
    case unknown
}

/// Result of submitting or querying one step attempt.
public struct CanvasStepQueryResult: Hashable, Sendable {
    public var attemptID: UUID
    public var nodeID: UUID
    public var status: CanvasStepQueryStatus
    public var outputs: [String: FlowValue]
    /// Asset identities the step produced; bytes resolve through
    /// `CanvasAssetStore`.
    public var producedAssets: [CanvasAssetLocator]
    /// Recoverable binding to the host's own task/job record, so a restarted
    /// runtime can re-attach to work it previously submitted.
    public var hostTaskBinding: UUID?
    public var error: String?

    public init(
        attemptID: UUID,
        nodeID: UUID,
        status: CanvasStepQueryStatus,
        outputs: [String: FlowValue] = [:],
        producedAssets: [CanvasAssetLocator] = [],
        hostTaskBinding: UUID? = nil,
        error: String? = nil
    ) {
        self.attemptID = attemptID
        self.nodeID = nodeID
        self.status = status
        self.outputs = outputs
        self.producedAssets = producedAssets
        self.hostTaskBinding = hostTaskBinding
        self.error = error
    }
}

/// Boundary the future Flow runtime drives. The kit declares the contract;
/// the host implements scheduling against its existing jobs/service
/// lifecycle (no duplicate provider/permission/job subsystem here).
public protocol CanvasStepExecutor: Sendable {
    /// Submits one attempt. Implementations must dedupe by
    /// `(runIdentity.runID, attemptID)` and return `.unknown` (never a fresh
    /// job) when submission cannot be confirmed.
    func submitStep(
        _ request: CanvasStepExecutionRequest
    ) async throws -> CanvasStepQueryResult
    /// Per-step query: status plus outputs/asset references and the
    /// recoverable host task binding, so a resumed runtime can adopt work
    /// that finished while it was away.
    func queryStep(attemptID: UUID, runID: UUID) async throws -> CanvasStepQueryResult
    /// Run-level progress for scheduling decisions.
    func queryRun(runID: UUID) async throws -> FlowRunCheckpoint
    func cancelRun(runID: UUID) async throws
}

// MARK: - UI callbacks (MainActor, separate from async IO)

/// Native UI callbacks stay on the main actor and are deliberately separate
/// from the async IO protocols above. Hosts observe store changes here.
public protocol CanvasHostUIDelegate: Sendable {
    @MainActor func canvasDidChange(canvasID: UUID, revision: Int64) async
    @MainActor func canvasConflictDetected(canvasID: UUID, expected: Int64, current: Int64) async
    @MainActor func sourceRefreshDidProduceAlternatives(canvasID: UUID, nodeIDs: [UUID]) async
}
