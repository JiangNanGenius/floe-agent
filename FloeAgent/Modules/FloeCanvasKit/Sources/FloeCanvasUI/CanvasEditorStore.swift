#if canImport(UIKit)
import Foundation
import Combine
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasLayout
import FloeCanvasFlow
import FloeDiagramCore

/// Live Flow-run presentation driven by real runtime events (ICH07–09).
/// No cosmetic timers: every mutation here comes from `FlowRuntimeEvent`s or
/// explicit runtime queries.
public struct CanvasFlowRunSnapshot: Hashable, Sendable {
    public var runID: UUID
    public var graphID: UUID
    public var phase: FlowRunPhase
    public var completedSteps: Int
    public var totalUnits: Int
    public var pendingReconciliations: Int
    public var failureCount: Int
    /// Host-reported run-save (checkpoint) failure, if any. Presence is a
    /// REAL failure state — never presented as a successful save.
    public var checkpointFailure: String?
    /// Most-recent-first bounded event list for the debugger panel.
    public var events: [FlowRuntimeEvent]
    public var stepRecords: [FlowStepRecord]
    public var lateDeliveries: [FlowAttemptRecord]
    public var breakpoints: Set<UUID>

    public init(
        runID: UUID,
        graphID: UUID,
        phase: FlowRunPhase,
        completedSteps: Int,
        totalUnits: Int,
        pendingReconciliations: Int,
        failureCount: Int,
        checkpointFailure: String? = nil,
        events: [FlowRuntimeEvent],
        stepRecords: [FlowStepRecord],
        lateDeliveries: [FlowAttemptRecord],
        breakpoints: Set<UUID>
    ) {
        self.runID = runID
        self.graphID = graphID
        self.phase = phase
        self.completedSteps = completedSteps
        self.totalUnits = totalUnits
        self.pendingReconciliations = pendingReconciliations
        self.failureCount = failureCount
        self.checkpointFailure = checkpointFailure
        self.events = events
        self.stepRecords = stepRecords
        self.lateDeliveries = lateDeliveries
        self.breakpoints = breakpoints
    }

    public var isTerminal: Bool {
        switch phase {
        case .completed, .failed, .cancelled: return true
        case .running, .paused, .stepping, .waitingReconcile: return false
        }
    }
}

/// The single source of truth for the canvas editor UI.
///
/// Ownership rules (UI_BRIEF):
/// - The document repository owns committed undo. This store never keeps a
///   second committed undo stack; local transient editors (text, Pencil)
///   commit one completed gesture as exactly one repository batch.
/// - One user gesture = one document batch = one undo unit.
/// - On CAS/save failure the payload becomes a `CanvasTransientDraft` tied to
///   the exact page/node/revision; nothing is silently dropped or applied to
///   another page.
/// - The layout index rebuilds only at snapshot boundaries (after commits,
///   undo/redo, load), never per pan.
@MainActor
public final class CanvasEditorStore: ObservableObject {
    // MARK: Immutable configuration

    public let canvasID: UUID
    public let services: CanvasEditorServices
    public let configuration: CanvasEditorConfiguration
    public let strings: CanvasStrings
    /// Shared bounded preview pipeline (host `CanvasPreviewProviding` gate).
    /// Owned by the store so the board and the inspector resolve thumbnails
    /// through ONE cache/cancellation authority (P1c).
    public let previews: CanvasPreviewPipeline

    // MARK: Published document state

    @Published public private(set) var snapshot: CanvasSnapshot
    @Published public private(set) var isLoaded = false
    @Published public private(set) var activeMutationCount = 0
    public var isMutating: Bool { activeMutationCount > 0 }
    @Published public private(set) var revision: Int64 = 0

    /// The page currently shown on the board. Always a member of `snapshot.pages`.
    @Published public private(set) var selectedPageID: UUID

    /// Current node selection (real canvas node IDs).
    @Published public var selection: Set<UUID> = []

    @Published public var tool: CanvasEditingTool = .select
    @Published public var inspectorTab: CanvasInspectorTab = .node
    @Published public var showsSidebar: Bool
    @Published public var showsInspector = false
    @Published public var showsDebugger = false

    // MARK: Prepared layout (rebuilt at snapshot boundaries only)

    @Published public private(set) var layoutIndex: CanvasPageLayoutIndex
    @Published public private(set) var relationEdges: [CanvasRelationEdgeGeometry] = []
    @Published public private(set) var flowEdges: [CanvasFlowEdgeGeometry] = []
    @Published public private(set) var layoutIssues: [CanvasLayoutIssue] = []
    /// The flow graph currently displayed/edited on the board (a page may
    /// hold several; the UI edits one at a time).
    @Published public private(set) var activeFlowGraphID: UUID?

    // MARK: Viewport

    /// Live world↔view transform. Transient: panning never commits.
    @Published public var viewport: CanvasViewportTransform

    // MARK: Search

    @Published public var searchQuery = ""
    @Published public private(set) var searchResults: [CanvasSearchResult] = []

    // MARK: Undo availability (queried from the repository, never local)

    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    // MARK: Drafts and alerts

    @Published public private(set) var drafts: [CanvasTransientDraft] = []
    @Published public private(set) var alert: CanvasUserAlert?

    // MARK: Flow runtime

    @Published public private(set) var flowRun: CanvasFlowRunSnapshot?

    // MARK: Private state

    private var viewportByPage: [UUID: CanvasViewportTransform] = [:]
    private var rebuildGeneration: UInt64 = 0
    private var rebuildTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var eventBindingGeneration: UInt64 = 0
    private var presentationIndex = CanvasPresentationIndex()
    private var pageNodeLookup: [UUID: CanvasNodeSnapshot] = [:]
    private var pendingFitPageID: UUID?
    private var flowRuntime: FlowRuntimeService?
    private var flowBreakpoints: Set<UUID> = []
    private var eventHistory: [FlowRuntimeEvent] = []
    private var flowRunPageID: UUID?
    private static let maxRetainedEvents = 400

    deinit {
        rebuildTask?.cancel()
        eventTask?.cancel()
        eventRefreshTask?.cancel()
    }

    // MARK: Derived values

    public var page: CanvasPageSnapshot {
        snapshot.pages.first(where: { $0.id == selectedPageID })
            ?? snapshot.pages.first
            ?? CanvasPageSnapshot(id: selectedPageID, name: "Page")
    }

    public var activeFlowGraph: FlowGraph? {
        guard let activeFlowGraphID else { return page.flowGraphs.first }
        return page.flowGraphs.first(where: { $0.id == activeFlowGraphID })
    }

    /// Selects which of the current page's flow graphs is edited, routed,
    /// run and debugged on the board. The ID is validated against the page;
    /// other graphs' cards remain ordinary visible content and their data
    /// and state are never merged or lost.
    public func selectFlowGraph(_ graphID: UUID) {
        guard page.flowGraphs.contains(where: { $0.id == graphID }),
              graphID != activeFlowGraphID else { return }
        activeFlowGraphID = graphID
        scheduleRebuild()
    }

    /// Single selection node, when exactly one node is selected.
    public var singleSelectedNode: CanvasNodeSnapshot? {
        guard selection.count == 1,
              let id = selection.first else { return nil }
        return pageNodeLookup[id]
    }

    // MARK: Init

    public init(
        canvasID: UUID,
        services: CanvasEditorServices,
        configuration: CanvasEditorConfiguration = CanvasEditorConfiguration()
    ) {
        self.canvasID = canvasID
        self.services = services
        self.configuration = configuration
        self.strings = CanvasStrings(
            language: CanvasStrings.resolve(preferred: configuration.preferredLanguage))
        self.previews = CanvasPreviewPipeline(provider: services.previewProvider)
        let placeholderPage = CanvasPageSnapshot()
        let placeholder = CanvasSnapshot(
            name: strings[.canvasTitleUntitled],
            pages: [placeholderPage])
        self.snapshot = placeholder
        self.selectedPageID = placeholderPage.id
        self.showsSidebar = true
        // Viewport starts at a sane default until the view reports its size.
        self.viewport = try! CanvasViewportTransform(
            center: .zero, scale: 1,
            viewSize: .init(width: 1024, height: 768))
        self.layoutIndex = try! CanvasPageLayoutIndex(page: placeholderPage)
    }

