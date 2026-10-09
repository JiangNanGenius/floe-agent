// SPDX-License-Identifier: MPL-2.0
// FloeApp — Canvas entry path for the native `.floecad` CAD workbench.
//
// Mirrors the 2D drawing flow (`CanvasDrawingEditorSheet.applyToCanvas` /
// `makeVariant`): the native workbench exports its REAL projected drawing
// page as a PNG asset (offscreen CoreGraphics through `CADDrawingService`),
// persists it into the app-owned material library and commits it into the
// canvas with the SAME atomic patch primitives the 2D flow uses
// (`CADCanvasNodePlanner` + `CanvasCommandService.applying` +
// `CanvasProjectFileWriter.compareAndSwap`):
//
//   * "Apply to canvas" updates the ORIGINAL bound node in place — identity,
//     name, position, size and edges are preserved; only its rendered asset
//     and typed CAD metadata change, in ONE revision.
//   * "Make variant" is the only path that creates a NEW `.file` node plus a
//     `generatedFrom` edge; the original node is never modified.
//
// The bridge refuses honestly when no canvas node references the source
// package (nothing is guessed and no parallel node path is created), and it
// runs its own bounded CAS retry so a concurrent canvas writer is never
// overwritten silently.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCAD
import FloeCore
import FloePersistence

@MainActor
enum CADCanvasActionBridge {

    /// A located target: the canvas project file plus the exact node id of
    /// the node whose asset references the source package.
    private struct Target {
        let canvasID: UUID
        let project: CanvasProject
        let documentID: UUID
        let nodeID: UUID
    }

    /// The host-installed actions for `FloeCADWorkbenchView`. The operation
    /// closures receive the exact resolved package URL from the workbench.
    static func actions(assetStore: CreativeAssetStore) -> CADCanvasActions {
        CADCanvasActions(
            applyToCanvas: { document, url in
                await applyToCanvas(document: document, url: url, assetStore: assetStore)
            },
            makeVariant: { document, url in
                await makeVariant(document: document, url: url, assetStore: assetStore)
            },
            createTargets: {
                Self.explicitCreateTargets()
            },
            createNode: { document, url, choice in
                await createNodeInCanvas(document: document, url: url,
                                         choice: choice, assetStore: assetStore)
            })
    }

    /// Every canvas document the user can explicitly pick — no "first canvas"
    /// guessing. The token encodes canvas + document; `createNodeInCanvas`
    /// parses it back and validates both still exist before writing.
    private static func explicitCreateTargets() -> [CADCanvasActions.TargetChoice] {
        var choices: [CADCanvasActions.TargetChoice] = []
        for summary in WorkspaceCanvasRegistry.summaries() {
            guard let project = try? WorkspaceCanvasRegistry.project(canvasID: summary.id) else { continue }
            for document in project.documents {
                choices.append(CADCanvasActions.TargetChoice(
                    id: "\(summary.id.uuidString)|\(document.id.uuidString)",
                    title: summary.name,
                    documentTitle: document.name))
            }
        }
        return choices.sorted { lhs, rhs in
            lhs.title == rhs.title
                ? (lhs.documentTitle ?? "") < (rhs.documentTitle ?? "")
                : lhs.title < rhs.title
        }
    }

    // MARK: Apply (update the ORIGINAL bound node)

