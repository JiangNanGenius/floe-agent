// FloeAppTests — IDE Markdown outline extraction.
//
// The IDE keeps Markdown editing in the native UITextView and adds a
// structured outline over the same buffer. The outline must agree with the
// document's real heading structure: fenced code blocks and quoted `#` text
// must never become navigation targets, and every heading must carry an exact
// UTF-16 location so the editor can select and scroll to it.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.IDEMarkdownOutline")
@MainActor
struct IDEMarkdownOutlineTests {
    @Test("ATX headings carry level, title, line and UTF-16 location")
    func parsesHeadings() {
        let text = "# Title\n\nsome body\n\n## Section one\n### Deep ###\n"
        let headings = IDEMarkdownOutline.headings(in: text)
        #expect(headings.map(\.level) == [1, 2, 3])
        #expect(headings.map(\.title) == ["Title", "Section one", "Deep"])
        #expect(headings.map(\.line) == [0, 4, 5])
        // "# Title\n" is 8 UTF-16 units; "\n" + "some body\n" + "\n" = 12 more.
        #expect(headings[1].utf16Location == 20)
        #expect(text.utf16.count > headings[2].utf16Location)
    }

    @Test("Fenced code blocks never contribute outline entries")
    func ignoresFencedCode() {
        let text = "# Real\n```\n# Not a heading\n```\n## Also real\n"
        let headings = IDEMarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["Real", "Also real"])
    }

    @Test("Seven hashes and non-heading text are ignored")
    func ignoresNonHeadings() {
        let text = "####### too many\n#nospace\n  ### indented ok\ntext # inline\n"
        let headings = IDEMarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["indented ok"])
        #expect(headings.first?.level == 3)
    }

    @Test("A selection range stays inside the document and scrolls the heading")
    func selectionRangeIsBounded() {
        let text = "# One\nbody\n"
        let headings = IDEMarkdownOutline.headings(in: text)
        let range = IDEMarkdownOutline.selectionRange(for: headings[0], in: text)
        #expect(range.location == 0)
        #expect(range.length == 1)

        let empty = IDEMarkdownOutline.headings(in: "")
        #expect(empty.isEmpty)
        let emptyRange = IDEMarkdownOutline.selectionRange(
            for: IDEMarkdownHeading(id: 0, level: 1, title: "x", utf16Location: 40, line: 0), in: ""
        )
        #expect(emptyRange.location == 0)
        #expect(emptyRange.length == 0)
    }
}

@Suite("FloeApp.IDEMarkdownEditing")
@MainActor
struct IDEMarkdownEditingTests {
    @Test("Wrapping keeps the selection text and places the caret for empty selections")
    func wrapBehaviour() {
        let bold = IDEMarkdownEditing.wrap(text: "hello world", selection: NSRange(location: 6, length: 5), prefix: "**", suffix: "**")
        #expect(bold.text == "hello **world**")
        let caret = IDEMarkdownEditing.wrap(text: "abc", selection: NSRange(location: 3, length: 0), prefix: "**", suffix: "**")
        #expect(caret.text == "abc****")
        #expect(caret.selection.location == 5)
    }

    @Test("Line prefixes replace an existing heading instead of stacking hashes")
    func prefixReplacesHeading() {
        let once = IDEMarkdownEditing.prefixLines(text: "## Title\nbody", selection: NSRange(location: 0, length: 0), marker: "### ")
        #expect(once.text == "### Title\nbody")
        let bullet = IDEMarkdownEditing.prefixLines(text: "- item\n- item", selection: NSRange(location: 0, length: 12), marker: "1. ")
        #expect(bullet.text == "1. item\n1. item")
    }

    @Test("The table scaffold is plain Markdown with the caret in the first cell")
    func tableScaffold() {
        let result = IDEMarkdownEditing.tableScaffold(text: "", selection: NSRange(location: 0, length: 0))
        #expect(result.text.hasPrefix("|  |  |\n| --- | --- |"))
        #expect(result.selection.location == 2)
    }

    @Test("Editor zoom follows Dynamic Type, clamps to 12...28 and steps by one")
    func fontZoomBounds() {
        let baseline = EditorTheme.resolvedSize(nil)
        #expect(IDEEditorFontSize.resolved(IDEEditorFontSize.automatic) == baseline)
        #expect(IDEEditorFontSize.resolved(99) == 28)
        #expect(IDEEditorFontSize.resolved(4) == 12)
        #expect(IDEEditorFontSize.increased(27) == 28)
        #expect(IDEEditorFontSize.increased(28) == 28)
        #expect(IDEEditorFontSize.decreased(13) == 12)
        #expect(!IDEEditorFontSize.canIncrease(28))
        #expect(!IDEEditorFontSize.canDecrease(12))
        // Gutter geometry follows the same resolved size.
        #expect(EditorTheme.gutterFont(size: 28).pointSize > EditorTheme.gutterFont(size: 12).pointSize)
    }
}
#endif