    // MARK: Load

    /// Loads the canvas and performs the first index rebuild. Call once from
    /// `.task` on the root view.
    public func load() async {
        do {
            let loaded = try await services.documentStore.load(canvasID: canvasID)
            applySnapshot(loaded)
            isLoaded = true
            await refreshUndoAvailability()
            scheduleRebuild()
            await rebuildTask?.value
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .saveFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
        }
    }

    /// Host-side commits refresh the visible original without replacing the
    /// editor, its selection, viewport or recoverable local drafts.
    public func refreshFromHost() async {
        guard activeMutationCount == 0 else { return }
        await reloadAfterMutation()
    }

    private func applySnapshot(_ next: CanvasSnapshot) {
        snapshot = next
        revision = next.revision
        let target = next.pages.first(where: { $0.id == selectedPageID })?.id
            ?? next.pages.first(where: { $0.id == next.selectedPageID })?.id
            ?? next.pages.first?.id
        if let target { snapshot.selectedPageID = target }
        if let target, target != selectedPageID {
            selectedPageID = target
            selection = []
            if let saved = viewportByPage[target] {
                viewport = saved
                pendingFitPageID = nil
            } else if let saved = next.viewports[target],
                      let transform = try? CanvasViewportTransform(
                        center: .init(x: saved.center.x, y: saved.center.y),
                        scale: saved.scale, viewSize: viewport.viewSize) {
                viewport = transform
                pendingFitPageID = nil
            } else {
                pendingFitPageID = target
            }
        }
        pageNodeLookup.removeAll(keepingCapacity: true)
        for node in page.nodes where pageNodeLookup[node.id] == nil {
            pageNodeLookup[node.id] = node
        }
        if let graph = activeFlowGraph {
            activeFlowGraphID = graph.id
        } else {
            activeFlowGraphID = page.flowGraphs.first?.id
        }
        updateSearchResults()
    }

    public func node(id: UUID) -> CanvasNodeSnapshot? { pageNodeLookup[id] }

    public func visibleRelationEdges(in rect: DiagramRect) -> [CanvasRelationEdgeGeometry] {
        guard layoutIndex.pageID == selectedPageID else { return [] }
        return presentationIndex.relationEdges(in: rect)
    }

    public func visibleFlowEdges(in rect: DiagramRect) -> [CanvasFlowEdgeGeometry] {
        guard layoutIndex.pageID == selectedPageID else { return [] }
        return presentationIndex.flowEdges(in: rect)
    }

    public func visibleFlowPortAnchors(in rect: DiagramRect) -> [CanvasFlowPortAnchor] {
        guard layoutIndex.pageID == selectedPageID else { return [] }
        return presentationIndex.portAnchors(in: rect)
    }

    // MARK: Commit pipeline

    /// One commit attempt with stable identity. The request ID and the
    /// original expected revision survive into drafts so retries replay the
    /// exact same request (idempotent receipt lookup precedes CAS).
    public struct CanvasCommitAttempt: Sendable {
        public var batch: CanvasDocumentBatch
        public var requestID: UUID
        public var expectedRevision: Int64
        public var undoLabel: String
        public var pageBatch: CanvasEditBatch? = nil
    }

    /// Truthful outcome of ONE commit attempt through the single
    /// authoritative pipeline. Callers that must not claim success on an
    /// unconfirmed acknowledgement (e.g. run-output placement) branch on
    /// this; the public `commit` entry points stay additive-compatible.
    public enum CanvasCommitOutcome: Hashable, Sendable {
        /// The repository confirmed the batch: exactly one committed
        /// revision and one undo unit.
        case committed
        /// The batch did NOT confirm. It survives as a recoverable
        /// `CanvasTransientDraft` carrying the original request identity —
        /// the failure alert is already presented.
        case pending(CanvasTransientDraft)
    }

    /// Commits one document-level batch. Exactly one repository commit — one
    /// undo unit. Recoverable failures become transient drafts carrying the
    /// original request identity.
    public func commit(
        _ batch: CanvasDocumentBatch,
        undoLabel: String,
        expectedRevision: Int64? = nil
    ) async {
        guard !batch.operations.isEmpty else { return }
        let attempt = CanvasCommitAttempt(
            batch: batch,
            requestID: UUID(),
            expectedRevision: expectedRevision ?? revision,
            undoLabel: undoLabel)
        await perform(attempt, draftID: nil)
    }

    @discardableResult
    private func perform(
        _ attempt: CanvasCommitAttempt,
        draftID: UUID?
    ) async -> CanvasCommitOutcome {
        activeMutationCount += 1
        defer { activeMutationCount -= 1 }
        do {
            if let pageBatch = attempt.pageBatch {
                _ = try await services.documentStore.commit(pageBatch,
                    canvasID: canvasID, expectedRevision: attempt.expectedRevision,
                    requestID: attempt.requestID)
            } else {
                _ = try await services.documentStore.commitDocument(
                attempt.batch,
                canvasID: canvasID,
                expectedRevision: attempt.expectedRevision,
                requestID: attempt.requestID)
            }
            if let draftID {
                drafts.removeAll { $0.id == draftID }
            }
            await reloadAfterMutation()
            return .committed
        } catch let error as CanvasKitError {
            return await handleCommitError(error, attempt: attempt, draftID: draftID)
        } catch {
            return await handleCommitError(
                .io(String(describing: error)), attempt: attempt, draftID: draftID)
        }
    }

    /// Commits one classic page batch nested in a document batch (same CAS /
    /// idempotency / undo pipeline).
    public func commit(
        _ batch: CanvasEditBatch,
        undoLabel: String
    ) async {
        let documentBatch = CanvasDocumentBatch(
            scope: .wholeDocument,
            operations: [.editPage(batch)])
        await perform(.init(batch: documentBatch, requestID: UUID(),
            expectedRevision: revision, undoLabel: undoLabel, pageBatch: batch), draftID: nil)
    }

    private func reloadAfterMutation() async {
        do {
            let current = try await services.documentStore.load(canvasID: canvasID)
            applySnapshot(current)
            scheduleRebuild()
            await refreshUndoAvailability()
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .saveFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
        }
    }

    @discardableResult
    private func handleCommitError(
        _ error: CanvasKitError,
        attempt: CanvasCommitAttempt,
        draftID: UUID?
    ) async -> CanvasCommitOutcome {
        switch error {
        case .revisionConflict(let expected, let current):
            // Real CAS conflict: reload so the user sees current state, and
            // KEEP the draft recoverable (both sides survive). The user
            // chooses: rebase onto the current revision (explicit new
            // intent -> new request ID) or discard. Never silently rebase.
            presentAlert(CanvasUserAlert(
                kind: .revisionConflict,
                title: strings[.alertConflictTitle],
                message: "Expected \(expected), current \(current).",
                primaryActionTitle: strings[.alertReload]))
            if let reloaded = try? await services.documentStore.load(canvasID: canvasID) {
                applySnapshot(reloaded)
                scheduleRebuild()
            }
            let draft = keepOrUpdateDraft(
                attempt: attempt, draftID: draftID, didConflict: true)
            return .pending(draft)
        case .editScopeViolations(let violations):
            // Authoring error: show and keep recoverable.
            let detail = violations.prefix(3).map { $0.reason.rawValue }.joined(separator: ", ")
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: detail))
            return .pending(keepOrUpdateDraft(attempt: attempt, draftID: draftID))
        default:
            // Transient failure (e.g. lost acknowledgement after the
            // service already committed). The draft keeps the ORIGINAL
            // request ID and expected revision so retry replays the
            // identical request; the repository receipt lookup makes the
            // retry return the original receipt without a second mutation.
            presentAlert(CanvasUserAlert(
                kind: .saveFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
            return .pending(keepOrUpdateDraft(attempt: attempt, draftID: draftID))
        }
    }

