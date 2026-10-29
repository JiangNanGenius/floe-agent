// Canvas child-project fork lifecycle for copied nodes.
//
// A duplicated/pasted image node must never share the original's mutable
// editable project. The lifecycle is explicit and crash-recoverable:
//
//   1. When copies are created they are synchronously marked `.pending`
//      (parent project id recorded, resolved binding key removed) BEFORE they
//      become visible. A pending node cannot open any editable session.
//   2. A forked project is created off the main actor.
//   3. The result is committed back to the CAPTURED document id (never the
//      live "selected document"), with file revision checks: success writes a
//      resolved valid binding; failure writes an explicit `.failed` marker that
//      retains the parent id for retry. There is no fallback that leaves the
//      copy sharing the parent's mutable project.
//
// These helpers are value-based and unit-testable; the view owns the async
// fork call and the atomic file commit.

import Foundation

public enum CanvasCopyForkPlanner {
    /// Marks freshly created copied nodes as pending forks, capturing the
    /// parent project they must be forked from. Called inside the SAME
    /// synchronous mutation that appends the copies, so a copy is never exposed
    /// with a live (shared) binding.
    public static func markCopiesPending(
        nodes: inout [CanvasNode],
        copyNodeIDs: [UUID],
        startedAt: Date = Date()
    ) {
        for index in nodes.indices where copyNodeIDs.contains(nodes[index].id) {
            // Resolve the parent project from whatever binding the copy
            // inherited. If none, there is nothing to fork (leave as-is).
            guard let inherited = nodes[index].childProjectBinding else { continue }
            let pending = CanvasChildProjectPending(
                parentProjectID: inherited.projectID,
                sourceNodeID: inherited.sourceNodeID,
                startedAt: startedAt)
            nodes[index].setChildProjectPending(.pending(pending))
        }
    }

    public enum Resolution: Sendable {
        case forked(projectID: UUID, revision: Int64)
        case failed(reason: String)
    }

    /// Applies fork resolutions to a captured document snapshot, producing a
    /// new document value. Nodes are resolved by id inside `documentID` only —
    /// the caller must pass the document captured before awaiting, so a
    /// document switch cannot rebind into the wrong canvas. Nodes that have
    /// disappeared (deleted while the fork ran) are skipped; their forks become
    /// orphans the store can prune, but they never mutate another document.
    @discardableResult
    public static func resolve(
        document: inout CanvasDocument,
        resolutions: [UUID: Resolution],
        resolvedAt: Date = Date()
    ) -> (resolvedIDs: Set<UUID>, failedIDs: Set<UUID>, skippedIDs: Set<UUID>) {
        var resolved = Set<UUID>()
        var failed = Set<UUID>()
        var skipped = Set<UUID>()
        for (nodeID, result) in resolutions {
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else {
                skipped.insert(nodeID)
                continue
            }
            // Resolve only a node still waiting on a pending marker. The store
            // resets failed nodes to pending before retrying. A node retargeted
            // or rebound meanwhile is skipped.
            guard case .pending(let pending) = document.nodes[index].childProjectBindingState else {
                skipped.insert(nodeID)
                continue
            }
            switch result {
            case .forked(let projectID, let revision):
                let binding = CanvasChildProjectBinding(
                    projectID: projectID,
                    appliedRevision: revision,
                    draftRevision: revision,
                    renderedAssetID: nil,
                    sourceNodeID: pending.sourceNodeID)
                document.nodes[index].childProjectBinding = binding
                resolved.insert(nodeID)
            case .failed(let reason):
                document.nodes[index].setChildProjectPending(
                    .failed(pending, reason: reason))
                failed.insert(nodeID)
            }
        }
        if !resolved.isEmpty || !failed.isEmpty {
            document.updatedAt = resolvedAt
        }
        return (resolved, failed, skipped)
    }

    /// Collects pending fork requests (node id → parent project) from a
    /// captured document. Used to kick off forks against fixed identities.
    public static func pendingRequests(in document: CanvasDocument) -> [UUID: CanvasChildProjectPending] {
        var map: [UUID: CanvasChildProjectPending] = [:]
        for node in document.nodes {
            if case .pending(let pending) = node.childProjectBindingState {
                map[node.id] = pending
            }
        }
        return map
    }
}

