// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2CompoundInspector:View {
    @Bindable var session:MediaV2Session
    @State private var name=""
    private var selected:MediaPreparedClip? { session.selectedClip?.clip }
    private var busy:Bool { session.saving || session.processingTool || session.rendering }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            if let clip=selected,let compound=clip.compound {
                PersonalEditorAssetPreview(sourceID:"compound:\(session.id):\(clip.id):\(clip.revision)",title:compound.name) { pixels in
                    guard let located=session.document.trackGraph.clip(id:clip.id) else { throw MediaV2CommandError.missingSelection }
                    return try await PersonalEditorPreviewRequests.mediaClip(session:session,track:located.track,clip:located.clip,pixels:pixels)
                }.aspectRatio(16/9,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:5) {
                    Label(compound.name,systemImage:"square.stack.3d.up.fill").font(.headline)
                    Text(WorkbenchText.t("\(compound.source.trackGraph.tracks.count) 条轨道 · \(compound.source.trackGraph.tracks.flatMap(\.clips).count) 个片段","\(compound.source.trackGraph.tracks.count) tracks · \(compound.source.trackGraph.tracks.flatMap(\.clips).count) clips")).font(.caption).foregroundStyle(.secondary)
                    if compound.needsRender { Label(WorkbenchText.t("内部编辑已保存，预览待更新","Edits saved; preview needs updating"),systemImage:"arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                }
                Button { Task { do { try await session.openCompound(clip.id) } catch { session.diagnostic=error.localizedDescription } } } label: {
                    Label(WorkbenchText.t("编辑内部片段","Edit contents"),systemImage:"square.stack.3d.up").frame(maxWidth:.infinity,minHeight:44)
                }.buttonStyle(.borderedProminent).disabled(busy)
                Button { run("refresh",clipID:clip.id) } label: { Label(WorkbenchText.t("更新复合片段","Update compound clip"),systemImage:"arrow.triangle.2.circlepath").frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.bordered).disabled(busy)
                Menu {
                    Button(WorkbenchText.t("替换为内部片段","Replace with contents")) { run("expand",clipID:clip.id) }
                    Button(WorkbenchText.t("保留当前结果并恢复静音副本","Keep result and restore a muted copy")) { run("restoreMutedCopy",clipID:clip.id) }
                } label: { Label(WorkbenchText.t("展开与恢复","Expand and restore"),systemImage:"square.stack.3d.down.right").frame(maxWidth:.infinity,minHeight:44) }.disabled(busy)
            } else {
                Label(WorkbenchText.t("创建复合片段","Create compound clip"),systemImage:"square.stack.3d.up").font(.headline)
                TextField(WorkbenchText.t("复合片段名称","Compound name"),text:$name).textFieldStyle(.roundedBorder).frame(minHeight:44)
                Toggle(WorkbenchText.t("在时间轴多选片段","Select multiple timeline clips"),isOn:$session.multipleClipSelection).toggleStyle(.switch)
                Text(WorkbenchText.t("已选 \(session.compoundSelectedIDs.count) 个；关联原声会一并保留。","\(session.compoundSelectedIDs.count) selected; linked source audio is included.")).font(.caption).foregroundStyle(.secondary)
                Button { run("create") } label: { Label(WorkbenchText.t("创建并保存","Create and save"),systemImage:"square.stack.3d.up.fill").frame(maxWidth:.infinity,minHeight:44) }.buttonStyle(.borderedProminent).disabled(busy || session.compoundSelectedIDs.isEmpty)
            }
            if session.processingTool {
                HStack { ProgressView();Text(session.providerStatus ?? WorkbenchText.t("正在合成…","Compositing…")).font(.caption);Spacer();Button(WorkbenchText.t("取消","Cancel")) { session.cancelToolProcessing() }.frame(minHeight:44) }
            }
        }.disabled(session.compoundScopeID != nil)
    }
    private func run(_ action:String,clipID:UUID?=nil) {
        var input=MediaV2ToolInput();input.expectedRevision=session.document.revision;input.property=action;input.objectID=clipID
        if action == "create" { input.clipIDs=Array(session.compoundSelectedIDs);input.text=name }
        Task { do { _ = try await session.performTool("video.nest",input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
}

/// The accepted MediaV2 canvas/timeline/controls are reused for the projected
/// source. There is no alternate editor, project file or view-owned undo stack.
struct MediaV2CompoundEditor:View {
    @Bindable var rootSession:MediaV2Session
    let route:MediaV2CompoundRoute
    var onAssistant:(()->Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmClose=false
    @State private var closing=false
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Button { requestClose() } label: { Image(systemName:"chevron.backward").frame(width:44,height:44) }.accessibilityLabel(WorkbenchText.t("返回原片段","Back to original")).frame(minHeight:44)
                Divider().frame(height:22)
                Label(route.name,systemImage:"square.stack.3d.up").font(.headline).lineLimit(1)
                Spacer(minLength:8)
                Button { updateAndClose() } label: { Label(WorkbenchText.t("更新","Update"),systemImage:"checkmark.circle").lineLimit(1) }.buttonStyle(.borderedProminent).frame(minHeight:44).disabled(rootSession.processingTool || route.session.processingTool || closing)
            }.padding(.horizontal,12)
            if rootSession.processingTool { HStack { ProgressView();Text(rootSession.providerStatus ?? "").font(.caption);Spacer();Button(WorkbenchText.t("取消","Cancel")) { rootSession.cancelToolProcessing() } }.padding(.horizontal,12).frame(minHeight:44) }
            Divider()
            MediaV2Workspace(session:route.session,onAssistant:onAssistant)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        }.background(Color(uiColor:.systemBackground)).interactiveDismissDisabled(true)
        .confirmationDialog(WorkbenchText.t("内部编辑已保存，更新外层预览吗？","Your edits are saved. Update the outer preview?"),isPresented:$confirmClose,titleVisibility:.visible) {
            Button(WorkbenchText.t("保存并更新","Save and update")) { updateAndClose() }
            Button(WorkbenchText.t("稍后更新并返回","Return and update later")) { close() }
            Button(WorkbenchText.t("继续编辑","Keep editing"),role:.cancel) {}
        }
    }
    private func requestClose() {
        guard !rootSession.processingTool,!route.session.processingTool,!closing else { return }
        Task { do { try await rootSession.reload();if rootSession.document.trackGraph.clip(id:route.id)?.clip.compound?.needsRender == true { confirmClose=true } else { close() } } catch { rootSession.diagnostic=error.localizedDescription } }
    }
    private func updateAndClose() {
        guard !closing else { return };closing=true
        Task { defer { closing=false };do { try await rootSession.reload();var input=MediaV2ToolInput();input.expectedRevision=rootSession.document.revision;input.property="refresh";input.objectID=route.id;_ = try await rootSession.performTool("video.nest",input:input);close() } catch { route.session.diagnostic=error.localizedDescription } }
    }
    private func close() { route.session.stopPlayback();rootSession.compoundEditorRoute=nil;Task { try? await rootSession.reload() } }
}
#endif
