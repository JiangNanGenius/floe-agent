// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Value-only commands shared by UI and tool adapters. No executable scripts or filesystem paths.
public enum NoteEdit: Codable, Hashable, Sendable {
    case rename(String)
    case moveToNotebook(UUID?)
    case favorite(Bool)
    case tags([String])
    case insertPage(NotePage, at: Int)
    case updatePage(NotePage)
    case movePage(UUID, to: Int)
    case deletePage(UUID)
    case drawing(pageID: UUID, resourceID: UUID?)
    case upsertElement(pageID: UUID, element: NoteElement)
    case deleteElements(pageID: UUID, ids: [UUID])
    case upsertNode(MindMapNode)
    case deleteBranch(UUID)
    case upsertConnection(MindMapConnection)
    case deleteConnection(UUID)
    case replaceMindMap(nodes: [MindMapNode], connections: [MindMapConnection])
    case replaceOfficeResource(UUID)
    case mindMapLayout(direction: Int, summaries: [MindMapSummary])

    public func apply(to document: inout NoteDocument) throws {
        switch self {
        case .mindMapLayout(let direction, let summaries):
            guard document.kind == .mindMap else { throw NoteError.invalidOperation("目标不是思维导图。") }
            document.mindMapDirection = direction; document.summaries = summaries
        case .replaceOfficeResource(let resource):
            guard document.kind == .office else { throw NoteError.invalidOperation("目标不是 Office 文档。") }
            document.officeResourceID = resource
        case .replaceMindMap(let nodes, let connections):
            guard document.kind == .mindMap else { throw NoteError.invalidOperation("目标不是思维导图。") }
            document.nodes = nodes; document.connections = connections
        case .rename(let title): document.title = title
        case .moveToNotebook(let id): document.notebookID = id
        case .favorite(let value): document.isFavorite = value
        case .tags(let values): document.tags = Array(Set(values)).sorted()
        case .insertPage(let page, let index):
            guard (0...document.pages.count).contains(index) else { throw NoteError.invalidOperation("页面位置无效。") }
            document.pages.insert(page, at: index)
        case .updatePage(let page): document.pages[try pageIndex(page.id, in: document)] = page
        case .movePage(let id, let index):
            guard document.pages.indices.contains(index) else { throw NoteError.invalidOperation("页面位置无效。") }
            let page = document.pages.remove(at: try pageIndex(id, in: document))
            document.pages.insert(page, at: index)
        case .deletePage(let id): document.pages.remove(at: try pageIndex(id, in: document))
        case .drawing(let id, let resource): document.pages[try pageIndex(id, in: document)].drawingResourceID = resource
        case .upsertElement(let id, let element):
            let index = try pageIndex(id, in: document)
            if let existing = document.pages[index].elements.firstIndex(where: { $0.id == element.id }) {
                document.pages[index].elements[existing] = element
            } else { document.pages[index].elements.append(element) }
        case .deleteElements(let id, let ids):
            let index = try pageIndex(id, in: document)
            guard Set(ids).isSubset(of: Set(document.pages[index].elements.map(\.id))) else { throw NoteError.notFound }
            document.pages[index].elements.removeAll { ids.contains($0.id) }
        case .upsertNode(let node):
            if let index = document.nodes.firstIndex(where: { $0.id == node.id }) { document.nodes[index] = node }
            else { document.nodes.append(node) }
        case .deleteBranch(let id):
            guard let node = document.nodes.first(where: { $0.id == id }), node.parentID != nil else {
                throw NoteError.invalidOperation("不能删除中心主题；可以重命名或清空其分支。")
            }
            var removed: Set<UUID> = [id]
            var changed = true
            while changed {
                changed = false
                for value in document.nodes where value.parentID.map(removed.contains) == true {
                    if removed.insert(value.id).inserted { changed = true }
                }
            }
            document.nodes.removeAll { removed.contains($0.id) }
            document.connections.removeAll { removed.contains($0.from) || removed.contains($0.to) }
        case .upsertConnection(let edge):
            if let index = document.connections.firstIndex(where: { $0.id == edge.id }) { document.connections[index] = edge }
            else { document.connections.append(edge) }
        case .deleteConnection(let id):
            guard document.connections.contains(where: { $0.id == id }) else { throw NoteError.notFound }
            document.connections.removeAll { $0.id == id }
        }
    }

    private func pageIndex(_ id: UUID, in document: NoteDocument) throws -> Int {
        guard let index = document.pages.firstIndex(where: { $0.id == id }) else { throw NoteError.notFound }
        return index
    }
}

public struct NoteEditBatch: Codable, Hashable, Sendable {
    public var documentID: UUID
    public var expectedRevision: Int
    public var title: String
    public var edits: [NoteEdit]
    public var requestID: String?
    public init(documentID: UUID, expectedRevision: Int, title: String, edits: [NoteEdit], requestID: String? = nil) {
        self.documentID = documentID; self.expectedRevision = expectedRevision; self.title = title; self.edits = edits
        self.requestID = requestID
    }
}

public struct NoteHistoryState: Sendable {
    public var canUndo: Bool
    public var canRedo: Bool
}
