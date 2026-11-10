// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeNotes
@testable import FloeApp

@Suite("Mind map search presentation")
@MainActor struct NextRoundMindMapSearchTests {
    @Test func hiddenSearchResultGetsARealLayoutWithoutChangingSavedCollapseState() {
        let root = MindMapNode(title: "Root", isCollapsed: true)
        let parent = MindMapNode(parentID: root.id, title: "Parent", isCollapsed: true)
        let match = MindMapNode(parentID: parent.id, title: "Needle")
        var document = NoteDocument(kind: .mindMap, title: "Map")
        document.nodes = [root, parent, match]
        #expect(MindMapLayout.frames(document: document, sizes: [:])[match.id] == nil)
        let projection = MindMapSearchPresentation.revealing(match.id, in: document)
        let frames = MindMapLayout.frames(document: projection, sizes: [:])
        #expect(frames[match.id]?.isValid == true)
        #expect(projection.nodes[0].isCollapsed == false && projection.nodes[1].isCollapsed == false)
        #expect(document.nodes[0].isCollapsed && document.nodes[1].isCollapsed)
        #expect(projection.revision == document.revision && projection.nodes[2] == match)
        #expect(MindMapSearchPresentation.revealing(nil, in: document) == document)
        #expect(MindMapSearchPresentation.revealing(UUID(), in: document) == document)
    }
}
#endif
