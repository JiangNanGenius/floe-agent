// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public enum DiagramCopy {
    /// Copies a selected subgraph, retaining external references as explicitly broken links.
    public static func selection(_ document: DiagramDocument, pageID: UUID, ids: Set<UUID>) throws -> DiagramDocument {
        guard var page = document.page(pageID), !ids.isEmpty else { throw DiagramError.invalid("copy selection") }
        let selected = DiagramPageIndex(page).descendants(of: ids)
        page.elements = page.elements.filter { selected.contains($0.id) }
        for i in page.elements.indices {
            if let p = page.elements[i].parentID, !selected.contains(p) { page.elements[i].parentID = nil }
            if let p = page.elements[i].containerID, !selected.contains(p) { page.elements[i].containerID = nil }
            page.elements[i].memberIDs = page.elements[i].memberIDs.filter(selected.contains)
            page.elements[i].links = page.elements[i].links.map { link in
                var link = link
                if link.pageID != nil && link.pageID != pageID || link.elementID.map({ !selected.contains($0) }) == true { link.isBroken = true }
                return link
            }
        }
        page.connections = page.connections.filter { selected.contains($0.from) && selected.contains($0.to) }; page.ink = nil
        var tasks = Set(page.elements.compactMap(\.taskID))
        // Include task ancestors so copied planning references remain valid.
        var pending = Array(tasks)
        while let id = pending.popLast(), let task = document.tasks.first(where: { $0.id == id }) {
            if let parent = task.parentID, tasks.insert(parent).inserted { pending.append(parent) }
        }
        let assets = Set(page.elements.flatMap(\.content).compactMap(\.assetID))
        let result = DiagramDocument(title: document.title, pages: [page], tasks: document.tasks.filter { tasks.contains($0.id) },
                                     dependencies: document.dependencies.filter { tasks.contains($0.predecessorID) && tasks.contains($0.successorID) },
                                     assets: document.assets.filter { assets.contains($0.id) })
        try result.validate(); return result
    }
    /// A fresh file/template copy remaps every entity identity, including resources and internal links.
    public static func fresh(_ document: DiagramDocument, offset: DiagramPoint = .init(x: 0, y: 0)) throws -> DiagramDocument {
        try document.validate()
        let all = [document.id] + document.pages.map(\.id) + document.pages.flatMap { $0.elements.map(\.id) + $0.connections.map(\.id) } + document.tasks.map(\.id) + document.dependencies.map(\.id) + document.assets.map(\.id)
        let map = Dictionary(uniqueKeysWithValues: all.map { ($0, UUID()) })
        func id(_ value: UUID) -> UUID { map[value] ?? value }
        var copy = document; copy.id = id(document.id); copy.revision = 0
        if copy.legacyPayload != nil { copy.metadata["originalSourceDocumentID"] = document.id.uuidString }
        copy.assets = copy.assets.map { var a = $0; a.id = id(a.id); return a }
        copy.tasks = copy.tasks.map { var t = $0; t.id = id(t.id); t.parentID = t.parentID.map(id); t.floeTaskID = nil; return t }
        copy.dependencies = copy.dependencies.map { var d = $0; d.id = id(d.id); d.predecessorID = id(d.predecessorID); d.successorID = id(d.successorID); return d }
        for p in copy.pages.indices {
            copy.pages[p].id = id(copy.pages[p].id)
            for n in copy.pages[p].elements.indices {
                var node = copy.pages[p].elements[n]; node.id = id(node.id); node.parentID = node.parentID.map(id); node.containerID = node.containerID.map(id)
                node.taskID = node.taskID.map(id); node.memberIDs = node.memberIDs.map(id); node.frame = node.frame?.translated(by: offset)
                node.sources = node.sources.map { var s = $0; s.id = UUID(); return s }
                node.links = node.links.map { var l = $0; l.pageID = l.pageID.map(id); l.elementID = l.elementID.map(id); return l }
                node.content = node.content.map { block in
                    switch block { case .image(let asset, let alt): .image(assetID: id(asset), caption: alt)
                    case .attachment(let asset): .attachment(id(asset))
                    default: block }
                }
                copy.pages[p].elements[n] = node
            }
            copy.pages[p].connections = copy.pages[p].connections.map { var e = $0; e.id = id(e.id); e.from = id(e.from); e.to = id(e.to); e.waypoints = e.waypoints.map { $0 + offset }; return e }
        }
        try copy.validate(); return copy
    }
}
