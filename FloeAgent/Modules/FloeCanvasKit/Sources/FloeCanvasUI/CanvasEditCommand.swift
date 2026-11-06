import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

/// One user-level editing intent. The store translates each intent into
/// exactly one `CanvasDocumentBatch` — one gesture, one commit, one undo
/// unit (UI_BRIEF). Interactive gestures (text/Pencil) bypass commands and
/// commit their completed gesture directly.
public enum CanvasEditCommand: Sendable {
    // Insertion (positions are world coordinates on the current page)
    case insertNode(CanvasNodeSnapshot)
    case insertContent(CanvasContent, title: String?, at: CanvasGeometry.Point)
    case insertShape(CanvasShapeKind, text: String, at: CanvasGeometry.Point)

    // Node edits
    case moveNodes([(UUID, CanvasGeometry.Point)])
    case resizeNode(UUID, CanvasGeometry.Size)
    case updateContent(UUID, CanvasContent)
    case updateTitle(UUID, String?)
    case deleteSelection
    case duplicateSelection
    case setLocked(Set<UUID>, Bool)
    case updateNodeMetadata(UUID, values: [String: String], removingKeys: [String])
    case updateNodeRotation(UUID, Double)
    case updateNodeSource(UUID, CanvasSourceReference?)

    // Ordinary relations (never execution)
    case connect(UUID, UUID, kind: CanvasRelationKind, label: String?)
    case removeConnection(UUID)

    // Organization (group ≠ region ≠ scene, per the brief)
    case groupSelection
    case ungroupSelection
    case createRegionForSelection(name: String?)
    case updateRegion(CanvasRegionRecord)
    case setRegionCollapsed(UUID, Bool)
    case removeRegion(UUID, deleteContents: Bool)
    case createScene(name: String)
    case updateScene(CanvasSceneRecord)
    case removeScene(UUID)

    // Flow (typed execution lives in FlowGraph, visuals in bound cards)
    case insertFlowStep(kind: FlowNodeKind, name: String, at: CanvasGeometry.Point)
    case connectFlowPorts(
        sourceNodeID: UUID, sourcePortID: UUID,
        destinationNodeID: UUID, destinationPortID: UUID)
    case updateFlowNode(FlowNode)
    case deleteFlowCard(UUID)
    case duplicateFlowCard(UUID)

    // Freehand strokes (derived view; Pencil bytes use setPencilDrawingData)
    case addStroke(CanvasStrokeSnapshot)
    case updateStroke(CanvasStrokeSnapshot)
    case removeStroke(UUID)

    // Pages
    case createPage(name: String, select: Bool)
    case renamePage(UUID, String)
    case deletePage(UUID)
}

/// Pure translator from intents to validated document batches.
public enum CanvasCommandBatchBuilder {
    public static func makeBatch(
        _ command: CanvasEditCommand,
        in snapshot: CanvasSnapshot,
        pageID: UUID,
        selection: Set<UUID>,
        configuration: CanvasEditorConfiguration
    ) throws -> CanvasDocumentBatch {
        switch command {
        case .insertNode(let node):
            return pageBatch(pageID, [
                .insertNode(node)
            ])

        case .insertContent(let content, let title, let at):
            let node = CanvasNodeSnapshot(
                title: title,
                content: content,
                frame: .init(
                    center: at,
                    size: defaultSize(for: content, configuration: configuration)))
            return pageBatch(pageID, [.insertNode(node)])

        case .insertShape(let kind, let text, let at):
            let node = CanvasNodeSnapshot(
                content: .shape(kind: kind, text: text),
                frame: .init(center: at, size: configuration.defaultNodeSize))
            return pageBatch(pageID, [.insertNode(node)])

        case .moveNodes(let moves):
            return pageBatch(pageID, moves.map { .move(nodeID: $0.0, center: $0.1) })

        case .resizeNode(let nodeID, let size):
            return pageBatch(pageID, [.resize(nodeID: nodeID, size: size)])

        case .updateContent(let nodeID, let content):
            let edit = CanvasEditOperation.updateContent(nodeID: nodeID, content: content)
            guard let node = snapshot.pages.first(where: { $0.id == pageID })?.nodes.first(where: { $0.id == nodeID }),
                  let source = node.source, node.content != content else { return pageBatch(pageID, [edit]) }
            let (next, overflow) = source.usedRevision.addingReportingOverflow(1)
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .editPage(.init(pageID: pageID, scope: .wholeDocument, operations: [edit])),
                .updateNodeMetadata(nodeID: nodeID,
                    values: [CanvasSourceRefresher.manualEditRevisionMetadataKey: String(overflow ? Int64.max : next)], removingKeys: [])
            ])

