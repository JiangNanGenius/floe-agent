import Foundation
import FloeCanvasCore

/// The host's actual edit request context, issued from the user's current
/// intent and selection. This is the AUTHORITY a gateway reply is
/// validated against: imported Codable fields (including a batch's own
/// `scope`) are data, never authority. Ordinary authorized edits stay
/// direct — this adds no approval prompts or second-confirmation steps.
public struct CanvasHostEditContext: Hashable, Sendable {
    public var canvasID: UUID
    public var pageID: UUID
    /// Revision the host loaded and is editing against.
    public var revision: Int64
    /// The user's actual current selection.
    public var selectedNodeIDs: Set<UUID>
    /// True only when the host itself granted a whole-document operation
    /// from the user's intent (e.g. "apply to the whole canvas").
    public var grantsWholeDocument: Bool
    /// The host request explicitly allows creating new nodes (branch
    /// results, new cards, …).
    public var allowsCreation: Bool
    /// The host request explicitly allows removing nodes.
    public var allowsRemoval: Bool
    /// The host request explicitly allows lock CHANGES (lock or unlock).
    /// Absent by default: lock state is a host ownership gesture.
    public var allowsLockChanges: Bool
    /// The host request explicitly allows structural creation (a new flow
    /// draft plus its card on the current selection's page).
    public var allowsStructuralChanges: Bool
    /// The user explicitly authorized editing the SELECTED flow/card in
    /// place (ICQA04: an explicit "change this one" instruction). Only
    /// flow-definition differences bound to trusted selected cards — and
    /// attribute edits on selected nodes — become legal; everything else
    /// stays host work.
    public var allowsSelectedFlowEdits: Bool

    public init(
        canvasID: UUID,
        pageID: UUID,
        revision: Int64,
        selectedNodeIDs: Set<UUID>,
        grantsWholeDocument: Bool = false,
        allowsCreation: Bool = false,
        allowsRemoval: Bool = false,
        allowsLockChanges: Bool = false,
        allowsStructuralChanges: Bool = false,
        allowsSelectedFlowEdits: Bool = false
    ) {
        self.canvasID = canvasID
        self.pageID = pageID
        self.revision = revision
        self.selectedNodeIDs = selectedNodeIDs
        self.grantsWholeDocument = grantsWholeDocument
        self.allowsCreation = allowsCreation
        self.allowsRemoval = allowsRemoval
        self.allowsLockChanges = allowsLockChanges
        self.allowsStructuralChanges = allowsStructuralChanges
        self.allowsSelectedFlowEdits = allowsSelectedFlowEdits
    }
}

/// Validation helper for assistant-produced edits. The gateway's reply can
/// NARROW the host grant but never broaden it:
///
/// 1. A batch claiming `.wholeDocument` without an explicit host grant is
///    rejected (`scopeEscalation`).
/// 2. Lock changes are rejected unless the host request explicitly allows
///    them — a model may NOT unlock-then-modify.
/// 3. Creation/removal intent must come from the actual host request.
/// 4. Organizational gestures (`setRegionCollapsed`, page-original Pencil
///    data) require the whole-document grant; they cannot slip past a
///    selection by not touching a node.
/// 5. The batch is re-bound to the host's real selection — plus only the
///    IDs it genuinely creates when creation is authorized — so duplicate
///    IDs can never reach outside the selection to update an original.
public enum CanvasAssistantEditGuard {
    public static func validatedBatch(
        _ batch: CanvasEditBatch,
        request: CanvasHostEditContext
    ) throws -> CanvasEditBatch {
        var violations: [CanvasEditViolation] = []

        if case .wholeDocument = batch.scope, !request.grantsWholeDocument {
            violations.append(.init(
                operationIndex: 0, reason: .scopeEscalation,
                detail: "gateway returned wholeDocument scope but the host "
                    + "request only granted selectedNodes"))
        }

        for (index, operation) in batch.operations.enumerated() {
            switch operation {
            case .insertNode:
                if !request.allowsCreation {
                    violations.append(.init(
                        operationIndex: index, reason: .creationNotGranted))
                }
            case .removeNode:
                if !request.allowsRemoval {
                    violations.append(.init(
                        operationIndex: index, reason: .removalNotGranted))
                }
            case .setLocked:
                if !request.allowsLockChanges {
                    violations.append(.init(
                        operationIndex: index, reason: .lockNotGranted,
                        detail: "lock changes require explicit host intent; "
                            + "a model may not unlock-then-modify"))
                }
            case .setRegionCollapsed:
                if !request.grantsWholeDocument {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        detail: "organizational gestures cannot bypass the "
                            + "selection scope"))
                }
            case .setPencilDrawingData:
                // Page-original strokes are a host ownership gesture.
                violations.append(.init(
                    operationIndex: index, reason: .scopeEscalation,
                    detail: "assistant batches may not replace pencil "
                        + "drawing data"))
            default:
                break
            }
        }

        if batch.pageID != request.pageID, !request.grantsWholeDocument {
            violations.append(.init(
                operationIndex: 0, reason: .pageMissing,
                detail: "batch targets page \(batch.pageID.uuidString) but "
                    + "the host request is for page \(request.pageID.uuidString)"))
        }

        // Effective scope: the host's real selection, extended ONLY with the
        // IDs this batch actually creates when creation is authorized. The
        // engine's duplicate-ID check then guarantees a create can never
        // overwrite an unselected original.
        var effectiveSelection = request.selectedNodeIDs
        if request.allowsCreation {
            for operation in batch.operations {
                if case .insertNode(let node) = operation {
                    effectiveSelection.insert(node.id)
                }
            }
        }
        let effectiveScope: CanvasEditScope = request.grantsWholeDocument
            ? batch.scope
            : .selectedNodes(effectiveSelection)

        guard violations.isEmpty else {
            throw CanvasKitError.editScopeViolations(violations)
        }
        return CanvasEditBatch(
            pageID: batch.pageID, scope: effectiveScope,
            operations: batch.operations)
    }
}

