// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeNotes

struct NoteWorkspaceTabsTests {
    @Test func switchingPreservesOrderAndClosingSelectsNeighbor() {
        let a = UUID(), b = UUID(), c = UUID()
        var tabs = NoteWorkspaceTabs()
        [a, b, c, a, b].forEach { tabs.open($0) }
        #expect(tabs.documentIDs == [a, b, c])
        tabs.close(b)
        #expect(tabs.selectedID == c && tabs.documentIDs == [a, c])
        tabs.close(a) // Closing an inactive tab must not navigate.
        #expect(tabs.selectedID == c)
        tabs.close(c)
        #expect(tabs.documentIDs.isEmpty && tabs.selectedID == nil)
    }

    @Test func reopeningRestoresIndependentPageToolAndViewport() throws {
        let a = UUID(), b = UUID(), page = UUID()
        var tabs = NoteWorkspaceTabs()
        tabs.open(a); tabs.open(b)
        var state = NoteWorkspaceTabs.EditorState()
        state.pageID = page; state.tool = "荧光笔"
        state.viewports[page] = .init(x: 60, y: 130, zoom: 2)
        tabs.updateEditor(state, for: a)
        tabs.close(a)
        var restored = try JSONDecoder().decode(NoteWorkspaceTabs.self, from: JSONEncoder().encode(tabs))
        restored.open(a)
        #expect(restored.editors[a] == state)
        #expect(restored.editors[b] == nil)
        #expect(restored.selectedID == a)
        #expect(restored.documentIDs == [b, a])
    }

    @Test func deletingSourcePrunesOnlyItsTabAndReadingState() {
        let a = UUID(), b = UUID()
        var tabs = NoteWorkspaceTabs()
        tabs.open(a); tabs.open(b)
        tabs.updateEditor(.init(), for: a); tabs.updateEditor(.init(), for: b)
        tabs.prune(availableIDs: [a])
        #expect(tabs.documentIDs == [a] && tabs.selectedID == a)
        #expect(tabs.editors[a] != nil && tabs.editors[b] == nil)
    }

    @Test func invalidViewportDoesNotPropagateNonFiniteGeometry() {
        let viewport = NoteWorkspaceTabs.Viewport(x: .nan, y: -.infinity, zoom: .infinity)
        #expect(viewport.x == 0 && viewport.y == 0 && viewport.zoom == 1)
        #expect(NoteWorkspaceTabs.Viewport(x: -1, y: -10, zoom: 99).zoom == 5)
    }
}
