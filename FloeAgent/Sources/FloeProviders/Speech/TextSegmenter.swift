// FloeProviders — Sentence-boundary segmenter for incremental TTS input.
//
// SPDX-License-Identifier: MPL-2.0
//
// Two cut policies share the one append/finish interface:
//
// * `.bounded` (legacy): cut at any terminator and force-cut at
//   maxCharacters. Retained unchanged for call sites and regression tests
//   that pin the historical fragment-bounded behavior.
// * `.completeSentences` (production read-aloud and local inference): a
//   segment is emitted ONLY at a true sentence end — 。！？ and an English
//   sentence-ending .!? plus any immediately following closing
//   quotes/brackets — together with ellipsis runs. Commas, colons,
//   semicolons, spaces and newlines never flush an unfinished sentence;
//   decimal/version/domain points and abbreviation dots never split. A
//   boundary held at the buffer end (its lookahead is not yet streamed)
//   resolves on the next append, and an unterminated tail is emitted
//   exactly once by `finish()`. Nothing is ever fragmented mid-sentence:
//   hard native input limits are enforced by the model's own context and
//   frame guards at the synthesis boundary (see `TTSSpeechBudget`), never
//   by cutting a sentence here.
//
// Value type: no async, no shared state — safe for deterministic
// regression tests.

import Foundation

public struct TTSTextSegmenter: Sendable {
    /// How aggressively incremental text is cut into synthesis segments.
    public enum SentencePolicy: Sendable {
        /// Historical behavior: cut at terminators, force-cut at
        /// maxCharacters (word-preferred boundary, hard cut as last
        /// resort). Fragments are possible by design.
        case bounded
        /// Never emit fragments: only true sentence ends (with their
        /// trailing closers) or `finish()` complete a segment.
        case completeSentences
    }

    /// Minimum characters before a bounded-mode terminator emits (legacy).
    public var minCharacters: Int
    /// Hard ceiling for bounded-mode force cuts (legacy; ignored by
    /// `.completeSentences`, which must never fragment a sentence).
    public var maxCharacters: Int
    public var policy: SentencePolicy

    private var buffer = ""

    /// Legacy terminators (ASCII + fullwidth) and line breaks.
    static let terminators: Set<Character> = [
        ".", "!", "?", ";",
        "。", "！", "？", "；", "\n", "…",
    ]

    // MARK: - Complete-sentence boundary rules

    /// Fullwidth sentence terminators: 。！？ (Chinese/Japanese). These are
    /// never word-internal, so they terminate unconditionally (once their
    /// closer lookahead is resolved).
    static let fullwidthTerminators: Set<Character> = ["。", "！", "？"]
    /// English/Japanese terminators that are still terminators even when the
    /// next character is unknown; only '.' needs disambiguation.
    static let asciiTerminators: Set<Character> = ["!", "?"]
    static let ellipsisCharacter: Character = "…"
    /// Closing quotes/brackets consumed INTO the sentence they follow.
    static let sentenceClosers: Set<Character> = [
        "\"", "'", "”", "’", "）", ")", "】", "』", "」", "》",
    ]
    /// Words whose trailing '.' is not a sentence end (case-insensitive,
    /// stored without the final dot; dotted forms keep their inner dots).
    static let abbreviations: Set<String> = [
        "mr", "mrs", "dr", "prof", "st", "jr", "sr", "vs", "etc",
        "inc", "ltd", "co", "corp", "dept", "approx", "vol", "vols",
        "no", "nos", "fig", "figs", "pp", "al", "e.g", "i.e", "u.s",
        "u.k", "u.n", "ph.d", "m.b.a", "ll.b", "ll.m", "b.a", "b.s",
        "m.a", "m.s", "m.d", "a.m", "p.m", "a.d", "b.c",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct",
        "nov", "dec", "mon", "tue", "wed", "thu", "fri", "sat", "sun",
    ]

    public init(minCharacters: Int = 8, maxCharacters: Int = 600) {
        self.minCharacters = minCharacters
        self.maxCharacters = maxCharacters
        self.policy = .bounded
    }

    /// Policy-selected initializer. `minCharacters`/`maxCharacters` keep
    /// their legacy meaning for `.bounded` and are ignored by
    /// `.completeSentences` (a complete sentence may be any length; hard
    /// native input limits are enforced by the model's own context/frame
    /// guards at the synthesis boundary, not by fragmenting here).
    public init(policy: SentencePolicy, minCharacters: Int = 8, maxCharacters: Int = 600) {
        self.minCharacters = minCharacters
        self.maxCharacters = maxCharacters
        self.policy = policy
    }

