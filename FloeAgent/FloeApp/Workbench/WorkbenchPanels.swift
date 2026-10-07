// FloeApp — Workbench panels: assets/layers, properties, export.

import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Assets & layers

struct WorkbenchAssetsPanel: View {
    @ObservedObject var center: WorkbenchCenter
    @ObservedObject private var layout = LayoutPreferences.shared
    @State private var showTextSheet = false
    @State private var showAssetImporter = false
    @State private var assetImportMode: AssetImportMode = .imageLayer
    @State private var showMusicImporter = false
    @State private var relinkAssetID: UUID?
    @State private var multiSelectLayers = false

    enum AssetImportMode { case imageLayer, videoClip, music }

    var body: some View {
        List {
            Section(WorkbenchText.t("项目", "Project")) {
                if let project = center.project {
                    LabeledContent(WorkbenchText.t("名称", "Name"), value: project.name)
                    LabeledContent(WorkbenchText.t("修订", "Revision"), value: "\(project.revision)")
                    if let canvas = project.canvas {
                        LabeledContent(WorkbenchText.t("画布", "Canvas"),
                                       value: "\(canvas.width)×\(canvas.height)" + (canvas.frameRate.map { String(format: " @ %.0ffps", $0) } ?? ""))
                    }
                }
            }

            Section(WorkbenchText.t("显示", "Display")) {
                ForEach(LayoutListKind.allCases, id: \.self) { kind in
                    Picker(kind == .files
                           ? WorkbenchText.t("文件列表字号", "File list font")
                           : kind == .assets
                           ? WorkbenchText.t("素材列表字号", "Asset list font")
                           : WorkbenchText.t("图层列表字号", "Layer list font"),
                           selection: Binding(
                            get: { layout.settings.fontSize(for: kind) },
                            set: { layout.setFontSize($0, for: kind) })) {
                        ForEach(LayoutListFontSize.allCases, id: \.self) { size in
                            Text(WorkbenchText.t(size.titleZH, size.titleEN)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workbench.display.font.\(kind.rawValue)")
                }
                Picker(WorkbenchText.t("文件名行数", "File name lines"), selection: Binding(
                    get: { layout.settings.fileNameLines },
                    set: { layout.setFileNameLines($0) })) {
                    Text(WorkbenchText.t("一行", "One line")).tag(1)
                    Text(WorkbenchText.t("两行", "Two lines")).tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("workbench.display.fileNameLines")
                Toggle(WorkbenchText.t("显示完整路径", "Show full path"), isOn: Binding(
                    get: { layout.settings.showFullPath },
                    set: { layout.setShowFullPath($0) }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.display.showPath")
                Toggle(WorkbenchText.t("显示扩展名", "Show file extension"), isOn: Binding(
                    get: { layout.settings.showFileExtension },
                    set: { layout.setShowFileExtension($0) }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.display.showExtension")
            }

            Section(WorkbenchText.t("素材", "Assets")) {
                ForEach(center.project?.assets ?? []) { asset in
                    HStack {
                        Image(systemName: center.isAssetAvailable(asset.id)
                              ? icon(for: asset.kind) : "exclamationmark.triangle")
                        VStack(alignment: .leading) {
                            Text(asset.originalName)
                                .font(.system(size: layout.settings.fontSize(for: .assets).pointSize))
                                .lineLimit(layout.settings.fileNameLines)
                            if layout.settings.fileNameLines > 1 || layout.settings.showFullPath {
                                Text(asset.relativePath)
                                    .font(.system(size: layout.settings.fontSize(for: .assets).pointSize - 2))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if !center.isAssetAvailable(asset.id) {
                            Button(WorkbenchText.t("重新链接", "Relink")) {
                                relinkAssetID = asset.id
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.asset.relink.\(asset.id.uuidString)")
                        }
                    }
                    .accessibilityIdentifier("workbench.asset.\(asset.id.uuidString)")
                }
                Menu {
                    Button(WorkbenchText.t("导入图片图层", "Import image layer")) {
                        assetImportMode = .imageLayer
                        showAssetImporter = true
                    }
                    Button(WorkbenchText.t("导入视频片段", "Import video clip")) {
                        assetImportMode = .videoClip
                        showAssetImporter = true
                    }
                    Button(WorkbenchText.t("导入音乐", "Import music")) {
                        assetImportMode = .music
                        showMusicImporter = true
                    }
                } label: {
                    Label(WorkbenchText.t("添加素材", "Add asset"), systemImage: "plus")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("workbench.asset.add")
            }

            if center.project?.kind == .image {
                Section(WorkbenchText.t("工具", "Tools")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(WorkbenchCenter.ImageAuthoringTool.allCases) { tool in
                                Button {
                                    center.setImageTool(tool)
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(systemName: toolIcon(tool))
                                            .font(.system(size: 18))
                                        Text(toolTitle(tool))
                                            .font(.caption2)
                                    }
                                    .frame(minWidth: 52, minHeight: 44)
                                    .padding(.horizontal, 6)
                                    .background(center.imageTool == tool
                                                ? Color.accentColor.opacity(0.18) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workbench.tool.\(tool.rawValue)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if center.imageTool == .marquee {
                        selectionControls
                    }
                    if center.imageTool == .brush || center.imageTool == .eraser {
                        brushControls(isEraser: center.imageTool == .eraser)
                    }
                }
                Section(WorkbenchText.t("图层", "Layers")) {
                    HStack {
                        Button(WorkbenchText.t("全选图层", "Select all layers")) {
                            center.selectAllLayers()
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.layer.selectAll")
                        Spacer()
                        Toggle(WorkbenchText.t("多选", "Multi"), isOn: $multiSelectLayers)
                            .toggleStyle(.button)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.layer.multiSelect")
                    }
                    layerRows
                }
                Section {
                    Button {
                        showTextSheet = true
                    } label: {
                        Label(WorkbenchText.t("添加文字图层", "Add text layer"), systemImage: "textformat")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("workbench.layer.addText")
                    Button {
                        center.setImageTool(.brush)
                    } label: {
                        Label(WorkbenchText.t("使用画笔", "Use brush"), systemImage: "paintbrush.pointed")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("workbench.layer.freehand")
                    Button {
                        center.duplicateSelectedLayer()
                    } label: {
                        Label(WorkbenchText.t("复制图层", "Duplicate layer"), systemImage: "plus.square.on.square")
                            .frame(minHeight: 44)
                    }
                    .disabled(center.selectedLayerID == nil)
                    .accessibilityIdentifier("workbench.layer.duplicate")
                    HStack {
                        Button {
                            center.flipSelectedLayer(horizontal: true)
                        } label: {
                            Label(WorkbenchText.t("水平翻转", "Flip horizontal"), systemImage: "arrow.left.and.right")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.layer.flipH")
                        Button {
                            center.flipSelectedLayer(horizontal: false)
                        } label: {
                            Label(WorkbenchText.t("垂直翻转", "Flip vertical"), systemImage: "arrow.up.and.down")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.layer.flipV")
                    }
                    .disabled(center.selectedLayerID == nil)
                    Menu {
                        ForEach(LayerAlignment.allCases, id: \.self) { alignment in
                            Button(alignmentTitle(alignment)) {
                                Task { await center.alignSelectedLayers(alignment) }
                            }
                        }
                    } label: {
                        Label(WorkbenchText.t("对齐所选图层", "Align selected layers"), systemImage: "align.horizontal.left")
                            .frame(minHeight: 44)
                    }
                    .disabled(center.selectedLayerIDs.count < 2)
                    .accessibilityIdentifier("workbench.layer.align")
                    Button {
                        Task { await center.mergeSelectedLayers() }
                    } label: {
                        Label(WorkbenchText.t("合并所选图层", "Merge selected layers"), systemImage: "square.stack.3d.down.right")
                            .frame(minHeight: 44)
                    }
                    .disabled(center.selectedLayerIDs.count < 2 || center.busy)
                    .accessibilityIdentifier("workbench.layer.merge")
                    Button(role: .destructive) {
                        center.deleteSelectedLayers()
                    } label: {
                        Label(WorkbenchText.t("删除图层", "Delete layer"), systemImage: "trash")
                            .frame(minHeight: 44)
                    }
                    .disabled(center.selectedLayerID == nil)
                    .accessibilityIdentifier("workbench.layer.delete")
                }
            }
        }
        .fileImporter(isPresented: $showAssetImporter,
                      allowedContentTypes: assetImportMode == .videoClip ? [.movie, .video] : [.image],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAsset(url) }
            case .failure(let error):
                center.alert = .init(title: WorkbenchText.t("导入失败", "Import failed"),
                                     message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showMusicImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importMusic(url) }
            case .failure(let error):
                center.alert = .init(title: WorkbenchText.t("导入失败", "Import failed"),
                                     message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: Binding(
            get: { relinkAssetID != nil },
            set: { if !$0 { relinkAssetID = nil } }),
            allowedContentTypes: [.image, .movie, .audio, .data],
            allowsMultipleSelection: false) { result in
            guard let assetID = relinkAssetID else { return }
            relinkAssetID = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await center.relinkAsset(assetID, to: url) }
            case .failure(let error):
                center.alert = .init(title: WorkbenchText.t("重新链接失败", "Relink failed"),
                                     message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showTextSheet) {
            TextLayerSheet(center: center)
        }
    }

    private var selectedLayer: ImageLayer? {
        center.project?.imageLayers.first { $0.id == center.selectedLayerID }
    }

    // MARK: Image tool controls

    private func toolIcon(_ tool: WorkbenchCenter.ImageAuthoringTool) -> String {
        switch tool {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: "selection.pin.in.out"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .eyedropper: "eyedropper"
        }
    }

    private func toolTitle(_ tool: WorkbenchCenter.ImageAuthoringTool) -> String {
        switch tool {
        case .move: WorkbenchText.t("移动", "Move")
        case .marquee: WorkbenchText.t("选区", "Select")
        case .brush: WorkbenchText.t("画笔", "Brush")
        case .eraser: WorkbenchText.t("擦除", "Erase")
        case .eyedropper: WorkbenchText.t("吸管", "Pick")
        }
    }

    private func alignmentTitle(_ alignment: LayerAlignment) -> String {
        switch alignment {
        case .left: WorkbenchText.t("左对齐", "Align left")
        case .centerX: WorkbenchText.t("水平居中", "Center horizontally")
        case .right: WorkbenchText.t("右对齐", "Align right")
        case .top: WorkbenchText.t("顶对齐", "Align top")
        case .centerY: WorkbenchText.t("垂直居中", "Center vertically")
        case .bottom: WorkbenchText.t("底对齐", "Align bottom")
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        Picker(WorkbenchText.t("选区形状", "Selection shape"), selection: $center.selectionKind) {
            Text(WorkbenchText.t("矩形", "Rectangle")).tag(ImageSelectionKind.rectangle)
            Text(WorkbenchText.t("椭圆", "Ellipse")).tag(ImageSelectionKind.ellipse)
            Text(WorkbenchText.t("套索", "Lasso")).tag(ImageSelectionKind.lasso)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("workbench.selection.kind")
        Picker(WorkbenchText.t("选区运算", "Selection operation"), selection: $center.selectionOperation) {
            Text(WorkbenchText.t("替换", "Replace")).tag(ImageSelectionOperation.replace)
            Text(WorkbenchText.t("添加", "Add")).tag(ImageSelectionOperation.add)
            Text(WorkbenchText.t("减去", "Subtract")).tag(ImageSelectionOperation.subtract)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("workbench.selection.operation")
        VStack(alignment: .leading) {
            Text(WorkbenchText.t("羽化", "Feather") + " \(Int((center.project?.imageSelection?.feather ?? 0) * 100))%")
                .font(.caption)
            Slider(value: Binding(
                get: { center.project?.imageSelection?.feather ?? 0 },
                set: { center.setSelectionFeather($0) }), in: 0...0.5)
                .accessibilityIdentifier("workbench.selection.feather")
        }
        HStack {
            Button(WorkbenchText.t("全选", "Select all")) { center.selectAllImage() }
                .frame(minHeight: 44)
            Button(WorkbenchText.t("反选", "Invert")) { center.invertImageSelection() }
                .frame(minHeight: 44)
                .disabled((center.project?.imageSelection?.isEmpty ?? true))
            Button(WorkbenchText.t("清除", "Clear")) { center.clearImageSelection() }
                .frame(minHeight: 44)
                .disabled(center.project?.imageSelection == nil)
        }
        .font(.callout)
        if let layer = selectedLayer, let selection = center.project?.imageSelection, !selection.isEmpty {
            Button {
                center.apply(.setLayerSelectionMask(id: layer.id, selection: .set(selection)))
            } label: {
                Label(WorkbenchText.t("将选区应用到图层", "Apply selection to layer"),
                      systemImage: "square.on.square.dashed")
                    .frame(minHeight: 44)
            }
            .disabled(layer.isLocked)
            .accessibilityIdentifier("workbench.selection.applyToLayer")
        }
    }

    @ViewBuilder
    private func brushControls(isEraser: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(WorkbenchText.t("粗细", "Size") + " \(Int(center.brushWidth))")
                .font(.caption)
            Slider(value: $center.brushWidth, in: 1...120)
                .accessibilityIdentifier("workbench.brush.width")
        }
        VStack(alignment: .leading) {
            Text(WorkbenchText.t("硬度", "Hardness") + " \(Int(center.brushHardness * 100))%")
                .font(.caption)
            Slider(value: $center.brushHardness, in: 0...1)
                .accessibilityIdentifier("workbench.brush.hardness")
        }
        VStack(alignment: .leading) {
            Text(WorkbenchText.t("不透明度", "Opacity") + " \(Int(center.brushOpacity * 100))%")
                .font(.caption)
            Slider(value: $center.brushOpacity, in: 0.05...1)
                .accessibilityIdentifier("workbench.brush.opacity")
        }
        if !isEraser {
            ColorPicker(WorkbenchText.t("颜色", "Color"),
                        selection: Binding(
                            get: { WorkbenchPreviewColor.color(center.brushColorHex) },
                            set: { center.brushColorHex = hexString($0) }))
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.brush.color")
            HStack(spacing: 8) {
                ForEach(["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE", "#000000", "#FFFFFF"],
                        id: \.self) { preset in
                    Button {
                        center.brushColorHex = preset
                    } label: {
                        Circle()
                            .fill(WorkbenchPreviewColor.color(preset))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle(WorkbenchText.t("压感（仅 Apple Pencil）", "Pressure (Apple Pencil only)"),
                   isOn: $center.brushUsesPressure)
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.brush.pressure")
        } else {
            Toggle(WorkbenchText.t("恢复（还原被擦除的像素）", "Restore erased pixels"),
                   isOn: $center.maskRestore)
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.brush.restore")
        }
    }

    private func hexString(_ color: Color) -> String {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return center.brushColorHex
        #endif
    }

    private var layerRows: some View {
        ForEach(Array((center.project?.imageLayers ?? []).reversed())) { layer in
            HStack {
                Button {
                    center.selectedLayerID = layer.id
                } label: {
                    HStack {
                        Image(systemName: icon(for: layer.kind))
                        VStack(alignment: .leading) {
                            Text(layer.name)
                                .font(.system(size: layout.settings.fontSize(for: .layers).pointSize))
                                .lineLimit(layout.settings.fileNameLines)
                            Text("\(Int(layer.opacity * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Button {
                    center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil,
                                              isHidden: !layer.isHidden, isLocked: nil,
                                              adjustment: nil, text: nil, crop: .unchanged))
                } label: {
                    Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                Button {
                    center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil,
                                              isHidden: nil, isLocked: !layer.isLocked,
                                              adjustment: nil, text: nil, crop: .unchanged))
                } label: {
                    Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                center.setLayerSelected(layer.id, additive: multiSelectLayers)
            }
            .background(center.selectedLayerIDs.contains(layer.id) ? Color.accentColor.opacity(0.15) : Color.clear)
            .accessibilityIdentifier("workbench.layer.\(layer.id.uuidString)")
            .draggable(layer.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let sourceID = UUID(uuidString: raw),
                      sourceID != layer.id, var current = center.project,
                      let from = current.imageLayers.firstIndex(where: { $0.id == sourceID }),
                      let to = current.imageLayers.firstIndex(where: { $0.id == layer.id }) else { return false }
                var ordered = current.imageLayers
                let moved = ordered.remove(at: from)
                ordered.insert(moved, at: to)
                current.imageLayers = ordered
                center.reorderLayers(to: ordered.map(\.id))
                return true
            }
        }
    }

    private func importAsset(_ url: URL) async {
        switch assetImportMode {
        case .imageLayer:
            await center.importImageLayer(url: url)
        case .videoClip:
            await center.importVideoClip(url: url)
        case .music:
            await importMusic(url)
        }
    }

    private func importMusic(_ url: URL) async {
        await center.importMusic(url: url)
    }

    private func icon(for kind: MediaAssetKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        }
    }

    private func icon(for kind: ImageLayerKind) -> String {
        switch kind {
        case .image: "photo"
        case .text: "textformat"
        case .freehand: "scribble"
        case .fill: "paintbrush.pointed.fill"
        }
    }
}

// MARK: - Text layer sheet

struct TextLayerSheet: View {
    @ObservedObject var center: WorkbenchCenter
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fontSize: Double = 64
    @State private var color = Color.black

    var body: some View {
        NavigationStack {
            Form {
                TextField(WorkbenchText.t("文字内容", "Text"), text: $text)
                    .accessibilityIdentifier("workbench.text.content")
                Slider(value: $fontSize, in: 12...300) {
                    Text(WorkbenchText.t("字号", "Font size"))
                } minimumValueLabel: { Text("12") } maximumValueLabel: { Text("300") }
                    .accessibilityIdentifier("workbench.text.size")
                ColorPicker(WorkbenchText.t("颜色", "Color"), selection: $color)
            }
            .navigationTitle(WorkbenchText.t("文字图层", "Text layer"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WorkbenchText.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("添加", "Add")) {
                        let layer = ImageLayer(kind: .text,
                                               name: text.isEmpty ? WorkbenchText.t("文字", "Text") : String(text.prefix(24)),
                                               text: ImageTextContent(text: text, fontSize: fontSize,
                                                                      colorHex: color.hexString))
                        center.apply(.addImageLayer(layer))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("workbench.text.add")
                }
            }
        }
    }
}

// MARK: - Properties

struct WorkbenchPropertiesPanel: View {
    @ObservedObject var center: WorkbenchCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if center.project?.kind == .video {
                    VideoPropertiesView(center: center)
                } else {
                    ImagePropertiesView(center: center)
                    CanvasPropertiesView(center: center)
                }
            }
            .padding(12)
        }
    }
}

struct ImagePropertiesView: View {
    @ObservedObject var center: WorkbenchCenter

    private var layer: ImageLayer? {
        center.project?.imageLayers.first { $0.id == center.selectedLayerID }
    }

    var body: some View {
        Group {
            if let layer {
                SectionCard(title: WorkbenchText.t("图层属性", "Layer properties")) {
                    Text(layer.name).font(.subheadline).foregroundStyle(.secondary)

                    CommitSlider(label: WorkbenchText.t("水平位置", "Horizontal"),
                                 value: layer.transform.centerX, range: 0...1,
                                 identifier: "workbench.layer.centerX") { value in
                        update(transform: ImageLayerTransform(centerX: value,
                                                              centerY: layer.transform.centerY,
                                                              scale: layer.transform.scale,
                                                              rotationDegrees: layer.transform.rotationDegrees))
                    }
                    CommitSlider(label: WorkbenchText.t("垂直位置", "Vertical"),
                                 value: layer.transform.centerY, range: 0...1,
                                 identifier: "workbench.layer.centerY") { value in
                        update(transform: ImageLayerTransform(centerX: layer.transform.centerX,
                                                              centerY: value,
                                                              scale: layer.transform.scale,
                                                              rotationDegrees: layer.transform.rotationDegrees))
                    }
                    CommitSlider(label: WorkbenchText.t("缩放", "Scale"),
                                 value: layer.transform.scale, range: 0.1...5,
                                 identifier: "workbench.layer.scale") { value in
                        update(transform: ImageLayerTransform(centerX: layer.transform.centerX,
                                                              centerY: layer.transform.centerY,
                                                              scale: value,
                                                              rotationDegrees: layer.transform.rotationDegrees))
                    }
                    CommitSlider(label: WorkbenchText.t("旋转", "Rotation"),
                                 value: layer.transform.rotationDegrees, range: 0...360,
                                 identifier: "workbench.layer.rotation") { value in
                        update(transform: ImageLayerTransform(centerX: layer.transform.centerX,
                                                              centerY: layer.transform.centerY,
                                                              scale: layer.transform.scale,
                                                              rotationDegrees: value))
                    }
                    CommitSlider(label: WorkbenchText.t("不透明度", "Opacity"),
                                 value: layer.opacity, range: 0...1,
                                 identifier: "workbench.layer.opacity") { value in
                        center.apply(.updateLayer(id: layer.id, transform: nil, opacity: value,
                                                  isHidden: nil, isLocked: nil, adjustment: nil,
                                                  text: nil, crop: .unchanged))
                    }
                }

                if layer.kind == .image {
                    SectionCard(title: WorkbenchText.t("裁剪", "Crop")) {
                        Text(center.cropRect.map { rect in
                            String(format: "x %.2f  y %.2f  w %.2f  h %.2f", rect.x, rect.y, rect.width, rect.height)
                        } ?? WorkbenchText.t("未裁剪", "Not cropped"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(center.isCropping
                                   ? WorkbenchText.t("完成裁剪", "Finish crop")
                                   : WorkbenchText.t("开始裁剪", "Start crop")) {
                                if center.isCropping {
                                    if let rect = center.cropRect {
                                        center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil,
                                                                  isHidden: nil, isLocked: nil, adjustment: nil,
                                                                  text: nil, crop: .set(rect)))
                                    }
                                    center.isCropping = false
                                } else {
                                    center.cropRect = layer.crop ?? NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                                    center.isCropping = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.crop.toggle")
                            if layer.crop != nil {
                                Button(WorkbenchText.t("清除裁剪", "Clear crop")) {
                                    center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil,
                                                              isHidden: nil, isLocked: nil, adjustment: nil,
                                                              text: nil, crop: .clear))
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }

                SectionCard(title: WorkbenchText.t("调整", "Adjust")) {
                    adjustmentSliders(layer: layer)
                }

                if layer.kind == .text, let text = layer.text {
                    SectionCard(title: WorkbenchText.t("文字", "Text")) {
                        TextField(WorkbenchText.t("内容", "Content"), text: Binding(
                            get: { text.text },
                            set: { newValue in
                                center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil,
                                                          isHidden: nil, isLocked: nil, adjustment: nil,
                                                          text: ImageTextContent(text: newValue,
                                                                                 fontSize: text.fontSize,
                                                                                 colorHex: text.colorHex,
                                                                                 fontName: text.fontName),
                                                          crop: .unchanged))
                            }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                Text(WorkbenchText.t("选择一个图层以编辑属性。", "Select a layer to edit its properties."))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
        }
    }

    @ViewBuilder
    private func adjustmentSliders(layer: ImageLayer) -> some View {
        let adjustment = layer.adjustment
        CommitSlider(label: WorkbenchText.t("饱和度", "Saturation"),
                     value: adjustment.saturation ?? 1, range: 0...3,
                     identifier: "workbench.adjust.saturation") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: value, contrast: adjustment.contrast, brightness: adjustment.brightness,
                exposureEV: adjustment.exposureEV, blurRadius: adjustment.blurRadius,
                sharpenRadius: adjustment.sharpenRadius, mosaicBlockSize: adjustment.mosaicBlockSize,
                filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("对比度", "Contrast"),
                     value: adjustment.contrast ?? 1, range: 0...3,
                     identifier: "workbench.adjust.contrast") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: value, brightness: adjustment.brightness,
                exposureEV: adjustment.exposureEV, blurRadius: adjustment.blurRadius,
                sharpenRadius: adjustment.sharpenRadius, mosaicBlockSize: adjustment.mosaicBlockSize,
                filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("亮度", "Brightness"),
                     value: adjustment.brightness ?? 0, range: -0.5...0.5,
                     identifier: "workbench.adjust.brightness") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: adjustment.contrast, brightness: value,
                exposureEV: adjustment.exposureEV, blurRadius: adjustment.blurRadius,
                sharpenRadius: adjustment.sharpenRadius, mosaicBlockSize: adjustment.mosaicBlockSize,
                filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("曝光", "Exposure"),
                     value: adjustment.exposureEV ?? 0, range: -5...5,
                     identifier: "workbench.adjust.exposure") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: adjustment.contrast,
                brightness: adjustment.brightness, exposureEV: value,
                blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("模糊", "Blur"),
                     value: adjustment.blurRadius ?? 0, range: 0...40,
                     identifier: "workbench.adjust.blur") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: adjustment.contrast,
                brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                blurRadius: value, sharpenRadius: adjustment.sharpenRadius,
                mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("锐化", "Sharpen"),
                     value: adjustment.sharpenRadius ?? 0, range: 0...100,
                     identifier: "workbench.adjust.sharpen") { value in
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: adjustment.contrast,
                brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                blurRadius: adjustment.blurRadius, sharpenRadius: value,
                mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID))
        }
        CommitSlider(label: WorkbenchText.t("马赛克", "Mosaic"),
                     value: Double(adjustment.mosaicBlockSize ?? 0), range: 0...64,
                     identifier: "workbench.adjust.mosaic") { value in
            let block = value < 1 ? nil : Int(value)
            setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                saturation: adjustment.saturation, contrast: adjustment.contrast,
                brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                mosaicBlockSize: block, filterID: adjustment.filterID))
        }
        Picker(WorkbenchText.t("滤镜", "Filter"), selection: Binding(
            get: { adjustment.filterID ?? "none" },
            set: { newValue in
                setAdjustment(layer: layer, adjustment: ImageLayerAdjustment(
                    saturation: adjustment.saturation, contrast: adjustment.contrast,
                    brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                    blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                    mosaicBlockSize: adjustment.mosaicBlockSize,
                    filterID: newValue == "none" ? nil : newValue))
            })) {
            Text(WorkbenchText.t("无", "None")).tag("none")
            ForEach(WorkbenchImageRenderer.supportedFilterIDs, id: \.self) { id in
                Text(id.replacingOccurrences(of: "CIPhotoEffect", with: "")
                    .replacingOccurrences(of: "CISepiaTone", with: "Sepia")).tag(id)
            }
        }
        .accessibilityIdentifier("workbench.adjust.filter")
    }

    private func setAdjustment(layer: ImageLayer, adjustment: ImageLayerAdjustment) {
        center.apply(.updateLayer(id: layer.id, transform: nil, opacity: nil, isHidden: nil,
                                  isLocked: nil, adjustment: adjustment, text: nil, crop: .unchanged))
    }

    private func update(transform: ImageLayerTransform) {
        guard let layer else { return }
        center.apply(.updateLayer(id: layer.id, transform: transform, opacity: nil, isHidden: nil,
                                  isLocked: nil, adjustment: nil, text: nil, crop: .unchanged))
    }
}

struct CanvasPropertiesView: View {
    @ObservedObject var center: WorkbenchCenter
    @State private var canvasWidth: Double = 1024
    @State private var canvasHeight: Double = 1024

    var body: some View {
        SectionCard(title: WorkbenchText.t("画布", "Canvas")) {
            if let canvas = center.project?.canvas {
                HStack {
                    Text(WorkbenchText.t("宽", "W"))
                    TextField("W", value: $canvasWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("workbench.canvas.width")
                    Text(WorkbenchText.t("高", "H"))
                    TextField("H", value: $canvasHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("workbench.canvas.height")
                }
                Button(WorkbenchText.t("应用画布尺寸", "Apply canvas size")) {
                    center.setCanvas(width: Int(canvasWidth), height: Int(canvasHeight),
                                     frameRate: canvas.frameRate)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.canvas.apply")
            }
            if let adjustment = center.project?.canvasAdjustment {
                CommitSlider(label: WorkbenchText.t("画布饱和度", "Canvas saturation"),
                             value: adjustment.saturation ?? 1, range: 0...3,
                             identifier: "workbench.canvas.saturation") { value in
                    center.apply(.setCanvasAdjustment(ImageLayerAdjustment(
                        saturation: value, contrast: adjustment.contrast,
                        brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                        blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                        mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID)))
                }
                CommitSlider(label: WorkbenchText.t("画布对比度", "Canvas contrast"),
                             value: adjustment.contrast ?? 1, range: 0...3,
                             identifier: "workbench.canvas.contrast") { value in
                    center.apply(.setCanvasAdjustment(ImageLayerAdjustment(
                        saturation: adjustment.saturation, contrast: value,
                        brightness: adjustment.brightness, exposureEV: adjustment.exposureEV,
                        blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                        mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID)))
                }
                CommitSlider(label: WorkbenchText.t("画布亮度", "Canvas brightness"),
                             value: adjustment.brightness ?? 0, range: -0.5...0.5,
                             identifier: "workbench.canvas.brightness") { value in
                    center.apply(.setCanvasAdjustment(ImageLayerAdjustment(
                        saturation: adjustment.saturation, contrast: adjustment.contrast,
                        brightness: value, exposureEV: adjustment.exposureEV,
                        blurRadius: adjustment.blurRadius, sharpenRadius: adjustment.sharpenRadius,
                        mosaicBlockSize: adjustment.mosaicBlockSize, filterID: adjustment.filterID)))
                }
            }
        }
        .onAppear {
            if let canvas = center.project?.canvas {
                canvasWidth = Double(canvas.width)
                canvasHeight = Double(canvas.height)
            }
        }
    }
}

// MARK: - Export

struct WorkbenchExportPanel: View {
    @ObservedObject var center: WorkbenchCenter
    var onExported: ((URL) -> Void)?
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)?
    /// Explicit "make variant": a new canvas node/branch keeping the original
    /// untouched; nil where the entrance has no canvas semantics.
    var onMakeVariant: ((ImageExportOptions) async throws -> Void)?

    @State private var imageFormat: ImageExportFormat = .png
    @State private var useOriginalSize = true
    @State private var width: Double = 1024
    @State private var height: Double = 1024
    @State private var quality: Double = 0.95
    @State private var preserveTransparency = true
    @State private var stripMetadata = true
    @State private var videoCodec: VideoExportCodec = .h264
    @State private var videoWidth: Double = 1280
    @State private var videoHeight: Double = 720
    @State private var videoFPS: Double = 30
    @State private var validationMessage: String?
    @State private var fileName = "export"
    @State private var showsShareSheet = false

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if center.project?.kind == .video {
                videoExportForm
            } else {
                imageExportForm
            }
            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if let progress = center.exportProgress {
                Section {
                    ProgressView(value: progress) {
                        Text(WorkbenchText.t("导出中…", "Exporting…"))
                    }
                    Button(WorkbenchText.t("取消导出", "Cancel export"), role: .destructive) {
                        center.cancelExport()
                    }
                    .frame(minHeight: 44)
                }
            }
            // Only a VERIFIED export is shown as a success; cancellation is a
            // neutral note without share actions (see notice below).
            if let result = center.lastExportResult {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(WorkbenchText.t("导出完成", "Export complete"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                            .accessibilityIdentifier("workbench.export.result")
                        Text(result.detail).font(.subheadline)
                        Text(result.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        // The native URL-based activity controller offers
                        // Save to Files, AirDrop and other destinations
                        // without loading the (possibly large) movie into
                        // memory.
                        Button {
                            showsShareSheet = true
                        } label: {
                            Label(WorkbenchText.t("分享 / 存到文件", "Share / Save to Files"),
                                  systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workbench.export.share")
                    }
                    .padding(.vertical, 2)
                }
                .id("workbench.export.result.section")
            } else if let message = center.lastExportMessage {
                // Cancellation and write-back confirmations are notices, not
                // successes: no retained URL, no share actions.
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workbench.export.notice")
                }
                .id("workbench.export.result.section")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: center.lastExportResult?.id) { _, _ in
            guard center.lastExportResult != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("workbench.export.result.section", anchor: .bottom)
                }
            }
        }
        .onAppear {
            // The panel hosts the entrance callback for this presentation:
            // exactly one verified export invokes it, exactly once.
            center.setExportEntranceCallback(onExported)
            if let canvas = center.project?.canvas {
                videoWidth = Double(canvas.width)
                videoHeight = Double(canvas.height)
                videoFPS = canvas.frameRate ?? 30
            }
            if let last = center.project?.lastVideoExport {
                videoCodec = last.codec
            }
            if center.lastExportResult != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    proxy.scrollTo("workbench.export.result.section", anchor: .bottom)
                }
            }
        }
        }
        .sheet(isPresented: $showsShareSheet) {
            if let result = center.lastExportResult {
                WorkbenchResultShareSheet(url: result.url)
            }
        }
    }

    private var imageExportForm: some View {
        Group {
            Section(WorkbenchText.t("图片导出", "Image export")) {
                Picker(WorkbenchText.t("格式", "Format"), selection: $imageFormat) {
                    Text("PNG").tag(ImageExportFormat.png)
                    Text("JPEG").tag(ImageExportFormat.jpeg)
                    Text("HEIC").tag(ImageExportFormat.heic)
                }
                .accessibilityIdentifier("workbench.export.image.format")
                Toggle(WorkbenchText.t("使用原始尺寸", "Original size"), isOn: $useOriginalSize)
                if !useOriginalSize {
                    HStack {
                        Text(WorkbenchText.t("宽", "W"))
                        TextField("W", value: $width, format: .number)
                            .textFieldStyle(.roundedBorder)
                        Text(WorkbenchText.t("高", "H"))
                        TextField("H", value: $height, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if imageFormat != .png {
                    CommitSlider(label: WorkbenchText.t("质量", "Quality"), value: quality,
                                 range: 0.1...1, identifier: "workbench.export.image.quality") { value in
                        quality = value
                    }
                }
                Toggle(WorkbenchText.t("保留透明度", "Preserve transparency"), isOn: $preserveTransparency)
                    .disabled(imageFormat == .jpeg)
                Toggle(WorkbenchText.t("移除元数据", "Strip metadata"), isOn: $stripMetadata)
                TextField(WorkbenchText.t("文件名", "File name"), text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workbench.export.image.name")
            }
            Section {
                Button(WorkbenchText.t("导出图片", "Export image")) {
                    exportImage()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.export.image.run")
                if let onSaveToSource {
                    Button(WorkbenchText.t("应用到画布", "Apply to canvas")) {
                        saveToSource(onSaveToSource, success: WorkbenchText.t("已更新画布原节点。", "Canvas node updated."))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.export.image.saveSource")
                }
                if let onMakeVariant {
                    Button(WorkbenchText.t("另存为分支", "Make variant")) {
                        saveToSource(onMakeVariant, success: WorkbenchText.t("已创建画布分支节点。", "Canvas variant created."))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.export.image.makeVariant")
                }
            }
        }
    }

    private var videoExportForm: some View {
        Group {
            Section(WorkbenchText.t("视频导出", "Video export")) {
                Picker(WorkbenchText.t("编码", "Codec"), selection: $videoCodec) {
                    Text("H.264").tag(VideoExportCodec.h264)
                    Text("HEVC").tag(VideoExportCodec.hevc)
                }
                .accessibilityIdentifier("workbench.export.video.codec")
                Menu {
                    Button(WorkbenchText.t("横版 1080p（1920×1080）", "Landscape 1080p (1920×1080)")) {
                        applyExportPreset(.landscape1080p)
                    }
                    Button(WorkbenchText.t("竖版 1080p（1080×1920）", "Portrait 1080p (1080×1920)")) {
                        applyExportPreset(.portrait1080p)
                    }
                    Button(WorkbenchText.t("方形 1080（1080×1080）", "Square 1080 (1080×1080)")) {
                        applyExportPreset(.square1080)
                    }
                } label: {
                    Label(WorkbenchText.t("导出预设", "Export preset"), systemImage: "rectangle.on.rectangle")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("workbench.export.video.preset")
                HStack {
                    Text(WorkbenchText.t("宽", "W"))
                    TextField("W", value: $videoWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text(WorkbenchText.t("高", "H"))
                    TextField("H", value: $videoHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                CommitSlider(label: WorkbenchText.t("帧率", "Frame rate"), value: videoFPS,
                             range: 1...120, identifier: "workbench.export.video.fps") { value in
                    videoFPS = value
                }
                TextField(WorkbenchText.t("文件名", "File name"), text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workbench.export.video.name")
            }
            Section {
                Button(WorkbenchText.t("导出视频", "Export video")) {
                    exportVideo()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.export.video.run")
            }
        }
    }

    private func applyExportPreset(_ preset: VideoExportPreset) {
        videoWidth = Double(preset.width)
        videoHeight = Double(preset.height)
        videoFPS = preset.defaultFrameRate
    }

    private func saveToSource(_ save: @escaping (ImageExportOptions) async throws -> Void,
                              success: String) {
        let options = ImageExportOptions(format: imageFormat,
                                         width: useOriginalSize ? nil : Int(width),
                                         height: useOriginalSize ? nil : Int(height),
                                         quality: quality,
                                         preserveTransparency: preserveTransparency,
                                         stripMetadata: stripMetadata,
                                         fileName: sanitized(fileName))
        validationMessage = nil
        // A write-back attempt is a new output: the retained export result no
        // longer represents the latest attempt.
        center.clearExportDelivery()
        Task {
            do {
                try await save(options)
                center.noteExportMessage(success)
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func exportImage() {
        let options = ImageExportOptions(format: imageFormat,
                                         width: useOriginalSize ? nil : Int(width),
                                         height: useOriginalSize ? nil : Int(height),
                                         quality: quality,
                                         preserveTransparency: preserveTransparency,
                                         stripMetadata: stripMetadata,
                                         fileName: sanitized(fileName))
        validationMessage = nil
        // Clear before validation too: a rejected attempt must never leave a
        // stale success on screen.
        center.clearExportDelivery()
        do {
            try MediaExportValidation.validateImage(options,
                                                    canvasSize: center.project?.canvas.map {
                CGSizeLike(width: $0.width, height: $0.height)
            }, hasTransparency: true)
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        Task { await center.exportImage(options: options) }
    }

    private func exportVideo() {
        let options = VideoExportOptions(codec: videoCodec,
                                         width: MediaResourceGuard.even(Int(videoWidth)),
                                         height: MediaResourceGuard.even(Int(videoHeight)),
                                         frameRate: videoFPS,
                                         fileName: sanitized(fileName))
        validationMessage = nil
        center.clearExportDelivery()
        do {
            try MediaExportValidation.validateVideo(options, timeline: center.project?.videoTimeline ?? VideoTimeline())
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        Task { await center.exportVideo(options: options) }
    }

    private func sanitized(_ name: String) -> String {
        let allowed = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.isEmpty ? "export" : String(allowed.prefix(120))
    }
}

// MARK: - Verified result delivery

#if canImport(UIKit)
/// Native URL-based activity controller for a verified export. It offers
/// Save to Files, AirDrop and other system destinations directly for the
/// retained file, so even a large movie is never copied into app memory.
struct WorkbenchResultShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Shared controls

/// Slider bound to an external model value.
///
/// * Exactly ONE commit per gesture. SwiftUI can write the binding once more
///   *after* `onEditingChanged(false)`; committing immediately there and then
///   debouncing the trailing write produced two undo steps per drag (r3→r5).
///   The gesture-end commit therefore waits a short settle interval that any
///   trailing change reschedules, so the final value commits exactly once.
/// * Accessibility edits (VoiceOver adjust actions) that never toggle editing
///   still commit once through the longer debounced path.
/// * External changes (undo/redo, AI proposal, another panel) resync the
///   shown value and cancel any pending local commit, so an undo can never be
///   overwritten by a stale local value.
/// * No-op commits (delta below tolerance) are dropped here and again in the
///   transaction engine.
struct CommitSlider: View {
    let label: String
    let range: ClosedRange<Double>
    let identifier: String
    let onCommit: (Double) -> Void

    private let externalValue: Double
    @State private var value: Double
    @State private var lastCommitted: Double
    @State private var isEditing = false
    @State private var pendingCommit: Task<Void, Never>?

    private static let tolerance = 0.004
    private static let gestureSettle = Duration.milliseconds(180)
    private static let accessibilitySettle = Duration.milliseconds(350)

    init(label: String, value: Double, range: ClosedRange<Double>, identifier: String,
         onCommit: @escaping (Double) -> Void) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        self.label = label
        self.range = range
        self.identifier = identifier
        self.onCommit = onCommit
        self.externalValue = value
        _value = State(initialValue: clamped)
        _lastCommitted = State(initialValue: clamped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if editing {
                    isEditing = true
                    pendingCommit?.cancel()
                } else {
                    isEditing = false
                    scheduleCommit(after: Self.gestureSettle)
                }
            })
            .frame(minHeight: 44)
            .accessibilityIdentifier(identifier)
        }
        .onChange(of: value) { _, _ in
            guard !isEditing else { return }
            scheduleCommit(after: Self.accessibilitySettle)
        }
        .onChange(of: externalValue) { _, newValue in
            guard !isEditing else { return }
            // The document is the source of truth again: drop any local commit
            // that has not fired yet so undo/redo/proposals cannot be
            // overwritten by a stale slider value.
            pendingCommit?.cancel()
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if abs(clamped - value) > Self.tolerance {
                value = clamped
            }
            lastCommitted = clamped
        }
    }

    private func scheduleCommit(after delay: Duration) {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            commitIfNeeded()
        }
    }

    private func commitIfNeeded() {
        guard abs(value - lastCommitted) > Self.tolerance else { return }
        lastCommitted = value
        onCommit(value)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Color {
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// `#RRGGBB` / `RRGGBB` initializer used by the caption overlay.
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        let int = UInt64(value, radix: 16) ?? 0
        self.init(red: Double((int >> 16) & 0xFF) / 255,
                  green: Double((int >> 8) & 0xFF) / 255,
                  blue: Double(int & 0xFF) / 255)
    }
}
