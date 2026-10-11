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

    /// Exact owner identity of a workbench presentation: the canvas document
    /// and node the user explicitly opened. Apply/Variant bind to THIS node
    /// when supplied instead of choosing the first node that references the
    /// package (the same native file may legitimately be referenced by more
    /// than one node).
    struct CADCanvasNodeOwner: Sendable, Hashable {
        let canvasID: UUID
        let documentID: UUID
        let nodeID: UUID
    }

    /// In-flight new-CAD creations keyed by canvas+document. Two rapid
    /// requests (a tool duplicate or a fast double tap that slips past the
    /// UI's disabled state) must share ONE package and ONE committed node:
    /// without this, both callers observe the same pending package across
    /// their awaits and each commits its own node.
    private static var inFlightCreates: [String: Task<(nodeID: UUID?, message: String), Never>] = [:]

    /// A located target: the canvas project file plus the exact node id of
    /// the node whose asset references the source package.
    private struct Target {
        let canvasID: UUID
        let project: CanvasProject
        let documentID: UUID
        let nodeID: UUID
    }

    /// How a package resolves to canvas targets when no frozen presentation
    /// owner was supplied (the file-preview entry).
    private enum TargetResolution {
        case unique(Target)
        case none
        /// More than one VERIFIED reference, or only unverified file-name
        /// matches: an explicit choice / actionable refusal is required.
        case ambiguous(verifiedCount: Int, nameMatchCount: Int)
    }

    /// The host-installed actions for `FloeCADWorkbenchView`. The operation
    /// closures receive the exact resolved package URL from the workbench.
    ///
    /// `owner` is the FROZEN node this workbench presentation was opened for.
    /// It is captured into EACH action closure at creation: there is no global
    /// "current presentation" registry, so two workbenches for the same
    /// package (different canvas nodes) keep independent bindings and closing
    /// one can never unregister the other's target. A file-preview action set
    /// passes nil and only ever writes through a single VERIFIED reference.
    static func actions(
        assetStore: CreativeAssetStore,
        owner: CADCanvasNodeOwner? = nil
    ) -> CADCanvasActions {
        CADCanvasActions(
            applyToCanvas: { document, url in
                await applyToCanvas(document: document, url: url,
                                    assetStore: assetStore, frozenOwner: owner)
            },
            makeVariant: { document, url in
                await makeVariant(document: document, url: url,
                                  assetStore: assetStore, frozenOwner: owner)
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
        assetStore: CreativeAssetStore,
        frozenOwner: CADCanvasNodeOwner?
    ) async -> CADCanvasActionResult {
        do {
            // Resolve the exact target FIRST (cheap reads): a frozen
            // presentation owner binds that node; the no-owner entry needs
            // one unique VERIFIED reference or it refuses before any work.
            let owner: CADCanvasNodeOwner
            if let frozenOwner {
                guard try exactTarget(owner: frozenOwner, packageURL: url) != nil else {
                    return .status(canvasLocalized(
                        "原画布节点已被删除或不再引用该 CAD 文档；未写入。",
                        "The original canvas node was deleted or no longer references this CAD document; nothing was written."))
                }
                owner = frozenOwner
            } else {
                switch try resolveTarget(packageURL: url) {
                case .unique(let target):
                    owner = CADCanvasNodeOwner(
                        canvasID: target.canvasID,
                        documentID: target.documentID,
                        nodeID: target.nodeID)
                case .none:
                    // Actionable, not a dead end: the explicit "Add to canvas"
                    // route in the tools panel creates the first node in a
                    // canvas the user picks; only then do Apply/Variant apply
                    // to it.
                    return .status(canvasLocalized(
                        "画布中没有引用该 CAD 文档的节点。请使用工具面板中的“添加到画布”，选择目标画布后创建第一个节点。",
                        "No canvas node references this CAD document yet. Use \"Add to Canvas\" in the tools panel and pick a destination to create the first node."))
                case .ambiguous:
                    return .status(ambiguousTargetMessage())
                }
            }
            // Export the real projected page: a canvas write never happens
            // without verified result bytes.
            let exported = try await exportPNG(document: document, url: url)
            // Re-validate the EXACT node/source after the export await; the
            // commit below checks it again inside every CAS attempt.
            guard let located = try exactTarget(owner: owner, packageURL: url),
                  let node = located.project.documents
                    .flatMap(\.nodes).first(where: { $0.id == located.nodeID }) else {
                return .status(canvasLocalized(
                    "原画布节点已被删除或不再引用该 CAD 文档；未写入。",
                    "The original canvas node was deleted or no longer references this CAD document; nothing was written."))
            }
            let sourceKey = sourcePathKey(packageURL: url)
            let reference = try await persistRender(exported, document: document,
                                                    node: node, assetStore: assetStore)
            let captured = CADCanvasNodePlanner.capturedSourceHash(for: node)
            let operation = try CADCanvasNodePlanner.applyPatch(
                liveNode: node,
                sourcePath: sourceKey,
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
                             assetStore: assetStore,
                             expectedSource: (node.id, sourceKey)) != nil else {
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
        assetStore: CreativeAssetStore,
        frozenOwner: CADCanvasNodeOwner?
    ) async -> CADCanvasActionResult {
        do {
            let owner: CADCanvasNodeOwner
            if let frozenOwner {
                guard try exactTarget(owner: frozenOwner, packageURL: url) != nil else {
                    return .status(canvasLocalized(
                        "原画布节点已被删除或不再引用该 CAD 文档；未写入。",
                        "The original canvas node was deleted or no longer references this CAD document; nothing was written."))
                }
                owner = frozenOwner
            } else {
                switch try resolveTarget(packageURL: url) {
                case .unique(let target):
                    owner = CADCanvasNodeOwner(
                        canvasID: target.canvasID,
                        documentID: target.documentID,
                        nodeID: target.nodeID)
                case .none:
                    // A variant branches FROM a bound node; without one the
                    // actionable route is "Add to Canvas" first (explicit
                    // pick), never an invented source.
                    return .status(canvasLocalized(
                        "没有可分支的原节点。请先用“添加到画布”选择目标画布创建第一个节点，再从此节点创建分支。",
                        "There is no bound node to branch from. Use \"Add to Canvas\" first and pick a destination; then create the variant from that node."))
                case .ambiguous:
                    return .status(ambiguousTargetMessage())
                }
            }
            let exported = try await exportPNG(document: document, url: url)
            // Re-validate the exact branch source after the export await.
            guard let located = try exactTarget(owner: owner, packageURL: url),
                  let sourceNode = located.project.documents
                    .flatMap(\.nodes).first(where: { $0.id == located.nodeID }) else {
                return .status(canvasLocalized(
                    "没有可分支的原节点。请先用“添加到画布”选择目标画布创建第一个节点，再从此节点创建分支。",
                    "There is no bound node to branch from. Use \"Add to Canvas\" first and pick a destination; then create the variant from that node."))
            }
            let sourceKey = sourcePathKey(packageURL: url)
            let reference = try await persistRender(exported, document: document,
                                                    node: sourceNode, assetStore: assetStore)
            let captured = CADCanvasNodePlanner.capturedSourceHash(for: sourceNode)
            let (_, operations) = try CADCanvasNodePlanner.variantPatch(
                sourceNodeID: sourceNode.id,
                sourcePath: sourceKey,
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
                             assetStore: assetStore,
                             expectedSource: (sourceNode.id, sourceKey)) != nil else {
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

    /// Single-flight entry: rapid duplicate requests for the SAME canvas
    /// document share one creation. The second caller awaits the first
    /// result instead of opening the same pending package and committing a
    /// second node. (The UI's disabled state handles ordinary taps; a tool
    /// replay or a fast double-submit must not depend on view state.)
    static func newCADDocumentInCanvas(
        canvasID: UUID,
        documentID: UUID,
        position: CanvasPoint,
        assetStore: CreativeAssetStore
    ) async -> (nodeID: UUID?, message: String) {
        let key = "\(canvasID.uuidString)|\(documentID.uuidString)"
        if let inFlight = inFlightCreates[key] {
            return await inFlight.value
        }
        let task = Task { @MainActor in
            await performNewCADDocumentInCanvas(
                canvasID: canvasID, documentID: documentID,
                position: position, assetStore: assetStore)
        }
        inFlightCreates[key] = task
        let result = await task.value
        inFlightCreates[key] = nil
        return result
    }

    /// Canvas Add-menu "New CAD model": creates a NEW editable parametric
    /// `.floecad` package in the canvas workspace and binds it as a native
    /// CAD node through the same atomic patch primitives as the workbench
    /// entry. This is the ONLY 3D creation route: the legacy 3D Director is
    /// retired for editing (existing `scene3D` nodes migrate on first edit
    /// through `LegacySceneMigrationService`), and simple compositions are
    /// ordinary native documents — there is no second editor.
    private static func performNewCADDocumentInCanvas(
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
                    // The node TITLE follows the UI language ("CAD 模型" in
                    // Chinese); the package file name/binding key stay the
                    // stable English stem, so a language switch keeps identity.
                    text: CADCanvasNodePlanner.defaultDisplayName(),
                    extraMetadata: [
                        "editor": "native-cad",
                        "cadFormat": "floecad",
                        "cadStorage": "canvas-owned",
                        "preview": exported.isPlaceholder ? "placeholder" : "viewport",
                        "appliedRevision": String(exported.revision),
                        "appliedContentHash": exported.hash,
                        // The exact MODEL identity of the creation commit:
                        // `discardNewCADDocument` re-verifies it so preview
                        // flushes (fullscreen return/close) can never fake an
                        // edit and real edits/foreign revisions still refuse.
                        Self.sourceModelHashMetadataKey: exported.packageModelSHA256,
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
                    "已创建 CAD 模型“\(document.name)”（统一 3D 工作台）。",
                    "Created CAD model \"\(document.name)\" (unified 3D workbench).") + placeholderNote)
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

    /// Node metadata carrying the creation-time MODEL identity
    /// (`CADSaveOutcome.modelSHA256`: user-editable name/unit/tolerance +
    /// canonical document records + blobs; preview excluded). Written only by
    /// the creation route; used here to prove the semantic document is still
    /// the untouched creation.
    static let sourceModelHashMetadataKey = "canvas.nativeCAD.sourceModelHash"

    #if DEBUG
    /// TEST-ONLY probe invoked inside `discardNewCADDocument` at the exact
    /// post-fence/pre-remove boundary, while the in-process package gate is
    /// held. Production never sets it (DEBUG builds only).
    static var discardBoundaryProbe: (@MainActor () async -> Void)?
    #endif

    /// Cancels a JUST-CREATED native CAD document the user has not accepted
    /// (the workbench's Cancel for a newly created model).
    ///
    /// Untouched proof — two EXACT paths; nothing is guessed and no
    /// hash/revision is ignored:
    ///
    /// 1. **Pristine**: the on-disk commit is still the creation commit —
    ///    the exact committed REVISION and content identity — and the live
    ///    session (when given) has no uncommitted edit. A same-content
    ///    foreign save moves the revision and fails here.
    /// 2. **Session-owned preview writes**: exactly the fullscreen/close
    ///    preview flushes this creation session itself made. The on-disk
    ///    revision + `contentSHA256` must EQUAL the live `FloeCADDocument`'s
    ///    own last-committed identity (so any foreign revision — even a
    ///    same-content save — or a writer that landed after our session
    ///    refuses), that live document must be bound to THIS exact package
    ///    URL, the revision never moved backwards from the creation, the
    ///    semantic metadata/content is still the creation's (`modelSHA256`
    ///    equals the recorded model identity), and no in-session edit is
    ///    uncommitted.
    ///
    /// Only then are OWNED writes drained/fenced (the store's disk CAS makes
    /// a save refuse rather than overwrite a foreign commit), the committed
    /// identity is RE-VERIFIED after fencing, and the exact created node is
    /// removed through the same revision-CAS primitives, the canvas-owned
    /// package deleted, and the pending record cleared. A failed package
    /// removal is reported honestly, never as a clean cancel.
    ///
    /// - A document with user edits (or one whose bytes can no longer be
    ///   verified against the creation identity) is NEVER discarded: the node
    ///   and package stay as the recoverable draft and the outcome reports
    ///   that honestly.
    /// - Existing nodes, other references and other documents are untouched;
    ///   the package is deleted only when no remaining node references it.
    static func discardNewCADDocument(
        canvasID: UUID,
        documentID: UUID,
        nodeID: UUID,
        liveDocument: FloeCADDocument?,
        assetStore: CreativeAssetStore
    ) async -> CADCanvasActionResult {
        do {
            let url = try WorkspaceCanvasRegistry.projectURL(
                canvasID: canvasID, createDirectory: false)
            let current = try CanvasProjectFileWriter.shared.project(canvasID: canvasID, at: url)
            guard current.documents.contains(where: { $0.id == documentID }),
                  let node = current.documents.flatMap(\.nodes).first(where: { $0.id == nodeID }),
                  CADCanvasNodePlanner.isNativeCADNode(node),
                  let sourceKey = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
                  CanvasCADStorage.isCanvasOwnedKey(sourceKey),
                  let packageURL = packageURL(forSourceKey: sourceKey) else {
                // Already gone (or never a canvas-owned creation): nothing to
                // delete, and nothing left behind either.
                return .status(canvasLocalized(
                    "该 CAD 节点已不存在；未做任何修改。",
                    "The CAD node no longer exists; nothing was changed."))
            }
            // The live session the user is looking at: its identity moves only
            // through its OWN commits, so equality with the package on disk is
            // the exact ownership proof for the preview-only writes a
            // fullscreen return/close flush produces. The SAME document must
            // be the one bound to THIS package URL.
            let liveDocument = liveDocument
            let liveDirty = liveDocument?.hasUnsavedChanges ?? false
            let creationHash = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourceHash]
            let recordedModelHash = node.metadata[Self.sourceModelHashMetadataKey]
            let creationRevision = Int(node.metadata["appliedRevision"] ?? "")
            let identity = await FloeCADDocument.storedIdentity(at: packageURL)
            guard let creationHash, !creationHash.isEmpty,
                  let identity, !liveDirty else {
                return refuseChangedDraft()
            }
            let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
            let livePath = liveDocument?.url.standardizedFileURL
                .resolvingSymlinksInPath().path
            let liveIsThisPackage = livePath == packagePath
            // The semantic proof: the additive canonical model identity (or,
            // for historical manifests without it, the exact content identity)
            // must still be the creation's.
            let semanticMatch: Bool
            if let recordedModelHash, !recordedModelHash.isEmpty {
                semanticMatch = identity.modelSHA256 == recordedModelHash
            } else {
                semanticMatch = identity.contentSHA256 == creationHash
            }
            // (1) Nothing on disk moved at all since creation — the exact
            //     committed revision AND content identity, so a same-content
            //     foreign save (which moves the revision) cannot pass.
            let pristine = identity.contentSHA256 == creationHash
                && (creationRevision == nil || identity.revision == creationRevision)
            // (2) The current commit is EXACTLY this live creation session's
            //     own last commit for THIS package, the semantic model is
            //     still the creation's, and the revision never moved backwards.
            var sessionOwnedPreview = false
            if !pristine, semanticMatch,
               let liveDocument, liveIsThisPackage,
               !liveDocument.isClosed, !liveDocument.hasUnsavedChanges,
               let creationRevision, identity.revision >= creationRevision,
               liveDocument.revision == identity.revision,
               liveDocument.contentSHA256 == identity.contentSHA256 {
                sessionOwnedPreview = true
            }
            guard pristine || sessionOwnedPreview else {
                return refuseChangedDraft()
            }
            // Fence + drain OWNED writes (saves are no-ops for untouched
            // bytes; the store's disk CAS refuses to overwrite anything a
            // foreign writer landed) before touching the package again.
            await FloeCAD3DBridge.shared.releaseDocument(at: packageURL)
            // Serialize every SUPPORTED writer of this package with the
            // verify→delete section below: all store commits acquire the same
            // in-process package gate, so a foreign session either lands
            // BEFORE the final re-check (which refuses and preserves it) or
            // waits until after the removal, where the missing manifest and
            // the disk CAS refuse its commit — its data is never deleted.
            await CADPackageGate.acquireAsync(packageURL)
            defer { CADPackageGate.release(packageURL) }
            #if DEBUG
            // Test-only probe at the exact post-fence/pre-remove boundary
            // (production never sets it).
            if let probe = discardBoundaryProbe { await probe() }
            #endif
            // FINAL re-verify of the EXACT committed identity, immediately
            // before anything is deleted. If a foreign write raced the
            // release (it refused instead of clobbering) or a non-cooperating
            // writer changed the package at this boundary, the disk no longer
            // equals this session's identity and the deletion must NOT
            // proceed.
            let expectedRevision = liveDocument?.revision ?? identity.revision
            let expectedContent = liveDocument?.contentSHA256 ?? identity.contentSHA256
            guard let afterFence = await FloeCADDocument.storedIdentity(at: packageURL),
                  afterFence.revision == expectedRevision,
                  afterFence.contentSHA256 == expectedContent,
                  (recordedModelHash?.isEmpty == false
                       ? afterFence.modelSHA256 == recordedModelHash
                       : afterFence.contentSHA256 == creationHash) else {
                return refuseChangedDraft()
            }
            let delete = CanvasPatchOperation(kind: .delete, nodeID: nodeID)
            guard try await commit(
                operations: [delete], nodeID: nodeID,
                canvasID: canvasID, documentID: documentID,
                assetStore: assetStore,
                expectedSource: (nodeID, sourceKey)) != nil else {
                throw CADDocumentError(code: "canvas_write_failed",
                                       message: canvasLocalized(
                                           "画布写入失败；未创建任何内容。",
                                           "The canvas write failed; nothing was created."))
            }
            CanvasCADStorage.clearPending(canvasID: canvasID, documentID: documentID)
            // Delete the package only when no remaining node references it.
            let after = try CanvasProjectFileWriter.shared.project(canvasID: canvasID, at: url)
            let stillReferenced = after.documents.flatMap(\.nodes).contains {
                $0.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] == sourceKey
            }
            if stillReferenced {
                return .status(canvasLocalized(
                    "画布中仍有节点引用该文档；节点已取消，未删除文档。",
                    "A canvas node still references this document; the node was cancelled but the document was not deleted."))
            }
            do {
                try FileManager.default.removeItem(at: packageURL)
            } catch {
                // Honest outcome: never report a clean cancel when the
                // package could not actually be removed.
                return .status(canvasLocalized(
                    "已取消创建并移除节点，但本机文档未能删除：\(error.localizedDescription)",
                    "Creation cancelled and the node removed, but the on-device document could not be deleted: \(error.localizedDescription)"))
            }
            return .success(canvasLocalized(
                "已取消创建；未留下空节点或孤立文档。",
                "Creation cancelled; no empty node or orphan document was left behind."))
        } catch {
            return .status(error.localizedDescription)
        }
    }

    /// The single honest refusal for a draft whose creation identity can no
    /// longer be verified as exact (edits, foreign/concurrent revision, or an
    /// unreadable package). Nothing is deleted.
    private static func refuseChangedDraft() -> CADCanvasActionResult {
        .status(canvasLocalized(
            "文档已有修改或无法验证，已保留为可恢复草稿；未删除任何内容。",
            "The document has edits or can no longer be verified; it was kept as a recoverable draft. Nothing was deleted."))
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
            // the explicit create must never shadow an existing node. Only an
            // exact VERIFIED match (or an unverified same-name match) counts;
            // nothing is guessed and nothing is overwritten.
            switch try resolveTarget(packageURL: url) {
            case .unique(let existing):
                return .status(canvasLocalized(
                    "画布“\(existing.project.name)”已有引用该文档的节点；请改用“更新画布”或“创建分支”。",
                    "Canvas \"\(existing.project.name)\" already has a node referencing this document; use Apply or Make variant instead."))
            case .ambiguous:
                return .status(ambiguousTargetMessage())
            case .none:
                break
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
        /// The committed MODEL identity of the same save (user-editable
        /// name/unit/tolerance + canonical document records + blobs, preview
        /// excluded). The creation route records it on the node so
        /// `discardNewCADDocument` can prove the semantic document is still
        /// the untouched creation across preview-only commits.
        let packageModelSHA256: String
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
                                  packageModelSHA256: save.modelSHA256,
                                  isPlaceholder: false)
        }
        if let placeholder = CADCanvasPreview.placeholderPNG(), !placeholder.isEmpty {
            return ExportedRender(data: placeholder, hash: FloeDigest.sha256Hex(placeholder),
                                  revision: save.revision,
                                  packageSHA256: save.contentSHA256,
                                  packageModelSHA256: save.modelSHA256,
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
    /// Shared with `LegacySceneMigrationService` (same atomic render persistence).
    static func persistRender(_ render: ExportedRender,
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

    /// The EXACT node a workbench presentation was opened for. It must still
    /// exist in its frozen document AND still reference this package; a
    /// deleted/unbound node returns nil so the action refuses instead of
    /// choosing another node. Never falls back to the first match.
    private static func exactTarget(
        owner: CADCanvasNodeOwner,
        packageURL: URL
    ) throws -> Target? {
        guard let project = try? WorkspaceCanvasRegistry.project(canvasID: owner.canvasID),
              project.id == owner.canvasID,
              let document = project.documents.first(where: { $0.id == owner.documentID }),
              let node = document.nodes.first(where: { $0.id == owner.nodeID }) else {
            return nil
        }
        let sourceKey = sourcePathKey(packageURL: packageURL).lowercased()
        let needle = packageURL.lastPathComponent.lowercased()
        let recorded = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath]?.lowercased()
        let references = recorded == sourceKey
            || (node.asset?.localRelativePath.map {
                ($0 as NSString).lastPathComponent.lowercased() == needle
            } ?? false)
        guard references else { return nil }
        return Target(
            canvasID: project.id, project: project,
            documentID: document.id, nodeID: node.id)
    }

    /// Finds the canvas document and node that reference the source
    /// `.floecad` package when NO frozen presentation owner exists (the file
    /// preview entry). A previously applied node matches through its recorded
    /// `sourcePath` metadata — a VERIFIED reference. A node whose asset merely
    /// has the same file name is an unverified match and is never written to
    /// automatically:
    ///
    /// - exactly one verified reference → that exact node;
    /// - several verified references or only name matches → `.ambiguous`
    ///   (the caller refuses with an actionable message and writes nothing);
    /// - no match → `.none` (use the explicit "Add to Canvas" route first).
    ///
    /// This never returns a "first match": a foreign file preview can no
    /// longer apply over an unrelated node.
    private static func resolveTarget(packageURL: URL) throws -> TargetResolution {
        let needle = packageURL.lastPathComponent.lowercased()
        let sourceKey = sourcePathKey(packageURL: packageURL).lowercased()
        var verified: [Target] = []
        var nameOnly: [Target] = []
        for summary in WorkspaceCanvasRegistry.summaries() {
            guard let project = try? WorkspaceCanvasRegistry.project(canvasID: summary.id) else { continue }
            for document in project.documents {
                for node in document.nodes {
                    let recorded = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath]?.lowercased()
                    if recorded == sourceKey {
                        verified.append(Target(canvasID: project.id, project: project,
                                               documentID: document.id, nodeID: node.id))
                    } else if let path = node.asset?.localRelativePath,
                              (path as NSString).lastPathComponent.lowercased() == needle {
                        nameOnly.append(Target(canvasID: project.id, project: project,
                                               documentID: document.id, nodeID: node.id))
                    }
                }
            }
        }
        if verified.count == 1 { return .unique(verified[0]) }
        if verified.count > 1 || !nameOnly.isEmpty {
            return .ambiguous(verifiedCount: verified.count, nameMatchCount: nameOnly.count)
        }
        return .none
    }

    private static func ambiguousTargetMessage() -> String {
        canvasLocalized(
            "画布中有多个节点（或仅有同名文件）可能引用该 CAD 文档；无法确定唯一目标。请从具体画布节点打开后再更新，未写入。",
            "Multiple canvas nodes (or only same-name files) may reference this CAD document; the target is ambiguous. Open it from the specific canvas node to update it. Nothing was written.")
    }

    /// One patch applied with bounded revision-CAS retries against the exact
    /// canvas file, plus creative-asset reference reconciliation. Returns the
    /// operation result on success; nil when the write failed.
    ///
    /// `expectedSource` re-validates the EXACT node→package binding inside
    /// every CAS attempt: if the node was re-bound to another CAD document
    /// while the render was produced, the write refuses instead of stamping
    /// the wrong package's render onto it.
    @discardableResult
    /// Shared with `LegacySceneMigrationService` (same revision-CAS commit).
    static func commit(
        operations: [CanvasPatchOperation],
        nodeID: UUID?,
        canvasID: UUID,
        documentID: UUID,
        assetStore: CreativeAssetStore,
        expectedSource: (nodeID: UUID, sourceKey: String)? = nil
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
            if let expectedSource {
                guard let node = current.documents.flatMap(\.nodes)
                        .first(where: { $0.id == expectedSource.nodeID }),
                      node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath]?
                        .caseInsensitiveCompare(expectedSource.sourceKey) == .orderedSame else {
                    throw CADDocumentError(code: "node_unbound", message: canvasLocalized(
                        "原节点的 CAD 引用已改变；未写入。",
                        "The original node's CAD reference changed; nothing was written."))
                }
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
    static func sourcePathKey(packageURL: URL) -> String {
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
