// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2CanvasInspector: View {
    @Bindable var session:MediaV2Session
    @State private var width=1600
    @State private var height=1200
    @State private var keepRatio=true
    @State private var ratio=4.0/3.0
    @State private var anchor=4
    private var resizing:Bool { session.tool == "image.resize" }
    private var valid:Bool { width>0 && height>0 && width<=16_384 && height<=16_384 && width*height<=64_000_000 }
    private var changed:Bool { session.document.canvas?.width != width || session.document.canvas?.height != height }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if let current=session.document.canvas {
                Label("\(current.width) × \(current.height) px",systemImage:resizing ? "photo":"square.dashed")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
            }
            dimension(WorkbenchText.t("宽度", "Width"),symbol:"arrow.left.and.right",value:Binding(get:{width},set:{value in
                width=value;if resizing && keepRatio,value>0,value<=16_384 { height=max(1,Int((Double(value)/ratio).rounded())) }
            }))
            dimension(WorkbenchText.t("高度", "Height"),symbol:"arrow.up.and.down",value:Binding(get:{height},set:{value in
                height=value;if resizing && keepRatio,value>0,value<=16_384 { width=max(1,Int((Double(value)*ratio).rounded())) }
            }))
            if resizing {
                Toggle(isOn:$keepRatio) { Label(WorkbenchText.t("保持宽高比", "Keep aspect ratio"),systemImage:"link") }.frame(minHeight:44)
                Text(WorkbenchText.t("调整作品尺寸，图层仍可继续编辑。", "Resize the work while keeping its layers editable.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Label(WorkbenchText.t("内容位置", "Content anchor"),systemImage:"arrow.up.left.and.down.right.and.arrow.up.right.and.down.left").font(.subheadline.weight(.medium))
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(44),spacing:4),count:3),spacing:4) {
                    ForEach(0..<9) { index in
                        Button { anchor=index } label: {
                            Image(systemName:index == anchor ? "circle.inset.filled":anchorSymbol(index)).frame(width:44,height:44)
                                .background(index == anchor ? Color.accentColor.opacity(0.12):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:6))
                        }.buttonStyle(.plain).accessibilityLabel(anchorName(index)).accessibilityAddTraits(index == anchor ? .isSelected:[])
                    }
                }
                Text(WorkbenchText.t("选择原内容在新画布中的位置。", "Choose where the existing content sits in the new canvas.")).font(.caption).foregroundStyle(.secondary)
            }
            if !valid { Label(WorkbenchText.t("宽高须为 1–16384 像素，总像素不超过 6400 万。", "Use 1–16384 pixels per edge, up to 64 megapixels total."),systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            MediaV2InspectorApplyButton(title:resizing ? WorkbenchText.t("调整图像尺寸", "Resize image"):WorkbenchText.t("调整画布尺寸", "Resize canvas"),isWorking:session.canvasLayoutInProgress,action:apply)
                .disabled(!valid || !changed || session.saving || session.processingTool)
            if session.canvasLayoutInProgress {
                ProgressView(WorkbenchText.t("正在调整尺寸…", "Resizing…"))
                Button(WorkbenchText.t("取消处理", "Cancel processing"),systemImage:"xmark.circle") { session.cancelToolProcessing() }.frame(minHeight:44)
            } else if session.processingTool {
                Label(session.providerStatus ?? WorkbenchText.t("另一项处理正在进行。", "Another operation is running."),systemImage:"hourglass").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear(perform:load).onChange(of:session.tool) { _,_ in load() }.onChange(of:session.document.canvas) { _,_ in load() }.onChange(of:keepRatio) { _,locked in if locked,width>0,height>0 { ratio=Double(width)/Double(height) } }
    }
    private func dimension(_ title:String,symbol:String,value:Binding<Int>) -> some View {
        HStack(spacing:10) {
            Label(title,systemImage:symbol).frame(maxWidth:.infinity,alignment:.leading)
            TextField(title,value:value,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                .multilineTextAlignment(.trailing).frame(width:104).frame(minHeight:44).accessibilityLabel(title)
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func load() { width=session.document.canvas?.width ?? 1600;height=session.document.canvas?.height ?? 1200;ratio=Double(width)/Double(max(1,height)) }
    private func anchorSymbol(_ index:Int) -> String { ["arrow.up.left","arrow.up","arrow.up.right","arrow.left","circle","arrow.right","arrow.down.left","arrow.down","arrow.down.right"][index] }
    private func anchorName(_ index:Int) -> String { [WorkbenchText.t("左上", "Top left"),WorkbenchText.t("上方", "Top"),WorkbenchText.t("右上", "Top right"),WorkbenchText.t("左侧", "Left"),WorkbenchText.t("居中", "Center"),WorkbenchText.t("右侧", "Right"),WorkbenchText.t("左下", "Bottom left"),WorkbenchText.t("下方", "Bottom"),WorkbenchText.t("右下", "Bottom right")][index] }
    private func apply() {
        var input=MediaV2ToolInput();input.expectedRevision=session.document.revision;input.number=Double(width);input.secondary=Double(height)
        if !resizing { input.points=[.init(x:Double(anchor%3)/2,y:Double(anchor/3)/2)] }
        let tool=session.tool
        Task { do { _ = try await session.performTool(tool,input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
}
#endif
