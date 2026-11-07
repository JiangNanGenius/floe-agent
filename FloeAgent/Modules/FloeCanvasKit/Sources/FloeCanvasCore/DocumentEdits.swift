import Foundation

/// P0.1 additive document transactions: explicit domain edits for pages,
/// groups, regions, scenes, strokes, node source/rotation/style attributes
/// and page-attached flow-graph definitions.
///
/// These run through the SAME store pipeline as `CanvasEditBatch`
/// (expected-revision CAS, request-ID idempotency, one batch = one undo
/// unit, persistence rollback) — there is no second store and no unchecked
/// wholesale replace. Structural edits are host-authority gestures: a
/// document batch requires `.wholeDocument` scope; selection-scoped
/// assistants stay on `CanvasEditOperation` (`CanvasAssistantEditGuard`
/// in Integration enforces that boundary).
public enum CanvasDocumentOperation: Codable, Hashable, Sendable {
    case updateCanvasMetadata(values: [String: String], removingKeys: [String])
    case renameCanvas(name: String)
    // MARK: Pages
    /// Creates a page. When `select` is true the new page becomes the
    /// selected page. The page is fully validated (duplicate IDs, internal
    /// references, geometry, flow graphs).
    case createPage(CanvasPageSnapshot, select: Bool)
    case renamePage(pageID: UUID, name: String)
    /// Reorders pages; `orderedPageIDs` must be a permutation of the
    /// snapshot's page IDs.
    case reorderPages(orderedPageIDs: [UUID])
    /// Deletes a page. The last remaining page can never be deleted;
    /// deleting the selected page selects the first surviving page in
    /// declared order.
    case deletePage(pageID: UUID)
    case selectPage(pageID: UUID)
    case setPageBackground(pageID: UUID, background: CanvasBackgroundStyle)
    case setViewport(pageID: UUID, viewport: CanvasViewport)

    // MARK: Groups
    case createGroup(pageID: UUID, group: CanvasGroupRecord)
    /// Replaces name and/or membership of an existing group.
    case updateGroup(CanvasGroupRecord)
    /// Removing a group keeps its members' content (members just lose the
    /// groupID). `deleteMembers: true` also deletes the member nodes —
    /// including their connections and memberships — and rejects the whole
    /// batch when any member is locked.
    case removeGroup(groupID: UUID, deleteMembers: Bool)
    /// Moves every member of the group by `delta` as one atomic update;
    /// locked members reject the whole batch.
    case moveGroup(groupID: UUID, delta: CanvasGeometry.Point)

    // MARK: Regions
    case createRegion(pageID: UUID, region: CanvasRegionRecord)
    case updateRegion(CanvasRegionRecord)
    /// Removing a region keeps its contents (nodes just lose the regionID
    /// cache). `deleteContents: true` also deletes the cached member nodes,
    /// rejecting the whole batch when any of them is locked.
    case removeRegion(regionID: UUID, deleteContents: Bool)

    // MARK: Scenes
    case createScene(pageID: UUID, scene: CanvasSceneRecord)
    case updateScene(CanvasSceneRecord)
    case removeScene(sceneID: UUID)

    // MARK: Strokes
    case addStroke(pageID: UUID, stroke: CanvasStrokeSnapshot)
    case updateStroke(CanvasStrokeSnapshot)
    case removeStroke(strokeID: UUID)

    // MARK: Unified transaction composition
    /// Nests a classic page edit batch inside this document transaction so
    /// node/connection work (insert flow card, convert ink to shape, …)
    /// composes with structural edits in ONE batch — one store CAS, one
    /// receipt, one revision bump, one undo unit. The nested batch must
    /// declare `.wholeDocument` scope itself: a document transaction can
    /// never widen, only narrow, the host trust it runs under. Nested
    /// violations abort the WHOLE document batch (nothing applies).
    case editPage(CanvasEditBatch)

    // MARK: Node attribute edits (beyond CanvasEditOperation)
    /// Replaces or detaches (nil) the node's source reference.
    case updateNodeSource(nodeID: UUID, source: CanvasSourceReference?)
    case updateNodeRotation(nodeID: UUID, rotationDegrees: Double)
    /// Updates presentation style (zIndex). Visual styling metadata is
    /// validated against `CanvasVisualStyle` canonical spellings.
    case updateNodeStyle(nodeID: UUID, zIndex: Int)
    /// Explicit metadata patch: merges `values`, removes `removingKeys`,
    /// preserves every untouched key. Visual-style values must satisfy the
    /// canonical color/width grammar; flow-card binding values must be
    /// well-formed UUIDs; final-state binding consistency is validated with
    /// the rest of the batch.
    case updateNodeMetadata(
        nodeID: UUID, values: [String: String], removingKeys: [String])

    // MARK: Page-attached flow definitions
    /// Inserts a validated flow-graph definition. Graph revisions must
    /// increase on every definition change (`replaceFlowGraph` enforces
    /// this); execution records/checkpoints never enter document state.
    case insertFlowGraph(pageID: UUID, graph: FlowGraph)
    /// Replaces a definition; requires a strictly greater graph revision.
    case replaceFlowGraph(graph: FlowGraph)
    case removeFlowGraph(graphID: UUID)
}

