// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import FloeWorkbench

/// The accepted integrated workspace: tools, layers/assets, the actual
/// canvas, properties/assistant and a multi-track video timeline.
struct MediaV2Workspace: View {
    @Bindable var session: MediaV2Session
    var onAssistant: (() -> Void)? = nil
    var onExported: ((URL) -> Void)? = nil
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)? = nil
    var onMakeVariant: ((ImageExportOptions) async throws -> Void)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.editorCanvasOwnsTextInput) private var ownsTextInput
    @State private var importing = false
    @State private var importingCaptions = false
    @State private var objectsVisible = true
    @State private var inspectorVisible = true
    @State private var compactPanel: String?
    @State private var audio: NativeCreativeAudioSession?
    @State private var text = ""
    @State private var number = 12.0
    @State private var property = "scale"
    @State private var showingDiagnostic = false
    @State private var showingProviderSettings = false
    @State private var showingImageExport = false
    @State private var showingToolPicker = false
    @State private var compactToolSection: MediaV2ImageToolSection?
    @State private var showingSelectionFeather = false
    @State private var pickedTool: String?
    @State private var inspectorIsInline = false
    @AppStorage(MediaDrawingInputPolicy.preferenceKey) private var fingerDrawing = false
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1050
            let compactTools = UIDevice.current.userInterfaceIdiom == .phone || geometry.size.width < 700
            VStack(spacing: 0) {
                toolbar(wide: wide, compact: geometry.size.width < 600)
                Divider()
                if session.project.kind == .image {
                    if !compactTools { imageOptionsBar(wide: wide); Divider() }
                } else { toolCategories(wide: wide); Divider() }
                HStack(alignment: .top, spacing: 0) {
                    if session.project.kind == .image {
                        if !compactTools {
                            MediaV2ImageToolRail(selectedTool: session.tool, pencilEditing: session.pencilEditing, color: paintColor,
                                onChoose: { selectTool($0, wide: wide) }, onSearch: { showingToolPicker = true })
                                .disabled(session.saving || session.processingTool)
                        }
                    } else { toolRail(wide: wide) }
                    if wide && objectsVisible { objectPanel.frame(width: 224); Divider() }
                    VStack(spacing: 0) {
                        MediaV2Preview(session: session)
                        previewControls(wide: wide)
                        if session.project.kind == .video { Divider(); MediaV2Timeline(session: session).frame(height: max(190, min(260, geometry.size.height * 0.32))) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide && inspectorVisible { Divider(); propertiesPanel.frame(width: 288) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                if session.project.kind == .image && compactTools {
                    Divider()
                    imageOptionsBar(wide: false, compact: true)
                    Divider()
                    MediaV2CompactImageTools(selectedTool: session.tool,
                        onSection: { compactToolSection = $0 }, onSearch: { showingToolPicker = true })
                        .disabled(session.saving || session.processingTool)
                }
                Divider()
                status
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
                .onChange(of: wide, initial: true) { _, value in inspectorIsInline = value }
        }
        .ignoresSafeArea(.keyboard, edges: ownsTextInput ? [] : .bottom)
        .background(Color(uiColor: .systemBackground))
        .fileImporter(isPresented: $importing, allowedContentTypes: importContentTypes) { result in
            switch result {
            case .success(let url):
                if importingCaptions { Task { do { try await session.importCaptions(url) } catch { session.diagnostic = error.localizedDescription } } }
                else { Task { await session.importFile(url) } }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { compactPanel != nil }, set: { if !$0 { compactPanel = nil } })) {
            NavigationStack {
                Group { if compactPanel == "objects" { objectPanel } else { propertiesPanel } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { compactPanel = nil } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingDiagnostic) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(session.diagnostic ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if session.exportError as? PreparedVideoError == .emptyTimeline {
                            Button(WorkbenchText.t("导入视频或图片", "Import video or images")) { showingDiagnostic = false; beginImport() }.frame(minHeight: 44)
                        }
                    }.padding()
                }.navigationTitle(WorkbenchText.t("操作详情", "Action details"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { showingDiagnostic = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingProviderSettings) { MediaV2ProviderConfigurationView() }
        .sheet(isPresented: $showingImageExport) { MediaV2ImageExportSheet(session: session) }
        .sheet(isPresented: $showingToolPicker, onDismiss: usePickedTool) {
            MediaV2ToolPicker(tools: session.applicableTools, isImage: session.project.kind == .image,
                selectedTool: session.tool, categoryTitle: categoryTitle) { pickedTool = $0 }
        }
        .sheet(item: $compactToolSection, onDismiss: usePickedTool) { section in
            MediaV2CompactToolPicker(section: section, selectedTool: session.tool, pencilEditing:session.pencilEditing) { pickedTool = $0 }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item:$session.compoundEditorRoute) { route in
            MediaV2CompoundEditor(rootSession:session,route:route,onAssistant:onAssistant)
        }
        .onDisappear { session.stopPlayback() }
        .onChange(of: session.tool) { _, tool in
            number = tool == "image.text" ? 72 : tool.contains("exposure") ? 0 : tool.contains("speed") ? 1 : tool.contains("white-balance") ? 6500 : tool.contains("opacity") || tool.contains("hsl") ? 1 : tool.contains("pip") ? 0.4 : 12
            if let layer = session.selectedLayer, case .text(let content) = layer.content { text = content.text }
        }
    }
    private func toolbar(wide: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            MusicIconButton("sidebar.left", WorkbenchText.t("图层与素材", "Layers and assets")) {
                if wide { objectsVisible.toggle() } else { compactPanel = "objects" }
            }
            if !compact { Divider().frame(height: 22).padding(.horizontal, 4) }
            MusicIconButton("arrow.uturn.backward", WorkbenchText.t("撤销", "Undo")) { session.undo() }.disabled(!session.canUndo)
            if !compact { MusicIconButton("arrow.uturn.forward", WorkbenchText.t("重做", "Redo")) { session.redo() }.disabled(!session.canRedo) }
            Menu {
                if !wide { Button(WorkbenchText.t("导入素材", "Import media"), systemImage: "square.and.arrow.down") { beginImport() } }
                if session.project.kind == .image {
                    Section(WorkbenchText.t("新增图层", "New layer")) {
                        Button(WorkbenchText.t("绘画图层", "Drawing layer"), systemImage: "paintbrush") {
                            session.addLayer(.strokes(.init()), name: WorkbenchText.t("绘图", "Drawing"))
                            selectTool("image.brush", wide: wide)
                        }
                        Button(WorkbenchText.t("文字", "Text"), systemImage: "character.cursor.ibeam") { addTextLayer(wide: wide) }
                        Button(WorkbenchText.t("形状", "Shape"), systemImage: "square.on.circle") {
                            run("image.shape"); selectTool("image.shape", wide: wide)
                        }
                        Button(WorkbenchText.t("调色调整层", "Color adjustment layer"), systemImage: "slider.horizontal.3") {
                            session.addLayer(.adjustment(.init()), name: WorkbenchText.t("调色", "Color adjustment"))
                            selectTool("image.curves", wide: wide)
                        }
                    }
                    Section(WorkbenchText.t("整理图层", "Organize layers")) {
                        Button(WorkbenchText.t("编组所选图层", "Group selected layers"), systemImage: "folder") { run("image.group-layer") }
                            .disabled(session.selectedLayerSet.isEmpty)
                    }
                } else {
                    Button(WorkbenchText.t("视频轨", "Video track")) { session.addTrack(.visual) }
                    Button(WorkbenchText.t("音频轨", "Audio track")) { session.addTrack(.audio) }
                    Button(WorkbenchText.t("字幕", "Caption")) { run("video.caption") }
                }
            } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .accessibilityLabel(WorkbenchText.t("添加", "Add"))
                .disabled(session.saving || session.processingTool)
            if !compact { Divider().frame(height: 22).padding(.horizontal, 4) }
            if wide { MusicIconButton("square.and.arrow.down", WorkbenchText.t("导入素材", "Import media")) { beginImport() } }
            Menu {
                if compact { Button(WorkbenchText.t("重做", "Redo"), systemImage: "arrow.uturn.forward") { session.redo() }.disabled(!session.canRedo) }
                if session.project.kind == .image {
                    Button(WorkbenchText.t("导出图片…", "Export image…")) { showingImageExport = true }
                } else { Button(WorkbenchText.t("导出 MP4", "Export MP4")) { session.export() } }
                Button(WorkbenchText.t("完整工程包", "Complete original")) { exchange(.original) }
                Button(WorkbenchText.t("引用工程包", "Referenced original")) { exchange(.references) }
                if session.project.kind == .image {
                    Button("OpenRaster (.ora)") { exchange(.ora) }
                    Button("Photoshop (.psd)") { exchange(.psd) }
                    if let onSaveToSource {
                        Button(WorkbenchText.t("更新原图", "Update original"), systemImage: "arrow.triangle.2.circlepath") {
                            session.saveToSource(message: WorkbenchText.t("已更新原图", "Original updated")) {
                                try await onSaveToSource(.init(format: .png))
                            }
                        }
                    }
                    if let onMakeVariant {
                        Button(WorkbenchText.t("另存一版", "Make variant"), systemImage: "square.on.square") {
                            session.saveToSource(message: WorkbenchText.t("已另存一版", "Variant saved")) {
                                try await onMakeVariant(.init(format: .png))
                            }
                        }
                    }
                } else { Button("OpenTimelineIO (.otio)") { exchange(.otio) } }
            } label: {
                if session.project.kind == .image { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                else if wide { Label(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                else { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
            }.accessibilityLabel(session.project.kind == .image ? WorkbenchText.t("文件操作", "File actions") : WorkbenchText.t("导出", "Export"))
                .accessibilityIdentifier("media.v2.fileActions")
                .disabled(session.rendering || session.processingTool || session.saving || session.imageWarpDraft != nil)
            Spacer(minLength: 8)
            if wide {
                Label(session.saving ? WorkbenchText.t("正在保存…", "Saving…")
                    : session.sourceSaveFeedback ?? WorkbenchText.t("工程已保存", "Project saved"),
                    systemImage: session.saving ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("media.v2.saveStatus")
            }
            MusicIconButton("sidebar.right", WorkbenchText.t("属性", "Properties")) {
                if wide { inspectorVisible.toggle() } else { compactPanel = "properties" }
            }
            if session.project.kind == .image {
                Button { showingImageExport = true } label: {
                    Group {
                        if compact { Image(systemName: "square.and.arrow.up").frame(minWidth: 24) }
                        else { Label(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up") }
                    }.font(.callout.weight(.semibold)).frame(minHeight: 32)
                }.buttonStyle(.borderedProminent)
                    .accessibilityLabel(WorkbenchText.t("导出图片", "Export image"))
                    .accessibilityIdentifier("media.v2.export")
                    .disabled(session.rendering || session.processingTool || session.saving || session.imageWarpDraft != nil)
            }
        }.padding(.horizontal, compact ? 6 : 10).background(Color(uiColor: .secondarySystemBackground))
    }
    private func imageOptionsBar(wide: Bool, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: wide ? 10 : 6) {
                    Label(currentToolTitle, systemImage: MediaV2ImageToolLayout.entry(for: session.tool)?.icon ?? "slider.horizontal.3")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("media.v2.options.tool")
                    Divider().frame(height: 24)
                    if MediaV2ImageToolLayout.selectionTools.contains(session.tool) {
                        Picker(WorkbenchText.t("选区模式", "Selection mode"), selection: $session.selectionMode) {
                            Text(WorkbenchText.t("新建", "New")).tag(ImageSelectionOperation.replace)
                            Text(WorkbenchText.t("添加", "Add")).tag(ImageSelectionOperation.add)
                            Text(WorkbenchText.t("减去", "Subtract")).tag(ImageSelectionOperation.subtract)
                        }.pickerStyle(.segmented).frame(width: compact ? 190 : 210, height: 44)
                            .accessibilityIdentifier("media.v2.selection.mode")
                        if session.tool == "image.wand" {
                            MediaV2ToolValuePopover(title: WorkbenchText.t("容差", "Tolerance"), value: session.wandTolerance,
                                range: 0...1, percent: true) { session.wandTolerance = $0 }
                        }
                        featherButton
                        invertButton(showTitle: false)
                        deselectButton(showTitle: false)
                        subjectMenu
                        if session.tool == "image.polygon" { polygonMenu }
                    } else if session.tool == "image.feather-brush" {
                        MediaV2ToolValuePopover(title:WorkbenchText.t("直径","Diameter"),value:session.featherDiameter,
                            range:1...200,suffix:"px") { session.featherDiameter = $0 }
                            .accessibilityIdentifier("media.v2.feather.diameter")
                        MediaV2ToolValuePopover(title:WorkbenchText.t("强度","Strength"),value:session.featherStrength,
                            range:0.01...1,percent:true) { session.featherStrength = $0 }
                            .accessibilityIdentifier("media.v2.feather.strength")
                        MediaDrawingInputMenu()
                    } else if MediaV2Session.usesDirectStroke(session.tool) {
                        if compact {
                            Toggle(WorkbenchText.t("手指绘画", "Finger drawing"), isOn: $fingerDrawing)
                                .toggleStyle(.button).frame(minHeight: 44)
                            ColorPicker(WorkbenchText.t("绘画颜色", "Paint color"), selection: paintColor, supportsOpacity: false)
                                .labelsHidden().frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("media.v2.paintColor")
                        }
                        MediaV2ToolValuePopover(title: WorkbenchText.t("大小", "Size"), value: session.brushWidth,
                            range: 1...200, suffix: "px") { session.brushWidth = $0 }
                        MediaV2ToolValuePopover(title: WorkbenchText.t("不透明度", "Opacity"), value: session.brushOpacity,
                            range: 0.01...1, percent: true) { session.brushOpacity = $0 }
                        MediaV2ToolValuePopover(title: WorkbenchText.t("硬度", "Hardness"), value: session.brushHardness,
                            range: 0...1, percent: true) { session.brushHardness = $0 }
                        if ["image.clone", "image.heal"].contains(session.tool) {
                            Button(WorkbenchText.t("设置取样点", "Set sample point"), systemImage: "scope") { session.clonePickSource = true }
                                .frame(minHeight: 44)
                                .tint(session.clonePickSource ? Color.accentColor : Color.primary)
                                .accessibilityIdentifier("media.v2.paint.samplePoint")
                        }
                        if session.tool == "image.eraser" {
                            Toggle(WorkbenchText.t("恢复", "Restore"), isOn: $session.eraserRestores).fixedSize()
                        }
                        if !compact { MediaDrawingInputMenu() }
                    } else if session.tool == "view.pan" {
                        Text(WorkbenchText.t("拖动移动画布，双指缩放。", "Drag to move the canvas; pinch to zoom."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if MediaV2ImageToolLayout.tapTools.contains(session.tool) {
                        Text(canvasTapHint).font(.caption).foregroundStyle(.secondary)
                        if session.tool == "image.eyedropper" {
                            Circle().fill(paintColor.wrappedValue).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                                .accessibilityHidden(true)
                            Text(session.colorHex.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    if !compact && session.selection != nil && !MediaV2ImageToolLayout.selectionTools.contains(session.tool) {
                        Divider().frame(height: 24)
                        featherButton
                        invertButton(showTitle: false)
                        deselectButton(showTitle: false)
                    }
                    if session.tool != "view.pan" {
                        Button { openProperties(wide: wide) } label: {
                            if !wide && MediaV2ImageToolLayout.selectionTools.contains(session.tool) {
                                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                            } else {
                                Label(WorkbenchText.t("更多设置", "More settings"), systemImage: "slider.horizontal.3")
                                    .frame(minHeight: 44)
                            }
                        }
                            .accessibilityLabel(WorkbenchText.t("更多设置", "More settings"))
                            .accessibilityIdentifier("media.v2.options.more")
                    }
                }.padding(.horizontal, 12).frame(minHeight: 50)
            }
            if compact && session.selection != nil {
                Divider()
                HStack(spacing: 16) {
                    if !MediaV2ImageToolLayout.selectionTools.contains(session.tool) { featherButton }
                    invertButton(showTitle: true)
                    deselectButton(showTitle: true)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media.v2.toolOptions")
        .disabled(session.saving || session.processingTool)
    }
    private var canvasTapHint: String {
        switch session.tool {
        case "image.wand":
            return WorkbenchText.t("点按画布选择相近颜色的区域。", "Tap the canvas to select a similar color region.")
        case "image.polygon":
            return WorkbenchText.t("点按画布添加顶点，闭合后生成选区。", "Tap the canvas to add vertices, then close the selection.")
        default:
            return WorkbenchText.t("点按画布取色。", "Tap the canvas to sample a color.")
        }
    }
    private var featherButton: some View {
        Button { showingSelectionFeather = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "wind")
                Text(WorkbenchText.t("羽化边缘", "Feather edges") + " "
                    + session.selectionDisplayFeatherPixels.formatted(.number.precision(.fractionLength(0...1))) + " px")
            }.font(.callout).frame(minHeight: 44)
        }.disabled(session.selection == nil)
            .accessibilityLabel(WorkbenchText.t("羽化", "Feather"))
            .accessibilityValue(session.selectionDisplayFeatherPixels.formatted(.number.precision(.fractionLength(0...1))) + " px")
            .accessibilityIdentifier("media.v2.selection.feather")
            .accessibilityHint(session.selection == nil
                ? WorkbenchText.t("先建立选区，再调整羽化。", "Create a selection before adjusting feather.")
                : WorkbenchText.t("柔化当前选区的边缘。", "Soften the edges of the current selection."))
            .popover(isPresented: $showingSelectionFeather) {
                MediaV2SelectionFeatherEditor(session: session)
            }
    }
    private func invertButton(showTitle: Bool) -> some View {
        Button { performImageAction("image.inverse") } label: {
            if showTitle {
                Label(WorkbenchText.t("反选", "Invert"), systemImage: "circle.lefthalf.filled").font(.callout).frame(minHeight: 44)
            } else {
                Image(systemName: "circle.lefthalf.filled").frame(width: 44, height: 44)
            }
        }.buttonStyle(.plain)
            .disabled(session.selection == nil)
            .accessibilityLabel(WorkbenchText.t("反选", "Invert selection"))
            .accessibilityIdentifier("media.v2.selection.inverse")
    }
    private func deselectButton(showTitle: Bool) -> some View {
        Button { performImageAction("image.deselect") } label: {
            if showTitle {
                Label(WorkbenchText.t("取消选择", "Deselect"), systemImage: "xmark.circle").font(.callout).frame(minHeight: 44)
            } else {
                Image(systemName: "xmark.circle").frame(width: 44, height: 44)
            }
        }.buttonStyle(.plain)
            .disabled(session.selection == nil)
            .accessibilityLabel(WorkbenchText.t("取消选择", "Deselect"))
            .accessibilityIdentifier("media.v2.selection.deselect")
    }
    private var subjectMenu: some View {
        Menu {
            Button(WorkbenchText.t("选择主体", "Select subject"), systemImage: "person.crop.rectangle") { performImageAction("image.subject") }
            Button(WorkbenchText.t("移除背景", "Remove background"), systemImage: "person.crop.circle.badge.minus") { performImageAction("image.background") }
        } label: {
            Label(WorkbenchText.t("主体", "Subject"), systemImage: "person.crop.rectangle")
                .font(.callout).frame(minHeight: 44)
        }.disabled(session.selectedLayer == nil || session.selectedLayer?.isLocked == true)
            .accessibilityIdentifier("media.v2.selection.subject")
    }
    private var polygonMenu: some View {
        Menu {
            Button(WorkbenchText.t("闭合选区", "Close selection"), systemImage: "checkmark") { closePolygon() }
                .disabled(session.polygonPoints.count < 3)
            Button(WorkbenchText.t("清除顶点", "Clear vertices"), systemImage: "trash") { session.polygonPoints = [] }
                .disabled(session.polygonPoints.isEmpty)
        } label: {
            Label(WorkbenchText.t("顶点 \(session.polygonPoints.count)", "Vertices \(session.polygonPoints.count)"),
                  systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout).frame(minHeight: 44)
        }.accessibilityIdentifier("media.v2.selection.polygon")
    }
    private func closePolygon() {
        var input = MediaV2ToolInput()
        input.points = session.polygonPoints; input.property = session.selectionMode.rawValue
        input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool("image.polygon", input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func toolCategories(wide: Bool) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(categories, id: \.self) { category in
                        Menu {
                            let tools = session.applicableTools.filter { $0.category == category }
                            ForEach(tools.filter { !MediaV2Session.providerToolIDs.contains($0.id) }) { tool in
                                toolMenuButton(tool, wide: wide)
                            }
                            let providerTools = tools.filter { MediaV2Session.providerToolIDs.contains($0.id) }
                            if !providerTools.isEmpty {
                                Section(WorkbenchText.t("AI 编辑", "AI editing")) {
                                    ForEach(providerTools) { tool in toolMenuButton(tool, wide: wide) }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(categoryTitle(category)).font(.callout)
                                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                            }.foregroundStyle(.primary).frame(minHeight: 44).padding(.horizontal, 10)
                                .background(session.applicableTools.first(where: { $0.id == session.tool })?.category == category ? Color.primary.opacity(0.07) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.padding(.horizontal, 6)
            }
            if MediaDrawingInputPolicy.isStrokeTool(session.tool) || session.tool == "video.motion-path" {
                Divider().frame(height: 22)
                MediaDrawingInputMenu()
            }
            if session.project.kind == .image {
                Divider().frame(height: 22)
                Button { showingToolPicker = true } label: {
                    Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                }.accessibilityLabel(WorkbenchText.t("查找全部工具", "Find all tools"))
                    .accessibilityIdentifier("media.v2.tools.search")
            }
        }.accessibilityIdentifier("media.v2.toolbox").disabled(session.saving || session.processingTool)
    }
    private var categories: [String] {
        var values: [String] = []
        for tool in session.applicableTools where tool.category != "assets" && !values.contains(tool.category) { values.append(tool.category) }
        guard session.project.kind == .image else { return values }
        let order = ["selection", "paint", "vector", "mask", "transform", "repair", "adjust"]
        return order.filter { values.contains($0) } + values.filter { !order.contains($0) }
    }
    private func toolMenuButton(_ tool: MediaPreparedToolDescriptor, wide: Bool) -> some View {
        Button { selectTool(tool.id, wide: wide) } label: {
            Text(tool.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en"))
            if session.tool == tool.id { Image(systemName: "checkmark") }
        }
    }
    private func selectTool(_ id: String, wide: Bool) {
        guard !session.saving, !session.processingTool else { return }
        // Selection refinements are actions on a region, never drawing tools.
        if id == "image.feather" {
            guard session.selection != nil else {
                session.diagnostic = WorkbenchText.t("请先在画布上建立选区。", "Create a selection on the canvas first.")
                return
            }
            showingSelectionFeather = true
            return
        }
        if ["image.inverse", "image.deselect", "image.subject"].contains(id) {
            performImageAction(id)
            return
        }
        if id == "view.zoom-in" { session.zoom = min(4, session.zoom * 1.25); return }
        if id == "view.zoom-out" { session.zoom = max(0.25, session.zoom / 1.25); return }
        if id == "view.fit" { session.fitCanvas(); return }
        if id != session.tool { session.selectionFeatherDraftPixels = nil }
        if MediaV2ImageToolLayout.editsCanvas(id) { session.lastCanvasEditTool = id }
        if id == "view.pan" { session.pencilEditing = false }
        session.tool = id
        // Canvas tools preserve the user's panel visibility. Parameter tools
        // reveal their inspector after the picker has finished dismissing.
        let directImageTool = session.project.kind == .image &&
            (MediaV2ImageToolLayout.editsCanvas(id) || id == "view.pan")
        if wide && !directImageTool { inspectorVisible = true }
        else if session.project.kind == .image && !directImageTool { compactPanel = "properties" }
    }
    private func usePickedTool() {
        guard let pickedTool else { return }
        self.pickedTool = nil
        selectTool(pickedTool, wide: inspectorIsInline)
    }
    private var currentToolTitle: String {
        MediaV2ImageToolLayout.entry(for: session.tool)?.title
            ?? session.applicableTools.first(where: { $0.id == session.tool })?.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en")
            ?? WorkbenchText.t("移动", "Move")
    }
    private func openProperties(wide: Bool) {
        if wide { inspectorVisible = true } else { compactPanel = "properties" }
    }
    private func performImageAction(_ id: String) {
        var input = MediaV2ToolInput()
        input.expectedRevision = session.document.revision
        input.objectID = session.selectedLayerID
        input.color = session.colorHex
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func addTextLayer(wide: Bool) {
        Task {
            do {
                _ = try await session.createImageTextLayer()
                selectTool("image.text", wide: wide)
            } catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func categoryTitle(_ category: String) -> String {
        if category == "assets" { return WorkbenchText.t("素材", "Assets") }
        let names: [String: (String, String)] = ["selection": ("选区", "Selection"), "paint": ("绘画", "Paint"), "mask": ("图层与蒙版", "Layers and masks"), "transform": ("几何与画布", "Geometry"), "vector": ("文字与路径", "Text and paths"), "repair": ("修复", "Retouch"), "adjust": ("调色", "Color"), "edit": ("剪辑", "Editing"), "composite": ("合成", "Compositing"), "animation": ("动画", "Animation"), "captions": ("字幕", "Captions"), "sound": ("声音", "Audio"), "video-color": ("调色", "Color")]
        let value = names[category] ?? (category, category)
        return WorkbenchText.t(value.0, value.1)
    }
    private func toolRail(wide: Bool) -> some View {
        VStack(spacing: 2) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(railTools, id: \.0) { value in
                        Button { selectTool(value.0, wide: wide) } label: {
                            Image(systemName: value.1).frame(width: 44, height: 44)
                                .background(session.tool == value.0 ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel(value.2).help(value.2)
                            .accessibilityIdentifier("media.v2.tool.\(value.0)")
                            .accessibilityAddTraits(session.tool == value.0 ? .isSelected : [])
                    }
                }
            }
            Divider()
            ColorPicker(session.project.kind == .image ? WorkbenchText.t("绘画颜色", "Paint color") : WorkbenchText.t("颜色", "Color"), selection: paintColor, supportsOpacity: false)
                .labelsHidden().frame(width: 44, height: 44)
                .accessibilityIdentifier("media.v2.paintColor")
        }.frame(width: 48).padding(.top, 4).overlay(alignment: .trailing) { Divider() }
    }
    private var railTools: [(String, String, String)] {
        session.project.kind == .image
            ? [("move", "cursorarrow", WorkbenchText.t("移动", "Move")), ("image.rectangle", "rectangle.dashed", WorkbenchText.t("选区", "Selection")), ("image.brush", "paintbrush.pointed", WorkbenchText.t("画笔", "Brush")), ("image.eraser", "eraser", WorkbenchText.t("橡皮", "Eraser")), ("image.crop", "crop", WorkbenchText.t("裁剪", "Crop")), ("image.pen", "point.topleft.down.to.point.bottomright.curvepath", WorkbenchText.t("钢笔", "Pen")), ("image.text", "character.cursor.ibeam", WorkbenchText.t("文字", "Text")), ("image.eyedropper", "eyedropper", WorkbenchText.t("吸管", "Eyedropper"))]
            : [("video.trim", "cursorarrow", WorkbenchText.t("剪辑", "Edit")), ("video.split", "scissors", WorkbenchText.t("分割", "Split")), ("video.video-transform", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", WorkbenchText.t("变换", "Transform")), ("video.keyframes", "diamond", WorkbenchText.t("关键帧", "Keyframes")), ("video.caption", "captions.bubble", WorkbenchText.t("字幕", "Captions")), ("video.mix", "speaker.wave.2", WorkbenchText.t("混音", "Mix"))]
    }
    private var paintColor: Binding<Color> {
        Binding(get: {
            let hex = session.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let rgb = (UInt64(hex, radix: 16) ?? 0x166F74) >> (hex.count == 8 ? 8 : 0)
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            session.colorHex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        })
    }
    private var objectPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.project.kind == .image ? WorkbenchText.t("图层", "Layers") : WorkbenchText.t("素材与轨道", "Assets and tracks")).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if session.project.kind == .image {
                    Menu {
                        if let layer = session.selectedLayer { layerActions(layer) }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel(WorkbenchText.t("图层操作", "Layer actions"))
                        .accessibilityIdentifier("media.v2.layerActions")
                        .disabled(session.selectedLayer == nil || session.saving || session.processingTool)
                    MusicIconButton(session.multipleLayerSelection ? "checkmark.circle.fill" : "checklist", WorkbenchText.t("多选图层", "Select multiple layers")) {
                        session.multipleLayerSelection.toggle(); session.selectedLayerIDs = session.selectedLayerID.map { [$0] } ?? []
                    }
                }
                Menu {
                    if session.project.kind == .image {
                        Button(WorkbenchText.t("绘画图层", "Drawing layer")) { session.addLayer(.strokes(.init()), name: WorkbenchText.t("绘图", "Drawing")) }
                        Button(WorkbenchText.t("编组所选图层", "Group selected layers")) { run("image.group-layer") }
                    } else {
                        Button(WorkbenchText.t("视频轨", "Video track")) { session.addTrack(.visual) }
                        Button(WorkbenchText.t("音频轨", "Audio track")) { session.addTrack(.audio) }
                        Button(WorkbenchText.t("字幕轨", "Caption track")) { session.addTrack(.caption) }
                    }
                    Button(WorkbenchText.t("导入素材", "Import media")) { beginImport() }
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
            }.padding(.leading, 10)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    if session.project.kind == .image {
                        ForEach(session.document.layers.reversed()) { layer in layerRow(layer) }
                    } else {
                        ForEach(session.document.trackGraph.tracks) { track in
                            HStack {
                                Button { session.select(track) } label: { Label(track.name, systemImage: track.kind == .audio ? "waveform" : track.kind == .caption ? "captions.bubble" : "film").font(.caption).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                                Button { session.submit([.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: nil, isMuted: !track.isMuted, isLocked: nil, volume: nil)]) } label: { Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.1").frame(width: 36, height: 44) }
                            }.padding(.horizontal, 8).background(session.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : .clear)
                            .contextMenu {
                                Button(track.isLocked ? WorkbenchText.t("解锁轨道", "Unlock track") : WorkbenchText.t("锁定轨道", "Lock track")) {
                                    session.submit([.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: nil, isMuted: nil, isLocked: !track.isLocked, volume: nil)])
                                }
                                Button(WorkbenchText.t("删除空轨道", "Delete empty track"), role: .destructive) {
                                    session.submit([.removeTrack(id: track.id, expectedRevision: track.revision)])
                                }.disabled(!track.clips.isEmpty)
                            }
                        }
                    }
                    Divider().padding(.vertical, 8)
                    Text(WorkbenchText.t("工程素材", "Project assets")).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    ForEach(session.document.assets) { asset in
                        HStack(spacing: 7) {
                            PersonalEditorAssetPreview(sourceID: "media:\(session.id):\(session.document.revision):\(asset.id)", title: asset.originalName) { pixels in
                                try await PersonalEditorPreviewRequests.mediaAsset(session: session, asset: asset, pixels: pixels)
                            }.frame(width: 64, height: 48).accessibilityIdentifier("media.asset.preview.\(asset.id.uuidString)")
                            Button { session.insertExistingAsset(asset) } label: {
                                HStack(spacing: 4) {
                                    Text(asset.originalName).font(.caption2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus.circle").font(.caption)
                                }.frame(minHeight: 44)
                            }.buttonStyle(.plain).help(WorkbenchText.t("加入当前工程", "Insert into project"))
                            MediaV2AssetActions(session: session, asset: asset)
                        }.padding(.horizontal, 8).padding(.vertical, 3)
                    }
                }
            }
        }
    }
    private func layerRow(_ layer: MediaPreparedLayer) -> some View {
        HStack(spacing: 3) {
            Button { session.select(layer) } label: {
                HStack(spacing: 8) {
                    if session.multipleLayerSelection { Image(systemName: session.selectedLayerIDs.contains(layer.id) ? "checkmark.circle.fill" : "circle").frame(width: 18) }
                    Image(systemName: layer.contentKind == .text ? "character.cursor.ibeam" : layer.contentKind == .group ? "folder" : layer.contentKind == .strokes ? "paintbrush" : layer.contentKind == .vectorPaths ? "square.on.circle" : "photo").frame(width: 28, height: 34).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) { Text(layer.name).lineLimit(1); if layer.isLocked { Image(systemName: "lock.fill").font(.caption2) } }.font(.caption)
                    Spacer(minLength: 0)
                }.frame(minHeight: 50)
            }.buttonStyle(.plain)
            Button { session.submit([.updateLayerFlags(id: layer.id, expectedRevision: layer.revision, name: nil, isVisible: !layer.isVisible, isLocked: nil, opacity: nil)]) } label: { Image(systemName: layer.isVisible ? "eye" : "eye.slash").frame(width: 44, height: 44) }.buttonStyle(.plain)
                .accessibilityLabel((layer.isVisible ? WorkbenchText.t("隐藏图层：", "Hide layer: ") : WorkbenchText.t("显示图层：", "Show layer: ")) + layer.name)
        }.padding(.leading, CGFloat(min(8, session.layerDepth(layer))) * 8).padding(.horizontal, 7)
            .disabled(session.saving || session.processingTool)
            .background((session.multipleLayerSelection ? session.selectedLayerIDs.contains(layer.id) : session.selectedLayerID == layer.id) ? Color.accentColor.opacity(0.1) : .clear)
            .contextMenu { layerActions(layer) }
    }
    @ViewBuilder private func layerActions(_ layer: MediaPreparedLayer) -> some View {
        Button(layer.isLocked ? WorkbenchText.t("解锁", "Unlock") : WorkbenchText.t("锁定", "Lock"), systemImage: layer.isLocked ? "lock.open" : "lock") { session.submit([.updateLayerFlags(id: layer.id, expectedRevision: layer.revision, name: nil, isVisible: nil, isLocked: !layer.isLocked, opacity: nil)]) }
        Button(WorkbenchText.t("复制图层", "Duplicate layer"), systemImage: "square.on.square") { objectAction("image.duplicate-layer", layer: layer) }
        if layer.contentKind == .group { Button(WorkbenchText.t("取消编组", "Ungroup"), systemImage: "folder.badge.minus") { objectAction("image.group-layer", layer: layer, flag: false) } }
        Button(WorkbenchText.t("上移", "Move up"), systemImage: "arrow.up") { session.shiftLayer(layer, by: 1) }
        Button(WorkbenchText.t("下移", "Move down"), systemImage: "arrow.down") { session.shiftLayer(layer, by: -1) }
        Button(WorkbenchText.t("删除图层", "Delete layer"), systemImage: "trash", role: .destructive) { session.submit([.removeLayer(id: layer.id, expectedRevision: layer.revision)]) }
            .disabled(layer.isLocked)
    }
    private var propertiesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(WorkbenchText.t("属性", "Properties")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { inspectorVisible = false; compactPanel = nil } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("收起属性", "Hide properties"))
            }.padding(.leading, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toolProperties
                    Divider()
                    if let layer = session.selectedLayer {
                        if session.tool == "move" { layerProperties(layer) }
                        else {
                            DisclosureGroup(WorkbenchText.t("图层属性", "Layer properties")) { layerProperties(layer).padding(.top, 12) }
                        }
                    }
                    if let selected = session.selectedClip { clipProperties(track: selected.track, clip: selected.clip) }
                    if let file = session.exportedFile {
                        Divider()
                        ShareLink(item: file) { Label(WorkbenchText.t("分享已导出文件", "Share exported file"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        if let onExported { Button(WorkbenchText.t("返回此文件", "Return this file")) { onExported(file) }.frame(minHeight: 44) }
                    }
                }.padding(14)
            }
        }.accessibilityIdentifier("media.v2.inspector")
    }
    @ViewBuilder private var toolProperties: some View {
        Text(currentToolTitle).font(.headline)
        if session.tool == "view.pan" {
            Text(WorkbenchText.t("拖动画布可调整视图位置。", "Drag the canvas to change the view position."))
                .font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("适应画布", "Fit canvas")) { session.fitCanvas() }.frame(minHeight: 44)
        } else if ["image.remove","image.content-fill"].contains(session.tool) {
            MediaV2ContentFillInspector(session:session,onImport:{beginImport()})
        } else if ["image.boolean","image.path-text","image.outline"].contains(session.tool) {
            MediaV2VectorTextInspector(session:session)
        } else if ["image.resize","image.canvas-size"].contains(session.tool) {
            MediaV2CanvasInspector(session:session)
        } else if ["image.inpaint","image.outpaint","video.transcribe","video.translate","video.voice-separate"].contains(session.tool) {
            MediaV2ProviderInspector(session:session,onImport:{beginImport()},onImportCaptions:{beginImport(captions:true)},onConfigure:{showingProviderSettings=true})
        } else if session.tool == "video.hdr" {
            MediaV2HDRInspector(session:session)
        } else if session.tool == "video.color-match" {
            MediaV2ColorMatchInspector(session:session,onImport:{beginImport()})
        } else if ["video.tracking","video.stabilize"].contains(session.tool) {
            MediaV2VideoMotionInspector(session:session,onImport:{beginImport()})
        } else if ["video.video-curves","video.wheels","video.video-hsl","video.video-lut"].contains(session.tool) {
            MediaV2VideoColorInspector(session: session, onImport: { beginImport() })
        } else if ["video.chroma","video.video-blend"].contains(session.tool) {
            MediaV2CompositeInspector(session:session, onImport: { beginImport() })
        } else if session.tool == "image.feather-brush" {
            MusicValueSlider(title: WorkbenchText.t("直径", "Diameter"), value: session.featherDiameter, range: 1...200, suffix: "px") { session.featherDiameter = $0 }
            MusicValueSlider(title: WorkbenchText.t("强度", "Strength"), value: session.featherStrength * 100, range: 1...100, suffix: "%") { session.featherStrength = $0 / 100 }
            Text(WorkbenchText.t("沿蒙版或图层的边缘涂抹。", "Brush along the edge of the mask or layer."))
                .font(.caption).foregroundStyle(.secondary)
        } else if MediaV2Session.nativePaintTools.contains(session.tool) {
            MediaV2PaintEffectsInspector(session:session)
        } else if session.tool == "video.scopes" {
            MediaV2ScopesInspector(session:session)
        } else if MediaV2Session.audioDerivationToolIDs.contains(session.tool) {
            MediaV2AudioDerivationInspector(session: session)
        } else if ["video.eq", "video.compressor"].contains(session.tool) {
            MediaV2AudioEffectsInspector(session:session)
        } else if MediaV2Session.extendedAnimationTools.contains(session.tool) {
            MediaV2AnimationInspector(session:session)
        } else if ["video.reverse", "video.freeze"].contains(session.tool) {
            MediaV2PlaybackInspector(session: session)
        } else if MediaV2Session.extendedColorTools.contains(session.tool) {
            MediaV2ColorInspector(session:session)
        } else if MediaV2Session.imageWarpToolIDs.contains(session.tool) {
            MediaV2ImageWarpInspector(session: session)
        } else if MediaV2Session.extendedImageTools.contains(session.tool) {
            MediaV2NativeSelectionInspector(session:session)
        } else if session.project.kind == .image, ["image.rectangle", "image.ellipse", "image.lasso", "image.polygon", "image.layer-mask", "image.vector-mask", "image.clip-mask"].contains(session.tool) {
            MediaV2SelectionInspector(session: session)
        } else if session.tool == "video.nest" {
            MediaV2CompoundInspector(session:session)
        } else if session.tool == "image.crop" {
            if let layer = session.selectedLayer, layer.contentKind == .raster { MediaV2CropInspector(session: session, layer: layer).id(layer.id) }
            else { Text(WorkbenchText.t("请选择图片图层。", "Select an image layer.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.tool == "image.text", let layer = session.selectedLayer, layer.contentKind == .text {
            MediaV2TextInspector(session: session, layer: layer).id(layer.id)
        } else if session.tool == "image.align" {
            Button(WorkbenchText.t("水平居中", "Center horizontally")) { property = "centerX"; run("image.align") }.frame(minHeight: 44)
            Button(WorkbenchText.t("垂直居中", "Center vertically")) { property = "centerY"; run("image.align") }.frame(minHeight: 44)
        } else if session.tool == "image.blend-mode" {
            Text(WorkbenchText.t("在编组的图层属性中选择混合模式。", "Choose a blend mode in the selected group's layer properties.")).font(.caption).foregroundStyle(.secondary)
        } else if session.tool == "image.merge-layer" {
            Text(WorkbenchText.t("多选至少两个连续的同级图层。", "Select at least two adjacent sibling layers.")).font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("合并所选图层", "Merge selected layers")) { run("image.merge-layer") }.frame(minHeight: 44).disabled(session.selectedLayerSet.count < 2)
        } else if session.project.kind == .video, ["video.graph", "video.keyframes", "video.easing", "video.video-transform", "video.pip"].contains(session.tool) {
            if let selected = session.selectedClip, selected.track.kind == .visual { MediaV2KeyframeInspector(session: session, clip: selected.clip).id(selected.clip.id) }
            else { Text(WorkbenchText.t("请选择视频或图片片段。", "Select a video or image clip.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.project.kind == .video, ["video.video-mask", "video.video-feather"].contains(session.tool) {
            if let selected = session.selectedClip, selected.track.kind == .visual { MediaV2VideoMaskInspector(session: session, clip: selected.clip).id(selected.clip.id) }
            else { Text(WorkbenchText.t("请选择视频或图片片段。", "Select a video or image clip.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.project.kind == .video, ["video.caption", "video.caption-time", "video.caption-style", "video.srt"].contains(session.tool) || session.selectedClip?.track.kind == .caption {
            MediaV2CaptionInspector(session: session, onImport: { beginImport(captions: true) })
            Divider()
            MediaV2CaptionStyleInspector(session: session)
        } else if session.project.kind == .video, ["video.mix", "video.fades", "video.audio-sync"].contains(session.tool) || session.selectedClip?.track.kind == .audio {
            MediaV2AudioInspector(session: session)
        } else if session.project.kind == .video, ["video.trim", "video.ripple", "video.roll"].contains(session.tool) {
            Text(WorkbenchText.t("拖动片段或左右边界，也可在下方输入时间。波纹操作仅影响当前轨道。", "Drag a clip or its trim handles, or enter times below. Ripple edits affect the current track.")).font(.caption).foregroundStyle(.secondary)
        } else if ["image.brush", "image.eraser", "image.pen"].contains(session.tool) {
            MusicValueSlider(title: WorkbenchText.t("大小", "Size"), value: session.brushWidth, range: 1...200, suffix: "px") { session.brushWidth = $0 }
            MusicValueSlider(title: WorkbenchText.t("硬度", "Hardness"), value: session.brushHardness, range: 0...1) { session.brushHardness = $0 }
            MusicValueSlider(title: WorkbenchText.t("不透明度", "Opacity"), value: session.brushOpacity, range: 0.01...1) { session.brushOpacity = $0 }
            if session.tool == "image.eraser" { Toggle(WorkbenchText.t("恢复擦除区域", "Restore erased area"), isOn: $session.eraserRestores).frame(minHeight: 44) }
        } else if session.tool == "video.video-feather" {
            MusicValueSlider(title: WorkbenchText.t("羽化半径", "Feather radius"), value: number, range: 0...200, suffix: "px") { number = $0; run(session.tool) }
            Text(WorkbenchText.t("半径按原画布像素计算。", "Radius uses original canvas pixels.")).font(.caption2).foregroundStyle(.secondary)
        } else if session.tool == "image.fill" {
            Text(WorkbenchText.t("使用当前颜色填充整个画布或当前选区。",
                                  "Fill the whole canvas or the active selection with the current color."))
                .font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("填充", "Fill")) { run("image.fill") }.frame(minHeight: 44)
        } else if session.tool == "image.text" || session.tool == "video.caption" {
            TextField(WorkbenchText.t("文字", "Text"), text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
            Button(WorkbenchText.t("应用文字", "Apply text")) { run(session.tool) }.frame(minHeight: 44)
        } else if session.tool != "move", !session.tool.hasPrefix("image.rectangle"), !session.tool.hasPrefix("image.ellipse"), !session.tool.contains("lasso"), !session.tool.contains("polygon") {
            if MediaV2Session.localToolIDs.contains(session.tool) {
                if ["video.keyframes", "video.video-transform", "video.easing"].contains(session.tool) {
                    Picker(WorkbenchText.t("属性", "Property"), selection: $property) { Text(WorkbenchText.t("缩放", "Scale")).tag("scale"); Text("X").tag("centerX"); Text("Y").tag("centerY"); Text(WorkbenchText.t("透明度", "Opacity")).tag("opacity"); Text(WorkbenchText.t("旋转", "Rotation")).tag("rotationDegrees") }
                }
                if !["image.fill", "image.layer-mask", "image.clip-mask", "image.group-layer", "image.duplicate-layer", "image.flip", "image.shape", "image.bw", "video.split", "video.video-mask"].contains(session.tool) {
                    TextField(WorkbenchText.t("数值", "Value"), value: $number, format: .number).textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                }
                Button(WorkbenchText.t("应用", "Apply")) { run(session.tool) }.frame(minHeight: 44)
            } else {
                Text(WorkbenchText.t("此工具的执行服务尚未接入。", "This tool's execution service is not connected yet.")).font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("在作品助手中继续", "Continue in work assistant")) { onAssistant?() }.frame(minHeight: 44).disabled(onAssistant == nil)
            }
        }
    }
    private func layerProperties(_ layer: MediaPreparedLayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaV2LayerInspector(session: session, layer: layer).id(layer.id)
            if layer.contentKind == .text, !["image.text","image.path-text","image.outline"].contains(session.tool) { Divider(); MediaV2TextInspector(session: session, layer: layer).id(layer.id) }
        }
    }
    private func clipProperties(track: MediaPreparedTrack, clip: MediaPreparedClip) -> some View {
        MediaV2ClipTimingInspector(session: session, track: track, clip: clip).id(clip.id)
    }
    private func previewControls(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
            if session.project.kind == .video {
                Button {
                    if session.player != nil { session.stopPlayback() }
                    else { if audio == nil { audio = NativeCreativeAudioSession(environment: environment) }; if let audio { session.play(authority: audio) } }
                } label: { Image(systemName: session.player == nil ? "play.fill" : "stop.fill").frame(width: 44, height: 44) }
                MusicIconButton("backward.end", WorkbenchText.t("上一帧", "Previous frame")) { session.scrub(max(0, session.playhead - 1 / (session.document.trackGraph.frameRate?.seconds ?? 30))) }
                MusicIconButton("forward.end", WorkbenchText.t("下一帧", "Next frame")) { session.scrub(session.playhead + 1 / (session.document.trackGraph.frameRate?.seconds ?? 30)) }
                Text(MusicWorkbenchFormat.time(session.playhead)).font(.caption.monospacedDigit())
            }
            if session.project.kind == .image {
                targetLayerButton(wide: wide)
            }
            Spacer()
            Button(WorkbenchText.t("适应画布", "Fit canvas")) { session.fitCanvas() }.font(.caption).frame(minHeight: 44)
                .accessibilityIdentifier("media.v2.fitCanvas")
            MusicIconButton("minus.magnifyingglass", WorkbenchText.t("缩小", "Zoom out")) { session.zoom = max(0.25, session.zoom / 1.25) }
                .accessibilityIdentifier("media.v2.zoom.out")
            if session.project.kind == .image {
                Menu {
                    ForEach([25,50,100,200,400],id:\.self) { value in
                        Button("\(value)%") { session.zoom = Double(value)/100 }
                    }
                } label: {
                    Text("\(Int((session.zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(minWidth:44,minHeight:44)
                }.accessibilityLabel(WorkbenchText.t("缩放倍率","Zoom level"))
                    .accessibilityValue("\(Int((session.zoom * 100).rounded()))%")
                    .accessibilityIdentifier("media.v2.zoom.value")
            } else { Text("\(Int(session.zoom * 100))%").font(.caption.monospacedDigit()) }
            MusicIconButton("plus.magnifyingglass", WorkbenchText.t("放大", "Zoom in")) { session.zoom = min(4, session.zoom * 1.25) }
                .accessibilityIdentifier("media.v2.zoom.in")
            }.padding(.horizontal, 8)
            if session.project.kind == .image, MediaV2Session.usesDirectStroke(session.tool) || (session.pencilEditing && MediaV2ImageToolLayout.editsCanvas(session.tool)) {
                Text(fingerDrawing ? WorkbenchText.t("单指绘画，双指移动与缩放。", "Draw with one finger; use two to pan and zoom.")
                    : WorkbenchText.t("用 Pencil 或鼠标绘画；手指移动画布，双指缩放。", "Draw with Pencil or a pointer; drag to pan and pinch to zoom."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            } else if session.project.kind == .image, MediaV2ImageToolLayout.editsCanvas(session.tool) {
                Text(WorkbenchText.t("用 Pencil 或单指编辑；双指移动与缩放。", "Edit with Pencil or one finger; use two to pan and zoom."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.background(Color(uiColor: .secondarySystemBackground))
    }
    private func targetLayerButton(wide: Bool) -> some View {
        let layer = session.selectedLayer
        let title = layer?.name ?? WorkbenchText.t("未选择图层", "No layer selected")
        return Button {
            if wide { objectsVisible = true } else { compactPanel = "objects" }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: targetLayerIcon(layer))
                Text(title).lineLimit(1)
                if layer?.isLocked == true { Image(systemName: "lock.fill").font(.caption2) }
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption).frame(minHeight: 44)
        }.buttonStyle(.plain)
            .accessibilityLabel(WorkbenchText.t("当前图层：", "Current layer: ") + title)
            .accessibilityHint(WorkbenchText.t("打开图层列表", "Open the layer list"))
            .accessibilityIdentifier("media.v2.targetLayer")
    }
    private func targetLayerIcon(_ layer: MediaPreparedLayer?) -> String {
        guard let kind = layer?.contentKind else { return "square.dashed" }
        switch kind {
        case .text: return "character.cursor.ibeam"
        case .group: return "folder"
        case .strokes: return "paintbrush"
        case .vectorPaths: return "square.on.circle"
        case .raster: return "photo"
        default: return "square.dashed"
        }
    }
    private var status: some View {
        HStack(spacing: 6) {
            if let error = session.diagnostic {
                Button { showingDiagnostic = true } label: {
                    Label(error, systemImage: "exclamationmark.triangle").lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.orange)
                }.buttonStyle(.plain).accessibilityHint(WorkbenchText.t("打开操作详情", "Open action details"))
                Button(WorkbenchText.t("详情", "Details")) { showingDiagnostic = true }
            } else if session.saving {
                Label(WorkbenchText.t("正在保存…", "Saving…"), systemImage: "arrow.triangle.2.circlepath")
            } else if let feedback = session.sourceSaveFeedback {
                Label(feedback, systemImage: "checkmark.circle")
            } else if let file = session.exportedFile {
                ShareLink(item: file) { Label(WorkbenchText.t("分享导出文件", "Share exported file"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
            } else { Text(session.project.kind == .image ? WorkbenchText.t("工程自动保存", "Project saves automatically") : WorkbenchText.t("多轨工程", "Multi-track project")) }
            Spacer()
            if session.rendering { ProgressView(value: session.exportProgress).frame(width: 70); Button(WorkbenchText.t("取消", "Cancel")) { session.cancelExport() } }
            else if session.processingTool { ProgressView(); Button(WorkbenchText.t("取消", "Cancel")) { session.cancelToolProcessing() } }
            Text("\(session.document.canvas?.width ?? 0) × \(session.document.canvas?.height ?? 0)").monospacedDigit().lineLimit(1)
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(minHeight: session.diagnostic == nil ? 28 : 44)
            .accessibilityIdentifier("media.v2.status")
    }
    private func run(_ tool: String) {
        var input = MediaV2ToolInput(); input.text = ["image.text", "video.caption"].contains(tool) && !text.isEmpty ? text : nil
        if tool != "video.caption" {
            input.number = tool == "image.text" && session.tool != tool ? 72 : number
            input.color = session.colorHex; input.property = property
        }
        input.expectedRevision = session.document.revision
        if session.project.kind == .image { input.objectIDs = Array(session.selectedLayerSet) }
        Task { do { _ = try await session.performTool(tool, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private var importContentTypes: [UTType] {
        if importingCaptions { return [.plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText] }
        return session.project.kind == .image ? [.image, UTType(filenameExtension: "psd") ?? .image, UTType(filenameExtension: "ora") ?? UTType(importedAs: "org.openraster.image")] : [.image, .movie, .audio]
    }
    private func beginImport(captions: Bool = false) { importingCaptions = captions; importing = true }
    private func objectAction(_ id: String, layer: MediaPreparedLayer, flag: Bool? = nil) {
        var input = MediaV2ToolInput(); input.objectID = layer.id; input.flag = flag
        input.expectedRevision = session.document.revision; input.objectIDs = Array(session.selectedLayerSet)
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func exchange(_ format: MediaV2ExchangeFormat) {
        Task { do { _ = try await session.exportInterchange(format) } catch { session.diagnostic = error.localizedDescription } }
    }
}

extension MediaV2Session {
    /// The Add menu creates a new object even while another text layer is
    /// selected. Inspector edits still use the existing image.text command.
    @discardableResult
    func createImageTextLayer() async throws -> UUID {
        guard project.kind == .image, !processingTool, !canvasLayoutInProgress, imageWarpDraft == nil else {
            throw MediaV2CommandError.invalidInput
        }
        let content = ImageTextContent(text: WorkbenchText.t("文字", "Text"), fontSize: 72, colorHex: colorHex)
        let layer = MediaPreparedLayer(name: content.text, content: .text(content))
        _ = try await apply([.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))], expectedRevision: document.revision)
        selectedLayerID = layer.id
        selectedLayerIDs = [layer.id]
        multipleLayerSelection = false
        return layer.id
    }
}

struct MediaV2ImageToolEntry: Identifiable, Hashable, Sendable {
    let id: String
    let icon: String
    let chinese: String
    let english: String
    let shortEnglish: String?
    init(_ id: String, _ icon: String, _ chinese: String, _ english: String, short: String? = nil) {
        self.id = id; self.icon = icon; self.chinese = chinese; self.english = english; shortEnglish = short
    }
    @MainActor var title: String { WorkbenchText.t(chinese, english) }
    @MainActor var shortTitle: String { WorkbenchText.t(chinese, shortEnglish ?? english) }
}

struct MediaV2ImageToolGroup: Identifiable, Sendable {
    let id: String
    let entries: [MediaV2ImageToolEntry]
    init(_ entries: [MediaV2ImageToolEntry]) { self.entries = entries; id = entries[0].id }
}

struct MediaV2ImageToolSection: Identifiable, Sendable {
    let id: String
    let icon: String
    let chinese: String
    let english: String
    let entries: [MediaV2ImageToolEntry]
    @MainActor var title: String { WorkbenchText.t(chinese, english) }
}

@MainActor enum MediaV2ImageToolLayout {
    static let selectionTools: Set<String> = ["image.rectangle", "image.ellipse", "image.lasso", "image.polygon", "image.wand"]
    static let selectionActions: Set<String> = ["image.feather", "image.inverse", "image.deselect", "image.subject"]
    /// Tools whose primary canvas action is a single tap, never a drag.
    static let tapTools: Set<String> = ["image.wand", "image.polygon", "image.eyedropper"]
    /// A tap may wobble by this many canvas points and still count as a tap.
    static let tapSlop: CGFloat = 12
    static let paintTools: Set<String> = ["image.brush", "image.eraser", "image.gradient", "image.fill", "image.eyedropper"]
    static let retouchTools: Set<String> = ["image.clone", "image.heal", "image.patch", "image.remove", "image.content-fill", "image.blur-brush", "image.sharpen-brush", "image.smudge", "image.feather-brush"]
    static let columnsKey = MediaImageCanvasControls.columnsKey
    static let smudgeGroup = MediaV2ImageToolGroup([
        .init("image.smudge","hand.draw","涂抹","Smudge"), .init("image.feather-brush","wind","羽化","Feather Brush",short:"Feather")
    ])
    static let adjustTools: Set<String> = ["image.curves", "image.exposure", "image.levels", "image.hsl", "image.white-balance", "image.bw"]
    static let createTools: Set<String> = ["image.text", "image.pen", "image.shape"]
    static let canvasTools: Set<String> = ["move", "image.crop", "image.resize", "image.canvas-size", "image.perspective", "image.distort", "view.pan", "view.zoom-in", "view.zoom-out", "view.fit"]
    static let clusters: [[MediaV2ImageToolGroup]] = [
        [
            .init([.init("move", "cursorarrow", "移动", "Move")]),
            .init([.init("image.rectangle", "rectangle.dashed", "矩形选区", "Rectangular marquee", short: "Marquee"), .init("image.ellipse", "circle.dashed", "椭圆选区", "Elliptical marquee", short: "Ellipse")]),
            .init([.init("image.lasso", "lasso", "套索", "Lasso"), .init("image.polygon", "point.3.connected.trianglepath.dotted", "多边形", "Polygonal lasso", short: "Polygon")]),
            .init([.init("image.wand", "wand.and.rays", "魔棒", "Magic wand", short: "Wand")]),
            .init([.init("image.crop", "crop", "裁剪", "Crop"), .init("image.resize", "arrow.up.left.and.arrow.down.right", "图像尺寸", "Image size", short: "Size"), .init("image.canvas-size", "rectangle.expand.vertical", "画布尺寸", "Canvas size", short: "Canvas")]),
            .init([.init("image.perspective", "perspective", "透视", "Perspective"), .init("image.distort", "move.3d", "变形", "Distort")]),
            .init([.init("image.eyedropper", "eyedropper", "吸管", "Eyedropper")])
        ], [
            .init([.init("image.brush", "paintbrush.pointed", "画笔", "Brush")]),
            .init([.init("image.eraser", "eraser", "橡皮", "Eraser")]),
            .init([.init("image.fill", "drop.fill", "填色", "Fill")]),
            .init([.init("image.gradient", "rectangle.lefthalf.filled", "渐变", "Gradient")])
        ], [
            .init([.init("image.clone", "seal", "仿制", "Clone stamp", short: "Clone")]),
            .init([.init("image.heal", "bandage", "修复", "Healing brush", short: "Healing"), .init("image.patch", "bandage.fill", "修补", "Patch")]),
            .init([.init("image.remove", "wand.and.stars", "移除", "Remove object", short: "Remove"), .init("image.content-fill", "sparkles", "内容填充", "Content-aware fill", short: "Content fill")]),
            .init([.init("image.blur-brush", "drop.halffull", "模糊", "Blur brush", short: "Blur"), .init("image.sharpen-brush", "triangle", "锐化", "Sharpen brush", short: "Sharpen")]),
            smudgeGroup
        ], [
            .init([.init("image.text", "character.cursor.ibeam", "文字", "Text")]),
            .init([.init("image.pen", "point.topleft.down.to.point.bottomright.curvepath", "钢笔", "Pen")]),
            .init([.init("image.shape", "square.on.circle", "形状", "Shape")]),
            .init([.init("image.curves", "slider.horizontal.3", "曲线", "Curves"), .init("image.exposure", "plusminus.circle", "曝光", "Exposure"), .init("image.levels", "chart.bar", "色阶", "Levels"), .init("image.hsl", "paintpalette", "色相饱和", "Hue and saturation", short: "HSL"), .init("image.white-balance", "thermometer.medium", "白平衡", "White balance", short: "Balance"), .init("image.bw", "circle.lefthalf.filled", "黑白", "Black and white", short: "B&W")])
        ], [
            .init([.init("view.pan", "hand.raised", "抓手", "Hand")])
        ]
    ]
    static var groups: [MediaV2ImageToolGroup] { clusters.flatMap { $0 } }
    static var entries: [MediaV2ImageToolEntry] { groups.flatMap(\.entries) }
    static func railClusters(pencilEditing: Bool) -> [[MediaV2ImageToolGroup]] {
        clusters.map { $0.filter { !pencilEditing || $0.id != "view.pan" } }.filter { !$0.isEmpty }
    }
    static var compactSections: [MediaV2ImageToolSection] {
        [
            .init(id: "selection", icon: "lasso", chinese: "选择", english: "Select", entries: entries.filter { selectionTools.contains($0.id) }),
            .init(id: "retouch", icon: "bandage", chinese: "修图", english: "Retouch", entries: entries.filter { retouchTools.contains($0.id) }),
            .init(id: "paint", icon: "paintbrush.pointed", chinese: "绘画", english: "Paint", entries: entries.filter { paintTools.contains($0.id) }),
            .init(id: "create", icon: "textformat", chinese: "创作", english: "Create", entries: entries.filter { createTools.contains($0.id) }),
            .init(id: "adjust", icon: "slider.horizontal.3", chinese: "调色", english: "Adjust", entries: entries.filter { adjustTools.contains($0.id) }),
            .init(id: "canvas", icon: "crop", chinese: "画布", english: "Canvas", entries: entries.filter { canvasTools.contains($0.id) })
        ]
    }
    static func entry(for id: String) -> MediaV2ImageToolEntry? { entries.first { $0.id == id } }
    static func editsCanvas(_ id: String) -> Bool {
        MediaV2Session.usesDirectStroke(id) || selectionTools.contains(id) || tapTools.contains(id)
            || ["move", "image.crop"].contains(id) || MediaV2Session.imageWarpToolIDs.contains(id)
    }
    static func reservesFingerForEditing(_ id: String, fingerDrawing: Bool, pencilEditing: Bool = false) -> Bool {
        // Selecting, cropping and moving objects use one finger even when
        // finger painting is off. The hand tool always leaves one finger for pan.
        MediaImageCanvasControls.fingerEditsCanvas(editsCanvas:editsCanvas(id),stroke:MediaV2Session.usesDirectStroke(id),
            pencilEditing:pencilEditing,fingerDrawing:fingerDrawing)
    }
}

private struct MediaV2ImageToolRail: View {
    let selectedTool: String
    let pencilEditing: Bool
    @Binding var color: Color
    let onChoose: (String) -> Void
    let onSearch: () -> Void
    @AppStorage(MediaV2ImageToolLayout.columnsKey) private var columnCount = 1
    private var columns: [GridItem] { Array(repeating:GridItem(.fixed(60),spacing:4),count:MediaImageCanvasControls.columns(columnCount)) }
    var body: some View {
        let clusters = MediaV2ImageToolLayout.railClusters(pencilEditing:pencilEditing)
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(clusters.indices, id: \.self) { index in
                        if index > 0 { Divider().padding(.horizontal, 4) }
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(clusters[index]) { group in
                                MediaV2ImageToolCell(group: group, selectedTool: selectedTool, onChoose: onChoose)
                            }
                        }
                    }
                }.padding(.vertical, 6)
            }
            Divider()
            MediaV2RailLayoutMenu()
            ColorPicker(WorkbenchText.t("绘画颜色", "Paint color"), selection: $color, supportsOpacity: false)
                .labelsHidden().frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("media.v2.paintColor")
            Button(action: onSearch) {
                Label(WorkbenchText.t("全部工具", "All tools"), systemImage: "magnifyingglass")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("查找全部工具", "Find all tools"))
                .accessibilityIdentifier("media.v2.tools.search")
        }
        .frame(width: columnCount == 2 ? 132 : 68)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .trailing) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media.v2.imageToolRail")
    }
}

private struct MediaV2RailLayoutMenu: View {
    @AppStorage(MediaV2ImageToolLayout.columnsKey) private var columns = 1
    var body: some View {
        Menu {
            ForEach([1,2],id:\.self) { count in
                Button { columns = count } label: {
                    let title = count == 1 ? WorkbenchText.t("一列","One column") : WorkbenchText.t("两列","Two columns")
                    if (columns == 2 ? 2 : 1) == count { Label(title,systemImage:"checkmark") } else { Text(title) }
                }.accessibilityIdentifier("media.v2.rail.columns.\(count)")
            }
        } label: { Image(systemName:"sidebar.left").frame(minWidth:44,minHeight:44) }
        .accessibilityLabel(WorkbenchText.t("工具栏布局","Toolbar layout"))
        .accessibilityValue(columns == 2 ? "2" : "1")
        .accessibilityIdentifier("media.v2.rail.layout")
    }
}

private struct MediaV2ImageToolCell: View {
    let group: MediaV2ImageToolGroup
    let selectedTool: String
    let onChoose: (String) -> Void
    @State private var rememberedID: String?
    private var entry: MediaV2ImageToolEntry {
        group.entries.first { $0.id == selectedTool } ?? group.entries.first { $0.id == rememberedID } ?? group.entries[0]
    }
    private var selected: Bool { group.entries.contains { $0.id == selectedTool } }
    var body: some View {
        Group {
            if group.entries.count > 1 {
                Menu {
                    ForEach(group.entries) { item in
                        Button { choose(item.id) } label: {
                            Label(item.title, systemImage: item.icon)
                            if item.id == entry.id { Image(systemName: "checkmark") }
                        }.accessibilityIdentifier("media.v2.tool.\(item.id)")
                    }
                } label: { tile }
                    .menuIndicator(.hidden)
                    .accessibilityHint(WorkbenchText.t("点按可展开同组工具。", "Tap to choose a tool in this group."))
            } else { Button { choose(entry.id) } label: { tile } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier(group.id == "image.smudge" ? "media.v2.toolGroup.smudge" : "media.v2.tool.\(entry.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(entry.title)
        .onChange(of: selectedTool) { _, id in if group.entries.contains(where: { $0.id == id }) { rememberedID = id } }
    }
    private var tile: some View {
        VStack(spacing: 3) {
            Image(systemName: entry.icon).font(.title3).frame(height: 24)
            Text(entry.shortTitle).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 60).frame(minHeight: 64)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if group.entries.count > 1 { Image(systemName: "chevron.down").font(.caption2).imageScale(.small).padding(2).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
    }
    private func choose(_ id: String) { rememberedID = id; onChoose(id) }
}

private struct MediaV2CompactImageTools: View {
    let selectedTool: String
    let onSection: (MediaV2ImageToolSection) -> Void
    let onSearch: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(MediaV2ImageToolLayout.compactSections) { section in
                let selected = section.entries.contains { $0.id == selectedTool }
                Button { onSection(section) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.icon).font(.title3)
                        Text(section.title).font(.caption2).lineLimit(2)
                    }.frame(maxWidth: .infinity, minHeight: 58)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                }.buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityIdentifier("media.v2.compactTools.\(section.id)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass").frame(width: 44, height: 58)
            }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("查找全部工具", "Find all tools"))
                .accessibilityIdentifier("media.v2.tools.search")
        }.padding(.horizontal, 4).background(Color(uiColor: .secondarySystemBackground))
            .accessibilityIdentifier("media.v2.compactImageTools")
    }
}

private struct MediaV2CompactToolPicker: View {
    let section: MediaV2ImageToolSection
    let selectedTool: String
    let pencilEditing: Bool
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(section.entries.filter { $0.id != "image.feather-brush" && (!pencilEditing || $0.id != "view.pan") }) { item in
                    if item.id == "image.smudge" {
                        Menu {
                            ForEach(MediaV2ImageToolLayout.smudgeGroup.entries) { child in
                                Button { onSelect(child.id); dismiss() } label: { Label(child.title,systemImage:child.icon) }
                                    .accessibilityIdentifier("media.v2.tool.\(child.id)")
                            }
                        } label: { Label(item.title,systemImage:item.icon).frame(minHeight:44) }
                        .accessibilityIdentifier("media.v2.toolGroup.smudge")
                    } else {
                        Button { onSelect(item.id); dismiss() } label: {
                            HStack { Label(item.title,systemImage:item.icon); Spacer()
                                if selectedTool == item.id { Image(systemName:"checkmark") }
                            }.frame(minHeight:44)
                        }.accessibilityIdentifier("media.v2.pickTool.\(item.id)")
                        .accessibilityAddTraits(selectedTool == item.id ? .isSelected : [])
                    }
                }
            }
            .navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { MediaV2RailLayoutMenu() }
                ToolbarItem(placement:.confirmationAction) { Button(WorkbenchText.t("完成","Done")) { dismiss() } }
            }
        }
    }
}

private struct MediaV2ToolValuePopover: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var percent = false
    let onChange: (Double) -> Void
    @State private var showing = false
    private var scale: Double { percent ? 100 : 1 }
    var body: some View {
        Button { showing = true } label: {
            Text("\(title) \((value * scale).formatted(.number.precision(.fractionLength(0...1))))\(percent ? "%" : suffix)")
                .font(.callout).frame(minHeight: 44)
        }
        .popover(isPresented: $showing) {
            VStack(spacing: 14) {
                MusicValueSlider(title: title, value: value * scale,
                    range: (range.lowerBound * scale)...(range.upperBound * scale), suffix: percent ? "%" : suffix) { onChange($0 / scale) }
                Button(WorkbenchText.t("完成", "Done")) { showing = false }.frame(minHeight: 44)
            }.padding(18).frame(width: 280)
        }
    }
}

private struct MediaV2ToolPicker: View {
    let tools: [MediaPreparedToolDescriptor]
    let isImage: Bool
    let selectedTool: String
    let categoryTitle: (String) -> String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var navigationMatches: [MediaV2ImageToolEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaV2ImageToolLayout.entries.filter {
            ($0.id == "move" || (isImage && $0.id.hasPrefix("view.")))
                && (query.isEmpty || $0.chinese.localizedCaseInsensitiveContains(query) || $0.english.localizedCaseInsensitiveContains(query))
        }
    }

    private var matches: [MediaPreparedToolDescriptor] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tools }
        return tools.filter {
            $0.localizedTitle(languageCode: "zh").localizedCaseInsensitiveContains(query)
                || $0.localizedTitle(languageCode: "en").localizedCaseInsensitiveContains(query)
                || categoryTitle($0.category).localizedCaseInsensitiveContains(query)
        }
    }
    private var categories: [String] {
        matches.filter { !MediaV2ImageToolLayout.selectionActions.contains($0.id) }
            .reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }
    var body: some View {
        NavigationStack {
            List {
                if !navigationMatches.isEmpty {
                    Section {
                        ForEach(navigationMatches) { item in
                            Button {
                                onSelect(item.id); dismiss()
                            } label: {
                                HStack {
                                    Label(item.title, systemImage: item.icon).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedTool == item.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("media.v2.pickTool.\(item.id)")
                                .accessibilityAddTraits(selectedTool == item.id ? .isSelected : [])
                        }
                    }
                }
                ForEach(categories, id: \.self) { category in
                    Section(categoryTitle(category)) {
                        ForEach(matches.filter { $0.category == category && !MediaV2ImageToolLayout.selectionActions.contains($0.id) }) { tool in
                            Button {
                                onSelect(tool.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(tool.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en"))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if tool.id == selectedTool { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("media.v2.pickTool.\(tool.id)")
                                .accessibilityAddTraits(tool.id == selectedTool ? .isSelected : [])
                        }
                    }
                }
                let actions = matches.filter { MediaV2ImageToolLayout.selectionActions.contains($0.id) }
                if !actions.isEmpty {
                    Section(WorkbenchText.t("选区操作", "Selection actions")) {
                        ForEach(actions) { action in
                            Button(action.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en")) {
                                onSelect(action.id); dismiss()
                            }.frame(minHeight: 44).accessibilityIdentifier("media.v2.pickAction.\(action.id)")
                        }
                    }
                }
            }
            .overlay { if matches.isEmpty && navigationMatches.isEmpty { ContentUnavailableView.search(text: search) } }
            .searchable(text: $search, prompt: WorkbenchText.t("搜索裁剪、画笔、调色…", "Search crop, brush, color…"))
            .navigationTitle(WorkbenchText.t("工具与操作", "Tools and actions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
        }
    }
}

private struct MediaV2CaptionStyleInspector: View {
    @Bindable var session: MediaV2Session
    @State private var style = CaptionStyle()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("字幕样式", "Caption style")).font(.headline)
            Text(WorkbenchText.t("应用到全部字幕", "Applies to all captions")).font(.caption).foregroundStyle(.secondary)
            MediaV2NumberField(title: WorkbenchText.t("字号", "Font size"), value: $style.fontSize, suffix: "px")
            ColorPicker(WorkbenchText.t("文字颜色", "Text color"), selection: Binding(get: { displayColor(style.colorHex) }, set: { style.colorHex = hex($0) }), supportsOpacity: true).frame(minHeight: 44)
            Toggle(WorkbenchText.t("字幕背景", "Caption background"), isOn: Binding(get: { style.backgroundHex != nil }, set: { style.backgroundHex = $0 ? "#000000" : nil })).frame(minHeight: 44)
            if style.backgroundHex != nil {
                ColorPicker(WorkbenchText.t("背景颜色", "Background color"), selection: Binding(get: { displayColor(style.backgroundHex ?? "#000000") }, set: { style.backgroundHex = hex($0) }), supportsOpacity: true).frame(minHeight: 44)
            }
            MediaV2NumberField(title: WorkbenchText.t("纵向位置（0–1）", "Vertical position (0–1)"), value: $style.positionY)
            Picker(WorkbenchText.t("对齐", "Alignment"), selection: Binding(get: { style.alignment ?? .center }, set: { style.alignment = $0 })) {
                Text(WorkbenchText.t("左对齐", "Leading")).tag(CaptionAlignment.leading)
                Text(WorkbenchText.t("居中", "Center")).tag(CaptionAlignment.center)
                Text(WorkbenchText.t("右对齐", "Trailing")).tag(CaptionAlignment.trailing)
            }
            Toggle(WorkbenchText.t("保持在安全区域", "Keep in safe area"), isOn: Binding(get: { style.respectsSafeArea ?? true }, set: { style.respectsSafeArea = $0 })).frame(minHeight: 44)
            Button(WorkbenchText.t("应用字幕样式", "Apply caption style")) {
                var input = MediaV2ToolInput(); input.captionStyle = style; input.expectedRevision = session.document.revision
                Task { do { _ = try await session.performTool("video.caption-style", input: input) } catch { session.diagnostic = error.localizedDescription } }
            }.frame(minHeight: 44)
        }.disabled(session.saving)
            .onAppear { style = session.document.trackGraph.captionStyle ?? CaptionStyle() }
            .onChange(of: session.document.trackGraph.captionStyleRevision) { _, _ in style = session.document.trackGraph.captionStyle ?? CaptionStyle() }
    }
    private func displayColor(_ value: String) -> Color {
        guard let rgba = try? PreparedVideoColor(hex: value) else { return .white }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Int((a * 255).rounded()))
    }
}
#endif