/// Transactional first-edit migration for a legacy flattened image/video node
/// (no child binding yet) toward an editable child project.
///
/// The apply is ONE `CanvasPatchOperation(kind: .update, ...)` carrying the
/// rendered asset, the typed binding and the pending-marker removal, committed
/// through `CanvasCommandService`. Persistence, undo and sync therefore never
/// observe an asset without its binding (or a binding without its asset), and
/// the revision advances exactly once. The node's original flattened asset is
/// never touched until that commit succeeds; the ORIGINAL flatten content hash
/// is recorded in `sourceAssetHash` (not the rendered hash).
///
/// Unknown-newer, malformed or unrecognized raw binding metadata is never
/// overwritten: those nodes must route through an explicit new-node variant.
public enum CanvasChildProjectMigrationPlanner {
    public enum Refusal: Error, LocalizedError, Equatable {
        case nodeMissing
        case missingProject
        case missingRenderedAsset
        case sourceChanged
        case notMigratable(String)

        public var errorDescription: String? {
            switch self {
            case .nodeMissing:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_original_canvas_node_no_longer")
            case .missingProject:
                return FloeL10n.l("core.canvas_copy_fork_planner.no_bindable_editing_project_the_export")
            case .missingRenderedAsset:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_migration_marker_is_missing_the")
            case .sourceChanged:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_node_asset_changed_during_editing")
            case .notMigratable(let detail):
                return FloeL10n.l("core.canvas_copy_fork_planner.this_node_cannot_be_migrated_in", detail)
            }
        }
    }

    /// Serialized `canvas.childProject` metadata entry for a binding.
    public static func encodedBindingEntry(_ binding: CanvasChildProjectBinding) throws -> [String: String] {
        guard let data = try? JSONEncoder().encode(binding),
              let raw = String(data: data, encoding: .utf8) else {
            throw Refusal.notMigratable("binding-encoding")
        }
        return [CanvasNode.childProjectMetadataKey: raw]
    }

    /// The single patch for "update original" / first apply.
    ///
    /// - Parameters:
    ///   - liveNode: the node read from the live project at commit time, not
    ///     the presentation-time capture.
    ///   - capturedSourceAssetHash: the node's asset content hash captured when
    ///     the editor opened. A live asset with a different hash is refused.
    ///   - allowRetryState: true only for the retry commit of a migration
    ///     marker (the node then already carries a `.pending`/`.failed` key
    ///     written by the failed first attempt).
    public static func applyPatch(
        liveNode: CanvasNode?,
        capturedSourceAssetHash: String?,
        renderedAsset: CanvasAssetReference,
        projectID: UUID?,
        projectRevision: Int64,
        extraMetadata: [String: String] = [:],
        allowRetryState: Bool = false
    ) throws -> CanvasPatchOperation {
        guard let liveNode else { throw Refusal.nodeMissing }
        guard let projectID else { throw Refusal.missingProject }
        let originalHash: String?
        switch liveNode.childProjectBindingState {
        case .absent:
            originalHash = capturedSourceAssetHash
        case .valid(let binding):
            originalHash = binding.sourceAssetHash ?? capturedSourceAssetHash
        case .pending, .failed:
            guard allowRetryState else {
                throw Refusal.notMigratable("fork-or-migration-pending")
            }
            originalHash = capturedSourceAssetHash
        case .unknownVersion, .malformed, .unrecognizedStatus:
            // Raw metadata from a newer build is preserved verbatim; the only
            // safe route is an explicit new node.
            throw Refusal.notMigratable("preserved-raw-binding")
        }
        if let captured = capturedSourceAssetHash, !captured.isEmpty,
           liveNode.asset?.contentHash != captured {
            throw Refusal.sourceChanged
        }
        guard liveNode.asset != nil else {
            throw Refusal.notMigratable("no-source-asset")
        }
        let binding = CanvasChildProjectBinding(
            projectID: projectID,
            appliedRevision: projectRevision,
            draftRevision: projectRevision,
            renderedAssetID: renderedAsset.id,
            sourceNodeID: liveNode.id,
            sourceAssetHash: originalHash)
        var metadata = extraMetadata
        metadata[CanvasNode.childProjectMetadataKey] = try encodedBindingEntry(binding)[CanvasNode.childProjectMetadataKey]
        return CanvasPatchOperation(
            kind: .update,
            nodeID: liveNode.id,
            asset: renderedAsset,
            metadata: metadata,
            removedMetadataKeys: [CanvasNode.childProjectPendingMetadataKey])
    }

