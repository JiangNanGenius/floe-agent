// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers
import ImageIO
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramLayout
import FloeDiagramExchange

public extension UTType {
    static var floeDiagram: UTType { UTType(exportedAs: "org.floe.diagram",conformingTo: .data) }
}

public struct DiagramTemplate: Identifiable, Sendable {
    public let id: URL
    public let title: String
}
private struct DiagramTaskClipboard: Codable {
    var tasks: [DiagramTask]
    var dependencies: [DiagramTaskDependency]
}
@MainActor public extension DiagramEditorModel {
    static var pasteboardType: String { "org.floe.diagram.selection" }
    func attach(_ data: Data, fileName: String, mediaType: String, to id: UUID) {
        let p = pageID
        launch { model in
            let asset = try await model.assets.store(data, fileName: fileName, mediaType: mediaType)
            let rasterImage = mediaType.hasPrefix("image/") && CGImageSourceCreateWithData(data as CFData,nil) != nil
            guard !model.isClosed else { return }
            model.perform(DL("添加附件", "Add attachment")) { doc in
                guard var node = doc.page(p)?.elements.first(where: { $0.id == id }) else { throw DiagramError.notFound(id) }
                node.content.append(rasterImage ? .image(assetID: asset.id, caption: fileName) : .attachment(asset.id))
                return [.upsertAsset(asset), .upsertElement(pageID: p, element: node)]
            }
        }
    }
    func exportData(format: DiagramFormat, allPages: Bool = false, draft: Bool = false) async throws -> DiagramExportResult {
        await waitForIdle()
        guard !isClosed else { throw DiagramError.closed }
        var snapshot = document
        if draft, let batch = failedBatch, let base = failedBase { snapshot = try DiagramEditEngine.applying(batch, to: base, context: .init(permitsUnlock: true)) }
        if mode == .board || mode == .gantt, [.png, .pdf, .svg].contains(format) { snapshot = try DiagramPlanProjection.document(snapshot, board: mode == .board) }
        return try await DiagramExchange.export(snapshot, format: format, pageID: allPages || mode == .board || mode == .gantt ? nil : pageID, assets: assets)
    }
    func importFile(_ data: Data, format: DiagramFormat, title: String) {
        launch { model in
            let imported = try await Task.detached { try DiagramExchange.importData(data, format: format, title: title) }.value
            let prepared = try await model.prepareImported(imported)
            guard !model.isClosed else { return }
            model.insertPages(prepared, title: DL("导入文件", "Import file"))
            if !imported.issues.isEmpty { model.exchangeIssues = imported.issues }
        }
    }
    func copySelection(cut: Bool = false) {
        let snapshot = document, p = pageID, ids = selection
        if mode == .board || mode == .gantt {
            let tasks = selectedTaskIDs
            guard !tasks.isEmpty else { return }
            let copied = snapshot.tasks.filter { tasks.contains($0.id) }.map { old in var t = old; t.floeTaskID = nil; if t.parentID.map({ !tasks.contains($0) }) == true { t.parentID = nil }; return t }
            if let data = try? DiagramCodec.encode(DiagramTaskClipboard(tasks: copied,dependencies: snapshot.dependencies.filter { tasks.contains($0.predecessorID) && tasks.contains($0.successorID) })) {
                UIPasteboard.general.setData(data,forPasteboardType: "org.floe.diagram.tasks")
                if cut { perform(DL("剪切任务", "Cut tasks")) { doc in guard doc.revision == snapshot.revision else { throw DiagramError.conflict(expected: snapshot.revision,actual: doc.revision) }; return tasks.map(DiagramEdit.deleteTask) } }
            }; return
        }
        launch { model in
            var copied = try DiagramCopy.selection(snapshot, pageID: p, ids: ids)
            let layout = try DiagramLayoutEngine.layout(snapshot.page(p)!)
            for n in copied.pages[0].elements.indices { copied.pages[0].elements[n].frame = layout.frames[copied.pages[0].elements[n].id] }
            let output = try await DiagramExchange.export(copied, format: .floemap, assets: model.assets)
            guard !model.isClosed else { return }; UIPasteboard.general.setData(output.data, forPasteboardType: Self.pasteboardType)
            if cut { model.perform(DL("剪切分支", "Cut branch")) { doc in guard doc.revision == snapshot.revision else { throw DiagramError.conflict(expected: snapshot.revision,actual: doc.revision) }; return [.deleteElements(pageID: p,ids: ids,includeDescendants: true)] } }
        }
    }
    func pasteSelection(at point: DiagramPoint? = nil) {
        if mode == .board || mode == .gantt {
            if let data = UIPasteboard.general.data(forPasteboardType: "org.floe.diagram.tasks"), data.count <= 16*1_024*1_024, let clipboard = try? DiagramCodec.decode(DiagramTaskClipboard.self,from: data), clipboard.tasks.count <= 20_000 {
                let mapping = Dictionary(clipboard.tasks.map { ($0.id,UUID()) },uniquingKeysWith: { a,_ in a })
                let tasks = clipboard.tasks.map { old in var t = old; t.id = mapping[t.id]!; t.parentID = t.parentID.flatMap { mapping[$0] }; t.floeTaskID = nil; return t }
                let dependencies = clipboard.dependencies.compactMap { old -> DiagramTaskDependency? in guard let a = mapping[old.predecessorID], let b = mapping[old.successorID] else { return nil }; return .init(predecessorID: a,successorID: b,lagDays: old.lagDays) }
                perform(DL("粘贴任务", "Paste tasks")) { _ in tasks.map(DiagramEdit.upsertTask)+dependencies.map(DiagramEdit.upsertDependency) }
            } else if let text = UIPasteboard.general.string, !text.isEmpty { let task = DiagramTask(title: String(text.prefix(20_000))); perform(DL("粘贴任务", "Paste task")) { _ in [.upsertTask(task)] } }
            else { notice = .init(title: DL("切换到画布以粘贴图形", "Switch to Canvas to paste shapes"),message: "") }
            return
        }
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType) else {
            if let string = UIPasteboard.general.string, !string.isEmpty { let id = addElement(kind: .floatingTopic, child: false, at: point); editElement(id) { $0.title = String(string.prefix(20_000)) } }
            return
        }
        let p = pageID
        launch { model in
            let result = try DiagramExchange.importData(data, format: .floemap)
            let prepared = try await model.prepareImported(result, offset: .init(x: 32, y: 32))
            let preparedPages = Set(prepared.pages.map(\.id))
            let elements = prepared.pages.flatMap(\.elements).map { old in var node = old; node.links = node.links.map { link in var l = link; if l.pageID.map(preparedPages.contains) == true { l.pageID = p }; return l }; return node }, edges = prepared.pages.flatMap(\.connections)
            model.perform(DL("粘贴", "Paste")) { _ in
                prepared.assets.map(DiagramEdit.upsertAsset) + prepared.tasks.map(DiagramEdit.upsertTask) +
                elements.map { .upsertElement(pageID: p, element: $0) } + edges.map { .upsertConnection(pageID: p, connection: $0) } + prepared.dependencies.map(DiagramEdit.upsertDependency)
            }; model.selection = Set(elements.map(\.id)); model.selectedEdge = nil
        }
    }
    func saveTemplate() {
        guard let directory = templateDirectory else { return }
        launch { model in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = try await model.exportData(format: .floemap, allPages: true)
            let name = model.document.id.uuidString+".floemap", url = directory.appendingPathComponent(name)
            try DiagramExchange.save(output, to: url)
            model.notice = .init(title: DL("模板已保存", "Template saved"), message: model.document.title)
        }
    }
    func templates() -> [DiagramTemplate] {
        guard let directory = templateDirectory, let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "floemap" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let bytes = try? Data(contentsOf: url), let imported = try? DiagramExchange.importData(bytes, format: .floemap) else { return nil }
            return DiagramTemplate(id: url, title: imported.document.title)
        }
    }
    func useTemplate(_ template: DiagramTemplate) {
        launch { model in
            let bytes = try Data(contentsOf: template.id), imported = try DiagramExchange.importData(bytes, format: .floemap)
            let prepared = try await model.prepareImported(imported); model.insertPages(prepared, title: DL("使用模板", "Use template"))
        }
    }
    func useBuiltinTemplate(_ structure: DiagramStructure) {
        let page: DiagramPage
        if structure == .flow {
            let a = DiagramElement(kind: .roundedRectangle, title: DL("开始", "Start")), b = DiagramElement(kind: .diamond, title: DL("是否满足条件？", "Condition met?")), c = DiagramElement(kind: .rectangle, title: DL("执行步骤", "Action"))
            page = .init(title: DL("流程图", "Flowchart"), structure: .flow, elements: [a,b,c], connections: [.init(from: a.id, to: b.id, kind: .flow, route: .orthogonal, endArrow: true), .init(from: b.id, to: c.id, kind: .flow, route: .orthogonal, label: DL("是", "Yes"), endArrow: true), .init(from: c.id, to: b.id, kind: .flow, route: .orthogonal, label: DL("继续检查", "Review"), endArrow: true)])
        } else {
            let root = DiagramElement(title: DL("中心主题", "Central topic"))
            page = .init(title: structure.title, structure: structure, elements: [root] + (0..<3).map { .init(title: DL("分支", "Branch")+" \($0+1)", parentID: root.id, order: $0) })
        }
        perform(DL("使用模板", "Use template")) { doc in [.insertPage(page, at: doc.pages.count)] }
        Task { await waitForIdle(); selectPage(page.id) }
    }
    private func insertPages(_ prepared: DiagramDocument, title: String) {
        perform(title) { doc in
            prepared.assets.map(DiagramEdit.upsertAsset) + prepared.tasks.map(DiagramEdit.upsertTask) + prepared.dependencies.map(DiagramEdit.upsertDependency) + prepared.pages.enumerated().map { .insertPage($0.element, at: doc.pages.count+$0.offset) }
        }
        if let p = prepared.pages.first?.id { Task { await waitForIdle(); selectPage(p) } }
    }
    private func prepareImported(_ imported: DiagramImportResult, offset: DiagramPoint = .init(x: 0, y: 0)) async throws -> DiagramDocument {
        var fresh = try DiagramCopy.fresh(imported.document, offset: offset), mapping: [UUID: UUID] = [:], descriptors: [DiagramAsset] = []
        for (old, renamed) in zip(imported.document.assets, fresh.assets) {
            guard let data = imported.assets[old.id] else { throw DiagramError.invalid("missing imported resource") }
            let stored = try await assets.store(data, fileName: old.fileName, mediaType: old.mediaType)
            mapping[renamed.id] = stored.id; descriptors.append(stored)
        }
        fresh.assets = descriptors
        for p in fresh.pages.indices { for n in fresh.pages[p].elements.indices {
            fresh.pages[p].elements[n].content = fresh.pages[p].elements[n].content.map { block in switch block {
            case .image(let id, let caption): .image(assetID: mapping[id] ?? id, caption: caption)
            case .attachment(let id): .attachment(mapping[id] ?? id)
            default: block } }
        } }
        try fresh.validate(); return fresh
    }
}

@MainActor public extension DiagramStructure {
    var title: String { switch self {
    case .balanced: DL("左右导图", "Balanced map"); case .right: DL("向右导图", "Right map"); case .left: DL("向左导图", "Left map")
    case .tree: DL("树状图", "Tree"); case .organization: DL("组织结构", "Organization"); case .fishbone: DL("鱼骨图", "Fishbone")
    case .timeline: DL("时间线", "Timeline"); case .flow: DL("流程图", "Flowchart"); case .free: DL("自由画布", "Free canvas")
    } }
}
#endif
