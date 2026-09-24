// FloeApp — IDE Markdown editing transforms.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE's Markdown toolbar applies plain-text Markdown transforms to the
// active native buffer's selection (or cursor). Everything stays source-only:
// there is no second WYSIWYG document, no Web editor and no separate dirty
// state. Pure helpers so focused tests pin the exact text/selection results.

#if canImport(UIKit)
import Foundation

enum IDEMarkdownEditing {
    struct Result: Equatable {
        let text: String
        let selection: NSRange
    }

    /// Wraps the selection (or inserts the empty markers at the cursor).
    static func wrap(text: String, selection: NSRange, prefix: String, suffix: String) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, length: ns.length)
        let selected = ns.substring(with: clamped)
        let replacement = prefix + selected + suffix
        let updated = ns.replacingCharacters(in: clamped, with: replacement)
        let cursor = selected.isEmpty
            ? clamped.location + prefix.utf16.count
            : clamped.location + replacement.utf16.count
        return Result(text: updated, selection: NSRange(location: cursor, length: 0))
    }

    /// Prefixes every line touched by the selection with `marker` (heading
    /// level, list bullet, quote). Existing heading hashes are replaced.
    static func prefixLines(text: String, selection: NSRange, marker: String) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, length: ns.length)
        let lineRange = ns.lineRange(for: clamped)
        let block = ns.substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        let prefixed = lines.map { line -> String in
            if line.isEmpty { return line }
            var body = Substring(line)
            // Replace an existing ATX heading or bullet so repeated taps do
            // not stack markers.
            while body.hasPrefix("#") { body = body.dropFirst() }
            if body.hasPrefix("> ") { body = body.dropFirst(2) }
            if body.hasPrefix("- ") || body.hasPrefix("* ") { body = body.dropFirst(2) }
            body = body.drop(while: { $0 == " " })
            return marker + body
        }
        let replacement = prefixed.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        let delta = replacement.utf16.count - block.utf16.count
        return Result(
            text: updated,
            selection: NSRange(location: clamped.location, length: max(0, clamped.length + delta))
        )
    }

    /// Inserts a table scaffold at the cursor, leaving the caret in the first
    /// header cell. This is a scaffold (rows/columns are then plain Markdown
    /// text); there is no cell-level table editor.
    static func tableScaffold(text: String, selection: NSRange) -> Result {
        let firstCell = "|  |  |"
        let scaffold = firstCell + "\n| --- | --- |\n|  |  |\n"
        let ns = text as NSString
        let clamped = clamp(selection, length: ns.length)
        let updated = ns.replacingCharacters(in: clamped, with: scaffold)
        // Caret after "| " in the first header cell.
        let cursor = clamped.location + ("| " as NSString).length
        return Result(text: updated, selection: NSRange(location: cursor, length: 0))
    }

    /// Insert a fenced code block that wraps the selection (or an empty one).
    static func codeBlock(text: String, selection: NSRange) -> Result {
        wrap(text: text, selection: selection, prefix: "```\n", suffix: "\n```")
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let available = max(0, length - location)
        let boundedLength = min(max(0, range.length), available)
        return NSRange(location: location, length: boundedLength)
    }
}
#endif
