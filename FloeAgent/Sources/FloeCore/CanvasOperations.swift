import Foundation

public struct CanvasContextSnapshot: Sendable, Codable, Hashable {
    public var canvasID: UUID
    public var documentID: UUID
    public var revision: Int64
    public var viewport: CanvasViewportState
    public var selectedNodeIDs: [UUID]
    public var nodes: [CanvasNode]
    public var connections: [CanvasConnection]

    public init(
        canvasID: UUID, documentID: UUID, revision: Int64,
        viewport: CanvasViewportState, selectedNodeIDs: [UUID],
        nodes: [CanvasNode], connections: [CanvasConnection]
    ) {
        self.canvasID = canvasID; self.documentID = documentID
        self.revision = revision; self.viewport = viewport
        self.selectedNodeIDs = selectedNodeIDs; self.nodes = nodes
        self.connections = connections
    }
}

public enum CanvasPatchOperationKind: String, Sendable, Codable, Hashable {
    case create, update, delete, connect, disconnect, group, ungroup, arrange
}

/// Flat, provider-friendly operation. Fields irrelevant to `kind` must be
/// omitted. Validation happens before any mutation so a patch is atomic.
public struct CanvasPatchOperation: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: CanvasPatchOperationKind
    public var nodeID: UUID?
    public var nodeIDs: [UUID]?
    public var nodeKind: CanvasNodeKind?
    public var text: String?
    public var position: CanvasPoint?
    public var size: CanvasSize?
    public var rotation: Double?
    public var isLocked: Bool?
    public var shape: CanvasShapeKind?
    public var asset: CanvasAssetReference?
    public var generationJobID: UUID?
    public var createdByRunID: UUID?
    public var metadata: [String: String]?
    public var sourceNodeID: UUID?
    public var destinationNodeID: UUID?
    public var connectionID: UUID?
    public var connectionKind: CanvasConnectionKind?
    public var sourcePort: CanvasConnectionPort?
    public var destinationPort: CanvasConnectionPort?
    public var label: String?
    public var arrangement: String?

    public init(
        id: UUID = UUID(), kind: CanvasPatchOperationKind,
        nodeID: UUID? = nil, nodeIDs: [UUID]? = nil,
        nodeKind: CanvasNodeKind? = nil, text: String? = nil,
        position: CanvasPoint? = nil, size: CanvasSize? = nil,
        rotation: Double? = nil, isLocked: Bool? = nil,
        shape: CanvasShapeKind? = nil, asset: CanvasAssetReference? = nil,
        generationJobID: UUID? = nil, createdByRunID: UUID? = nil,
        metadata: [String: String]? = nil,
        sourceNodeID: UUID? = nil,
        destinationNodeID: UUID? = nil, connectionID: UUID? = nil,
        connectionKind: CanvasConnectionKind? = nil,
        sourcePort: CanvasConnectionPort? = nil,
        destinationPort: CanvasConnectionPort? = nil,
        label: String? = nil, arrangement: String? = nil
    ) {
        self.id = id; self.kind = kind; self.nodeID = nodeID; self.nodeIDs = nodeIDs
        self.nodeKind = nodeKind; self.text = text; self.position = position
        self.size = size; self.rotation = rotation; self.isLocked = isLocked
        self.shape = shape; self.asset = asset; self.sourceNodeID = sourceNodeID
        self.generationJobID = generationJobID
        self.createdByRunID = createdByRunID; self.metadata = metadata
        self.destinationNodeID = destinationNodeID; self.connectionID = connectionID
        self.connectionKind = connectionKind
        self.sourcePort = sourcePort; self.destinationPort = destinationPort
        self.label = label; self.arrangement = arrangement
    }
}

public struct CanvasPatch: Sendable, Codable, Hashable {
    public var canvasID: UUID
    public var documentID: UUID
    public var expectedRevision: Int64
    public var operations: [CanvasPatchOperation]

    public init(
        canvasID: UUID, documentID: UUID, expectedRevision: Int64,
        operations: [CanvasPatchOperation]
    ) {
        self.canvasID = canvasID; self.documentID = documentID
        self.expectedRevision = expectedRevision; self.operations = operations
    }
}

public struct CanvasOperationDelta: Sendable, Codable, Hashable {
    public var nodes: [CanvasNode]
    public var connections: [CanvasConnection]
    public var removedNodeIDs: [UUID]
    public var removedConnectionIDs: [UUID]
}

public struct CanvasOperationResult: Sendable, Codable, Hashable {
    public var canvasID: UUID
    public var documentID: UUID
    public var previousRevision: Int64
    public var revision: Int64
    public var changedNodeIDs: [UUID]
    public var changedConnectionIDs: [UUID]
    public var undoToken: UUID
    /// Exact committed mutation, not a later inspection that may race another edit.
    public var delta: CanvasOperationDelta?

    public init(
        canvasID: UUID, documentID: UUID, previousRevision: Int64,
        revision: Int64, changedNodeIDs: [UUID],
        changedConnectionIDs: [UUID], undoToken: UUID = UUID(),
        delta: CanvasOperationDelta? = nil
    ) {
        self.canvasID = canvasID; self.documentID = documentID
        self.previousRevision = previousRevision; self.revision = revision
        self.changedNodeIDs = changedNodeIDs
        self.changedConnectionIDs = changedConnectionIDs
        self.undoToken = undoToken
        self.delta = delta
    }
}

/// Deterministic, size-aware layout shared by the canvas UI and canvas agent.
/// Connected nodes are placed by graph depth; nodes in the same layer are
/// stacked without overlap. The result stays anchored to the original bounds
/// so arranging never makes the graph appear to disappear off screen.
public enum CanvasAutoLayout {
    public enum Direction: Sendable {
        case horizontal
        case vertical
    }

