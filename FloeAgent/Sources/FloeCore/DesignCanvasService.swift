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

public actor DesignCanvasService {
    public typealias CanvasAuthorization = @Sendable (_ runID: UUID?, _ canvasID: UUID) async -> Bool

    public struct Snapshot: Sendable {
        public let canvasID: UUID
        public let nodeID: UUID
        /// The canvas document that contains the node (explicit identity for
        /// generation ownership and editor bindings).
        public let canvasDocumentID: UUID?
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
            canvasDocumentID: Self.document(containing: nodeID, in: project)?.id,
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
        body: @Sendable (inout DesignProject) throws -> Void
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
        let wasCreated = !Self.hasDesignSubdocument(node)
        var design = try DesignCanvasMetadata.loadOrCreate(
            raw: node.metadata[DesignCanvasMetadata.key],
            nodeID: nodeID.uuidString.lowercased(),
            contentType: contentType ?? DesignContentTypeMapper.contentType(for: node.kind)
        )
        // A brand-new subdocument inherits the canvas-level brief/spec
        // authority; an existing one and frozen runs stay untouched.
        Self.inheritProjectAuthority(into: &design, wasCreated: wasCreated, project: project)
        // Replay check strictly before the revision check.
        let containingDocumentID = project.documents[documentIndex].id
        if design.hasApplied(operationID: operationID) {
            return Snapshot(
                canvasID: canvasID,
                nodeID: nodeID,
                canvasDocumentID: containingDocumentID,
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
                canvasID: canvasID, nodeID: nodeID, canvasDocumentID: containingDocumentID,
                canvasRevision: project.revision, nodeKind: node.kind,
                design: design, operationReplayed: true
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
            canvasDocumentID: containingDocumentID,
            canvasRevision: project.revision,
            nodeKind: node.kind,
            design: design,
            operationReplayed: false
        )
    }

    private static func document(containing nodeID: UUID, in project: CanvasProject) -> CanvasDocument? {
        project.documents.first { $0.nodes.contains { $0.id == nodeID } }
    }

    /// Seeds a FRESHLY CREATED design subdocument from the canvas-level
    /// authority (inheritance on new nodes). Existing subdocuments and frozen
    /// run records are never touched.
    private static func inheritProjectAuthority(
        into design: inout DesignProject,
        wasCreated: Bool,
        project: CanvasProject
    ) {
        guard wasCreated, let authority = project.designProjectAuthority else { return }
        design.brief = authority.brief
        design.spec = authority.spec
    }

    /// Whether the node already carries a non-empty design subdocument.
    private static func hasDesignSubdocument(_ node: CanvasNode) -> Bool {
        guard let raw = node.metadata[DesignCanvasMetadata.key] else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The canvas-level project brief/spec authority, when one was set.
    public func projectAuthority(canvasID: UUID) async throws -> DesignProjectAuthority? {
        let project = try await repository.project(canvasID: canvasID)
        return project.designProjectAuthority
    }

    public struct ProjectAuthorityResult: Sendable {
        public let canvasRevision: Int64
        public let authority: DesignProjectAuthority
        /// Nodes updated to carry the new payload in this commit.
        public let updatedNodeIDs: [UUID]
        /// Nodes that could not be updated (corrupt subdocument); they keep
        /// their raw bytes untouched.
        public let skippedNodeIDs: [UUID]
        public let operationReplayed: Bool
    }

    /// Applies (or updates) the canvas-level brief/spec authority in ONE
    /// Canvas CAS: the authority record AND every existing design
    /// subdocument that inherits it commit in the same project save, so the
    /// project revision advances exactly once. Replay is keyed by operationID
    /// AND the FULL payload identity: the same operation with a different
    /// payload is rejected, a repeated identical apply dedupes without a
    /// revision bump. Frozen run records are never modified.
    @discardableResult
    public func applyProjectAuthority(
        runID: UUID? = nil,
        canvasID: UUID,
        expectedRevision: Int64,
        operationID: String,
        brief: DesignBrief?,
        spec: DesignSpec?,
        inheritToExistingNodes: Bool
    ) async throws -> ProjectAuthorityResult {
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        try await requireAuthorization(runID: runID, canvasID: canvasID)
        var project = try await repository.project(canvasID: canvasID)
        let identity = DesignProjectAuthority.identity(brief: brief, spec: spec)
        let existing = project.designProjectAuthority
        if let appliedIdentity = existing?.appliedOperations[operationID] {
            guard appliedIdentity == identity else {
                throw FloeError.validationFailed(
                    "operationID '\(operationID)' was already applied with a different project spec payload"
                )
            }
            return ProjectAuthorityResult(
                canvasRevision: project.revision,
                authority: existing ?? DesignProjectAuthority(brief: brief, spec: spec, contentSHA256: identity),
                updatedNodeIDs: [],
                skippedNodeIDs: [],
                operationReplayed: true
            )
        }
        // Full-payload dedupe: an identical payload (regardless of
        // operationID) that every eligible node already carries is a no-op.
        if let existing, existing.contentSHA256 == identity, !inheritToExistingNodes || Self.allDesignNodesCarry(
            identity: identity, project: project, authorityNodes: Set(existing.inheritedNodeIDs)
        ) {
            return ProjectAuthorityResult(
                canvasRevision: project.revision,
                authority: existing,
                updatedNodeIDs: [],
                skippedNodeIDs: [],
                operationReplayed: true
            )
        }
        guard project.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(expectedRevision), current \(project.revision)"
            )
        }
        var authority = existing ?? DesignProjectAuthority(brief: brief, spec: spec, contentSHA256: identity)
        authority.brief = brief
        authority.spec = spec
        authority.contentSHA256 = identity
        authority.updatedAt = Date()
        var applied = authority.appliedOperations
        applied[operationID] = identity
        if applied.count > 128 {
            // Bounded replay tail: keep the newest 128 keys by insertion of
            // the current one; deterministic pruning of arbitrary oldest
            // entries is acceptable because fingerprints are also embedded in
            // the identity check for the current operation.
            for key in applied.keys.sorted().prefix(applied.count - 128) {
                applied.removeValue(forKey: key)
            }
        }
        authority.appliedOperations = applied

        var updatedNodeIDs: [UUID] = []
        var skippedNodeIDs: [UUID] = []
        if inheritToExistingNodes {
            var inherited: [String] = []
            for documentIndex in project.documents.indices {
                for nodeIndex in project.documents[documentIndex].nodes.indices {
                    let node = project.documents[documentIndex].nodes[nodeIndex]
                    guard Self.hasDesignSubdocument(node) else { continue }
                    guard var design = try? DesignCanvasMetadata.decode(
                        node.metadata[DesignCanvasMetadata.key],
                        nodeID: node.id.uuidString.lowercased()
                    ) else {
                        // Corrupt payload: never rewrite or drop raw bytes.
                        skippedNodeIDs.append(node.id)
                        continue
                    }
                    design.brief = brief
                    design.spec = spec
                    design.updatedAt = Date()
                    // frozenRun is deliberately NOT modified: a frozen run
                    // keeps its own recorded spec hash.
                    guard let raw = try? DesignCanvasMetadata.encode(design) else {
                        skippedNodeIDs.append(node.id)
                        continue
                    }
                    project.documents[documentIndex].nodes[nodeIndex].metadata[DesignCanvasMetadata.key] = raw
                    updatedNodeIDs.append(node.id)
                    inherited.append(node.id.uuidString.lowercased())
                }
            }
            authority.inheritedNodeIDs = inherited
        }
        project.designProjectAuthority = authority
        project.revision = expectedRevision + 1
        project.updatedAt = Date()
        try await repository.save(project, expectedRevision: expectedRevision)
        return ProjectAuthorityResult(
            canvasRevision: project.revision,
            authority: authority,
            updatedNodeIDs: updatedNodeIDs,
            skippedNodeIDs: skippedNodeIDs,
            operationReplayed: false
        )
    }

    private static func allDesignNodesCarry(
        identity: String,
        project: CanvasProject,
        authorityNodes: Set<String>
    ) -> Bool {
        for document in project.documents {
            for node in document.nodes where hasDesignSubdocument(node) {
                guard authorityNodes.contains(node.id.uuidString.lowercased()) else { return false }
                guard let design = try? DesignCanvasMetadata.decode(
                    node.metadata[DesignCanvasMetadata.key],
                    nodeID: node.id.uuidString.lowercased()
                ) else { return false }
                guard DesignProjectAuthority.identity(brief: design.brief, spec: design.spec) == identity else {
                    return false
                }            }
        }
        return true
    }

    public func designState(canvasID: UUID, nodeID: UUID) async throws -> DesignProject? {
        try await snapshot(canvasID: canvasID, nodeID: nodeID).design
    }

    /// Authorized read of the bound Canvas node itself: the current-node
    /// source entry freezes text/asset/workspace-binding content that already
    /// exists on the canvas, so it must read the exact node through the same
    /// authorization as every other design operation.
    public func node(runID: UUID? = nil, canvasID: UUID, nodeID: UUID) async throws -> CanvasNode {
        try await requireAuthorization(runID: runID, canvasID: canvasID)
        let project = try await repository.project(canvasID: canvasID)
        guard let node = Self.node(nodeID, in: project) else {
            throw FloeError.validationFailed("Canvas node \(nodeID.uuidString.lowercased()) does not exist on this canvas")
        }
        return node
    }

    /// Whole-project read-modify-write through the same Canvas CAS. This is
    /// what ADOPTION and RESTORATION use: the design subdocument AND the real
    /// node content (asset reference / text) commit in ONE transaction, so a
    /// candidate is never "adopted" in metadata while the node still shows the
    /// old bytes. Replay-before-conflict and the single revision advance are
    /// identical to `mutate`.
    @discardableResult
    public func mutateProject(
        runID: UUID? = nil,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        contentType: DesignContentType? = nil,
        body: @Sendable (inout CanvasProject, inout DesignProject) async throws -> Void
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
        let wasCreated = !Self.hasDesignSubdocument(node)
        var design = try DesignCanvasMetadata.loadOrCreate(
            raw: node.metadata[DesignCanvasMetadata.key],
            nodeID: nodeID.uuidString.lowercased(),
            contentType: contentType ?? DesignContentTypeMapper.contentType(for: node.kind)
        )
        // New subdocuments inherit the canvas-level authority; existing
        // subdocuments and frozen runs stay untouched.
        Self.inheritProjectAuthority(into: &design, wasCreated: wasCreated, project: project)
        let containingDocumentID = project.documents[documentIndex].id
        // Replay check strictly before the revision check.
        if design.hasApplied(operationID: operationID) {
            return Snapshot(
                canvasID: canvasID,
                nodeID: nodeID,
                canvasDocumentID: containingDocumentID,
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
        _ = DesignWorkflowEngine.recordOperation(operationID, in: &design)
        try await body(&project, &design)
        // Persist the design subdocument next to whatever node content the
        // body committed (find the node again: variant adoption may have
        // added nodes but never removes the original).
        if let updatedIndex = project.documents[documentIndex].nodes.firstIndex(where: { $0.id == nodeID }) {
            project.documents[documentIndex].nodes[updatedIndex].metadata[DesignCanvasMetadata.key] = try DesignCanvasMetadata.encode(design)
        } else {
            project.documents[documentIndex].nodes[nodeIndex].metadata[DesignCanvasMetadata.key] = try DesignCanvasMetadata.encode(design)
        }
        project.revision = expectedRevision + 1
        project.updatedAt = Date()
        try await repository.save(project, expectedRevision: expectedRevision)
        return Snapshot(
            canvasID: canvasID,
            nodeID: nodeID,
            canvasDocumentID: containingDocumentID,
            canvasRevision: project.revision,
            nodeKind: node.kind,
            design: design,
            operationReplayed: false
        )
    }

    private static func node(_ nodeID: UUID, in project: CanvasProject) -> CanvasNode? {
        for document in project.documents {
            if let node = document.nodes.first(where: { $0.id == nodeID }) { return node }
        }
        return nil
    }
}
