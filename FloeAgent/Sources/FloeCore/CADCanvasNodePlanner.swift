// Canvas node semantics for a native FloeCAD `.floecad` document.
//
// A native CAD node is a `.file` node whose asset is a FloeCAD package. This
// planner is the native counterpart of `CanvasDrawingNodePlanner` for the 2D
// DWG/DXF flow and follows the same contract:
//
//   * `applyPatch` is ONE `CanvasPatchOperation(kind: .update, ...)` that
//     replaces the node's rendered asset while preserving node identity,
//     text, position, size, rotation, locking and edges. It records the
//     ORIGINAL package hash (`sourceAssetHash`) for a compare-and-refuse and
//     appends the new render to the node's typed CAD revision history.
//   * `variantPatch` creates a NEW `.file` node with the generated asset plus
//     a `generatedFrom` edge as one patch (one revision). The source node is
//     never touched.
//
// The model is deliberately pure so the app view stays a thin adapter: the
// view owns the async export and the atomic file commit.

import Foundation

public enum CADCanvasNodePlanner {
    /// Canonical metadata keys carried by a native CAD canvas node.
    public enum MetadataKeys {
        /// App-relative or workspace-relative path of the source `.floecad`
        /// package the node was derived from.
        public static let sourcePath = "canvas.nativeCAD.sourcePath"
        /// Content hash (SHA-256 hex) of the source package when the node was
        /// last applied. The compare-and-refuse identity for re-apply.
        public static let sourceHash = "canvas.nativeCAD.sourceHash"
        /// Editor marker for the native workbench entry.
        public static let editor = "editor"
        /// Whether the node was created as an explicit variant.
        public static let variant = "nativeCADVariant"
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case nodeMissing
        case notCADNode
        case missingAsset
        case missingSourceHash
        case missingSourcePath
        case sourceChanged
        case emptyRender
        case historyUnsupported

        public var errorDescription: String? {
            switch self {
            case .nodeMissing:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_original_canvas_node_no_longer")
            case .notCADNode:
                return FloeL10n.l("core.canvas_copy_fork_planner.this_node_is_not_an_editable")
            case .missingAsset:
                return FloeL10n.l("core.canvas_copy_fork_planner.this_node_has_no_local_drawing")
            case .missingSourceHash:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_drawing_is_missing_its_content")
            case .missingSourcePath:
                return "The CAD document has no source path to bind the canvas node to."
            case .sourceChanged:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_node_drawing_changed_during_editing")
            case .emptyRender:
                return FloeL10n.l("core.canvas_copy_fork_planner.the_drawing_content_is_empty_nothing")
            case .historyUnsupported:
                return "This node carries CAD history from a newer version; it is preserved and not overwritten."
            }
        }
    }

    /// `.floecad` package extension on a node asset path.
    public static func nativeCADExtension(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "floecad" ? ext : nil
    }

    public static func isNativeCADAsset(_ asset: CanvasAssetReference?) -> Bool {
        nativeCADExtension(for: asset?.localRelativePath) != nil
    }

    /// A `.file` node whose asset is a native FloeCAD package, or a node that
    /// already carries the native CAD metadata (after an apply its live asset
    /// is the PNG render, not the package).
    public static func isNativeCADNode(_ node: CanvasNode) -> Bool {
        if node.kind == .file, isNativeCADAsset(node.asset) { return true }
        return node.metadata[MetadataKeys.sourcePath] != nil
    }

    /// Identity hash recorded when the native document was last applied, if
    /// any. Falls back to the node's current asset hash (first apply).
    public static func capturedSourceHash(for node: CanvasNode) -> String? {
        if let recorded = node.metadata[MetadataKeys.sourceHash], !recorded.isEmpty {
            return recorded
        }
        return node.asset?.contentHash
    }