/// One atomic document-level batch. Requires `.wholeDocument` scope:
/// structural edits are host authority, not selection data.
public struct CanvasDocumentBatch: Codable, Hashable, Sendable {
    public var scope: CanvasEditScope
    public var operations: [CanvasDocumentOperation]

    public init(
        scope: CanvasEditScope = .wholeDocument,
        operations: [CanvasDocumentOperation]
    ) {
        self.scope = scope
        self.operations = operations
    }
}

public struct CanvasDocumentEditResult: Hashable, Sendable {
    public var snapshot: CanvasSnapshot
    public var changedPageIDs: [UUID]
    public var changedNodeIDs: [UUID]
    public var changedFlowGraphIDs: [UUID]

    public init(
        snapshot: CanvasSnapshot,
        changedPageIDs: [UUID],
        changedNodeIDs: [UUID],
        changedFlowGraphIDs: [UUID]
    ) {
        self.snapshot = snapshot
        self.changedPageIDs = changedPageIDs
        self.changedNodeIDs = changedNodeIDs
        self.changedFlowGraphIDs = changedFlowGraphIDs
    }
}

public enum CanvasDocumentEditEngine {
    /// Validates the whole batch first, then returns the next snapshot.
    /// Throws `editScopeViolations` with ALL violations found, or
    /// `invalidFlowGraph` for structurally broken flow definitions; on any
    /// throw the input snapshot is untouched.
    public static func apply(
        _ batch: CanvasDocumentBatch,
        to snapshot: CanvasSnapshot
    ) throws -> CanvasDocumentEditResult {
        if case .selectedNodes(let ids) = batch.scope {
            throw CanvasKitError.editScopeViolations([.init(
                operationIndex: 0, reason: .scopeEscalation,
                detail: "document transactions require wholeDocument scope; "
                    + "received selectedNodes(\(ids.count))")])
        }
        try validateStoredIDs(snapshot)

        var next = snapshot
        var violations: [CanvasEditViolation] = []
        var changedPages = Set<UUID>()
        var changedNodes = Set<UUID>()
        var changedGraphs = Set<UUID>()

        for (index, operation) in batch.operations.enumerated() {
            switch operation {
            case .updateCanvasMetadata(let values, let removingKeys):
                for key in removingKeys { next.metadata.removeValue(forKey: key) }
                next.metadata.merge(values) { _, new in new }
                changedPages.formUnion(next.pages.map(\.id))
            case .renameCanvas(let name):
                next.name = name
            case .setPageBackground(let pageID, let background):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(operationIndex: index, reason: .pageMissing)); continue
                }
                next.pages[pageIndex].background = background
                changedPages.insert(pageID)
            case .setViewport(let pageID, let viewport):
                guard next.pages.contains(where: { $0.id == pageID }) else {
                    violations.append(.init(operationIndex: index, reason: .pageMissing)); continue
                }
                guard viewport.center.x.isFinite, viewport.center.y.isFinite,
                      viewport.scale.isFinite, viewport.scale > 0 else {
                    violations.append(.init(operationIndex: index, reason: .invalidGeometry)); continue
                }
                next.viewports[pageID] = viewport
            case .createPage(let page, let select):
                guard !next.pages.contains(where: { $0.id == page.id }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "page \(page.id.uuidString) already exists"))
                    continue
                }
                do {
                    try validateNewPage(page)
                } catch let CanvasKitError.invalidSnapshot(message) {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: message))
                    continue
                }
                next.pages.append(page)
                if select { next.selectedPageID = page.id }
                changedPages.insert(page.id)

            case .renamePage(let pageID, let name):
                guard let pageIndex = next.pages.firstIndex(where: {
                    $0.id == pageID
                }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                next.pages[pageIndex].name = name
                changedPages.insert(pageID)

            case .reorderPages(let orderedPageIDs):
                let existing = next.pages.map(\.id)
                guard orderedPageIDs.count == existing.count,
                      Set(orderedPageIDs) == Set(existing) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: "orderedPageIDs must be a permutation of the "
                            + "snapshot's page IDs"))
                    continue
                }
                let order = Dictionary(
                    uniqueKeysWithValues: orderedPageIDs.enumerated()
                        .map { ($0.element, $0.offset) })
                next.pages.sort { order[$0.id]! < order[$1.id]! }

            case .deletePage(let pageID):
                guard let pageIndex = next.pages.firstIndex(where: {
                    $0.id == pageID
                }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard next.pages.count > 1 else {
                    violations.append(.init(
                        operationIndex: index, reason: .lastPageRemaining,
                        detail: "cannot delete the last remaining page"))
                    continue
                }
                next.pages.remove(at: pageIndex)
                next.viewports[pageID] = nil
                if next.selectedPageID == pageID {
                    // First surviving page in declared order.
                    next.selectedPageID = next.pages[0].id
                }
                changedPages.insert(pageID)

            case .selectPage(let pageID):
                guard next.pages.contains(where: { $0.id == pageID }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                next.selectedPageID = pageID

            case .createGroup(let pageID, let group):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard findGroup(group.id, in: next) == nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "group \(group.id.uuidString) already exists"))
                    continue
                }
                let nodeIDs = Set(next.pages[pageIndex].nodes.map(\.id))
                guard Set(group.memberNodeIDs).isSubset(of: nodeIDs) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: "group member is not a node on page "
                            + pageID.uuidString))
                    continue
                }
                next.pages[pageIndex].groups.append(group)
                changedPages.insert(pageID)

            case .updateGroup(let group):
                guard let (pageIndex, groupIndex) = findGroup(
                    group.id, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .groupMissing))
                    continue
                }
                let nodeIDs = Set(next.pages[pageIndex].nodes.map(\.id))
                guard Set(group.memberNodeIDs).isSubset(of: nodeIDs) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: "group member is not a node on the group's page"))
                    continue
                }
                next.pages[pageIndex].groups[groupIndex] = group
                changedPages.insert(next.pages[pageIndex].id)

            case .removeGroup(let groupID, let deleteMembers):
                guard let (pageIndex, groupIndex) = findGroup(
                    groupID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .groupMissing))
                    continue
                }
                let memberIDs = next.pages[pageIndex].groups[groupIndex]
                    .memberNodeIDs
                if deleteMembers {
                    let lockedMembers = memberIDs.filter { memberID in
                        node(memberID, in: next)?.isLocked == true
                    }
                    if !lockedMembers.isEmpty {
                        for memberID in lockedMembers {
                            violations.append(.init(
                                operationIndex: index, reason: .nodeLocked,
                                nodeID: memberID,
                                detail: "deleteMembers requires every member "
                                    + "to be unlocked"))
                        }
                        continue
                    }
                    for memberID in memberIDs {
                        removeNodeCompletely(&next, memberID)
                        changedNodes.insert(memberID)
                    }
                    changedPages.insert(next.pages[pageIndex].id)
                } else {
                    for nodeIndex in next.pages[pageIndex].nodes.indices
                    where next.pages[pageIndex].nodes[nodeIndex].groupID == groupID {
                        next.pages[pageIndex].nodes[nodeIndex].groupID = nil
                        changedNodes.insert(
                            next.pages[pageIndex].nodes[nodeIndex].id)
                    }
                    changedPages.insert(next.pages[pageIndex].id)
                }
                next.pages[pageIndex].groups.removeAll { $0.id == groupID }

            case .moveGroup(let groupID, let delta):
                guard delta.x.isFinite, delta.y.isFinite else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        detail: "group move delta must be finite"))
                    continue
                }
                guard let (pageIndex, groupIndex) = findGroup(
                    groupID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .groupMissing))
                    continue
                }
                let memberIDs = next.pages[pageIndex].groups[groupIndex]
                    .memberNodeIDs
                var lockedMembers = Set<UUID>()
                for memberID in memberIDs {
                    guard let node = node(memberID, in: next) else {
                        violations.append(.init(
                            operationIndex: index, reason: .invalidReference,
                            nodeID: memberID,
                            detail: "group member does not exist"))
                        continue
                    }
                    if node.isLocked { lockedMembers.insert(memberID) }
                }
                if !lockedMembers.isEmpty {
                    for memberID in lockedMembers.sorted(by: {
                        $0.uuidString < $1.uuidString
                    }) {
                        violations.append(.init(
                            operationIndex: index, reason: .nodeLocked,
                            nodeID: memberID,
                            detail: "group move is atomic; locked member "
                                + "rejects the whole batch"))
                    }
                    continue
                }
                for memberID in memberIDs {
                    guard let (mPage, mNode) = nodeIndex(
                        memberID, in: next) else { continue }
                    next.pages[mPage].nodes[mNode].frame.center.x += delta.x
                    next.pages[mPage].nodes[mNode].frame.center.y += delta.y
                    changedNodes.insert(memberID)
                }
                changedPages.insert(next.pages[pageIndex].id)

            case .createRegion(let pageID, let region):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard findRegion(region.id, in: next) == nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "region \(region.id.uuidString) already exists"))
                    continue
                }
                guard isUsableFrame(region.frame) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        detail: "region frame must be finite with positive size"))
                    continue
                }
                next.pages[pageIndex].regions.append(region)
                changedPages.insert(pageID)

            case .updateRegion(let region):
                guard let (pageIndex, regionIndex) = findRegion(
                    region.id, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .regionMissing))
                    continue
                }
                guard isUsableFrame(region.frame) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        detail: "region frame must be finite with positive size"))
                    continue
                }
                next.pages[pageIndex].regions[regionIndex] = region
                changedPages.insert(next.pages[pageIndex].id)

            case .removeRegion(let regionID, let deleteContents):
                guard let (pageIndex, regionIndex) = findRegion(
                    regionID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .regionMissing))
                    continue
                }
                if deleteContents {
                    // Containment is GEOMETRIC (region.frame contains
                    // node.frame.center), never the regionID cache: the
                    // cache is a derived hint that move operations do not
                    // maintain, and an outer region contains the members of
                    // nested inner regions too.
                    let memberIDs = nodeIDsContainedByRegion(
                        regionID, in: next)
                    let lockedMembers = memberIDs.filter { memberID in
                        node(memberID, in: next)?.isLocked == true
                    }
                    if !lockedMembers.isEmpty {
                        for memberID in lockedMembers {
                            violations.append(.init(
                                operationIndex: index, reason: .nodeLocked,
                                nodeID: memberID,
                                detail: "deleteContents requires every cached "
                                    + "member to be unlocked"))
                        }
                        continue
                    }
                    for memberID in memberIDs {
                        removeNodeCompletely(&next, memberID)
                        changedNodes.insert(memberID)
                    }
                    changedPages.insert(next.pages[pageIndex].id)
                } else {
                    // Keep contents: the derived cache is recomputed below,
                    // so nodes that were inside simply lose the region.
                    changedPages.insert(next.pages[pageIndex].id)
                }
                next.pages[pageIndex].regions.removeAll { $0.id == regionID }

            case .createScene(let pageID, let scene):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard findScene(scene.id, in: next) == nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "scene \(scene.id.uuidString) already exists"))
                    continue
                }
                guard isUsableScene(scene),
                      referencesExist(scene, on: next.pages[pageIndex]) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: "scene focus lists must reference nodes and "
                            + "regions on page \(pageID.uuidString)"))
                    continue
                }
                next.pages[pageIndex].scenes.append(scene)
                changedPages.insert(pageID)

            case .updateScene(let scene):
                guard let (pageIndex, sceneIndex) = findScene(
                    scene.id, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .sceneMissing))
                    continue
                }
                guard isUsableScene(scene),
                      referencesExist(scene, on: next.pages[pageIndex]) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidReference,
                        detail: "scene focus lists must reference nodes and "
                            + "regions on the scene's page"))
                    continue
                }
                next.pages[pageIndex].scenes[sceneIndex] = scene
                changedPages.insert(next.pages[pageIndex].id)

            case .removeScene(let sceneID):
                guard let (pageIndex, sceneIndex) = findScene(
                    sceneID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .sceneMissing))
                    continue
                }
                next.pages[pageIndex].scenes.remove(at: sceneIndex)
                changedPages.insert(next.pages[pageIndex].id)

            case .addStroke(let pageID, let stroke):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard findStroke(stroke.id, in: next) == nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "stroke \(stroke.id.uuidString) already exists"))
                    continue
                }
                guard isUsableStroke(stroke) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        detail: "stroke points must be finite and width "
                            + "finite and positive"))
                    continue
                }
                next.pages[pageIndex].strokes.append(stroke)
                changedPages.insert(pageID)

            case .updateStroke(let stroke):
                guard let (pageIndex, strokeIndex) = findStroke(
                    stroke.id, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .strokeMissing))
                    continue
                }
                guard isUsableStroke(stroke) else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        detail: "stroke points must be finite and width "
                            + "finite and positive"))
                    continue
                }
                next.pages[pageIndex].strokes[strokeIndex] = stroke
                changedPages.insert(next.pages[pageIndex].id)

            case .removeStroke(let strokeID):
                guard let (pageIndex, strokeIndex) = findStroke(
                    strokeID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .strokeMissing))
                    continue
                }
                next.pages[pageIndex].strokes.remove(at: strokeIndex)
                changedPages.insert(next.pages[pageIndex].id)

            case .editPage(let nestedBatch):
                guard case .wholeDocument = nestedBatch.scope else {
                    violations.append(.init(
                        operationIndex: index, reason: .scopeEscalation,
                        detail: "editPage requires the nested batch to "
                            + "declare wholeDocument scope; a document "
                            + "transaction cannot widen the host trust"))
                    continue
                }
                // Nested violations (scope/locks/dangling) abort the WHOLE
                // document batch: the input snapshot is never partially
                // modified.
                let result = try CanvasEditEngine.apply(nestedBatch, to: next)
                next = result.snapshot
                changedPages.insert(nestedBatch.pageID)
                changedNodes.formUnion(result.changedNodeIDs)

            case .updateNodeSource(let nodeID, let source):
                guard let (pageIndex, nodeIndex) = editableNode(
                    nodeID, in: next, operationIndex: index,
                    violations: &violations) else { continue }
                next.pages[pageIndex].nodes[nodeIndex].source = source
                changedNodes.insert(nodeID)
                changedPages.insert(next.pages[pageIndex].id)

            case .updateNodeRotation(let nodeID, let rotationDegrees):
                guard rotationDegrees.isFinite else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        nodeID: nodeID,
                        detail: "rotation must be finite"))
                    continue
                }
                guard let (pageIndex, nodeIndex) = editableNode(
                    nodeID, in: next, operationIndex: index,
                    violations: &violations) else { continue }
                next.pages[pageIndex].nodes[nodeIndex].rotationDegrees =
                    rotationDegrees
                changedNodes.insert(nodeID)
                changedPages.insert(next.pages[pageIndex].id)

            case .updateNodeStyle(let nodeID, let zIndex):
                guard let (pageIndex, nodeIndex) = editableNode(
                    nodeID, in: next, operationIndex: index,
                    violations: &violations) else { continue }
                next.pages[pageIndex].nodes[nodeIndex].zIndex = zIndex
                changedNodes.insert(nodeID)
                changedPages.insert(next.pages[pageIndex].id)

            case .updateNodeMetadata(let nodeID, let values, let removingKeys):
                guard let (pageIndex, nodeIndex) = editableNode(
                    nodeID, in: next, operationIndex: index,
                    violations: &violations) else { continue }
                var metadata = next.pages[pageIndex].nodes[nodeIndex].metadata
                for key in removingKeys {
                    metadata[key] = nil
                }
                var invalidKeys: [String] = []
                for (key, value) in values {
                    if CanvasVisualMetadataKeys.isVisualKey(key),
                       !CanvasVisualMetadataKeys.isValid(
                        value: value, forKey: key) {
                        invalidKeys.append(key)
                    }
                    if CanvasFlowCardBindingKey.isBindingKey(key),
                       UUID(uuidString: value) == nil {
                        invalidKeys.append(key)
                    }
                    metadata[key] = value
                }
                guard invalidKeys.isEmpty else {
                    violations.append(.init(
                        operationIndex: index, reason: .invalidGeometry,
                        nodeID: nodeID,
                        detail: "invalid metadata values for keys: "
                            + invalidKeys.sorted().joined(separator: ", ")))
                    continue
                }
                next.pages[pageIndex].nodes[nodeIndex].metadata = metadata
                changedNodes.insert(nodeID)
                changedPages.insert(next.pages[pageIndex].id)

            case .insertFlowGraph(let pageID, let graph):
                guard let pageIndex = pageIndex(of: pageID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .pageMissing))
                    continue
                }
                guard findGraph(graph.id, in: next) == nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        detail: "flow graph \(graph.id.uuidString) already exists"))
                    continue
                }
                let checked = try validatedGraph(graph)
                validateFlowSourceBindings(
                    checked, in: next, operationIndex: index,
                    violations: &violations)
                next.pages[pageIndex].flowGraphs.append(checked)
                changedPages.insert(pageID)
                changedGraphs.insert(checked.id)

            case .replaceFlowGraph(let graph):
                guard let (pageIndex, graphIndex) = findGraph(
                    graph.id, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .flowGraphMissing))
                    continue
                }
                let existing = next.pages[pageIndex].flowGraphs[graphIndex]
                guard graph.revision > existing.revision else {
                    violations.append(.init(
                        operationIndex: index, reason: .staleFlowGraphRevision,
                        detail: "graph revision must increase on definition "
                            + "changes (current \(existing.revision), received "
                            + "\(graph.revision))"))
                    continue
                }
                let checked = try validatedGraph(graph)
                validateFlowSourceBindings(
                    checked, in: next, operationIndex: index,
                    violations: &violations)
                // Replacing a definition must not bypass a locked flow card
                // bound to this graph: the locked card's presented node set
                // cannot be changed from under it.
                for page in next.pages {
                    for card in page.nodes
                    where card.isLocked
                        && CanvasFlowCardBinding(metadata: card.metadata)?
                            .graphID == graph.id {
                        violations.append(.init(
                            operationIndex: index, reason: .nodeLocked,
                            nodeID: card.id,
                            detail: "flow graph \(graph.id.uuidString) is "
                                + "bound to a locked card; unlock the card "
                                + "before replacing the definition"))
                    }
                }
                next.pages[pageIndex].flowGraphs[graphIndex] = checked
                changedPages.insert(next.pages[pageIndex].id)
                changedGraphs.insert(graph.id)

            case .removeFlowGraph(let graphID):
                guard let (pageIndex, graphIndex) = findGraph(
                    graphID, in: next) else {
                    violations.append(.init(
                        operationIndex: index, reason: .flowGraphMissing))
                    continue
                }
                next.pages[pageIndex].flowGraphs.remove(at: graphIndex)
                changedPages.insert(next.pages[pageIndex].id)
                changedGraphs.insert(graphID)
            }
        }

        // Final-state flow-card binding validation (covers card+graph
        // inserted in the same batch): every binding must resolve to an
        // existing graph and flow node, and no two cards may bind the same
        // (graph, node) pair. Violations reject the commit recoverably;
        // stored legacy documents are never rewritten.
        validateFlowCardBindings(
            in: next,
            operationIndex: max(batch.operations.count - 1, 0),
            violations: &violations)

        guard violations.isEmpty else {
            throw CanvasKitError.editScopeViolations(violations)
        }

        // Keep node order deterministic after zIndex changes, and refresh
        // the derived regionID caches for every touched page: the cache is
        // never save authority, only the last computed containment.
        for pageID in changedPages {
            guard let pageIndex = pageIndex(of: pageID, in: next) else { continue }
            next.pages[pageIndex].nodes.sort { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            recomputeRegionCache(&next.pages[pageIndex])
        }

        return CanvasDocumentEditResult(
            snapshot: next,
            changedPageIDs: changedPages.sorted { $0.uuidString < $1.uuidString },
            changedNodeIDs: changedNodes.sorted { $0.uuidString < $1.uuidString },
            changedFlowGraphIDs: changedGraphs.sorted {
                $0.uuidString < $1.uuidString
            })
    }

    // MARK: - Stored snapshot validation

    /// Duplicate durable IDs in the STORED snapshot would trap dictionary
    /// builds; they are a hard data error, never repaired silently.
    static func validateStoredIDs(_ snapshot: CanvasSnapshot) throws {
        var pageIDs = Set<UUID>()
        for page in snapshot.pages {
            guard pageIDs.insert(page.id).inserted else {
                throw CanvasKitError.invalidSnapshot(
                    "duplicate page ID \(page.id.uuidString)")
            }
            try checkUnique(page.nodes.map(\.id), kind: "node", page: page.id)
            try checkUnique(page.connections.map(\.id), kind: "connection", page: page.id)
            try checkUnique(page.strokes.map(\.id), kind: "stroke", page: page.id)
            try checkUnique(page.groups.map(\.id), kind: "group", page: page.id)
            try checkUnique(page.regions.map(\.id), kind: "region", page: page.id)
            try checkUnique(page.scenes.map(\.id), kind: "scene", page: page.id)
            try checkUnique(page.flowGraphs.map(\.id), kind: "flow graph", page: page.id)
        }
    }

    private static func checkUnique(
        _ ids: [UUID], kind: String, page: UUID
    ) throws {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            throw CanvasKitError.invalidSnapshot(
                "duplicate \(kind) ID \(id.uuidString) on page \(page.uuidString)")
        }
    }

    /// Validates a page being added: internal uniqueness, references,
    /// geometry, flow graphs, visual metadata.
    static func validateNewPage(_ page: CanvasPageSnapshot) throws {
        try checkUnique(page.nodes.map(\.id), kind: "node", page: page.id)
        try checkUnique(page.connections.map(\.id), kind: "connection", page: page.id)
        try checkUnique(page.strokes.map(\.id), kind: "stroke", page: page.id)
        try checkUnique(page.groups.map(\.id), kind: "group", page: page.id)
        try checkUnique(page.regions.map(\.id), kind: "region", page: page.id)
        try checkUnique(page.scenes.map(\.id), kind: "scene", page: page.id)
        try checkUnique(page.flowGraphs.map(\.id), kind: "flow graph", page: page.id)

        let nodeIDs = Set(page.nodes.map(\.id))
        let groupIDs = Set(page.groups.map(\.id))
        let regionIDs = Set(page.regions.map(\.id))
        for connection in page.connections where
            !nodeIDs.contains(connection.sourceNodeID)
            || !nodeIDs.contains(connection.destinationNodeID) {
            throw CanvasKitError.invalidSnapshot(
                "connection \(connection.id.uuidString) dangles on new page "
                    + page.id.uuidString)
        }
        for group in page.groups where
            !Set(group.memberNodeIDs).isSubset(of: nodeIDs) {
            throw CanvasKitError.invalidSnapshot(
                "group \(group.id.uuidString) references nodes outside the new page")
        }
        for node in page.nodes {
            if let groupID = node.groupID, !groupIDs.contains(groupID) {
                throw CanvasKitError.invalidSnapshot(
                    "node \(node.id.uuidString) references missing group \(groupID.uuidString)")
            }
            if let regionID = node.regionID, !regionIDs.contains(regionID) {
                throw CanvasKitError.invalidSnapshot(
                    "node \(node.id.uuidString) references missing region \(regionID.uuidString)")
            }
            guard isUsableFrame(node.frame) else {
                throw CanvasKitError.invalidSnapshot(
                    "node \(node.id.uuidString) has a non-finite or non-positive frame")
            }
            if !visualMetadataValid(node.metadata) {
                throw CanvasKitError.invalidSnapshot(
                    "node \(node.id.uuidString) has invalid visual metadata")
            }
        }
        for region in page.regions where !isUsableFrame(region.frame) {
            throw CanvasKitError.invalidSnapshot(
                "region \(region.id.uuidString) has a non-finite or non-positive frame")
        }
        for scene in page.scenes where !isUsableScene(scene) {
            throw CanvasKitError.invalidSnapshot(
                "scene \(scene.id.uuidString) has invalid viewport values")
        }
        for scene in page.scenes where !referencesExist(scene, on: page) {
            throw CanvasKitError.invalidSnapshot(
                "scene \(scene.id.uuidString) references nodes/regions outside the new page")
        }
        for stroke in page.strokes where !isUsableStroke(stroke) {
            throw CanvasKitError.invalidSnapshot(
                "stroke \(stroke.id.uuidString) has non-finite points or width")
        }
        if let data = page.pencilDrawingData,
           data.count > CanvasPageSnapshot.maxPencilDrawingByteCount {
            throw CanvasKitError.invalidSnapshot(
                "page pencil drawing exceeds "
                    + "\(CanvasPageSnapshot.maxPencilDrawingByteCount) bytes")
        }
        for graph in page.flowGraphs {
            _ = try validatedGraph(graph)
        }
    }

    /// Nodes whose center lies inside the region's frame, on the region's
    /// page. Geometric containment is the ONLY authority for "region
    /// contents"; the regionID cache may be stale or nil (e.g. after moves)
    /// and is recomputed, never trusted.
    static func nodeIDsContainedByRegion(
        _ regionID: UUID, in snapshot: CanvasSnapshot
    ) -> [UUID] {
        guard let (pageIndex, regionIndex) = findRegion(
            regionID, in: snapshot) else { return [] }
        let frame = snapshot.pages[pageIndex].regions[regionIndex].frame
        return snapshot.pages[pageIndex].nodes
            .filter { isInsideRegion(frame, point: $0.frame.center) }
            .map(\.id)
    }

    static func isInsideRegion(
        _ frame: CanvasGeometry.Frame, point: CanvasGeometry.Point
    ) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }

    /// Recomputes the derived regionID cache for every node: the INNERMOST
    /// region (smallest containing frame; ties break on the smaller ID)
    /// whose frame contains the node center, or nil outside all regions.
    static func recomputeRegionCache(_ page: inout CanvasPageSnapshot) {
        let regions = page.regions
        for nodeIndex in page.nodes.indices {
            let center = page.nodes[nodeIndex].frame.center
            let containing = regions
                .filter { isInsideRegion($0.frame, point: center) }
                .sorted { lhs, rhs in
                    let lhsArea = lhs.frame.size.width * lhs.frame.size.height
                    let rhsArea = rhs.frame.size.width * rhs.frame.size.height
                    if lhsArea != rhsArea { return lhsArea < rhsArea }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            page.nodes[nodeIndex].regionID = containing.first?.id
        }
    }

    // MARK: - Geometry / style validation

    static func isUsableFrame(_ frame: CanvasGeometry.Frame) -> Bool {
        frame.center.x.isFinite && frame.center.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }

    static func isUsableScene(_ scene: CanvasSceneRecord) -> Bool {
        scene.viewportCenter.x.isFinite && scene.viewportCenter.y.isFinite
            && scene.viewportScale.isFinite && scene.viewportScale > 0
    }

    static func isUsableStroke(_ stroke: CanvasStrokeSnapshot) -> Bool {
        !stroke.points.isEmpty
            && stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && stroke.width.isFinite && stroke.width > 0
    }

    static func visualMetadataValid(_ metadata: [String: String]) -> Bool {
        CanvasVisualStyle(metadata: metadata)?.isValid ?? true
    }

    static func referencesExist(
        _ scene: CanvasSceneRecord, on page: CanvasPageSnapshot
    ) -> Bool {
        let nodeIDs = Set(page.nodes.map(\.id))
        let regionIDs = Set(page.regions.map(\.id))
        return scene.focusedNodeIDs.allSatisfy { nodeIDs.contains($0) }
            && scene.focusedRegionIDs.allSatisfy { regionIDs.contains($0) }
    }

    /// Final-state validation of flow-card bindings: every bound card's
    /// (graph, flow node) locator must resolve, and no two cards may bind
    /// the same pair. Runs after all operations so card+graph inserted in
    /// one batch validate against the batch's final state.
    static func validateFlowCardBindings(
        in snapshot: CanvasSnapshot,
        operationIndex: Int,
        violations: inout [CanvasEditViolation]
    ) {
        var seen = Set<CanvasFlowCardBinding>()
        for page in snapshot.pages {
            for node in page.nodes {
                guard let binding = CanvasFlowCardBinding(
                    metadata: node.metadata) else { continue }
                if !seen.insert(binding).inserted {
                    violations.append(.init(
                        operationIndex: operationIndex, reason: .duplicateID,
                        nodeID: node.id,
                        detail: "duplicate flow card binding "
                            + "\(binding.graphID.uuidString) / "
                            + "\(binding.nodeID.uuidString)"))
                }
                guard let (graphPage, graphIndex) = findGraph(
                    binding.graphID, in: snapshot) else {
                    violations.append(.init(
                        operationIndex: operationIndex, reason: .invalidReference,
                        nodeID: node.id,
                        detail: "flow card binding references missing graph "
                            + "\(binding.graphID.uuidString)"))
                    continue
                }
                guard snapshot.pages[graphPage].flowGraphs[graphIndex].nodes
                    .contains(where: { $0.id == binding.nodeID }) else {
                    violations.append(.init(
                        operationIndex: operationIndex, reason: .invalidReference,
                        nodeID: node.id,
                        detail: "flow card binding references missing flow "
                            + "node \(binding.nodeID.uuidString)"))
                    continue
                }
            }
        }
    }

    // MARK: - Flow graph validation

    static func validatedGraph(_ graph: FlowGraph) throws -> FlowGraph {
        // Persistence validates structure, not a particular host's run
        // policy. The runtime/compiler still defaults to 100 and applies
        // the explicitly supplied run limit before scheduling anything.
        let errors = FlowGraphValidator.validate(graph, maxLoopIterations: Int.max)
            .filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw CanvasKitError.invalidFlowGraph(errors)
        }
        return graph
    }

    /// Source cards feed flows through typed input-source nodes whose
    /// parameters locate canvas content (locator only — never permission).
    /// When the locator points at THIS canvas, the page/node must exist.
    static func validateFlowSourceBindings(
        _ graph: FlowGraph,
        in snapshot: CanvasSnapshot,
        operationIndex: Int,
        violations: inout [CanvasEditViolation]
    ) {
        for node in graph.nodes where node.kind == .source {
            guard let nodeIDLiteral = node.parameters[
                CanvasFlowSourceParameterKey.nodeID]?.stringValue,
                let boundNodeID = UUID(uuidString: nodeIDLiteral) else {
                continue
            }
            if let usedRevision = node.parameters[
                CanvasFlowSourceParameterKey.usedRevision]?.numberLiteral,
               Int64(usedRevision) == nil {
                violations.append(.init(
                    operationIndex: operationIndex, reason: .invalidReference,
                    detail: "flow source \(node.id.uuidString) has a "
                        + "non-integer usedRevision"))
            }
            guard let canvasLiteral = node.parameters[
                CanvasFlowSourceParameterKey.canvasID]?.stringValue,
                UUID(uuidString: canvasLiteral) == snapshot.id else {
                continue // external canvas locator; not validated here
            }
            guard let pageLiteral = node.parameters[
                CanvasFlowSourceParameterKey.pageID]?.stringValue,
                let boundPageID = UUID(uuidString: pageLiteral),
                let page = snapshot.pages.first(where: {
                    $0.id == boundPageID
                }) else {
                violations.append(.init(
                    operationIndex: operationIndex, reason: .invalidReference,
                    detail: "flow source \(node.id.uuidString) references "
                        + "missing page"))
                continue
            }
            guard page.nodes.contains(where: { $0.id == boundNodeID }) else {
                violations.append(.init(
                    operationIndex: operationIndex, reason: .invalidReference,
                    detail: "flow source \(node.id.uuidString) references "
                        + "missing node \(boundNodeID.uuidString)"))
                continue
            }
        }
    }

    // MARK: - Lookups

    static func pageIndex(
        of pageID: UUID, in snapshot: CanvasSnapshot
    ) -> Int? {
        snapshot.pages.firstIndex(where: { $0.id == pageID })
    }

    static func nodeIndex(
        _ nodeID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, node: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let nodeIndex = page.nodes.firstIndex(where: {
                $0.id == nodeID
            }) {
                return (pageIndex, nodeIndex)
            }
        }
        return nil
    }

    static func node(
        _ nodeID: UUID, in snapshot: CanvasSnapshot
    ) -> CanvasNodeSnapshot? {
        guard let location = nodeIndex(nodeID, in: snapshot) else { return nil }
        return snapshot.pages[location.page].nodes[location.node]
    }

    /// Node must exist and be unlocked; appends the right violation and
    /// returns nil otherwise.
    static func editableNode(
        _ nodeID: UUID,
        in snapshot: CanvasSnapshot,
        operationIndex: Int,
        violations: inout [CanvasEditViolation]
    ) -> (page: Int, node: Int)? {
        guard let location = nodeIndex(nodeID, in: snapshot) else {
            violations.append(.init(
                operationIndex: operationIndex, reason: .nodeMissing,
                nodeID: nodeID))
            return nil
        }
        if snapshot.pages[location.page].nodes[location.node].isLocked {
            violations.append(.init(
                operationIndex: operationIndex, reason: .nodeLocked,
                nodeID: nodeID))
            return nil
        }
        return location
    }

    static func findGroup(
        _ groupID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, group: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let groupIndex = page.groups.firstIndex(where: {
                $0.id == groupID
            }) {
                return (pageIndex, groupIndex)
            }
        }
        return nil
    }

    static func findRegion(
        _ regionID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, region: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let regionIndex = page.regions.firstIndex(where: {
                $0.id == regionID
            }) {
                return (pageIndex, regionIndex)
            }
        }
        return nil
    }

    static func findScene(
        _ sceneID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, scene: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let sceneIndex = page.scenes.firstIndex(where: {
                $0.id == sceneID
            }) {
                return (pageIndex, sceneIndex)
            }
        }
        return nil
    }

    static func findStroke(
        _ strokeID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, stroke: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let strokeIndex = page.strokes.firstIndex(where: {
                $0.id == strokeID
            }) {
                return (pageIndex, strokeIndex)
            }
        }
        return nil
    }

    static func findGraph(
        _ graphID: UUID, in snapshot: CanvasSnapshot
    ) -> (page: Int, graph: Int)? {
        for (pageIndex, page) in snapshot.pages.enumerated() {
            if let graphIndex = page.flowGraphs.firstIndex(where: {
                $0.id == graphID
            }) {
                return (pageIndex, graphIndex)
            }
        }
        return nil
    }

    /// Removes a node plus every reference to it (connections, group
    /// memberships, scene focus lists). Caller performs lock checks.
    static func removeNodeCompletely(
        _ snapshot: inout CanvasSnapshot,
        _ nodeID: UUID
    ) {
        guard let (pageIndex, nodeIndex) = nodeIndex(nodeID, in: snapshot)
        else { return }
        snapshot.pages[pageIndex].nodes.remove(at: nodeIndex)
        snapshot.pages[pageIndex].connections.removeAll {
            $0.sourceNodeID == nodeID || $0.destinationNodeID == nodeID
        }
        for groupIndex in snapshot.pages[pageIndex].groups.indices {
            snapshot.pages[pageIndex].groups[groupIndex].memberNodeIDs
                .removeAll { $0 == nodeID }
        }
        for sceneIndex in snapshot.pages[pageIndex].scenes.indices {
            snapshot.pages[pageIndex].scenes[sceneIndex].focusedNodeIDs
                .removeAll { $0 == nodeID }
        }
    }
}
