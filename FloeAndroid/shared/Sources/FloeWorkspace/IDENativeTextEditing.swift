// FloeWorkspace — Native IDE text editing primitives.
//
// SPDX-License-Identifier: MPL-2.0
//
// UTF-16 based helpers shared by the native editor pane and its tests.
// `UITextView` selections, `NSRange` lookups and the IME marked range all use
// UTF-16 offsets, so every search, replacement and cursor computation here
// works on the same unit and never splits a surrogate pair when a location is
// mapped back to a string index (splitting one would corrupt the next
// programmatic replacement).
//
// The composition guard is the IME safeguard: while a marked (composing)
// range is active the editor must not replace its text storage and must not
// re-render syntax highlighting, because either write commits/cancels the
// composition and can drop or duplicate what the user typed. Programmatic
// updates are recorded and applied once the composition ends.

import Foundation

/// One replacement produced by `IDENativeTextEditing.replaceCurrent`/
/// `replaceAll`: the resulting text plus the selection that should follow it.
public struct IDENativeTextReplaceResult: Equatable, Sendable {
    public var text: String
    public var selection: NSRange
    /// True when the text changed; false when the call only moved the
    /// selection to the next match.
    public var replaced: Bool

    public init(text: String, selection: NSRange, replaced: Bool) {
        self.text = text
        self.selection = selection
        self.replaced = replaced
    }
}

public enum IDENativeTextEditing {
    /// Clamps a UTF-16 range to `text` and keeps both offsets on composed
    /// character boundaries.
    public static func clamp(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = composedBoundary(in: text, offset: max(0, min(range.location, length)))
        let end = composedBoundary(in: text, offset: max(location, min(range.location + range.length, length)))
        return NSRange(location: location, length: end - location)
    }

    /// True when `offset` may be used as a UTF-16 substring boundary. A trail
    /// surrogate at `offset` means the boundary sits inside a surrogate pair
    /// (an emoji), which UIKit would round to a different unit anyway.
    public static func isComposedBoundary(in text: String, offset: Int) -> Bool {
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count else { return false }
        guard offset > 0, offset < units.count else { return true }
        return !UTF16.isTrailSurrogate(units[offset])
    }

    private static func composedBoundary(in text: String, offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        return isComposedBoundary(in: text, offset: offset) ? offset : offset - 1
    }

    /// Case-insensitive forward/backward search that wraps once. Mirrors the
    /// pre-existing native editor behavior (`TextFileEditorView.find`) so the
    /// IDE pane and the inspector editor stay identical.
    public static func find(
        in text: String,
        query: String,
        backwards: Bool,
        from selection: NSRange
    ) -> NSRange? {
        guard !query.isEmpty else { return nil }
        let nsText = text as NSString
        let selection = clamp(selection, to: text)
        let start = backwards ? 0 : min(NSMaxRange(selection), nsText.length)
        let length = backwards ? min(selection.location, nsText.length) : nsText.length - start
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        var range = nsText.range(of: query, options: options, range: NSRange(location: start, length: length))
        if range.location == NSNotFound {
            range = nsText.range(of: query, options: options, range: NSRange(location: 0, length: nsText.length))
        }
        return range.location == NSNotFound ? nil : range
    }

    /// Replaces the current selection when it matches `query`; otherwise moves
    /// the selection to the next match without touching the text.
    public static func replaceCurrent(
        in text: String,
        query: String,
        replacement: String,
        selection: NSRange
    ) -> IDENativeTextReplaceResult {
        let nsText = text as NSString
        let clamped = clamp(selection, to: text)
        if clamped.length > 0,
           nsText.substring(with: clamped).localizedCaseInsensitiveCompare(query) == .orderedSame {
            let replacedText = nsText.replacingCharacters(in: clamped, with: replacement)
            let cursor = clamped.location + (replacement as NSString).length
            return IDENativeTextReplaceResult(
                text: replacedText,
                selection: clamp(NSRange(location: cursor, length: 0), to: replacedText),
                replaced: true
            )
        }
        guard let match = find(in: text, query: query, backwards: false, from: clamped) else {
            return IDENativeTextReplaceResult(text: text, selection: clamped, replaced: false)
        }
        return IDENativeTextReplaceResult(text: text, selection: match, replaced: false)
    }

    /// Case-insensitive replace-all over the whole document.
    public static func replaceAll(
        in text: String,
        query: String,
        replacement: String,
        selection: NSRange
    ) -> IDENativeTextReplaceResult {
        guard !query.isEmpty else {
            return IDENativeTextReplaceResult(text: text, selection: clamp(selection, to: text), replaced: false)
        }
        let replacedText = text.replacingOccurrences(of: query, with: replacement, options: .caseInsensitive)
        let cursor = clamp(selection, to: text).location
        return IDENativeTextReplaceResult(
            text: replacedText,
            selection: clamp(NSRange(location: cursor, length: 0), to: replacedText),
            replaced: replacedText != text
        )
    }

    /// 1-based line and UTF-16 column for a cursor location, clamped to a
    /// composed boundary so an emoji cursor never reports a broken column.
    public static func lineAndColumn(in text: String, at location: Int) -> (line: Int, column: Int) {
        let nsText = text as NSString
        let safeLocation = clamp(NSRange(location: location, length: 0), to: text).location
        let prefix = nsText.substring(to: safeLocation)
        let lines = prefix.components(separatedBy: "\n")
        return (line: lines.count, column: (lines.last?.utf16.count ?? 0) + 1)
    }

    public static func lineCount(in text: String) -> Int {
        var count = 1
        for unit in text.utf16 where unit == 0x0A { count += 1 }
        return count
    }
}

/// Per-editor IME safeguard. One value belongs to one text view instance; the
/// view feeds it the real `markedTextRange != nil` state and never mutates the
/// text storage or re-highlights while compositing.
public struct IDENativeEditorCompositionGuard: Equatable, Sendable {
    /// True while the input method has a marked (uncommitted) range.
    public private(set) var hasMarkedText = false
    /// Programmatic text that could not be applied yet.
    public private(set) var pendingProgrammaticText: String?

    public init() {}

    /// Whether a programmatic storage replacement or re-highlight may run.
    public static func mayWriteTextStorage(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    /// Records a programmatic update. Returns true when the caller may apply
    /// it now; false means it was deferred until the composition ends.
    public mutating func requestProgrammaticUpdate(_ text: String, hasMarkedText: Bool) -> Bool {
        self.hasMarkedText = hasMarkedText
        guard hasMarkedText else {
            pendingProgrammaticText = nil
            return true
        }
        pendingProgrammaticText = text
        return false
    }

    /// The composition ended (commit or cancel). Returns the deferred text the
    /// caller must now apply, exactly once.
    public mutating func compositionDidEnd() -> String? {
        hasMarkedText = false
        defer { pendingProgrammaticText = nil }
        return pendingProgrammaticText
    }
}
