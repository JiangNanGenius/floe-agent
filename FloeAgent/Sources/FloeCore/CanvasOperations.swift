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

public enum CanvasGenerationGraphKind: String, Sendable, Codable, Hashable {
    case image, video
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
    public var createdByRunID: UUID?
    public var metadata: [String: String]

    public init(
        kind: CanvasGenerationGraphKind,
        prompt: String,
        sourceNodeIDs: [UUID] = [],
        resultPosition: CanvasPoint,
        existingConfigurationNodeID: UUID? = nil,
        reusableResultNodeID: UUID? = nil,
        createdByRunID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind; self.prompt = prompt
        self.sourceNodeIDs = sourceNodeIDs; self.resultPosition = resultPosition
        self.existingConfigurationNodeID = existingConfigurationNodeID
        self.reusableResultNodeID = reusableResultNodeID
        self.createdByRunID = createdByRunID; self.metadata = metadata
    }
}

public struct CanvasGenerationGraphPlan: Sendable, Hashable {
    public var promptNodeID: UUID
    public var configurationNodeID: UUID
    public var resultNodeID: UUID
    public var sourceNodeIDs: [UUID]
    public var operations: [CanvasPatchOperation]

    public init(
        promptNodeID: UUID, configurationNodeID: UUID,
        resultNodeID: UUID, sourceNodeIDs: [UUID],
        operations: [CanvasPatchOperation]
    ) {
        self.promptNodeID = promptNodeID
        self.configurationNodeID = configurationNodeID
        self.resultNodeID = resultNodeID
        self.sourceNodeIDs = sourceNodeIDs; self.operations = operations
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
        let promptNodeID = promptNode?.id ?? UUID()
        let configurationNodeID: UUID
        if let id = request.existingConfigurationNodeID,
           nodesByID[id]?.kind == .generationTask {
            configurationNodeID = id
        } else {
            configurationNodeID = UUID()
        }
        let resultKind: CanvasNodeKind = request.kind == .image ? .image : .video
        let resultNodeID: UUID
        if let id = request.reusableResultNodeID,
           let node = nodesByID[id], node.kind == resultKind, node.asset == nil {
            resultNodeID = id
        } else {
            resultNodeID = UUID()
        }

        var metadata = request.metadata
        metadata["generationKind"] = request.kind.rawValue
        metadata["generationPrompt"] = prompt
        metadata["generationState"] = metadata["generationState"] ?? "preparing"
        let sourceIDs = Array(Set(requestedSources.map(\.id) + [promptNodeID]))
            .sorted { $0.uuidString < $1.uuidString }
        metadata["generationSourceNodeIDs"] = sourceIDs.map(\.uuidString).joined(separator: ",")

        var operations: [CanvasPatchOperation] = []
        if promptNode == nil {
            operations.append(CanvasPatchOperation(
                kind: .create, nodeID: promptNodeID, nodeKind: .text,
                text: prompt,
                position: .init(x: request.resultPosition.x - 840, y: request.resultPosition.y),
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
                position: .init(x: request.resultPosition.x - 420, y: request.resultPosition.y),
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

        if nodesByID[resultNodeID] == nil {
            operations.append(CanvasPatchOperation(
                kind: .create, nodeID: resultNodeID, nodeKind: resultKind,
                text: request.kind == .image ? "图片生成中" : "视频生成中",
                position: request.resultPosition,
                size: .init(width: 320, height: request.kind == .image ? 260 : 220),
                createdByRunID: request.createdByRunID,
                metadata: metadata.merging(["generationRole": "result"]) { _, new in new }
            ))
        } else {
            operations.append(CanvasPatchOperation(
                kind: .update, nodeID: resultNodeID,
                text: request.kind == .image ? "图片生成中" : "视频生成中",
                createdByRunID: request.createdByRunID,
                metadata: metadata.merging(["generationRole": "result"]) { _, new in new }
            ))
        }

        let existingEdges = Set(document.connections.map {
            "\($0.sourceNodeID.uuidString)>\($0.destinationNodeID.uuidString)"
        })
        for sourceID in sourceIDs where sourceID != configurationNodeID {
            let key = "\(sourceID.uuidString)>\(configurationNodeID.uuidString)"
            if !existingEdges.contains(key) {
                operations.append(CanvasPatchOperation(
                    kind: .connect, sourceNodeID: sourceID,
                    destinationNodeID: configurationNodeID,
                    connectionKind: .source, sourcePort: .trailing,
                    destinationPort: .leading, label: "生成输入"
                ))
            }
        }
        let resultEdge = "\(configurationNodeID.uuidString)>\(resultNodeID.uuidString)"
        if !existingEdges.contains(resultEdge) {
            operations.append(CanvasPatchOperation(
                kind: .connect, sourceNodeID: configurationNodeID,
                destinationNodeID: resultNodeID,
                connectionKind: .generatedFrom, sourcePort: .trailing,
                destinationPort: .leading, label: "生成结果"
            ))
        }
        return CanvasGenerationGraphPlan(
            promptNodeID: promptNodeID,
            configurationNodeID: configurationNodeID,
            resultNodeID: resultNodeID,
            sourceNodeIDs: sourceIDs,
            operations: operations
        )
    }
}

public protocol CanvasDocumentRepository: Sendable {
    func project(canvasID: UUID) async throws -> CanvasProject
    func save(_ project: CanvasProject, expectedRevision: Int64) async throws
}
