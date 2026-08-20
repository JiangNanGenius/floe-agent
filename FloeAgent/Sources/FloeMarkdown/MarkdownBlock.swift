// FloeMarkdown — Typed Markdown block tree.
//
// SPDX-License-Identifier: MPL-2.0
//
// Block-level representation of the Markdown subset produced by agent
// output (see docs/ARCHITECTURE_AGENT_WORKSPACE.md §1.2). The block
// parser owns structure; inline styling is delegated to the system
// AttributedString markdown parser (see InlineRenderer.swift).

import Foundation

/// One node of a parsed Markdown document. The tree is intentionally
/// shallow — only block-level structure is modeled; emphasis, links,
/// inline code etc. live inside `AttributedString` payloads.
public enum MarkdownBlock: Sendable, Hashable {

    /// An ATX heading (`#` … `######`). `level` is clamped to 1...6.
    case heading(level: Int, text: AttributedString)

    /// A flow paragraph. Single line breaks inside the source paragraph
    /// are preserved as-is (`.inlineOnlyPreservingWhitespace`).
    case paragraph(AttributedString)

    /// A bullet or numbered list. Nested lists appear as
    /// `ListItem.children`, parsed from indentation.
    case list(ordered: Bool, items: [ListItem])

    /// A block quote (`>`). Contents are recursively parsed blocks, so a
    /// quote may contain headings, lists or nested quotes.
    case quote([MarkdownBlock])

    /// A fenced code block (``` or ~~~). `language` is nil when the info
    /// string is empty; `code` is verbatim (never inline-parsed).
    case codeBlock(language: String?, code: String)

    /// A GFM pipe table. `header` holds the cells of the first row;
    /// `rows` holds body rows, padded to the header column count.
    case table(header: [AttributedString], rows: [[AttributedString]])

    /// A horizontal rule (`---`, `***`, `___`).
    case thematicBreak

    /// One entry of a list block.
    public struct ListItem: Sendable, Hashable {
        /// Inline-rendered item text (the source line minus its marker).
        public var content: AttributedString
        /// Nested list blocks parsed from deeper-indented sibling lines.
        public var children: [MarkdownBlock]

        public init(content: AttributedString, children: [MarkdownBlock] = []) {
            self.content = content
            self.children = children
        }
    }
}
