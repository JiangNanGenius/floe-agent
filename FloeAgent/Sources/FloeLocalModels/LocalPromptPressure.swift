import Foundation

/// Mixed-script prompt pressure accounting for the on-device path.
///
/// The on-device adapter historically bounded its system envelope, transcript
/// and tool evidence in *characters*. That unit is not the unit the model
/// consumes: a CJK ideograph costs roughly one token for the supported
/// Qwen/Gemma tokenizers while an ASCII character is a fraction of a token, so
/// a character-bounded Chinese prompt could be several times larger in real
/// prepared tokens than the same byte count of English. The helpers here
/// convert those bounds into a *heuristic* mixed-script token estimate, clip a
/// section by that estimate keeping its head and tail, and derive per-section
/// allowances from the model window minus the output reserve and the native
/// tool schemas selected for this turn.
///
/// The estimate is deliberately approximate in both directions — neither "one
/// token per CJK scalar" nor "three bytes per token" is a strict upper bound
/// for every tokenizer or script — so it is used only to shape optional
/// sections and to decide whether starting a model is obviously hopeless. The
/// engine's prepared-token guard over the real tokenizer output remains the
/// final admission decision, and its overflow is a recoverable event.
///
/// Everything here is pure value logic with no MLX dependency, so the budget
/// can be exercised without mapping weights.
enum LocalPromptPressure {
    /// Per-section token allowances for one on-device prompt. These are
    /// heuristic allowances, not a fit proof: when the model window is smaller
    /// than the sum of the floors, the adapter's final window check still
    /// refuses before any model allocation.
    struct SectionTokenBudgets: Sendable, Equatable {
        let directory: Int
        let offeredTools: Int
        let runtimeInstructions: Int
        let transcript: Int
        let evidence: Int
        let replay: Int
    }

    /// Heuristic mixed-script token estimate. CJK ideographs, kana, Hangul and
    /// full-width forms are counted as one token per scalar; everything else
    /// as one token per three UTF-8 bytes — the same rough ratio the runtime's
    /// `ContextTokenEstimator` uses for its character estimates. Real
    /// tokenizers can be denser for either class, so this is not a strict
    /// upper bound: it shapes sections conservatively and feeds the
    /// pre-allocation check, while the engine's prepared-token guard over the
    /// real tokenizer output stays the final admission decision.
    static func heuristicTokens(in text: String) -> Int {
        var cjkScalars = 0
        var otherBytes = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkScalars += 1
            } else {
                otherBytes += utf8Width(scalar)
            }
        }
        return cjkScalars + (otherBytes + 2) / 3
    }

    /// Longest prefix whose heuristic estimate stays within `limit`.
    static func prefix(text: String, tokenLimit: Int) -> String {
        guard tokenLimit > 0 else { return "" }
        var cjkScalars = 0
        var otherBytes = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            let nextCJK: Int
            let nextOther: Int
            if isCJK(scalar) {
                nextCJK = cjkScalars + 1
                nextOther = otherBytes
            } else {
                nextCJK = cjkScalars
                nextOther = otherBytes + utf8Width(scalar)
            }
            if estimate(cjkScalars: nextCJK, otherBytes: nextOther) > tokenLimit { break }
            scalars.append(scalar)
            cjkScalars = nextCJK
            otherBytes = nextOther
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Longest suffix whose heuristic estimate stays within `limit`.
    static func suffix(text: String, tokenLimit: Int) -> String {
        guard tokenLimit > 0 else { return "" }
        var cjkScalars = 0
        var otherBytes = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let nextCJK: Int
            let nextOther: Int
            if isCJK(scalar) {
                nextCJK = cjkScalars + 1
                nextOther = otherBytes
            } else {
                nextCJK = cjkScalars
                nextOther = otherBytes + utf8Width(scalar)
            }
            if estimate(cjkScalars: nextCJK, otherBytes: nextOther) > tokenLimit { break }
            scalars.append(scalar)
            cjkScalars = nextCJK
            otherBytes = nextOther
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// Token-bounded analogue of the adapter's character `clipped`: short text
    /// is returned unchanged; longer text keeps a head and a tail around an
    /// explicit marker so ids, cursors and tail markers survive. Idempotent
    /// once the heuristic estimate is inside the limit.
    static func clippedToTokens(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard heuristicTokens(in: text) > limit else { return text }
        let marker = "\n...[omitted]...\n"
        let markerTokens = heuristicTokens(in: marker)
        let remaining = limit - markerTokens
        guard remaining >= 24 else { return prefix(text: text, tokenLimit: limit) }
        let headLimit = remaining * 2 / 3
        let tailLimit = remaining - headLimit
        return prefix(text: text, tokenLimit: headLimit)
            + marker
            + suffix(text: text, tokenLimit: tailLimit)
    }

    /// Output tokens reserved on the wire. Mirrors the runtime's
    /// `contextOutputReservation` so the on-device prompt guard and the
    /// runtime's compaction budget describe the same window, with a floor for
    /// the adapter's minimum generation length.
    static func outputReserveTokens(configuredMaxOutputTokens: Int?, contextTokens: Int) -> Int {
        let window = max(1, contextTokens)
        let reservation: Int
        if let configured = configuredMaxOutputTokens {
            reservation = min(max(0, configured), max(1, window / 2))
        } else {
            reservation = min(4_096, max(512, window / 4))
        }
        return max(64, reservation)
    }

    /// Splits the model window into bounded sections. The schema estimate is
    /// subtracted before any prose allowance: a turn that selected many
    /// dynamic tool schemas shrinks the transcript/evidence sections instead
    /// of silently overfilling the prepared prompt. 92% of the usable window
    /// is allocated; the remainder plus the fixed 384-token deduction covers
    /// the adapter's constant instructions, the chat template and estimation
    /// error.
    static func sectionTokenBudgets(
        contextTokens: Int,
        outputReserveTokens: Int,
        nativeSchemaTokens: Int
    ) -> SectionTokenBudgets {
        let usable = max(
            320,
            contextTokens - max(0, outputReserveTokens) - max(0, nativeSchemaTokens) - 384
        )
        func share(_ percent: Int, floor: Int) -> Int {
            max(floor, usable * percent / 100)
        }
        return SectionTokenBudgets(
            directory: share(10, floor: 96),
            offeredTools: share(8, floor: 96),
            runtimeInstructions: share(26, floor: 256),
            transcript: share(16, floor: 192),
            evidence: share(16, floor: 192),
            replay: share(16, floor: 160)
        )
    }

    private static func estimate(cjkScalars: Int, otherBytes: Int) -> Int {
        cjkScalars + (otherBytes + 2) / 3
    }

    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2EFF,   // CJK radicals
             0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // kana
             0x3100...0x312F,   // bopomofo
             0x3130...0x318F,   // Hangul compatibility jamo
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xA960...0xA97F,   // Hangul jamo extended A
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFE30...0xFE4F,   // CJK compatibility forms
             0xFF00...0xFFEF,   // full-width forms
             0x20000...0x2FA1F: // CJK extension B+
            true
        default:
            false
        }
    }
}
