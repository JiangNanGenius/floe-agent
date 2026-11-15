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
                Text(WorkbenchText.t("点按画布选择相近颜色的连续区域。容差与选区模式在工具选项栏中调整。",
                                      "Tap the canvas to select a connected area of similar color. Tolerance and selection mode live in the tool options bar."))
                    .font(.caption).foregroundStyle(.secondary)
                if let selection = session.selection {
                    Text(WorkbenchText.t("当前选区为像素蒙版，羽化在工具选项栏调整。",
                                          "The current selection is a pixel mask; adjust feather in the tool options bar."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
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
/// Displays the actual coverage mask, including its applied or previewed
/// feather. Rendering is bounded so a live feather drag stays responsive and
/// never blocks the canvas.
struct MediaV2SelectionMaskOverlay:View {
    let selection:ImageSelection
    let canvas:MediaCanvas
    var maxEdge:Int = 768
    var opacity:Double = 0.24
    @State private var image:CGImage?
    var body:some View{
        Group{if let image{Image(decorative:image,scale:1).resizable().colorMultiply(.accentColor).opacity(opacity)}}
            .allowsHitTesting(false).accessibilityHidden(true)
            .task(id:OverlayKey(selection:selection,maxEdge:maxEdge)){
                // Coalesce rapid feather drags: only the latest selection state
                // is rasterized, and a superseded task stops before rendering.
                do{try await Task.sleep(for:.milliseconds(120))}catch{return}
                let source=selection,width=canvas.width,height=canvas.height,edge=maxEdge
                let worker=Task.detached(priority:.utility){try MediaNativeSelection.flattened(source,width:width,height:height,maxEdge:edge).cgImage}
                do{let value=try await withTaskCancellationHandler{try await worker.value}onCancel:{worker.cancel()};try Task.checkCancellation();image=value}catch is CancellationError{}catch{image=nil}
            }
    }
    private struct OverlayKey:Equatable{let selection:ImageSelection;let maxEdge:Int}
}
#endif