    public static func positions(
        nodes: [CanvasNode],
        connections: [CanvasConnection],
        nodeIDs: Set<UUID>,
        direction: Direction = .horizontal,
        layerSpacing: Double = 96,
        itemSpacing: Double = 48
    ) -> [UUID: CanvasPoint] {
        let selected = nodes.filter { nodeIDs.contains($0.id) && !$0.isLocked }
        guard selected.count > 1 else { return [:] }

        let selectedIDs = Set(selected.map(\.id))
        var outgoing: [UUID: [UUID]] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, 0) })
        for connection in connections
        where selectedIDs.contains(connection.sourceNodeID)
            && selectedIDs.contains(connection.destinationNodeID) {
            outgoing[connection.sourceNodeID, default: []].append(connection.destinationNodeID)
            indegree[connection.destinationNodeID, default: 0] += 1
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        let stableOrder: (UUID, UUID) -> Bool = { lhs, rhs in
            guard let left = nodeByID[lhs], let right = nodeByID[rhs] else {
                return lhs.uuidString < rhs.uuidString
            }
            let leftCross = direction == .horizontal ? left.position.y : left.position.x
            let rightCross = direction == .horizontal ? right.position.y : right.position.x
            if leftCross != rightCross { return leftCross < rightCross }
            return lhs.uuidString < rhs.uuidString
        }

        var layerByID: [UUID: Int] = [:]
        var queue = indegree.filter { $0.value == 0 }.map(\.key).sorted(by: stableOrder)
        for id in queue { layerByID[id] = 0 }
        var cursor = 0
        while cursor < queue.count {
            let source = queue[cursor]
            cursor += 1
            for destination in (outgoing[source] ?? []).sorted(by: stableOrder) {
                layerByID[destination] = max(
                    layerByID[destination] ?? 0,
                    (layerByID[source] ?? 0) + 1
                )
                indegree[destination, default: 0] -= 1
                if indegree[destination] == 0 { queue.append(destination) }
            }
        }

        // Cycles have no Kahn root. Keep each cycle together in one extra
        // layer, ordered by its current cross-axis position.
        let unvisited = selectedIDs.subtracting(layerByID.keys)
        let cycleLayer = (layerByID.values.max() ?? -1) + 1
        for id in unvisited { layerByID[id] = cycleLayer }

        let layers = Dictionary(grouping: selected) { layerByID[$0.id] ?? 0 }
        let minimumPrimary = selected.map {
            direction == .horizontal
                ? $0.position.x - $0.size.width / 2
                : $0.position.y - $0.size.height / 2
        }.min() ?? 0
        let minimumCross = selected.map {
            direction == .horizontal
                ? $0.position.y - $0.size.height / 2
                : $0.position.x - $0.size.width / 2
        }.min() ?? 0
        let maximumCross = selected.map {
            direction == .horizontal
                ? $0.position.y + $0.size.height / 2
                : $0.position.x + $0.size.width / 2
        }.max() ?? minimumCross
        let originalCrossCenter = (minimumCross + maximumCross) / 2

        var result: [UUID: CanvasPoint] = [:]
        var primaryCursor = minimumPrimary
        for layer in layers.keys.sorted() {
            let items = (layers[layer] ?? []).sorted {
                stableOrder($0.id, $1.id)
            }
            let primaryExtent = items.map {
                direction == .horizontal ? $0.size.width : $0.size.height
            }.max() ?? 0
            let totalCrossExtent = items.reduce(0) {
                $0 + (direction == .horizontal ? $1.size.height : $1.size.width)
            } + itemSpacing * Double(max(0, items.count - 1))
            var crossCursor = originalCrossCenter - totalCrossExtent / 2

            for node in items {
                let crossExtent = direction == .horizontal ? node.size.height : node.size.width
                let primary = primaryCursor + primaryExtent / 2
                let cross = crossCursor + crossExtent / 2
                result[node.id] = direction == .horizontal
                    ? CanvasPoint(x: primary, y: cross)
                    : CanvasPoint(x: cross, y: primary)
                crossCursor += crossExtent + itemSpacing
            }
            primaryCursor += primaryExtent + layerSpacing
        }
        return result
    }
}

public enum CanvasCommandService {
    public static func snapshot(
        project: CanvasProject, documentID: UUID? = nil,
        selectedNodeIDs: [UUID] = []
    ) throws -> CanvasContextSnapshot {
        let id = documentID ?? project.selectedDocumentID
        guard let document = project.documents.first(where: { $0.id == id }) else {
            throw FloeError.validationFailed("Canvas document does not exist")
        }
        return CanvasContextSnapshot(
            canvasID: project.id, documentID: id, revision: project.revision,
            viewport: project.viewports[id] ?? .init(),
            selectedNodeIDs: selectedNodeIDs,
            nodes: document.nodes, connections: document.connections
        )
    }

