// SPDX-License-Identifier: MPL-2.0
import Foundation

/// View-owned reuse of one parsed document or completed streaming prefix.
/// Input bytes and entry count are bounded; AST allocation overhead remains
/// proportional to the parser's output. No global cache or rendering state.
@MainActor
public final class MarkdownBlockParseCache {
    public static let maximumCachedSourceBytes = 512 * 1024

    private var cachedSource: String?
    private var cachedBlocks: [MarkdownBlock] = []
    private let parseSource: @MainActor (String) -> [MarkdownBlock]

    public init() { parseSource = MarkdownBlockParser.parse }

    // Tests wrap the real parser to observe execution rather than inspecting
    // cache flags or replacing the Markdown algorithm.
    init(parseSource: @escaping @MainActor (String) -> [MarkdownBlock]) {
        self.parseSource = parseSource
    }

    public func blocks(for source: String) -> [MarkdownBlock] {
        guard source.utf8.count <= Self.maximumCachedSourceBytes else {
            clear()
            // Oversized content is still rendered in full. Only retention is
            // refused; no truncation, omitted rows, or synthetic success.
            return parseSource(source)
        }
        if let cachedSource, cachedSource.utf8.elementsEqual(source.utf8) {
            return cachedBlocks
        }
        clear()
        let blocks = parseSource(source)
        cachedSource = source
        cachedBlocks = blocks
        return blocks
    }

    /// Same split/window semantics as MarkdownBlockParser.parseStreaming.
    /// Only the completed prefix is retained; the unfinished tail remains
    /// reparsed so Markdown syntax may still change as tokens arrive.
    public func streamingParts(
        for source: String
    ) -> (completed: [MarkdownBlock], tail: [MarkdownBlock]) {
        let window = source.suffix(MarkdownBlockParser.maximumStreamingCharacters)
        guard let newline = window.lastIndex(of: "\n") else {
            return ([], blocks(for: String(window)))
        }
        let completed = String(window[...newline])
        let tail = String(window[window.index(after: newline)...])
        return (blocks(for: completed), parseSource(tail))
    }

    public func clear() {
        cachedSource = nil
        cachedBlocks = []
    }
}