    /// Failed first-edit commit: keep the node's ORIGINAL asset and record a
    /// retryable marker carrying the exported asset, source hash, project and
    /// revision. Never writes the binding key.
    public static func failedMarkerPatch(
        liveNode: CanvasNode,
        projectID: UUID,
        projectRevision: Int64,
        renderedAsset: CanvasAssetReference,
        sourceAssetHash: String?,
        reason: String
    ) throws -> CanvasPatchOperation {
        let pending = CanvasChildProjectPending(
            parentProjectID: projectID,
            sourceNodeID: liveNode.id,
            renderedAsset: renderedAsset,
            sourceAssetHash: sourceAssetHash,
            appliedRevision: projectRevision)
        guard let raw = PendingWrapper(status: "failed", pending: pending, reason: reason).json else {
            throw Refusal.notMigratable("marker-encoding")
        }
        return CanvasPatchOperation(
            kind: .update,
            nodeID: liveNode.id,
            metadata: [CanvasNode.childProjectPendingMetadataKey: raw])
    }

    /// Retry commit for a migration failed marker. Fork markers (no rendered
    /// asset) must go through `CanvasCopyForkPlanner` resolution instead.
    public static func retryPatch(
        liveNode: CanvasNode?,
        pending: CanvasChildProjectPending,
        extraMetadata: [String: String] = [:]
    ) throws -> CanvasPatchOperation {
        guard let renderedAsset = pending.renderedAsset else {
            throw Refusal.missingRenderedAsset
        }
        return try applyPatch(
            liveNode: liveNode,
            capturedSourceAssetHash: pending.sourceAssetHash,
            renderedAsset: renderedAsset,
            projectID: pending.parentProjectID,
            projectRevision: pending.appliedRevision ?? 0,
            extraMetadata: extraMetadata,
            allowRetryState: true)
    }

    /// Explicit "make variant": a NEW node plus its `generatedFrom` edge and
    /// binding as one patch (one revision). Works from any source state —
    /// including a preserved raw unknown binding — because it never reads or
    /// writes the source node's own binding keys.
    public static func variantPatch(
        sourceNodeID: UUID,
        kind: CanvasNodeKind,
        position: CanvasPoint,
        size: CanvasSize,
        renderedAsset: CanvasAssetReference,
        projectID: UUID,
        projectRevision: Int64,
        sourceAssetHash: String?,
        extraMetadata: [String: String] = [:]
    ) throws -> (nodeID: UUID, operations: [CanvasPatchOperation]) {
        let nodeID = UUID()
        let binding = CanvasChildProjectBinding(
            projectID: projectID,
            appliedRevision: projectRevision,
            draftRevision: projectRevision,
            renderedAssetID: renderedAsset.id,
            sourceNodeID: sourceNodeID,
            sourceAssetHash: sourceAssetHash)
        var metadata = extraMetadata
        metadata[CanvasNode.childProjectMetadataKey] = try encodedBindingEntry(binding)[CanvasNode.childProjectMetadataKey]
        metadata["derivedFromNodeID"] = sourceNodeID.uuidString
        let create = CanvasPatchOperation(
            kind: .create,
            nodeID: nodeID,
            nodeKind: kind,
            position: position,
            size: size,
            asset: renderedAsset,
            metadata: metadata)
        let connect = CanvasPatchOperation(
            kind: .connect,
            sourceNodeID: sourceNodeID,
            destinationNodeID: nodeID,
            connectionKind: .generatedFrom)
        return (nodeID, [create, connect])
    }
}

