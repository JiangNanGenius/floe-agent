// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2VectorTextInspector:View {
    @Bindable var session:MediaV2Session
    @State private var operation=MediaVectorBooleanOperation.union
    @State private var chosen=Set<UUID>()
    @State private var primaryID:UUID?
    @State private var pathID:UUID?
    @State private var text=""
    @State private var start=0.0
    @State private var baseline=0.0
    @State private var reversed=false
    @State private var length:Double?
    @State private var sourceRevision:Int64 = -1
    @State private var status:String?
    private var vectors:[MediaPreparedLayer] { session.document.layers.filter{$0.parentID==nil && $0.contentKind == .vectorPaths} }
    private var textLayers:[MediaPreparedLayer] { session.document.layers.filter{$0.parentID==nil && $0.contentKind == .text} }
    private var selectedText:ImageTextContent? { if case .text(let value)=session.selectedLayer?.content { value } else { nil } }
    private var fresh:Bool { sourceRevision==session.document.revision }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            if session.tool == "image.boolean" { booleanControls }
            else {
                textSource
                if let value=selectedText {
                    if session.tool == "image.path-text" { pathControls(value) }
                    else { outlineControls(value) }
                }
            }
            if !fresh {
                Label(WorkbenchText.t("作品已更新，请重新载入再应用。", "The work has changed. Reload before applying."),systemImage:"arrow.clockwise.circle").font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("重新载入", "Reload"),systemImage:"arrow.clockwise",action:load).frame(minHeight:44)
            }
            if session.processingTool {
                ProgressView(WorkbenchText.t("正在处理路径…", "Processing paths…"))
                Button(WorkbenchText.t("取消处理", "Cancel processing"),systemImage:"xmark.circle") { session.cancelToolProcessing() }.frame(minHeight:44)
            }
            if let status { Label(status,systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary) }
        }.onAppear(perform:load).onChange(of:session.tool) { _,_ in load() }.onChange(of:session.selectedLayerID) { _,_ in load() }
            .task(id:"\(session.document.revision):\(session.selectedLayerID?.uuidString ?? ""): \(pathID?.uuidString ?? "")") { await refreshLength() }
    }
    private var booleanControls:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(WorkbenchText.t("运算", "Operation"),selection:$operation) {
                ForEach(MediaVectorBooleanOperation.allCases,id:\.self) { value in Label(title(value),systemImage:symbol(value)).labelStyle(.iconOnly).tag(value) }
            }.pickerStyle(.segmented).frame(minHeight:44)
            Label(title(operation),systemImage:symbol(operation)).font(.subheadline.weight(.medium))
            Text(operation == .subtract ? WorkbenchText.t("从基准形状中减去其他形状。", "Subtract the other shapes from the primary shape."):WorkbenchText.t("选择填充形状，生成仍可编辑的矢量结果。", "Select filled shapes to create an editable vector result.")).font(.caption).foregroundStyle(.secondary)
            if vectors.count<2 {
                ContentUnavailableView { Label(WorkbenchText.t("需要两个形状", "Two shapes required"),systemImage:"square.on.circle") }
                description: { Text(WorkbenchText.t("先创建或导入填充的矢量形状。", "Create or import filled vector shapes first.")) }
                actions: { Button(WorkbenchText.t("添加形状", "Add shape"),systemImage:"plus") { session.tool="image.shape" }.frame(minHeight:44) }
            }
            ScrollView {
                LazyVStack(spacing:0) {
                    ForEach(vectors) { layer in
                        Button {
                            if chosen.contains(layer.id) { chosen.remove(layer.id);if primaryID==layer.id { primaryID=nil } } else { chosen.insert(layer.id) }
                        } label: {
                            HStack(spacing:8) {
                                Image(systemName:chosen.contains(layer.id) ? "checkmark.circle.fill":"circle")
                                Text(layer.name).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                                if layer.isLocked { Image(systemName:"lock.fill").foregroundStyle(.secondary) }
                            }.frame(minHeight:44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!eligible(layer))
                    }
                }
            }.frame(maxHeight:180)
            if chosen.count>=2 {
                Picker(WorkbenchText.t("基准形状", "Primary shape"),selection:$primaryID) {
                    Text(WorkbenchText.t("第一个所选形状", "First selected shape")).tag(Optional<UUID>.none)
                    ForEach(vectors.filter{chosen.contains($0.id)}) { layer in Text(layer.name).tag(Optional(layer.id)) }
                }
            }
            Button { run() } label: { Label(WorkbenchText.t("应用路径运算", "Apply path operation"),systemImage:symbol(operation)).frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!fresh || !(2...16).contains(chosen.count) || session.processingTool || session.saving)
        }
    }
    private var textSource:some View {
        VStack(alignment:.leading,spacing:8) {
            if textLayers.isEmpty {
                ContentUnavailableView { Label(WorkbenchText.t("需要文字图层", "Text layer required"),systemImage:"character.cursor.ibeam") }
                description: { Text(WorkbenchText.t("创建文字后，即可排版到路径或转换为轮廓。", "Create text to place it on a path or convert it to outlines.")) }
                actions: { Button(WorkbenchText.t("添加文字", "Add text"),systemImage:"plus") { session.addLayer(.text(.init(text:WorkbenchText.t("文字", "Text"))),name:WorkbenchText.t("文字", "Text")) }.frame(minHeight:44) }
            } else {
                Picker(WorkbenchText.t("文字图层", "Text layer"),selection:Binding(get:{session.selectedLayer?.contentKind == .text ? session.selectedLayerID:nil},set:{value in if let target=textLayers.first(where:{$0.id==value}) { session.select(target) }})) {
                    Text(WorkbenchText.t("选择文字", "Choose text")).tag(Optional<UUID>.none)
                    ForEach(textLayers) { layer in Text(layer.name).tag(Optional(layer.id)) }
                }
                if let layer=session.selectedLayer,layer.contentKind == .text,layer.isLocked {
                    Button(WorkbenchText.t("解锁文字图层", "Unlock text layer"),systemImage:"lock.open") { session.submit([.updateLayerFlags(id:layer.id,expectedRevision:layer.revision,name:nil,isVisible:nil,isLocked:false,opacity:nil)]) }.frame(minHeight:44)
                }
            }
        }
    }
    private func pathControls(_ value:ImageTextContent) -> some View {
        VStack(alignment:.leading,spacing:12) {
            TextField(WorkbenchText.t("文字内容", "Text"),text:$text).textFieldStyle(.roundedBorder).frame(minHeight:44)
            Button(WorkbenchText.t("编辑字体与样式", "Edit font and style"),systemImage:"textformat") { session.tool="image.text" }.frame(minHeight:44)
            Picker(WorkbenchText.t("排版路径", "Text path"),selection:$pathID) {
                Text(value.pathLayout==nil ? WorkbenchText.t("选择路径", "Choose path"):WorkbenchText.t("保持已保存路径", "Keep saved path")).tag(Optional<UUID>.none)
                ForEach(vectors.filter{if case .vectorPaths(let path)=$0.content { path.subpaths.count==1 } else { false }}) { layer in Text(layer.name).tag(Optional(layer.id)) }
            }
            if vectors.isEmpty && value.pathLayout==nil {
                Button(WorkbenchText.t("绘制路径", "Draw path"),systemImage:"point.topleft.down.to.point.bottomright.curvepath") { session.tool="image.pen" }.frame(minHeight:44)
            }
            if let length { LabeledContent(WorkbenchText.t("路径长度", "Path length"),value:"\(Int(length.rounded())) px").font(.caption).foregroundStyle(.secondary) }
            numeric(WorkbenchText.t("起点偏移", "Start offset"),value:$start)
            numeric(WorkbenchText.t("基线偏移", "Baseline offset"),value:$baseline)
            Toggle(WorkbenchText.t("沿反向路径排字", "Reverse path direction"),isOn:$reversed).frame(minHeight:44)
            Text(WorkbenchText.t("文字仍可编辑，所用路径会随作品保存。", "Text stays editable, and its path is saved with the work.")).font(.caption).foregroundStyle(.secondary)
            Button { run() } label: { Label(WorkbenchText.t("沿路径排版", "Place text on path"),systemImage:"textformat").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!fresh || (pathID==nil && value.pathLayout==nil) || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || session.selectedLayer?.isLocked==true || session.processingTool || session.saving)
        }
    }
    private func outlineControls(_ value:ImageTextContent) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(value.text).font(.body).lineLimit(4).textSelection(.enabled)
            Label("\(Int(value.fontSize.rounded())) pt",systemImage:"textformat.size").font(.caption).foregroundStyle(.secondary)
            Text(WorkbenchText.t("转换后可编辑每个字形的路径；可撤销以恢复文字编辑。", "Edit the glyph paths after conversion. Undo restores editable text.")).font(.caption).foregroundStyle(.secondary)
            if value.shadow != nil { Text(WorkbenchText.t("请先在文字样式中移除阴影。", "Remove the text shadow in its style settings first.")).font(.caption).foregroundStyle(.secondary) }
            Button(WorkbenchText.t("编辑文字样式", "Edit text style"),systemImage:"textformat") { session.tool="image.text" }.frame(minHeight:44)
            Button { run() } label: { Label(WorkbenchText.t("转换为矢量轮廓", "Convert to vector outlines"),systemImage:"point.topleft.down.to.point.bottomright.curvepath").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!fresh || session.selectedLayer?.isLocked==true || value.shadow != nil || session.processingTool || session.saving)
        }
    }
    private func numeric(_ title:String,value:Binding<Double>) -> some View {
        HStack {
            Text(title).frame(maxWidth:.infinity,alignment:.leading)
            TextField(title,value:value,format:.number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width:104).frame(minHeight:44)
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func eligible(_ layer:MediaPreparedLayer) -> Bool {
        guard !layer.isLocked,layer.mask==nil,layer.clip==nil,layer.adjustment.isIdentity,case .vectorPaths(let path)=layer.content else { return false }
        return path.fillColorHex != nil && path.subpaths.allSatisfy(\.isClosed)
    }
    private func title(_ operation:MediaVectorBooleanOperation) -> String { switch operation { case .union:WorkbenchText.t("合并填充区域", "Combine filled areas");case .subtract:WorkbenchText.t("减去其他形状", "Subtract other shapes");case .intersect:WorkbenchText.t("保留交集", "Keep intersection");case .xor:WorkbenchText.t("排除重叠区域", "Exclude overlap") } }
    private func symbol(_ operation:MediaVectorBooleanOperation) -> String { switch operation { case .union:"plus.square";case .subtract:"minus.square";case .intersect:"square.on.square";case .xor:"square.on.circle" } }
    private func load() {
        sourceRevision=session.document.revision;status=nil
        chosen=session.selectedLayerSet.intersection(Set(vectors.filter(eligible).map(\.id)))
        if let selected=session.selectedLayer,eligible(selected) { chosen.insert(selected.id) }
        primaryID=session.selectedLayerID.flatMap{chosen.contains($0) ? $0:nil}
        if let value=selectedText {
            text=value.text;start=value.pathLayout?.startOffset ?? 0;baseline=value.pathLayout?.normalOffset ?? 0;reversed=value.pathLayout?.isReversed ?? false
            pathID=value.pathLayout==nil ? vectors.first?.id:nil
        }
    }
    private func refreshLength() async {
        let document=session.document,source=pathID,text=selectedText
        let task=Task.detached(priority:.utility) { () throws -> Double? in
            let layout:MediaTextPathLayout
            if let source,let layer=document.layer(source),let canvas=document.canvas,let packed=try MediaNativeVectorGeometry.packed(try MediaNativeVectorGeometry.placedPath(layer,in:document),canvas:canvas,fill:nil) {
                layout = .init(path:packed.path,referenceCanvas:canvas,pathToCanvas:packed.canvasSpace.transform)
            } else if let saved=text?.pathLayout { layout=saved } else { return nil }
            return try MediaNativeTextGeometry.pathLength(layout)
        }
        let value=try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled,session.document.revision==document.revision,pathID==source else { return }
        length=value
    }
    private func run() {
        var input=MediaV2ToolInput();input.expectedRevision=sourceRevision
        if session.tool == "image.boolean" { input.objectIDs=session.document.layers.filter{chosen.contains($0.id)}.map(\.id);input.objectID=primaryID;input.property=operation.rawValue }
        else { input.objectID=session.selectedLayerID;if session.tool == "image.path-text" { input.property=pathID?.uuidString;input.text=text;input.number=start;input.secondary=baseline;input.flag=reversed } }
        let tool=session.tool,intersection=operation == .intersect
        Task {
            do {
                _ = try await session.performTool(tool,input:input);load()
                if tool == "image.boolean",intersection,session.selectedLayerID==nil { status=WorkbenchText.t("没有重叠区域；可撤销恢复。", "No overlapping area; undo restores the shapes.") }
            } catch { session.diagnostic=error.localizedDescription }
        }
    }
}
#endif
