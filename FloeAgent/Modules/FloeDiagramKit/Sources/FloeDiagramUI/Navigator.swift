// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeDiagramCore
import FloeDiagramLayout

struct DiagramNavigator: View {
    @Bindable var model: DiagramEditorModel
    var fullWidth = false
    @State private var replacement = ""
    @State private var selecting = false
    private struct Row: Identifiable { let node: DiagramElement; let depth: Int; let hasChildren: Bool; var id: UUID { node.id } }
    private var rows: [Row] {
        let page = model.page, index = DiagramPageIndex(page)
        if !model.query.isEmpty || !model.tagFilter.isEmpty || model.taskFilter != nil {
            return model.visibleElements.map { .init(node: $0, depth: 0, hasChildren: !(index.children[$0.id] ?? []).isEmpty) }
        }
        var stack = page.elements.filter { $0.parentID == nil }.sorted { $0.order < $1.order }.reversed().map { ($0.id,0) }, result: [Row] = []
        while let (id, depth) = stack.popLast() {
            guard let node = index.elements[id] else { continue }
            let children = index.children[id] ?? []
            result.append(.init(node: node, depth: depth, hasChildren: !children.isEmpty))
            if !node.collapsed { stack += children.reversed().map { ($0, depth+1) } }
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            if fullWidth {
                HStack {
                    Menu(DL("筛选", "Filter")) {
                        Button(DL("全部状态", "All statuses")) { model.taskFilter = nil }
                        ForEach(DiagramTaskStatus.allCases, id: \.self) { status in Button(status.title) { model.taskFilter = status } }
                        Divider(); Button(DL("全部标签", "All tags")) { model.tagFilter = "" }
                        ForEach(Array(Set(model.page.elements.flatMap(\.tags))).sorted(), id: \.self) { tag in Button(tag) { model.tagFilter = tag } }
                    }
                    if !model.query.isEmpty {
                        TextField(DL("替换为", "Replace with"), text: $replacement).textFieldStyle(.roundedBorder)
                        Button(DL("全部替换", "Replace all")) { model.replaceAll(replacement) }
                    }
                    Spacer(minLength: 0)
                }.font(.subheadline).padding(.horizontal,16).padding(.vertical,8)
            }
            if model.focusID != nil { Button(DL("显示全部内容", "Show all content")) { model.focus(nil) }.padding(10) }
            if rows.isEmpty { ContentUnavailableView.search(text: model.query) }
            else {
                List {
                    ForEach(rows) { row in
                        HStack(spacing: 5) {
                            if row.hasChildren {
                                Button { model.toggleCollapse(row.id) } label: { Image(systemName: row.node.collapsed ? "chevron.right" : "chevron.down").font(.caption2.weight(.semibold)).frame(width: 44,height: 44) }.buttonStyle(.borderless).accessibilityLabel(row.node.collapsed ? DL("展开", "Expand") : DL("折叠", "Collapse"))
                            } else { Image(systemName: row.node.isLocked ? "lock" : row.node.kind.isTopic ? "circle" : "square").font(.caption2).foregroundStyle(.secondary).frame(width: 44) }
                            if selecting { Image(systemName: model.selection.contains(row.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selection.contains(row.id) ? Color.accentColor : .secondary) }
                            VStack(alignment: .leading,spacing: 3) {
                                Text(row.node.title.isEmpty ? DL("未命名", "Untitled") : row.node.title).font(.body.weight(row.node.parentID == nil ? .medium : .regular)).lineLimit(2)
                                if fullWidth, !row.node.tags.isEmpty { Text(row.node.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 4)
                            if let task = row.node.taskID.flatMap({ id in model.document.tasks.first { $0.id == id } }) { Image(systemName: task.status.icon).font(.caption).foregroundStyle(task.status == .done ? .green : .secondary).accessibilityLabel(task.status.title) }
                            if !row.node.sources.isEmpty { Image(systemName: "link").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.leading, CGFloat(min(row.depth, 7))*(fullWidth ? 20 : 12))
                        .frame(minHeight: 44).contentShape(Rectangle())
                        .onTapGesture { if selecting { model.select(row.id, extending: true) } else { model.reveal(row.id); if !fullWidth { model.centerRequest = row.id } } }
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(model.selection.contains(row.id) ? Color.accentColor.opacity(0.12) : .clear))
                        .accessibilityAddTraits(model.selection.contains(row.id) ? .isSelected : [])
                        .accessibilityIdentifier("diagram.node.\(row.id)")
                        .contextMenu {
                            Button(DL("编辑", "Edit")) { model.select(row.id); model.showInspector = true }
                            Button(DL("聚焦分支", "Focus branch")) { model.focus(row.id); model.selectMode(.canvas); model.focus(row.id) }
                            Button(DL("添加子主题", "Add child")) { model.select(row.id); model.addElement() }
                            Button(DL("复制", "Copy")) { model.select(row.id); model.copySelection() }
                        }
                        .draggable(row.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            let ids = Set(values.compactMap(UUID.init(uuidString:))).intersection(model.page.elements.map(\.id))
                            guard ids.count == 1 else { return false }; model.moveSelection(ids, delta: .init(x: 0,y: 0), reparentTo: row.id); return true
                        }
                    }
                    .onMove { offsets, target in
                        let visible = rows, p = model.pageID
                        var ordered = visible.map(\.node); ordered.move(fromOffsets: offsets, toOffset: target)
                        model.perform(DL("调整顺序", "Reorder")) { doc in
                            let before = doc.page(p)?.elements ?? []
                            return ordered.enumerated().compactMap { at, old in guard var node = before.first(where: { $0.id == old.id }) else { return nil }; node.order = at; return .upsertElement(pageID: p, element: node) }
                        }
                    }
                    if !model.page.connections.isEmpty {
                        DisclosureGroup(DL("关联与流程连线", "Relationships & flow connections")) {
                            ForEach(model.page.connections) { edge in
                                let from = model.page.elements.first { $0.id == edge.from }?.title ?? "", to = model.page.elements.first { $0.id == edge.to }?.title ?? ""
                                Button {
                                    model.selection = []; model.selectedEdge = .connection(edge.id); model.showInspector = true; model.centerRequest = edge.from
                                } label: {
                                    VStack(alignment: .leading,spacing: 4) {
                                        Text(from+" → "+to).font(.caption)
                                        if !edge.label.isEmpty { Text(edge.label).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }.accessibilityIdentifier("diagram.edge.\(edge.id)")
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 44)
            }
            if fullWidth {
                HStack { Button { model.addElement() } label: { Label(DL("添加主题", "Add topic"), systemImage: "plus") }; Spacer(); Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit() }.font(.subheadline).padding(16)
            }
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(DL("搜索主题", "Search topics")))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { selecting.toggle() } label: { Label(selecting ? DL("完成多选", "Finish selection") : DL("多选", "Multiple selection"), systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle").labelStyle(.iconOnly) }
                    .accessibilityIdentifier("diagram.multiselect")
                Menu {
                    Button(DL("全选", "Select all")) { model.selection = Set(model.visibleElements.map(\.id)) }
                    Button(DL("整理选区", "Arrange selection")) { model.arrangeSelection() }
                    Button(DL("转为任务", "Make tasks")) { model.makeTask() }
                    Button(DL("锁定选区", "Lock selection")) { model.lockSelection(true) }
                    Button(DL("解锁选区", "Unlock selection")) { model.lockSelection(false) }
                    Button(DL("删除选区", "Delete selection"), role: .destructive) { model.removeSelection() }

                } label: { Label(DL("选区操作", "Selection actions"), systemImage: "ellipsis").labelStyle(.iconOnly) }.accessibilityIdentifier("diagram.selectionMenu")
            }
        }
    }
}

struct DiagramMinimap: View {
    let model: DiagramEditorModel
    let scene: DiagramEditorScene
    var body: some View {
        Canvas { context, size in
            let box = scene.layout.bounds.insetBy(-24), scale = min(size.width/box.width,size.height/box.height)
            for (id, frame) in scene.layout.frames {
                let rect = CGRect(x: (frame.x-box.x)*scale, y: (frame.y-box.y)*scale, width: max(2,frame.width*scale),height: max(2,frame.height*scale))
                context.fill(Path(roundedRect: rect,cornerRadius: 1),with: .color(model.selection.contains(id) ? .accentColor : .secondary.opacity(0.35)))
            }
        }.padding(8).glassEffect(.regular, in: .rect(cornerRadius: 16))
            .gesture(SpatialTapGesture().onEnded { value in
                let box = scene.layout.bounds.insetBy(-24), scale = min(128/box.width,72/box.height), point = DiagramPoint(x: box.x+(value.location.x-8)/scale,y: box.y+(value.location.y-8)/scale)
                if let id = scene.layout.frames.min(by: { hypot($0.value.center.x-point.x,$0.value.center.y-point.y) < hypot($1.value.center.x-point.x,$1.value.center.y-point.y) })?.key { model.centerRequest = id }
            }).accessibilityLabel(DL("图形导航，点按跳转", "Diagram navigator, tap to jump"))
    }
}
@MainActor extension DiagramTaskStatus {
    var title: String { switch self { case .todo: DL("待办", "To do"); case .inProgress: DL("进行中", "In progress"); case .done: DL("已完成", "Done") } }
    var icon: String { switch self { case .todo: "circle"; case .inProgress: "circle.lefthalf.filled"; case .done: "checkmark.circle.fill" } }
}
#endif