/// CAD/drawing node semantics inside Canvas. A drawing node is a `.file` node
/// whose asset bytes are a DWG/DXF document. The model is deliberately pure so
/// the app view (which cannot be compiled by the package tests) stays a thin
/// adapter over tested planning logic:
///
///   * `openPlan` computes the deterministic staging path for the editable
///     copy (`CanvasDrafts/<canvas>/<node>/<name>` under the app-controlled
///     media root). The original asset bytes are never edited in place.
///   * `applyPatch` is ONE `CanvasPatchOperation(kind: .update, ...)` that
///     replaces the node asset with the saved drawing bytes while keeping the
///     node identity, text, position, size and edges. The ORIGINAL asset hash
///     is re-checked against the live node, so an externally changed node is
///     refused with the draft preserved.
///   * `variantPatch` creates a NEW `.file` node with provenance plus a
///     `generatedFrom` edge as one patch (one revision).
public enum CanvasDrawingNodePlanner {
    public static let draftRootDirectoryName = "CanvasDrafts"

    /// Canonical app-owned canvas draft root. THE single construction shared
    /// by the editor staging and the Drawing Assistant runtime binding, so
    /// both resolve the identical path string (CAD access equality is
    /// string-based). Returns nil only when Application Support is missing.
    public static func canonicalDraftRoot() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(draftRootDirectoryName, isDirectory: true)
    }

    /// Upper bound for one drawing payload (matches the engineering preview).
    public static let maximumDrawingBytes: Int64 = 32 * 1024 * 1024

    public enum Refusal: Error, LocalizedError, Equatable {
        case notDrawing
        case nodeMissing
        case missingAsset
        case missingSourceHash
        case sourceChanged
        case emptyDrawing

        public var errorDescription: String? {
            switch self {
            case .notDrawing:
                return FloeL10n.l("core.canvas_copy_fork_planner.this_node_is_not_an_editable")
            case .nodeMissing:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_original_canvas_node_no_longer_2")
            case .missingAsset:
                return FloeL10n.l("core.canvas_copy_fork_planner.this_node_has_no_local_drawing")
            case .missingSourceHash:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_drawing_is_missing_its_content")
            case .sourceChanged:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_node_drawing_changed_during_editing")
            case .emptyDrawing:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_drawing_content_is_empty_nothing")
            }
        }
    }

    /// DWG/DXF only: this is the format set the bundled CAD engine can edit
    /// and serialize back. Anything else (STEP/IGES/mesh) is not editable yet.
    public static func drawingExtension(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "dwg", "dxf": return ext
        default: return nil
        }
    }

    public static func isDrawingAsset(_ asset: CanvasAssetReference?) -> Bool {
        drawingExtension(for: asset?.localRelativePath) != nil
    }

    public static func isDrawingNode(_ node: CanvasNode) -> Bool {
        node.kind == .file && node.asset != nil && isDrawingAsset(node.asset)
    }

    /// Persisted sidecar for one staged drawing draft. Kept beside the staged
    /// file so a stale draft is never silently discarded and a draft captured
    /// from a different source revision is never resumed.
    public struct CanvasDrawingDraftDescriptor: Codable, Sendable, Equatable {
        public static let currentSchemaVersion = 1
        public var schemaVersion: Int
        public var canvasID: UUID
        public var nodeID: UUID
        public var sourceAssetID: UUID?
        public var sourceContentHash: String?
        public var sourceRelativePath: String
        /// Service-relative staging path under the draft root.
        public var stagedRelativePath: String
        public var createdAt: Date
        /// Set only after a successful "apply back to canvas": the content hash
        /// the node adopted and the asset it references. A draft with a nil
        /// applied hash is unapplied user work and must never be auto-deleted.
        public var appliedContentHash: String?
        public var appliedAssetID: UUID?
        /// Hash of the staged file bytes after the last durable save. It
        /// diverges from `appliedContentHash` as soon as the user saves new
        /// edits that were not applied to the canvas yet.
        public var stagedContentHash: String?
        /// Monotonic per-node write generation. Descriptor writers use it as a
        /// CAS so an older async write can never overwrite a newer adopted
        /// baseline (e.g. a delayed saved-draft marker after an apply).
        public var generation: Int64?

        public init(schemaVersion: Int = CanvasDrawingDraftDescriptor.currentSchemaVersion,
                    canvasID: UUID, nodeID: UUID, sourceAssetID: UUID?,
                    sourceContentHash: String?, sourceRelativePath: String,
                    stagedRelativePath: String, createdAt: Date = Date(),
                    appliedContentHash: String? = nil,
                    appliedAssetID: UUID? = nil,
                    stagedContentHash: String? = nil,
                    generation: Int64? = nil) {
            self.schemaVersion = schemaVersion
            self.canvasID = canvasID
            self.nodeID = nodeID
            self.sourceAssetID = sourceAssetID
            self.sourceContentHash = sourceContentHash
            self.sourceRelativePath = sourceRelativePath
            self.stagedRelativePath = stagedRelativePath
            self.createdAt = createdAt
            self.appliedContentHash = appliedContentHash
            self.appliedAssetID = appliedAssetID
            self.stagedContentHash = stagedContentHash
            self.generation = generation
        }
    }

    public struct OpenPlan: Sendable, Equatable {
        public var nodeID: UUID
        public var canvasID: UUID
        /// App-root-relative path of the original node asset (Materials/...).
        public var sourceRelativePath: String
        public var sourceContentHash: String?
        /// Staging-root-relative editable copy path.
        public var stagedRelativePath: String
        public var fileExtension: String
        public var descriptor: CanvasDrawingDraftDescriptor
    }

    /// Deterministic, contained staging path. The basename is sanitized so no
    /// caller-controlled path component can escape the draft root.
    public static func openPlan(
        node: CanvasNode,
        canvasID: UUID,
        sourceRelativePath: String? = nil
    ) throws -> OpenPlan {
        guard isDrawingNode(node) else { throw Refusal.notDrawing }
        guard let asset = node.asset else { throw Refusal.missingAsset }
        guard let source = sourceRelativePath ?? asset.localRelativePath, !source.isEmpty else {
            throw Refusal.missingAsset
        }
        guard let ext = drawingExtension(for: source) else { throw Refusal.notDrawing }
        let directory = "\(canvasID.uuidString.lowercased())/\(node.id.uuidString.lowercased())"
        let staged = "\(directory)/\(sanitizedDrawingName(source, extension: ext))"
        let descriptor = CanvasDrawingDraftDescriptor(
            canvasID: canvasID, nodeID: node.id,
            sourceAssetID: asset.id, sourceContentHash: asset.contentHash,
            sourceRelativePath: source, stagedRelativePath: staged)
        return OpenPlan(
            nodeID: node.id, canvasID: canvasID,
            sourceRelativePath: source, sourceContentHash: asset.contentHash,
            stagedRelativePath: staged, fileExtension: ext,
            descriptor: descriptor)
    }

    /// A draft is resumable only when it was staged from the exact source
    /// revision the node still carries. A mismatch keeps the old draft on
    /// disk untouched and stages a fresh copy instead of discarding either.
    public static func shouldResumeDraft(
        _ descriptor: CanvasDrawingDraftDescriptor?,
        liveSourceHash: String?
    ) -> Bool {
        guard let descriptor, descriptor.schemaVersion <= CanvasDrawingDraftDescriptor.currentSchemaVersion,
              let liveSourceHash, !liveSourceHash.isEmpty,
              descriptor.sourceContentHash == liveSourceHash else { return false }
        return true
    }

    /// A distinct name for a second staged copy while an older draft for a
    /// different source revision is preserved beside it.
    public static func alternateStagedRelativePath(
        _ plan: OpenPlan,
        contentHash: String?
    ) -> String {
        let suffix = String((contentHash ?? UUID().uuidString).prefix(8))
        let directory = (plan.stagedRelativePath as NSString).deletingLastPathComponent
        let base = (plan.stagedRelativePath as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return "\(directory)/\(stem.isEmpty ? "drawing" : stem)-\(suffix).\(plan.fileExtension)"
    }

    /// The single patch for "apply back to canvas": replace the asset with the
    /// saved drawing bytes, keep every other node field, record the ORIGINAL
    /// source hash for compare and never rewrite the node kind.
    public static func applyPatch(
        liveNode: CanvasNode?,
        capturedSourceAssetHash: String?,
        renderedAsset: CanvasAssetReference,
        extraMetadata: [String: String] = [:]
    ) throws -> CanvasPatchOperation {
        guard let liveNode else { throw Refusal.nodeMissing }
        guard isDrawingNode(liveNode), let liveAsset = liveNode.asset else {
            throw Refusal.notDrawing
        }
        guard let captured = capturedSourceAssetHash, !captured.isEmpty,
              let liveHash = liveAsset.contentHash, !liveHash.isEmpty else {
            throw Refusal.missingSourceHash
        }
        guard liveHash == captured else { throw Refusal.sourceChanged }
        guard let newHash = renderedAsset.contentHash, !newHash.isEmpty,
              drawingExtension(for: renderedAsset.localRelativePath) != nil else {
            throw Refusal.emptyDrawing
        }
        var metadata = extraMetadata
        metadata["drawingEditor"] = "engineering"
        metadata["drawingSourceHash"] = captured
        metadata["drawingContentHash"] = newHash
        return CanvasPatchOperation(
            kind: .update,
            nodeID: liveNode.id,
            asset: renderedAsset,
            metadata: metadata)
    }

    /// Explicit "make variant": a NEW `.file` node plus its `generatedFrom`
    /// edge as one patch (one revision). The source node is never touched.
    public static func variantPatch(
        sourceNodeID: UUID,
        drawingAsset: CanvasAssetReference,
        position: CanvasPoint,
        size: CanvasSize,
        sourceAssetHash: String?,
        extraMetadata: [String: String] = [:]
    ) throws -> (nodeID: UUID, operations: [CanvasPatchOperation]) {
        guard drawingExtension(for: drawingAsset.localRelativePath) != nil,
              let contentHash = drawingAsset.contentHash, !contentHash.isEmpty else {
            throw Refusal.emptyDrawing
        }
        let nodeID = UUID()
        var metadata = extraMetadata
        metadata["derivedFromNodeID"] = sourceNodeID.uuidString
        metadata["drawingEditor"] = "engineering"
        metadata["drawingVariant"] = "true"
        if let sourceAssetHash, !sourceAssetHash.isEmpty {
            metadata["drawingSourceHash"] = sourceAssetHash
        }
        metadata["drawingContentHash"] = contentHash
        let create = CanvasPatchOperation(
            kind: .create,
            nodeID: nodeID,
            nodeKind: .file,
            position: position,
            size: size,
            asset: drawingAsset,
            metadata: metadata)
        let connect = CanvasPatchOperation(
            kind: .connect,
            sourceNodeID: sourceNodeID,
            destinationNodeID: nodeID,
            connectionKind: .generatedFrom)
        return (nodeID, [create, connect])
    }

    private static func sanitizedDrawingName(_ source: String, extension ext: String) -> String {
        let base = (source as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        var cleaned = String(stem.map { character in
            (character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-")
                ? character : "-"
        })
        cleaned = cleaned.replacingOccurrences(of: "..", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)) }
        if cleaned.isEmpty { cleaned = "drawing" }
        return "\(cleaned).\(ext)"
    }
}