    public static func applying(
        _ patch: CanvasPatch, to original: CanvasProject
    ) throws -> (CanvasProject, CanvasOperationResult) {
        guard patch.canvasID == original.id else {
            throw FloeError.validationFailed("Patch canvas does not match the active canvas")
        }
        guard patch.expectedRevision == original.revision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(patch.expectedRevision), current \(original.revision)"
            )
        }
        guard !patch.operations.isEmpty, patch.operations.count <= 100 else {
            throw FloeError.validationFailed("Canvas patch must contain 1...100 operations")
        }
        var project = original
        guard let documentIndex = project.documents.firstIndex(where: { $0.id == patch.documentID }) else {
            throw FloeError.validationFailed("Canvas document does not exist")
        }
        var document = project.documents[documentIndex]
        let originalGenerationSources = generationSourceNodeIDs(in: document)
        try validate(patch.operations, document: document)
        var changedNodes = Set<UUID>()
        var changedConnections = Set<UUID>()
        for operation in patch.operations {
            try apply(
                operation, document: &document,
                changedNodes: &changedNodes, changedConnections: &changedConnections
            )
        }
        synchronizeGenerationSourceMetadata(
            originalSourceNodeIDs: originalGenerationSources,
            document: &document,
            changedNodes: &changedNodes
        )
        document.updatedAt = Date()
        project.documents[documentIndex] = document
        let previousRevision = project.revision
        project.revision += 1
        project.updatedAt = Date()
        return (project, CanvasOperationResult(
            canvasID: project.id, documentID: document.id,
            previousRevision: previousRevision, revision: project.revision,
            changedNodeIDs: changedNodes.sorted { $0.uuidString < $1.uuidString },
            changedConnectionIDs: changedConnections.sorted { $0.uuidString < $1.uuidString },
            delta: CanvasOperationDelta(
                nodes: document.nodes.filter { changedNodes.contains($0.id) },
                connections: document.connections.filter { changedConnections.contains($0.id) },
                removedNodeIDs: changedNodes.subtracting(document.nodes.map(\.id))
                    .sorted { $0.uuidString < $1.uuidString },
                removedConnectionIDs: changedConnections.subtracting(document.connections.map(\.id))
                    .sorted { $0.uuidString < $1.uuidString }
            )
        ))
    }

    /// Incoming `.source` edges are the canonical generation-input contract.
    /// Keep the task's metadata fallback synchronized inside the same document
    /// mutation so every caller (UI, agent tools, recovery planners) observes
    /// one revision. Only tasks whose edge set actually changed are rewritten;
    /// this preserves legacy metadata on documents that have never materialized
    /// source edges.
    private static func synchronizeGenerationSourceMetadata(
        originalSourceNodeIDs: [UUID: Set<UUID>],
        document: inout CanvasDocument,
        changedNodes: inout Set<UUID>
    ) {
        let currentSourceNodeIDs = generationSourceNodeIDs(in: document)
        for index in document.nodes.indices
        where document.nodes[index].kind == .generationTask {
            let taskID = document.nodes[index].id
            let original = originalSourceNodeIDs[taskID] ?? []
            let current = currentSourceNodeIDs[taskID] ?? []
            guard original != current else { continue }
            document.nodes[index].metadata["generationSourceNodeIDs"] = current
                .sorted { $0.uuidString < $1.uuidString }
                .map(\.uuidString)
                .joined(separator: ",")
            changedNodes.insert(taskID)
        }
    }

    private static func generationSourceNodeIDs(
        in document: CanvasDocument
    ) -> [UUID: Set<UUID>] {
        let generationTaskIDs = Set(document.nodes.compactMap { node in
            node.kind == .generationTask ? node.id : nil
        })
        let nodeIDs = Set(document.nodes.map(\.id))
        var values = Dictionary(
            uniqueKeysWithValues: generationTaskIDs.map { ($0, Set<UUID>()) }
        )
        for connection in document.connections
        where connection.kind == .source
            && generationTaskIDs.contains(connection.destinationNodeID)
            && nodeIDs.contains(connection.sourceNodeID) {
            values[connection.destinationNodeID, default: []]
                .insert(connection.sourceNodeID)
        }
        return values
    }

    private static func validate(
        _ operations: [CanvasPatchOperation], document: CanvasDocument
    ) throws {
        var nodeIDs = Set(document.nodes.map(\.id))
        var connectionIDs = Set(document.connections.map(\.id))
        for operation in operations {
            switch operation.kind {
            case .create:
                guard let nodeKind = operation.nodeKind, let position = operation.position else {
                    throw FloeError.validationFailed("create requires nodeKind and position")
                }
                _ = nodeKind; _ = position
                let id = operation.nodeID ?? operation.id
                guard nodeIDs.insert(id).inserted else {
                    throw FloeError.validationFailed("Duplicate canvas node id")
                }
            case .update:
                guard let id = operation.nodeID, nodeIDs.contains(id) else {
                    throw FloeError.validationFailed("update references a missing node")
                }
            case .delete, .group, .ungroup, .arrange:
                let ids = operation.nodeIDs ?? operation.nodeID.map { [$0] } ?? []
                guard !ids.isEmpty, ids.allSatisfy(nodeIDs.contains) else {
                    throw FloeError.validationFailed("operation references missing nodes")
                }
                if operation.kind == .group {
                    guard let memberIDs = operation.nodeIDs, memberIDs.count > 1 else {
                        throw FloeError.validationFailed("group requires at least two member nodes")
                    }
                    let groupID = operation.nodeID ?? operation.id
                    if nodeIDs.contains(groupID) {
                        guard document.nodes.first(where: { $0.id == groupID })?.kind == .group else {
                            throw FloeError.validationFailed("group container id belongs to another node")
                        }
                    } else {
                        nodeIDs.insert(groupID)
                    }
                } else if operation.kind == .delete {
                    nodeIDs.subtract(ids)
                }
            case .connect:
                guard let source = operation.sourceNodeID,
                      let destination = operation.destinationNodeID,
                      source != destination, nodeIDs.contains(source), nodeIDs.contains(destination) else {
                    throw FloeError.validationFailed("connect requires two existing distinct nodes")
                }
                guard connectionIDs.insert(operation.connectionID ?? operation.id).inserted else {
                    throw FloeError.validationFailed("Duplicate canvas connection id")
                }
            case .disconnect:
                guard let id = operation.connectionID, connectionIDs.remove(id) != nil else {
                    throw FloeError.validationFailed("disconnect references a missing connection")
                }
            }
        }
    }

    private static func apply(
        _ operation: CanvasPatchOperation, document: inout CanvasDocument,
        changedNodes: inout Set<UUID>, changedConnections: inout Set<UUID>
    ) throws {
        switch operation.kind {
        case .create:
            let id = operation.nodeID ?? operation.id
            var node = CanvasNode.placeholder(
                kind: operation.nodeKind!, position: operation.position!,
                zIndex: (document.nodes.map(\.zIndex).max() ?? 0) + 1
            )
            node.id = id
            if let text = operation.text { node.text = text }
            if let size = operation.size { node.size = size }
            if let shape = operation.shape { node.shape = shape }
            if let asset = operation.asset { node.asset = asset }
            if let generationJobID = operation.generationJobID { node.generationJobID = generationJobID }
            if let createdByRunID = operation.createdByRunID { node.createdByRunID = createdByRunID }
            if let metadata = operation.metadata { node.metadata.merge(metadata) { _, new in new } }
            document.nodes.append(node); changedNodes.insert(id)
        case .update:
            let id = operation.nodeID!
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
            guard !document.nodes[index].isLocked || operation.isLocked == false else {
                throw FloeError.validationFailed("Locked nodes must be unlocked before editing")
            }
            if let text = operation.text { document.nodes[index].text = text }
            if let nodeKind = operation.nodeKind { document.nodes[index].kind = nodeKind }
            if let position = operation.position {
                let previous = document.nodes[index].position
                document.nodes[index].position = position
                if document.nodes[index].kind == .group {
                    let dx = position.x - previous.x
                    let dy = position.y - previous.y
                    for childIndex in document.nodes.indices
                    where document.nodes[childIndex].groupID == id {
                        document.nodes[childIndex].position.x += dx
                        document.nodes[childIndex].position.y += dy
                        changedNodes.insert(document.nodes[childIndex].id)
                    }
                }
            }
            if let size = operation.size { document.nodes[index].size = size }
            if let rotation = operation.rotation { document.nodes[index].rotation = rotation }
            if let locked = operation.isLocked { document.nodes[index].isLocked = locked }
            if let shape = operation.shape { document.nodes[index].shape = shape }
            if let asset = operation.asset {
                document.nodes[index].asset = asset
                document.nodes[index].metadata["placeholder"] = nil
            }
            if let generationJobID = operation.generationJobID {
                document.nodes[index].generationJobID = generationJobID
            }
            if let createdByRunID = operation.createdByRunID {
                document.nodes[index].createdByRunID = createdByRunID
            }
            if let metadata = operation.metadata {
                document.nodes[index].metadata.merge(metadata) { _, new in new }
            }
            changedNodes.insert(id)
        case .delete:
            let ids = Set(operation.nodeIDs ?? operation.nodeID.map { [$0] } ?? [])
            let deletedGroupIDs = Set(document.nodes.compactMap { node in
                ids.contains(node.id) && node.kind == .group ? node.id : nil
            })
            if !deletedGroupIDs.isEmpty {
                for index in document.nodes.indices
                where document.nodes[index].groupID.map(deletedGroupIDs.contains) == true {
                    document.nodes[index].groupID = nil
                    changedNodes.insert(document.nodes[index].id)
                }
            }
            document.nodes.removeAll { ids.contains($0.id) }
            let removed = document.connections.filter {
                ids.contains($0.sourceNodeID) || ids.contains($0.destinationNodeID)
            }.map(\.id)
            document.connections.removeAll { removed.contains($0.id) }
            changedNodes.formUnion(ids); changedConnections.formUnion(removed)
        case .connect:
            let id = operation.connectionID ?? operation.id
            document.connections.append(CanvasConnection(
                id: id, sourceNodeID: operation.sourceNodeID!,
                destinationNodeID: operation.destinationNodeID!,
                kind: operation.connectionKind ?? .arrow,
                label: operation.label, sourcePort: operation.sourcePort,
                destinationPort: operation.destinationPort
            ))
            changedConnections.insert(id)
        case .disconnect:
            let id = operation.connectionID!
            document.connections.removeAll { $0.id == id }; changedConnections.insert(id)
        case .group:
            let ids = Set(operation.nodeIDs ?? []).subtracting([operation.nodeID ?? operation.id])
            let groupID = operation.nodeID ?? operation.id
            let members = document.nodes.filter { ids.contains($0.id) }
            guard !members.isEmpty else { return }
            if !document.nodes.contains(where: { $0.id == groupID }) {
                let minX = members.map { $0.position.x - $0.size.width / 2 }.min() ?? 0
                let maxX = members.map { $0.position.x + $0.size.width / 2 }.max() ?? 0
                let minY = members.map { $0.position.y - $0.size.height / 2 }.min() ?? 0
                let maxY = members.map { $0.position.y + $0.size.height / 2 }.max() ?? 0
                var container = CanvasNode.placeholder(
                    kind: .group,
                    position: .init(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                    zIndex: (members.map(\.zIndex).min() ?? 0) - 1
                )
                container.id = groupID
                container.size = .init(
                    width: max(180, maxX - minX + 48),
                    height: max(120, maxY - minY + 72)
                )
                container.metadata["container"] = "true"
                document.nodes.append(container)
                changedNodes.insert(groupID)
            }
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].groupID = groupID; changedNodes.insert(document.nodes[index].id)
            }
        case .ungroup:
            let ids = Set(operation.nodeIDs ?? operation.nodeID.map { [$0] } ?? [])
            let groupIDs = Set(document.nodes.compactMap { node -> UUID? in
                guard ids.contains(node.id) else { return nil }
                return node.kind == .group ? node.id : node.groupID
            })
            for index in document.nodes.indices
            where document.nodes[index].groupID.map(groupIDs.contains) == true {
                document.nodes[index].groupID = nil
                changedNodes.insert(document.nodes[index].id)
            }
            let removedConnections = document.connections.filter {
                groupIDs.contains($0.sourceNodeID) || groupIDs.contains($0.destinationNodeID)
            }.map(\.id)
            document.connections.removeAll { removedConnections.contains($0.id) }
            document.nodes.removeAll { $0.kind == .group && groupIDs.contains($0.id) }
            changedNodes.formUnion(groupIDs)
            changedConnections.formUnion(removedConnections)
        case .arrange:
            let ids = Set(operation.nodeIDs ?? [])
            let arrangement = operation.arrangement ?? "horizontal"
            let positions = CanvasAutoLayout.positions(
                nodes: document.nodes,
                connections: document.connections,
                nodeIDs: ids,
                direction: arrangement == "vertical" ? .vertical : .horizontal
            )
            for index in document.nodes.indices {
                guard let position = positions[document.nodes[index].id] else { continue }
                document.nodes[index].position = position
                changedNodes.insert(document.nodes[index].id)
            }
        }
    }
}