    /// Feeds incremental text; returns any segments now complete, in order.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        return drain(final: false)
    }

    /// Signals end-of-text; returns the remaining segment if any. In
    /// `.completeSentences` this is the ONLY place an unpunctuated final
    /// answer/title/table tail is emitted — exactly once.
    public mutating func finish() -> [String] {
        drain(final: true)
    }

    /// True when pending text remains (used to decide whether finish work is
    /// needed at all).
    public var hasPendingText: Bool {
        !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Characters currently held without a completed boundary. Informational
    /// only (barge/stop decisions and tests): the text is never truncated or
    /// cut here, and real model input limits stay with the native guards.
    public var pendingCharacterCount: Int {
        buffer.count
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
        switch policy {
        case .bounded: return drainBounded(final: final)
        case .completeSentences: return drainCompleteSentences(final: final)
        }
    }

    // MARK: - Legacy bounded policy (unchanged)

    private mutating func drainBounded(final: Bool) -> [String] {
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

    // MARK: - Complete-sentence policy

    private mutating func drainCompleteSentences(final: Bool) -> [String] {
        var segments: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let candidate: Bool
            switch character {
            case ".":
                candidate = Self.dotTerminates(
                    buffer, dot: index, segmentStart: start)
            case "。", "！", "？", "!", "?", "…":
                // A terminator exactly at the buffer edge is HELD: the next
                // append may bring a closing quote/bracket that belongs to
                // this sentence, and an unknown continuation must never be
                // split from it. `finish()` still flushes a held tail.
                candidate = Self.indexAfter(buffer, index) < buffer.endIndex
            default:
                candidate = false
            }
            guard candidate else {
                index = buffer.index(after: index)
                continue
            }
            // Consume the full terminator/closer run (e.g. "?! …」") so the
            // emitted sentence carries its terminal punctuation and closers.
            var end = index
            var cursor = Self.indexAfter(buffer, index)
            while cursor < buffer.endIndex,
                  Self.fullwidthTerminators.contains(buffer[cursor])
                    || Self.asciiTerminators.contains(buffer[cursor])
                    || buffer[cursor] == Self.ellipsisCharacter
                    || buffer[cursor] == "."
                    || Self.sentenceClosers.contains(buffer[cursor]) {
                end = cursor
                cursor = Self.indexAfter(buffer, cursor)
            }
            // A run that reaches the buffer edge is still UNRESOLVED: the
            // next append may extend it with more closers, so nothing is
            // emitted yet. Only a run stopped by a real non-boundary
            // character proves the sentence (and its closers) is complete.
            guard cursor < buffer.endIndex else {
                index = cursor
                continue
            }
            segments.append(contentsOf: emitted(String(buffer[start...end])))
            index = cursor
            start = cursor
        }
        if final {
            segments.append(contentsOf: emitted(String(buffer[start...])))
            buffer = ""
        } else {
            buffer = String(buffer[start...])
        }
        return segments
    }

    /// Is the '.' at `dot` a true English sentence end within the pending
    /// segment `segmentStart..<buffer.endIndex`? False means "not a
    /// boundary" (decimal/domain/version/abbreviation) or "cannot decide
    /// yet" (lookahead at the buffer edge) — both keep accumulating.
    static func dotTerminates(
        _ buffer: String, dot: String.Index, segmentStart: String.Index
    ) -> Bool {
        let nextIndex = indexAfter(buffer, dot)
        let previous = dot == segmentStart ? nil : buffer[buffer.index(before: dot)]
        let following = nextIndex < buffer.endIndex ? buffer[nextIndex] : nil
        // Alphanumeric on BOTH sides: decimal point, version, domain,
        // ordinal-with-no-space forms — never a sentence end.
        if let previous, previous.isLetter || previous.isNumber,
           let following, following.isLetter || following.isNumber {
            return false
        }
        // Unknown lookahead: hold (the re-scan on the next append decides;
        // `finish()` flushes a genuinely final dot as part of the tail).
        guard let following else { return false }
        // Word immediately before the dot is a known abbreviation.
        if Self.isAbbreviationDot(buffer, dot: dot, segmentStart: segmentStart) {
            return false
        }
        if following.isWhitespace {
            // Scan past the whitespace gap (stream-safe: unknown beyond the
            // edge holds via the same rule when the scan reaches the edge).
            var probe = nextIndex
            while probe < buffer.endIndex, buffer[probe].isWhitespace {
                probe = buffer.index(after: probe)
            }
            guard probe < buffer.endIndex else { return false }     // hold
            let first = buffer[probe]
            if first.isLowercase { return false }                   // "vs. this"
            return true                                             // "…done. Next"
        }
        // Closers and further terminators continue the run (consumed by the
        // caller); anything else after a resolved '.' still ends the clause.
        return true
    }

    /// True when the letters/dots immediately before `dot` spell a known
    /// abbreviation ("Dr.", "e.g.", "U.S.", "Oct.") — its '.' is content.
    static func isAbbreviationDot(
        _ buffer: String, dot: String.Index, segmentStart: String.Index
    ) -> Bool {
        var word = ""
        var cursor = dot
        while cursor > segmentStart {
            let before = buffer.index(before: cursor)
            let character = buffer[before]
            if character.isLetter || character == "." {
                word.insert(character, at: word.startIndex)
                cursor = before
            } else {
                break
            }
        }
        var candidate = word.lowercased()
        while candidate.hasSuffix(".") { candidate.removeLast() }
        // Strip a single trailing dot that IS this dot ("dr." → scan held the
        // dot itself out; inner dots remain for "e.g"/"u.s" forms).
        return !candidate.isEmpty && abbreviations.contains(candidate)
    }

    static func indexAfter(_ text: String, _ index: String.Index) -> String.Index {
        let next = text.index(after: index)
        return next
    }

    private func emitted(_ piece: String) -> [String] {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [trimmed]
    }

    private func emit(_ segments: inout [String], _ piece: String) {
        segments.append(contentsOf: emitted(piece))
    }

    private func emit(_ segments: inout [String], _ piece: inout String) {
        emit(&segments, piece)
        piece = ""
    }
}