/// Draft-continuity policy for the Canvas CAD editor. Pure decisions so the
/// view can never silently lose unsaved edits:
///
///   * a staged draft may be resumed only when it was captured from the exact
///     node revision still on the canvas;
///   * when the node changed externally, a dirty session must be serialized
///     to its durable staged file first, then the old draft is preserved on
///     disk while a fresh editable copy is staged for the new revision;
///   * staging may only be auto-deleted when the descriptor records a
///     successful apply AND the node still carries exactly those bytes.
public enum CanvasDrawingDraftContinuity {
    public enum ResumeDecision: Equatable, Sendable {
        /// Same source revision: resume the existing draft/session.
        case resume
        /// The draft belongs to another revision. `serializeFirst` is true
        /// when live edits are still only in Web memory and MUST be written
        /// to the durable staged file before the session is replaced.
        case replacePreservingDraft(serializeFirst: Bool)
        /// No usable draft metadata: stage a fresh editable copy.
        case fresh
    }

    public static func resumeDecision(
        existingSourceHash: String?,
        liveSourceHash: String?,
        sessionDirty: Bool
    ) -> ResumeDecision {
        guard let existing = existingSourceHash, !existing.isEmpty else { return .fresh }
        guard let live = liveSourceHash, !live.isEmpty else {
            return .replacePreservingDraft(serializeFirst: sessionDirty)
        }
        if existing == live { return .resume }
        return .replacePreservingDraft(serializeFirst: sessionDirty)
    }

