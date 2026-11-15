// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2NumberField: View {
    let title: String
    @Binding var value: Double
    var suffix = ""
    var maximumFractionDigits = 3
    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer(minLength: 6)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...maximumFractionDigits)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation).frame(width: 88)
            if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
        }.frame(minHeight: 44)
    }
}

struct MediaV2SelectionInspector: View {
    @Bindable var session: MediaV2Session
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorkbenchText.t("选区与蒙版", "Selection and masks")).font(.headline)
            if let selection = session.selection {
                Text(selectionSummary(selection)).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(WorkbenchText.t("羽化在工具选项栏调整；选区本身是临时状态。",
                                      "Adjust feather in the tool options bar; the selection itself is temporary."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(WorkbenchText.t("在画布上拖动建立矩形、椭圆或套索选区，或点按使用魔棒。",
                                      "Drag on the canvas to make a rectangular, elliptical or lasso selection, or tap with the magic wand."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(WorkbenchText.t("显示选区", "Show selection"), isOn: $session.showSelection).frame(minHeight: 44)
            Divider()
            Button(WorkbenchText.t("应用为图层蒙版", "Apply as layer mask")) { perform("image.layer-mask") }
                .frame(minHeight: 44).disabled(session.selection == nil || session.selectedLayer == nil)
                .accessibilityIdentifier("media.v2.selection.applyMask")
            Button(WorkbenchText.t("剪贴到下方图层", "Clip to layer below")) { perform("image.clip-mask") }
                .frame(minHeight: 44).disabled(session.selectedLayer == nil)
            if let mask = session.selectedLayer?.mask {
                Text(mask.vector == nil
                    ? WorkbenchText.t("该图层使用画笔蒙版，边缘由画笔硬度决定。",
                                       "This layer uses a painted mask; edge softness follows brush hardness.")
                    : WorkbenchText.t("该图层蒙版保留创建时的羽化，与当前选区羽化相互独立。",
                                       "This layer mask keeps the feather it was created with, independent of the current selection."))
                    .font(.caption2).foregroundStyle(.secondary)
                Button(WorkbenchText.t("移除图层蒙版", "Remove layer mask")) {
                    var input = MediaV2ToolInput(); input.flag = false; perform("image.layer-mask", input)
                }.frame(minHeight: 44)
            }
            if session.selectedLayer?.clip != nil {
                Button(WorkbenchText.t("解除剪贴", "Release clipping")) {
                    var input = MediaV2ToolInput(); input.flag = false; perform("image.clip-mask", input)
                }.frame(minHeight: 44)
            }
        }
    }
    private func selectionSummary(_ selection: ImageSelection) -> String {
        var parts: [String] = []
        if let canvas = session.document.canvas {
            let px = selection.feather * Double(min(canvas.width, canvas.height))
            parts.append(WorkbenchText.t("羽化 \(Int(px.rounded())) px", "Feather \(Int(px.rounded())) px"))
        }
        if !selection.shapes.isEmpty {
            parts.append(WorkbenchText.t("\(selection.shapes.count) 个形状", "\(selection.shapes.count) shapes"))
        }
        if selection.bitmap != nil { parts.append(WorkbenchText.t("像素选区", "Pixel selection")) }
        if selection.inverted { parts.append(WorkbenchText.t("已反选", "Inverted")) }
        return parts.joined(separator: " · ")
    }
    private func perform(_ id: String, _ supplied: MediaV2ToolInput = .init()) {
        var input = supplied; input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

extension MediaV2Session {
    /// The kernel stores a normalized radius; the UI displays and submits
    /// pixels through the existing `image.feather` command contract.
    var selectionFeatherPixelRadius: Double {
        guard let canvas = document.canvas else { return 0 }
        return (selection?.feather ?? 0) * Double(min(canvas.width, canvas.height))
    }
    /// Shown while the feather editor is open: the pending radius on top of
    /// the selection, without mutating the actual selection.
    var selectionDisplayFeatherPixels: Double {
        guard let canvas = document.canvas else { return 0 }
        let normalized = selectionDisplay?.feather ?? 0
        return normalized * Double(min(canvas.width, canvas.height))
    }
    var selectionDisplay: ImageSelection? {
        guard var value = selection, let canvas = document.canvas else { return selection }
        if let draft = selectionFeatherDraftPixels, draft.isFinite {
            value.feather = min(0.5, max(0, draft / Double(min(canvas.width, canvas.height))))
        }
        return value
    }
}

struct MediaV2SelectionFeatherEditor: View {
    @Bindable var session: MediaV2Session
    @Environment(\.dismiss) private var dismiss
    @State private var pixels = 0.0
    @State private var applying = false
    @State private var error: String?
    private var maximum: Double {
        guard let canvas = session.document.canvas else { return 0 }
        return Double(min(canvas.width, canvas.height)) * 0.5
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(WorkbenchText.t("羽化选区边缘", "Feather selection edges")).font(.headline)
            MediaV2NumberField(title: WorkbenchText.t("半径", "Radius"), value: $pixels,
                               suffix: "px", maximumFractionDigits: 1)
                .accessibilityIdentifier("media.v2.feather.radius")
            Slider(value: $pixels, in: 0...max(0.5, maximum), step: 0.1)
                .accessibilityLabel(WorkbenchText.t("羽化半径", "Feather radius"))
                .accessibilityIdentifier("media.v2.feather.slider")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(WorkbenchText.t("清零", "Reset to 0")) { pixels = 0 }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("media.v2.feather.clear")
                Spacer()
                Button(WorkbenchText.t("取消", "Cancel")) { cancel() }.frame(minHeight: 44)
                    .accessibilityIdentifier("media.v2.feather.cancel")
                Button(WorkbenchText.t("应用", "Apply")) { apply() }.buttonStyle(.borderedProminent)
                    .disabled(applying || session.selection == nil || !pixels.isFinite || pixels < 0
                        || pixels > maximum || session.saving || session.processingTool || session.document.canvas == nil)
                    .accessibilityIdentifier("media.v2.feather.apply")
            }
        }.padding(18).frame(width: 300)
            .onAppear {
                pixels = session.selectionFeatherPixelRadius
                syncDraft()
            }
            .onChange(of: pixels) { _, value in
                guard !applying else { return }
                session.selectionFeatherDraftPixels = value.isFinite ? min(maximum, max(0, value)) : nil
            }
            .onDisappear { session.selectionFeatherDraftPixels = nil }
    }
    private func syncDraft() {
        session.selectionFeatherDraftPixels = pixels.isFinite ? min(maximum, max(0, pixels)) : nil
    }
    private func cancel() {
        session.selectionFeatherDraftPixels = nil
        dismiss()
    }
    private func apply() {
        guard !applying else { return }
        applying = true; error = nil
        let radius = min(maximum, max(0, pixels))
        var input = MediaV2ToolInput(); input.number = radius; input.expectedRevision = session.document.revision
        Task {
            defer { applying = false }
            do {
                _ = try await session.performTool("image.feather", input: input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                session.diagnostic = error.localizedDescription
            }
        }
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
                    ForEach(["normal", "multiply", "screen", "overlay", "darken", "lighten", "difference", "exclusion"], id: \.self) { mode in Text(blendTitle(mode)).tag(mode) }
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
                     "overlay": ("叠加", "Overlay"), "darken": ("变暗", "Darken"), "lighten": ("变亮", "Lighten"),
                     "difference": ("差值", "Difference"), "exclusion": ("排除", "Exclusion")]
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

struct MediaV2ImageExportSheet: View {
    @Bindable var session: MediaV2Session
    @Environment(\.dismiss) private var dismiss
    @State private var options: ImageExportOptions
    @State private var lockAspect = true
    @State private var preview: CGImage?
    @State private var estimatedBytes: Int64?
    @State private var error: String?
    private struct PreviewKey: Hashable { let revision: Int64; let options: ImageExportOptions }
    private var previewKey: PreviewKey { .init(revision: session.project.revision, options: options) }
    init(session: MediaV2Session) {
        self.session = session
        _options = State(initialValue: session.imageExportOptions)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 240) }
                    else if error == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                    if let estimatedBytes {
                        Text(WorkbenchText.t("预计大小：", "Estimated size: ") + ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section(WorkbenchText.t("格式与质量", "Format and quality")) {
                    Picker(WorkbenchText.t("格式", "Format"), selection: $options.format) {
                        Text("PNG").tag(ImageExportFormat.png); Text("JPEG").tag(ImageExportFormat.jpeg); Text("HEIC").tag(ImageExportFormat.heic)
                    }
                    if options.format != .png {
                        MusicValueSlider(title: WorkbenchText.t("质量", "Quality"), value: options.quality, range: 0.01...1) { options.quality = $0 }
                    }
                    Toggle(WorkbenchText.t("保留透明背景", "Preserve transparency"), isOn: $options.preserveTransparency).disabled(!options.format.supportsAlpha)
                }
                Section(WorkbenchText.t("尺寸", "Dimensions")) {
                    HStack { Text(WorkbenchText.t("宽度", "Width")); Spacer(); TextField("px", value: dimension(width: true), format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad); Text("px") }
                    HStack { Text(WorkbenchText.t("高度", "Height")); Spacer(); TextField("px", value: dimension(width: false), format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad); Text("px") }
                    Toggle(WorkbenchText.t("保持比例", "Keep aspect ratio"), isOn: $lockAspect)
                    Button(WorkbenchText.t("使用原始尺寸", "Use original dimensions")) { options.width = nil; options.height = nil }
                }
                Section(WorkbenchText.t("文件", "File")) {
                    TextField(WorkbenchText.t("文件名", "File name"), text: $options.fileName)
                    Toggle(WorkbenchText.t("移除拍摄信息", "Remove capture metadata"), isOn: $options.stripMetadata)
                    if !options.stripMetadata { Text(WorkbenchText.t("保留底层来源图片的拍摄信息，可能包含位置。", "Keeps capture metadata from the bottom source image, which may include location.")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(WorkbenchText.t("导出图片", "Export image"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WorkbenchText.t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("导出", "Export")) {
                        session.imageExportOptions = options; session.export(options: options); dismiss()
                    }.disabled(error != nil || preview == nil || session.rendering)
                }
            }
        }
        .onChange(of: options.format) { _, format in if !format.supportsAlpha { options.preserveTransparency = false } }
        .task(id: previewKey) { await updatePreview() }
    }
    private func dimension(width: Bool) -> Binding<Int> {
        Binding(get: { width ? options.width ?? session.project.canvas?.width ?? 1 : options.height ?? session.project.canvas?.height ?? 1 }, set: { value in
            if width { options.width = value } else { options.height = value }
            guard lockAspect, (1...16384).contains(value), let canvas = session.project.canvas else { return }
            if width { options.height = max(1, Int((Double(value) * Double(canvas.height) / Double(canvas.width)).rounded())) }
            else { options.width = max(1, Int((Double(value) * Double(canvas.width) / Double(canvas.height)).rounded())) }
        })
    }
    private func updatePreview() async {
        preview = nil; estimatedBytes = nil; error = nil
        let key = previewKey, project = session.project, options = options
        do {
            try await Task.sleep(for: .milliseconds(200))
            let assets = try session.resolvedAssets(), renderer = session.imageRenderer
            let worker = Task.detached(priority: .userInitiated) { try await renderer.previewImageExport(project: project, options: options, resolveAsset: { assets[$0] }) }
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); guard key == previewKey else { return }
            preview = value.image; estimatedBytes = value.estimatedBytes
        } catch is CancellationError { } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
#endif
