// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — Canvas design authority over the EXISTING G09CanvasProjectRepository.
//
// Design state is the shared `canvas.design` node subdocument. Mutations are
// translated into the same node patch the Canvas UI uses, so the repository's
// canonical encode / atomic replace / revision CAS (and its duplicate-op
// receipt) remain the ONE Canvas write path. No second Canvas/design store is
// introduced.
import Foundation
import FloeCore
import FloePersistence

/// `CanvasDocumentRepository` adapter. `DesignCanvasService` reads the real
/// project and asks this adapter to save one patched revision; the adapter
/// diffs only node content/metadata and submits that as a normal Canvas patch.
struct G09R2DesignCanvasDocumentRepository: CanvasDocumentRepository {
    let repository: G09CanvasProjectRepository

    func project(canvasID: UUID) async throws -> CanvasProject {
        try await repository.load(id: canvasID).project
    }

    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        let current = try await repository.load(id: project.id).project
        guard current.revision == expectedRevision else {
            throw G09R2DesignStoreError.conflict(
                expected: expectedRevision, actual: current.revision)
        }
        var operations: [CanvasPatchOperation] = []
        var documentID: UUID?
        for document in project.documents {
            let currentDocument = current.documents.first(where: { $0.id == document.id })
            for node in document.nodes {
                if let existing = currentDocument?.nodes.first(where: { $0.id == node.id }) {
                    if let operation = Self.update(existing: existing, desired: node) {
                        operations.append(operation)
                        if documentID == nil { documentID = document.id }
                    }
                } else {
                    operations.append(Self.create(node))
                    if documentID == nil { documentID = document.id }
                }
            }
            if let currentDocument {
                let desiredIDs = Set(document.nodes.map(\.id))
                let removed = currentDocument.nodes.map(\.id).filter { !desiredIDs.contains($0) }
                if !removed.isEmpty {
                    operations.append(CanvasPatchOperation(
                        kind: .delete, nodeIDs: removed))
                    if documentID == nil { documentID = document.id }
                }
            }
        }
        for document in current.documents
        where !project.documents.contains(where: { $0.id == document.id }) {
            let ids = document.nodes.map(\.id)
            if !ids.isEmpty {
                operations.append(CanvasPatchOperation(kind: .delete, nodeIDs: ids))
            }
        }
        guard !operations.isEmpty, operations.count <= G09CreativeLimits.batchOperations else {
            throw G09R2DesignStoreError.writeFailed
        }
        guard let documentID else {
            throw G09R2DesignStoreError.writeFailed
        }
        let operationSeed = Self.designOperationID(
            project: project, canvasID: project.id, expectedRevision: expectedRevision)
        let patch = CanvasPatch(
            canvasID: project.id,
            documentID: documentID,
            expectedRevision: expectedRevision,
            operations: operations)
        let request = G09CanvasPatchRequest(
            canvasID: project.id,
            expectedRevision: expectedRevision,
            sessionToken: "design-canvas-native",
            opID: operationSeed,
            patch: patch)
        let receipt = try await repository.patch(request)
        guard receipt.revision == expectedRevision + 1 else {
            throw G09R2DesignStoreError.writeFailed
        }
        let committed = try await repository.load(id: project.id).project
        guard committed.revision == receipt.revision else {
            throw G09R2DesignStoreError.writeFailed
        }
        try Self.verify(committed: committed, desired: project)
    }

    private static func create(_ node: CanvasNode) -> CanvasPatchOperation {
        CanvasPatchOperation(
            kind: .create,
            nodeID: node.id,
            nodeKind: node.kind,
            text: node.text,
            position: node.position,
            size: node.size,
            rotation: node.rotation,
            isLocked: node.isLocked,
            shape: node.shape,
            asset: node.asset,
            generationJobID: node.generationJobID,
            createdByRunID: node.createdByRunID,
            metadata: node.metadata)
    }

    private static func update(
        existing: CanvasNode,
        desired: CanvasNode
    ) -> CanvasPatchOperation? {
        var changedMetadata: [String: String] = [:]
        for (key, value) in desired.metadata where existing.metadata[key] != value {
            changedMetadata[key] = value
        }
        let removedKeys = existing.metadata.keys.filter {
            desired.metadata[$0] == nil
        }
        let textChanged = existing.text != desired.text
        let kindChanged = existing.kind != desired.kind
        let positionChanged = existing.position != desired.position
        let sizeChanged = existing.size != desired.size
        let rotationChanged = existing.rotation != desired.rotation
        let lockChanged = existing.isLocked != desired.isLocked
        let shapeChanged = existing.shape != desired.shape
        let assetChanged = existing.asset != desired.asset
        let generationChanged = existing.generationJobID != desired.generationJobID
        let runChanged = existing.createdByRunID != desired.createdByRunID
        guard textChanged || kindChanged || positionChanged || sizeChanged ||
                rotationChanged || lockChanged || shapeChanged || assetChanged ||
                generationChanged || runChanged ||
                !changedMetadata.isEmpty || !removedKeys.isEmpty else {
            return nil
        }
        return CanvasPatchOperation(
            kind: .update,
            nodeID: desired.id,
            nodeKind: kindChanged ? desired.kind : nil,
            text: textChanged ? desired.text : nil,
            position: positionChanged ? desired.position : nil,
            size: sizeChanged ? desired.size : nil,
            rotation: rotationChanged ? desired.rotation : nil,
            isLocked: lockChanged ? desired.isLocked : nil,
            shape: shapeChanged ? desired.shape : nil,
            asset: assetChanged ? desired.asset : nil,
            generationJobID: generationChanged ? desired.generationJobID : nil,
            createdByRunID: runChanged ? desired.createdByRunID : nil,
            metadata: changedMetadata.isEmpty ? nil : changedMetadata,
            removedMetadataKeys: removedKeys.isEmpty ? nil : removedKeys)
    }

    private static func designOperationID(
        project: CanvasProject,
        canvasID: UUID,
        expectedRevision: Int64
    ) -> String {
        var seed = "canvas:\(canvasID.uuidString.lowercased()):\(expectedRevision)"
        for document in project.documents {
            for node in document.nodes {
                guard let raw = node.metadata[DesignCanvasMetadata.key],
                      let design = try? DesignCanvasMetadata.decode(
                        raw, nodeID: node.id.uuidString.lowercased()),
                      let operation = design.appliedOperationIDs.last else {
                    continue
                }
                seed += ":\(operation)"
            }
        }
        let digest = FloeDigest.sha256Hex(Data(seed.utf8))
        return "design-canvas-\(digest.prefix(48))"
    }

    private static func verify(
        committed: CanvasProject,
        desired: CanvasProject
    ) throws {
        for document in desired.documents {
            guard let committedDocument = committed.documents.first(
                where: { $0.id == document.id }) else {
                throw G09R2DesignStoreError.writeFailed
            }
            for node in document.nodes {
                guard let committedNode = committedDocument.nodes.first(
                    where: { $0.id == node.id }) else {
                    throw G09R2DesignStoreError.writeFailed
                }
                guard committedNode.text == node.text,
                      committedNode.asset == node.asset else {
                    throw G09R2DesignStoreError.writeFailed
                }
                if let raw = node.metadata[DesignCanvasMetadata.key] {
                    guard committedNode.metadata[DesignCanvasMetadata.key] == raw else {
                        throw G09R2DesignStoreError.writeFailed
                    }
                    let expected = try DesignCanvasMetadata.decode(
                        raw, nodeID: node.id.uuidString.lowercased())
                    let actual = try DesignCanvasMetadata.decode(
                        committedNode.metadata[DesignCanvasMetadata.key],
                        nodeID: node.id.uuidString.lowercased())
                    guard expected == actual else {
                        throw G09R2DesignStoreError.writeFailed
                    }
                }
            }
        }
    }
}