    /// A staged draft is provably redundant only when it was recorded as
    /// applied AND the node still carries exactly those applied bytes AND the
    /// staged file has not changed since (saved-but-unapplied edits diverge
    /// the staged hash from the applied hash and are therefore preserved).
    public static func isProvablyApplied(
        appliedContentHash: String?,
        stagedContentHash: String? = nil,
        liveSourceHash: String?
    ) -> Bool {
        guard let applied = appliedContentHash, !applied.isEmpty,
              let live = liveSourceHash, !live.isEmpty else { return false }
        if let staged = stagedContentHash, !staged.isEmpty, staged != applied {
            return false
        }
        return applied == live
    }

    public static let defaultDraftBudgetBytes: Int64 = 256 * 1024 * 1024

    /// Explicit maintenance reporting instead of silent deletion when the
    /// preserved (unapplied) drafts exceed the budget.
    public static func maintenanceNotice(
        draftCount: Int,
        totalBytes: Int64,
        budgetBytes: Int64 = defaultDraftBudgetBytes
    ) -> String? {
        guard draftCount > 0, totalBytes > budgetBytes, budgetBytes > 0 else { return nil }
        let totalMB = totalBytes / (1024 * 1024)
        let budgetMB = budgetBytes / (1024 * 1024)
        return FloeL10n.l("core.canvas_copy_fork_planner.drawing_drafts_take_mb_files_over", totalMB, draftCount, budgetMB)
    }

