// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2NumberField: View {
    let title: String
    @Binding var value: Double
    var suffix = ""
    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer(minLength: 6)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation).frame(width: 88)
            if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
        }.frame(minHeight: 44)
    }
}

struct MediaV2SelectionInspector: View {
    @Bindable var session: MediaV2Session
    @State private var feather = 12.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorkbenchText.t("选区与蒙版", "Selection and masks")).font(.headline)
            Picker(WorkbenchText.t("选区运算", "Selection operation"), selection: $session.selectionMode) {
                Text(WorkbenchText.t("新建", "New")).tag(ImageSelectionOperation.replace)
                Text(WorkbenchText.t("添加", "Add")).tag(ImageSelectionOperation.add)
                Text(WorkbenchText.t("减去", "Subtract")).tag(ImageSelectionOperation.subtract)
            }.pickerStyle(.segmented)
            Menu(WorkbenchText.t("选择工具", "Selection tool")) {
                Button(WorkbenchText.t("矩形", "Rectangle")) { session.tool = "image.rectangle" }
                Button(WorkbenchText.t("椭圆", "Ellipse")) { session.tool = "image.ellipse" }
                Button(WorkbenchText.t("套索", "Lasso")) { session.tool = "image.lasso" }
                Button(WorkbenchText.t("多边形", "Polygon")) { session.tool = "image.polygon" }
            }.frame(minHeight: 44)
            if session.tool == "image.polygon" {
                Text(WorkbenchText.t("点按画布添加顶点。", "Tap the canvas to add vertices.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(WorkbenchText.t("闭合多边形", "Close polygon")) {
                        var input = MediaV2ToolInput(); input.points = session.polygonPoints; input.property = session.selectionMode.rawValue
                        perform("image.polygon", input)
                    }.disabled(session.polygonPoints.count < 3)
                    Spacer()
                    Button(WorkbenchText.t("取消", "Cancel")) { session.polygonPoints = [] }
                }.frame(minHeight: 44)
            }
            Toggle(WorkbenchText.t("显示选区", "Show selection"), isOn: $session.showSelection).frame(minHeight: 44)
            MediaV2NumberField(title: WorkbenchText.t("羽化半径", "Feather radius"), value: $feather, suffix: "px")
            Button(WorkbenchText.t("应用羽化", "Apply feather")) {
                var input = MediaV2ToolInput(); input.number = feather; perform("image.feather", input)
            }.frame(minHeight: 44).disabled(session.selection == nil)
            HStack {
                Button(WorkbenchText.t("反选", "Invert")) { perform("image.inverse") }
                Spacer()
                Button(WorkbenchText.t("取消选择", "Deselect")) { perform("image.deselect") }
            }.frame(minHeight: 44)
            Button(WorkbenchText.t("应用为图层蒙版", "Apply as layer mask")) { perform("image.layer-mask") }
                .frame(minHeight: 44).disabled(session.selection == nil || session.selectedLayer == nil)
            Button(WorkbenchText.t("剪贴到下方图层", "Clip to layer below")) { perform("image.clip-mask") }
                .frame(minHeight: 44).disabled(session.selectedLayer == nil)
            if session.selectedLayer?.mask != nil {
                Button(WorkbenchText.t("移除图层蒙版", "Remove layer mask")) { var input = MediaV2ToolInput(); input.flag = false; perform("image.layer-mask", input) }.frame(minHeight: 44)
            }
            if session.selectedLayer?.clip != nil {
                Button(WorkbenchText.t("解除剪贴", "Release clipping")) { var input = MediaV2ToolInput(); input.flag = false; perform("image.clip-mask", input) }.frame(minHeight: 44)
            }
        }
        .onAppear {
            if let canvas = session.document.canvas { feather = (session.selection?.feather ?? 0) * Double(min(canvas.width, canvas.height)) }
        }
    }
    private func perform(_ id: String, _ supplied: MediaV2ToolInput = .init()) {
        var input = supplied; input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

struct MediaV2CropInspector: View {
    @Bindable var session: MediaV2Session
    let layer: MediaPreparedLayer
    @State private var crop: NormalizedRect
    init(session: MediaV2Session, layer: MediaPreparedLayer) {
        self.session = session; self.layer = layer
        if case .raster(let raster) = layer.content { _crop = State(initialValue: raster.crop ?? .unit) }
        else { _crop = State(initialValue: .unit) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("图片源裁剪", "Source crop")).font(.headline)
            MediaV2NumberField(title: "X", value: percent(\.x), suffix: "%")
            MediaV2NumberField(title: "Y", value: percent(\.y), suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("宽", "Width"), value: percent(\.width), suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("高", "Height"), value: percent(\.height), suffix: "%")
            Button(WorkbenchText.t("应用裁剪", "Apply crop")) { apply(reset: false) }.frame(minHeight: 44)
            Button(WorkbenchText.t("重置裁剪", "Reset crop")) { apply(reset: true) }.frame(minHeight: 44)
            Text(WorkbenchText.t("按原图百分比裁剪，原素材保留。也可在画布拖动框选。", "Crop by source percentage while retaining the original. Drag on the canvas to crop visually."))
                .font(.caption2).foregroundStyle(.secondary)
        }.disabled(layer.isLocked || session.saving)
            .onChange(of: layer.revision) { _, _ in if case .raster(let raster) = layer.content { crop = raster.crop ?? .unit } }
    }
    private func percent(_ key: WritableKeyPath<NormalizedRect, Double>) -> Binding<Double> {
        Binding(get: { crop[keyPath: key] * 100 }, set: { crop[keyPath: key] = $0 / 100 })
    }
    private func apply(reset: Bool) {
        var input = MediaV2ToolInput(); input.expectedRevision = session.document.revision; input.objectID = layer.id
        input.flag = !reset; input.points = [.init(x: crop.x, y: crop.y), .init(x: crop.x + crop.width, y: crop.y + crop.height)]
        Task { do { _ = try await session.performTool("image.crop", input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

struct MediaV2LayerInspector: View {
    @Bindable var session: MediaV2Session
    let layer: MediaPreparedLayer
    @State private var name: String
    @State private var transform: ImageLayerTransform
    @State private var opacity: Double
    @State private var blend = "normal"
    init(session: MediaV2Session, layer: MediaPreparedLayer) {
        self.session = session; self.layer = layer
        _name = State(initialValue: layer.name); _transform = State(initialValue: layer.transform); _opacity = State(initialValue: layer.opacity)
        if case .group(let group) = layer.content { _blend = State(initialValue: group.blendMode ?? "normal") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("图层属性", "Layer properties")).font(.caption.weight(.semibold))
            TextField(WorkbenchText.t("图层名称", "Layer name"), text: $name).textFieldStyle(.roundedBorder)
            MediaV2NumberField(title: "X", value: coordinate(\.centerX, dimension: session.document.canvas?.width ?? 1), suffix: "px")
            MediaV2NumberField(title: "Y", value: coordinate(\.centerY, dimension: session.document.canvas?.height ?? 1), suffix: "px")
            MediaV2NumberField(title: WorkbenchText.t("缩放", "Scale"), value: Binding(get: { transform.scale * 100 }, set: { transform.scale = $0 / 100 }), suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("旋转", "Rotation"), value: $transform.rotationDegrees, suffix: "°")
            MediaV2NumberField(title: WorkbenchText.t("不透明度", "Opacity"), value: Binding(get: { opacity * 100 }, set: { opacity = $0 / 100 }), suffix: "%")
            HStack {
                Button(WorkbenchText.t("水平翻转", "Flip horizontal")) { transform.flipX = !(transform.flipX ?? false) }
                Spacer()
                Button(WorkbenchText.t("垂直翻转", "Flip vertical")) { transform.flipY = !(transform.flipY ?? false) }
            }.frame(minHeight: 44)
            HStack {
                Button(WorkbenchText.t("水平居中", "Center X")) { transform.centerX = 0.5 }
                Spacer()
                Button(WorkbenchText.t("垂直居中", "Center Y")) { transform.centerY = 0.5 }
            }.frame(minHeight: 44)
            if layer.contentKind == .group {
                Picker(WorkbenchText.t("混合模式", "Blend mode"), selection: $blend) {
                    ForEach(["normal", "multiply", "screen", "overlay", "darken", "lighten"], id: \.self) { mode in Text(blendTitle(mode)).tag(mode) }
                }
            }
            Button(WorkbenchText.t("应用图层属性", "Apply layer properties")) { apply() }.frame(minHeight: 44)
            if let mask = layer.mask {
                Toggle(WorkbenchText.t("启用蒙版", "Enable mask"), isOn: Binding(get: { mask.isEnabled }, set: { enabled in session.updateLayer { $0.mask?.isEnabled = enabled } })).frame(minHeight: 44)
                Toggle(WorkbenchText.t("反转蒙版", "Invert mask"), isOn: Binding(get: { mask.isInverted }, set: { inverted in session.updateLayer { $0.mask?.isInverted = inverted } })).frame(minHeight: 44)
            }
        }.disabled(layer.isLocked || session.saving)
            .onChange(of: layer.revision) { _, _ in
                name = layer.name; transform = layer.transform; opacity = layer.opacity
                if case .group(let group) = layer.content { blend = group.blendMode ?? "normal" }
            }
    }
    private func coordinate(_ key: WritableKeyPath<ImageLayerTransform, Double>, dimension: Int) -> Binding<Double> {
        Binding(get: { transform[keyPath: key] * Double(dimension) }, set: { transform[keyPath: key] = $0 / Double(max(1, dimension)) })
    }
    private func apply() {
        guard session.selectedLayerID == layer.id, session.selectedLayer?.revision == layer.revision,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              opacity.isFinite, (0...1).contains(opacity), transform.scale.isFinite, transform.scale > 0 else { session.diagnostic = MediaV2CommandError.invalidInput.localizedDescription; return }
        session.updateLayer { value in
            value.name = name; value.transform = transform; value.opacity = opacity
            if case .group(var group) = value.content { group.blendMode = blend; value.content = .group(group) }
        }
    }
    private func blendTitle(_ mode: String) -> String {
        let names = ["normal": ("正常", "Normal"), "multiply": ("正片叠底", "Multiply"), "screen": ("滤色", "Screen"),
                     "overlay": ("叠加", "Overlay"), "darken": ("变暗", "Darken"), "lighten": ("变亮", "Lighten")]
        let value = names[mode] ?? (mode, mode); return WorkbenchText.t(value.0, value.1)
    }
}

struct MediaV2TextInspector: View {
    @Bindable var session: MediaV2Session
    let layer: MediaPreparedLayer
    @State private var content: ImageTextContent
    init(session: MediaV2Session, layer: MediaPreparedLayer) {
        self.session = session; self.layer = layer
        if case .text(let text) = layer.content { _content = State(initialValue: text) }
        else { _content = State(initialValue: .init(text: "")) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
            Text(WorkbenchText.t("文字", "Text")).font(.headline)
            TextField(WorkbenchText.t("文字内容", "Text content"), text: $content.text, axis: .vertical).textFieldStyle(.roundedBorder)
            MediaV2NumberField(title: WorkbenchText.t("字号", "Size"), value: $content.fontSize, suffix: "px")
            Picker(WorkbenchText.t("字体", "Font"), selection: Binding(get: { content.fontName ?? "" }, set: { content.fontName = $0.isEmpty ? nil : $0 })) {
                Text(WorkbenchText.t("系统字体", "System font")).tag("")
                ForEach(fontNames, id: \.self) { Text($0).tag($0) }
            }
            MediaV2NumberField(title: WorkbenchText.t("字距", "Tracking"), value: Binding(get: { content.tracking ?? 0 }, set: { content.tracking = $0 }), suffix: "px")
            MediaV2NumberField(title: WorkbenchText.t("行距", "Leading"), value: Binding(get: { content.leading ?? 0 }, set: { content.leading = $0 }), suffix: "px")
            TextField(WorkbenchText.t("颜色", "Color"), text: $content.colorHex).textFieldStyle(.roundedBorder)
            Toggle(WorkbenchText.t("描边", "Stroke"), isOn: Binding(get: { (content.strokeWidth ?? 0) > 0 }, set: { enabled in content.strokeWidth = enabled ? 2 : nil; content.strokeColorHex = enabled ? "#FFFFFF" : nil })).frame(minHeight: 44)
            if content.strokeWidth != nil { MediaV2NumberField(title: WorkbenchText.t("描边宽度", "Stroke width"), value: Binding(get: { content.strokeWidth ?? 0 }, set: { content.strokeWidth = $0 }), suffix: "px") }
            Toggle(WorkbenchText.t("阴影", "Shadow"), isOn: Binding(get: { content.shadow != nil }, set: { content.shadow = $0 ? .init() : nil })).frame(minHeight: 44)
            Button(WorkbenchText.t("应用文字", "Apply text")) {
                guard content.fontSize.isFinite, content.fontSize > 0, !content.text.isEmpty else { session.diagnostic = MediaV2CommandError.invalidInput.localizedDescription; return }
                if content.pathLayout != nil {
                    let value=content,revision=session.document.revision
                    Task { do { _ = try await session.applyEditablePathText(value,to:layer,revision:revision,actor:.user) } catch { session.diagnostic=error.localizedDescription } }
                } else { session.submit([.replaceLayerContent(id: layer.id, expectedRevision: layer.revision, content: .text(content))]) }
            }.frame(minHeight: 44)
            }.disabled(session.processingTool)
            if content.pathLayout != nil,session.processingTool {
                ProgressView(WorkbenchText.t("正在排版文字…", "Laying out text…"))
                Button(WorkbenchText.t("取消处理", "Cancel processing"),systemImage:"xmark.circle") { session.cancelToolProcessing() }.frame(minHeight:44)
            }
        }.disabled(layer.isLocked || session.saving)
            .onChange(of: layer.revision) { _, _ in if case .text(let text) = layer.content { content = text } }
    }
    private var fontNames: [String] {
        let names = [content.fontName].compactMap { $0 } + ["HelveticaNeue", "AvenirNext-Regular", "PingFangSC-Regular", "SongtiSC-Regular", "Menlo-Regular"]
        return Array(Set(names)).filter { UIFont(name: $0, size: 16) != nil }.sorted()
    }
}
#endif
