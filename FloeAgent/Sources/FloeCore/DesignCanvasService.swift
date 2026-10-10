import Foundation

// FloeCore — Design workflow on the existing Canvas authority.
//
// Design state is a typed subdocument of the bound Canvas node, persisted with
// the same `CanvasDocumentRepository` compare-and-swap used by every other
// Canvas edit (backup/sync/fork/revision conflict included). There is no design
// project store, no temporary fallback and no second project identity: the
// canvas and node IDs are required, binding is verified on decode, and tool
// callers must additionally pass a Canvas authorization closure (run → canvas)
// so an arbitrary UUID cannot reach another canvas.

/// Content type used when a node's design subdocument is first created.
public enum DesignContentTypeMapper {
    public static func contentType(for kind: CanvasNodeKind) -> DesignContentType {
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

/// Single-use, expiring user credential required before an AI-proposed design
/// candidate may be adopted. Grants are minted only by the design panel (a user
/// action) and consumed by `canvas.designAdopt` after its transaction succeeds;
/// the agent cannot mint one, and a failed transaction does not burn it.
public actor DesignAdoptionGrantStore {
    public static let shared = DesignAdoptionGrantStore()

    public struct Grant: Sendable, Equatable {
        public let id: String
        public let canvasID: UUID
        public let nodeID: UUID
        public let candidateID: String
        /// The candidate's base revision at issue time, so the grant cannot be
        /// reused if the artifact moved in the meantime.
        public let baselineRevisionID: String
        public let expiresAt: Date
    }

    private var grants: [String: Grant] = [:]

    public init() {}

    @discardableResult
    public func issue(
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        ttl: TimeInterval = 300
    ) -> Grant {
        let grant = Grant(
            id: UUID().uuidString.lowercased(),
            canvasID: canvasID,
            nodeID: nodeID,
            candidateID: candidateID,
            baselineRevisionID: baselineRevisionID,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        grants[grant.id] = grant
        return grant
    }

    /// Non-consuming validation used before the transaction starts.
    public func validate(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String
    ) -> Bool {
        let now = Date()
        grants = grants.filter { $0.value.expiresAt > now }
        guard let grant = grants[id] else { return false }
        return grant.canvasID == canvasID
            && grant.nodeID == nodeID
            && grant.candidateID == candidateID
            && grant.baselineRevisionID == baselineRevisionID
    }

    /// Consume after a successful transaction. Returns false if the grant was
    /// already used/expired or bound to different inputs.
    @discardableResult
    public func consume(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String
    ) -> Bool {
        guard validate(
            id: id, canvasID: canvasID, nodeID: nodeID,
            candidateID: candidateID, baselineRevisionID: baselineRevisionID
        ) else { return false }
        grants[id] = nil
        return true
    }

    public func revokeAll() { grants.removeAll() }
}

public actor DesignCanvasService {
    public typealias CanvasAuthorization = @Sendable (_ runID: UUID?, _ canvasID: UUID) async -> Bool

    public struct Snapshot: Sendable {
        public let canvasID: UUID
        public let nodeID: UUID
        public let canvasRevision: Int64
        public let nodeKind: CanvasNodeKind
        public let design: DesignProject?
        public let operationReplayed: Bool
    }

    private let repository: CanvasDocumentRepository
    private let authorize: CanvasAuthorization?

    public init(
        repository: CanvasDocumentRepository,
        authorize: CanvasAuthorization? = nil
    ) {
        self.repository = repository
        self.authorize = authorize
    }

    /// Tool callers pass their run ID; a canvas is only reachable when the run
    /// is bound to it. Panel/direct (in-app) callers wire no closure.
    public func requireAuthorization(runID: UUID?, canvasID: UUID) async throws {
        guard let authorize else { return }
        guard await authorize(runID, canvasID) else {
            throw FloeError.validationFailed("This run is not authorized for the requested canvas")
        }
    }

    public func snapshot(runID: UUID? = nil, canvasID: UUID, nodeID: UUID) async throws -> Snapshot {
        try await requireAuthorization(runID: runID, canvasID: canvasID)
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
            design: design,
            operationReplayed: false
        )
    }

    /// Read-modify-write through the Canvas CAS.
    ///
    /// Ordering guarantees:
    /// 1. An already-applied `operationID` returns the current state *before*
    ///    any revision check, so replaying the original request never conflicts.
    /// 2. `expectedRevision` is checked for a genuinely new operation.
    /// 3. The canvas revision advances exactly once per successful mutation.
    @discardableResult
    public func mutate(
        runID: UUID? = nil,
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
        try await requireAuthorization(runID: runID, canvasID: canvasID)
        var project = try await repository.project(canvasID: canvasID)
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
        // Replay check strictly before the revision check.
        if design.hasApplied(operationID: operationID) {
            return Snapshot(
                canvasID: canvasID,
                nodeID: nodeID,
                canvasRevision: project.revision,
                nodeKind: node.kind,
                design: design,
                operationReplayed: true
            )
        }
        guard project.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(expectedRevision), current \(project.revision)"
            )
        }
        guard DesignWorkflowEngine.recordOperation(operationID, in: &design) else {
            // Defensive: recordOperation and hasApplied agree, but never write
            // twice if they were to diverge.
            return Snapshot(
                canvasID: canvasID, nodeID: nodeID, canvasRevision: project.revision,
                nodeKind: node.kind, design: design, operationReplayed: true
            )
        }
        try body(&design)
        design.updatedAt = Date()
        let raw = try DesignCanvasMetadata.encode(design)
        project.documents[documentIndex].nodes[nodeIndex].metadata[DesignCanvasMetadata.key] = raw
        // Advance the canvas revision exactly once, like every other Canvas
        // mutation; the repository's compare-and-swap enforces it.
        project.revision = expectedRevision + 1
        project.updatedAt = Date()
        try await repository.save(project, expectedRevision: expectedRevision)
        return Snapshot(
            canvasID: canvasID,
            nodeID: nodeID,
            canvasRevision: project.revision,
            nodeKind: node.kind,
            design: design,
            operationReplayed: false
        )
    }

    public func designState(canvasID: UUID, nodeID: UUID) async throws -> DesignProject? {
        try await snapshot(canvasID: canvasID, nodeID: nodeID).design
    }

    private static func node(_ nodeID: UUID, in project: CanvasProject) -> CanvasNode? {
        for document in project.documents {
            if let node = document.nodes.first(where: { $0.id == nodeID }) { return node }
        }
        return nil
    }
}
