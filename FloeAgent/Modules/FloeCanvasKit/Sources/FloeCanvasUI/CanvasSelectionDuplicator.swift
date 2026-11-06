import Foundation
import FloeCanvasCore

/// Selection duplication with correct identity remapping for the copied
/// SUBSET only.
///
/// Scope note (coordinator guidance, 2026-11-03): Core's
/// `CanvasIdentityMapper.copyFlow` whole-graph remap has known gaps (declared
/// ports, branch output ports, body/variable/operand references). Root owns
/// the Core fix. This duplicator does NOT paper over that: it is a different,
/// subset-scoped operation that remaps exactly what it copies. It never
/// copies an active run (`createdByRunID` is cleared on every copy).
public enum CanvasSelectionDuplicator {
    public struct Plan: Sendable {
        /// One committed batch: graph updates first, then card insertions.
        public var batch: CanvasDocumentBatch
        /// New canvas node IDs in deterministic (sorted-source) order.
        public var newNodeIDs: [UUID]
        /// Old flow node ID → new flow node ID for every duplicated step.
        public var flowIDMapping: [UUID: UUID]

        public init(
            batch: CanvasDocumentBatch,
            newNodeIDs: [UUID],
            flowIDMapping: [UUID: UUID]
        ) {
            self.batch = batch
            self.newNodeIDs = newNodeIDs
            self.flowIDMapping = flowIDMapping
        }
    }

    public static func plan(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        nodeIDs: Set<UUID>,
        offset: CanvasGeometry.Point = .init(x: 48, y: 48)
    ) throws -> Plan {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        let liveIDs = Set(page.nodes.map(\.id)).intersection(nodeIDs)
        guard !liveIDs.isEmpty else {
            return Plan(batch: CanvasDocumentBatch(
                scope: .wholeDocument, operations: []), newNodeIDs: [], flowIDMapping: [:])
        }

        var operations: [CanvasDocumentOperation] = []
        var flowIDMapping: [UUID: UUID] = [:]

        // MARK: Flow subset duplication
        // Every bound card in the selection forces duplication of its flow
        // node — otherwise the copy would re-bind to the original node and
        // the engine would reject the duplicate (graph, node) binding.
        var graphEdits: [UUID: FlowGraph] = [:]
        for graph in page.flowGraphs.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let boundCards = page.nodes.filter { node in
                guard let binding = CanvasFlowCardBinding(metadata: node.metadata) else {
                    return false
                }
                return binding.graphID == graph.id && liveIDs.contains(node.id)
            }
            guard !boundCards.isEmpty else { continue }
            var edited = graph

            struct FlowCopy {
                var newNodeID: UUID
                var portMap: [UUID: UUID]
                var node: FlowNode
            }
            var copies: [UUID: FlowCopy] = [:]
            for card in boundCards.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard let binding = CanvasFlowCardBinding(metadata: card.metadata),
                      let source = graph.nodes.first(where: { $0.id == binding.nodeID }) else {
                    continue
                }
                var copy = source
                let newNodeID = UUID()
                var portMap: [UUID: UUID] = [:]
                var newPorts: [FlowPort] = []
                for port in source.ports {
                    var newPort = port
                    let newPortID = UUID()
                    portMap[port.id] = newPortID
                    newPort.id = newPortID
                    newPorts.append(newPort)
                }
                copy.id = newNodeID
                copy.ports = newPorts
                if let branches = source.branches {
                    copy.branches = branches.map { branch in
                        var newBranch = branch
                        newBranch.outputPortID = portMap[branch.outputPortID]
                            ?? branch.outputPortID
                        return newBranch
                    }
                }
                if let body = source.bodyNodeIDs {
                    copy.bodyNodeIDs = body.map { bodyID in
                        copies[bodyID]?.newNodeID ?? bodyID
                    }
                }
                copy.position = .init(
                    x: source.position.x + offset.x,
                    y: source.position.y + offset.y)
                copies[source.id] = FlowCopy(
                    newNodeID: newNodeID, portMap: portMap, node: copy)
                flowIDMapping[source.id] = newNodeID
            }
            guard !copies.isEmpty else { continue }

