#if canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import Testing
import FloeNotes
@testable import FloeApp

@Suite("Notes Markdown pagination")
@MainActor struct NotesMarkdownPaginationTests {
    private var source: String {
        "# 项目总结\n\n**中文粗体** 和 *italic*\n\n| 项目 | 人数 |\n|---|---|\n" +
        (0..<80).map { "| 部门\($0) | \($0 + 10) |" }.joined(separator: "\n")
    }

    @Test("Long table paginates visual rows, retaining one exact shared source")
    func tablePagination() throws {
        let result = NotesTextLayout.formattedPages(text: source, source: nil, width: 500, height: 400)
        #expect(result.pages.count > 3)
        var document = NoteDocument(title: "布局")
        document.schemaVersion = 2
        document.pages = result.pages
        document.textSources = [result.sourceID.uuidString: result.source]
        try document.validate()
        #expect(NoteTextContent.reading(document).text == source)
        let visible = result.pages.flatMap(\.elements).map(\.text).joined(separator: "\n")
        #expect(!visible.contains("**"))
        #expect(!visible.contains("|---|"))
        for index in 0..<80 { #expect(visible.contains("部门\(index)")) }
        #expect(document.textSources?.count == 1)
        let last = try #require(result.pages.last?.elements.first?.textSlice)
        #expect(last.start + last.count == last.total)
    }

    @Test("Editing and converting text preserves page IDs, unrelated content and ink")
    func reflowPreservesOtherContent() throws {
        let result = NotesTextLayout.formattedPages(text: source, source: nil, width: 500, height: 400)
        var document = NoteDocument(title: "保留")
        document.schemaVersion = 2
        document.pages = result.pages; document.textSources = [result.sourceID.uuidString: source]
        let ink = UUID(), image = UUID()
        document.pages[0].drawingResourceID = ink
        document.pages[0].elements.append(NoteElement(kind: .image, resourceID: image))
        let first = document.pages[0].elements[0]
        let ids = document.pages.map(\.id)
        let changed = source + "\n\n**新增结论**"
        let edits = NotesTextLayout.replacementEdits(element: first, text: changed, markdown: true,
                                                    page: document.pages[0], document: document)
        for edit in edits { try edit.apply(to: &document) }
        #expect(Array(document.pages.prefix(ids.count)).map(\.id) == ids)
        #expect(document.pages[0].drawingResourceID == ink)
        #expect(document.pages[0].elements.contains { $0.resourceID == image })
        #expect(NoteTextContent.reading(document).text == changed)
        #expect(document.pages.flatMap(\.elements).filter { $0.kind == .text }.count == document.pages.flatMap(\.elements).compactMap(\.textSlice).count)
    }

    @Test("PDF uses the same vector text layout and exported Chinese text can be read")
    func vectorPDF() throws {
        let source = "**中文粗体**\n\n| 项目 | 人数 |\n|---|---|\n| Alpha | 90 |"
        let result = NotesTextLayout.formattedPages(text: source, source: nil)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let data = renderer.pdfData { context in
            for page in result.pages {
                context.beginPage()
                NotePageRenderer.draw(page, background: nil, textSources: [result.sourceID.uuidString: source])
            }
        }
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == result.pages.count)
        let text = pdf.string ?? ""
        #expect(text.contains("中文粗体"))
        #expect(text.contains("Alpha"))
        #expect(!text.contains("**"))
        #expect(!text.contains("|---|"))
    }

    @Test("Legacy literal text changes only after an explicit format transaction")
    func explicitConversion() throws {
        var document = NoteDocument(title: "旧笔记")
        let element = NoteElement(frame: .init(x: 40, y: 50, width: 688, height: 924), text: "**中文**")
        document.pages[0].elements = [element]
        #expect(!NoteTextContent.reading(document).markdown)
        let original = document
        for edit in NotesTextLayout.replacementEdits(element: element, text: element.text, markdown: true,
                                                    page: document.pages[0], document: document) { try edit.apply(to: &document) }
        #expect(NoteTextContent.reading(document).markdown)
        #expect(NoteTextContent.reading(document).text == element.text)
        #expect(original.pages[0].elements[0].textFormat == nil)
    }

