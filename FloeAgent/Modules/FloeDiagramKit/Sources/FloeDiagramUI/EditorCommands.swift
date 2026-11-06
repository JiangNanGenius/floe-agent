// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import PencilKit
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramLayout
import FloeDiagramIntegration
import FloeDiagramExchange

@MainActor public extension DiagramEditorModel {
    func moveSelectionToPage(_ target: UUID? = nil) {
        let source = pageID, ids = selection, newPage = target == nil ? DiagramPage(title: selectedElement?.title ?? DL("新页面", "New page")) : nil
        guard let targetID = target ?? newPage?.id else { return }
        perform(DL("移动到页面", "Move to page")) { doc in try DiagramCrossPage.edits(doc,ids: ids,from: source,to: targetID,creating: newPage) }
        Task { await waitForIdle(); if let page = document.page(targetID), ids.isSubset(of: Set(page.elements.map(\.id))) { selectPage(targetID); selection = ids } }
    }
    func copyStyle() {
        guard let style = selectedElement?.style, let data = try? DiagramCodec.encode(style) else { return }; UIPasteboard.general.setData(data,forPasteboardType: "org.floe.diagram.style")
    }
    func pasteStyle() {
        guard let data = UIPasteboard.general.data(forPasteboardType: "org.floe.diagram.style"), let style = try? DiagramCodec.decode(DiagramStyle.self,from: data) else { return }
        editSelection(DL("应用样式", "Apply style")) { $0.style = style }
    }
    func changeLayer(forward: Bool) { editSelection(DL("调整层次", "Change layer")) { node in let layer = Int(node.metadata["layer"] ?? "0") ?? 0; node.metadata["layer"] = String(min(999_999,max(-999_999,layer))+(forward ? 1 : -1)) } }
    func editElement(_ id: UUID, title: String = "Edit", _ change: @escaping @MainActor (inout DiagramElement) -> Void) {
        let p = pageID
        perform(title) { doc in
            guard var node = doc.page(p)?.elements.first(where: { $0.id == id }) else { throw DiagramError.notFound(id) }
            change(&node); return [.upsertElement(pageID: p, element: node)]
        }
    }
    func editSelection(_ title: String, _ change: @escaping @MainActor (inout DiagramElement) -> Void) {
        let ids = selection, p = pageID
        perform(title) { doc in
            guard let page = doc.page(p) else { return [] }
            return page.elements.filter { ids.contains($0.id) }.map { old in var node = old; change(&node); return .upsertElement(pageID: p, element: node) }
        }
    }
    func editConnection(_ change: @escaping @MainActor (inout DiagramConnection) -> Void) {
        guard case .connection(let id) = selectedEdge else { return }; let p = pageID
        perform(DL("编辑连线", "Edit connection")) { doc in
            guard var edge = doc.page(p)?.connections.first(where: { $0.id == id }) else { return [] }
            change(&edge); return [.upsertConnection(pageID: p, connection: edge)]
        }
    }
    @discardableResult func addElement(kind: DiagramElementKind = .topic, child: Bool = true, at point: DiagramPoint? = nil) -> UUID {
        let id = UUID(), p = pageID, parent = child ? selectedElement?.id : nil
        let label = kind == .topic ? DL("新主题", "New topic") : DL("新图形", "New shape")
        perform(DL("添加主题", "Add topic")) { doc in
            guard let page = doc.page(p) else { return [] }
            let frame = point.map { DiagramRect(x: $0.x, y: $0.y, width: kind.isContainer ? 520 : 160, height: kind.isContainer ? 280 : 56) }
            let node = DiagramElement(id: id, kind: kind, title: label, parentID: kind.isTopic ? parent : nil,
                                      order: (page.elements.filter { $0.parentID == parent }.map(\.order).max() ?? -1)+1,
                                      frame: frame ?? (kind.isTopic ? nil : .init(x: 0, y: Double(page.elements.count%8)*90)), style: page.theme.topicStyle)
            return [.upsertElement(pageID: p, element: node)]
        }
        selection = [id]; selectedEdge = nil; return id
    }
    func addSibling() {
        let parent = selectedElement?.parentID, p = pageID, id = UUID()
        perform(DL("添加同级主题", "Add sibling")) { doc in
            guard let page = doc.page(p) else { return [] }
            return [.upsertElement(pageID: p, element: .init(id: id, title: DL("新主题", "New topic"), parentID: parent,
                                                          order: (page.elements.filter { $0.parentID == parent }.map(\.order).max() ?? -1)+1, style: page.theme.topicStyle))]
        }; selection = [id]; selectedEdge = nil
    }
    func toggleCollapse(_ id: UUID) { editElement(id, title: DL("折叠 / 展开", "Fold / unfold")) { $0.collapsed.toggle() } }
    func removeSelection() {
        if mode == .board || mode == .gantt {
            let tasks = selectedTaskIDs; perform(DL("删除任务", "Delete tasks")) { _ in tasks.map(DiagramEdit.deleteTask) }; selectedTaskID = nil; selection = []; return
        }
        let p = pageID, ids = selection
        if case .connection(let id) = selectedEdge { perform(DL("删除连线", "Delete connection")) { _ in [.deleteConnection(pageID: p, id: id)] }; selectedEdge = nil }
        else if !ids.isEmpty { perform(DL("删除分支", "Delete branch")) { _ in [.deleteElements(pageID: p, ids: ids, includeDescendants: true)] }; selection = [] }
    }
    func moveSelection(_ ids: Set<UUID>, delta: DiagramPoint, reparentTo: UUID? = nil, detach: Bool = false) {
        let p = pageID
        perform(DL("移动", "Move")) { doc in
            guard let page = doc.page(p) else { return [] }; let index = DiagramPageIndex(page)
            let moved = index.descendants(of: ids), layout = try DiagramLayoutEngine.layout(page)
            if let target = reparentTo, ids.count == 1, let id = ids.first {
                guard !moved.contains(target), !index.effectivelyLockedIDs.contains(target) else { throw DiagramError.invalid("parent") }
                var edits: [DiagramEdit] = [.reparent(pageID: p, id: id, parentID: target, order: (index.children[target]?.count ?? 0))]
                for old in page.elements where moved.contains(old.id) { var n = old; n.frame = nil; if n.id == id { n.parentID = target }; edits.append(.upsertElement(pageID: p, element: n)) }
                return edits
            }
            var edits: [DiagramEdit] = []
            for old in page.elements where moved.contains(old.id) {
                guard let frame = old.frame ?? layout.frames[old.id] else { continue }
                var node = old; node.frame = frame
                if detach && ids.contains(node.id) { node.parentID = nil; node.containerID = nil; if node.kind == .topic { node.kind = .floatingTopic } }
                edits.append(.upsertElement(pageID: p, element: node))
            }
            edits.append(.moveElements(pageID: p, ids: ids, delta: delta, includeDescendants: true)); return edits
        }
    }
    func resize(_ id: UUID, to frame: DiagramRect) { editElement(id, title: DL("调整大小", "Resize")) { $0.frame = frame } }
    func lockSelection(_ locked: Bool) {
        let p = pageID, ids = selection
        perform(locked ? DL("锁定", "Lock") : DL("解锁", "Unlock"), context: .init(permitsUnlock: !locked)) { doc in
            guard let page = doc.page(p) else { return [] }; let index = DiagramPageIndex(page), layout = try DiagramLayoutEngine.layout(page)
            let protected = index.descendants(of: ids)
            var edits: [DiagramEdit] = []
            if locked { for old in page.elements where protected.contains(old.id) && old.frame == nil {
                var node = old; node.frame = layout.frames[node.id]; edits.append(.upsertElement(pageID: p, element: node))
            } }
            edits.append(.setLocked(pageID: p, ids: ids, locked: locked)); return edits
        }
    }
    func arrangeSelection() {
        let p = pageID, ids = selection
        perform(DL("整理选区", "Arrange selection")) { doc in
            guard let page = doc.page(p) else { return [] }; return try DiagramLayoutEngine.arrangeEdits(page: page, selection: ids.isEmpty ? nil : ids)
        }
    }
    func alignSelection(vertical: Bool = false, distribute: Bool = false) {
        let p = pageID, ids = selection
        perform(distribute ? DL("均匀分布", "Distribute") : DL("对齐", "Align")) { doc in
            guard let page = doc.page(p), ids.count > 1 else { return [] }
            let layout = try DiagramLayoutEngine.layout(page)
            let nodes = page.elements.filter { ids.contains($0.id) && layout.frames[$0.id] != nil }.sorted { (vertical ? layout.frames[$0.id]!.y : layout.frames[$0.id]!.x) < (vertical ? layout.frames[$1.id]!.y : layout.frames[$1.id]!.x) }
            guard let first = nodes.first.flatMap({ layout.frames[$0.id] }), let last = nodes.last.flatMap({ layout.frames[$0.id] }) else { return [] }
            return nodes.enumerated().map { position, old in
                var node = old, f = layout.frames[old.id]!
                let start = vertical ? first.y : first.x, end = vertical ? last.y : last.x
                let value = distribute ? start+(end-start)*Double(position)/Double(max(1, nodes.count-1)) : start
                if vertical { f.y = value } else { f.x = value }; node.frame = f
                return .upsertElement(pageID: p, element: node)
            }
        }
    }
    func connect(_ from: UUID, to: UUID, source: DiagramAnchorSide = .automatic, target: DiagramAnchorSide = .automatic) {
        if mode == .board || mode == .gantt,
           let a = scene?.page.elements.first(where: { $0.id == from })?.taskID,
           let b = scene?.page.elements.first(where: { $0.id == to })?.taskID {
            perform(DL("添加任务依赖", "Add dependency")) { _ in [.upsertDependency(.init(predecessorID: a, successorID: b))] }; return
        }
        let p = pageID
        perform(DL("添加连线", "Add connection")) { doc in
            let flow = doc.page(p)?.elements.first(where: { $0.id == from })?.kind.isTopic == false
            return [.upsertConnection(pageID: p, connection: .init(from: from, to: to, kind: flow ? .flow : .association, route: flow ? .orthogonal : .curve, sourceAnchor: source, targetAnchor: target, endArrow: true))]
        }
    }
    func addWaypoint(_ point: DiagramPoint) { editConnection { $0.waypoints.append(point) } }
    func addPage(structure: DiagramStructure = .balanced) {
        let id = UUID()
        perform(DL("添加页面", "Add page")) { doc in
            [.insertPage(.init(id: id, title: DL("新页面", "New page"), structure: structure,
                               elements: [.init(title: DL("中心主题", "Central topic"))]), at: doc.pages.count)]
        }
        Task { await waitForIdle(); selectPage(id) }
    }
    func updatePage(title: String? = nil, structure: DiagramStructure? = nil, theme: DiagramTheme? = nil) {
        let p = pageID
        perform(DL("页面设置", "Page settings")) { doc in
            guard let page = doc.page(p) else { return [] }
            return [.updatePage(id: p, title: title ?? page.title, structure: structure ?? page.structure, theme: theme ?? page.theme)]
        }
    }
    func duplicatePage() { let p = pageID; perform(DL("复制页面", "Duplicate page")) { _ in [.duplicatePage(p)] } }
    func deletePage() { let p = pageID; perform(DL("删除页面", "Delete page")) { _ in [.deletePage(p)] } }
    func movePage(by delta: Int) { let p = pageID; perform(DL("调整页序", "Reorder page")) { doc in guard let at = doc.pages.firstIndex(where: { $0.id == p }), doc.pages.indices.contains(at+delta) else { return [] }; return [.movePage(p, to: at+delta)] } }
    func addCollection(kind: DiagramElementKind) {
        let p = pageID, ids = selection
        guard !ids.isEmpty else { return }
        perform(DL("添加分组", "Add group")) { doc in
            guard let page = doc.page(p) else { return [] }; let layout = try DiagramLayoutEngine.layout(page)
            let frames = ids.compactMap { layout.frames[$0] }, bounds = frames.dropFirst().reduce(frames.first ?? .init()) { $0.union($1) }.insetBy(-28)
            let group = DiagramElement(kind: kind, title: kind == .summary ? DL("概要", "Summary") : DL("分组", "Group"), frame: kind == .summary ? nil : bounds, memberIDs: Array(ids))
            var edits: [DiagramEdit] = [.upsertElement(pageID: p, element: group)]
            if kind.isContainer { edits += page.elements.filter { ids.contains($0.id) }.map { old in var n = old; n.containerID = group.id; n.frame = layout.frames[n.id]; return .upsertElement(pageID: p, element: n) } }
            return edits
        }
    }
    func replaceAll(_ replacement: String) {
        guard !query.isEmpty else { return }; let p = pageID, search = query, ids = Set(visibleElements.map(\.id))
        perform(DL("全部替换", "Replace all")) { doc in
            doc.page(p)?.elements.filter { ids.contains($0.id) }.map { old in
                var node = old; node.title = node.title.replacingOccurrences(of: search, with: replacement, options: .caseInsensitive)
                node.content = node.content.map { block in switch block {
                case .richText(let runs): .richText(runs.map { var r = $0; r.text = r.text.replacingOccurrences(of: search, with: replacement, options: .caseInsensitive); return r })
                case .note(let text): .note(text.replacingOccurrences(of: search, with: replacement, options: .caseInsensitive))
                default: block } }
                return .upsertElement(pageID: p, element: node)
            } ?? []
        }
    }
    func makeTask() {
        let p = pageID, ids = selection
        perform(DL("转为任务", "Make task")) { doc in
            var edits: [DiagramEdit] = []
            for old in doc.page(p)?.elements ?? [] where ids.contains(old.id) && old.taskID == nil {
                let task = DiagramTask(title: old.title); var node = old; node.taskID = task.id
                edits += [.upsertTask(task), .upsertElement(pageID: p, element: node)]
            }; return edits
        }
    }
    func addTask() {
        let today = document.workCalendar.calendar.startOfDay(for: Date()), task = DiagramTask(title: DL("新任务", "New task"), start: today, end: today)
        perform(DL("添加任务", "Add task")) { _ in [.upsertTask(task)] }; selectedTaskID = task.id; showInspector = true
    }
    func editTask(_ id: UUID, _ change: @escaping @MainActor (inout DiagramTask) -> Void) {
        perform(DL("编辑任务", "Edit task")) { doc in guard var task = doc.tasks.first(where: { $0.id == id }) else { return [] }; change(&task); return [.upsertTask(task)] }
    }
    func movePlanTask(_ taskID: UUID, delta: DiagramPoint, resizeEnd: Bool = false) {
        movePlanTasks([taskID],delta: delta,resizeEnd: resizeEnd)
    }
    func movePlanTasks(_ ids: Set<UUID>,delta: DiagramPoint,resizeEnd: Bool = false) {
        let board = mode == .board, unit = Double(scene?.page.metadata["dayWidth"] ?? "36") ?? 36, days = Int((delta.x/unit).rounded()), calendar = document.workCalendar.calendar
        let centers = Dictionary((scene?.page.elements ?? []).filter { $0.taskID != nil && $0.metadata["taskLabel"] != "true" }.compactMap { node -> (UUID, Double)? in guard let task = node.taskID, let frame = scene?.layout.frames[node.id] else { return nil }; return (task,frame.center.x) },uniquingKeysWith: { a,_ in a })
        perform(DL("移动任务", "Move tasks")) { doc in
            doc.tasks.filter { ids.contains($0.id) }.map { old in
                var task = old
                if board, let center = centers[task.id] {
                    task.status = DiagramTaskStatus.allCases[min(2,max(0,Int(floor((center+delta.x)/300))))]
                    if task.status == .done { task.progress = 1 } else if task.progress == 1 { task.progress = 0 }
                } else if let start = task.start, let end = task.end {
                    if resizeEnd { task.end = max(start,calendar.date(byAdding: .day,value: days,to: end) ?? end) }
                    else { task.start = calendar.date(byAdding: .day,value: days,to: start); task.end = calendar.date(byAdding: .day,value: days,to: end) }
                }
                return .upsertTask(task)
            }
        }
    }
    func scheduleTasks() {
        perform(DL("按依赖排期", "Schedule dependencies")) { doc in
            let ranges = try DiagramPlanning.schedule(doc, from: doc.tasks.compactMap(\.start).min() ?? doc.workCalendar.calendar.startOfDay(for: Date()),workCalendar: doc.workCalendar)
            return doc.tasks.compactMap { old in guard let range = ranges[old.id] else { return nil }; var task = old; task.start = range.start; task.end = range.end; return .upsertTask(task) }
        }
    }
    func askAssistant(_ instruction: String) {
        guard let callback = callbacks.askAssistant else { return }
        let p = pageID, ids = selection, edge = selectedEdge, project = mode == .board || mode == .gantt, selectedTasks = selectedTaskIDs
        launch { model in
            await model.waitForIdle()
            let taskIDs = project ? (selectedTasks.isEmpty ? Set(model.document.tasks.map(\.id)) : selectedTasks) : Set(model.document.tasks.filter { task in model.page.elements.contains { ids.contains($0.id) && $0.taskID == task.id } }.map(\.id))
            let scope = DiagramEditScope(pageID: p, elementIDs: project || edge != nil && ids.isEmpty ? [] : ids.isEmpty ? nil : ids,
                                         connectionIDs: edge.map { [$0.uuid] } ?? [], taskIDs: taskIDs,allowsNewTasks: project && selectedTasks.isEmpty)
            let request = try DiagramAssistantRequest(document: model.document, pageID: p, scope: scope, instruction: instruction)
            let batch = try await callback(request)
            guard !model.isClosed, !Task.isCancelled else { return }
            model.perform(batch.title, context: .init(scope: scope)) { doc in
                guard batch.documentID == doc.id, batch.expectedRevision == doc.revision else { throw DiagramError.conflict(expected: batch.expectedRevision, actual: doc.revision) }; return batch.edits
            }
        }
    }
    func requestExecution(_ instruction: String, intent: DiagramExecutionRequest.Intent = .start) {
        guard let callback = callbacks.execute else { return }
        let snapshot = document, ids = selection, taskIDs = selectedTaskIDs.isEmpty && selection.isEmpty ? Set(document.tasks.map(\.id)) : selectedTaskIDs
        let p = pageID, actualElements = Set(page.elements.map(\.id))
        launch { _ in try await callback(.init(document: snapshot, pageID: p, elementIDs: ids.intersection(actualElements), taskIDs: taskIDs, userInstruction: instruction, intent: intent)) }
    }
    func prepareSourceRefresh() {
        guard let callback = callbacks.refreshSources else { return }; let ids = selection, snapshot = document, p = pageID
        launch { model in
            let input = try await callback(snapshot, ids)
            guard model.document.revision == snapshot.revision else { throw DiagramError.conflict(expected: snapshot.revision, actual: model.document.revision) }
            model.preparedMerge = .init(expectedRevision: snapshot.revision, result: try DiagramMerge.threeWay(base: input.base, local: snapshot, incoming: input.incoming), context: .init(scope: .init(pageID: p, elementIDs: ids.isEmpty ? nil : ids)))
        }
    }
    func setInk(_ data: Data?) { let p = pageID; perform(DL("手写批注", "Ink annotation")) { _ in [.setInk(pageID: p, data: data)] } }
    func promoteInk(keepOriginal: Bool = true) {
        let p = pageID
        perform(DL("识别图形与箭头", "Recognize shapes and arrows")) { doc in
            guard let page = doc.page(p), let data = page.ink else { return [] }; let drawing = try PKDrawing(data: data)
            let strokes = drawing.strokes.map { stroke in DiagramInkStroke(points: stroke.path.map { let point = $0.location.applying(stroke.transform); return .init(x: point.x, y: point.y) }) }
            let recognized = DiagramInkRecognizer.recognize(strokes)
            guard !recognized.isEmpty else { throw DiagramError.invalid(DL("未识别到明确的图形或箭头，笔迹已保留", "No clear shapes or arrows found. Your ink is retained.")) }
            var nodes: [DiagramElement] = [], edges: [DiagramConnection] = [], consumed: Set<Int> = []
            let layout = try DiagramLayoutEngine.layout(page)
            for shape in recognized { switch shape {
            case .rectangle(let rect, let ids): nodes.append(.init(kind: .rectangle, title: DL("图形", "Shape"), frame: rect)); consumed.formUnion(ids)
            case .ellipse(let rect, let ids): nodes.append(.init(kind: .ellipse, title: DL("图形", "Shape"), frame: rect)); consumed.formUnion(ids)
            case .arrow: break
            } }
            func endpoint(_ point: DiagramPoint) -> UUID {
                if let node = nodes.first(where: { $0.frame?.insetBy(-24).contains(point) == true }) { return node.id }
                if let id = layout.hitElement(at: point, page: page) { return id }
                let node = DiagramElement(kind: .text, title: "", frame: .init(x: point.x, y: point.y, width: 1, height: 1), metadata: ["connectorEndpoint": "true"])
                nodes.append(node); return node.id
            }
            for shape in recognized { if case .arrow(let from, let to, let ids) = shape { edges.append(.init(from: endpoint(from), to: endpoint(to), kind: .flow, route: .straight, endArrow: true)); consumed.formUnion(ids) } }
            var edits = nodes.map { DiagramEdit.upsertElement(pageID: p, element: $0) } + edges.map { .upsertConnection(pageID: p, connection: $0) }
            if !keepOriginal { edits.append(.setInk(pageID: p, data: PKDrawing(strokes: drawing.strokes.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)).dataRepresentation())) }
            return edits
        }
    }
}
#endif
