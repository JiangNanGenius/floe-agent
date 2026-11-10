// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramExchange

/// iPad-first editor surface. Embed inside the host's existing Notes/Files navigation.
public struct DiagramEditorView: View {
    @Bindable private var model: DiagramEditorModel
    @AppStorage(DiagramDrawingInputPolicy.preferenceKey) private var fingerDrawing = false
    @State private var sheet: EditorSheet?
    @State private var importing = false
    @State private var importFormat: DiagramFormat = .floemap
    @State private var exporting = false
    @State private var exportFile: DiagramDataFile?
    @State private var exportType: UTType = .data
    @State private var exportName = "Diagram"
    @State private var compact = false
    @State private var presentedSheetID: String?
    @State private var showOverview = false
    private let onClose: (() -> Void)?
    private let onAssistant: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(model: DiagramEditorModel, onClose: (() -> Void)? = nil, onAssistant: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.onAssistant = onAssistant
    }
    public var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 900
            NavigationSplitView(columnVisibility: columnVisibility(narrow: narrow), preferredCompactColumn: .constant(.detail)) {
                if model.mode != .outline, !model.isPresenting {
                    DiagramNavigator(model: model)
                        .navigationTitle(DL("导航", "Navigator"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(removing: .sidebarToggle)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                }
            } detail: {
                HStack(spacing: 0) {
                    workspace.safeAreaInset(edge: .bottom, spacing: 0) {
                        if model.mode == .outline, !model.isPresenting { footer.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    }
                    if model.showInspector, !narrow, !model.isPresenting {
                        Divider()
                        DiagramInspector(model: model).frame(width: 320)
                    }
                }
                    .navigationTitle(model.document.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(true)
                    .toolbar(removing: .sidebarToggle)
                    .toolbarRole(.editor)
                    .toolbar { editorToolbar(narrow: narrow || dynamicTypeSize.isAccessibilitySize) }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
            .environment(\.horizontalSizeClass, narrow ? .compact : .regular)
            .onAppear { compact = narrow }
            .onChange(of: narrow) { _, value in
                compact = value
                if value, model.showInspector, sheet == nil { sheet = .inspector }
                else if !value, sheet?.id == "inspector" { presentedSheetID = nil; sheet = nil }
            }
            .onChange(of: model.showInspector) { _, value in if value && compact { sheet = .inspector } }
        }
        .sheet(item: $sheet, onDismiss: {
            if presentedSheetID == "inspector" { model.showInspector = false }
            presentedSheetID = nil
        }) { route in sheetContent(route).onAppear { presentedSheetID = route.id } }
        .alert(item: $model.notice) { notice in Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(DL("好", "OK")))) }
        .onChange(of: model.preparedMerge?.id) { _, id in
            guard let id else { if sheet?.id == "mergeReview" { sheet = nil }; return }
            if sheet != nil { sheet = nil }
            Task { try? await Task.sleep(for: .milliseconds(350)); guard model.preparedMerge?.id == id, !model.isClosed else { return }; sheet = .mergeReview }
        }
        .onChange(of: model.exchangeIssues) { _, issues in
            guard !issues.isEmpty else { return }
            Task { try? await Task.sleep(for: .milliseconds(350)); guard !model.isClosed else { return }; sheet = .importReview(issues); model.exchangeIssues = [] }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .content], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey]); guard (attributes.fileSize ?? 0) <= 128*1_024*1_024 else { throw DiagramError.invalid(DL("文件过大", "File is too large")) }
                model.importFile(try Data(contentsOf: url), format: importFormat, title: url.deletingPathExtension().lastPathComponent)
            } catch { model.report(error) }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { model.report(error) }
        }
    }
    private func columnVisibility(narrow: Bool) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { !narrow && model.showNavigator && model.mode != .outline && !model.isPresenting ? .all : .detailOnly }, set: { value in
            if !narrow, model.mode != .outline, !model.isPresenting {
                let visible = value != .detailOnly
                if model.showNavigator != visible { model.showNavigator = visible }
            }
        })
    }
    @ToolbarContentBuilder private func editorToolbar(narrow: Bool) -> some ToolbarContent {
        if let onAssistant {
            ToolbarItem(placement: .topBarTrailing) {
                Button(DL("作品助手", "Work assistant"), systemImage: "sparkles", action: onAssistant)
                    .accessibilityIdentifier("space.editor.assistant")
            }
        }
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button(DL("完成", "Done"), action: onClose)
                    .accessibilityIdentifier("space.editor.done")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            icon("sidebar.left", DL("导航", "Navigator"), id: "diagram.navigator") {
                if compact || model.mode == .outline { sheet = .navigator } else { model.showNavigator.toggle() }
            }
        }
        ToolbarItem(placement: narrow ? .principal : .topBarLeading) {
            Menu {
                Button { sheet = .rename } label: { Label(DL("重命名", "Rename"), systemImage: "pencil") }
                Label(saveStatus, systemImage: model.failedBatch != nil ? "exclamationmark.triangle" : "checkmark.circle")
            } label: {
                HStack(spacing: 6) {
                    Text(model.document.title).font(.headline).lineLimit(1).accessibilityIdentifier("diagram.documentTitle")
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }.foregroundStyle(.primary).frame(maxWidth: narrow ? 120 : 240, alignment: .leading)
            }.accessibilityIdentifier("diagram.documentMenu")
        }
        if !narrow {
            ToolbarItem(placement: .principal) {
                Picker(DL("视图", "View"), selection: Binding(get: { model.mode }, set: { model.selectMode($0) })) {
                    ForEach(DiagramEditorMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 320).accessibilityIdentifier("diagram.mode")
            }
        }
        if !narrow {
            ToolbarItemGroup(placement: .topBarTrailing) {
                icon("arrow.uturn.backward", DL("撤销", "Undo"), id: "diagram.undo") { model.undo() }.disabled(!model.history.canUndo || model.failedBatch != nil)
                icon("arrow.uturn.forward", DL("重做", "Redo"), id: "diagram.redo") { model.undo(redo: true) }.disabled(!model.history.canRedo || model.failedBatch != nil)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if narrow {
                Menu { ForEach(DiagramEditorMode.allCases) { mode in Button { model.selectMode(mode) } label: { Label(mode.title, systemImage: mode.icon) } } } label: { Label(DL("切换视图", "Change view"), systemImage: model.mode.icon) }.accessibilityIdentifier("diagram.modeMenu")
            }
            fileMenu
            icon("slider.horizontal.3", DL("检查器", "Inspector"), id: "diagram.inspector") {
                if compact { model.showInspector = true; sheet = .inspector } else { model.showInspector.toggle() }
            }
        }
    }
    private var saveStatus: String {
        model.failedBatch != nil ? DL("修改等待保存", "Changes waiting to save") : model.isSaving ? DL("正在保存…", "Saving…") : DL("已保存在此设备", "Saved on this device")
    }
    private var fileMenu: some View {
        Menu {
            Button { sheet = .templates } label: { Label(DL("模板", "Templates"), systemImage: "square.grid.2x2") }
            Menu(DL("插入文件", "Insert file")) { ForEach([DiagramFormat.floemap,.xmind,.freemind,.opml,.markdown,.drawio,.mermaid], id: \.self) { format in Button(format.rawValue) { importFormat = format; importing = true } } }
            Menu(DL("导出", "Export")) { ForEach(DiagramFormat.allCases, id: \.self) { format in Button(format.rawValue.uppercased()) { prepareExport(format) } }; Button(DL("整份图册 PDF", "Entire atlas PDF")) { prepareExport(.pdf, allPages: true) } }
            Button { printDocument() } label: { Label(DL("打印", "Print"), systemImage: "printer") }
            Divider()
            Button { model.isPresenting = true; model.showInspector = false; model.fitRequest += 1 } label: { Label(DL("演示", "Present"), systemImage: "play.rectangle") }
            Button { model.copySelection() } label: { Label(DL("复制选区", "Copy selection"), systemImage: "doc.on.doc") }.disabled(model.selection.isEmpty)
            Button { model.pasteSelection() } label: { Label(DL("粘贴", "Paste"), systemImage: "doc.on.clipboard") }
            Button { sheet = .rename } label: { Label(DL("重命名文件", "Rename file"), systemImage: "pencil") }
            Button { model.reload() } label: { Label(DL("重新打开", "Reopen"), systemImage: "arrow.clockwise") }
            if !compact { Toggle(DL("缩略导航", "Overview map"), isOn: $showOverview).accessibilityIdentifier("diagram.overviewToggle") }

            if compact || dynamicTypeSize.isAccessibilitySize {
            Divider()
            Button { model.undo() } label: { Label(DL("撤销", "Undo"), systemImage: "arrow.uturn.backward") }.disabled(!model.history.canUndo || model.failedBatch != nil)
            Button { model.undo(redo: true) } label: { Label(DL("重做", "Redo"), systemImage: "arrow.uturn.forward") }.disabled(!model.history.canRedo || model.failedBatch != nil)
            }
        } label: { Label(DL("文件操作", "File actions"), systemImage: "ellipsis") }.accessibilityIdentifier("diagram.fileMenu")
    }
    @ViewBuilder private var workspace: some View {
        VStack(spacing: 0) {
            if model.failedBatch != nil {
                HStack {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    Text(DL("修改已保留，等待恢复保存", "Changes retained, waiting to save")).font(.subheadline)
                    Spacer()
                    Button(DL("重试", "Retry")) { model.retrySave() }
                    Button(DL("合并", "Merge")) { model.prepareConflictRecovery() }
                    Button(DL("导出副本", "Export copy")) { prepareExport(.floemap, allPages: true, draft: true) }
                }.padding(12).background(.yellow.opacity(0.12))
            }
            if model.isPresenting { presentationBar }
            if model.mode == .outline { DiagramNavigator(model: model, fullWidth: true) }
            else if let scene = model.scene {
                ZStack(alignment: .topLeading) {
                    DiagramCanvas(model: model, fingerDrawing: fingerDrawing).accessibilityIdentifier("diagram.nativeCanvas")
                    if !model.isPresenting { canvasTools.padding(8) }
                    if showOverview, !compact, !model.isPresenting {
                        DiagramMinimap(model: model, scene: scene).frame(width: 128, height: 72)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
                    }
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 8) {
                            if !model.isPresenting { footer.frame(maxWidth: 460, alignment: .leading).layoutPriority(-1) }
                            Spacer(minLength: 0)
                            zoomControls.fixedSize(horizontal: true, vertical: true)
                        }.padding(8)
                    }
                }.clipped()
            } else if (model.mode == .board || model.mode == .gantt) && model.document.tasks.isEmpty {
                ContentUnavailableView { Label(DL("为想法安排下一步", "Give ideas a next step"), systemImage: "checklist") } description: { Text(DL("将主题转为任务，或在这里添加任务。", "Turn a topic into a task, or add a task here.")) } actions: { Button(DL("添加任务", "Add task")) { model.addTask() }.buttonStyle(.borderedProminent) }
                    .overlay(alignment: .bottomLeading) { if !model.isPresenting { emptyPageDock } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) { if !model.isPresenting { emptyPageDock } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyPageDock: some View {
        footer.frame(maxWidth: 460, alignment: .leading).padding(8)
    }
    private var canvasTools: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                HStack(spacing: 2) {
                    toolButton(.select, symbol: "cursorarrow", title: DL("选择", "Select"))
                    toolButton(.pan, symbol: "hand.draw", title: DL("移动画布", "Pan canvas"))
                    toolButton(.connect, symbol: "arrow.up.right", title: DL("连接", "Connect"))
                    if model.mode == .canvas { toolButton(.pencil, symbol: "pencil.tip", title: DL("手写", "Ink")) }
                }.padding(2).glassEffect(.regular, in: .rect(cornerRadius: 14))
                if model.mode == .canvas {
                    Menu { insertMenu } label: { Label(DL("添加", "Add"), systemImage: "plus").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(DiagramChromeButtonStyle()).foregroundStyle(.primary).padding(2).glassEffect(.regular, in: .rect(cornerRadius: 14)).accessibilityIdentifier("diagram.addMenu")
                } else {
                    icon("plus", DL("添加任务", "Add task"), id: "diagram.addTask") { model.addTask() }.buttonStyle(DiagramChromeButtonStyle()).foregroundStyle(.primary).padding(2).glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                }
                if model.mode == .canvas, model.tool == .pencil {
                    Toggle(isOn: $fingerDrawing) {
                        Label(DL("手指绘图", "Draw with Finger"), systemImage: "hand.point.up.left")
                    }
                    .fixedSize().frame(minHeight: 44).padding(.horizontal, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .accessibilityIdentifier("diagram.fingerDrawing.toggle")
                }
            }
        }
    }
    private func toolButton(_ tool: DiagramEditorTool, symbol: String, title: String) -> some View {
        let selected = model.tool == tool
        return icon(symbol, title, id: "diagram.tool."+tool.rawValue) { model.tool = selected && tool != .select && tool != .pan ? .select : tool }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background { if selected { RoundedRectangle(cornerRadius: 10).fill(.tint.opacity(0.14)) } }
            .buttonStyle(DiagramChromeButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var insertMenu: some View {
        Button { model.addElement() } label: { Label(DL("子主题", "Child topic"), systemImage: "plus") }.keyboardShortcut(.tab, modifiers: [])
        Button(DL("同级主题", "Sibling topic")) { model.addSibling() }
        Button(DL("自由主题", "Floating topic")) { model.addElement(kind: .floatingTopic, child: false) }
        Divider()
        ForEach([DiagramElementKind.rectangle,.roundedRectangle,.diamond,.ellipse,.parallelogram,.text,.swimlanePool,.swimlane], id: \.self) { kind in Button(kind.title) { model.addElement(kind: kind, child: false) } }
        Divider()
        Button(DL("分组", "Group")) { model.addCollection(kind: .group) }.disabled(model.selection.isEmpty)
        Button(DL("边界", "Boundary")) { model.addCollection(kind: .boundary) }.disabled(model.selection.isEmpty)
        Button(DL("概要", "Summary")) { model.addCollection(kind: .summary) }.disabled(model.selection.isEmpty)
    }
    private var zoomControls: some View {
        Group {
        if compact || dynamicTypeSize.isAccessibilitySize {
            Menu {
                Button(DL("放大", "Zoom in"), systemImage: "plus.magnifyingglass") { model.zoomRequest = model.zoom*1.25 }
                Button(DL("缩小", "Zoom out"), systemImage: "minus.magnifyingglass") { model.zoomRequest = model.zoom/1.25 }
                Button(DL("适合画布", "Fit canvas"), systemImage: "arrow.up.left.and.arrow.down.right") { model.fitRequest += 1 }
                Button("100%") { model.zoomRequest = 1 }
            } label: {
                HStack(spacing: 6) { Text(model.zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit(); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline)
                    .padding(.horizontal, 8).frame(minHeight: 44)
            }.accessibilityLabel(DL("缩放", "Zoom")).accessibilityIdentifier("diagram.zoomMenu")
        } else { HStack(spacing: 0) {
            icon("minus", DL("缩小", "Zoom out"), id: "diagram.zoomOut") { model.zoomRequest = model.zoom/1.25 }
            Text(model.zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption).frame(minWidth: 44)
            icon("plus", DL("放大", "Zoom in"), id: "diagram.zoomIn") { model.zoomRequest = model.zoom*1.25 }
            Divider().frame(height: 20)
            icon("arrow.up.left.and.arrow.down.right", DL("适合画布", "Fit canvas"), id: "diagram.fit") { model.fitRequest += 1 }
        } }
        }.buttonStyle(DiagramChromeButtonStyle()).padding(2).glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
    private var footer: some View {
        DiagramPageBar(model: model, compact: compact) { sheet = .renamePage }
    }
    private var presentationBar: some View {
        HStack {
            Button(DL("退出演示", "End presentation")) { model.isPresenting = false; model.focus(nil) }
            Spacer(); Text(model.page.title).font(.headline); Spacer()
            Button { nextPresentation(-1) } label: { Image(systemName: "chevron.left").frame(width: 44,height: 44) }
            Button { nextPresentation(1) } label: { Image(systemName: "chevron.right").frame(width: 44,height: 44) }
        }.padding(.horizontal, 16).background(.bar)
    }
    private func nextPresentation(_ delta: Int) {
        let ids = model.page.elements.filter { $0.kind.isTopic && $0.parentID == nil }.map(\.id)
        let topics = ids.count > 1 ? ids : model.page.elements.filter { $0.parentID == ids.first }.map(\.id)
        guard !topics.isEmpty else { return }; let at = model.focusID.flatMap { topics.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        model.focus(topics[(at+delta+topics.count)%topics.count])
    }
    private func icon(_ name: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: name).labelStyle(.iconOnly).font(.body).frame(minWidth: 44, minHeight: 44) }.accessibilityIdentifier(id).help(title)
    }
    private func prepareExport(_ format: DiagramFormat, allPages: Bool = false, draft: Bool = false) {
        model.launch { model in
            let output = try await model.exportData(format: format, allPages: allPages, draft: draft)
            if output.issues.isEmpty { beginExport(output) } else { sheet = .exportReview(output) }
        }
    }
    private func beginExport(_ output: DiagramExportResult) {
        exportFile = .init(data: output.data); exportType = output.format == .floemap ? .floeDiagram : UTType(filenameExtension: output.format.fileExtension) ?? .data
        exportName = model.document.title+"."+output.format.fileExtension; sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { exporting = true }
    }
    private func printDocument() {
        model.launch { model in
            let output = try await model.exportData(format: .pdf, allPages: true)
            guard !model.isClosed, !Task.isCancelled else { return }
            sheet = .printPreview(output.data)
        }
    }
    @ViewBuilder private func sheetContent(_ route: EditorSheet) -> some View {
        if route.id == "mergeReview", let prepared = model.preparedMerge { mergeReview(prepared) }
        else {
        NavigationStack {
            Group { switch route {
            case .navigator: DiagramNavigator(model: model, fullWidth: true).navigationTitle(DL("导航", "Navigator"))
            case .inspector: DiagramInspector(model: model,isPresented: true)
            case .templates: templatePicker
            case .rename, .renamePage: DiagramRenameSheet(model: model, page: route.id == "renamePage")
            case .exportReview(let output): List { Section { ForEach(output.issues, id: \.self) { DiagramIssueRow(issue: $0) } }; Button(DL("继续导出", "Export")) { beginExport(output) } }.navigationTitle(DL("导出说明", "Export details"))
            case .importReview(let issues): List { ForEach(issues,id: \.self) { DiagramIssueRow(issue: $0) } }.navigationTitle(DL("导入说明", "Import details"))
            case .printPreview(let data): DiagramPrintPreview(data: data,title: model.document.title) { error in sheet = nil; if let error { model.report(error) } }.navigationTitle(DL("打印", "Print"))
            case .mergeReview: EmptyView()
            } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if route.id != "rename", route.id != "renamePage" {
                    ToolbarItem(placement: .confirmationAction) { Button(DL("完成", "Done")) { if route.id == "inspector" { model.showInspector = false }; sheet = nil }.accessibilityIdentifier("diagram.dismissSheet") }
                }
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
    private var templatePicker: some View {
        List {
            Section(DL("开始一张新图", "Start a new diagram")) { ForEach(DiagramStructure.allCases, id: \.self) { structure in Button(structure.title) { model.useBuiltinTemplate(structure); sheet = nil } } }
            if model.templateDirectory != nil {
                Section(DL("我的模板", "My templates")) { ForEach(model.templates()) { template in Button(template.title) { model.useTemplate(template); sheet = nil } }; Button(DL("将当前图册存为模板", "Save this atlas as a template")) { model.saveTemplate(); sheet = nil } }
            }
        }.navigationTitle(DL("模板", "Templates"))
    }
    private func mergeReview(_ prepared: DiagramPreparedMerge) -> some View {
        NavigationStack {
            List {
                Section { Text(prepared.result.conflicts.isEmpty ? DL("可合并新的资料内容，并保留已有手工修改。", "New source content can be merged while preserving manual edits.") : DL("有些内容在两边都被修改。冲突处保留当前内容，另一版本另存为可恢复副本。", "Some content changed in both versions. Keep current values at conflicts and save the other version as a recovery copy.")) }
                ForEach(Array(prepared.result.conflicts.enumerated()), id: \.offset) { _, conflict in Text(conflict.field).font(.body) }
                Button(DL("合并并保留恢复副本", "Merge and retain recovery copy")) { model.applyPreparedMerge() }.accessibilityIdentifier("diagram.mergeApply")
            }.navigationTitle(DL("更新与合并", "Update & merge"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(DL("暂不更新", "Not now")) { model.preparedMerge = nil } } }
        }
    }
}

private enum EditorSheet: Identifiable {
    case navigator, inspector, templates, rename, renamePage, mergeReview, exportReview(DiagramExportResult), importReview([DiagramExchangeIssue]), printPreview(Data)
    var id: String { switch self { case .navigator: "navigator"; case .inspector: "inspector"; case .templates: "templates"; case .rename: "rename"; case .renamePage: "renamePage"; case .mergeReview: "mergeReview"; case .exportReview: "exportReview"; case .importReview: "importReview"; case .printPreview: "printPreview" } }
}
private struct DiagramIssueRow: View {
    let issue: DiagramExchangeIssue
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            Text(summary)
            if !issue.detail.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                DisclosureGroup(DL("详细说明","Details")) {Text(issue.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            }
        }
    }
    private var summary: String {
        switch issue.code {
        case "relationships": return DL("这个大纲格式不保留关联与流程连线。","This outline format does not preserve relationship or flow connections.")
        case "shapes": return DL("图形与容器将转换为大纲条目。","Shapes and containers become outline items.")
        case "richContent": return DL("图文内容会转换为目标格式支持的文字，完整内容请保留原生文件。","Rich content is converted to text supported by this format. Keep the editable original for the complete content.")
        case "projectFields": return DL("负责人、日期、依赖等项目字段不能完整保留。","Assignees, dates and dependencies cannot be fully preserved.")
        case "syntheticRoot": return DL("多个根主题将归到一个新的中心主题下。","Multiple root topics are grouped under a new central topic.")
        case "handwriting": return DL("这个格式不保留手写笔迹，请同时保留原生文件。","This format does not preserve handwriting. Keep the editable original as well.")
        case "inkRasterized": return DL("手写笔迹将作为图像嵌入，可编辑笔迹保留在原生文件中。","Handwriting is embedded as an image. Editable strokes remain in the original.")
        case "formulaRasterized": return DL("公式将以图像嵌入 SVG，PDF 保留原生公式绘制。","Formulas are embedded as images in SVG; PDF retains native formula drawing.")
        case "rasterScaleReduced": return DL("大图的 PNG 分辨率已缩小；建议使用 PDF 或 SVG。","PNG resolution was reduced for this large diagram. Use PDF or SVG for more detail.")
        case "dependencyLag": return DL("非零的依赖间隔会转换为日期，请核对排期。","Dependency delays are converted to dates. Check the schedule.")
        case "dependencyScheduling": return DL("Mermaid 依赖可能重新计算手工日期，请保留原生排期。","Mermaid dependencies may recalculate manual dates. Keep the original schedule.")
        case "linkedLegacyDocuments": return DL("本次转换根导图，关联文件需要单独保留。","This conversion includes the root map. Keep linked files separately.")
        case "imageConverted": return DL("SVG 中的部分图片会转换为 PNG 预览，原图保留在原生文件中。","Some images become PNG previews in SVG. Original images remain in the editable file.")
        case "platformSymbols": return DL("SVG 不包含系统符号图标；PDF、PNG 和可编辑原生文件会保留。","SVG does not include system-symbol icons. PDF, PNG and the editable original preserve them.")
        default: return DL("部分内容、结构或样式需要按目标格式转换。完整内容请保留原生文件，并查看详细说明。","Some content or formatting needs conversion. Keep the editable original and view details.")
        }
    }
}
public struct DiagramDataFile: FileDocument {
    public static var readableContentTypes: [UTType] { [.data] }
    public var data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws { guard let bytes = configuration.file.regularFileContents else { throw DiagramError.invalid("file contents") }; data = bytes }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct DiagramRenameSheet: View {
    let model: DiagramEditorModel
    let page: Bool
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form { Section { TextField(DL("名称", "Name"), text: $name).focused($nameFocused).accessibilityIdentifier("diagram.renameField") } }
            .navigationTitle(page ? DL("页面名称", "Page name") : DL("文件名称", "File name"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(DL("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(DL("保存", "Save")) {
                        if page { model.updatePage(title: name) } else { let value = name; model.perform(DL("重命名", "Rename")) { _ in [.rename(value)] } }
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.onAppear { name = page ? model.page.title : model.document.title; nameFocused = true }
    }
}
@MainActor extension DiagramElementKind {
    var title: String { switch self {
    case .topic: DL("主题", "Topic"); case .floatingTopic: DL("自由主题", "Floating topic"); case .rectangle: DL("矩形", "Rectangle")
    case .roundedRectangle: DL("圆角矩形", "Rounded rectangle"); case .ellipse: DL("椭圆", "Ellipse"); case .diamond: DL("判断", "Decision")
    case .parallelogram: DL("输入 / 输出", "Input / output"); case .text: DL("文字", "Text"); case .group: DL("分组", "Group")
    case .boundary: DL("边界", "Boundary"); case .summary: DL("概要", "Summary"); case .swimlane: DL("泳道", "Swimlane"); case .swimlanePool: DL("泳池", "Pool")
    } }
}
#endif
