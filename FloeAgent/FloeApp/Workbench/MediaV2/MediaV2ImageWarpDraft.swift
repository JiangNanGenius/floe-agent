// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import CoreGraphics
import FloeTools
import FloeWorkbench

/// Unsaved interactive state belongs to this existing editor session. The
/// actual document and its undo groups remain in the original coordinator.
@MainActor @Observable final class MediaV2ImageWarpDraft {
    weak var session: MediaV2Session?
    let revision: Int64
    let layer: MediaPreparedLayer
    let selection: ImageSelection?
    let sourceGeometry: MediaImageWarpGeometry
    let frozen: MediaPreparedDocument
    let assets: [UUID: URL]
    let source: CGImage
    let coverage: CGImage?
    var mode: MediaImageWarpMode
    private(set) var quad: MediaImageWarpQuad
    private(set) var preview: CGImage?
    private(set) var rendering = false
    private(set) var message: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var undoQuads: [MediaImageWarpQuad] = []
    @ObservationIgnored private var redoQuads: [MediaImageWarpQuad] = []
    @ObservationIgnored private var dragStart: MediaImageWarpQuad?
    var canUndo: Bool { !undoQuads.isEmpty }
    var canRedo: Bool { !redoQuads.isEmpty }
    var isDirty: Bool { quad != sourceGeometry.sourceQuad }
    var isValid: Bool { (try? quad.validate()) != nil }

    init(session: MediaV2Session, layer: MediaPreparedLayer, selection: ImageSelection?, frozen: MediaPreparedDocument,
        assets: [UUID: URL], input: MediaV2WarpPreviewInput, mode: MediaImageWarpMode) {
        self.session = session; self.revision = frozen.revision; self.layer = layer; self.selection = selection
        self.frozen = frozen; self.assets = assets; sourceGeometry = input.geometry
        source = input.source; coverage = input.coverage; self.mode = mode; quad = input.geometry.sourceQuad
    }
    func beginDrag() { dragStart = quad }
    func moveCorner(_ index: Int, to point: CGPoint) {
        guard (0...4).contains(index), point.x.isFinite, point.y.isFinite else { return }
        var points = quad.points
        if index == 4 {
            let original = (dragStart ?? quad).points
            let centerX = original.map(\.x).reduce(0,+)/4, centerY = original.map(\.y).reduce(0,+)/4
            let dx = max(-4-original.map(\.x).min()!,min(4-original.map(\.x).max()!,Double(point.x)-centerX))
            let dy = max(-4-original.map(\.y).min()!,min(4-original.map(\.y).max()!,Double(point.y)-centerY))
            points = original.map { .init(x: $0.x+dx,y: $0.y+dy) }
        } else { points[index] = .init(x: max(-4,min(4,Double(point.x))), y: max(-4,min(4,Double(point.y)))) }
        guard let value = try? MediaImageWarpQuad(points: points) else { return }
        quad = value; requestPreview()
    }
    func endDrag(cancelled: Bool = false) {
        guard let before = dragStart else { return }; dragStart = nil
        if cancelled { quad = before; requestPreview() }
        else if before != quad { remember(before) }
    }
    func reset() { guard isDirty else { return }; remember(quad); quad = sourceGeometry.sourceQuad; requestPreview() }
    func undo() { guard let value = undoQuads.popLast() else { return }; redoQuads.append(quad); quad = value; requestPreview() }
    func redo() { guard let value = redoQuads.popLast() else { return }; undoQuads.append(quad); quad = value; requestPreview() }
    func setMode(_ value: MediaImageWarpMode) { guard mode != value else { return }; mode = value; requestPreview() }
    func cancelPreview() { generation = UUID(); previewTask?.cancel(); previewTask = nil; rendering = false }
    private func remember(_ value: MediaImageWarpQuad) { undoQuads.append(value); if undoQuads.count > 64 { undoQuads.removeFirst() }; redoQuads = [] }
    func requestPreview() {
        cancelPreview(); message = nil
        guard isValid else { message = WorkbenchText.t("控制点不能交叉或重合。", "Keep the control points apart without crossing edges."); return }
        guard let session, let canvas = frozen.canvas else { return }
        let token = CancellationToken(), current = UUID(), expected = quad, mode = mode
        generation = current; rendering = true
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == current { rendering = false } }
            do {
                try await Task.sleep(for: .milliseconds(80))
                let result = try await withTaskCancellationHandler {
                    try await MediaV2WarpPixels.shared.apply(source, mode: mode, quad: expected, coverage: coverage, token: token)
                } onCancel: { token.cancel() }
                // One complete native stack render: original target is replaced,
                // not drawn below the moved preview a second time. Overrides
                // preserve order, adjustment layers and clipping dependencies.
                let image = try await session.imageRenderer.renderPrepared(frozen, canvas: .init(width: canvas.width,height: canvas.height),
                    resolveAsset: { [assets] in assets[$0] }, previewMaxEdge: 1_024,
                    rasterOverrides: [layer.id: result.image], outputMaxEdge: 1_024)
                try Task.checkCancellation()
                guard generation == current, session.document.id == frozen.id, session.document.revision == revision,
                      session.selectedLayerID == layer.id, session.selection == selection else { return }
                preview = image
            } catch {
                if generation == current, !Task.isCancelled { message = WorkbenchText.t("无法预览此变形，请调整控制点后重试。", "Could not preview this transform. Adjust the control points and retry.") }
            }
        }
    }
    func apply() {
        guard let session, isDirty, isValid, session.document.revision == revision, session.selectedLayerID == layer.id, session.selection == selection else { return }
        var input = MediaV2ToolInput(); input.objectID = layer.id; input.expectedRevision = revision
        input.selectionFence = try? StudioMediaObservation.media(session).selectionFence
        input.text = sourceGeometry.pixelSHA256; input.property = "apply"
        input.points = quad.points.map { .init(x: $0.x,y: $0.y) }
        let tool = mode == .perspective ? "image.perspective" : "image.distort"
        Task { do { _ = try await session.performTool(tool, input: input) }
            catch is CancellationError {}
            catch let error as MediaImageWarpError {
                switch error {
                case .cancelled: break
                case .invalidGeometry: session.diagnostic = WorkbenchText.t("请将控制点拖回不交叉的位置。", "Move the control points so the edges do not cross.")
                case .emptyVisiblePixels: session.diagnostic = WorkbenchText.t("所选范围没有可见内容，请选择图片内容。", "This area has no visible content. Select image content first.")
                case .resourceLimit: session.diagnostic = WorkbenchText.t("图片较大，请先缩小画布后重试。", "This image exceeds the transform limit. Reduce the canvas size and retry.")
                case .renderFailed: session.diagnostic = WorkbenchText.t("无法完成变形，请调整控制点后重试。", "Could not apply the transform. Adjust the control points and retry.")
                }
            }
            catch { session.diagnostic = error.localizedDescription }
        }
    }
}

