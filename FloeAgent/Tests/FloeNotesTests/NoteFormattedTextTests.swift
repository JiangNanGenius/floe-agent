import Foundation
import Testing
@testable import FloeNotes

@Suite("Notes formatted text storage")
struct NoteFormattedTextTests {
    private func fixture() -> NoteDocument {
        var document = NoteDocument(title: "排版")
        document.schemaVersion = 2
        let id = UUID()
        document.textSources = [id.uuidString: "**中文粗体**\n\n| 项目 | 值 |\n|---|---|\n| 人数 | 90 |"]
        document.pages = (0..<3).map { index in
            var element = NoteElement(text: "第\(index)页")
            element.textFormat = "markdown"; element.textSourceID = id
            element.textSlice = NoteTextSlice(start: index * 3, count: 3, total: 9)
            return NotePage(elements: [element])
        }
        return document
    }

    @Test("Missing format fields decode as plain and literal markers stay unchanged")
    func legacyPlain() throws {
        var document = NoteDocument(title: "旧笔记")
        document.pages[0].elements = [NoteElement(text: "**literal** |---| 中文")]
        let roundTrip = try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(document))
        #expect(roundTrip.pages[0].elements[0].textFormat == nil)
        #expect(NoteTextContent.reading(roundTrip).markdown == false)
        #expect(NoteTextContent.reading(roundTrip).text == "**literal** |---| 中文")
    }

    @Test("Source is stored once across pages and reading reconstructs it once")
    func sharedSource() throws {
        let document = fixture()
        try document.validate()
        let encoded = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(NoteDocument.self, from: encoded)
        #expect(restored.textSources?.count == 1)
        #expect(NoteTextContent.reading(restored).text == restored.textSources?.values.first)
        #expect(NoteTextContent.reading(restored).markdown)
        #expect(restored.pages.map { $0.elements[0].textSourceID }.allSatisfy { $0 == restored.pages[0].elements[0].textSourceID })
    }

    @Test("Deleted or repeated slices cannot resurrect or omit visible page content")
    func partialFlow() {
        var document = fixture()
        document.pages.removeFirst()
        let reading = NoteTextContent.reading(document).text
        #expect(!reading.contains("中文粗体"))
        #expect(reading.contains("第1页") && reading.contains("第2页"))
        document.pages.append(document.pages[0])
        #expect(NoteTextContent.reading(document).text.components(separatedBy: "第1页").count == 3)
    }

    @Test("Mixed plain and formatted notes escape literal markup in reading mode")
    func mixedText() {
        var document = fixture()
        document.pages.append(NotePage(elements: [NoteElement(text: "**literal**")]))
        #expect(NoteTextContent.reading(document).text.hasSuffix("\\*\\*literal\\*\\*"))
    }

    @Test("Unknown format identifiers survive round-trip without conversion")
    func unknownFormat() throws {
        var document = NoteDocument(title: "Future")
        var element = NoteElement(text: "original")
        element.textFormat = "future-format-v2"
        document.pages[0].elements = [element]
        let restored = try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.pages[0].elements[0].textFormat == "future-format-v2")
        #expect(!restored.pages[0].elements[0].isMarkdown)
    }

    @Test("Reading long tables repeats only the header at bounded paragraph boundaries")
    func boundedReaderTable() {
        let header = "| 项目 | 数值 |\n|---|---|"
        let rows = (0..<300).map { "| item-\($0) | \($0) |" }
        let source = header + "\n" + rows.joined(separator: "\n")
        let presentation = NoteTextContent.readerMarkdown(source)
        #expect(presentation.components(separatedBy: "|---|---|").count > 2)
        for row in rows { #expect((presentation + "\n").components(separatedBy: row + "\n").count == 2) }
        #expect(presentation.contains(rows.last!))
        #expect(presentation.components(separatedBy: "\n\n").allSatisfy { $0.count < 4_000 })
        let code = "```\n" + source + "\n```"
        #expect(NoteTextContent.readerMarkdown(code) == code)
    }

    @Test("Missing shared source and negative ranges fail validation")
    func invalidReferences() throws {
        var document = fixture()
        document.textSources = [:]
        #expect(throws: NoteError.self) { try document.validate() }
        document = fixture(); document.pages[0].elements[0].textSlice?.start = -1
        #expect(throws: NoteError.self) { try document.validate() }
    }

    @Test("Duplicate page gets an independent text flow")
    func independentDuplicate() throws {
        var document = fixture()
        let old = document.pages[0].elements[0].textSourceID!
        try NoteEdit.duplicatePage(document.pages[0].id).apply(to: &document)
        let copy = document.pages[1].elements[0].textSourceID!
        #expect(copy != old)
        try NoteEdit.textSource(id: copy, text: "replacement").apply(to: &document)
        #expect(document.textSources?[old.uuidString]?.contains("中文粗体") == true)
    }

    @Test("SQLite save reopen, undo and redo retain source and unrelated ink references")
    func persistentFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let initial = try await store.create(fixture())
        let sourceID = initial.pages[0].elements[0].textSourceID!
        let updated = try await store.apply(NoteEditBatch(documentID: initial.id, expectedRevision: initial.revision,
                                                        title: "格式编辑", edits: [.textSource(id: sourceID, text: "**changed**")]))
        let reopened = try NotesStore(root: root)
        #expect(try await reopened.document(initial.id).textSources?[sourceID.uuidString] == "**changed**")
        #expect(updated.pages == initial.pages)
        let undone = try await store.undo(initial.id, expectedRevision: updated.revision)
        #expect(undone.textSources == initial.textSources)
        let redone = try await store.undo(initial.id, expectedRevision: undone.revision, redo: true)
        #expect(redone.textSources?[sourceID.uuidString] == "**changed**")
        let deleted = try await store.apply(NoteEditBatch(documentID: initial.id, expectedRevision: redone.revision,
                                                        title: "删除", edits: redone.pages.map { .deleteElements(pageID: $0.id, ids: $0.elements.map(\.id)) }))
        #expect(deleted.textSources?.isEmpty == true)
        let restored = try await store.undo(initial.id, expectedRevision: deleted.revision)
        #expect(restored.textSources?[sourceID.uuidString] == "**changed**")
    }
}
