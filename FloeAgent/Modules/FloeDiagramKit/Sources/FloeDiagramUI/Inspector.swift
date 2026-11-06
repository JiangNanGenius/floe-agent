// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramLayout
import FloeDiagramExchange

struct DiagramInspector: View {
    let model: DiagramEditorModel
    var isPresented = false
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            if !isPresented {
                HStack {
                    Text(DL("检查器", "Inspector")).font(.headline)
                    Spacer()
                    Button { model.showInspector = false } label: { Label(DL("关闭检查器", "Close inspector"), systemImage: "xmark").labelStyle(.iconOnly) }.accessibilityIdentifier("diagram.closeInspector")
                }.buttonStyle(DiagramChromeButtonStyle()).padding(.leading, 16).padding(.trailing, 8)
            }
            Picker(DL("面板", "Panel"), selection: $tab) {
                Text(DL("内容", "Content")).tag(0); Text(DL("样式", "Style")).tag(1); Text(DL("任务", "Tasks")).tag(2)
                if model.callbacks.askAssistant != nil || model.callbacks.execute != nil { Text("Floe").tag(3) }
            }.pickerStyle(.segmented).padding(.horizontal,16).padding(.vertical,12)
            Group {
                if tab == 3 { AssistantInspector(model: model) }
                else if tab == 2 || model.mode == .board || model.mode == .gantt { TaskInspector(model: model) }
                else if let connection = model.selectedConnection { ConnectionInspector(model: model, connection: connection).id(connection.id) }
                else if case .branch(let id) = model.selectedEdge, let node = model.page.elements.first(where: { $0.id == id }) { ElementInspector(model: model, node: node, styleOnly: true).id(node.id) }
                else if let node = model.selectedElement { ElementInspector(model: model, node: node, styleOnly: tab == 1).id(node.id) }
                else if !model.selection.isEmpty { BatchInspector(model: model) }
                else { PageInspector(model: model) }
            }.formStyle(.grouped)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(isPresented ? DL("检查器", "Inspector") : model.document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ElementInspector: View {
    let model: DiagramEditorModel
    let node: DiagramElement
    let styleOnly: Bool
    @State private var base: DiagramElement
    @State private var draft: DiagramElement
    @State private var importing = false
    @State private var targetPage: UUID?
    @State private var targetElement: UUID?
    @State private var linkURL = ""
    @State private var exportedAttachment: DiagramDataFile?
    @State private var attachmentName = "Attachment"
    @State private var exporting = false
    init(model: DiagramEditorModel, node: DiagramElement, styleOnly: Bool) {
        self.model = model; self.node = node; self.styleOnly = styleOnly
        _base = State(initialValue: node); _draft = State(initialValue: node)
    }
    var body: some View {
        Form {
            if !styleOnly {
                Section(DL("主题", "Topic")) {
                    TextField(DL("标题", "Title"), text: $draft.title, axis: .vertical).accessibilityIdentifier("diagram.inspector.title")
                    Toggle(DL("展开卡片内容", "Expand card content"), isOn: $draft.contentExpanded)
                    TextField(DL("标签，用逗号分隔", "Tags, separated by commas"), text: Binding(get: { draft.tags.joined(separator: ", ") },set: { draft.tags = $0.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    Menu {
                        Button(DL("移除图标", "Remove icon")) { draft.markers = [] }
                        ForEach(["star","flag","bookmark","exclamationmark.circle","checkmark.circle"],id: \.self) { symbol in Button { draft.markers = [symbol] } label: { Label(markerTitle(symbol),systemImage: symbol) } }
                    } label: { Label(DL("主题图标", "Topic icon"),systemImage: draft.markers.first ?? "tag") }
                    Picker(DL("所属分组或泳道", "Group or swimlane"),selection: $draft.containerID) {
                        Text(DL("无", "None")).tag(Optional<UUID>.none)
                        ForEach(model.page.elements.filter { $0.kind.isContainer && $0.id != draft.id }) { Text($0.title).tag(Optional($0.id)) }
                    }
                    if draft.kind == .swimlane || draft.kind == .swimlanePool { Toggle(DL("竖向标题栏", "Vertical header"),isOn: Binding(get: { draft.metadata["orientation"] == "vertical" },set: { draft.metadata["orientation"] = $0 ? "vertical" : "horizontal" })) }
                    if draft.kind.isTopic { Picker(DL("分支布局", "Branch layout"), selection: $draft.structure) { Text(DL("跟随页面", "Use page layout")).tag(Optional<DiagramStructure>.none); ForEach(DiagramStructure.allCases.filter { $0 != .flow && $0 != .free },id: \.self) { Text($0.title).tag(Optional($0)) } } }
                }
                Section(DL("卡片内容", "Card content")) {
                    ForEach(draft.content.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 10) {
                            ContentBlockEditor(block: $draft.content[i], model: model)
                            HStack {
                                Button { if i > 0 { draft.content.swapAt(i,i-1) } } label: { Image(systemName: "arrow.up").frame(width: 44,height: 44) }.disabled(i == 0).accessibilityLabel(DL("上移内容", "Move block up"))
                                Button { if i+1 < draft.content.count { draft.content.swapAt(i,i+1) } } label: { Image(systemName: "arrow.down").frame(width: 44,height: 44) }.disabled(i+1 == draft.content.count).accessibilityLabel(DL("下移内容", "Move block down"))
                                Spacer(); Button(role: .destructive) { draft.content.remove(at: i) } label: { Image(systemName: "trash").frame(width: 44,height: 44) }.accessibilityLabel(DL("移除内容", "Remove block"))
                            }.font(.caption)
                        }
                    }
                    Menu {
                        Button(DL("富文本", "Rich text")) { draft.content.append(.richText([.init("")])) }
                        Button(DL("公式", "Formula")) { draft.content.append(.formula("E = mc^2")) }
                        Button(DL("代码", "Code")) { draft.content.append(.code(language: "swift", text: "")) }
                        Button(DL("表格", "Table")) { draft.content.append(.table(.init(rows: [[DL("项目", "Item"), DL("内容", "Details")],["",""]]))) }
                        Button(DL("备注", "Note")) { draft.content.append(.note("")) }
                        Button(DL("图片或附件…", "Image or attachment…")) { save(); importing = true }
                    } label: { Label(DL("添加内容", "Add content"), systemImage: "plus") }.accessibilityIdentifier("diagram.addContent")
                }
                Section(DL("链接与来源", "Links & sources")) {
                    ForEach(Array(draft.links.enumerated()),id: \.offset) { at, link in
                        HStack { Button(link.title.isEmpty ? link.url ?? DL("页面链接", "Page link") : link.title) { model.follow(link) }.foregroundStyle(model.document.isBroken(link,sourcePageID: model.pageID) ? Color.secondary : Color.accentColor); Spacer(); Button(role: .destructive) { draft.links.remove(at: at) } label: { Image(systemName: "minus.circle").frame(width: 44,height: 44) }.accessibilityLabel(DL("移除链接", "Remove link")) }
                    }
                    Picker(DL("目标页面", "Target page"), selection: $targetPage) { Text(DL("选择页面", "Choose page")).tag(Optional<UUID>.none); ForEach(model.document.pages) { Text($0.title).tag(Optional($0.id)) } }.onChange(of: targetPage) { _, _ in targetElement = nil }
                    if let p = targetPage.flatMap(model.document.page) {
                        Picker(DL("目标主题", "Target topic"),selection: $targetElement) { Text(DL("整页", "Entire page")).tag(Optional<UUID>.none); ForEach(p.elements.filter { !$0.kind.isContainer }.prefix(500)) { Text($0.title).tag(Optional($0.id)) } }
                        Button(DL("添加跨页链接", "Add page link")) { draft.links.append(.init(pageID: p.id, elementID: targetElement, title: targetElement.flatMap { id in p.elements.first { $0.id == id }?.title } ?? p.title)) }
                    }
                    TextField(DL("网页地址", "Web address"),text: $linkURL).keyboardType(.URL).textInputAutocapitalization(.never)
                    Button(DL("添加网页链接", "Add web link")) { draft.links.append(.init(url: linkURL, title: linkURL)); linkURL = "" }.disabled(URL(string: linkURL)?.scheme.map { !["https","http","mailto"].contains($0.lowercased()) } ?? true)
                    ForEach(draft.sources) { source in
                        Button { if let open = model.callbacks.openSource { model.launch { _ in try await open(source) } } } label: { Label(source.title.isEmpty ? DL("来源资料", "Source") : source.title,systemImage: "link") }.disabled(model.callbacks.openSource == nil)
                        if let excerpt = source.excerpt { Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                    }
                    if model.callbacks.refreshSources != nil, !draft.sources.isEmpty { Button(DL("检查资料更新", "Check source updates")) { model.prepareSourceRefresh() } }
                }
            } else {
                Section(DL("主题样式", "Topic style")) {
                    Picker(DL("形状", "Shape"), selection: $draft.kind) { ForEach(DiagramElementKind.allCases,id: \.self) { Text($0.title).tag($0) } }
                    ColorPicker(DL("填充", "Fill"),selection: colorBinding(\.fill))
                    ColorPicker(DL("边框", "Border"),selection: colorBinding(\.stroke))
                    ColorPicker(DL("文字", "Text"),selection: colorBinding(\.text))
                    Stepper(DL("字号", "Font size")+" \(Int(draft.style.fontSize))",value: $draft.style.fontSize,in: 9...48,step: 1)
                    Toggle(DL("粗体", "Bold"),isOn: $draft.style.bold)
                    Stepper(DL("线宽", "Line width")+" \(draft.style.lineWidth.formatted())",value: $draft.style.lineWidth,in: 0...8,step: 0.5)
                    Stepper(DL("圆角", "Corner radius")+" \(Int(draft.style.cornerRadius))",value: $draft.style.cornerRadius,in: 0...32,step: 2)
                }
                if draft.parentID != nil {
                    Section(DL("分支连线", "Branch connection")) {
                        Picker(DL("线型", "Routing"),selection: Binding(get: { DiagramRouteKind(rawValue: draft.metadata["branchRoute"] ?? "") ?? .curve },set: { draft.metadata["branchRoute"] = $0.rawValue })) { Text(DL("曲线", "Curve")).tag(DiagramRouteKind.curve); Text(DL("折线", "Elbow")).tag(DiagramRouteKind.orthogonal); Text(DL("直线", "Straight")).tag(DiagramRouteKind.straight) }
                        Toggle(DL("虚线", "Dashed"),isOn: Binding(get: { draft.metadata["branchDashed"] == "true" },set: { draft.metadata["branchDashed"] = String($0) }))
                        Toggle(DL("箭头", "Arrow"),isOn: Binding(get: { draft.metadata["branchArrow"] == "true" },set: { draft.metadata["branchArrow"] = String($0) }))
                    }
                }
            }
            Section {
                Menu(DL("移动分支到页面", "Move branch to page")) { Button(DL("拆分为新页面", "Split to a new page")) { model.moveSelectionToPage() }; ForEach(model.document.pages.filter { $0.id != model.pageID }) { page in Button(page.title) { model.moveSelectionToPage(page.id) } } }
                Button(DL("复制样式", "Copy style")) { model.copyStyle() }; Button(DL("粘贴样式", "Paste style")) { model.pasteStyle() }
                Button(DL("上移一层", "Bring forward")) { model.changeLayer(forward: true) }; Button(DL("下移一层", "Send backward")) { model.changeLayer(forward: false) }
                Button(DL("聚焦分支", "Focus branch")) { model.focus(node.id) }
                if node.taskID == nil { Button(DL("转为任务", "Make task")) { model.makeTask() } }
                Button(node.isLocked ? DL("解锁", "Unlock") : DL("锁定", "Lock")) { model.lockSelection(!node.isLocked) }
                if node.parentID != nil { Button(DL("脱离父级，成为自由主题", "Detach as floating topic")) { model.moveSelection([node.id], delta: .init(x: 40,y: 40),detach: true) } }
            }
        }
        .accessibilityIdentifier("diagram.elementForm")
        .safeAreaInset(edge: .bottom) {
            if draft != base { Button { save() } label: { Text(DL("应用修改", "Apply changes")).frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("diagram.applyElement").padding(16).background(.bar) }
        }
        .onChange(of: node) { _, latest in if draft == base { base = latest; draft = latest } }
        .fileImporter(isPresented: $importing,allowedContentTypes: [.content],allowsMultipleSelection: false) { result in
            do { guard let url = try result.get().first else { return }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.fileSizeKey,.contentTypeKey]); guard (info.fileSize ?? 0) <= 64*1_024*1_024 else { throw DiagramError.invalid("attachment size") }
                model.attach(try Data(contentsOf: url),fileName: url.lastPathComponent,mediaType: info.contentType?.preferredMIMEType ?? "application/octet-stream",to: node.id)
            } catch { model.report(error) }
        }
    }
    private func colorBinding(_ key: WritableKeyPath<DiagramStyle,String>) -> Binding<Color> { Binding(get: { Color(cgColor: DiagramPalette.color(draft.style[keyPath: key])) },set: { draft.style[keyPath: key] = UIColor($0).diagramHex }) }
    private func markerTitle(_ symbol: String) -> String { switch symbol { case "star": DL("星标", "Star"); case "flag": DL("旗标", "Flag"); case "bookmark": DL("书签", "Bookmark"); case "exclamationmark.circle": DL("重要", "Important"); default: DL("完成", "Complete") } }
    private func save() {
        let old = base, value = draft, p = model.pageID
        model.perform(DL("编辑主题", "Edit topic")) { doc in
            guard let current = doc.page(p)?.elements.first(where: { $0.id == value.id }) else { throw DiagramError.notFound(value.id) }
            return [.upsertElement(pageID: p,element: try DiagramFieldPatch.apply(base: old,draft: value,current: current))]
        }
        Task { await model.waitForIdle(); if model.failedBatch == nil, let latest = model.document.element(value.id) {
            if draft == value { base = latest; draft = latest }
            else if let rebased = try? DiagramFieldPatch.apply(base: value,draft: latest,current: draft) { base = latest; draft = rebased }
        } }
    }
}

private struct ConnectionInspector: View {
    let model: DiagramEditorModel
    let connection: DiagramConnection
    @State private var base: DiagramConnection
    @State private var draft: DiagramConnection
    init(model: DiagramEditorModel, connection: DiagramConnection) { self.model = model; self.connection = connection; _base = State(initialValue: connection); _draft = State(initialValue: connection) }
    var body: some View {
        Form {
            Section(DL("连线", "Connection")) {
                TextField(DL("标签", "Label"),text: $draft.label).accessibilityIdentifier("diagram.connection.label")
                Picker(DL("线型", "Routing"),selection: $draft.route) { Text(DL("曲线", "Curve")).tag(DiagramRouteKind.curve); Text(DL("折线", "Elbow")).tag(DiagramRouteKind.orthogonal); Text(DL("直线", "Straight")).tag(DiagramRouteKind.straight) }
                ColorPicker(DL("颜色", "Color"),selection: Binding(get: { Color(cgColor: DiagramPalette.color(draft.color)) },set: { draft.color = UIColor($0).diagramHex }))
                Stepper(DL("线宽", "Line width")+" \(draft.width.formatted())",value: $draft.width,in: 0.5...8,step: 0.5)
                Toggle(DL("虚线", "Dashed"),isOn: $draft.dashed); Toggle(DL("起点箭头", "Start arrow"),isOn: $draft.startArrow); Toggle(DL("终点箭头", "End arrow"),isOn: $draft.endArrow)
                anchorPicker(DL("起点连接点", "Start port"),value: $draft.sourceAnchor); anchorPicker(DL("终点连接点", "End port"),value: $draft.targetAnchor)
                Slider(value: $draft.labelPosition,in: 0...1) { Text(DL("标签位置", "Label position")) }
                Button(DL("清除手动拐点", "Clear waypoints")) { draft.waypoints = [] }.disabled(draft.waypoints.isEmpty)
            }
            Section {
                Button(DL("应用修改", "Apply changes")) {
                    let p = model.pageID, before = base, value = draft
                    model.perform(DL("编辑连线", "Edit connection")) { doc in guard let current = doc.page(p)?.connections.first(where: { $0.id == value.id }) else { return [] }; return [.upsertConnection(pageID: p,connection: try DiagramFieldPatch.apply(base: before,draft: value,current: current))] }
                    Task { await model.waitForIdle(); if model.failedBatch == nil, let current = model.selectedConnection { base = current; draft = current } }
                }.disabled(base == draft)
                Button(DL("删除连线", "Delete connection"),role: .destructive) { model.removeSelection() }
            }
        }.onChange(of: connection) { _, latest in if base == draft { base = latest; draft = latest } }
    }
    private func anchorPicker(_ title: String,value: Binding<DiagramAnchorSide>) -> some View {
        Picker(title,selection: value) { Text(DL("自动", "Automatic")).tag(DiagramAnchorSide.automatic); Text(DL("左", "Left")).tag(DiagramAnchorSide.left); Text(DL("右", "Right")).tag(DiagramAnchorSide.right); Text(DL("上", "Top")).tag(DiagramAnchorSide.top); Text(DL("下", "Bottom")).tag(DiagramAnchorSide.bottom) }
    }
}

private struct PageInspector: View {
    let model: DiagramEditorModel
    @State private var themeName = ""
    @State private var fill = Color.white
    var body: some View {
        Form {
            Section(DL("页面", "Page")) {
                Text(model.page.title).font(.headline)
                Picker(DL("布局", "Layout"),selection: Binding(get: { model.page.structure },set: { model.updatePage(structure: $0) })) { ForEach(DiagramStructure.allCases,id: \.self) { Text($0.title).tag($0) } }
                Button(DL("整理全页", "Arrange page")) { model.arrangeSelection() }
            }
            Section(DL("主题", "Theme")) {
                Button(DL("Floe · 清朗", "Floe · Clear")) { applyTheme(.init()) }
                Button(DL("纸墨", "Paper & ink")) { applyTheme(.init(name: "Ink",topicStyle: .init(fill: "surface",stroke: "edge",text: "text",cornerRadius: 4,fontSize: 15),branchColor: "edge",background: "canvas")) }
                Button(DL("松绿", "Evergreen")) { applyTheme(.init(name: "Evergreen",topicStyle: .init(fill: "E7F0EB",stroke: "A3BCB0",text: "24483B"),branchColor: "52796A")) }
                ColorPicker(DL("主题填充", "Theme fill"),selection: $fill)
                TextField(DL("自定义主题名称", "Custom theme name"),text: $themeName)
                Button(DL("保存并应用主题", "Save and apply theme")) {
                    let theme = DiagramTheme(name: themeName,topicStyle: .init(fill: UIColor(fill).diagramHex)), value = theme
                    model.perform(DL("保存主题", "Save theme")) { doc in var metadata = doc.metadata; metadata["theme."+value.id.uuidString] = try DiagramCodec.encode(value).base64EncodedString(); return [.setMetadata(metadata)] }; applyTheme(theme)
                }.disabled(themeName.isEmpty)
                ForEach(customThemes) { theme in Button(theme.name) { applyTheme(theme) } }
            }
            Section(DL("Apple Pencil", "Apple Pencil")) {
                Button(DL("开始手写批注", "Start ink annotation")) { model.tool = .pencil }
                Button(DL("识别图形，保留笔迹", "Recognize shapes, keep ink")) { model.promoteInk() }.disabled(model.page.ink == nil)
                Button(DL("识别并替换对应笔迹", "Recognize and replace matching ink")) { model.promoteInk(keepOriginal: false) }.disabled(model.page.ink == nil)
                Button(DL("识别笔迹文字", "Recognize ink text")) { model.recognizeInkText() }.disabled(model.page.ink == nil)
            }
            if model.callbacks.refreshSources != nil { Section { Button(DL("检查资料更新", "Check source updates")) { model.prepareSourceRefresh() } } }
        }
    }
    private var customThemes: [DiagramTheme] { model.document.metadata.filter { $0.key.hasPrefix("theme.") }.values.compactMap { Data(base64Encoded: $0).flatMap { try? DiagramCodec.decode(DiagramTheme.self,from: $0) } }.sorted { $0.name < $1.name } }
    private func applyTheme(_ theme: DiagramTheme) {
        let p = model.pageID
        model.perform(DL("应用主题", "Apply theme")) { doc in
            guard let page = doc.page(p) else { return [] }; let locked = DiagramPageIndex(page).effectivelyLockedIDs
            return [.updatePage(id: p,title: page.title,structure: page.structure,theme: theme)] + page.elements.filter { !locked.contains($0.id) }.map { old in var node = old; node.style = theme.topicStyle; return .upsertElement(pageID: p,element: node) }
        }
    }
}
private struct BatchInspector: View {
    let model: DiagramEditorModel
    @State private var fill = Color.white
    @State private var tag = ""
    var body: some View {
        Form {
            Section { Text(DL("已选择", "Selected")+" \(model.selection.count)")
                ColorPicker(DL("填充", "Fill"),selection: $fill)
                Button(DL("应用填充", "Apply fill")) { let hex = UIColor(fill).diagramHex; model.editSelection(DL("批量样式", "Batch style")) { $0.style.fill = hex } }
                TextField(DL("添加标签", "Add tag"),text: $tag)
                Button(DL("应用标签", "Apply tag")) { let value = tag; model.editSelection(DL("添加标签", "Add tag")) { if !$0.tags.contains(value) { $0.tags.append(value) } } }.disabled(tag.isEmpty)
            }
            Section {
                Button(DL("左对齐", "Align left")) { model.alignSelection() }; Button(DL("顶部对齐", "Align top")) { model.alignSelection(vertical: true) }
                Button(DL("横向均匀分布", "Distribute horizontally")) { model.alignSelection(distribute: true) }; Button(DL("纵向均匀分布", "Distribute vertically")) { model.alignSelection(vertical: true,distribute: true) }
                Button(DL("整理选区", "Arrange selection")) { model.arrangeSelection() }; Button(DL("转为任务", "Make tasks")) { model.makeTask() }
            }
        }
    }
}
private struct TaskInspector: View {
    let model: DiagramEditorModel
    var body: some View {
        if let task = model.selectedTask { TaskDraftInspector(model: model,task: task).id(task.id) }
        else {
            List {
                if model.selectedTaskIDs.count > 1 {
                    Section(DL("批量更新状态", "Update selected tasks")) {
                        ForEach(DiagramTaskStatus.allCases,id: \.self) { status in Button(status.title) { let ids = model.selectedTaskIDs; model.perform(DL("更新任务", "Update tasks")) { doc in doc.tasks.filter { ids.contains($0.id) }.map { old in var t = old; t.status = status; return .upsertTask(t) } } } }
                    }
                }
                if model.mode == .canvas || model.mode == .outline { Button(DL("将选中主题转为任务", "Make selected topics tasks")) { model.makeTask() }.disabled(model.selection.isEmpty) }
                Button(DL("添加任务", "Add task")) { model.addTask() }
                ForEach(model.document.tasks) { task in Button { model.selectedTaskID = task.id } label: { Label(task.title,systemImage: task.status.icon) } }
                if !model.document.tasks.isEmpty { Button(DL("按依赖排期", "Schedule dependencies")) { model.scheduleTasks() } }
            }
        }
    }
}
private struct TaskDraftInspector: View {
    let model: DiagramEditorModel
    let task: DiagramTask
    @State private var base: DiagramTask
    @State private var draft: DiagramTask
    @State private var predecessor: UUID?
    @State private var lag = 0
    init(model: DiagramEditorModel,task: DiagramTask) { self.model = model; self.task = task; _base = State(initialValue: task); _draft = State(initialValue: task) }
    var body: some View {
        Form {
            Section(DL("任务", "Task")) {
                TextField(DL("任务名称", "Task title"),text: $draft.title).accessibilityIdentifier("diagram.task.title")
                Picker(DL("状态", "Status"),selection: $draft.status) { ForEach(DiagramTaskStatus.allCases,id: \.self) { Text($0.title).tag($0) } }.accessibilityIdentifier("diagram.task.status")
                TextField(DL("负责人", "Assignee"),text: $draft.assignee)
                Stepper(DL("优先级", "Priority")+" \(draft.priority)",value: $draft.priority,in: 0...4)
                LabeledContent(DL("进度", "Progress"),value: draft.progress.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $draft.progress,in: 0...1,step: 0.05).disabled(draft.status == .done)
                Picker(DL("上级任务", "Parent task"),selection: $draft.parentID) { Text(DL("无", "None")).tag(Optional<UUID>.none); ForEach(model.document.tasks.filter { $0.id != task.id }) { Text($0.title).tag(Optional($0.id)) } }
                if let rollup = try? DiagramPlanning.rollups(model.document)[task.id] { LabeledContent(DL("汇总进度", "Rollup progress"),value: rollup.formatted(.percent.precision(.fractionLength(0)))) }
            }
            Section(DL("日期", "Dates")) {
                Toggle(DL("安排日期", "Schedule dates"),isOn: Binding(get: { draft.start != nil },set: { enabled in if enabled { draft.start = Date(); draft.end = Date() } else { draft.start = nil; draft.end = nil } }))
                if draft.start != nil {
                    DatePicker(DL("开始", "Start"),selection: Binding(get: { draft.start ?? Date() },set: { draft.start = $0; if let end = draft.end, end < $0 { draft.end = $0 } }),displayedComponents: .date)
                    DatePicker(DL("完成", "Finish"),selection: Binding(get: { draft.end ?? Date() },set: { draft.end = max($0,draft.start ?? $0) }),displayedComponents: .date)
                }
            }
            Section(DL("依赖", "Dependencies")) {
                ForEach(model.document.dependencies.filter { $0.successorID == task.id || $0.predecessorID == task.id }) { edge in
                    let predecessor = model.document.tasks.first { $0.id == edge.predecessorID }?.title ?? "", successor = model.document.tasks.first { $0.id == edge.successorID }?.title ?? ""
                    HStack { Text(predecessor+" → "+successor).font(.caption); Spacer(); Button(role: .destructive) { model.perform(DL("移除依赖", "Remove dependency")) { _ in [.deleteDependency(edge.id)] } } label: { Image(systemName: "minus.circle").frame(width: 44,height: 44) }.accessibilityLabel(DL("移除依赖", "Remove dependency")) }
                }
                Picker(DL("在此任务之后开始", "Start after"),selection: $predecessor) { Text(DL("选择任务", "Choose task")).tag(Optional<UUID>.none); ForEach(model.document.tasks.filter { $0.id != task.id }) { Text($0.title).tag(Optional($0.id)) } }
                Stepper(DL("间隔工作日", "Lag in working days")+" \(lag)",value: $lag,in: 0...365)
                Button(DL("添加依赖", "Add dependency")) { if let predecessor { let edge = DiagramTaskDependency(predecessorID: predecessor,successorID: task.id,lagDays: lag); model.perform(DL("添加依赖", "Add dependency")) { _ in [.upsertDependency(edge)] } } }.disabled(predecessor == nil)
                Button(DL("按依赖排期", "Schedule dependencies")) { model.scheduleTasks() }
            }
            Section {
                Button(DL("应用修改", "Apply changes")) {
                    let before = base, value = draft
                    model.perform(DL("编辑任务", "Edit task")) { doc in guard let current = doc.tasks.first(where: { $0.id == value.id }) else { return [] }; return [.upsertTask(try DiagramFieldPatch.apply(base: before,draft: value,current: current))] }
                    Task { await model.waitForIdle(); if model.failedBatch == nil, let latest = model.document.tasks.first(where: { $0.id == task.id }) { base = latest; draft = latest } }
                }.disabled(base == draft).accessibilityIdentifier("diagram.applyTask")
                Button(DL("返回任务列表", "All tasks")) { model.selectedTaskID = nil; model.selection = [] }
            }
        }.environment(\.timeZone,model.document.workCalendar.calendar.timeZone).onChange(of: task) { _, latest in if base == draft { base = latest; draft = latest } }
    }
}
private struct AssistantInspector: View {
    let model: DiagramEditorModel
    @State private var instruction = ""
    var body: some View {
        Form {
            Section { Text(model.selection.isEmpty && model.selectedTaskID == nil && model.selectedEdge == nil ? (model.mode == .board || model.mode == .gantt ? DL("整份项目计划", "Entire project plan") : DL("当前页面", "Current page")) : DL("当前选区", "Current selection")).font(.headline)
                TextEditor(text: $instruction).frame(minHeight: 120).accessibilityIdentifier("diagram.assistant.instruction")
            }
            if model.callbacks.askAssistant != nil {
                Section {
                    Button(DL("修改导图", "Edit diagram")) { model.askAssistant(instruction) }.disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                    if model.mode == .canvas || model.mode == .outline {
                        Button(DL("另做一页", "Create another page")) {
                            let oldIDs = Set(model.document.pages.map(\.id)), source = model.page, selected = model.selection, edge = model.selectedEdge, text = instruction; model.duplicatePage()
                            Task { await model.waitForIdle(); if let page = model.document.pages.first(where: { !oldIDs.contains($0.id) }) {
                                let nodes = Dictionary(uniqueKeysWithValues: zip(source.elements,page.elements).map { pair in (pair.0.id,pair.1.id) }), edges = Dictionary(uniqueKeysWithValues: zip(source.connections,page.connections).map { pair in (pair.0.id,pair.1.id) })
                                model.selectPage(page.id); model.selection = Set(selected.compactMap { nodes[$0] })
                                if case .branch(let id) = edge, let mapped = nodes[id] { model.selectedEdge = .branch(mapped) }
                                if case .connection(let id) = edge, let mapped = edges[id] { model.selectedEdge = .connection(mapped) }
                                model.askAssistant(text)
                            } }
                        }.disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                    }
                    Text(DL("修改可撤销，锁定内容会保留。", "Changes can be undone. Locked content stays protected.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.callbacks.execute != nil {
                Section(DL("交给 Floe 执行", "Run with Floe")) {
                    Button(DL("按此指令开始", "Start with this instruction")) { model.requestExecution(instruction) }.disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                    Button(DL("停止所选任务", "Stop selected tasks")) { model.requestExecution(DL("停止所选任务", "Stop selected tasks"),intent: .stop) }.disabled(model.isWorking)
                }
            }
            if model.isWorking { ProgressView() }
        }
    }
}
extension UIColor {
    @MainActor var diagramHex: String { var r: CGFloat = 0,g: CGFloat = 0,b: CGFloat = 0,a: CGFloat = 0; getRed(&r,green: &g,blue: &b,alpha: &a); return String(format: "%02X%02X%02X",Int(r*255),Int(g*255),Int(b*255)) }
}
#endif
