// FloeApp — IDE Markdown outline.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE keeps Markdown source editing in the native UITextView and adds a
// structured outline plus a native rendered preview over the SAME unsaved
// buffer (no Web editor, no second document). This file owns the pure heading
// extraction used by the outline list and the source-navigation target.

#if canImport(UIKit)
import Foundation

/// One ATX heading in document order.
struct IDEMarkdownHeading: Equatable, Identifiable {
    /// Document-order index; stable while the document text is unchanged.
    let id: Int
    /// 1...6, `#` count.
    let level: Int
    /// Heading text with the leading hashes and trailing closing hashes removed.
    let title: String
    /// UTF-16 offset of the heading's first character in the buffer text
    /// (NSRange space), so the native editor can select and scroll to it.
    let utf16Location: Int
    /// 0-based line index.
    let line: Int

    var displayTitle: String { title.isEmpty ? "(untitled)" : title }
}

enum IDEMarkdownOutline {
    /// Extracts ATX headings (`#`…`######`) while ignoring fenced code blocks
    /// (``` / ~~~) and setext underline lines. Pure so focused tests pin the
    /// outline without a UI or a renderer.
    static func headings(in text: String) -> [IDEMarkdownHeading] {
        var result: [IDEMarkdownHeading] = []
        var utf16Offset = 0
        var lineIndex = 0
        var fence: String?
        // split(omittingEmptySubsequences: false) keeps empty lines so line
        // indexes and offsets stay exact.
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let lineUTF16 = line.utf16.count
            defer {
                // +1 for the newline that split removed (the final line has
                // none, which only matters past the end of the text).
                utf16Offset += lineUTF16 + 1
                lineIndex += 1
            }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.utf16.count - trimmed.utf16.count
            if indent > 3 { continue }
            if let active = fence {
                if trimmed.hasPrefix(active) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                continue
            }
            guard trimmed.hasPrefix("#") else { continue }
            var level = 0
            var rest = Substring(trimmed)
            while rest.hasPrefix("#"), level < 7 {
                level += 1
                rest = rest.dropFirst()
            }
            guard (1...6).contains(level) else { continue }
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { continue }
            var title = rest.trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            result.append(IDEMarkdownHeading(
                id: result.count,
                level: level,
                title: title,
                utf16Location: utf16Offset,
                line: lineIndex
            ))
        }
        return result
    }

    /// A selectable range that scrolls the native editor to the heading. A
    /// one-character (or empty-line-safe) selection is used because the
    /// editor only scrolls non-empty selections into view.
    static func selectionRange(for heading: IDEMarkdownHeading, in text: String) -> NSRange {
        let length = text.utf16.count
        let location = min(max(0, heading.utf16Location), max(0, length - 1))
        let available = max(0, length - location)
        return NSRange(location: location, length: min(1, available))
    }
}
#endif
