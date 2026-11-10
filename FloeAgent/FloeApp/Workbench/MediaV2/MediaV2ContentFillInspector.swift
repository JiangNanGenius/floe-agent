// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2ContentFillInspector:View {
    @Bindable var session:MediaV2Session
    let onImport:() -> Void
    @State private var mode=MediaContentFillMode.adaptive
    @State private var quality=MediaContentFillQuality.balanced
    @State private var nearby=true
    @State private var expansion=0.0
    private var removing:Bool { session.tool=="image.remove" }
    private var targets:[MediaPreparedLayer] { session.document.layers.filter{$0.parentID==nil && ![MediaPreparedLayerContentKind.group,.adjustment].contains($0.contentKind)} }
    private var usable:Bool { guard let layer=session.selectedLayer else { return false };return targets.contains{$0.id==layer.id} && !layer.isLocked && layer.isVisible }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if let layer=session.selectedLayer {
                Label(layer.name,systemImage:layer.isLocked ? "lock.fill":"photo.on.rectangle").font(.subheadline.weight(.medium))
                Menu {
                    ForEach(targets) { value in Button { session.select(value) } label: { Label(value.name,systemImage:value.id==layer.id ? "checkmark":"photo") } }
                } label: { Label(WorkbenchText.t("选择处理图层", "Choose target layer"),systemImage:"square.3.layers.3d").frame(minHeight:44) }
                if layer.isLocked { Button(WorkbenchText.t("解锁图层", "Unlock layer"),systemImage:"lock.open") { session.submit([.updateLayerFlags(id:layer.id,expectedRevision:layer.revision,name:nil,isVisible:nil,isLocked:false,opacity:nil)]) }.frame(minHeight:44) }
                if !layer.isVisible { Button(WorkbenchText.t("显示图层", "Show layer"),systemImage:"eye") { session.submit([.updateLayerFlags(id:layer.id,expectedRevision:layer.revision,name:nil,isVisible:true,isLocked:nil,opacity:nil)]) }.frame(minHeight:44) }
                if !targets.contains(where:{$0.id==layer.id}) { Text(WorkbenchText.t("请选择独立的图片、绘画或文字图层。", "Choose an individual image, drawing or text layer.")).font(.caption).foregroundStyle(.secondary) }
            } else {
                ContentUnavailableView { Label(WorkbenchText.t("先选择图像", "Select an image first"),systemImage:"photo") }
                description: { Text(WorkbenchText.t("导入图片，再选择需要处理的图层。", "Import an image and select the layer to edit.")) }
                actions: { Button(WorkbenchText.t("导入图片", "Import image"),systemImage:"plus",action:onImport).frame(minHeight:44) }
            }
            if session.selection==nil {
                Label(removing ? WorkbenchText.t("请选择要移除的对象。", "Select the object to remove."):WorkbenchText.t("请选择需要填补的区域。", "Select the area to fill."),systemImage:"rectangle.dashed").font(.callout)
            } else { Label(WorkbenchText.t("已选定处理区域", "Edit area selected"),systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:8) {
                Button(WorkbenchText.t("选择主体", "Select subject"),systemImage:"person.crop.rectangle") { selectSubject() }
                    .frame(maxWidth:.infinity,minHeight:44).disabled(!usable || session.processingTool || session.saving)
                Button(WorkbenchText.t("框选", "Select area"),systemImage:"rectangle.dashed") { session.tool="image.rectangle" }
                    .frame(maxWidth:.infinity,minHeight:44).disabled(session.processingTool)
            }.buttonStyle(.bordered)
            Group {
                Picker(WorkbenchText.t("匹配方式", "Matching"),selection:$mode) {
                    Text(WorkbenchText.t("适应光照", "Adapt colors")).tag(MediaContentFillMode.adaptive)
                    Text(WorkbenchText.t("保持纹理", "Keep texture")).tag(MediaContentFillMode.texture)
                }.pickerStyle(.segmented).frame(minHeight:44)
                Toggle(WorkbenchText.t("优先从附近取样", "Sample nearby image"),isOn:$nearby).frame(minHeight:44)
                Picker(WorkbenchText.t("处理质量", "Quality"),selection:$quality) {
                    Text(WorkbenchText.t("快速", "Fast")).tag(MediaContentFillQuality.fast)
                    Text(WorkbenchText.t("标准", "Standard")).tag(MediaContentFillQuality.balanced)
                    Text(WorkbenchText.t("细致", "Detailed")).tag(MediaContentFillQuality.detailed)
                }
                LabeledContent(WorkbenchText.t("扩展选区边缘", "Expand selection edge"),value:"\(Int(expansion)) px")
                Slider(value:$expansion,in:0...12,step:1).accessibilityLabel(WorkbenchText.t("扩展选区边缘", "Expand selection edge"))
            }.disabled(session.processingTool || session.saving)
            Text(WorkbenchText.t("从周围画面匹配纹理。较大区域可分几次处理，原始内容可通过撤销恢复。", "Match texture from the surrounding image. Fill larger areas in stages; undo restores the original content.")).font(.caption).foregroundStyle(.secondary)
            Button(action:run) { Label(removing ? WorkbenchText.t("移除所选对象", "Remove selected object"):WorkbenchText.t("填补选区", "Fill selection"),systemImage:removing ? "eraser":"square.dotted").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!usable || session.selection==nil || session.processingTool || session.saving)
            if session.processingTool {
                ProgressView(WorkbenchText.t("正在处理画面…", "Processing image…"))
                Button(WorkbenchText.t("取消处理", "Cancel processing"),systemImage:"xmark.circle") { session.cancelToolProcessing() }.frame(minHeight:44)
            }
        }
    }
    private func selectSubject() {
        var input=MediaV2ToolInput();input.objectID=session.selectedLayerID;input.expectedRevision=session.document.revision
        Task { do { _ = try await session.performTool("image.subject",input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
    private func run() {
        var input=MediaV2ToolInput();input.objectID=session.selectedLayerID;input.expectedRevision=session.document.revision
        input.property=mode.rawValue;input.number=expansion;input.secondary=Double(quality.rawValue);input.flag=nearby
        let tool=session.tool
        Task { do { _ = try await session.performTool(tool,input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
}
#endif