/// Empirical generation budget for ONE whole-sentence native call.
///
/// IMPORTANT — what this is NOT: it is not a model input ceiling, and no
/// caller uses it to reject a sentence. The native runtimes remain the
/// authoritative hard guards:
///
/// * MOSS-TTS-Nano checks `actualPromptRows + maxFrames <= contextLength`
///   with the REAL sentencepiece tokenization BEFORE generating anything,
///   and throws `generationLimit` (loudly, never silently) if audio reaches
///   `maxFrames` before end-of-speech. Both map to a recoverable
///   sentence-too-long failure in the runtime. The vendored package now
///   exposes the exact prompt-row count (`promptRowCount(text:reference:)`),
///   so the app sizes each call's frame allowance against the REAL remaining
///   context (`mossGenerationFrameBudget`) instead of the estimate alone —
///   the measured-rate curve stays only as the lower floor.
/// * Qwen3-TTS caps generation itself at six codec frames per REAL text
///   token (`maxTokenCap`); the App's existing 8 MiB PCM-per-utterance
///   guard and the 4096-character request guard remain untouched.
///
/// The frame budget is derived from the 2026-10-22/23 audition measurements
/// on this host (M5 Pro): MOSS speech rates 4.8 char/s (zh), 4.9 (ja),
/// 6.9 (ko), 18.3 (en); Qwen 3.6 (zh), 11.0 (en), 5.6 (ko). Those are the
/// observed slowest rates for the shipped voices — clearly EMPIRICAL, not
/// asserted hard model capacities. Frames are 80 ms (12.5 fps) for both
/// engines.
public enum TTSSpeechBudget {
    /// Upper bound of fixed prompt-template + BOS/EOS rows in
    /// `MossTTSNanoTokenizer.prompt` (literal template strings plus the
    /// reference branch overhead). Empirical headroom: the native check
    /// still measures the actual rows and fails closed before any audio.
    public static let mossTemplateRowsUpperBound = 112
    /// EOS frames reserved after the estimated speech length.
    public static let mossEndOfSpeechMarginFrames = 10
    /// Rows the frame budget never claims, so an underestimated row count
    /// cannot silently eat into the native context check\'s margin.
    public static let mossContextSafetyRows = 8

    /// Same script classification the runtime has always used for language
    /// detection; here it only selects which measured-rate budget curve
    /// applies to the frame sizing.
    public static func hasCJKCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3000...0x30ff).contains($0.value)        // CJK punctuation + kana
                || (0x3400...0x9fff).contains($0.value) // CJK ideographs
                || (0xac00...0xd7af).contains($0.value) // Hangul
                || (0xf900...0xfaff).contains($0.value) // compatibility ideographs
        }
    }

    /// Frames per character at the slowest measured speech rate of the
    /// script class, with a 10% allowance for slower unmeasured voices.
    public static func mossFramesPerCharacter(hasCJK: Bool) -> Double {
        hasCJK ? (12.5 / 4.8) * 1.1 : (12.5 / 11.0) * 1.1
    }

    /// Frame budget for one MOSS call of a whole sentence: enough frames to
    /// cover the measured slowest speech for `characterCount` characters
    /// (plus the EOS margin), capped so the request can never claim more of
    /// the real context than the template reservation and safety margin
    /// allow. Always >= 1 so `MossTTSNanoOptions` stays valid. The native
    /// `contextExceeded` / `generationLimit` guards own everything beyond
    /// that, before or without any synthesized audio.
    public static func mossMaxFrames(
        contextLength: Int, characterCount: Int, hasCJK: Bool
    ) -> Int {
        let estimated = Int((Double(characterCount)
            * mossFramesPerCharacter(hasCJK: hasCJK)).rounded(.up))
            + mossEndOfSpeechMarginFrames
        let contextAvailable = max(1,
            contextLength - mossTemplateRowsUpperBound - mossContextSafetyRows)
        return min(estimated, contextAvailable)
    }

    /// Use actual context headroom rather than clipping valid speech to an
    /// estimated duration. Retain the expected-duration floor so the native
    /// guard rejects insufficient context before starting that block.
    public static func mossGenerationFrameBudget(
        contextLength: Int, promptRows: Int, characterCount: Int, hasCJK: Bool
    ) -> Int {
        let estimated = Int((Double(characterCount)
            * mossFramesPerCharacter(hasCJK: hasCJK)).rounded(.up))
            + mossEndOfSpeechMarginFrames
        let headroom = contextLength - promptRows - mossContextSafetyRows
        return max(1, max(estimated, headroom))
    }
}
