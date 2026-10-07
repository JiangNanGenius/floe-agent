// FloeNotesTests — page duplication semantics (Build265).
import Foundation
import Testing
@testable import FloeNotes

@Suite("Notes page edits")
struct NoteEditPageTests {
    @Test("duplicatePage copies content with fresh element identities")
    func duplicatePageFreshIdentities() throws {
        var document = NoteDocument(title: "Doc")
        let original = document.pages[0]
        var page = original
        page.extractedText = "source text"
        let element = NoteElement(frame: .init(x: 10, y: 20, width: 100, height: 40), text: "hello")
        page.elements = [element]
        try NoteEdit.updatePage(page).apply(to: &document)

        try NoteEdit.duplicatePage(original.id).apply(to: &document)
        #expect(document.pages.count == 2)
        let copy = document.pages[1]
        #expect(copy.id != original.id)
        #expect(copy.extractedText == "source text")
        #expect(copy.elements.count == 1)
        #expect(copy.elements[0].text == "hello")
        #expect(copy.elements[0].id != element.id, "copied elements need fresh identities")
        // Shared immutable resources stay by reference.
        #expect(copy.drawingResourceID == page.drawingResourceID)
        #expect(copy.backgroundResourceID == page.backgroundResourceID)
    }

    @Test("duplicatePage inserts directly after the original and rejects unknown pages")
    func duplicatePositionAndErrors() throws {
        var document = NoteDocument(title: "Doc")
        try NoteEdit.duplicatePage(document.pages[0].id).apply(to: &document)
        try NoteEdit.duplicatePage(document.pages[0].id).apply(to: &document)
        #expect(document.pages.count == 3)
        #expect(throws: (any Error).self) {
            try NoteEdit.duplicatePage(UUID()).apply(to: &document)
        }
    }

    @Test("movePage reorders without changing identity")
    func movePageKeepsIdentity() throws {
        var document = NoteDocument(title: "Doc")
        let first = document.pages[0].id
        var second = NotePage()
        try NoteEdit.insertPage(second, at: 1).apply(to: &document)
        second.id = document.pages[1].id
        try NoteEdit.movePage(second.id, to: 0).apply(to: &document)
        #expect(document.pages[0].id == second.id)
        #expect(document.pages[1].id == first)
    }
}