extension MediaV2Session {
    var imageWarpPreview: CGImage? {
        guard Self.imageWarpToolIDs.contains(tool), let draft = imageWarpDraft, draft.revision == document.revision,
              draft.layer.id == selectedLayerID, draft.selection == selection else { return nil }
        return draft.preview
    }
    func prepareImageWarpDraft() async throws {
        guard Self.imageWarpToolIDs.contains(tool), !processingTool, !saving, !canvasLayoutInProgress, project.kind == .image,
              let layer = selectedLayer, !layer.isLocked, layer.isVisible, layer.parentID == nil,
              ![MediaPreparedLayerContentKind.group,.adjustment].contains(layer.contentKind) else {
            throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请选择画布顶层可见、未锁定的图片、文字或图形图层。", "Select a visible, unlocked image, text, or shape layer at the top level of the canvas."))
        }
        let mode: MediaImageWarpMode = tool == "image.perspective" ? .perspective : .bilinear
        if let draft = imageWarpDraft, draft.revision == document.revision, draft.layer == layer, draft.selection == selection {
            draft.setMode(mode); if draft.preview == nil { draft.requestPreview() }; return
        }
        discardImageWarpDraft()
        let frozen = document, region = selection, base = frozen.revision, urls = try resolvedAssets(), token = CancellationToken()
        try await withTaskCancellationHandler {
            let bindings = try await MediaV2WarpPixels.shared.captureSources(document: frozen, layerID: layer.id, root: root, assetURLs: urls, token: token)
            let image = try await renderedLayerImage(layer, revision: base)
            let mask = try await MediaV2WarpPixels.shared.coverage(region, width: image.width,height: image.height,token: token)
            let input = try await MediaV2WarpPixels.shared.previewInput(image, coverage: mask, token: token)
            try await MediaV2WarpPixels.shared.validateSources(bindings, token: token)
            try Task.checkCancellation()
            guard document.revision == base, selectedLayer == layer, selection == region, Self.imageWarpToolIDs.contains(tool) else { throw MediaPreparedCoreError.documentChanged }
            let draft = MediaV2ImageWarpDraft(session: self,layer: layer,selection: region,frozen: frozen,assets: urls,input: input,mode: tool == "image.perspective" ? .perspective : .bilinear)
            imageWarpDraft = draft; draft.requestPreview()
        } onCancel: { token.cancel() }
    }
}
#endif
