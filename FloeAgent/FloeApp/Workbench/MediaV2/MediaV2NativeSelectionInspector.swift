// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2NativeSelectionInspector:View {
    @Bindable var session:MediaV2Session
    @State private var amount=6.0
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            if session.tool == "image.wand" {
                Text(WorkbenchText.t("点按画布选择相近颜色的连续区域。", "Tap the canvas to select a connected area of similar color.")).font(.caption).foregroundStyle(.secondary)
                MusicValueSlider(title:WorkbenchText.t("容差", "Tolerance"),value:session.wandTolerance,range:0...1){session.wandTolerance=$0}
                Picker(WorkbenchText.t("选区运算", "Selection operation"),selection:$session.selectionMode){Text(WorkbenchText.t("新建", "New")).tag(ImageSelectionOperation.replace);Text(WorkbenchText.t("添加", "Add")).tag(ImageSelectionOperation.add);Text(WorkbenchText.t("减去", "Subtract")).tag(ImageSelectionOperation.subtract)}.pickerStyle(.segmented)
            }else if ["image.expand","image.smooth","image.refine-edge"].contains(session.tool){
                MediaV2NumberField(title:WorkbenchText.t("半径", "Radius"),value:$amount,suffix:"px")
                if session.tool == "image.expand"{Text(WorkbenchText.t("正数扩展，负数收缩。", "Positive expands; negative contracts.")).font(.caption).foregroundStyle(.secondary)}
                Button(WorkbenchText.t("应用到选区", "Apply to selection")){run()}.frame(minHeight:44).disabled(session.selection==nil || session.processingTool)
            }else{
                Button(session.tool == "image.background" ? WorkbenchText.t("移除背景", "Remove background"):WorkbenchText.t("选择主体", "Select subject")){run()}.frame(minHeight:44).disabled(session.selectedLayer==nil || session.processingTool)
                Text(WorkbenchText.t("处理当前图片图层，原图会保留。", "Process the current image layer while retaining its source.")).font(.caption).foregroundStyle(.secondary)
            }
            if session.processingTool{ProgressView();Button(WorkbenchText.t("取消处理", "Cancel processing")){session.cancelToolProcessing()}.frame(minHeight:44)}
            if session.selection != nil{Button(WorkbenchText.t("应用为图层蒙版", "Apply as layer mask")){run("image.layer-mask")}.frame(minHeight:44)}
        }
    }
    private func run(_ supplied:String? = nil){
        let tool=supplied ?? session.tool;var input=MediaV2ToolInput();input.expectedRevision=session.document.revision
        input.objectID=session.selectedLayerID;input.number=amount
        Task{do{_=try await session.performTool(tool,input:input)}catch{session.diagnostic=error.localizedDescription}}
    }
}
struct MediaV2BitmapSelectionOverlay:View {
    let selection:ImageSelection
    let canvas:MediaCanvas
    @State private var image:CGImage?
    var body:some View{
        Group{if let image{Image(decorative:image,scale:1).resizable().colorMultiply(.accentColor).opacity(0.3)}}
            .allowsHitTesting(false).accessibilityHidden(true)
            .task(id:selection){
                let source=selection,width=canvas.width,height=canvas.height
                let worker=Task.detached(priority:.utility){try MediaNativeSelection.flattened(source,width:width,height:height).cgImage}
                do{let value=try await withTaskCancellationHandler{try await worker.value}onCancel:{worker.cancel()};try Task.checkCancellation();image=value}catch is CancellationError{}catch{image=nil}
            }
    }
}
#endif
