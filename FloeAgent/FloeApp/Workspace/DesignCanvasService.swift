// FloeApp — Design workflow on the existing Canvas authority.
//
// Design state is a typed subdocument of the bound Canvas node, persisted with
// the same `FileCanvasDocumentRepository` + `CanvasProjectFileWriter` CAS used
// by every other Canvas edit (backup/sync/fork/revision conflict included).
// There is no design project store, no temporary fallback and no second project
// identity: the canvas and node IDs are required and validated on every access.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

/// Single-use, expiring user credential required before an AI-proposed design
/// candidate may be adopted. Grants are minted only by the design panel (a user
/// action) and consumed by `canvas.designAdopt`; the agent cannot mint one.
actor DesignAdoptionGrantStore {
    static let shared = DesignAdoptionGrantStore()

    struct Grant: Sendable, Equatable {
        let id: String
        let canvasID: UUID
        let nodeID: UUID
        let candidateID: String
        let expiresAt: Date
    }

    private var grants: [String: Grant] = [:]

    @discardableResult
    func issue(canvasID: UUID, nodeID: UUID, candidateID: String, ttl: TimeInterval = 300) -> Grant {
        let grant = Grant(
            id: UUID().uuidString.lowercased(),
            canvasID: canvasID,
            nodeID: nodeID,
            candidateID: candidateID,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        grants[grant.id] = grant
        return grant
    }

    func consume(id: String, canvasID: UUID, nodeID: UUID, candidateID: String) -> Bool {
        let now = Date()
        grants = grants.filter { $0.value.expiresAt > now }
        guard let grant = grants[id],
              grant.canvasID == canvasID,
              grant.nodeID == nodeID,
              grant.candidateID == candidateID else { return false }
        grants[id] = nil
        return true
    }

    func revokeAll() { grants.removeAll() }
}

/// Which content type a bound node's design state uses when first created.
enum DesignContentTypeMapper {
    static func contentType(for kind: CanvasNodeKind) -> DesignContentType {
        switch kind {
        case .image: return .image
        case .video: return .video
        case .text, .stickyNote: return .notes
        case .file: return .pdf
        case .scene3D: return .cad
        case .card, .shape, .group, .generationTask, .audio: return .webpage
        }
    }
}

actor DesignCanvasService {
    struct Snapshot: Sendable {
        let canvasID: UUID
        let nodeID: UUID
        let canvasRevision: Int64
        let nodeKind: CanvasNodeKind
        let design: DesignProject?
    }

    private let repository: CanvasDocumentRepository

    init(repository: CanvasDocumentRepository = FileCanvasDocumentRepository()) {
        self.repository = repository
    }

    func snapshot(canvasID: UUID, nodeID: UUID) async throws -> Snapshot {
        let project = try await repository.project(canvasID: canvasID)
        guard let node = Self.node(nodeID, in: project) else {
            throw FloeError.validationFailed("Canvas node \(nodeID.uuidString.lowercased()) does not exist on this canvas")
        }
        let design = try DesignCanvasMetadata.decode(
            node.metadata[DesignCanvasMetadata.key],
            nodeID: nodeID.uuidString.lowercased()
        )
        return Snapshot(
            canvasID: canvasID,
            nodeID: nodeID,
            canvasRevision: project.revision,
            nodeKind: node.kind,
            design: design
        )
    }

    /// Read-modify-write through the Canvas CAS. `operationID` (required for
    /// mutations) makes replays a no-op. `expectedRevision` is the canvas
    /// revision the caller read; a mismatch surfaces as a conflict.
    @discardableResult
    func mutate(
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        contentType: DesignContentType? = nil,
        body: (inout DesignProject) throws -> Void
    ) async throws -> Snapshot {
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        var project = try await repository.project(canvasID: canvasID)
        guard project.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(expectedRevision), current \(project.revision)"
            )
        }
        guard let documentIndex = project.documents.firstIndex(where: { document in
            document.nodes.contains { $0.id == nodeID }
        }), let nodeIndex = project.documents[documentIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw FloeError.validationFailed("Canvas node \(nodeID.uuidString.lowercased()) does not exist on this canvas")
        }
        let node = project.documents[documentIndex].nodes[nodeIndex]
        var design = try DesignCanvasMetadata.loadOrCreate(
            raw: node.metadata[DesignCanvasMetadata.key],
            nodeID: nodeID.uuidString.lowercased(),
            contentType: contentType ?? DesignContentTypeMapper.contentType(for: node.kind)
        )
        guard DesignWorkflowEngine.recordOperation(operationID, in: &design) else {
            // Already applied: return the current state without a second write.
            return Snapshot(
                canvasID: canvasID,
                nodeID: nodeID,
                canvasRevision: project.revision,
                nodeKind: node.kind,
                design: design
            )
        }
        try body(&design)
        design.updatedAt = Date()
        let raw = try DesignCanvasMetadata.encode(design)
        project.documents[documentIndex].nodes[nodeIndex].metadata[DesignCanvasMetadata.key] = raw
        // Advance the canvas revision exactly once, like every other Canvas
        // mutation; the writer's compare-and-swap enforces it.
        project.revision = expectedRevision + 1
        project.updatedAt = Date()
        try await repository.save(project, expectedRevision: expectedRevision)
        return Snapshot(
            canvasID: canvasID,
            nodeID: nodeID,
            canvasRevision: project.revision,
            nodeKind: node.kind,
            design: design
        )
    }

    /// Read-only convenience for tools that only inspect state.
    func designState(canvasID: UUID, nodeID: UUID) async throws -> DesignProject? {
        try await snapshot(canvasID: canvasID, nodeID: nodeID).design
    }

    private static func node(_ nodeID: UUID, in project: CanvasProject) -> CanvasNode? {
        for document in project.documents {
            if let node = document.nodes.first(where: { $0.id == nodeID }) { return node }
        }
        return nil
    }
}
#endif