    @discardableResult
    private func keepOrUpdateDraft(
        attempt: CanvasCommitAttempt,
        draftID: UUID?,
        didConflict: Bool = false
    ) -> CanvasTransientDraft {
        if let draftID,
           let index = drafts.firstIndex(where: { $0.id == draftID }) {
            // Refresh payload/summary but PRESERVE the original request
            // identity: a retried failed attempt is the same request.
            drafts[index].documentBatch = attempt.batch
            drafts[index].pageBatch = attempt.pageBatch
            drafts[index].summary = attempt.undoLabel
            drafts[index].didConflict = didConflict
            return drafts[index]
        }
        let draft = CanvasTransientDraft(
            kind: .documentBatch,
            pageID: selectedPageID,
            nodeID: selection.first,
            baseRevision: attempt.expectedRevision,
            requestID: attempt.requestID,
            summary: attempt.undoLabel,
            documentBatch: attempt.batch,
            pageBatch: attempt.pageBatch,
            didConflict: didConflict)
        drafts.append(draft)
        return draft
    }

    // MARK: Editing commands

    /// Applies one editing intent as exactly one committed document batch.
    public func apply(_ command: CanvasEditCommand) async {
        do {
            let batch = try CanvasCommandBatchBuilder.makeBatch(
                command,
                in: snapshot,
                pageID: selectedPageID,
                selection: selection,
                configuration: configuration)
            guard !batch.operations.isEmpty else { return }
            await commit(batch, undoLabel: command.undoLabel)
            if case .deleteSelection = command {
                clearSelection()
            }
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: String(describing: error)))
        }
    }

    // MARK: Draft recovery

    /// Replays the failed commit with its ORIGINAL request ID, payload, and
    /// expected revision (idempotent replay). Only a real CAS conflict
    /// needs the explicit rebase choice; transient failures resolve here
    /// with exactly one committed revision and one undo unit.
    @discardableResult
    public func retryDraft(_ draft: CanvasTransientDraft) async -> CanvasCommitOutcome {
        guard let batch = draft.documentBatch else {
            discardDraft(draft)
            return .committed
        }
        let attempt = CanvasCommitAttempt(
            batch: batch,
            requestID: draft.requestID,
            expectedRevision: draft.baseRevision,
            undoLabel: draft.summary, pageBatch: draft.pageBatch)
        return await perform(attempt, draftID: draft.id)
    }

    /// Explicit new intent after a real conflict: commits the draft payload
    /// as a NEW request against the CURRENT revision. This is the only path
    /// that mints a fresh request ID for existing draft content.
    @discardableResult
    public func rebaseDraft(_ draft: CanvasTransientDraft) async -> CanvasCommitOutcome {
        guard let batch = draft.documentBatch else {
            discardDraft(draft)
            return .committed
        }
        let attempt = CanvasCommitAttempt(
            batch: batch,
            requestID: UUID(),
            expectedRevision: revision,
            undoLabel: draft.summary, pageBatch: draft.pageBatch)
        return await perform(attempt, draftID: draft.id)
    }

    public func discardDraft(_ draft: CanvasTransientDraft) {
        drafts.removeAll { $0.id == draft.id }
    }

    public func dismissAlert() {
        alert = nil
    }

    /// Presents an arbitrary error as an actionable alert (arrange rejects,
    /// host lab failures, …).
    public func presentAlertFromError(_ error: Error) {
        presentAlert(CanvasUserAlert(
            kind: .invalidFlow,
            title: strings[.alertInvalidFlowTitle],
            message: String(describing: error)))
    }
    public func presentLabResult(title: String, message: String) {
        presentAlert(.init(kind: .labActionCompleted, title: title, message: message))
    }

    private func presentAlert(_ userAlert: CanvasUserAlert) {
        alert = userAlert
    }

    // MARK: Undo / redo (repository-owned)

    public func undo() async {
        activeMutationCount += 1
        defer { activeMutationCount -= 1 }
        do {
            _ = try await services.documentStore.undo(
                canvasID: canvasID,
                expectedRevision: revision,
                requestID: UUID())
            await reloadAfterMutation()
        } catch let error as CanvasKitError {
            if case .revisionConflict(let expected, let current) = error {
                presentAlert(CanvasUserAlert(
                    kind: .revisionConflict,
                    title: strings[.alertConflictTitle],
                    message: "Expected \(expected), current \(current).",
                    primaryActionTitle: strings[.alertReload]))
            } else {
                presentAlert(CanvasUserAlert(
                    kind: .saveFailed,
                    title: strings[.alertSaveFailedTitle],
                    message: String(describing: error)))
            }
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .saveFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
        }
    }

    public func redo() async {
        activeMutationCount += 1
        defer { activeMutationCount -= 1 }
        do {
            _ = try await services.documentStore.redo(
                canvasID: canvasID,
                expectedRevision: revision,
                requestID: UUID())
            await reloadAfterMutation()
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .saveFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
        }
    }

    private func refreshUndoAvailability() async {
        guard let history = try? await services.documentStore.historyAvailability(canvasID: canvasID) else {
            canUndo = false
            canRedo = false
            return
        }
        canUndo = history.undoCount > 0
        canRedo = history.redoCount > 0
    }

    // MARK: Selection

    public func select(_ nodeID: UUID, extending: Bool = false) {
        if extending {
            selection.insert(nodeID)
        } else {
            selection = [nodeID]
        }
        if let node = page.nodes.first(where: { $0.id == nodeID }) {
            inspectorTab = CanvasInspectorTab.defaultTab(for: node)
            // Selecting a card bound to a flow step activates THAT graph
            // (validated against this page) so run/debug/edit act on it.
            if let binding = CanvasFlowCardBinding(metadata: node.metadata),
               page.flowGraphs.contains(where: { $0.id == binding.graphID }),
               binding.graphID != activeFlowGraphID {
                activeFlowGraphID = binding.graphID
                scheduleRebuild()
            }
        }
        showsInspector = !selection.isEmpty
    }

    public func select(_ nodeIDs: Set<UUID>) {
        selection = nodeIDs
        showsInspector = !selection.isEmpty
    }

    public func toggleSelection(_ nodeID: UUID) {
        if selection.contains(nodeID) {
            selection.remove(nodeID)
        } else {
            selection.insert(nodeID)
        }
        showsInspector = !selection.isEmpty
    }

    public func selectAll() {
        selection = Set(page.nodes.map(\.id))
    }

    public func clearSelection() {
        selection = []
        showsInspector = false
    }

    // MARK: Viewport

    /// Adopts a new transform (pan/zoom). Purely transient — never commits.
    public func setViewport(_ transform: CanvasViewportTransform) {
        viewport = transform
        viewportByPage[selectedPageID] = transform
    }

    /// Fits the current page content (visible nodes ∪ regions) in view.
    public func fitToContent() {
        // The layout index represents an empty board with a small valid
        // rectangle. Fitting that sentinel would zoom a new page to 800%.
        if page.nodes.isEmpty, page.regions.isEmpty, page.strokes.isEmpty,
           page.pencilDrawingData?.isEmpty != false {
            pendingFitPageID = nil
            if let empty = try? CanvasViewportTransform(center: .zero, scale: 1, viewSize: viewport.viewSize) {
                setViewport(empty)
            }
            return
        }
        guard layoutIndex.pageID == selectedPageID else {
            pendingFitPageID = selectedPageID
            return
        }
        pendingFitPageID = nil
        guard let fitted = viewport.fitting(layoutIndex.bounds, padding: 48) else { return }
        setViewport(fitted)
    }

    public func zoomIn() {
        if let zoomed = viewport.zoomed(byFactor: 1.25) {
            setViewport(zoomed)
        }
    }

    public func zoomOut() {
        if let zoomed = viewport.zoomed(byFactor: 0.8) {
            setViewport(zoomed)
        }
    }

    /// Jumps to a named scene without duplicating any content (ICH03).
    public func jumpToScene(_ sceneID: UUID) {
        guard let scene = page.scenes.first(where: { $0.id == sceneID }) else { return }
        let center = DiagramPoint(
            x: scene.viewportCenter.x, y: scene.viewportCenter.y)
        if let next = try? CanvasViewportTransform(
            center: center,
            scale: min(max(scene.viewportScale, CanvasViewportTransform.scaleRange.lowerBound),
                       CanvasViewportTransform.scaleRange.upperBound),
            viewSize: viewport.viewSize) {
            setViewport(next)
        }
        var focus = Set(scene.focusedNodeIDs)
        if focus.isEmpty, let firstRegion = scene.focusedRegionIDs.first {
            focus = Set(layoutIndex.nodeIDs(containedInRegion: firstRegion))
        }
        if !focus.isEmpty {
            selection = focus
            showsInspector = true
        }
    }

    // MARK: Search

    public func updateSearchQuery(_ query: String) {
        searchQuery = query
        updateSearchResults()
    }

    private func updateSearchResults() {
        searchResults = CanvasSearch.search(searchQuery, in: page)
    }

    /// Focuses the board on one search result.
    public func focusSearchResult(_ result: CanvasSearchResult) {
        select(result.node.id)
        let frame = CanvasLayoutGeometry.rect(from: result.node.frame)
        let center = DiagramPoint(x: frame.center.x, y: frame.center.y)
        if let next = try? CanvasViewportTransform(
            center: center, scale: max(viewport.scale, 0.75),
            viewSize: viewport.viewSize) {
            setViewport(next)
        }
    }

    // MARK: Page switching

    /// Switches the selected page. Selection is per-page and does not leak.
    public func selectPage(_ pageID: UUID) async {
        guard pageID != selectedPageID,
              snapshot.pages.contains(where: { $0.id == pageID }) else { return }
        // Navigation is view state, not a document edit or undo unit.
        var next = snapshot
        next.selectedPageID = pageID
        selectedPageID = pageID
        applySnapshot(next)
        scheduleRebuild()
        clearSelection()
        if let saved = viewportByPage[pageID] {
            viewport = saved
        } else {
            fitToContent()
        }
    }

    /// Creates a new page from template content in ONE document batch (one
    /// undo unit): the page, its nodes/connections and an optional flow
    /// graph land together.
    public func createScenePage(from content: CanvasTemplateContent) async {
        let page = CanvasPageSnapshot(name: content.pageName)
        var operations: [CanvasDocumentOperation] = [
            .createPage(page, select: true)
        ]
        let batch = CanvasDocumentBatch(scope: .wholeDocument, operations: operations)
        guard !content.nodes.isEmpty || content.flowGraph != nil else {
            await commit(batch, undoLabel: "New scene")
            await selectPage(page.id)
            clearSelection()
            fitToContent()
            return
        }
        // Page creation and content must be one commit; the created page ID
        // is minted here and referenced by the nested content operations.
        operations = [.createPage(page, select: true)]
        var pageEdits: [CanvasEditOperation] = content.nodes.map { .insertNode($0) }
        pageEdits.append(contentsOf: content.connections.map { .insertConnection($0) })
        if !pageEdits.isEmpty {
            operations.append(.editPage(.init(
                pageID: page.id,
                scope: .wholeDocument,
                operations: pageEdits)))
        }
        if let graph = content.flowGraph {
            operations.append(.insertFlowGraph(pageID: page.id, graph: graph))
        }
        await commit(CanvasDocumentBatch(scope: .wholeDocument, operations: operations),
                     undoLabel: "New scene")
        await selectPage(page.id)
        clearSelection()
        fitToContent()
    }

    // MARK: Layout rebuild (snapshot boundary only)

    /// Rebuilds the prepared index and re-routes edges. Rebuilds are
    /// generation-serialized: only the newest snapshot wins. Never called
    /// from pan/zoom paths.
    public func scheduleRebuild() {
        let pageSnapshot = page
        // A page may hold several flow graphs (branches). The ACTIVE graph
        // drives routing/run/debug; a rebuild never silently resets it to
        // the first graph while the previous choice still exists here.
        let graph = pageSnapshot.flowGraphs.first(where: { $0.id == activeFlowGraphID })
            ?? pageSnapshot.flowGraphs.first
        activeFlowGraphID = graph?.id
        let generation = rebuildGeneration &+ 1
        rebuildGeneration = generation
        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let index = try? CanvasPageLayoutIndex(
                page: pageSnapshot, flowGraph: graph) else { return }
            let relation = (try? CanvasEdgeRouter.routeRelationEdges(index: index)) ?? []
            var flow: [CanvasFlowEdgeGeometry] = []
            var issues: [CanvasLayoutIssue] = index.issues
            if let graph {
                let routed = try? CanvasFlowEdgeLayout.routeEdges(
                    flowGraph: graph,
                    nodeFrames: index.flowDisplayFrames,
                    representatives: index.flowDisplayRepresentatives,
                    endpointFrames: index.regionFrames)
                flow = routed?.edges ?? []
                issues.append(contentsOf: routed?.issues ?? [])
            }
            guard !Task.isCancelled else { return }
            let presentation = CanvasPresentationIndex(layout: index, relations: relation, flows: flow)
            await MainActor.run { [weak self] in
                guard let self, self.rebuildGeneration == generation,
                      self.selectedPageID == pageSnapshot.id else { return }
                self.presentationIndex = presentation
                self.layoutIndex = index
                self.relationEdges = relation
                self.flowEdges = flow
                self.layoutIssues = issues
                if self.pendingFitPageID == pageSnapshot.id { self.fitToContent() }
            }
        }
    }

    // MARK: Pencil persistence (ICH05)

    /// Saves the page's lossless PencilKit bytes as ONE whole-document
    /// gesture. Original strokes stay recoverable; the discrete `strokes`
    /// array is only a derived view and is not edited here.
    public func savePencilDrawing(_ data: Data?) async {
        guard data?.count ?? 0 <= configuration.maxPencilDrawingByteCount else { return }
        let batch = CanvasEditBatch(
            pageID: selectedPageID,
            scope: .wholeDocument,
            operations: [.setPencilDrawingData(data)])
        await commit(batch, undoLabel: "Ink")
    }

    // MARK: Ink recognition sessions (ICH05)

    /// Recognition candidates pending the user's explicit Keep-ink choice.
    @Published public private(set) var inkRecognitionSession: CanvasInkRecognitionSession?

    /// Called by the ink overlay when a drawing gesture ends. Saves the
    /// world-space bytes as one undo unit, then surfaces recognized
    /// line/arrow/box geometry for the explicit convert/keep decision.
    public func finishInkGesture(
        worldData: Data,
        clearedData: Data,
        newStrokePointsWorld: [[CanvasGeometry.Point]],
        wasInking: Bool,
        pageID: UUID? = nil,
        expectedRevision: Int64? = nil
    ) async {
        guard worldData.count <= configuration.maxPencilDrawingByteCount else { return }
        let targetPageID = pageID ?? selectedPageID
        let targetRevision = expectedRevision ?? revision
        await commit(CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .editPage(.init(pageID: targetPageID, scope: .wholeDocument,
                operations: [.setPencilDrawingData(worldData)]))
        ]), undoLabel: "Ink", expectedRevision: targetRevision)
        guard selectedPageID == targetPageID, alert == nil,
              page.pencilDrawingData == worldData else { return }
        guard wasInking, !newStrokePointsWorld.isEmpty else { return }
        guard let result = CanvasInkRecognition.recognize(
            strokes: newStrokePointsWorld) else { return }
        inkRecognitionSession = CanvasInkRecognitionSession(
            results: [result],
            clearedPencilData: clearedData, pageID: targetPageID, expectedRevision: revision)
    }

    /// Applies the conversion decision via the shared batch builder
    /// (keepInk=true keeps original strokes; keepInk=false replaces the
    /// drawing in the SAME batch as the insert — one undo unit).
    public func applyInkConversion(keepInk: Bool) async {
        guard let session = inkRecognitionSession else { return }
        inkRecognitionSession = nil
        let batch = CanvasInkObjectConversionBatchBuilder.batch(
            pageID: session.pageID ?? selectedPageID,
            results: session.results,
            keepInk: keepInk,
            clearedPencilData: session.clearedPencilData)
        await commit(batch, undoLabel: "Convert ink", expectedRevision: session.expectedRevision)
    }

    public func discardInkConversion() {
        inkRecognitionSession = nil
    }

    // MARK: Flow runs (ICH07–09)

    /// Starts a run of the active flow graph.
    ///
    /// The run configuration is host-authoritative: `makeRunConfiguration`
    /// supplies the real identity (owning task, environment per host
    /// policy), configuration digest, run inputs and source digests. The UI
    /// validates the identity against the live document (canvas, revision,
    /// graph identity/revision) and enforces that graphs containing
    /// customScript/customAPI nodes carry a non-empty environment — pure
    /// local/deterministic graphs may run in an explicitly offline
    /// qualification context without one. Nothing ever falls back to a host
    /// interpreter.
    @discardableResult
    public func startFlowRun() async -> Bool {
        guard let graph = activeFlowGraph else { return false }
        do {
            let runConfiguration = try await makeValidatedRunConfiguration(graph: graph)
            guard ensureEnvironmentIfRequired(by: graph, configuration: runConfiguration) else {
                return false
            }
            let runtime = try await validatedRuntime()
            let compiled = try await runtime.compile(graph, maxLoopIterations: runConfiguration.maxLoopIterations)
            let runID = try await runtime.startRun(
                compiled: compiled, configuration: runConfiguration)
            await bindFlowEvents(runtime: runtime, runID: runID, graphID: graph.id)
            return true
        } catch {
            presentFlowError(error)
            return false
        }
    }

    /// ICH08: attaches to an existing run owned by the trusted runtime
    /// (e.g. after the qualification host restarted and restored the run
    /// from its journal via `resumeRun`). The host supplies the run ID from
    /// its own journal listing (which already binds run → canvas/graph) and
    /// the expected graph ID; the UI verifies the graph belongs to the
    /// current page and the run exists in the trusted runtime before
    /// listening to its real event stream.
    public func attachFlowRun(
        runID: UUID,
        expectedGraphID: UUID
    ) async -> Bool {
        do {
            let runtime = try await validatedRuntime()
            guard page.flowGraphs.contains(where: { $0.id == expectedGraphID }) else {
                throw CanvasEditorUIError.runIdentityMismatch
            }
            guard await runtime.status(runID: runID) != nil else {
                throw CanvasEditorUIError.runNotFound(runID)
            }
            await bindFlowEvents(runtime: runtime, runID: runID, graphID: expectedGraphID)
            return true
        } catch {
            presentFlowError(error)
            return false
        }
    }

    /// ICH08: partial rerun after the graph moved on. The plan comes from
    /// the real previous result (`FlowRerunPlanner`); the new run adopts
    /// valid results through the seed, the old run record stays intact, and
    /// only invalidated nodes (plus their downstream closure) re-run. This
    /// is never a disguised full-graph rerun.
    @discardableResult
    public func rerunFlowFromPreviousRun(
        previousRunID: UUID,
        previousGraph: FlowGraph,
        previousResult: FlowRunResult
    ) async -> Bool {
        guard let graph = activeFlowGraph else { return false }
        do {
            let runConfiguration = try await makeValidatedRunConfiguration(graph: graph)
            guard ensureEnvironmentIfRequired(by: graph, configuration: runConfiguration) else {
                return false
            }
            let runtime = try await validatedRuntime()
            let compiled = try await runtime.compile(graph, maxLoopIterations: runConfiguration.maxLoopIterations)
            let plan = try FlowRerunPlanner.plan(
                previous: previousResult,
                previousGraph: previousGraph,
                editedGraph: graph,
                editedCompiled: compiled,
                configuration: runConfiguration)
            let runID = try await runtime.startRun(
                compiled: compiled,
                configuration: runConfiguration,
                seed: plan.seed)
            await bindFlowEvents(runtime: runtime, runID: runID, graphID: graph.id)
            return true
        } catch {
            presentFlowError(error)
            return false
        }
    }

    // MARK: Flow run plumbing

    private func makeValidatedRunConfiguration(
        graph: FlowGraph
    ) async throws -> FlowRunConfiguration {
        guard let makeRunConfiguration = services.makeRunConfiguration else {
            throw CanvasEditorUIError.runConfigurationProviderMissing
        }
        let configuration = try await makeRunConfiguration(
            snapshot, selectedPageID, graph)
        let identity = configuration.identity
        guard identity.canvasID == canvasID,
              identity.canvasRevision == revision,
              identity.flowGraphID == graph.id,
              identity.flowGraphRevision == graph.revision else {
            throw CanvasEditorUIError.runIdentityMismatch
        }
        return configuration
    }

    private func ensureEnvironmentIfRequired(
        by graph: FlowGraph,
        configuration: FlowRunConfiguration
    ) -> Bool {
        let needsEnvironment = graph.nodes.contains {
            $0.kind == .customScript || $0.kind == .customAPI
        }
        guard needsEnvironment, configuration.identity.environmentID.isEmpty else {
            return true
        }
        presentAlert(CanvasUserAlert(
            kind: .environmentRequired,
            title: strings[.alertEnvironmentRequired],
            message: strings[.alertEnvironmentRequiredMessage]))
        return false
    }

    private func validatedRuntime() async throws -> FlowRuntimeService {
        guard let runtime = flowRuntime ?? services.makeFlowRuntime?() else {
            throw CanvasEditorUIError.flowRuntimeMissing
        }
        flowRuntime = runtime
        return runtime
    }

    private func presentFlowError(_ error: Error) {
        presentAlert(CanvasUserAlert(
            kind: .invalidFlow,
            title: strings[.alertInvalidFlowTitle],
            message: String(describing: error)))
    }

    private func bindFlowEvents(
        runtime: FlowRuntimeService,
        runID: UUID,
        graphID: UUID
    ) async {
        eventBindingGeneration &+= 1
        let binding = eventBindingGeneration
        eventTask?.cancel()
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        eventHistory = []
        // Fence the page this run started on: outputs may only be placed
        // back here, never onto a newly selected page.
        flowRunPageID = selectedPageID
        let initial = await snapshotOfRun(runtime: runtime, runID: runID, graphID: graphID)
        guard eventBindingGeneration == binding else { return }
        flowRun = initial
        showsDebugger = true
        eventTask = Task { @MainActor [weak self] in
            let stream = await runtime.events(runID: runID)
            for await event in stream {
                guard !Task.isCancelled, self?.eventBindingGeneration == binding else { return }
                self?.appendFlowEvent(event, runtime: runtime, runID: runID,
                                      graphID: graphID, binding: binding)
            }
        }
    }

    private func appendFlowEvent(
        _ event: FlowRuntimeEvent, runtime: FlowRuntimeService,
        runID: UUID, graphID: UUID, binding: UInt64
    ) {
        eventHistory.insert(event, at: 0)
        if eventHistory.count > Self.maxRetainedEvents {
            eventHistory.removeLast(eventHistory.count - Self.maxRetainedEvents)
        }
        guard eventRefreshTask == nil else { return }
        // Coalesce an event burst before reading/sorting the full run state.
        // The runtime still schedules/debugs immediately; only presentation
        // is sampled, with the newest terminal state retained by the stream.
        eventRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, self?.eventBindingGeneration == binding else { return }
            let status = await runtime.status(runID: runID)
            guard !Task.isCancelled, self?.eventBindingGeneration == binding else { return }
            let records = await runtime.stepRecords(runID: runID)
            guard !Task.isCancelled, self?.eventBindingGeneration == binding else { return }
            let late = await runtime.lateDeliveries(runID: runID)
            guard !Task.isCancelled, let self,
                  self.eventBindingGeneration == binding, self.flowRun?.runID == runID else { return }
            self.eventRefreshTask = nil
            self.flowRun = CanvasFlowRunSnapshot(
                runID: runID, graphID: graphID, phase: status?.phase ?? .running,
                completedSteps: status?.completedSteps ?? 0, totalUnits: status?.totalUnits ?? 0,
                pendingReconciliations: status?.pendingReconciliations ?? 0,
                failureCount: status?.failureCount ?? 0,
                checkpointFailure: status?.checkpointFailure,
                events: self.eventHistory,
                stepRecords: records, lateDeliveries: late, breakpoints: self.flowBreakpoints)
        }
    }

    private func snapshotOfRun(
        runtime: FlowRuntimeService,
        runID: UUID,
        graphID: UUID
    ) async -> CanvasFlowRunSnapshot {
        let status = await runtime.status(runID: runID)
        let records = await runtime.stepRecords(runID: runID)
        let late = await runtime.lateDeliveries(runID: runID)
        let events = await runtime.retainedEvents(runID: runID)
        return CanvasFlowRunSnapshot(
            runID: runID,
            graphID: graphID,
            phase: status?.phase ?? .running,
            completedSteps: status?.completedSteps ?? 0,
            totalUnits: status?.totalUnits ?? 0,
            pendingReconciliations: status?.pendingReconciliations ?? 0,
            failureCount: status?.failureCount ?? 0,
            checkpointFailure: status?.checkpointFailure,
            events: events.reversed(),
            stepRecords: records,
            lateDeliveries: late,
            breakpoints: flowBreakpoints)
    }

    public func pauseFlowRun() {
        guard let runID = flowRun?.runID, let runtime = flowRuntime else { return }
        Task { await runtime.pause(runID: runID) }
    }

    public func resumeFlowRun() {
        guard let runID = flowRun?.runID, let runtime = flowRuntime else { return }
        Task { await runtime.resume(runID: runID) }
    }

    public func stepFlowRun() {
        guard let runID = flowRun?.runID, let runtime = flowRuntime else { return }
        Task { await runtime.step(runID: runID) }
    }

    public func cancelFlowRun() {
        guard let runID = flowRun?.runID, let runtime = flowRuntime else { return }
        Task { await runtime.cancel(runID: runID) }
    }

    public func bypassFlowNode(_ nodeID: UUID) {
        guard let runID = flowRun?.runID, let runtime = flowRuntime else { return }
        Task { await runtime.bypass(nodeID: nodeID, runID: runID) }
    }

    public func toggleFlowBreakpoint(_ nodeID: UUID) {
        if flowBreakpoints.contains(nodeID) {
            flowBreakpoints.remove(nodeID)
        } else {
            flowBreakpoints.insert(nodeID)
        }
        if let runID = flowRun?.runID, let runtime = flowRuntime {
            Task { await runtime.setBreakpoints(self.flowBreakpoints, runID: runID) }
        }
    }

    // MARK: Run output placement (run → compare → save/export)

    /// Metadata stamped on cards created from a run's outputs so repeated
    /// placement of the SAME run dedupes instead of duplicating paid work.
    /// The run itself is recorded in the node's first-class `createdByRunID`.
    public enum RunOutputMetadataKeys {
        public static let runOutputKey = "floe.canvas.runOutputKey"
        /// Deterministic JSON-style path of a typed asset leaf inside a
        /// batch output (e.g. `[2].report`), distinct per run + output key
        /// + path so archive asset collection never scans opaque text.
        public static let runOutputAssetPath = "floe.canvas.runOutputAssetPath"
    }

    public struct CanvasRunOutputPlacementResult: Hashable, Sendable {
        public var placedCount: Int
        public var alreadyPlacedCount: Int
        public var unsupportedCount: Int
        /// True only when the placement batch was CONFIRMED committed by
        /// the repository (exactly one undo unit). When false, nothing is
        /// claimed placed: the original batch/request/revision survive as a
        /// recoverable draft and `placedCount` stays 0 — never a false
        /// success.
        public var committed: Bool
    }

    /// Places the bound run's real `runOutputs` onto the run's ORIGINAL
    /// page as new editable cards in ONE document batch (one undo unit;
    /// a failed commit surfaces as the usual recoverable draft).
    ///
    /// Nothing is interpreted or fabricated: values map 1:1 to native
    /// content (text/table/media/JSON-code); a `.list` batch is saved whole
    /// as an editable JSON card plus typed media cards for its asset
    /// leaves. Bounded values that cannot be materialized produce an
    /// explicit recoverable error — data is never truncated or silently
    /// dropped. Original content is never overwritten — outputs always
    /// land beside existing cards, and a repeated placement of the same
    /// run skips cards it already created (or replays its still-pending
    /// draft with the original request identity).
    @discardableResult
    public func placeFlowRunOutputsOnPage() async -> CanvasRunOutputPlacementResult? {
        let strings = self.strings
        guard let runSnapshot = flowRun else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunUnavailable]))
            return nil
        }
        guard runSnapshot.phase == .completed else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunNotCompleted]))
            return nil
        }
        // Fence: outputs belong to the page the run started on — never to a
        // newly selected page/run.
        guard flowRunPageID == selectedPageID,
              page.flowGraphs.contains(where: { $0.id == runSnapshot.graphID }) else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunPageMismatch]))
            return nil
        }
        // Capture identity BEFORE the first suspension. Every mutable store
        // lookup after an `await` is revalidated against these captured
        // values so the batch can only ever name the original page/run.
        let capturedCanvasID = canvasID
        let capturedRunID = runSnapshot.runID
        let capturedGraphID = runSnapshot.graphID
        let capturedPageID = selectedPageID
        guard let runtime = flowRuntime else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunUnavailable]))
            return nil
        }

        // A still-pending placement of THIS run replays its exact original
        // batch / request / expected revision (the repository receipt
        // lookup precedes CAS) — the repeated button never mints duplicate
        // outputs for an unconfirmed acknowledgement.
        if let pendingDraft = pendingPlacementDraft(forRunID: capturedRunID) {
            switch await retryDraft(pendingDraft) {
            case .committed:
                let count = pendingPlacementInsertCount(pendingDraft)
                presentAlert(CanvasUserAlert(
                    kind: .runOutputsPlaced,
                    title: strings[.debuggerOutputsPlacedTitle],
                    message: strings.formatted(
                        .debuggerOutputsPlaced, count, 0, 0)))
                return CanvasRunOutputPlacementResult(
                    placedCount: count,
                    alreadyPlacedCount: 0,
                    unsupportedCount: 0,
                    committed: true)
            case .pending:
                // Failure alert is already up; the draft keeps the original
                // identity for the next explicit retry.
                return CanvasRunOutputPlacementResult(
                    placedCount: 0,
                    alreadyPlacedCount: 0,
                    unsupportedCount: 0,
                    committed: false)
            }
        }

        // First suspension point: fetching the run result hops off the main
        // actor, so the page/run/graph may change while we are away.
        guard let result = await runtime.result(runID: capturedRunID) else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunUnavailable]))
            return nil
        }
        // Revalidate the captured identity after EVERY suspension before
        // touching mutable state or committing.
        guard capturedCanvasID == canvasID,
              capturedPageID == selectedPageID,
              flowRunPageID == capturedPageID,
              flowRun?.runID == capturedRunID,
              let targetPage = snapshot.pages.first(where: { $0.id == capturedPageID }),
              targetPage.flowGraphs.contains(where: { $0.id == capturedGraphID }) else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunPageMismatch]))
            return nil
        }
        guard result.terminalStatus == .completed else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunNotCompleted]))
            return nil
        }
        // Stale only per the host/runtime report: our own placement commit
        // advances the canvas revision, so revision equality must not fence
        // re-visits (dedupe below handles those). The run→page→graph fences
        // keep identity exact.
        guard !result.stale else {
            presentAlert(CanvasUserAlert(
                kind: .invalidFlow,
                title: strings[.alertInvalidFlowTitle],
                message: strings[.debuggerRunStale]))
            return nil
        }

        // Dedupe: cards this run already placed (same run + output key,
        // where asset cards use key + structural path).
        let existingKeys = Set(targetPage.nodes.compactMap { node -> String? in
            guard node.createdByRunID == capturedRunID else { return nil }
            return node.metadata[Self.RunOutputMetadataKeys.runOutputKey]
        })

        struct PreparedCard {
            var key: String
            var title: String
            var content: CanvasContent
            var metadata: [String: String]?
        }
        var prepared: [PreparedCard] = []
        var alreadyPlaced = 0
        var unsupported = 0
        for (key, value) in result.runOutputs.sorted(by: { $0.key < $1.key }) {
            if existingKeys.contains(key), case .list = value {
                // Asset leaves have independent structural identities below.
            } else if existingKeys.contains(key) {
                alreadyPlaced += 1
                continue
            }
            switch value {
            case .list(let values):
                // Primary batch output: save the WHOLE list as one editable
                // JSON card, plus typed media cards for its asset leaves.
                do {
                    let batch = try CanvasRunOutputPlacement.prepareBatch(values)
                    if existingKeys.contains(key) { alreadyPlaced += 1 }
                    else { prepared.append(PreparedCard(key: key, title: key, content: batch.content, metadata: nil)) }
                    for leaf in batch.assetLeaves {
                        let leafKey = key + leaf.path
                        if existingKeys.contains(leafKey) { alreadyPlaced += 1; continue }
                        prepared.append(PreparedCard(
                            key: leafKey,
                            title: leafKey,
                            content: .media(leaf.locator),
                            metadata: [
                                Self.RunOutputMetadataKeys.runOutputAssetPath: leaf.path,
                            ]))
                    }
                } catch let error as CanvasRunOutputPlacement.MappingError {
                    // Explicit recoverable bound violation: the runtime
                    // result stays intact; nothing is truncated or dropped.
                    presentAlert(CanvasUserAlert(
                        kind: .invalidFlow,
                        title: strings[.alertInvalidFlowTitle],
                        message: strings.formatted(
                            .debuggerRunBatchTooLarge, error.detail)))
                    return nil
                } catch {
                    presentAlert(CanvasUserAlert(
                        kind: .invalidFlow,
                        title: strings[.alertInvalidFlowTitle],
                        message: String(describing: error)))
                    return nil
                }
            default:
                guard let content = CanvasRunOutputPlacement.content(for: value) else {
                    unsupported += 1
                    continue
                }
                prepared.append(PreparedCard(key: key, title: key, content: content, metadata: nil))
            }
        }
        guard !prepared.isEmpty else {
            presentAlert(CanvasUserAlert(
                kind: .runOutputsPlaced,
                title: strings[.debuggerOutputsPlacedTitle],
                message: strings.formatted(
                    .debuggerOutputsPlaced, 0, alreadyPlaced, unsupported)))
            return CanvasRunOutputPlacementResult(
                placedCount: 0,
                alreadyPlacedCount: alreadyPlaced,
                unsupportedCount: unsupported,
                committed: true)
        }

        var placed: [CanvasNodeSnapshot] = prepared.map { card in
            var metadata: [String: String] = [
                Self.RunOutputMetadataKeys.runOutputKey: card.key
            ]
            if let extra = card.metadata {
                for (name, value) in extra { metadata[name] = value }
            }
            CanvasRunOutputStateBadge(runID: capturedRunID).applied(to: &metadata)
            return CanvasNodeSnapshot(
                title: card.title,
                content: card.content,
                frame: .init(center: .zero, size: configuration.defaultNodeSize),
                createdByRunID: capturedRunID,
                metadata: metadata)
        }

        // Anchor beside the ACTUAL current target-page content — the union
        // of its committed node frames — never the prepared layout index
        // (it may be stale or belong to a previous page) and never on top
        // of existing cards.
        let contentBounds: DiagramRect? = targetPage.nodes
            .map { CanvasLayoutGeometry.rect(from: $0.frame) }
            .filter { CanvasLayoutGeometry.isSafeWorldRect($0) }
            .reduce(nil) { partial, rect in
                partial?.union(rect) ?? rect
            }
        let startX = contentBounds.map { $0.maxX + 48 } ?? 0
        let startY = contentBounds.map { $0.y } ?? 0
        for index in placed.indices {
            let column = index / 6
            let row = index % 6
            placed[index].frame = .init(
                center: .init(
                    x: startX + Double(column) * (configuration.defaultNodeSize.width + 32),
                    y: startY + Double(row) * (configuration.defaultNodeSize.height + 28)
                        + configuration.defaultNodeSize.height / 2),
                size: configuration.defaultNodeSize)
        }

        let batch = CanvasDocumentBatch(
            scope: .wholeDocument,
            operations: [
                .editPage(.init(
                    pageID: capturedPageID,
                    scope: .wholeDocument,
                    operations: placed.map { .insertNode($0) }))
            ])
        let outcome = await perform(CanvasCommitAttempt(
            batch: batch,
            requestID: UUID(),
            expectedRevision: revision,
            undoLabel: "Place run outputs"), draftID: nil)
        guard case .committed = outcome else {
            // The batch did NOT confirm: the failure alert is already up
            // and the draft retains the exact batch/request/expected
            // revision. Never claim a false success.
            return CanvasRunOutputPlacementResult(
                placedCount: 0,
                alreadyPlacedCount: alreadyPlaced,
                unsupportedCount: unsupported,
                committed: false)
        }
        presentAlert(CanvasUserAlert(
            kind: .runOutputsPlaced,
            title: strings[.debuggerOutputsPlacedTitle],
            message: strings.formatted(
                .debuggerOutputsPlaced, placed.count, alreadyPlaced, unsupported)))
        return CanvasRunOutputPlacementResult(
            placedCount: placed.count,
            alreadyPlacedCount: alreadyPlaced,
            unsupportedCount: unsupported,
            committed: true)
    }

    /// A still-uncommitted placement batch produced by `runID` (one
    /// edit-page batch inserting only that run's output cards). Matched by
    /// structural identity, never by summary text.
    private func pendingPlacementDraft(forRunID runID: UUID) -> CanvasTransientDraft? {
        drafts.first(where: { draft in
            guard let operations = draft.documentBatch?.operations,
                  operations.count == 1,
                  case .editPage(let batch) = operations[0],
                  !batch.operations.isEmpty else { return false }
            return batch.operations.allSatisfy { operation in
                guard case .insertNode(let node) = operation else { return false }
                return node.createdByRunID == runID
                    && node.metadata[Self.RunOutputMetadataKeys.runOutputKey] != nil
            }
        })
    }

    private func pendingPlacementInsertCount(_ draft: CanvasTransientDraft) -> Int {
        guard let operations = draft.documentBatch?.operations,
              operations.count == 1,
              case .editPage(let batch) = operations[0] else { return 0 }
        return batch.operations.reduce(0) { count, operation in
            if case .insertNode = operation { return count + 1 }
            return count
        }
    }

    // MARK: Content editing sessions

    /// Node whose native content editor is open (text/rich/markdown/table/
    /// formula/code). Focusing is a UI gesture; edits commit as one batch
    /// when the gesture completes.
    @Published public var focusedNodeID: UUID?

    public func focusNode(_ nodeID: UUID) {
        select(nodeID)
        focusedNodeID = nodeID
        showsInspector = false
    }

    public func closeContentEditor() {
        focusedNodeID = nil
    }

    /// Opens the professional editor for the selected node through the
    /// injected gateway (ICH10). Missing gateway = actionable alert.
    public func openEditorForSelectedNode() async {
        guard let node = singleSelectedNode,
              case .editor(let reference) = node.content else { return }
        guard let gateway = services.editorGateway else {
            presentAlert(CanvasUserAlert(
                kind: .missingResource,
                title: strings[.alertMissingResourceTitle],
                message: strings[.editorProjectMissing]))
            return
        }
        do {
            let context = CanvasRuntimeContext(
                canvasID: canvasID,
                pageID: selectedPageID,
                revision: revision)
            showsInspector = false
            try await gateway.openEditor(reference, context: context)
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .missingResource,
                title: strings[.alertMissingResourceTitle],
                message: String(describing: error)))
        }
    }

    /// Applies the child project's current draft back onto the canvas node
    /// (one committed update when the gateway returns a new reference).
    public func applyEditorResult() async {
        guard let node = singleSelectedNode,
              case .editor(let reference) = node.content,
              let gateway = services.editorGateway else { return }
        do {
            let context = CanvasRuntimeContext(
                canvasID: canvasID,
                pageID: selectedPageID,
                revision: revision)
            let updated = try await gateway.applyEditorResult(
                reference, context: context)
            await commit(CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .editPage(.init(
                    pageID: selectedPageID,
                    scope: .wholeDocument,
                    operations: [
                        .updateContent(
                            nodeID: node.id,
                            content: .editor(updated))
                    ]))
            ]), undoLabel: strings[.inspectorApplyEditorResult])
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .missingResource,
                title: strings[.alertMissingResourceTitle],
                message: String(describing: error)))
        }
    }

    /// Host-owned fork of a professional sub-project (never a shallow copy).
    public func forkEditorProject() async {
        guard let node = singleSelectedNode,
              case .editor(let reference) = node.content,
              let forkGateway = services.editorForkGateway else { return }
        do {
            let context = CanvasRuntimeContext(
                canvasID: canvasID,
                pageID: selectedPageID,
                revision: revision)
            let result = try await forkGateway.forkEditor(CanvasEditorForkRequest(
                reference: reference,
                context: context,
                reason: "canvas-ui-fork"))
            await commit(CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .editPage(.init(
                    pageID: selectedPageID,
                    scope: .wholeDocument,
                    operations: [
                        .updateContent(
                            nodeID: node.id,
                            content: .editor(result.forked))
                    ]))
            ]), undoLabel: "Fork")
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .missingResource,
                title: strings[.alertMissingResourceTitle],
                message: String(describing: error)))
        }
    }

    /// Opens the original source through the injected host resolver — the
    /// UI never reconstructs a location from stored document paths.
    public func openOriginalSource(nodeID: UUID) async {
        guard let node = page.nodes.first(where: { $0.id == nodeID }),
              let source = node.source,
              let opening = services.sourceOpening else {
            presentAlert(CanvasUserAlert(
                kind: .sourceUnavailable,
                title: strings[.alertSourceUnavailable],
                message: strings[.alertSourceUnavailable]))
            return
        }
        do {
            try await opening.openSource(
                sourceID: source.sourceID,
                fragment: source.fragment)
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .sourceUnavailable,
                title: strings[.alertSourceUnavailable],
                message: String(describing: error)))
        }
    }

    // MARK: Source actions (ICH04)

    /// Explicit source refresh; never automatic. The result commits through
    /// the normal pipeline, preserving annotations and manual layout.
    public func refreshSource(
        nodeID: UUID,
        instruction: CanvasSourceRefresher.Instruction
    ) async {
        guard let sourceService = services.sourceService else {
            presentAlert(CanvasUserAlert(
                kind: .sourceUnavailable,
                title: strings[.alertSourceUnavailable],
                message: strings[.alertSourceUnavailable]))
            return
        }
        let refreshBase = snapshot
        let refreshPageID = selectedPageID
        let refresher = CanvasSourceRefresher(sourceService: sourceService)
        do {
            let result = try await refresher.refresh(
                canvasID: canvasID,
                in: refreshBase,
                pageID: refreshPageID,
                nodeIDs: [nodeID],
                instruction: instruction)
            switch result.outcome {
            case .unchanged:
                break
            case .updated, .conflict:
                // Commit the refreshed snapshot as one batch. Conflicts keep
                // originals and add recoverable branch nodes (ICH04).
                guard let refreshedPage = result.snapshot.pages.first(where: { $0.id == refreshPageID }) else {
                    throw CanvasKitError.missingEntity("refresh page")
                }
                var edits: [CanvasEditOperation] = []
                var attributes: [CanvasDocumentOperation] = []
                switch result.outcome {
                case .updated(let nodeIDs):
                    for id in nodeIDs {
                        guard let node = refreshedPage.nodes.first(where: { $0.id == id }) else { continue }
                        edits.append(.updateContent(nodeID: id, content: node.content))
                        attributes.append(.updateNodeSource(nodeID: id, source: node.source))
                    }
                case .conflict(let alternatives, _):
                    for id in alternatives {
                        guard var node = refreshedPage.nodes.first(where: { $0.id == id }) else { continue }
                        node.groupID = nil
                        node.regionID = nil
                        node.metadata.removeValue(forKey: "floe.flow.graphID")
                        node.metadata.removeValue(forKey: "floe.flow.nodeID")
                        edits.append(.insertNode(node))
                    }
                case .unchanged: break
                }
                let batch = CanvasDocumentBatch(operations: [
                    .editPage(.init(pageID: refreshPageID, operations: edits))
                ] + attributes)
                await perform(CanvasCommitAttempt(batch: batch, requestID: UUID(),
                    expectedRevision: refreshBase.revision,
                    undoLabel: strings[.inspectorRefreshSource]), draftID: nil)
            }
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .sourceUnavailable,
                title: strings[.alertSourceUnavailable],
                message: String(describing: error)))
        }
    }

    // MARK: Lab actions

    public func runLabAction(_ action: CanvasLabAction) async {
        do {
            try await action.run(self)
        } catch {
            presentAlert(CanvasUserAlert(
                kind: .labActionFailed,
                title: strings[.alertSaveFailedTitle],
                message: String(describing: error)))
        }
    }
}

public extension CanvasInspectorTab {
    /// Which inspector tab a node opens with.
    static func defaultTab(for node: CanvasNodeSnapshot) -> CanvasInspectorTab {
        if CanvasFlowCardBinding(metadata: node.metadata) != nil { return .flow }
        switch node.content {
        case .media, .pdf, .editor:
            return .resource
        case .web, .text, .markdown, .richText, .code, .formula, .table, .shape:
            if node.source != nil { return .source }
            return .node
        case .unknown:
            return .node
        }
    }
}

#endif // canImport(UIKit)