    // MARK: Deterministic serialization + teardown decisions

    /// How the registry must flush a live session before it can be released.
    public enum SerializationPlan: Equatable, Sendable {
        case noop
        case requestSave
        case unavailable
    }

    public static func serializationPlan(
        isDirty: Bool,
        supportsRequestSave: Bool
    ) -> SerializationPlan {
        guard isDirty else { return .noop }
        return supportsRequestSave ? .requestSave : .unavailable
    }

    /// A session whose durable flush failed must NEVER be released: the
    /// registry/service retains it for retry instead of tearing it down.
    public enum SessionRetention: Equatable, Sendable {
        case release
        case retainForRetry
    }

    public static func sessionRetentionDecision(
        flushSucceeded: Bool
    ) -> SessionRetention {
        flushSucceeded ? .release : .retainForRetry
    }

    /// True when a session's saved staged bytes differ from both its adopted
    /// baseline and the node's current source hash: a saved but unapplied
    /// draft that a restore must not consume. The restore guard uses this so
    /// unflushed/unapplied user work is never silently replaced.
    public static func hasUnappliedDraft(
        stagedContentHash: String?,
        appliedContentHash: String?,
        sourceContentHash: String?
    ) -> Bool {
        guard let staged = stagedContentHash, !staged.isEmpty else { return false }
        if let applied = appliedContentHash, staged == applied { return false }
        if let source = sourceContentHash, staged == source { return false }
        return true
    }

    /// CAS merge for descriptor writes. `nil` means reject the write (a newer
    /// generation already landed, or a stale same-generation write would
    /// clear a recorded applied baseline). The writer actor calls this so
    /// delayed async writes can never regress an adopted apply.
    public static func mergedDescriptor(
        current: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor?,
        incoming: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor
    ) -> CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor? {
        let currentGeneration = current?.generation ?? 0
        let incomingGeneration = incoming.generation ?? 0
        guard incomingGeneration >= currentGeneration else { return nil }
        if incomingGeneration == currentGeneration,
           current?.appliedContentHash != nil,
           incoming.appliedContentHash == nil {
            return nil
        }
        return incoming
    }
}
