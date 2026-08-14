// FloeMarkdownTests — Snapshot coverage for the block parser.
//
// SPDX-License-Identifier: MPL-2.0
//
// Structure-level assertions over the [MarkdownBlock] tree for every
// supported construct, plus streaming split and malformed-input
// robustness. Inline styling is asserted through inline intents
// (strong / emphasis / code / link) rather than raw marker text.

import Foundation
import Testing
@testable import FloeMarkdown

@Suite("FloeMarkdown.MarkdownBlockParser")
struct MarkdownBlockParserTests {

    // MARK: - Helpers

    /// True when any run inside the attributed string carries the given
    /// inline presentation intent.
    private func hasIntent(
        _ intent: InlinePresentationIntent,
        in string: AttributedString
    ) -> Bool {
        for run in string.runs {
            if run.inlinePresentationIntent?.contains(intent) == true {
                return true
            }
        }
        return false
    }

    // MARK: - Headings

    @Test("heading levels 1–6 map to heading blocks with text")
    func headingLevels() {
        let blocks = MarkdownBlockParser.parse("# One\n## Two\n### Three\n###### Six")
        #expect(blocks.count == 4)
        guard case .heading(level: 1, text: let one) = blocks[0] else {
            Issue.record("block 0 must be level-1 heading"); return
        }
        #expect(String(one.characters) == "One")
        guard case .heading(level: 2, text: let two) = blocks[1] else {
            Issue.record("block 1 must be level-2 heading"); return
        }
        #expect(String(two.characters) == "Two")
        guard case .heading(level: 3, text: _) = blocks[2],
              case .heading(level: 6, text: _) = blocks[3] else {
            Issue.record("blocks 2/3 must be level-3/6 headings"); return
        }
    }