        case .updateTitle(let nodeID, let title):
            return pageBatch(pageID, [.updateTitle(nodeID: nodeID, title: title)])

        case .deleteSelection:
            let selected = selection.intersection(Set((snapshot.pages.first(where: { $0.id == pageID })?.nodes ?? []).map(\.id)))
            return try CanvasFlowGraphEditing.deleteNodesBatch(
                snapshot: snapshot, pageID: pageID, nodeIDs: selected)

        case .duplicateSelection:
            let selected = selection.live(on: snapshot.pages.first(where: { $0.id == pageID }))
            return try CanvasSelectionDuplicator.plan(
                snapshot: snapshot, pageID: pageID, nodeIDs: selected).batch

        case .setLocked(let ids, let locked):
            // Lock changes are whole-document ownership gestures.
            return pageBatch(pageID, ids.sorted(by: { $0.uuidString < $1.uuidString })
                .map { .setLocked(nodeID: $0, isLocked: locked) })

        case .updateNodeMetadata(let nodeID, let values, let removingKeys):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateNodeMetadata(
                    nodeID: nodeID, values: values, removingKeys: removingKeys)
            ])

        case .updateNodeRotation(let nodeID, let degrees):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateNodeRotation(nodeID: nodeID, rotationDegrees: degrees)
            ])

        case .updateNodeSource(let nodeID, let source):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateNodeSource(nodeID: nodeID, source: source)
            ])

        case .connect(let source, let destination, let kind, let label):
            return pageBatch(pageID, [
                .insertConnection(.init(
                    sourceNodeID: source,
                    destinationNodeID: destination,
                    kind: kind,
                    label: label))
            ])

        case .removeConnection(let connectionID):
            return pageBatch(pageID, [.removeConnection(connectionID: connectionID)])

        case .groupSelection:
            let selected = selection.intersection(Set((snapshot.pages.first(where: { $0.id == pageID })?.nodes ?? []).map(\.id)))
            guard !selected.isEmpty else { return emptyBatch() }
            let group = CanvasGroupRecord(
                name: "Group",
                memberNodeIDs: selected.sorted { $0.uuidString < $1.uuidString })
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .createGroup(pageID: pageID, group: group)
            ])

        case .ungroupSelection:
            // Dissolve every group intersecting the selection, keeping content.
            guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
                return emptyBatch()
            }
            let selected = selection.intersection(Set((snapshot.pages.first(where: { $0.id == pageID })?.nodes ?? []).map(\.id)))
            let groups = page.groups.filter { group in
                !Set(group.memberNodeIDs).isDisjoint(with: selected)
            }
            guard !groups.isEmpty else { return emptyBatch() }
            return CanvasDocumentBatch(scope: .wholeDocument, operations:
                groups.map { .removeGroup(groupID: $0.id, deleteMembers: false) }
            )

        case .createRegionForSelection(let name):
            let selected = selection.intersection(Set((snapshot.pages.first(where: { $0.id == pageID })?.nodes ?? []).map(\.id)))
            guard !selected.isEmpty,
                  let page = snapshot.pages.first(where: { $0.id == pageID }) else {
                return emptyBatch()
            }
            let nodes = page.nodes.filter { selected.contains($0.id) }
            let minX = nodes.map(\.frame.minX).min() ?? 0
            let minY = nodes.map(\.frame.minY).min() ?? 0
            let maxX = nodes.map(\.frame.maxX).max() ?? 0
            let maxY = nodes.map(\.frame.maxY).max() ?? 0
            let padded = 24.0
            let region = CanvasRegionRecord(
                name: name ?? "Region",
                frame: .init(
                    center: .init(
                        x: (minX + maxX) / 2,
                        y: (minY + maxY) / 2),
                    size: .init(
                        width: max(80, maxX - minX + padded * 2),
                        height: max(60, maxY - minY + padded * 2))),
                isCollapsed: false)
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .createRegion(pageID: pageID, region: region)
            ])

        case .updateRegion(let region):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateRegion(region)
            ])

        case .setRegionCollapsed(let regionID, let collapsed):
            return pageBatch(pageID, [
                .setRegionCollapsed(regionID: regionID, isCollapsed: collapsed)
            ])

        case .removeRegion(let regionID, let deleteContents):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .removeRegion(regionID: regionID, deleteContents: deleteContents)
            ])

        case .createScene(let name):
            guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
                return emptyBatch()
            }
            let order = (page.scenes.map(\.order).max() ?? -1) + 1
            let scene = CanvasSceneRecord(
                name: name,
                viewportCenter: page.nodes.first?.frame.center ?? .zero,
                viewportScale: 1,
                order: order)
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .createScene(pageID: pageID, scene: scene)
            ])

        case .updateScene(let scene):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateScene(scene)
            ])

        case .removeScene(let sceneID):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .removeScene(sceneID: sceneID)
            ])

        case .insertFlowStep(let kind, let name, let at):
            return try CanvasFlowGraphEditing.insertStepBatch(
                snapshot: snapshot,
                pageID: pageID,
                kind: kind,
                name: name,
                at: at,
                cardSize: configuration.defaultNodeSize)

        case .connectFlowPorts(let sourceNodeID, let sourcePortID,
                               let destinationNodeID, let destinationPortID):
            return try CanvasFlowGraphEditing.connectPortsBatch(
                snapshot: snapshot,
                pageID: pageID,
                sourceNodeID: sourceNodeID,
                sourcePortID: sourcePortID,
                destinationNodeID: destinationNodeID,
                destinationPortID: destinationPortID)

        case .updateFlowNode(let node):
            return try CanvasFlowGraphEditing.updateNodeBatch(
                snapshot: snapshot, pageID: pageID, node: node)

        case .deleteFlowCard(let cardNodeID):
            return try CanvasFlowGraphEditing.deleteFlowCardBatch(
                snapshot: snapshot, pageID: pageID, cardNodeID: cardNodeID)

        case .duplicateFlowCard(let cardNodeID):
            return try CanvasSelectionDuplicator.plan(
                snapshot: snapshot, pageID: pageID, nodeIDs: [cardNodeID]).batch

        case .addStroke(let stroke):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .addStroke(pageID: pageID, stroke: stroke)
            ])

        case .updateStroke(let stroke):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .updateStroke(stroke)
            ])

        case .removeStroke(let strokeID):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .removeStroke(strokeID: strokeID)
            ])

        case .createPage(let name, let select):
            let page = CanvasPageSnapshot(name: name)
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .createPage(page, select: select)
            ])

        case .renamePage(let pageID, let name):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .renamePage(pageID: pageID, name: name)
            ])

        case .deletePage(let pageID):
            return CanvasDocumentBatch(scope: .wholeDocument, operations: [
                .deletePage(pageID: pageID)
            ])
        }
    }

    static func pageBatch(
        _ pageID: UUID,
        _ operations: [CanvasEditOperation]
    ) -> CanvasDocumentBatch {
        CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .editPage(.init(pageID: pageID, scope: .wholeDocument, operations: operations))
        ])
    }

    static func emptyBatch() -> CanvasDocumentBatch {
        CanvasDocumentBatch(scope: .wholeDocument, operations: [])
    }

    static func defaultSize(
        for content: CanvasContent,
        configuration: CanvasEditorConfiguration
    ) -> CanvasGeometry.Size {
        switch content {
        case .table:
            return .init(width: 420, height: 240)
        case .code:
            return .init(width: 380, height: 220)
        case .formula:
            return .init(width: 320, height: 120)
        default:
            return configuration.defaultNodeSize
        }
    }
}