/// Proposal form for the extended assistant gateway: a reply may carry
/// either a classic page batch or a document-level (structural) batch, so
/// an authorized "build a flow draft from this selection" request lands as
/// ONE commit (card + graph, one undo unit) instead of being split.
public enum CanvasAssistantProposal: Hashable, Sendable {
    case canvasBatch(CanvasEditBatch)
    case documentBatch(CanvasDocumentBatch)
}

/// Extended gateway. Existing `CanvasAssistantGateway` conformances stay
/// valid; hosts that accept structural proposals adopt this protocol.
public protocol CanvasAssistantProposalGateway: Sendable {
    func propose(
        request: CanvasAssistantRequest
    ) async throws -> CanvasAssistantProposal
}

public extension CanvasAssistantEditGuard {
    /// Validates a gateway proposal against the actual host request
    /// (create-only compatibility path — prefer the `against:` overload for
    /// real requests so structural checks run against the live snapshot).
    ///
    /// Document proposals are CREATE-ONLY here: they may insert a new flow
    /// graph on the request's page and/or create card nodes, but they may
    /// not modify unselected originals, existing graphs, pages, locks or
    /// strokes, and they never carry run authority (execution records stay
    /// out of document state by construction). This is not a path for a
    /// model to grant itself whole-document power: either the host granted
    /// the whole document, or the request explicitly authorized structural
    /// creation — the engine re-checks scope, locks and final-state
    /// bindings at commit time anyway.
    static func validatedProposal(
        _ proposal: CanvasAssistantProposal,
        request: CanvasHostEditContext
    ) throws -> CanvasAssistantProposal {
        switch proposal {
        case .canvasBatch(let batch):
            return .canvasBatch(try validatedBatch(batch, request: request))
        case .documentBatch(let batch):
            try validateDocumentProposal(batch, request: request, snapshot: nil)
            return .documentBatch(batch)
        }
    }

    /// Snapshot-validated proposal check. Beyond the create-only rules this
    /// verifies the request actually matches the document (canvas, page,
    /// revision), pins inserted connections to the trusted selection plus
    /// this batch's own new node IDs (two unselected originals can never be
    /// newly wired together), and — when the user explicitly authorized
    /// editing the selected flow/card in place — allows a `replaceFlowGraph`
    /// whose changed flow nodes/ports/edges are all bound to trusted
    /// selected cards, plus attribute edits on selected nodes. Unselected
    /// definition content, pages, graphs, connections and locks stay
    /// protected; the engine re-validates the whole final diff at commit.
    static func validatedProposal(
        _ proposal: CanvasAssistantProposal,
        request: CanvasHostEditContext,
        against snapshot: CanvasSnapshot
    ) throws -> CanvasAssistantProposal {
        guard request.canvasID == snapshot.id else {
            throw CanvasKitError.editScopeViolations([.init(
                operationIndex: 0, reason: .invalidReference,
                detail: "host request targets a different canvas")])
        }
        guard request.revision == snapshot.revision else {
            throw CanvasKitError.revisionConflict(expected: request.revision, current: snapshot.revision)
        }
        guard snapshot.pages.contains(where: { $0.id == request.pageID }) else {
            throw CanvasKitError.editScopeViolations([.init(
                operationIndex: 0, reason: .pageMissing,
                detail: "host request page is absent from the current snapshot")])
        }
        switch proposal {
        case .canvasBatch(let batch):
            return .canvasBatch(try validatedBatch(batch, request: request))
        case .documentBatch(let batch):
            try validateDocumentProposal(
                batch, request: request, snapshot: snapshot)
            return .documentBatch(batch)
        }
    }