    @Test("heading without space after # stays paragraph")
    func headingWithoutSpaceIsParagraph() {
        let blocks = MarkdownBlockParser.parse("#notaheading")
        #expect(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0] else {
            Issue.record("must stay a paragraph"); return
        }
        #expect(String(text.characters) == "#notaheading")
    }

    @Test("closing hashes are stripped from heading text")
    func headingClosingHashes() {
        let blocks = MarkdownBlockParser.parse("## Title ##")
        guard case .heading(level: 2, text: let text) = blocks.first else {
            Issue.record("must be a heading"); return
        }
        #expect(String(text.characters) == "Title")
    }

    // MARK: - Paragraphs

    @Test("plain lines merge into one paragraph, blank line splits")
    func paragraphs() {
        let blocks = MarkdownBlockParser.parse("line one\nline two\n\nsecond para")
        #expect(blocks.count == 2)
        guard case .paragraph(let first) = blocks[0],
              case .paragraph(let second) = blocks[1] else {
            Issue.record("expected two paragraphs"); return
        }
        #expect(String(first.characters) == "line one\nline two")
        #expect(String(second.characters) == "second para")
    }

    // MARK: - Lists

    @Test("unordered list with - * + markers")
    func unorderedList() {
        let blocks = MarkdownBlockParser.parse("- alpha\n* beta\n+ gamma")
        #expect(blocks.count == 1)
        guard case .list(ordered: false, items: let items) = blocks[0] else {
            Issue.record("must be an unordered list"); return
        }
        #expect(items.count == 3)
        #expect(items.map { String($0.content.characters) } == ["alpha", "beta", "gamma"])
    }

    @Test("ordered list keeps items, discards numbers")
    func orderedList() {
        let blocks = MarkdownBlockParser.parse("1. first\n2. second\n3) third")
        #expect(blocks.count == 1)
        guard case .list(ordered: true, items: let items) = blocks[0] else {
            Issue.record("must be an ordered list"); return
        }
        #expect(items.count == 3)
        #expect(String(items[0].content.characters) == "first")
        #expect(String(items[2].content.characters) == "third")
    }

    @Test("nested list becomes children of the parent item")
    func nestedList() {
        let blocks = MarkdownBlockParser.parse("- outer\n  - inner a\n  - inner b\n- next")
        #expect(blocks.count == 1)
        guard case .list(ordered: false, items: let items) = blocks[0] else {
            Issue.record("must be an unordered list"); return
        }
        #expect(items.count == 2)
        #expect(items[0].children.count == 1)
        guard case .list(ordered: false, items: let nested) = items[0].children[0] else {
            Issue.record("children[0] must be a nested list"); return
        }
        #expect(nested.map { String($0.content.characters) } == ["inner a", "inner b"])
        #expect(String(items[1].content.characters) == "next")
        #expect(items[1].children.isEmpty)
    }

    @Test("list item continuation line joins the item text")
    func listContinuation() {
        let blocks = MarkdownBlockParser.parse("- first line\n  continued\n- second")
        guard case .list(ordered: false, items: let items) = blocks.first else {
            Issue.record("must be a list"); return
        }
        #expect(items.count == 2)
        #expect(String(items[0].content.characters) == "first line\ncontinued")
    }

    // MARK: - Quotes

    @Test("quote lines parse recursively into inner blocks")
    func quote() {
        let blocks = MarkdownBlockParser.parse("> quoted text\n> more text")
        #expect(blocks.count == 1)
        guard case .quote(let inner) = blocks[0] else {
            Issue.record("must be a quote"); return
        }
        guard case .paragraph(let text) = inner.first else {
            Issue.record("quote must contain a paragraph"); return
        }
        #expect(String(text.characters) == "quoted text\nmore text")
    }

    @Test("nested quotes and quote containing a list")
    func nestedQuoteAndList() {
        let blocks = MarkdownBlockParser.parse("> > deep\n> - item one\n> - item two")
        guard case .quote(let outer) = blocks.first else {
            Issue.record("must be a quote"); return
        }
        #expect(outer.count == 2)
        guard case .quote(let inner) = outer[0] else {
            Issue.record("outer[0] must be a nested quote"); return
        }
        guard case .paragraph(let deep) = inner.first else {
            Issue.record("inner quote must contain a paragraph"); return
        }
        #expect(String(deep.characters) == "deep")
        guard case .list(ordered: false, items: let items) = outer[1] else {
            Issue.record("outer[1] must be a list"); return
        }
        #expect(items.count == 2)
    }

    // MARK: - Code blocks

    @Test("fenced code block keeps verbatim code and language tag")
    func fencedCodeBlock() {
        let source = "```swift\nlet x = 1\n**not bold**\n```"
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .codeBlock(language: let language, code: let code) = blocks[0] else {
            Issue.record("must be a code block"); return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\n**not bold**")
    }

    @Test("code block without language has nil language")
    func codeBlockWithoutLanguage() {
        let blocks = MarkdownBlockParser.parse("```\nplain\n```")
        guard case .codeBlock(language: let language, code: let code) = blocks.first else {
            Issue.record("must be a code block"); return
        }
        #expect(language == nil)
        #expect(code == "plain")
    }

    @Test("unclosed fence still yields a code block")
    func unclosedFence() {
        let blocks = MarkdownBlockParser.parse("```python\nprint(1)")
        guard case .codeBlock(language: let language, code: let code) = blocks.first else {
            Issue.record("must be a code block"); return
        }
        #expect(language == "python")
        #expect(code == "print(1)")
    }

    @Test("tilde fences are accepted like backtick fences")
    func tildeFence() {
        let blocks = MarkdownBlockParser.parse("~~~json\n{}\n~~~")
        guard case .codeBlock(language: let language, code: let code) = blocks.first else {
            Issue.record("must be a code block"); return
        }
        #expect(language == "json")
        #expect(code == "{}")
    }

    // MARK: - Tables

    @Test("GFM pipe table yields header and rectangular rows")
    func pipeTable() {
        let source = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Alan | 41 |"
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .table(header: let header, rows: let rows) = blocks[0] else {
            Issue.record("must be a table"); return
        }
        #expect(header.map { String($0.characters) } == ["Name", "Age"])
        #expect(rows.count == 2)
        #expect(rows[0].map { String($0.characters) } == ["Ada", "36"])
        #expect(rows[1].map { String($0.characters) } == ["Alan", "41"])
    }

    @Test("alignment markers in delimiter row are accepted and dropped")
    func tableAlignmentMarkers() {
        let source = "| a | b | c |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |"
        let blocks = MarkdownBlockParser.parse(source)
        guard case .table(header: let header, rows: let rows) = blocks.first else {
            Issue.record("must be a table"); return
        }
        #expect(header.count == 3)
        #expect(rows.count == 1)
        #expect(rows[0].map { String($0.characters) } == ["1", "2", "3"])
    }

    @Test("short body rows are padded to the header width")
    func tableRowPadding() {
        let source = "| a | b | c |\n| - | - | - |\n| only one |"
        let blocks = MarkdownBlockParser.parse(source)
        guard case .table(header: _, rows: let rows) = blocks.first else {
            Issue.record("must be a table"); return
        }
        #expect(rows.count == 1)
        #expect(rows[0].count == 3)
        #expect(String(rows[0][0].characters) == "only one")
        #expect(String(rows[0][1].characters) == "")
    }

    @Test("pipe text without delimiter row stays a paragraph")
    func pipesWithoutDelimiterAreParagraph() {
        let blocks = MarkdownBlockParser.parse("a | b\nnot a table")
        #expect(blocks.count == 1)
        guard case .paragraph = blocks[0] else {
            Issue.record("must stay a paragraph"); return
        }
    }

    // MARK: - Thematic break

    @Test("thematic break variants --- *** ___")
    func thematicBreaks() {
        let blocks = MarkdownBlockParser.parse("above\n\n---\n\n***\n\n___\n\nbelow")
        let breaks = blocks.filter { $0 == .thematicBreak }
        #expect(breaks.count == 3)
        #expect(blocks.count == 5)
    }

    // MARK: - Inline styling

    @Test("bold, italic, inline code and links carry inline intents")
    func inlineStyling() {
        let blocks = MarkdownBlockParser.parse(
            "a **bold** b *italic* c `code` d [link](https://example.com)"
        )
        guard case .paragraph(let text) = blocks.first else {
            Issue.record("must be a paragraph"); return
        }
        let plain = String(text.characters)
        #expect(plain.contains("bold"))
        #expect(plain.contains("italic"))
        #expect(plain.contains("code"))
        #expect(plain.contains("link"))
        #expect(hasIntent(.stronglyEmphasized, in: text))
        #expect(hasIntent(.emphasized, in: text))
        #expect(hasIntent(.code, in: text))
        var sawLink = false
        for run in text.runs where run.link != nil {
            sawLink = true
            #expect(run.link?.absoluteString == "https://example.com")
        }
        #expect(sawLink)
    }

    @Test("heading text keeps inline styling")
    func headingInlineStyling() {
        let blocks = MarkdownBlockParser.parse("## A *styled* title")
        guard case .heading(level: 2, text: let text) = blocks.first else {
            Issue.record("must be a heading"); return
        }
        #expect(String(text.characters) == "A styled title")
        #expect(hasIntent(.emphasized, in: text))
    }

    // MARK: - Mixed document

    @Test("mixed document keeps block order")
    func mixedDocument() {
        let source = """
        # Report

        Intro paragraph.

        ## Findings

        - one
        - two

        > quoted conclusion

        ```sh
        echo hi
        ```

        | k | v |
        | - | - |
        | a | 1 |

        ---

        done
        """
        let blocks = MarkdownBlockParser.parse(source)
        #expect(blocks.count == 9)
        guard case .heading(level: 1, text: let title) = blocks[0],
              case .paragraph = blocks[1],
              case .heading(level: 2, text: _) = blocks[2],
              case .list(ordered: false, items: let items) = blocks[3],
              case .quote = blocks[4],
              case .codeBlock(language: "sh", code: "echo hi") = blocks[5],
              case .table = blocks[6],
              case .thematicBreak = blocks[7],
              case .paragraph(let done) = blocks[8] else {
            Issue.record("unexpected block order"); return
        }
        #expect(String(title.characters) == "Report")
        #expect(items.count == 2)
        #expect(String(done.characters) == "done")
    }

    // MARK: - Streaming

    @Test("streaming split keeps completed prefix, reparses tail")
    func streamingSplit() {
        let source = "# Title\n\ndone para\npartial para"
        let result = MarkdownBlockParser.parseStreaming(source)
        #expect(result.completed.count == 2)
        guard case .heading = result.completed[0],
              case .paragraph(let done) = result.completed[1] else {
            Issue.record("completed prefix must hold heading + paragraph"); return
        }
        #expect(String(done.characters) == "done para")
        #expect(result.tail.count == 1)
        guard case .paragraph(let tail) = result.tail[0] else {
            Issue.record("tail must be the unfinished paragraph"); return
        }
        #expect(String(tail.characters) == "partial para")
    }

    @Test("streaming split with no newline parses everything as tail")
    func streamingNoNewline() {
        let result = MarkdownBlockParser.parseStreaming("hello")
        #expect(result.completed.isEmpty)
        #expect(result.tail.count == 1)
    }

    // MARK: - Robustness

    @Test("empty and whitespace-only input yields no blocks")
    func emptyInput() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("\n\n\n").isEmpty)
        #expect(MarkdownBlockParser.parse("   \n \t \n").isEmpty)
    }

    @Test("malformed input never crashes and keeps content")
    func malformedInput() {
        let samples = [
            "| only pipes |||",
            "```",
            "> ",
            "- ",
            "1. ",
            "###### too many # hashes ######",
            "| --- |",
            "- a\n- b\n```unclosed",
            "> > > > > deep nest",
            "**dangling bold"
        ]
        for sample in samples {
            let blocks = MarkdownBlockParser.parse(sample)
            #expect(!blocks.isEmpty, "must produce blocks for: \(sample)")
        }
    }

    @Test("lone pipe delimiter row without header is not a table")
    func loneDelimiterRow() {
        let blocks = MarkdownBlockParser.parse("| --- | --- |")
        #expect(blocks.count == 1)
        guard case .paragraph = blocks[0] else {
            Issue.record("must stay a paragraph"); return
        }
    }
}
