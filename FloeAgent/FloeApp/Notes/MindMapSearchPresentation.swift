// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes

/// Search reveals ancestors in the presentation only. It must not create an
/// edit, change collapse state in the saved document, or consume undo history.
enum MindMapSearchPresentation {
    static func revealing(_ nodeID: UUID?, in document: NoteDocument) -> NoteDocument {
        guard let nodeID, document.nodes.contains(where: { $0.id == nodeID }) else { return document }
        let parents = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.parentID) })
        var current = nodeID, ancestors = Set<UUID>()
        while let entry = parents[current], let parent = entry, ancestors.insert(parent).inserted { current = parent }
        guard !ancestors.isEmpty else { return document }
        var projection = document
        for index in projection.nodes.indices where ancestors.contains(projection.nodes[index].id) {
            projection.nodes[index].isCollapsed = false
        }
        return projection
    }
}
#endif
