// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

/// This is a canvas tool. Properties provide context and exact optional
/// adjustment; the primary interaction remains the four visible controls.
struct MediaV2ImageWarpInspector: View {
    @Bindable var session: MediaV2Session
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = session.imageWarpDraft {
                Label(draft.layer.name, systemImage: "photo.on.rectangle").font(.subheadline).lineLimit(2)
                Text(WorkbenchText.t("拖动四个控制点变形，或拖动中心移动。预览后应用。", "Drag the four handles to reshape, or drag the center to move. Then apply the preview."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { draft.undo() } label: { Label(WorkbenchText.t("撤销调整", "Undo adjustment"), systemImage: "arrow.uturn.backward") }
                        .disabled(!draft.canUndo || session.processingTool)
                    Button { draft.reset() } label: { Label(WorkbenchText.t("还原", "Reset"), systemImage: "arrow.counterclockwise") }
                        .disabled(!draft.isDirty || session.processingTool)
                }.buttonStyle(.bordered).frame(minHeight: 44)
                if let message = draft.message { Text(message).font(.caption).foregroundStyle(draft.isValid ? Color.secondary : .red) }
                Text(WorkbenchText.t("Enter 应用，Esc 取消；方向键微调，Shift 加速。", "Enter applies, Esc cancels. Arrow keys nudge; Shift moves faster."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(WorkbenchText.t("原始图片会保留，应用后仍可撤销。", "The original image is kept. You can undo after applying."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(WorkbenchText.t("在画布中调整", "Adjust on the canvas"), systemImage: "viewfinder")
                Text(WorkbenchText.t("选择一个可见的图片、文字或图形图层。", "Choose a visible image, text, or shape layer."))
                    .font(.callout).foregroundStyle(.secondary)
                Button { prepare() } label: { Label(WorkbenchText.t("开始调整", "Start transform"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered).frame(minHeight: 44).disabled(session.selectedLayer == nil || session.processingTool || session.saving)
            }
        }
    }
    private func prepare() {
        Task { do { try await session.prepareImageWarpDraft() }
            catch is CancellationError {}
            catch { session.diagnostic = warpUserMessage(error) } }
    }
}

struct MediaV2ImageWarpCanvasOverlay: View {
    @Bindable var session: MediaV2Session
    @AppStorage(MediaDrawingInputPolicy.preferenceKey) private var fingerEditing = false
    @State private var preparing = false
    @State private var preparationGeneration = UUID()
    @State private var selectionGeneration = UUID()
    private var contextIdentity: String {
        "\(session.id)/\(session.document.revision)/\(session.selectedLayerID?.uuidString ?? "")/\(session.processingTool)/\(selectionGeneration)"
    }
    var body: some View {
        ZStack {
            if let draft = session.imageWarpDraft {
                MediaV2WarpHandleSurface(points: draft.quad.points.map { .init(x: $0.x,y: $0.y) },
                    canvasPixels: .init(width: draft.sourceGeometry.width,height: draft.sourceGeometry.height), displayScale: CGFloat(session.zoom), fingerEditing: fingerEditing, valid: draft.isValid,
                    onBegin: { draft.beginDrag() }, onChange: { draft.moveCorner($0,to: $1) }, onEnd: { draft.endDrag() },
                    onCancel: { draft.endDrag(cancelled: true) }, onApply: { draft.apply() }, onDiscard: { session.discardImageWarpDraft() })
                    .allowsHitTesting(!session.processingTool && !session.saving)
            }
            if preparing { ProgressView(WorkbenchText.t("正在读取图层…", "Reading layer…")).padding(10).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 10)) }
        }.task(id: contextIdentity) { await prepare() }
            .onChange(of: session.selection) { _,_ in selectionGeneration = UUID() }
            .onChange(of: session.tool) { _, tool in
                guard MediaV2Session.imageWarpToolIDs.contains(tool) else { session.discardImageWarpDraft(); return }
                session.imageWarpDraft?.setMode(tool == "image.perspective" ? .perspective : .bilinear)
            }
            .onDisappear { session.imageWarpDraft?.cancelPreview() }
    }
    private func prepare() async {
        guard !session.processingTool, !session.saving else { return }
        let generation = UUID(); preparationGeneration = generation; preparing = true
        defer { if preparationGeneration == generation { preparing = false } }
        do { try await session.prepareImageWarpDraft() }
        catch is CancellationError {}
        catch { if !Task.isCancelled { session.diagnostic = warpUserMessage(error) } }
    }
}

/// Outside the scaled canvas, so native controls retain 44-point hit targets
/// at every zoom and remain usable in compact iPhone layouts.
struct MediaV2ImageWarpActionBar: View {
    @Bindable var session: MediaV2Session
    var body: some View {
        Group {
            if let draft = session.imageWarpDraft {
                HStack(spacing: 8) {
                    if session.processingTool {
                        ProgressView().padding(.horizontal, 8)
                        Button { session.cancelToolProcessing() } label: { Label(WorkbenchText.t("取消处理", "Cancel processing"),systemImage: "xmark") }
                    } else {
                        Button { session.discardImageWarpDraft() } label: { Label(WorkbenchText.t("取消", "Cancel"),systemImage: "xmark") }
                        Button { draft.undo() } label: { Label(WorkbenchText.t("撤销调整", "Undo adjustment"),systemImage: "arrow.uturn.backward") }.disabled(!draft.canUndo)
                        Button { draft.reset() } label: { Label(WorkbenchText.t("还原", "Reset"),systemImage: "arrow.counterclockwise") }.disabled(!draft.isDirty)
                        if draft.rendering { ProgressView().controlSize(.small).frame(width: 32) }
                        Button { draft.apply() } label: { Label(WorkbenchText.t("应用", "Apply"),systemImage: "checkmark") }
                            .disabled(!draft.isDirty || !draft.isValid || session.saving)
                            .accessibilityIdentifier("media.warp.apply")
                    }
                }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
                    .padding(8).background(.regularMaterial,in: Capsule()).padding(10)
            } else if session.selectedLayer != nil, !session.processingTool {
                Button { Task { do { try await session.prepareImageWarpDraft() } catch { session.diagnostic = warpUserMessage(error) } } } label: {
                    Label(WorkbenchText.t("调整图层", "Transform layer"),systemImage: "arrow.up.left.and.arrow.down.right").padding(.horizontal, 12).frame(minHeight: 44)
                }.buttonStyle(.bordered).background(.regularMaterial,in: Capsule()).padding(10)
            }
        }
    }
}
private func warpUserMessage(_ error: any Error) -> String {
    guard let error = error as? MediaImageWarpError else { return error.localizedDescription }
    switch error {
    case .emptyVisiblePixels: return WorkbenchText.t("所选范围没有可见内容，请选择图片内容。", "This area has no visible content. Select image content first.")
    case .resourceLimit: return WorkbenchText.t("图片较大，请先缩小画布后重试。", "This image exceeds the transform limit. Reduce the canvas size and retry.")
    case .invalidGeometry: return WorkbenchText.t("请将控制点拖回不交叉的位置。", "Move the control points so the edges do not cross.")
    case .cancelled: return WorkbenchText.t("已取消", "Canceled")
    case .renderFailed: return WorkbenchText.t("无法预览此变形，请调整后重试。", "Could not preview this transform. Adjust it and retry.")
    }
}
#endif