public extension CanvasEditCommand {
    /// Short label for the undo history entry of this gesture.
    var undoLabel: String {
        switch self {
        case .insertNode, .insertContent, .insertShape: return "Insert"
        case .moveNodes: return "Move"
        case .resizeNode: return "Resize"
        case .updateContent: return "Edit content"
        case .updateTitle: return "Rename"
        case .deleteSelection: return "Delete"
        case .duplicateSelection, .duplicateFlowCard: return "Duplicate"
        case .setLocked: return "Lock"
        case .updateNodeMetadata, .updateNodeRotation, .updateNodeSource: return "Edit node"
        case .connect, .removeConnection: return "Connect"
        case .groupSelection: return "Group"
        case .ungroupSelection: return "Ungroup"
        case .createRegionForSelection, .updateRegion, .removeRegion: return "Region"
        case .setRegionCollapsed: return "Collapse"
        case .createScene, .updateScene, .removeScene: return "Scene"
        case .insertFlowStep: return "Insert flow step"
        case .connectFlowPorts: return "Connect ports"
        case .updateFlowNode: return "Edit flow node"
        case .deleteFlowCard: return "Delete flow step"
        case .addStroke, .updateStroke, .removeStroke: return "Stroke"
        case .createPage: return "New page"
        case .renamePage: return "Rename page"
        case .deletePage: return "Delete page"
        }
    }
}

public extension Set where Element == UUID {
    /// IDs from this set that still exist on the given page.
    func live(on page: CanvasPageSnapshot?) -> Set<UUID> {
        guard let page else { return [] }
        let liveIDs = Set(page.nodes.map(\.id))
        return intersection(liveIDs)
    }
}