    private static func applyToCanvas(
        document: FloeCADDocument,
        url: URL,
        assetStore: CreativeAssetStore
    ) async -> CADCanvasActionResult {
        do {
            // Export the real projected page first: a canvas write never
            // happens without verified result bytes.
            let exported = try await exportPNG(document: document, url: url)
            guard let located = try locateTarget(packageURL: url),
                  let node = located.project.documents
                    .flatMap(\.nodes).first(where: { $0.id == located.nodeID }) else {
                // Actionable, not a dead end: the explicit "Add to canvas"
                // route in the tools panel creates the first node in a canvas
                // the user picks; only then do Apply/Variant apply to it.
                return .status(canvasLocalized(
                    "画布中没有引用该 CAD 文档的节点。请使用工具面板中的“添加到画布”，选择目标画布后创建第一个节点。",
                    "No canvas node references this CAD document yet. Use \"Add to Canvas\" in the tools panel and pick a destination to create the first node."))
            }
            let reference = try await persistRender(exported, document: document,
                                                    node: node, assetStore: assetStore)
            let captured = CADCanvasNodePlanner.capturedSourceHash(for: node)
            let operation = try CADCanvasNodePlanner.applyPatch(
                liveNode: node,
                sourcePath: sourcePathKey(packageURL: url),
                capturedSourceAssetHash: captured,
                renderedAsset: reference,
                extraMetadata: [
                    "editor": "native-cad",
                    "cadFormat": "floecad",
                    "preview": exported.isPlaceholder ? "placeholder" : "viewport",
                    "appliedRevision": String(exported.revision),
                    "appliedContentHash": exported.hash,
                ])
            guard try await commit(operations: [operation],
                             nodeID: node.id,
                             canvasID: located.canvasID,
                             documentID: located.documentID,
                             assetStore: assetStore) != nil else {
                throw CADDocumentError(code: "canvas_write_failed",
                                       message: canvasLocalized(
                                           "画布写入失败；原节点未被修改。",
                                           "The canvas write failed; the original node was not changed."))
            }
            return .success(canvasLocalized(
                "已更新画布原节点（名称、位置与连线保持不变）。",
                "The original canvas node was updated (name, position and edges preserved)."))
        } catch {
            return .status(error.localizedDescription)
        }
    }

    // MARK: Variant (create a NEW node)

    private static func makeVariant(
        document: FloeCADDocument,
        url: URL,
        assetStore: CreativeAssetStore
    ) async -> CADCanvasActionResult {
        do {
            let exported = try await exportPNG(document: document, url: url)
            guard let located = try locateTarget(packageURL: url),
                  let sourceNode = located.project.documents
                    .flatMap(\.nodes).first(where: { $0.id == located.nodeID }) else {
                // A variant branches FROM a bound node; without one the
                // actionable route is "Add to Canvas" first (explicit pick),
                // never an invented source.
                return .status(canvasLocalized(
                    "没有可分支的原节点。请先用“添加到画布”选择目标画布创建第一个节点，再从此节点创建分支。",
                    "There is no bound node to branch from. Use \"Add to Canvas\" first and pick a destination; then create the variant from that node."))
            }
            let reference = try await persistRender(exported, document: document,
                                                    node: sourceNode, assetStore: assetStore)
            let captured = CADCanvasNodePlanner.capturedSourceHash(for: sourceNode)
            let (_, operations) = try CADCanvasNodePlanner.variantPatch(
                sourceNodeID: sourceNode.id,
                sourcePath: sourcePathKey(packageURL: url),
                capturedSourceAssetHash: captured,
                renderedAsset: reference,
                position: CanvasPoint(x: sourceNode.x + sourceNode.width + 100, y: sourceNode.y),
                size: sourceNode.size,
                text: sourceNode.text.isEmpty ? document.name : sourceNode.text,
                extraMetadata: [
                    "editor": "native-cad",
                    "cadFormat": "floecad",
                    "variant": "true",
                    "preview": exported.isPlaceholder ? "placeholder" : "viewport",
                    "appliedRevision": String(exported.revision),
                    "appliedContentHash": exported.hash,
                ])
            guard try await commit(operations: operations,
                             nodeID: nil,
                             canvasID: located.canvasID,
                             documentID: located.documentID,
                             assetStore: assetStore) != nil else {
                throw CADDocumentError(code: "canvas_write_failed",
                                       message: canvasLocalized(
                                           "画布写入失败；原节点未被修改。",
                                           "The canvas write failed; the original node was not changed."))
            }
            return .success(canvasLocalized(
                "已创建画布分支节点；原节点保持不变。",
                "A canvas variant node was created; the original is unchanged."))
        } catch {
            return .status(error.localizedDescription)
        }
    }

    // MARK: Create the FIRST node (explicit destination)

