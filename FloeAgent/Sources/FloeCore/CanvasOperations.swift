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
    public var sourceNodeID: UUID?
    public var destinationNodeID: UUID?
    public var connectionID: UUID?
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
        sourceNodeID: UUID? = nil,
        destinationNodeID: UUID? = nil, connectionID: UUID? = nil,
        sourcePort: CanvasConnectionPort? = nil,
        destinationPort: CanvasConnectionPort? = nil,
        label: String? = nil, arrangement: String? = nil
    ) {
        self.id = id; self.kind = kind; self.nodeID = nodeID; self.nodeIDs = nodeIDs
        self.nodeKind = nodeKind; self.text = text; self.position = position
        self.size = size; self.rotation = rotation; self.isLocked = isLocked
        self.shape = shape; self.asset = asset; self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID; self.connectionID = connectionID
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

public struct CanvasOperationResult: Sendable, Codable, Hashable {
    public var canvasID: UUID
    public var documentID: UUID
    public var previousRevision: Int64
    public var revision: Int64
    public var changedNodeIDs: [UUID]
    public var changedConnectionIDs: [UUID]
    public var undoToken: UUID

    public init(
        canvasID: UUID, documentID: UUID, previousRevision: Int64,
        revision: Int64, changedNodeIDs: [UUID],
        changedConnectionIDs: [UUID], undoToken: UUID = UUID()
    ) {
        self.canvasID = canvasID; self.documentID = documentID
        self.previousRevision = previousRevision; self.revision = revision
        self.changedNodeIDs = changedNodeIDs
        self.changedConnectionIDs = changedConnectionIDs
        self.undoToken = undoToken
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
        try validate(patch.operations, document: document)
        var changedNodes = Set<UUID>()
        var changedConnections = Set<UUID>()
        for operation in patch.operations {
            try apply(
                operation, document: &document,
                changedNodes: &changedNodes, changedConnections: &changedConnections
            )
        }
        document.updatedAt = Date()
        project.documents[documentIndex] = document
        let previousRevision = project.revision
        project.revision += 1
        project.updatedAt = Date()
        return (project, CanvasOperationResult(
            canvasID: project.id, documentID: document.id,
            previousRevision: previousRevision, revision: project.revision,
            changedNodeIDs: changedNodes.sorted { $0.uuidString < $1.uuidString },
            changedConnectionIDs: changedConnections.sorted { $0.uuidString < $1.uuidString }
        ))
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
                if operation.kind == .delete { nodeIDs.subtract(ids) }
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
            document.nodes.append(node); changedNodes.insert(id)
        case .update:
            let id = operation.nodeID!
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
            guard !document.nodes[index].isLocked || operation.isLocked == false else {
                throw FloeError.validationFailed("Locked nodes must be unlocked before editing")
            }
            if let text = operation.text { document.nodes[index].text = text }
            if let position = operation.position { document.nodes[index].position = position }
            if let size = operation.size { document.nodes[index].size = size }
            if let rotation = operation.rotation { document.nodes[index].rotation = rotation }
            if let locked = operation.isLocked { document.nodes[index].isLocked = locked }
            if let shape = operation.shape { document.nodes[index].shape = shape }
            changedNodes.insert(id)
        case .delete:
            let ids = Set(operation.nodeIDs ?? operation.nodeID.map { [$0] } ?? [])
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
                label: operation.label, sourcePort: operation.sourcePort,
                destinationPort: operation.destinationPort
            ))
            changedConnections.insert(id)
        case .disconnect:
            let id = operation.connectionID!
            document.connections.removeAll { $0.id == id }; changedConnections.insert(id)
        case .group:
            let ids = Set(operation.nodeIDs ?? [])
            let groupID = operation.nodeID ?? operation.id
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].groupID = groupID; changedNodes.insert(document.nodes[index].id)
            }
        case .ungroup:
            let ids = Set(operation.nodeIDs ?? operation.nodeID.map { [$0] } ?? [])
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].groupID = nil; changedNodes.insert(document.nodes[index].id)
            }
        case .arrange:
            let ids = Set(operation.nodeIDs ?? [])
            let selected = document.nodes.filter { ids.contains($0.id) }
            guard !selected.isEmpty else { return }
            let arrangement = operation.arrangement ?? "horizontal"
            for (offset, node) in selected.sorted(by: { $0.id.uuidString < $1.id.uuidString }).enumerated() {
                guard let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
                if arrangement == "vertical" { document.nodes[index].position.y += Double(offset) * 48 }
                else { document.nodes[index].position.x += Double(offset) * 48 }
                changedNodes.insert(node.id)
            }
        }
    }
}

public protocol CanvasDocumentRepository: Sendable {
    func project(canvasID: UUID) async throws -> CanvasProject
    func save(_ project: CanvasProject, expectedRevision: Int64) async throws
}
