// FloeNotesTests — shared per-text search offsets (Build265).
import Foundation
import Testing
@testable import FloeNotes

@Suite("Notes per-text search")
struct NoteTextSearchTests {
    private func notebook(_ configure: (inout NoteDocument) -> Void) -> NoteDocument {
        var document = NoteDocument(title: "搜索")
        configure(&document)
        return document
    }

    @Test("element matches carry UTF-16 offsets, including emoji and CJK")
    func elementOffsetsAreUTF16() throws {
        let element = NoteElement(frame: .init(x: 10, y: 20, width: 200, height: 60),
                                  text: "🙂机会成本 and Opportunity cost")
        let document = notebook { $0.pages[0].elements = [element] }

        let chinese = try #require(NoteTextSearch.firstMatch(in: document, query: "机会成本"))
        #expect(chinese.elementID == element.id)
        #expect(chinese.pageID == document.pages[0].id)
        #expect(chinese.utf16Offset == 2, "an emoji is two UTF-16 units")
        #expect(chinese.utf16Length == 4)
        #expect(chinese.sourceKind == "annotation")

        let english = try #require(NoteTextSearch.firstMatch(in: document, query: "opportunity"))
        #expect(english.utf16Offset == (element.text as NSString).range(of: "Opportunity").location)
        #expect(english.utf16Length == 11)
        #expect(english.snippet.contains("Opportunity"))
    }

    @Test("matching is case- and diacritic-insensitive")
    func caseAndDiacriticInsensitive() throws {
        let element = NoteElement(text: "Café 讨论 CAFÉ")
        let document = notebook { $0.pages[0].elements = [element] }
        let match = try #require(NoteTextSearch.firstMatch(in: document, query: "cafe"))
        #expect(match.utf16Offset == 0)
        #expect(match.utf16Length == 4)
    }

    @Test("multiple occurrences return the first range and value limits stop scanning")
    func multipleOccurrencesAndLimit() throws {
        let element = NoteElement(text: "alpha beta alpha gamma alpha")
        let document = notebook { $0.pages[0].elements = [element] }
        let first = try #require(NoteTextSearch.firstMatch(in: document, query: "alpha"))
        #expect(first.utf16Offset == 0)
        let limited = NoteTextSearch.matches(in: document, query: "alpha", limit: 2)
        #expect(limited.count == 2)
        #expect(limited.map(\.utf16Offset) == [0, 11])
        #expect(NoteTextSearch.matches(in: document, query: "alpha", limit: 0).isEmpty)
        #expect(NoteTextSearch.firstMatch(in: document, query: "  ") == nil)
        #expect(NoteTextSearch.firstMatch(in: document, query: "missing") == nil)
    }

    @Test("page scan order is element, extracted text, then cached OCR")
    func pageSourceOrderAndKinds() throws {
        var document = notebook { _ in }
        var page = document.pages[0]
        page.elements = [NoteElement(frame: .init(x: 0, y: 0, width: 200, height: 60), text: "机会成本 批注")]
        page.extractedText = "机会成本 原文"
        document.pages[0] = page
        let key = document.pages[0].visualIndexKey
        document.pages[0].ocrSourceKey = key
        document.pages[0].ocrText = "机会成本 OCR"

        let matches = NoteTextSearch.matches(in: document, query: "机会成本")
        #expect(matches.count == 3)
        #expect(matches[0].source == .elementText)
        #expect(matches[0].elementID != nil)
        #expect(matches[0].utf16Offset == 0)
        #expect(matches[1].source == .extractedText)
        #expect(matches[1].elementID == nil)
        #expect(matches[1].sourceKind == "source")
        #expect(matches[1].utf16Offset == 0)
        #expect(matches[2].source == .ocrText)
        #expect(matches[2].sourceKind == "ocr-composite")
        #expect(matches.allSatisfy { $0.pageID == document.pages[0].id })
    }

    @Test("AI annotations and map topics keep their historical sourceKind")
    func aiLabelsAndMaps() throws {
        var document = NoteDocument(kind: .mindMap, title: "导图")
        document.nodes[0].title = "中心主题"
        document.nodes[0].isAIGenerated = true
        let aiElementPage = NotePage(elements: [NoteElement(text: "AI 批注机会成本", isAIGenerated: true)])
        let map = document
        var notebook = NoteDocument(title: "手记")
        notebook.pages = [aiElementPage]

        let aiElement = try #require(NoteTextSearch.firstMatch(in: notebook, query: "机会成本"))
        #expect(aiElement.sourceKind == "ai-annotation")
        #expect(aiElement.pageID == aiElementPage.id)

        let aiNode = try #require(NoteTextSearch.firstMatch(in: map, query: "中心"))
        #expect(aiNode.nodeID == map.nodes[0].id)
        #expect(aiNode.sourceKind == "ai-map-topic")
        #expect(aiNode.utf16Offset == 0)
    }

    @Test("map note and attachment fields carry node identity and field offsets")
    func mapFieldOffsets() throws {
        var node = MindMapNode(title: "根主题")
        node.note = "备注里出现机会成本"
        node.attachments = [
            MindMapAttachment(resourceID: UUID(), fileName: "机会成本.pdf", mediaType: "application/pdf",
                              kind: .document, caption: "附件说明：机会成本")
        ]
        var document = NoteDocument(kind: .mindMap, title: "导图")
        document.nodes = [node]

        let note = try #require(NoteTextSearch.matches(in: document, query: "机会成本").first { $0.source == .mapNote })
        #expect(note.nodeID == node.id)
        #expect(note.sourceKind == "map-topic")
        #expect(note.utf16Offset == 5, "备注里出现 is five UTF-16 units")
        let fileName = try #require(NoteTextSearch.matches(in: document, query: "机会成本").first { $0.source == .mapAttachmentName })
        #expect(fileName.nodeID == node.id)
        #expect(fileName.utf16Offset == 0)
        let caption = try #require(NoteTextSearch.matches(in: document, query: "附件说明").first { $0.source == .mapAttachmentCaption })
        #expect(caption.utf16Offset == 0)
    }

    @Test("Office extracted text is searched only when cached for the current resource")
    func officeTextMatch() throws {
        var document = NoteDocument(kind: .office, title: "合同")
        let resource = UUID()
        document.officeResourceID = resource
        document.officeFileName = "合同.docx"
        document.officeTextResourceID = resource
        document.officeExtractedText = "甲方：Floe，机会成本条款"

        let match = try #require(NoteTextSearch.firstMatch(in: document, query: "机会成本"))
        #expect(match.source == .officeText)
        #expect(match.sourceKind == "office")
        #expect(match.pageID == nil && match.elementID == nil && match.nodeID == nil)
        #expect(match.utf16Offset == (document.officeExtractedText! as NSString).range(of: "机会成本").location)

        document.officeTextResourceID = UUID()
        #expect(NoteTextSearch.firstMatch(in: document, query: "机会成本") == nil,
                "a stale cache is not searchable")
    }

    @Test("document title and tags are not per-text matches")
    func titleIsNotAPerTextMatch() throws {
        let document = NoteDocument(title: "机会成本")
        #expect(NoteTextSearch.firstMatch(in: document, query: "机会成本") == nil)
    }
}