    /// Canvas Add-menu "New CAD model": creates a NEW editable parametric
    /// `.floecad` package in the canvas workspace and binds it as a native
    /// CAD node through the same atomic patch primitives as the workbench
    /// entry. This is the explicit CAD creation route next to the 3D
    /// Director's lightweight scene compositions — the scene editor is for
    /// arranging simple shapes, NOT parametric CAD, and the two are never
    /// conflated.
    static func newCADDocumentInCanvas(
        canvasID: UUID,
        documentID: UUID,
        position: CanvasPoint,
        assetStore: CreativeAssetStore
    ) async -> (nodeID: UUID?, message: String) {
        // Canvas is its OWN workspace: the editable package is created in the
        // app-owned, on-device `CanvasCAD` container for THIS canvas, never in
        // a temporary directory and never guessed from "the first project" or
        // an open chat task. No local file workspace is required.
        //
        // A previous failed creation persists a PENDING record; a retry REUSES
        // that same package (rebind) instead of generating another orphan.
        let url: URL
        let reused: Bool
        if let pending = CanvasCADStorage.pendingPackage(canvasID: canvasID,
                                                         documentID: documentID) {
            url = pending
            reused = true
        } else {
            do {
                url = try CanvasCADStorage.uniquePackageURL(canvasID: canvasID)
            } catch {
                return (nil, error.localizedDescription)
            }
            CanvasCADStorage.setPending(canvasID: canvasID, documentID: documentID,
                                        packageFileName: url.lastPathComponent)
            reused = false
        }
        let binding = CanvasCADStorage.key(canvasID: canvasID,
                                           packageFileName: url.lastPathComponent)
        do {
            let document: FloeCADDocument
            if reused {
                document = try await FloeCADDocument.open(at: url)
            } else {
                document = try await FloeCADDocument.create(
                    at: url, name: (url.lastPathComponent as NSString).deletingPathExtension)
            }
            do {
                let exported = try await exportPNG(document: document, url: url)
                let render = try await persistRender(exported, document: document,
                                                     node: nil, assetStore: assetStore)
                let operation = try CADCanvasNodePlanner.createPatch(
                    sourcePath: binding,
                    sourceAssetHash: exported.packageSHA256,
                    renderedAsset: render,
                    position: position,
                    size: CanvasSize(width: 420, height: 300),
                    text: document.name,
                    extraMetadata: [
                        "editor": "native-cad",
                        "cadFormat": "floecad",
                        "cadStorage": "canvas-owned",
                        "preview": exported.isPlaceholder ? "placeholder" : "viewport",
                        "appliedRevision": String(exported.revision),
                        "appliedContentHash": exported.hash,
                    ])
                // The bridge keeps the document open; release it now that the
                // node binds the package on disk — regardless of the canvas
                // write outcome (a failed write leaves a recoverable on-disk
                // package, not a locked live session).
                defer { Task { await FloeCAD3DBridge.shared.releaseDocument(at: url) } }
                guard try await commit(operations: [operation],
                                 nodeID: nil,
                                 canvasID: canvasID,
                                 documentID: documentID,
                                 assetStore: assetStore) != nil else {
                    // Recoverable, not a dead end: the package is durably
                    // saved and the pending record makes the retry rebind THIS
                    // document instead of creating a second orphan.
                    return (nil, canvasLocalized(
                        "画布写入失败，但 CAD 文档已保存在本机画布存储中；再次点击会重新绑定同一文档。",
                        "The canvas write failed, but the CAD document was saved in this canvas's on-device storage; trying again rebinds the same document."))
                }
                CanvasCADStorage.clearPending(canvasID: canvasID, documentID: documentID)
                let placeholderNote = exported.isPlaceholder
                    ? canvasLocalized("（预览为占位图，本机无法渲染视口）",
                                      " (placeholder preview; on-device viewport rendering is unavailable)")
                    : ""
                return (operation.nodeID, canvasLocalized(
                    "已创建 CAD 模型“\(document.name)”（参数化工作台）；如需组合简单场景请使用 3D 场景编辑器。",
                    "Created CAD model \"\(document.name)\" (parametric workbench); use the 3D scene editor only for simple scene compositions.") + placeholderNote)
            } catch {
                await FloeCAD3DBridge.shared.releaseDocument(at: url)
                // Keep a durable package's pending record (rebindable); a
                // failure before the package existed clears it so the next
                // attempt starts clean.
                if !FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                    CanvasCADStorage.clearPending(canvasID: canvasID, documentID: documentID)
                }
                return (nil, error.localizedDescription)
            }
        } catch {
            if !reused {
                CanvasCADStorage.clearPending(canvasID: canvasID, documentID: documentID)
            }
            return (nil, error.localizedDescription)
        }
    }

    /// Creates the first Canvas node for this package in the user's explicit
    /// pick. The node binds to the package by `sourcePath` + content hash
    /// metadata (the live asset is the exported render), so a later "Apply to
    /// canvas" resolves it through the recorded binding — never by guessing.
    private static func createNodeInCanvas(
        document: FloeCADDocument,
        url: URL,
        choice: CADCanvasActions.TargetChoice,
        assetStore: CreativeAssetStore
    ) async -> CADCanvasActionResult {
        do {
            let parts = choice.id.split(separator: "|").map(String.init)
            guard parts.count == 2,
                  let canvasID = UUID(uuidString: parts[0]),
                  let documentID = UUID(uuidString: parts[1]) else {
                return .status(canvasLocalized(
                    "画布目标已失效，请重新选择。",
                    "The canvas destination is no longer valid; please pick again."))
            }
            let exported = try await exportPNG(document: document, url: url)
            // Refuse when a binding appeared between the pick and the write:
            // the explicit create must never shadow an existing node.
            if let existing = try locateTarget(packageURL: url) {
                return .status(canvasLocalized(
                    "画布“\(existing.project.name)”已有引用该文档的节点；请改用“更新画布”或“创建分支”。",
                    "Canvas \"\(existing.project.name)\" already has a node referencing this document; use Apply or Make variant instead."))
            }
            let render = try await persistRender(exported, document: document,
                                                 node: nil, assetStore: assetStore)
            let position = CanvasPoint(x: 120, y: 120)
            let operation = try CADCanvasNodePlanner.createPatch(
                sourcePath: sourcePathKey(packageURL: url),
                sourceAssetHash: exported.packageSHA256,
                renderedAsset: render,
                position: position,
                size: CanvasSize(width: 420, height: 300),
                text: document.name,
                extraMetadata: [
                    "editor": "native-cad",
                    "cadFormat": "floecad",
                    "preview": exported.isPlaceholder ? "placeholder" : "viewport",
                    "appliedRevision": String(exported.revision),
                    "appliedContentHash": exported.hash,
                ])
            guard try await commit(operations: [operation],
                             nodeID: nil,
                             canvasID: canvasID,
                             documentID: documentID,
                             assetStore: assetStore) != nil else {
                throw CADDocumentError(code: "canvas_write_failed",
                                       message: canvasLocalized(
                                           "画布写入失败；未创建节点。",
                                           "The canvas write failed; no node was created."))
            }
            return .success(canvasLocalized(
                "已在所选画布中创建 CAD 节点；之后可用“更新画布”或“创建分支”。",
                "A CAD node was created in the chosen canvas; use Apply or Make variant from here."))
        } catch {
            return .status(error.localizedDescription)
        }
    }

    // MARK: Export + asset persistence

    struct ExportedRender {
        let data: Data
        let hash: String
        /// The committed document revision/package hash the preview was
        /// rendered from (AFTER a verified save).
        let revision: Int
        let packageSHA256: String
        /// True when the device could not render the viewport and an explicit
        /// empty placeholder was used (recorded in node metadata).
        let isPlaceholder: Bool
    }

    static func exportPNG(document: FloeCADDocument,
                                  url: URL) async throws -> ExportedRender {
        // The preview must never be published against an uncommitted or
        // conflicted draft: a failed save refuses BEFORE any canvas write.
        let save = await document.save()
        guard save.succeeded else {
            throw CADDocumentError(code: "save_failed",
                                   message: canvasLocalized(
                                       "CAD 文档保存失败，未写入画布：",
                                       "The CAD document could not be saved; nothing was written to the canvas. ")
                                   + (save.error ?? ""))
        }
        // Canvas node previews come from the VIEWPORT (bodies + assembly
        // instances), independent of any engineering drawing page — a brand
        // new blank CAD document must be creatable from the Canvas. Drawing
        // pages remain available for explicit PDF/SVG/DXF/PNG exports.
        if let data = document.viewportThumbnailPNG(width: 640, height: 480),
           !data.isEmpty {
            return ExportedRender(data: data, hash: FloeDigest.sha256Hex(data),
                                  revision: save.revision,
                                  packageSHA256: save.contentSHA256,
                                  isPlaceholder: false)
        }
        if let placeholder = CADCanvasPreview.placeholderPNG(), !placeholder.isEmpty {
            return ExportedRender(data: placeholder, hash: FloeDigest.sha256Hex(placeholder),
                                  revision: save.revision,
                                  packageSHA256: save.contentSHA256,
                                  isPlaceholder: true)
        }
        throw CADDocumentError(code: "empty_export",
                               message: canvasLocalized(
                                   "CAD 视口渲染为空，未应用到画布。",
                                   "The CAD viewport render was empty; nothing was applied to the canvas."))
    }

    /// Writes the render into the app-owned material library and registers it
    /// as a creative asset. A failed registration removes the partial file so
    /// the library never carries an unregistered orphan.
    private static func persistRender(_ render: ExportedRender,
                                      document: FloeCADDocument,
                                      node: CanvasNode?,
                                      assetStore: CreativeAssetStore) async throws -> CanvasAssetReference {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let assetID = UUID()
        let filename = "\(assetID.uuidString)-canvas-cad.png"
        let target = directory.appendingPathComponent(filename)
        try render.data.write(to: target, options: [.atomic])
        do {
            let displayName = (node?.text.isEmpty == false ? node?.text : nil)
                ?? (document.name.isEmpty ? "CAD" : document.name)
            try await assetStore.save(CreativeAssetRecord(
                id: assetID, contentHash: render.hash, kind: .image,
                displayName: displayName, mimeType: "image/png",
                localRelativePath: "Materials/\(filename)",
                byteCount: Int64(render.data.count),
                tags: ["canvas", "native-cad"], referenceCount: 0))
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return CanvasAssetReference(
            id: assetID, contentHash: render.hash,
            localRelativePath: "Materials/\(filename)",
            mimeType: "image/png", byteCount: Int64(render.data.count))
    }

    // MARK: Canvas location + atomic commit

    /// Finds the canvas document and node that reference the source
    /// `.floecad` package. A previously applied node matches through its
    /// recorded `sourcePath` metadata (its live asset is the PNG render); a
    /// first-time import matches by file name. The canvas project is read
    /// fresh again inside the CAS loop; this locator only selects the target
    /// identity.
    private static func locateTarget(packageURL: URL) throws -> Target? {
        let needle = packageURL.lastPathComponent.lowercased()
        let sourceKey = sourcePathKey(packageURL: packageURL).lowercased()
        var firstImport: Target?
        for summary in WorkspaceCanvasRegistry.summaries() {
            guard let project = try? WorkspaceCanvasRegistry.project(canvasID: summary.id) else { continue }
            for document in project.documents {
                for node in document.nodes {
                    let recorded = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath]?.lowercased()
                    if recorded == sourceKey {
                        return Target(canvasID: project.id, project: project,
                                      documentID: document.id, nodeID: node.id)
                    }
                    if firstImport == nil, let path = node.asset?.localRelativePath,
                       (path as NSString).lastPathComponent.lowercased() == needle {
                        firstImport = Target(canvasID: project.id, project: project,
                                             documentID: document.id, nodeID: node.id)
                    }
                }
            }
        }
        return firstImport
    }

    /// One patch applied with bounded revision-CAS retries against the exact
    /// canvas file, plus creative-asset reference reconciliation. Returns the
    /// operation result on success; nil when the write failed.
    @discardableResult
    private static func commit(
        operations: [CanvasPatchOperation],
        nodeID: UUID?,
        canvasID: UUID,
        documentID: UUID,
        assetStore: CreativeAssetStore
    ) async throws -> CanvasOperationResult? {
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false)
        for attempt in 0..<4 {
            let current = try CanvasProjectFileWriter.shared.project(canvasID: canvasID, at: url)
            // Re-check the target document/node still exists on every retry;
            // a deletion while the export ran refuses instead of resurrecting
            // the node and never targets another canvas.
            guard current.documents.contains(where: { $0.id == documentID }) else {
                throw CADDocumentError(code: "canvas_changed", message: canvasLocalized(
                    "画布文档已改变；原节点未被修改。", "The canvas document changed; the original node was not modified."))
            }
            if let nodeID, !current.documents.flatMap(\.nodes).contains(where: { $0.id == nodeID }) {
                throw CADDocumentError(code: "node_missing", message: canvasLocalized(
                    "原画布节点已被删除；未写入。", "The original canvas node was deleted; nothing was written."))
            }
            do {
                let patch = CanvasPatch(
                    canvasID: canvasID,
                    documentID: documentID,
                    expectedRevision: current.revision,
                    operations: operations)
                let (updated, result) = try CanvasCommandService.applying(patch, to: current)
                try CanvasProjectFileWriter.shared.compareAndSwap(
                    updated, at: url, expectedRevision: current.revision)
                await reconcileReferences(from: current, to: updated, assetStore: assetStore)
                NotificationCenter.default.post(
                    name: .floeCanvasProjectDidChange, object: nil,
                    userInfo: ["canvasID": canvasID])
                return result
            } catch {
                guard CanvasProjectFileWriter.isRevisionConflict(error), attempt < 3 else {
                    throw error
                }
            }
        }
        return nil
    }

    /// Reference-count reconciliation identical in shape to the visible
    /// canvas store's `writeCandidate`: reachable deltas (current asset +
    /// typed CAD history) applied as idempotent creative-asset ops. A failed
    /// op is left for the store's own reconciliation on the next canvas open;
    /// the published project bytes stay authoritative.
    private static func reconcileReferences(
        from before: CanvasProject,
        to after: CanvasProject,
        assetStore: CreativeAssetStore
    ) async {
        let deltas = CanvasDrawingRevisionHistory.reachableDeltas(from: before, to: after)
        guard !deltas.isEmpty else { return }
        for (assetID, delta) in deltas.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            try? await assetStore.applyReferenceOp(
                opID: UUID().uuidString, assetID: assetID, delta: delta)
        }
    }

    /// Identity recorded on the node and in the action metadata. Canvas-owned
    /// packages (created from the Canvas toolbar) bind with their explicit
    /// `canvas-cad:<canvas>/<file>` key; packages that live in a user file
    /// workspace keep the file-name based `floecad:<file>` key. Neither is an
    /// absolute path, so both survive container/workspace relocation.
    private static func sourcePathKey(packageURL: URL) -> String {
        let standardized = packageURL.standardizedFileURL
        if let root = try? CanvasCADStorage.containerRoot(createIfNeeded: false).standardizedFileURL,
           standardized.path.hasPrefix(root.path + "/") {
            let remainder = String(standardized.path.dropFirst(root.path.count + 1))
            let parts = remainder.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let canvasID = UUID(uuidString: parts[0]) {
                return CanvasCADStorage.key(canvasID: canvasID, packageFileName: parts[1])
            }
        }
        return "floecad:\(packageURL.lastPathComponent)"
    }

    /// Resolve a node-recorded source key to its absolute on-disk package.
    /// Canvas-owned keys resolve through `CanvasCADStorage`; legacy
    /// `floecad:` keys are not canvas-owned and resolve nil here (they live in
    /// a user file workspace and are opened through FilePreview).
    static func packageURL(forSourceKey key: String) -> URL? {
        CanvasCADStorage.packageURL(forKey: key)
    }
}

#endif
