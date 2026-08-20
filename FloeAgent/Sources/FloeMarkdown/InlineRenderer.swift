// FloeMarkdown — Inline Markdown → AttributedString.
//
// SPDX-License-Identifier: MPL-2.0
//
// Inline styling (bold, italic, strikethrough, links, inline code) is
// delegated to the system AttributedString markdown parser with
// `.inlineOnlyPreservingWhitespace` so block markers never leak into
// block payloads and no custom emphasis/link state machine is needed
// (see docs/ARCHITECTURE_AGENT_WORKSPACE.md §1.2, plan C).

import Foundation

/// Renders the inline layer of a Markdown source fragment.
public enum InlineRenderer {

    /// Parses inline Markdown in `source` into an `AttributedString`.
    ///
    /// Block-level syntax is NOT interpreted here: `#` stays literal,
    /// single newlines are preserved, and GFM-only constructs (tables,
    /// strikethrough) fall back to their literal marker characters —
    /// acceptable degradation for agent output. Failures of the system
    /// parser degrade to the raw source string (never crashes, never
    /// drops content).
    public static func render(_ source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString() }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            return parsed
        }
        return AttributedString(source)
    }
}