    /// The single patch for "Apply to canvas": replace the rendered asset,
    /// keep every other node field, record the original source identity and
    /// append the render to the node's CAD revision history in ONE operation.
    public static func applyPatch(
        liveNode: CanvasNode?,
        sourcePath: String,
        capturedSourceAssetHash: String?,
        renderedAsset: CanvasAssetReference,
        extraMetadata: [String: String] = [:]
    ) throws -> CanvasPatchOperation {
        guard let liveNode else { throw Refusal.nodeMissing }
        guard isNativeCADNode(liveNode) else { throw Refusal.notCADNode }
        guard let liveAsset = liveNode.asset else { throw Refusal.missingAsset }
        guard let captured = capturedSourceAssetHash, !captured.isEmpty else {
            throw Refusal.missingSourceHash
        }
        // The live asset may be the source package (first apply) or the last
        // render (re-apply, identity recorded in metadata). Either way the
        // recorded identity must still match — an externally changed node is
        // refused instead of silently overwritten.
        let matchesLiveAsset = liveAsset.contentHash == captured
        let matchesRecorded = liveNode.metadata[MetadataKeys.sourceHash] == captured
        guard matchesLiveAsset || matchesRecorded else { throw Refusal.sourceChanged }
        guard let renderHash = renderedAsset.contentHash, !renderHash.isEmpty,
              let renderPath = renderedAsset.localRelativePath, !renderPath.isEmpty else {
            throw Refusal.emptyRender
        }
        var metadata = extraMetadata
        metadata[MetadataKeys.sourcePath] = sourcePath
        metadata[MetadataKeys.sourceHash] = captured
        metadata[MetadataKeys.editor] = "native-cad"
        if let history = updatedHistory(liveNode: liveNode,
                                        sourcePath: sourcePath,
                                        capturedHash: captured,
                                        renderedAsset: renderedAsset) {
            metadata[CanvasDrawingRevisionHistory.metadataKey] = history
        }
        return CanvasPatchOperation(
            kind: .update,
            nodeID: liveNode.id,
            asset: renderedAsset,
            metadata: metadata)
    }

    /// Explicit "Add to canvas" when NO node references the source package
    /// yet: ONE `.create` patch for a `.file` node bound to the package
    /// through its metadata (sourcePath + sourceHash), with the exported
    /// render as its live asset and a seeded CAD revision history. No source
    /// node is read or modified, and no `generatedFrom` edge is invented —
    /// the destination canvas/document is the caller's explicit choice.
    public static func createPatch(
        sourcePath: String,
        sourceAssetHash: String,
        renderedAsset: CanvasAssetReference,
        position: CanvasPoint,
        size: CanvasSize,
        text: String? = nil,
        extraMetadata: [String: String] = [:]
    ) throws -> CanvasPatchOperation {
        guard !sourcePath.isEmpty else { throw Refusal.missingSourcePath }
        guard !sourceAssetHash.isEmpty else { throw Refusal.missingSourceHash }
        guard let renderHash = renderedAsset.contentHash, !renderHash.isEmpty,
              let renderPath = renderedAsset.localRelativePath, !renderPath.isEmpty else {
            throw Refusal.emptyRender
        }
        var metadata = extraMetadata
        metadata[MetadataKeys.sourcePath] = sourcePath
        metadata[MetadataKeys.sourceHash] = sourceAssetHash
        metadata[MetadataKeys.editor] = "native-cad"
        let seed = CanvasDrawingRevision(
            assetID: renderedAsset.id,
            contentHash: renderHash,
            relativePath: renderPath,
            byteCount: renderedAsset.byteCount ?? 0,
            kind: .original,
            label: nil)
        if let history = try? CanvasDrawingRevisionHistory.metadata([seed]) {
            metadata[CanvasDrawingRevisionHistory.metadataKey] =
                history[CanvasDrawingRevisionHistory.metadataKey]
        }
        return CanvasPatchOperation(
            kind: .create,
            nodeID: UUID(),
            nodeKind: .file,
            text: text,
            position: position,
            size: size,
            asset: renderedAsset,
            metadata: metadata)
    }

