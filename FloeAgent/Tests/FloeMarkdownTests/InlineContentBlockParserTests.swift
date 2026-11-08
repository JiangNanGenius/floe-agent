// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeMarkdown

@Suite("Ordered inline native-content blocks")
struct InlineContentBlockParserTests {
    let first = "![Chart](floe-content://artifact/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222)"
    let second = "![File](floe-content://output/11111111-1111-1111-1111-111111111111/" + String(repeating: "a", count: 64) + ")"
    @Test func referenceKeepsItsPositionBetweenParagraphs() {
        let blocks = InlineContentBlockParser.parse("Before\n\n" + first + "\n\nAfter")
        #expect(blocks.count == 3)
        #expect(blocks[0].content == .markdown("Before\n\n"))
        #expect(blocks[1].content == .reference(title: "Chart", uri: String(first.dropFirst(9).dropLast())))
        #expect(blocks[2].content == .markdown("\nAfter"))
    }
    @Test func consecutiveReferencesStayDistinctAndStableWhileAppending() {
        let source = "Before\n" + first + "\n" + second + "\n"
        let initial = InlineContentBlockParser.parse(source, streaming: true)
        let appended = InlineContentBlockParser.parse(source + "After streaming…", streaming: true)
        let ids = initial.compactMap { block -> Int? in if case .reference = block.content { return block.id }; return nil }
        #expect(ids.count == 2)
        #expect(ids == appended.compactMap { block -> Int? in if case .reference = block.content { return block.id }; return nil })
    }
    @Test func incompleteStreamNeverMountsAResource() {
        for count in 1...first.count {
            let tail = String(first.prefix(count))
            #expect(!InlineContentBlockParser.parse(tail, streaming: true).contains { if case .reference = $0.content { return true }; return false })
        }
        #expect(InlineContentBlockParser.parse(first + "\n", streaming: true).contains { if case .reference = $0.content { return true }; return false })
        #expect(InlineContentBlockParser.parse(first).count == 1)
    }
    @Test func ordinaryImagesLinksAndSurroundingInlineTextKeepLegacyMarkdown() {
        for source in ["![Photo](https://example.com/a.png)", "![Local](file:///tmp/a.png)", "[Link](https://example.com)",
                       "prefix " + first, first + " suffix", "    " + first,
                       "\t" + first, "  \t" + first] {
            #expect(InlineContentBlockParser.parse(source).map(\.content) == [.markdown(source)])
        }
    }
    @Test func examplesInsideBothFenceStylesStayCode() {
        for fence in ["```", "~~~~"] {
            let source = fence + "markdown\n" + first + "\n" + fence
            #expect(InlineContentBlockParser.parse(source).map(\.content) == [.markdown(source)])
        }
    }
    @Test func unsupportedOrInvalidReferencesRemainNonExecutingData() {
        let source = "![Unknown](floe-content://unknown/a/b)"
        #expect(InlineContentBlockParser.parse(source).map(\.content) == [.reference(title: "Unknown", uri: "floe-content://unknown/a/b")])
        for source in ["![Bad](floe-content://artifact/a/b)", "![Bad](floe-content://artifact/a/b))"] {
            #expect(!InlineContentBlockParser.parse(source).isEmpty)
        }
    }
}
