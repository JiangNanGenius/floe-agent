// FloeProviders — Sentence-boundary segmenter for incremental TTS input.
//
// SPDX-License-Identifier: MPL-2.0
//
// Turns an incremental text feed (assistant tokens arriving over time) into
// ordered, bounded synthesis segments. Cuts at sentence terminators so
// providers receive natural units — but a period flanked by digits is a
// DECIMAL point (12865.50, 0.7 stay whole), with a streaming-safe lookahead
// hold — and the hard ceiling prefers a preceding whitespace so English words
// are not severed. Value type: no async, no shared state — safe for
// deterministic regression tests.

import Foundation

public struct TTSTextSegmenter: Sendable {
    /// Minimum characters to emit in one segment (shorter sentences keep
    /// accumulating until a longer unit is available, bounded by maxCharacters).
    public var minCharacters: Int
    /// Hard ceiling: flush the buffer even without a sentence terminator.
    public var maxCharacters: Int

    private var buffer = ""

    /// Sentence terminators (ASCII + fullwidth) and line breaks.
    static let terminators: Set<Character> = [
        ".", "!", "?", ";",
        "。", "！", "？", "；", "\n", "…",
    ]

    public init(minCharacters: Int = 8, maxCharacters: Int = 600) {
        self.minCharacters = minCharacters
        self.maxCharacters = maxCharacters
    }

    /// Feeds incremental text; returns any segments now complete, in order.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        return drain(final: false)
    }

    /// Signals end-of-text; returns the remaining segment if any.
    public mutating func finish() -> [String] {
        drain(final: true)
    }

    /// True when pending text remains (used to decide whether finish work is
    /// needed at all).
    public var hasPendingText: Bool {
        !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A "." between two digits is a decimal point, never a sentence
    /// boundary. When the digit precedes and the lookahead is not yet
    /// available (streaming edge), the terminator check HOLDS: the re-scan
    /// on the next append decides once `following` is known.
    static func isDecimalPoint(
        character: Character, previous: Character?, following: Character?
    ) -> Bool {
        guard character == "." else { return false }
        guard let previous, previous.isNumber else { return false }
        guard let following else { return true }       // unknown → hold (not a cut)
        return following.isNumber                       // digit → decimal; other → terminator
    }

    private mutating func drain(final: Bool) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = buffer.startIndex
        // Walk the buffer, cutting after terminators once the current segment
        // reaches minCharacters; force-cut at maxCharacters.
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            index = next
            let following: Character? = next < buffer.endIndex ? buffer[next] : nil
            var terminates = Self.terminators.contains(character)
            if Self.isDecimalPoint(character: character, previous: current.last, following: following) {
                terminates = false
            }
            current.append(character)
            if terminates && current.count >= minCharacters {
                emit(&segments, &current)
            } else if current.count >= maxCharacters {
                // Keep words intact where possible: cut at the LAST
                // whitespace that is still at or past the minimum floor;
                // hard-cut at the ceiling only when no such boundary exists.
                if let space = current.lastIndex(where: { $0.isWhitespace }),
                   space != current.startIndex,
                   current.distance(from: current.startIndex, to: space) >= minCharacters {
                    emit(&segments, String(current[..<space]))
                    current = String(current[space...])   // leading space is trimmed at emit
                } else {
                    emit(&segments, &current)
                }
            }
        }
        let remainder = current
        if final {
            emit(&segments, remainder)
            buffer = ""
        } else {
            buffer = remainder
        }
        return segments
    }

    private func emit(_ segments: inout [String], _ piece: String) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(trimmed)
    }

    private func emit(_ segments: inout [String], _ piece: inout String) {
        emit(&segments, piece)
        piece = ""
    }
}