/// Reads the REAL current content of a Canvas node (text body or retained
/// asset). No synthetic "current" bytes and no stale exported copy are used
/// for freezing a design input.
struct G09R2DesignCanvasContentPort: DesignCanvasContentPort {
    let root: RuntimeStorageRoot
    let assets: G09CreativeAssetHost

    func readNode(
        canvasID: UUID,
        nodeID: UUID,
        snapshot: DesignCanvasService.Snapshot
    ) async throws -> DesignResolvedFile {
        guard let node = snapshot.node else {
            throw DesignTargetError.notFound("canvas node content is unavailable")
        }
        if Self.isTextNode(node) {
            guard !node.text.isEmpty,
                  let format = Self.textFormat(node) else {
                throw DesignTargetError.notFound("canvas node has no text design source")
            }
            let data = Data(node.text.utf8)
            guard !data.isEmpty,
                  Int64(data.count) <= G09R2CreativeLimits.designSourceBytes else {
                throw DesignTargetError.unverifiable("canvas text source is empty or too large")
            }
            return DesignResolvedFile(
                data: data,
                format: format,
                displayName: Self.displayName(nodeID: nodeID, format: format),
                contentSHA256: FloeDigest.sha256Hex(data),
                baseRevisionToken: "canvas-source:\(canvasID.uuidString.lowercased()):\(snapshot.canvasRevision):sha:\(FloeDigest.sha256Hex(data))",
                allowsInPlaceUpdate: true)
        }
        guard let asset = node.asset else {
            throw DesignTargetError.unavailable(
                "canvas node has no retained design source (composition nodes are not design files)")
        }
        guard let record = await assets.record(id: asset.id),
              let relative = record.localRelativePath,
              G09CreativeAssetHost.safeRelativePath(relative),
              let url = assets.materialsURL(relativePath: relative) else {
            throw DesignTargetError.notFound("canvas asset bytes are missing")
        }
        let data = try G09R2DesignFileIO.readBounded(
            url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
        guard !data.isEmpty else {
            throw DesignTargetError.unverifiable("canvas asset is empty")
        }
        let digest = FloeDigest.sha256Hex(data)
        guard record.contentHash.caseInsensitiveCompare(digest) == .orderedSame else {
            throw DesignTargetError.unverifiable("canvas asset digest mismatch")
        }
        if let recorded = asset.contentHash,
           recorded.caseInsensitiveCompare(digest) != .orderedSame {
            throw DesignTargetError.unverifiable("canvas asset reference digest mismatch")
        }
        let format = Self.assetFormat(record: record, asset: asset)
        guard DesignContentType.from(format: format) != nil else {
            throw DesignTargetError.unavailable(
                "canvas asset format '\(format)' has no registered design family")
        }
        return DesignResolvedFile(
            data: data,
            format: format,
            displayName: record.displayName.isEmpty
                ? Self.displayName(nodeID: nodeID, format: format)
                : record.displayName,
            contentSHA256: digest,
            baseRevisionToken: "canvas-source:\(canvasID.uuidString.lowercased()):\(snapshot.canvasRevision):sha:\(digest)",
            allowsInPlaceUpdate: true)
    }

    private static func isTextNode(_ node: CanvasNode) -> Bool {
        if let plugin = node.metadata[DesignContentTypeMapper.builtinPluginMetadataKey],
           DesignContentTypeMapper.textBodyBuiltinPlugins.contains(plugin) {
            return true
        }
        return node.kind == .text || node.kind == .stickyNote
    }

    private static func textFormat(_ node: CanvasNode) -> String? {
        if let plugin = node.metadata[DesignContentTypeMapper.builtinPluginMetadataKey] {
            return DesignContentTypeMapper.builtinPluginFormat(plugin)
        }
        return "md"
    }

    private static func assetFormat(
        record: CreativeAssetRecord,
        asset: CanvasAssetReference
    ) -> String {
        let nameExt = (record.displayName as NSString).pathExtension.lowercased()
        if !nameExt.isEmpty { return nameExt }
        if let relative = record.localRelativePath {
            let ext = (relative as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        if let relative = asset.localRelativePath {
            let ext = (relative as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        let mime = (record.mimeType ?? asset.mimeType ?? "").lowercased()
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "application/pdf": return "pdf"
        case "text/markdown": return "md"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "image/svg+xml": return "svg"
        case "application/json": return "json"
        default: return "bin"
        }
    }

    private static func displayName(nodeID: UUID, format: String) -> String {
        "canvas-\(nodeID.uuidString.lowercased().prefix(8)).\(format)"
    }
}