    /// Explicit "Make variant": a NEW `.file` node plus its `generatedFrom`
    /// edge and a fresh CAD revision history as one patch (one revision).
    /// Works from any source state (bound or not); the source node is never
    /// read for binding keys and never modified.
    public static func variantPatch(
        sourceNodeID: UUID,
        sourcePath: String,
        capturedSourceAssetHash: String?,
        renderedAsset: CanvasAssetReference,
        position: CanvasPoint,
        size: CanvasSize,
        text: String? = nil,
        extraMetadata: [String: String] = [:]
    ) throws -> (nodeID: UUID, operations: [CanvasPatchOperation]) {
        guard let renderHash = renderedAsset.contentHash, !renderHash.isEmpty,
              let renderPath = renderedAsset.localRelativePath, !renderPath.isEmpty else {
            throw Refusal.emptyRender
        }
        let nodeID = UUID()
        var metadata = extraMetadata
        metadata[MetadataKeys.sourcePath] = sourcePath
        metadata[MetadataKeys.editor] = "native-cad"
        metadata[MetadataKeys.variant] = "true"
        metadata["derivedFromNodeID"] = sourceNodeID.uuidString
        if let captured = capturedSourceAssetHash, !captured.isEmpty {
            metadata[MetadataKeys.sourceHash] = captured
        }
        let seed = CanvasDrawingRevision(
            assetID: renderedAsset.id,
            contentHash: renderHash,
            relativePath: renderPath,
            byteCount: renderedAsset.byteCount ?? 0,
            kind: .variant,
            label: nil)
        if let history = try? CanvasDrawingRevisionHistory.metadata([seed]) {
            metadata[CanvasDrawingRevisionHistory.metadataKey] =
                history[CanvasDrawingRevisionHistory.metadataKey]
        }
        let create = CanvasPatchOperation(
            kind: .create,
            nodeID: nodeID,
            nodeKind: .file,
            text: text,
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

    /// Appends the newly rendered asset to the node's typed CAD revision
    /// history. `nil` when the node's history is preserved (unsupported raw
    /// metadata) or absent — never overwrites unusable history.
    private static func updatedHistory(
        liveNode: CanvasNode,
        sourcePath: String,
        capturedHash: String,
        renderedAsset: CanvasAssetReference
    ) -> String? {
        guard let renderHash = renderedAsset.contentHash,
              let renderPath = renderedAsset.localRelativePath else { return nil }
        var revisions: [CanvasDrawingRevision]
        switch CanvasDrawingRevisionHistory.read(from: liveNode) {
        case .absent:
            revisions = []
            // Lazily seed the original package from the node's current asset
            // so the history can always be reverted to the source document.
            if let asset = liveNode.asset,
               let hash = asset.contentHash, !hash.isEmpty,
               let path = asset.localRelativePath,
               CanvasDrawingRevisionHistory.isValidStoredPath(path) {
                revisions.append(CanvasDrawingRevision(
                    assetID: asset.id, contentHash: hash,
                    relativePath: path, byteCount: asset.byteCount ?? 0,
                    kind: .original,
                    label: nil))
            }
        case .usable(let list):
            revisions = list
        case .unsupported:
            return nil
        }
        // The same render applied twice is idempotent: keep only one entry.
        revisions.removeAll { revision in
            revision.assetID == renderedAsset.id && revision.contentHash == renderHash
        }
        revisions.append(CanvasDrawingRevision(
            assetID: renderedAsset.id,
            contentHash: renderHash,
            relativePath: renderPath,
            byteCount: renderedAsset.byteCount ?? 0,
            kind: .adopt,
            label: nil))
        guard let encoded = try? CanvasDrawingRevisionHistory.metadata(revisions),
              let raw = encoded[CanvasDrawingRevisionHistory.metadataKey] else {
            return nil
        }
        return raw
    }
}

/// The ONE binding-key vocabulary shared by the app-side canvas CAD storage,
/// the export/import rewrite and the node planner: `canvas-cad:<canvasUUID>/
/// <packageFileName>`. Parsing is strict (UUID, no separators/traversal) so a
/// corrupted key can never resolve outside its canvas namespace.
public enum CanvasCADBindingKey {
    public static let prefix = "canvas-cad:"

    public static func key(canvasID: UUID, packageFileName: String) -> String {
        "\(prefix)\(canvasID.uuidString)/\(packageFileName)"
    }

    public static func parse(_ key: String) -> (canvasID: UUID, packageFileName: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = String(key.dropFirst(prefix.count))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let canvasID = UUID(uuidString: parts[0]) else { return nil }
        let fileName = (parts[1] as NSString).lastPathComponent
        guard fileName == parts[1], !fileName.isEmpty, fileName.hasSuffix(".floecad") else {
            return nil
        }
        return (canvasID, fileName)
    }

    public static func isCanvasOwned(_ key: String?) -> Bool {
        guard let key else { return false }
        return parse(key) != nil
    }
}