public enum CanvasGenerationGraphKind: String, Sendable, Codable, Hashable {
    case image, video
}

/// Resolves only explicit generation-input edges. Keeping this in FloeCore
/// gives UI, agents and tests one context contract and prevents narrative
/// arrows from silently changing provider input.
public enum CanvasGenerationContextResolver {
    public static func nodeIDs(
        selectedIDs: Set<UUID>,
        connections: [CanvasConnection],
        maximumDepth: Int = 12
    ) -> Set<UUID> {
        var included = selectedIDs
        var frontier = selectedIDs
        var depth = 0
        while !frontier.isEmpty && depth < max(0, maximumDepth) {
            let parents = Set(connections.compactMap { connection in
                guard connection.kind == .source,
                      frontier.contains(connection.destinationNodeID) else { return nil }
                return connection.sourceNodeID
            }).subtracting(included)
            included.formUnion(parents)
            frontier = parents
            depth += 1
        }
        return included
    }

    /// Resolves the provider inputs for both agent-driven generation and a
    /// saved generation-task retry. When the caller does not declare sources,
    /// existing typed source edges and the task's persisted source metadata are
    /// recovered before following only `.source` ancestry. An explicit source
    /// array (including an empty one) replaces that saved context. Ordinary
    /// arrows and generated-result edges never become implicit provider context.
    public static func resolvedNodeIDs(
        requestedIDs: [UUID]?,
        fallbackIDs: [UUID] = [],
        configurationNodeID: UUID?,
        document: CanvasDocument
    ) throws -> [UUID] {
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let requested = requestedIDs ?? []
        let missingRequested = Set(requested).subtracting(nodesByID.keys)
        guard missingRequested.isEmpty else {
            throw FloeError.validationFailed(
                "Generation references missing canvas nodes: \(missingRequested.map(\.uuidString).sorted().joined(separator: ", "))"
            )
        }

        var direct = Set(requestedIDs == nil && configurationNodeID == nil
            ? fallbackIDs.filter { nodesByID[$0] != nil }
            : requested)
        if requestedIDs == nil,
           let configurationNodeID,
           let configuration = nodesByID[configurationNodeID],
           configuration.kind == .generationTask {
            direct.formUnion(document.connections.compactMap { connection in
                connection.kind == .source
                    && connection.destinationNodeID == configurationNodeID
                    ? connection.sourceNodeID : nil
            })
            direct.formUnion(
                (configuration.metadata["generationSourceNodeIDs"] ?? "")
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
                    .filter { nodesByID[$0] != nil }
            )
        }
        if let configurationNodeID,
           let configuration = nodesByID[configurationNodeID],
           configuration.kind == .generationTask {
            direct.remove(configurationNodeID)
            let ownedResults = Set(document.connections.compactMap { connection in
                connection.kind == .generatedFrom
                    && connection.sourceNodeID == configurationNodeID
                    ? connection.destinationNodeID : nil
            })
            direct.subtract(ownedResults)
        }

        let included = nodeIDs(selectedIDs: direct, connections: document.connections)
        return document.nodes.filter { node in
            included.contains(node.id)
                && node.id != configurationNodeID
                && node.kind != .generationTask
        }.sorted {
            if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
            if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
    }

    /// Text that may accompany the media request. A generated image's saved
    /// prompt is included only when that image itself reached the canonical
    /// input set through an explicit source selection/edge.
    public static func contextText(
        nodes: [CanvasNode],
        excluding prompt: String
    ) -> [String] {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return nodes.compactMap { node -> String? in
            let value: String?
            switch node.kind {
            case .text, .stickyNote, .card:
                value = node.text
            case .image:
                value = node.metadata["generationPrompt"].map {
                    "Reference image original prompt: \($0)"
                }
            default:
                value = nil
            }
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, trimmed != base,
                  seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

/// Fixed-grid placement for newly-created generation nodes. Existing nodes
/// are obstacles and are never moved; new configuration/results form a short
/// left-to-right flow, with multiple results stacked in one aligned column.
public enum CanvasGenerationLayout {
    public struct Plan: Sendable, Hashable {
        public var configurationPosition: CanvasPoint
        public var resultPositions: [CanvasPoint]

        public init(configurationPosition: CanvasPoint, resultPositions: [CanvasPoint]) {
            self.configurationPosition = configurationPosition
            self.resultPositions = resultPositions
        }
    }

    private struct Box {
        var center: CanvasPoint
        var size: CanvasSize

        func intersects(_ other: Box, padding: Double = 24) -> Bool {
            abs(center.x - other.center.x) * 2 < size.width + other.size.width + padding * 2
                && abs(center.y - other.center.y) * 2 < size.height + other.size.height + padding * 2
        }
    }

    public static func plan(
        document: CanvasDocument,
        sourceNodeIDs: [UUID],
        preferredResultPosition: CanvasPoint,
        configurationNodeID: UUID,
        resultNodeIDs: [UUID],
        kind: CanvasGenerationGraphKind,
        resultCount: Int
    ) -> Plan {
        let grid = 24.0
        let horizontalGap = 72.0
        let verticalGap = 48.0
        let configurationSize = CanvasSize(width: 340, height: 210)
        let resultSize = CanvasSize(width: 320, height: kind == .image ? 260 : 220)
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let existingConfiguration = nodesByID[configurationNodeID]
        let sources = sourceNodeIDs.compactMap { nodesByID[$0] }
        let rightmostSource = sources.max {
            let lhs = $0.position.x + $0.size.width / 2
            let rhs = $1.position.x + $1.size.width / 2
            if lhs != rhs { return lhs < rhs }
            if $0.position.y != $1.position.y { return $0.position.y > $1.position.y }
            return $0.id.uuidString > $1.id.uuidString
        }

        func snapped(_ value: Double) -> Double { (value / grid).rounded() * grid }
        func snappedForward(_ value: Double) -> Double { ceil(value / grid) * grid }

        let flowY = existingConfiguration?.position.y
            ?? rightmostSource?.position.y
            ?? preferredResultPosition.y
        var configurationPosition = existingConfiguration?.position ?? CanvasPoint(
            x: rightmostSource.map {
                snappedForward($0.position.x + $0.size.width / 2
                    + horizontalGap + configurationSize.width / 2)
            } ?? snapped(preferredResultPosition.x
                - resultSize.width / 2 - horizontalGap - configurationSize.width / 2),
            y: snapped(flowY)
        )
        let firstResultPosition = resultNodeIDs.first.flatMap { nodesByID[$0]?.position }
            ?? CanvasPoint(
            x: snappedForward(configurationPosition.x + configurationSize.width / 2
                + horizontalGap + resultSize.width / 2),
            y: snapped(flowY)
        )
        let resultVerticalStep = ceil((resultSize.height + verticalGap) / grid) * grid
        var resultPositions = (0..<max(1, resultCount)).map { index in
            if resultNodeIDs.indices.contains(index),
               let existing = nodesByID[resultNodeIDs[index]] {
                return existing.position
            }
            return index == 0 ? firstResultPosition : CanvasPoint(
                x: firstResultPosition.x,
                y: firstResultPosition.y + Double(index) * resultVerticalStep
            )
        }

        let obstacles = document.nodes.map {
            Box(center: $0.position, size: $0.size)
        }
        let movesConfiguration = existingConfiguration == nil
        for _ in 0..<512 {
            var movable: [Box] = resultPositions.enumerated().compactMap {
                (index, position) -> Box? in
                guard resultNodeIDs.indices.contains(index),
                      nodesByID[resultNodeIDs[index]] == nil else { return nil }
                return Box(center: position, size: resultSize)
            }
            if movesConfiguration {
                movable.append(Box(center: configurationPosition, size: configurationSize))
            }
            guard movable.contains(where: { candidate in
                obstacles.contains { candidate.intersects($0) }
            }) else { break }
            if movesConfiguration { configurationPosition.y += grid }
            for index in resultPositions.indices
            where resultNodeIDs.indices.contains(index)
                && nodesByID[resultNodeIDs[index]] == nil {
                resultPositions[index].y += grid
            }
        }
        return Plan(
            configurationPosition: configurationPosition,
            resultPositions: resultPositions
        )
    }
}

/// Canonical topology prepared before a provider request crosses the network.
/// Both direct canvas UI and the canvas agent use this planner so prompts,
/// configuration, references, results and retries share one graph contract.
public struct CanvasGenerationGraphRequest: Sendable, Hashable {
    public var kind: CanvasGenerationGraphKind
    public var prompt: String
    public var sourceNodeIDs: [UUID]
    public var resultPosition: CanvasPoint
    public var existingConfigurationNodeID: UUID?
    public var reusableResultNodeID: UUID?
    public var resultCount: Int
    /// Whether a missing prompt source may be materialized as a visible text
    /// node. Existing task execution sets this to false: its saved prompt is
    /// configuration, not a request to mutate the graph topology.
    public var createsPromptNodeWhenMissing: Bool
    public var createdByRunID: UUID?
    public var metadata: [String: String]

    public init(
        kind: CanvasGenerationGraphKind,
        prompt: String,
        sourceNodeIDs: [UUID] = [],
        resultPosition: CanvasPoint,
        existingConfigurationNodeID: UUID? = nil,
        reusableResultNodeID: UUID? = nil,
        resultCount: Int = 1,
        createsPromptNodeWhenMissing: Bool = false,
        createdByRunID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind; self.prompt = prompt
        self.sourceNodeIDs = sourceNodeIDs; self.resultPosition = resultPosition
        self.existingConfigurationNodeID = existingConfigurationNodeID
        self.reusableResultNodeID = reusableResultNodeID
        self.resultCount = max(1, resultCount)
        self.createsPromptNodeWhenMissing = createsPromptNodeWhenMissing
        self.createdByRunID = createdByRunID; self.metadata = metadata
    }
}

public struct CanvasGenerationGraphPlan: Sendable, Hashable {
    public var promptNodeID: UUID
    public var configurationNodeID: UUID
    public var resultNodeID: UUID
    public var resultNodeIDs: [UUID]
    public var sourceNodeIDs: [UUID]
    public var resultPositions: [CanvasPoint]
    public var operations: [CanvasPatchOperation]

    public init(
        promptNodeID: UUID, configurationNodeID: UUID,
        resultNodeID: UUID, resultNodeIDs: [UUID],
        sourceNodeIDs: [UUID], resultPositions: [CanvasPoint],
        operations: [CanvasPatchOperation]
    ) {
        self.promptNodeID = promptNodeID
        self.configurationNodeID = configurationNodeID
        self.resultNodeID = resultNodeID
        self.resultNodeIDs = resultNodeIDs
        self.sourceNodeIDs = sourceNodeIDs
        self.resultPositions = resultPositions
        self.operations = operations
    }
}

public enum CanvasGenerationGraphPlanner {
    public static func plan(
        request: CanvasGenerationGraphRequest,
        document: CanvasDocument
    ) throws -> CanvasGenerationGraphPlan {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw FloeError.validationFailed("Generation prompt is required")
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let requestedSources = request.sourceNodeIDs.compactMap { nodesByID[$0] }
        let promptNode = requestedSources.first {
            [.text, .stickyNote, .card].contains($0.kind)
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
        }
        let configurationNodeID: UUID
        if let id = request.existingConfigurationNodeID,
           nodesByID[id]?.kind == .generationTask {
            configurationNodeID = id
        } else {
            configurationNodeID = UUID()
        }
        let shouldCreatePromptNode = promptNode == nil
            && request.createsPromptNodeWhenMissing
        // Keep the plan contract non-optional for existing callers. When an
        // existing task owns an inline prompt, its task ID is the prompt
        // anchor but is deliberately not added as a generation source.
        let promptNodeID = promptNode?.id
            ?? (shouldCreatePromptNode ? UUID() : configurationNodeID)
        let resultKind: CanvasNodeKind = request.kind == .image ? .image : .video
        let requestedResultCount = request.kind == .image ? request.resultCount : 1
        var reusableResultIDs: [UUID] = []
        if let id = request.reusableResultNodeID,
           let node = nodesByID[id], node.kind == resultKind, node.asset == nil {
            reusableResultIDs.append(id)
        }
        let connectedReusableResults = document.connections
            .filter {
                $0.kind == .generatedFrom && $0.sourceNodeID == configurationNodeID
            }
            .compactMap { connection in
                nodesByID[connection.destinationNodeID]
            }
            .filter { $0.kind == resultKind && $0.asset == nil }
            .sorted {
                if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
                if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)
        reusableResultIDs.append(contentsOf: connectedReusableResults)
        var seenResultIDs = Set<UUID>()
        var resultNodeIDs = reusableResultIDs.filter { seenResultIDs.insert($0).inserted }
        resultNodeIDs = Array(resultNodeIDs.prefix(requestedResultCount))
        while resultNodeIDs.count < requestedResultCount { resultNodeIDs.append(UUID()) }
        let resultNodeID = resultNodeIDs[0]
        let layout = CanvasGenerationLayout.plan(
            document: document,
            sourceNodeIDs: requestedSources.map(\.id),
            preferredResultPosition: request.resultPosition,
            configurationNodeID: configurationNodeID,
            resultNodeIDs: resultNodeIDs,
            kind: request.kind,
            resultCount: request.resultCount
        )

        var metadata = request.metadata
        metadata["generationKind"] = request.kind.rawValue
        metadata["generationPrompt"] = prompt
        metadata["generationState"] = metadata["generationState"] ?? "preparing"
        metadata["generationResultNodeIDs"] = resultNodeIDs.map(\.uuidString)
            .joined(separator: ",")
        var seenSourceIDs = Set<UUID>()
        let sourceIDs = (
            requestedSources.map(\.id) + (shouldCreatePromptNode ? [promptNodeID] : [])
        ).filter { seenSourceIDs.insert($0).inserted }
        metadata["generationSourceNodeIDs"] = sourceIDs.map(\.uuidString).joined(separator: ",")

        var operations: [CanvasPatchOperation] = []
        if shouldCreatePromptNode {
            operations.append(CanvasPatchOperation(
                kind: .create, nodeID: promptNodeID, nodeKind: .text,
                text: prompt,
                position: .init(
                    x: layout.configurationPosition.x - 420,
                    y: layout.configurationPosition.y
                ),
                size: .init(width: 320, height: 180),
                createdByRunID: request.createdByRunID,
                metadata: ["generationRole": "prompt"]
            ))
        }

        let configurationText = request.kind == .image ? "图片生成" : "视频生成"
        if nodesByID[configurationNodeID] == nil {
            operations.append(CanvasPatchOperation(
                kind: .create, nodeID: configurationNodeID, nodeKind: .generationTask,
                text: configurationText,
                position: layout.configurationPosition,
                size: .init(width: 340, height: 210),
                createdByRunID: request.createdByRunID, metadata: metadata
            ))
        } else {
            operations.append(CanvasPatchOperation(
                kind: .update, nodeID: configurationNodeID,
                text: configurationText,
                createdByRunID: request.createdByRunID, metadata: metadata
            ))
        }

        for (index, resultID) in resultNodeIDs.enumerated() {
            if nodesByID[resultID] == nil {
                operations.append(CanvasPatchOperation(
                    kind: .create, nodeID: resultID, nodeKind: resultKind,
                    text: request.kind == .image ? "图片生成中" : "视频生成中",
                    position: layout.resultPositions[index],
                    size: .init(width: 320, height: request.kind == .image ? 260 : 220),
                    createdByRunID: request.createdByRunID,
                    metadata: metadata.merging([
                        "generationRole": "result",
                        "artifactOrigin": "generated",
                        "imageGroupPrimary": index == 0 ? "true" : "false"
                    ]) { _, new in new }
                ))
            } else {
                operations.append(CanvasPatchOperation(
                    kind: .update, nodeID: resultID,
                    text: request.kind == .image ? "图片生成中" : "视频生成中",
                    createdByRunID: request.createdByRunID,
                    metadata: metadata.merging([
                        "generationRole": "result",
                        "artifactOrigin": "generated",
                        "imageGroupPrimary": index == 0 ? "true" : "false"
                    ]) { _, new in new }
                ))
            }
        }

        var disconnectedConnectionIDs = Set<UUID>()

        // Incoming source edges are the canonical provider-input contract.
        // Replace stale/duplicate edges on retry without deleting the source
        // nodes themselves, otherwise a prior reference can leak back into the
        // next request through context resolution.
        let currentSourceIDs = Set(sourceIDs)
        var retainedSourceIDs = Set<UUID>()
        let existingSourceConnections = document.connections
            .filter {
                $0.kind == .source && $0.destinationNodeID == configurationNodeID
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for connection in existingSourceConnections {
            let keepsCanonicalEdge = currentSourceIDs.contains(connection.sourceNodeID)
                && retainedSourceIDs.insert(connection.sourceNodeID).inserted
            if !keepsCanonicalEdge {
                disconnectedConnectionIDs.insert(connection.id)
                operations.append(CanvasPatchOperation(
                    kind: .disconnect, connectionID: connection.id
                ))
            }
        }

        // A generation task owns only the result nodes named by its current
        // generationResultNodeIDs metadata. Retries preserve prior artifacts,
        // but detach their historical generatedFrom edges so the active task
        // topology cannot silently grow from four outputs to eight, twelve, …
        let currentResultIDs = Set(resultNodeIDs)
        var retainedResultIDs = Set<UUID>()
        let existingResultConnections = document.connections
            .filter {
                $0.kind == .generatedFrom && $0.sourceNodeID == configurationNodeID
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for connection in existingResultConnections {
            let keepsCanonicalEdge = currentResultIDs.contains(connection.destinationNodeID)
                && retainedResultIDs.insert(connection.destinationNodeID).inserted
            if !keepsCanonicalEdge {
                disconnectedConnectionIDs.insert(connection.id)
                operations.append(CanvasPatchOperation(
                    kind: .disconnect, connectionID: connection.id
                ))
            }
        }
        let existingEdges = Set(document.connections.lazy
            .filter { !disconnectedConnectionIDs.contains($0.id) }
            .map {
                "\($0.kind.rawValue):\($0.sourceNodeID.uuidString)>\($0.destinationNodeID.uuidString)"
            })
        for sourceID in sourceIDs where sourceID != configurationNodeID {
            let key = "\(CanvasConnectionKind.source.rawValue):\(sourceID.uuidString)>\(configurationNodeID.uuidString)"
            if !existingEdges.contains(key) {
                operations.append(CanvasPatchOperation(
                    kind: .connect, sourceNodeID: sourceID,
                    destinationNodeID: configurationNodeID,
                    connectionKind: .source, sourcePort: .trailing,
                    destinationPort: .leading, label: "生成输入"
                ))
            }
        }
        for resultID in resultNodeIDs {
            let resultEdge = "\(CanvasConnectionKind.generatedFrom.rawValue):\(configurationNodeID.uuidString)>\(resultID.uuidString)"
            if !existingEdges.contains(resultEdge) {
                operations.append(CanvasPatchOperation(
                    kind: .connect, sourceNodeID: configurationNodeID,
                    destinationNodeID: resultID,
                    connectionKind: .generatedFrom, sourcePort: .trailing,
                    destinationPort: .leading, label: "生成结果"
                ))
            }
        }
        return CanvasGenerationGraphPlan(
            promptNodeID: promptNodeID,
            configurationNodeID: configurationNodeID,
            resultNodeID: resultNodeID,
            resultNodeIDs: resultNodeIDs,
            sourceNodeIDs: sourceIDs,
            resultPositions: layout.resultPositions,
            operations: operations
        )
    }
}

/// Enforces all-or-nothing result cardinality before callers index result
/// nodes or attach provider assets. A four-image request cannot be reported as
/// successful with only one to three images, and unexpected extras cannot
/// overrun the graph prepared before networking.
public enum CanvasGenerationOutputContract {
    public static func resultNodeIDs(
        expectedCount: Int,
        actualCount: Int,
        preparedResultNodeIDs: [UUID]
    ) throws -> [UUID] {
        let expected = max(1, min(expectedCount, 4))
        guard actualCount == expected,
              preparedResultNodeIDs.count == expected else {
            throw FloeError.validationFailed(
                "图片服务应返回 \(expected) 张图片，但实际返回 \(actualCount) 张；本次没有按部分成功提交，请从配置节点重试。"
            )
        }
        return preparedResultNodeIDs
    }
}

/// Verifies that an asynchronous provider response still belongs to the graph
/// that requested it.  Canvas edits may legitimately advance the revision
/// while a provider is running, so the attempt token and task state — rather
/// than the project revision — are the concurrency boundary.
public enum CanvasGenerationAttemptValidator {
    public static func matches(
        document: CanvasDocument,
        configurationNodeID: UUID,
        resultNodeIDs: [UUID],
        generationAttemptID: String
    ) -> Bool {
        guard !generationAttemptID.isEmpty, !resultNodeIDs.isEmpty,
              let configuration = document.nodes.first(where: {
                  $0.id == configurationNodeID && $0.kind == .generationTask
              }),
              configuration.metadata["generationAttemptID"] == generationAttemptID else {
            return false
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        return resultNodeIDs.allSatisfy { resultNodeID in
            nodesByID[resultNodeID]?.metadata["generationAttemptID"] == generationAttemptID
        }
    }

    public static func isActive(
        document: CanvasDocument,
        configurationNodeID: UUID,
        resultNodeIDs: [UUID],
        generationAttemptID: String
    ) -> Bool {
        guard matches(
            document: document,
            configurationNodeID: configurationNodeID,
            resultNodeIDs: resultNodeIDs,
            generationAttemptID: generationAttemptID
        ) else { return false }
        let expectedNodeIDs = Set([configurationNodeID] + resultNodeIDs)
        return document.nodes.filter { expectedNodeIDs.contains($0.id) }.allSatisfy { node in
            node.metadata["generationState"]
                .flatMap(CanvasGenerationTaskState.init(rawValue:))?.isRunning == true
        }
    }
}

/// Rebuilds the local commit for a completed media-generation attempt against
/// the latest canvas revision. The provider request may take long enough for a
/// viewport or node edit to advance the project while it is in flight; those
/// unrelated changes must be preserved instead of turning a successful remote
/// generation into a revision-conflict failure.
public enum CanvasGenerationCommitPlanner {
    public static func patch(
        project: CanvasProject,
        documentID: UUID,
        configurationNodeID: UUID,
        resultNodeIDs: [UUID],
        sourceNodeIDs: [UUID]? = nil,
        generationAttemptID: String,
        operations: [CanvasPatchOperation]
    ) throws -> CanvasPatch {
        guard !generationAttemptID.isEmpty else {
            throw FloeError.validationFailed("Canvas generation attempt id is missing")
        }
        guard let document = project.documents.first(where: { $0.id == documentID }) else {
            throw FloeError.validationFailed("Canvas document does not exist")
        }
        guard CanvasGenerationAttemptValidator.isActive(
            document: document,
            configurationNodeID: configurationNodeID,
            resultNodeIDs: resultNodeIDs,
            generationAttemptID: generationAttemptID
        ) else {
            throw FloeError.validationFailed(
                "Canvas generation attempt was superseded before its local result was committed"
            )
        }

        guard Set(resultNodeIDs).count == resultNodeIDs.count else {
            throw FloeError.validationFailed(
                "Canvas generation result node ids must be unique"
            )
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let persistedSourceNodeIDs = nodesByID[configurationNodeID]?
            .metadata["generationSourceNodeIDs"]?
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) } ?? []
        var seenSourceNodeIDs = Set<UUID>()
        let canonicalSourceNodeIDs = (sourceNodeIDs ?? persistedSourceNodeIDs)
            .filter { $0 != configurationNodeID && seenSourceNodeIDs.insert($0).inserted }
        guard canonicalSourceNodeIDs.allSatisfy({ nodesByID[$0] != nil }) else {
            throw FloeError.validationFailed(
                "Canvas generation source was removed before its local result was committed"
            )
        }

        let canonicalResultNodeIDs = resultNodeIDs
        let canonicalSourceSet = Set(canonicalSourceNodeIDs)
        let canonicalResultSet = Set(canonicalResultNodeIDs)
        let connectionsByID = Dictionary(
            uniqueKeysWithValues: document.connections.map { ($0.id, $0) }
        )

        // Completion owns the generation topology. Ignore any caller-supplied
        // operations for these same relationships, then rebuild them from the
        // latest document in this one atomic patch. This closes the window in
        // which a user can delete or redirect an edge while the provider is
        // still returning its result.
        var normalizedOperations = operations.filter { operation in
            switch operation.kind {
            case .connect:
                if operation.connectionKind == .source,
                   operation.destinationNodeID == configurationNodeID {
                    return false
                }
                if operation.connectionKind == .generatedFrom,
                   operation.sourceNodeID == configurationNodeID
                    || operation.destinationNodeID.map(canonicalResultSet.contains) == true {
                    return false
                }
                return true
            case .disconnect:
                guard let connectionID = operation.connectionID,
                      let connection = connectionsByID[connectionID] else { return true }
                if connection.kind == .source,
                   connection.destinationNodeID == configurationNodeID {
                    return false
                }
                if connection.kind == .generatedFrom,
                   connection.sourceNodeID == configurationNodeID
                    || canonicalResultSet.contains(connection.destinationNodeID) {
                    return false
                }
                return true
            default:
                return true
            }
        }

        var retainedSourceNodeIDs = Set<UUID>()
        var retainedResultNodeIDs = Set<UUID>()
        for connection in document.connections.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            if connection.kind == .source,
               connection.destinationNodeID == configurationNodeID {
                let keep = canonicalSourceSet.contains(connection.sourceNodeID)
                    && retainedSourceNodeIDs.insert(connection.sourceNodeID).inserted
                if !keep {
                    normalizedOperations.append(CanvasPatchOperation(
                        kind: .disconnect,
                        connectionID: connection.id
                    ))
                }
                continue
            }
            if connection.kind == .generatedFrom,
               connection.sourceNodeID == configurationNodeID
                || canonicalResultSet.contains(connection.destinationNodeID) {
                let keep = connection.sourceNodeID == configurationNodeID
                    && canonicalResultSet.contains(connection.destinationNodeID)
                    && retainedResultNodeIDs.insert(connection.destinationNodeID).inserted
                if !keep {
                    normalizedOperations.append(CanvasPatchOperation(
                        kind: .disconnect,
                        connectionID: connection.id
                    ))
                }
            }
        }

        for sourceNodeID in canonicalSourceNodeIDs
        where !retainedSourceNodeIDs.contains(sourceNodeID) {
            normalizedOperations.append(CanvasPatchOperation(
                kind: .connect,
                sourceNodeID: sourceNodeID,
                destinationNodeID: configurationNodeID,
                connectionKind: .source,
                sourcePort: .trailing,
                destinationPort: .leading,
                label: "生成输入"
            ))
        }
        for resultNodeID in canonicalResultNodeIDs
        where !retainedResultNodeIDs.contains(resultNodeID) {
            normalizedOperations.append(CanvasPatchOperation(
                kind: .connect,
                sourceNodeID: configurationNodeID,
                destinationNodeID: resultNodeID,
                connectionKind: .generatedFrom,
                sourcePort: .trailing,
                destinationPort: .leading,
                label: "生成结果"
            ))
        }

        let sourceList = canonicalSourceNodeIDs.map(\.uuidString).joined(separator: ",")
        let resultList = canonicalResultNodeIDs.map(\.uuidString).joined(separator: ",")
        normalizedOperations.append(CanvasPatchOperation(
            kind: .update,
            nodeID: configurationNodeID,
            metadata: [
                "generationSourceNodeIDs": sourceList,
                "generationResultNodeIDs": resultList
            ]
        ))
        normalizedOperations.append(contentsOf: canonicalResultNodeIDs.map { resultNodeID in
            CanvasPatchOperation(
                kind: .update,
                nodeID: resultNodeID,
                metadata: [
                    "generationSourceNodeIDs": sourceList,
                    "generationResultNodeIDs": resultList,
                    "generationTaskNodeID": configurationNodeID.uuidString
                ]
            )
        })
        return CanvasPatch(
            canvasID: project.id,
            documentID: documentID,
            expectedRevision: project.revision,
            operations: normalizedOperations
        )
    }
}

/// Produces the one atomic mutation used when cancelling a generation task and
/// all of its prepared result nodes. Replacing the attempt token first makes a
/// late provider response fail validation without requiring another cleanup
/// write from the executor's cancellation handler.
public enum CanvasGenerationCancellationPlanner {
    public static func operations(
        nodeIDs: [UUID],
        cancelledAttemptID: String
    ) -> [CanvasPatchOperation] {
        guard !cancelledAttemptID.isEmpty else { return [] }
        var seenNodeIDs = Set<UUID>()
        return nodeIDs.filter { seenNodeIDs.insert($0).inserted }.map { nodeID in
            CanvasPatchOperation(
                kind: .update,
                nodeID: nodeID,
                metadata: [
                    "generationAttemptID": cancelledAttemptID,
                    "generationState": CanvasGenerationTaskState.cancelled.rawValue,
                    "generationError": "",
                    "generationErrorDetail": ""
                ]
            )
        }
    }
}

/// Saves the editable generation node without manufacturing prompt or result
/// nodes. Generation execution uses `CanvasGenerationGraphPlanner` later to
/// materialize exactly the provider result that was actually requested.
public enum CanvasGenerationConfigurationPlanner {
    public static func plan(
        kind: CanvasGenerationGraphKind,
        prompt: String,
        sourceNodeIDs: [UUID],
        position: CanvasPoint,
        existingConfigurationNodeID: UUID?,
        metadata: [String: String],
        document: CanvasDocument
    ) throws -> (configurationNodeID: UUID, operations: [CanvasPatchOperation]) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeError.validationFailed("Generation prompt is required")
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let configurationNodeID = existingConfigurationNodeID.flatMap {
            nodesByID[$0]?.kind == .generationTask ? $0 : nil
        } ?? UUID()
        let sources = Array(Set(sourceNodeIDs.filter {
            $0 != configurationNodeID && nodesByID[$0] != nil
        })).sorted { $0.uuidString < $1.uuidString }
        var values = metadata
        values["generationKind"] = kind.rawValue
        values["generationPrompt"] = trimmed
        values["generationSourceNodeIDs"] = sources.map(\.uuidString).joined(separator: ",")
        values["generationState"] = CanvasGenerationTaskState.configured.rawValue
        // Saving configuration supersedes any provider response that was
        // created from the previous prompt/model/source set.
        values["generationAttemptID"] = UUID().uuidString
        let title = kind == .image ? "图片生成" : "视频生成"
        var operations: [CanvasPatchOperation] = [
            CanvasPatchOperation(
                kind: nodesByID[configurationNodeID] == nil ? .create : .update,
                nodeID: configurationNodeID,
                nodeKind: nodesByID[configurationNodeID] == nil ? .generationTask : nil,
                text: title,
                position: nodesByID[configurationNodeID] == nil ? position : nil,
                size: nodesByID[configurationNodeID] == nil
                    ? .init(width: 340, height: 210) : nil,
                metadata: values
            )
        ]
        let desired = Set(sources)
        for connection in document.connections where
            connection.destinationNodeID == configurationNodeID
                && connection.kind == .source
                && !desired.contains(connection.sourceNodeID) {
            operations.append(CanvasPatchOperation(
                kind: .disconnect, connectionID: connection.id
            ))
        }
        let existingSources = Set(document.connections.compactMap {
            $0.destinationNodeID == configurationNodeID && $0.kind == .source
                ? $0.sourceNodeID : nil
        })
        for sourceID in sources where !existingSources.contains(sourceID) {
            operations.append(CanvasPatchOperation(
                kind: .connect,
                sourceNodeID: sourceID,
                destinationNodeID: configurationNodeID,
                connectionKind: .source,
                sourcePort: .trailing,
                destinationPort: .leading,
                label: "生成输入"
            ))
        }
        return (configurationNodeID, operations)
    }
}

public protocol CanvasDocumentRepository: Sendable {
    func project(canvasID: UUID) async throws -> CanvasProject
    func save(_ project: CanvasProject, expectedRevision: Int64) async throws
}