            let copiedFlowIDs = Set(copies.keys)
            edited.nodes.append(contentsOf: copies.values.map(\.node))
            for edge in graph.edges
            where copiedFlowIDs.contains(edge.sourceNodeID)
                && copiedFlowIDs.contains(edge.destinationNodeID) {
                guard let source = copies[edge.sourceNodeID],
                      let destination = copies[edge.destinationNodeID],
                      let newSourcePort = source.portMap[edge.sourcePortID],
                      let newDestinationPort = destination.portMap[edge.destinationPortID] else {
                    continue
                }
                edited.edges.append(FlowEdge(
                    sourceNodeID: source.newNodeID,
                    sourcePortID: newSourcePort,
                    destinationNodeID: destination.newNodeID,
                    destinationPortID: newDestinationPort))
            }
            for variable in graph.variables
            where copiedFlowIDs.contains(variable.ownerNodeID) {
                edited.variables.append(FlowVariable(
                    name: variable.name,
                    dataType: variable.dataType,
                    ownerNodeID: copies[variable.ownerNodeID]?.newNodeID
                        ?? variable.ownerNodeID,
                    initial: variable.initial))
            }
            edited.revision += 1
            graphEdits[graph.id] = edited
        }
        for (_, edited) in graphEdits.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            operations.append(.replaceFlowGraph(graph: edited))
        }

        // MARK: Canvas node copies
        var newNodeIDs: [UUID] = []
        var newIDsByOld: [UUID: UUID] = [:]
        func freshCanvasID(_ old: UUID) -> UUID {
            if let existing = newIDsByOld[old] { return existing }
            let id = UUID()
            newIDsByOld[old] = id
            return id
        }
        var pageEdits: [CanvasEditOperation] = []
        for oldID in liveIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let node = page.nodes.first(where: { $0.id == oldID }) else { continue }
            var copy = node
            let newID = freshCanvasID(oldID)
            copy.id = newID
            copy.frame.center = .init(
                x: node.frame.center.x + offset.x,
                y: node.frame.center.y + offset.y)
            copy.createdByRunID = nil
            if let groupID = node.groupID,
               let group = page.groups.first(where: { $0.id == groupID }),
               !Set(group.memberNodeIDs).isSubset(of: liveIDs) {
                copy.groupID = nil
            }
            copy.regionID = nil
            if var binding = CanvasFlowCardBinding(metadata: node.metadata) {
                if let newFlowID = flowIDMapping[binding.nodeID] {
                    binding.nodeID = newFlowID
                    var metadata = copy.metadata
                    binding.applied(to: &metadata)
                    copy.metadata = metadata
                } else if !page.flowGraphs.contains(where: {
                    $0.id == binding.graphID
                        && $0.nodes.contains(where: { $0.id == binding.nodeID })
                }) {
                    // Unresolvable binding on the copy would fail engine
                    // validation; strip it and duplicate as a plain card.
                    var metadata = copy.metadata
                    metadata.removeValue(forKey: CanvasFlowCardBindingKey.graphID)
                    metadata.removeValue(forKey: CanvasFlowCardBindingKey.nodeID)
                    copy.metadata = metadata
                }
            }
            newNodeIDs.append(newID)
            pageEdits.append(.insertNode(copy))
        }

        // Internal ordinary relations between copied nodes keep kind/label.
        for connection in page.connections
        where liveIDs.contains(connection.sourceNodeID)
            && liveIDs.contains(connection.destinationNodeID) {
            pageEdits.append(.insertConnection(.init(
                id: UUID(),
                sourceNodeID: freshCanvasID(connection.sourceNodeID),
                destinationNodeID: freshCanvasID(connection.destinationNodeID),
                kind: connection.kind,
                label: connection.label,
                sourcePort: connection.sourcePort,
                destinationPort: connection.destinationPort)))
        }

        // Groups fully inside the selection are copied; partial groups are
        // dissolved for the copies (copy.groupID was cleared above).
        for group in page.groups
        .sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where !group.memberNodeIDs.isEmpty
            && Set(group.memberNodeIDs).isSubset(of: liveIDs) {
            operations.append(.createGroup(
                pageID: pageID,
                group: CanvasGroupRecord(
                    name: group.name,
                    memberNodeIDs: group.memberNodeIDs.map(freshCanvasID))))
        }

        if !pageEdits.isEmpty {
            operations.append(.editPage(.init(
                pageID: pageID,
                scope: .wholeDocument,
                operations: pageEdits)))
        }
        return Plan(
            batch: CanvasDocumentBatch(scope: .wholeDocument, operations: operations),
            newNodeIDs: newNodeIDs,
            flowIDMapping: flowIDMapping)
    }
}

/// Page-level snapshot diff committed as one nested edit batch. Used by
/// explicit source refresh: the Integration refresher produces a candidate
/// snapshot; the UI commits only the delta (annotations/layout preserved by
/// construction, ICH04).
public enum CanvasSnapshotDocumentDiff {
    public static func difference(
        from base: CanvasSnapshot,
        to target: CanvasSnapshot,
        pageID: UUID
    ) throws -> CanvasDocumentBatch {
        guard let basePage = base.pages.first(where: { $0.id == pageID }),
              let targetPage = target.pages.first(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        var operations: [CanvasEditOperation] = []
        let baseNodes = Dictionary(uniqueKeysWithValues: basePage.nodes.map { ($0.id, $0) })
        let targetNodes = Dictionary(uniqueKeysWithValues: targetPage.nodes.map { ($0.id, $0) })

        for node in targetPage.nodes where baseNodes[node.id] == nil {
            operations.append(.insertNode(node))
        }
        for node in basePage.nodes where targetNodes[node.id] == nil {
            operations.append(.removeNode(nodeID: node.id))
        }
        for node in targetPage.nodes {
            guard let old = baseNodes[node.id], old != node else { continue }
            if old.content != node.content {
                operations.append(.updateContent(nodeID: node.id, content: node.content))
            }
            if old.title != node.title {
                operations.append(.updateTitle(nodeID: node.id, title: node.title))
            }
        }
        for connection in targetPage.connections
        where !basePage.connections.contains(where: { $0.id == connection.id }) {
            operations.append(.insertConnection(connection))
        }
        for connection in basePage.connections
        where !targetPage.connections.contains(where: { $0.id == connection.id }) {
            operations.append(.removeConnection(connectionID: connection.id))
        }
        return CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .editPage(.init(
                pageID: pageID,
                scope: .wholeDocument,
                operations: operations))
        ])
    }
}
