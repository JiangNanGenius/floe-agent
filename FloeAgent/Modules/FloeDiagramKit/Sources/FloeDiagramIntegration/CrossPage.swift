// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public enum DiagramCrossPage {
    /// Moves owned identities. Relationships crossing the page boundary become explicit bidirectional page links.
    public static func edits(_ document: DiagramDocument, ids: Set<UUID>, from sourceID: UUID, to targetID: UUID,
                             creating target: DiagramPage? = nil) throws -> [DiagramEdit] {
        guard sourceID != targetID, let sourceIndex = document.pages.firstIndex(where: { $0.id == sourceID }), !ids.isEmpty else { throw DiagramError.invalid("cross-page selection") }
        var changed = document
        if let target { guard target.id == targetID, document.page(targetID) == nil else { throw DiagramError.invalid("new page identity") }; changed.pages.append(target) }
        guard let targetIndex = changed.pages.firstIndex(where: { $0.id == targetID }) else { throw DiagramError.notFound(targetID) }
        let source = document.pages[sourceIndex], moved = DiagramPageIndex(source).descendants(of: ids)
        guard ids.isSubset(of: Set(source.elements.map(\.id))) else { throw DiagramError.invalid("cross-page selection") }
        var moving = source.elements.filter { moved.contains($0.id) }
        for n in moving.indices {
            if moving[n].parentID.map({ !moved.contains($0) }) == true { moving[n].parentID = nil }
            if moving[n].containerID.map({ !moved.contains($0) }) == true { moving[n].containerID = nil }
            moving[n].memberIDs = moving[n].memberIDs.filter(moved.contains)
        }
        let internalEdges = source.connections.filter { moved.contains($0.from) && moved.contains($0.to) }
        changed.pages[sourceIndex].elements.removeAll { moved.contains($0.id) }
        changed.pages[sourceIndex].connections.removeAll { moved.contains($0.from) || moved.contains($0.to) }
        for n in changed.pages[sourceIndex].elements.indices { changed.pages[sourceIndex].elements[n].memberIDs.removeAll { moved.contains($0) } }
        changed.pages[targetIndex].elements += moving; changed.pages[targetIndex].connections += internalEdges
        for edge in source.connections where moved.contains(edge.from) != moved.contains(edge.to) {
            let aPage = moved.contains(edge.from) ? targetIndex : sourceIndex, bPage = moved.contains(edge.to) ? targetIndex : sourceIndex
            if let a = changed.pages[aPage].elements.firstIndex(where: { $0.id == edge.from }), let b = changed.pages[bPage].elements.firstIndex(where: { $0.id == edge.to }) {
                changed.pages[aPage].elements[a].links.append(.init(pageID: changed.pages[bPage].id,elementID: edge.to,title: edge.label.isEmpty ? changed.pages[bPage].elements[b].title : edge.label))
                changed.pages[bPage].elements[b].links.append(.init(pageID: changed.pages[aPage].id,elementID: edge.from,title: edge.label.isEmpty ? changed.pages[aPage].elements[a].title : edge.label))
            }
        }
        for p in changed.pages.indices { for n in changed.pages[p].elements.indices { for l in changed.pages[p].elements[n].links.indices {
            let link = changed.pages[p].elements[n].links[l]
            if link.elementID.map(moved.contains) == true && (link.pageID == sourceID || link.pageID == nil && changed.pages[p].id == sourceID) { changed.pages[p].elements[n].links[l].pageID = targetID }
        } } }
        try changed.validate(); return try DiagramDiff.edits(from: document,to: changed)
    }
}