    private static func validateDocumentProposal(
        _ batch: CanvasDocumentBatch,
        request: CanvasHostEditContext,
        snapshot: CanvasSnapshot?
    ) throws {
        var violations: [CanvasEditViolation] = []
        if case .selectedNodes = batch.scope {
            violations.append(.init(
                operationIndex: 0, reason: .scopeEscalation,
                detail: "document proposals must carry wholeDocument scope; "
                    + "the guard decides from the host request, not the batch"))
        }
        if !request.grantsWholeDocument && !request.allowsStructuralChanges
            && !request.allowsCreation && !request.allowsSelectedFlowEdits {
            violations.append(.init(
                operationIndex: 0, reason: .creationNotGranted,
                detail: "document proposals require grantsWholeDocument or "
                    + "explicit creation/edit intent in the host request"))
        }
        for (index, operation) in batch.operations.enumerated() {
            switch operation {
            case .insertFlowGraph(let pageID, let graph):
                if !request.allowsCreation && !request.grantsWholeDocument {
                    violations.append(.init(operationIndex: index, reason: .creationNotGranted))
                }
                // Structural creation on the request's page (never cross-page).
                if pageID != request.pageID, !request.grantsWholeDocument {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing,
                        detail: "assistant flow creation may not cross pages "
                            + "without a whole-document grant"))
                }
                if let snapshot {
                    let graphExists = snapshot.pages.contains {
                        $0.flowGraphs.contains(where: { $0.id == graph.id })
                    }
                    if graphExists {
                        violations.append(.init(
                            operationIndex: index, reason: .duplicateID,
                            detail: "insertFlowGraph collides with an existing "
                                + "graph; use replaceFlowGraph for edits"))
                    }
                }
            case .editPage(let nested):
                if nested.pageID != request.pageID,
                   !request.grantsWholeDocument {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing,
                        detail: "assistant document proposals may not cross "
                            + "pages without a whole-document grant"))
                }
                if case .selectedNodes = nested.scope {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        detail: "editPage requires wholeDocument scope"))
                }
                // Endpoints of a NEW connection must come from the trusted
                // selection or this batch's own new node IDs.
                var newNodeIDs = Set<UUID>()
                for nestedOperation in nested.operations {
                    if case .insertNode(let node) = nestedOperation {
                        newNodeIDs.insert(node.id)
                    }
                }
                let allowedEndpoints = request.grantsWholeDocument
                    ? nil
                    : request.selectedNodeIDs.union(newNodeIDs)
                for nestedOperation in nested.operations {
                    switch nestedOperation {
                    case .insertNode:
                        if !request.allowsCreation && !request.grantsWholeDocument {
                            violations.append(.init(operationIndex: index, reason: .creationNotGranted))
                        }
                    case .insertConnection(let connection):
                        if let allowedEndpoints,
                           !(allowedEndpoints.contains(connection.sourceNodeID)
                             && allowedEndpoints.contains(
                                connection.destinationNodeID)) {
                            violations.append(.init(
                                operationIndex: index,
                                reason: .scopeEscalation,
                                connectionID: connection.id,
                                detail: "assistant proposals may only connect "
                                    + "trusted selected nodes or nodes created "
                                    + "in the same batch"))
                        }
                    default:
                        violations.append(.init(
                            operationIndex: index, reason: .scopeEscalation,
                            detail: "assistant document proposals may only "
                                + "create; modifying existing nodes, "
                                + "connections, regions or locks is host work"))
                    }
                }
            case .replaceFlowGraph(let graph):
                guard request.allowsSelectedFlowEdits
                    || request.grantsWholeDocument else {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        detail: "in-place flow edits require explicit host "
                            + "intent (allowsSelectedFlowEdits)"))
                    continue
                }
                guard let snapshot else {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        detail: "replaceFlowGraph needs the snapshot-validated "
                            + "proposal path"))
                    continue
                }
                guard let existing = snapshot.pages
                    .flatMap({ $0.flowGraphs })
                    .first(where: { $0.id == graph.id }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .flowGraphMissing,
                        detail: "replaceFlowGraph targets a graph that does "
                            + "not exist"))
                    continue
                }
                // Every changed flow node/port/edge must be bound to a
                // trusted selected (and unlocked) card.
                let changed = changedFlowNodeIDs(old: existing, new: graph)
                for flowNodeID in changed
                .sorted(by: { $0.uuidString < $1.uuidString }) {
                    let boundCards = snapshot.pages
                        .flatMap { $0.nodes }
                        .filter { node in
                            guard let binding = CanvasFlowCardBinding(
                                metadata: node.metadata) else { return false }
                            return binding.graphID == graph.id
                                && binding.nodeID == flowNodeID
                        }
                    guard let card = boundCards.first(where: {
                        request.selectedNodeIDs.contains($0.id) && !$0.isLocked
                    }) else {
                        violations.append(.init(
                            operationIndex: index, reason: .invalidReference,
                            detail: "changed flow node "
                                + "\(flowNodeID.uuidString) is not bound to a "
                                + "trusted selected card; the unselected "
                                + "definition must stay unchanged"))
                        continue
                    }
                }
            case .updateNodeSource(let nodeID, _),
                 .updateNodeRotation(let nodeID, _),
                 .updateNodeStyle(let nodeID, _),
                 .updateNodeMetadata(let nodeID, _, _):
                guard request.allowsSelectedFlowEdits
                    || request.grantsWholeDocument else {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        nodeID: nodeID,
                        detail: "node attribute edits require explicit host "
                            + "intent"))
                    continue
                }
                if !request.grantsWholeDocument,
                   !request.selectedNodeIDs.contains(nodeID) {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope,
                        nodeID: nodeID,
                        detail: "node is outside the trusted selection"))
                }
            default:
                violations.append(.init(
                    operationIndex: index, reason: .scopeEscalation,
                    detail: "assistant document proposals may only create new "
                        + "flow/card state or explicitly authorized selected "
                        + "edits, not modify pages, groups, regions, scenes, "
                        + "strokes, graphs or locks"))
            }
        }
        guard violations.isEmpty else {
            throw CanvasKitError.editScopeViolations(violations)
        }
    }

    /// Flow-node IDs touched by a graph replacement: modified/added/removed
    /// nodes, plus endpoints of changed edges and owners of changed
    /// variables. Unchanged definition content yields an empty set.
    static func changedFlowNodeIDs(
        old: FlowGraph, new: FlowGraph
    ) -> Set<UUID> {
        var changed = Set<UUID>()
        let oldNodes = Dictionary(
            grouping: old.nodes, by: \.id).compactMapValues(\.first)
        for node in new.nodes {
            if let existing = oldNodes[node.id] {
                if existing != node { changed.insert(node.id) }
            } else {
                changed.insert(node.id)
            }
        }
        let newNodeIDs = Set(new.nodes.map(\.id))
        for node in old.nodes where !newNodeIDs.contains(node.id) {
            changed.insert(node.id)
        }

        let oldEdges = Dictionary(
            grouping: old.edges, by: \.id).compactMapValues(\.first)
        func note(_ edge: FlowEdge) {
            changed.insert(edge.sourceNodeID)
            changed.insert(edge.destinationNodeID)
        }
        for edge in new.edges {
            if let existing = oldEdges[edge.id] {
                if existing != edge { note(edge) }
            } else {
                note(edge)
            }
        }
        let newEdgeIDs = Set(new.edges.map(\.id))
        for edge in old.edges where !newEdgeIDs.contains(edge.id) {
            note(edge)
        }

        let oldVariables = Dictionary(
            grouping: old.variables, by: \.id).compactMapValues(\.first)
        for variable in new.variables {
            if let existing = oldVariables[variable.id] {
                if existing != variable {
                    changed.insert(variable.ownerNodeID)
                }
            } else {
                changed.insert(variable.ownerNodeID)
            }
        }
        let newVariableIDs = Set(new.variables.map(\.id))
        for variable in old.variables
        where !newVariableIDs.contains(variable.id) {
            changed.insert(variable.ownerNodeID)
        }
        return changed
    }
}
