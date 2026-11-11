// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeWorkbench

struct MediaV2ColorInspector: View {
    @Bindable var session: MediaV2Session
    @State private var controls = ImageLayerAdjustment()
    @State private var curveChannel = "RGB"
    @State private var tone = "midtones"
    @State private var lutName: String?
    @State private var showImport = false
    @State private var loadedKey = ""
    @State private var loadedRevision: Int64 = -1
    @State private var loadedLayerID: UUID?
    @State private var histogram: ImageColorHistogram?
    @State private var previewFailed = false

    private var contextKey: String { "\(session.selectedLayerID?.uuidString ?? "none")/\(session.document.revision)/\(session.tool)" }
    private struct PreviewRequest: Hashable {
        let key: String
        let controls: ImageLayerAdjustment
        let selection: ImageSelection?
    }
    private var previewRequest: PreviewRequest { .init(key: loadedKey, controls: inputControls, selection: session.selection) }
    private var inputControls: ImageLayerAdjustment {
        var value = controls
        switch session.tool {
        case "image.curves": value.toneCurve = value.toneCurve ?? MediaImageColorEditing.identityCurve
        case "image.balance": value.colorBalance = value.colorBalance ?? .init()
        case "image.lut": if value.colorLUT == nil { value.filterID = value.filterID ?? "CIPhotoEffectChrome" }
        default: value.noiseReduction = value.noiseReduction ?? 0.5; value.sharpenRadius = value.sharpenRadius ?? 20
        }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.tool == "image.curves" {
                Picker(WorkbenchText.t("通道", "Channel"), selection: $curveChannel) {
                    Text("RGB").tag("RGB"); Text(WorkbenchText.t("红", "Red")).tag("R")
                    Text(WorkbenchText.t("绿", "Green")).tag("G"); Text(WorkbenchText.t("蓝", "Blue")).tag("B")
                }.pickerStyle(.segmented)
                MediaV2ToneCurveEditor(points: curveBinding).frame(height: 180)
                    .background { if let histogram { MediaV2HistogramView(bins: histogramBins(histogram)) } }
                Button(WorkbenchText.t("重置当前通道", "Reset this channel")) { curveBinding.wrappedValue = MediaImageColorEditing.identityCurve }
                DisclosureGroup(WorkbenchText.t("控制点数值", "Control point values")) {
                    ForEach(0..<5, id: \.self) { index in
                        MusicValueSlider(title: "\(index + 1)", value: curveBinding.wrappedValue[index].y, range: 0...1) { value in
                            var points = curveBinding.wrappedValue; points[index].y = value; curveBinding.wrappedValue = points
                        }
                    }
                }
            } else if session.tool == "image.balance" {
                Picker(WorkbenchText.t("色调范围", "Tonal range"), selection: $tone) {
                    Text(WorkbenchText.t("阴影", "Shadows")).tag("shadows")
                    Text(WorkbenchText.t("中间调", "Midtones")).tag("midtones")
                    Text(WorkbenchText.t("高光", "Highlights")).tag("highlights")
                }.pickerStyle(.segmented)
                balanceChannel(WorkbenchText.t("青－红", "Cyan–red"), \.red)
                balanceChannel(WorkbenchText.t("洋红－绿", "Magenta–green"), \.green)
                balanceChannel(WorkbenchText.t("黄－蓝", "Yellow–blue"), \.blue)
                Toggle(WorkbenchText.t("保持亮度", "Preserve luminance"), isOn: Binding(
                    get: { controls.colorBalance?.preserveLuminance ?? true },
                    set: { var b = controls.colorBalance ?? .init(); b.preserveLuminance = $0; controls.colorBalance = b }))
            } else if session.tool == "image.lut" {
                Picker(WorkbenchText.t("滤镜", "Filter"), selection: Binding(
                    get: { controls.filterID ?? "CIPhotoEffectChrome" },
                    set: { controls.filterID = $0; controls.colorLUT = nil; lutName = nil })) {
                    Text(WorkbenchText.t("鲜艳", "Chrome")).tag("CIPhotoEffectChrome")
                    Text(WorkbenchText.t("黑白", "Mono")).tag("CIPhotoEffectMono")
                    Text(WorkbenchText.t("黑色电影", "Noir")).tag("CIPhotoEffectNoir")
                    Text(WorkbenchText.t("褪色", "Fade")).tag("CIPhotoEffectFade")
                    Text(WorkbenchText.t("即时成像", "Instant")).tag("CIPhotoEffectInstant")
                    Text(WorkbenchText.t("棕褐色", "Sepia")).tag("CISepiaTone")
                }
                Button(WorkbenchText.t("导入 .cube LUT", "Import .cube LUT")) { showImport = true }.frame(minHeight: 44)
                if controls.colorLUT != nil { Label(lutName ?? WorkbenchText.t("已保存的 LUT", "Saved LUT"), systemImage: "checkmark.circle") }
            } else {
                number(WorkbenchText.t("降噪", "Noise reduction"), \.noiseReduction, fallback: 0.5, range: 0...1)
                number(WorkbenchText.t("锐化", "Sharpen"), \.sharpenRadius, fallback: 20, range: 0...100)
            }
            if previewFailed { Text(WorkbenchText.t("暂时无法预览这组调整。", "This adjustment could not be previewed.")).font(.caption).foregroundStyle(.secondary) }
            Toggle(WorkbenchText.t("对比调整前", "Compare before adjustment"), isOn: $session.colorShowsOriginal).frame(minHeight: 44)
            Text(WorkbenchText.t("当前为预览，保存后生效。", "Changes are previewed until you save them.")).font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("保存调整", "Save adjustment"), action: apply).frame(minHeight: 44)
                .disabled(session.selectedLayer == nil || session.processingTool || session.saving || loadedKey != contextKey)
            if session.selection != nil { Text(WorkbenchText.t("仅调整当前选区。", "Only the current selection is adjusted.")).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: contextKey) { load() }
        .task(id: previewRequest) { await updatePreview() }
        .onDisappear { session.colorPreview = nil; session.colorShowsOriginal = false }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .data]) { result in importLUT(result) }
    }
    private var curveBinding: Binding<[ImageFreehandStroke.Point]> {
        Binding(get: {
            switch curveChannel {
            case "R": controls.channelCurves?.red ?? MediaImageColorEditing.identityCurve
            case "G": controls.channelCurves?.green ?? MediaImageColorEditing.identityCurve
            case "B": controls.channelCurves?.blue ?? MediaImageColorEditing.identityCurve
            default: controls.toneCurve ?? MediaImageColorEditing.identityCurve
            }
        }, set: { points in
            if curveChannel == "RGB" { controls.toneCurve = points; return }
            var channels = controls.channelCurves ?? .init()
            switch curveChannel { case "R": channels.red = points; case "G": channels.green = points; default: channels.blue = points }
            controls.channelCurves = channels
        })
    }
    private func load() {
        controls = session.selectedLayer.map(MediaImageColorEditing.controls) ?? .init()
        loadedRevision = session.document.revision; loadedLayerID = session.selectedLayerID; loadedKey = contextKey
        previewFailed = false; lutName = nil; session.colorPreview = nil; session.colorShowsOriginal = false
    }
    private var selectedBalance: ImageRGBBalance {
        let b = controls.colorBalance ?? .init()
        return tone == "shadows" ? b.shadows : tone == "highlights" ? b.highlights : b.midtones
    }
    private func balanceChannel(_ title: String, _ path: WritableKeyPath<ImageRGBBalance, Double>) -> some View {
        MusicValueSlider(title: title, value: selectedBalance[keyPath: path], range: -1...1) { value in
            var b = controls.colorBalance ?? .init(), rgb = selectedBalance; rgb[keyPath: path] = value
            if tone == "shadows" { b.shadows = rgb } else if tone == "highlights" { b.highlights = rgb } else { b.midtones = rgb }
            controls.colorBalance = b
        }
    }
    private func number(_ title: String, _ path: WritableKeyPath<ImageLayerAdjustment, Double?>, fallback: Double, range: ClosedRange<Double>) -> some View {
        MusicValueSlider(title: title, value: controls[keyPath: path] ?? fallback, range: range) { controls[keyPath: path] = $0 }
    }
    private func histogramBins(_ h: ImageColorHistogram) -> [Int] {
        switch curveChannel { case "R": h.red; case "G": h.green; case "B": h.blue; default: h.luminance }
    }
    private func updatePreview() async {
        let request = previewRequest, tool = session.tool
        guard loadedKey == contextKey, let layer = session.selectedLayer, let canvas = session.document.canvas else { return }
        let revision = session.document.revision, selectedID = layer.id
        do {
            try await Task.sleep(for: .milliseconds(120))
            var document = session.document
            let next = try MediaImageColorEditing.merging(request.controls, into: MediaImageColorEditing.controls(of: layer), tool: tool, selection: request.selection)
            guard let index = document.layers.firstIndex(where: { $0.id == selectedID }) else { return }
            if case .adjustment = layer.content { document.layers[index].content = .adjustment(next) }
            else { document.layers[index].adjustment = next }
            let frozen = document, assets = try session.resolvedAssets(), renderer = session.imageRenderer
            let worker = Task.detached(priority: .userInitiated) {
                let image = try await renderer.renderPrepared(frozen, canvas: .init(width: canvas.width, height: canvas.height),
                    resolveAsset: { assets[$0] }, previewMaxEdge: 1024, outputMaxEdge: 1024)
                return (image, try ImageColorHistogram.measure(image))
            }
            let (image, measured) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard session.document.revision == revision, session.selectedLayerID == selectedID,
                  session.tool == tool, request == previewRequest else { return }
            session.colorPreview = image; histogram = measured; previewFailed = false
        } catch is CancellationError { } catch { if !Task.isCancelled { session.colorPreview = nil; previewFailed = true } }
    }
    private func apply() {
        var input = MediaV2ToolInput(); input.expectedRevision = loadedRevision; input.objectID = loadedLayerID
        input.adjustment = inputControls; let tool = session.tool
        Task { do { _ = try await session.performTool(tool, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func importLUT(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get(); guard url.pathExtension.lowercased() == "cube" else { throw MediaV2CommandError.invalidInput }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else { throw MediaV2CommandError.invalidInput }
            let key = loadedKey, name = url.lastPathComponent
            Task { do {
                let worker = Task.detached { try ImageColorLUT.parseCube(text) }; let lut = try await worker.value
                guard loadedKey == key, contextKey == key else { return }
                controls.colorLUT = lut; controls.filterID = nil; lutName = name
            } catch { session.diagnostic = error.localizedDescription } }
        } catch { session.diagnostic = error.localizedDescription }
    }
}

private struct MediaV2HistogramView: View {
    let bins: [Int]
    var body: some View {
        Canvas { context, size in
            let maximum = max(1, bins.max() ?? 1), width = size.width / CGFloat(max(1, bins.count))
            for (i, count) in bins.enumerated() {
                let height = size.height * CGFloat(count) / CGFloat(maximum)
                context.fill(Path(CGRect(x: CGFloat(i) * width, y: size.height - height, width: max(1, width), height: height)), with: .color(.secondary.opacity(0.22)))
            }
        }.accessibilityHidden(true)
    }
}
struct MediaV2ToneCurveEditor:View{
    @Binding var points:[ImageFreehandStroke.Point]
    @State private var selected:Int?
    var body:some View{GeometryReader{geometry in
        Canvas{context,size in
            let rect=CGRect(origin:.zero,size:size);context.fill(Path(rect),with:.color(.secondary.opacity(0.06)))
            for index in 1...3{let f=CGFloat(index)/4;var grid=Path();grid.move(to:.init(x:size.width*f,y:0));grid.addLine(to:.init(x:size.width*f,y:size.height));grid.move(to:.init(x:0,y:size.height*f));grid.addLine(to:.init(x:size.width,y:size.height*f));context.stroke(grid,with:.color(.secondary.opacity(0.25)),lineWidth:1)}
            var curve=Path();for (index,p) in points.enumerated(){let point=CGPoint(x:p.x*size.width,y:(1-p.y)*size.height);if index==0{curve.move(to:point)}else{curve.addLine(to:point)};context.fill(Path(ellipseIn:.init(x:point.x-5,y:point.y-5,width:10,height:10)),with:.color(.accentColor))};context.stroke(curve,with:.color(.accentColor),lineWidth:2)
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{value in
            if selected==nil{selected=points.indices.min{a,b in hypot(points[a].x*geometry.size.width-value.startLocation.x,(1-points[a].y)*geometry.size.height-value.startLocation.y)<hypot(points[b].x*geometry.size.width-value.startLocation.x,(1-points[b].y)*geometry.size.height-value.startLocation.y)}}
            guard let index=selected else{return};points[index].y=min(1,max(0,1-Double(value.location.y/max(1,geometry.size.height))))
            if index>0 && index<points.count-1{points[index].x=min(points[index+1].x-0.01,max(points[index-1].x+0.01,Double(value.location.x/max(1,geometry.size.width))))}
        }.onEnded{_ in selected=nil})
    }.accessibilityLabel(WorkbenchText.t("明暗曲线", "Tone curve"))}
}
#endif