    private func operation(_ action: String, pageID: UUID, elementID: UUID, text: String? = nil) throws -> NotesEditTool.Operation {
        var value: [String: String] = ["action": action, "pageID": pageID.uuidString, "elementID": elementID.uuidString]
        value["text"] = text
        return try JSONDecoder().decode(NotesEditTool.Operation.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func formattedDocument() -> NoteDocument {
        let result = NotesTextLayout.formattedPages(text: source, source: nil, width: 500, height: 400)
        var document = NoteDocument(title: "AI 排版")
        document.schemaVersion = 2
        document.pages = result.pages; document.textSources = [result.sourceID.uuidString: result.source]
        return document
    }

    @Test("Focused Notes reads page the complete original Markdown; lists stay page previews")
    func agentSourceContinuation() throws {
        let document = formattedDocument(), page = try #require(document.pages.first)
        let element = try #require(page.elements.first)
        let preview = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 10, textOffset: 0, textLimit: 100)
        #expect(preview.elements[0].textScope == "pagePreview")
        #expect(!preview.elements[0].text.contains("|---|"))
        var offset = 0, reconstructed = ""
        repeat {
            let detail = NotesReadTool.pageDetail(document, page: page, index: 0, offset: 0, limit: 1,
                textOffset: offset, textLimit: 19, focusElement: element)
            let chunk = try #require(detail.elements.first)
            #expect(chunk.textScope == "source")
            #expect(chunk.textFormat == "markdown")
            #expect(chunk.textSourceID == element.textSourceID)
            #expect(chunk.textSlice == element.textSlice)
            #expect(chunk.textCharacters == source.count)
            #expect(try JSONEncoder().encode(detail).count <= NotesReadTool.maximumResponseBytes)
            reconstructed += chunk.text
            guard let next = chunk.nextTextOffset else { break }
            #expect(next > offset); offset = next
        } while offset < source.count
        #expect(reconstructed == source)
        var other = document
        other.textSources = [element.textSourceID!.uuidString: "另一份文档的原文"]
        let different = NotesReadTool.pageDetail(other, page: page, index: 0, offset: 0, limit: 1,
            textOffset: 0, textLimit: 100, focusElement: element)
        #expect(different.elements[0].text == "另一份文档的原文")
    }

    @Test("Notes AI updates the whole shared text flow atomically and reopens without losing ink")
    func agentTextSaveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-ai-text-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let bytes = root.appendingPathComponent("ink.fixture")
        try Data("independent ink bytes".utf8).write(to: bytes)
        let ink = try await store.importResource(from: bytes, mediaType: "application/octet-stream")
        var initial = formattedDocument()
        initial.pages[0].drawingResourceID = ink
        let unrelated = NoteElement(kind: .rectangle, frame: .init(x: 12, y: 12, width: 20, height: 20))
        initial.pages[0].elements.append(unrelated)
        let document = try await store.create(initial)
        let page = document.pages[0], first = page.elements[0]
        let changed = source + "\n\n**第一次更新**"
        let final = source + "\n\n**最终更新**"
        var draft = document
        let edits = try NotesEditTool.buildEdits([
            operation("updateText", pageID: page.id, elementID: first.id, text: changed),
            operation("updateText", pageID: page.id, elementID: first.id, text: final)
        ], in: &draft)
        #expect(NoteTextContent.reading(draft).text == final)
        let saved = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
            title: "更新正文", edits: edits, requestID: UUID().uuidString))
        let reopenedStore = try NotesStore(root: root)
        let reopened = try await reopenedStore.document(document.id)
        #expect(reopened.revision == saved.revision)
        #expect(reopened.pages[0].drawingResourceID == ink)
        #expect(reopened.pages[0].elements.contains(unrelated))
        #expect(NoteTextContent.reading(reopened).text == final)
        #expect(reopened.textSources?.count == 1)
        #expect(reopened.pages.flatMap(\.elements).filter { $0.textSourceID == first.textSourceID }.count > 1)
        let inkURL = try await reopenedStore.resourceURL(ink)
        #expect(try Data(contentsOf: inkURL) == Data("independent ink bytes".utf8))
        do {
            _ = try await reopenedStore.apply(.init(documentID: document.id, expectedRevision: document.revision,
                title: "过期更新", edits: edits))
            Issue.record("A stale revision must be rejected")
        } catch NoteError.conflict {
            // The specific revision conflict is required; other errors fail the test.
        }
        #expect(try await reopenedStore.document(document.id) == reopened)
    }

    @Test("Notes AI plain text stays literal and a bad later operation cannot mutate the draft")
    func agentPlainAndAtomicFailure() throws {
        var document = NoteDocument(title: "普通文字")
        let element = NoteElement(text: "**literal** |---| 中文")
        document.pages[0].elements = [element]
        let pageID = document.pages[0].id
        let original = document
        #expect(throws: (any Error).self) {
            try NotesEditTool.buildEdits([
                operation("updateText", pageID: pageID, elementID: element.id, text: "first"),
                operation("updateText", pageID: pageID, elementID: UUID(), text: "invalid")
            ], in: &document)
        }
        #expect(document == original)
        _ = try NotesEditTool.buildEdits([
            operation("updateText", pageID: pageID, elementID: element.id, text: "**still literal**")
        ], in: &document)
        #expect(document.pages[0].elements[0].text == "**still literal**")
        #expect(!document.pages[0].elements[0].isMarkdown)
        #expect(document.textSources == nil)
    }

}
#endif
