// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2OutpaintInspector: View {
    @Bindable var session:MediaV2Session
    let configured:Bool
    let onImport:() -> Void
    @State private var width=2000
    @State private var height=1500
    @State private var anchor=4
    @State private var prompt=""
    @State private var modelID:UUID?
    private var old:MediaCanvas? { session.document.canvas }
    private var layout:MediaOutpaintLayout? {
        guard let old else { return nil }
        return try? .init(sourceWidth:old.width,sourceHeight:old.height,width:width,height:height,anchor:point)
    }
    private var point:ImageFreehandStroke.Point { .init(x:Double(anchor%3)/2,y:Double(anchor/3)/2) }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if session.document.layers.isEmpty {
                ContentUnavailableView {
                    Label(WorkbenchText.t("先添加画面", "Add an image first"),systemImage:"photo.badge.plus")
                } description: { Text(WorkbenchText.t("导入图片或绘制内容，再向画布外扩展。", "Import an image or draw content, then expand beyond its canvas.")) }
                actions: { Button(WorkbenchText.t("导入图片", "Import image"),systemImage:"plus",action:onImport).frame(minHeight:44) }
            } else {
                targetPreview
                HStack(spacing:8) {
                    ForEach([1.25,1.5],id:\.self) { factor in
                        Button { preset(factor) } label: { Text(factor==1.25 ? "+25%":"+50%").frame(maxWidth:.infinity,minHeight:44) }
                            .buttonStyle(.bordered).disabled(!presetValid(factor) || session.processingTool)
                    }
                }
                dimension(WorkbenchText.t("宽度", "Width"),value:$width)
                dimension(WorkbenchText.t("高度", "Height"),value:$height)
                Label(WorkbenchText.t("原画面位置", "Original image anchor"),systemImage:"arrow.up.left.and.down.right.and.arrow.up.right.and.down.left").font(.subheadline.weight(.medium))
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(44),spacing:4),count:3),spacing:4) {
                    ForEach(0..<9) { index in
                        Button { anchor=index } label: {
                            Image(systemName:index==anchor ? "circle.inset.filled":anchorSymbol(index)).frame(width:44,height:44)
                                .background(index==anchor ? Color.accentColor.opacity(0.12):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:6))
                        }.buttonStyle(.plain).accessibilityLabel(anchorName(index)).accessibilityAddTraits(index==anchor ? .isSelected:[])
                    }
                }
                VStack(alignment:.leading,spacing:6) {
                    Text(WorkbenchText.t("边缘应如何延展？", "How should the scene extend?")).font(.subheadline.weight(.medium))
                    TextField(WorkbenchText.t("例如：延展远处的海岸与天空", "For example: extend the distant coast and sky"),text:$prompt,axis:.vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder)
                }
                Picker(WorkbenchText.t("图像模型", "Image model"),selection:$modelID) {
                    Text(WorkbenchText.t("使用默认模型", "Use default model")).tag(Optional<UUID>.none)
                    ForEach(MediaV2ProviderBridge.imageRoutes) { route in Text(route.title).tag(Optional(route.id)) }
                }
                Text(WorkbenchText.t("仅生成新边缘。原图层、文字和透明区域会保留，可撤销。", "Generate only new margins. Original layers, text and transparency stay editable; the expansion can be undone.")).font(.caption).foregroundStyle(.secondary)
                if layout==nil {
                    Label(WorkbenchText.t("请扩大至少一边，不缩小原画面；单边不超过 8192 像素，总像素不超过 800 万。", "Expand at least one edge without shrinking the original, up to 8192 pixels per edge and 8 megapixels total."),systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                Button(action:run) { Label(WorkbenchText.t("生成扩展边缘", "Generate expanded margins"),systemImage:"sparkles").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).disabled(!configured || layout==nil || prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || session.processingTool || session.saving)
            }
        }.onAppear(perform:load).onChange(of:session.document.canvas) { _,_ in load() }
    }
    private var targetPreview:some View {
        VStack(alignment:.leading,spacing:6) {
            Label("\(width) × \(height) px",systemImage:"arrow.up.left.and.arrow.down.right").font(.subheadline.weight(.medium)).monospacedDigit()
            GeometryReader { proxy in
                let targetWidth=Double(max(1,width)),targetHeight=Double(max(1,height))
                let scale=min(proxy.size.width/targetWidth,proxy.size.height/targetHeight)
                let w=targetWidth*scale,h=targetHeight*scale
                let oldWidth=Double(old?.width ?? 1),oldHeight=Double(old?.height ?? 1)
                let x=(targetWidth-oldWidth)*point.x,y=(targetHeight-oldHeight)*point.y
                ZStack(alignment:.topLeading) {
                    Rectangle().fill(.quaternary)
                    if let preview=session.preview {
                        Image(decorative:preview,scale:1).resizable().frame(width:oldWidth*scale,height:oldHeight*scale)
                            .offset(x:x*scale,y:y*scale)
                    }
                    Rectangle().stroke(Color.accentColor,lineWidth:1).frame(width:oldWidth*scale,height:oldHeight*scale).offset(x:x*scale,y:y*scale)
                }.frame(width:w,height:h).clipped().position(x:proxy.size.width/2,y:proxy.size.height/2)
            }.frame(height:160).accessibilityElement(children:.ignore).accessibilityLabel(WorkbenchText.t("扩展范围预览", "Expansion area preview"))
        }
    }
    private func dimension(_ title:String,value:Binding<Int>) -> some View {
        HStack(spacing:10) {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            TextField(title,value:value,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width:104).frame(minHeight:44)
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func presetValid(_ factor:Double) -> Bool {
        guard let old else { return false }
        return (try? MediaOutpaintLayout(sourceWidth:old.width,sourceHeight:old.height,width:Int((Double(old.width)*factor).rounded()),height:Int((Double(old.height)*factor).rounded()),anchor:point)) != nil
    }
    private func preset(_ factor:Double) { guard let old else { return };width=Int((Double(old.width)*factor).rounded());height=Int((Double(old.height)*factor).rounded()) }
    private func load() { preset(1.25) }
    private func anchorSymbol(_ index:Int) -> String { ["arrow.up.left","arrow.up","arrow.up.right","arrow.left","circle","arrow.right","arrow.down.left","arrow.down","arrow.down.right"][index] }
    private func anchorName(_ index:Int) -> String { [WorkbenchText.t("左上", "Top left"),WorkbenchText.t("上方", "Top"),WorkbenchText.t("右上", "Top right"),WorkbenchText.t("左侧", "Left"),WorkbenchText.t("居中", "Center"),WorkbenchText.t("右侧", "Right"),WorkbenchText.t("左下", "Bottom left"),WorkbenchText.t("下方", "Bottom"),WorkbenchText.t("右下", "Bottom right")][index] }
    private func run() {
        var input=MediaV2ToolInput();input.expectedRevision=session.document.revision;input.number=Double(width);input.secondary=Double(height);input.points=[point];input.text=prompt;input.property=modelID?.uuidString
        Task { do { _ = try await session.performTool("image.outpaint",input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
}
#endif
