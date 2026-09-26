import Foundation

/// Bounds the runtime envelope composed for on-device (local) models.
///
/// Build229: a 12-character user message reached a ~12.3k-character system
/// envelope because project instructions (FLOE.md/AGENTS.md), remembered
/// context, interaction style and profile state were injected verbatim on
/// every local turn. The prepared prefill then measured thousands of tokens
/// against the iPad's ~2.65GB available memory and crashed mid-prefill. The
/// device adapter already reserves a bounded share of the model window for
/// runtime instructions; this helper lets the runtime meet that share at
/// composition time, instead of shipping an oversized envelope and relying
/// on the adapter to refuse it after assembly.
///
/// Every bounded section keeps its head and tail around an explicit marker:
/// the section still exists for the model (and for the live clock, the
/// workspace identity and the latest corrections, which are *essential*
/// lines and are never clipped). This is deliberately different from a
/// silent whole-section drop — the failure mode Build 222 eliminated —
/// and from the adapter-side rewrite that Build 222 also eliminated.
enum LocalEnvelopeBounds {
    /// Marker inserted where a section was shortened. The clip keeps the
    /// section's head and tail, so the model still sees what the section
    /// begins and ends with.
    static let omissionMarker = "[local envelope: section clipped]"

    /// Total heuristic-token allowance for the whole local envelope
    /// (contract + mode + run context + data sections). Conservative
    /// (~20% of the model window, capped): the adapter additionally spends
    /// its own protocol text, the offered-tool index, the transcript and
    /// the tool receipts inside the same window, and its pre-allocation
    /// guard still refuses a prompt that cannot fit.
    static func envelopeTokenBudget(contextTokens: Int) -> Int {
        max(480, min(2_048, max(1, contextTokens) / 5))
    }

    /// Longest head prefix whose heuristic estimate stays within `limit`.
    static func prefix(_ text: String, tokenLimit: Int) -> String {
        guard tokenLimit > 0 else { return "" }
        var bytes = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            let width = utf8Width(scalar)
            guard estimate(bytes + width) <= tokenLimit else { break }
            scalars.append(scalar)
            bytes += width
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Longest tail suffix whose heuristic estimate stays within `limit`.
    static func suffix(_ text: String, tokenLimit: Int) -> String {
        guard tokenLimit > 0 else { return "" }
        var bytes = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let width = utf8Width(scalar)
            guard estimate(bytes + width) <= tokenLimit else { break }
            scalars.append(scalar)
            bytes += width
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// Head/tail clip with an explicit marker, analogue of the device
    /// adapter's `LocalPromptPressure.clippedToTokens` for the runtime
    /// envelope. Idempotent once the estimate fits.
    static func clipped(_ text: String, tokenLimit: Int) -> String {
        guard tokenLimit > 0 else { return "" }
        let estimator = ContextTokenEstimator()
        guard estimator.estimate(text) > tokenLimit else { return text }
        let marker = "\n" + omissionMarker + "\n"
        let remaining = tokenLimit - estimator.estimate(marker)
        guard remaining >= 24 else { return prefix(text, tokenLimit: tokenLimit) }
        let headLimit = remaining * 2 / 3
        let tailLimit = remaining - headLimit
        return prefix(text, tokenLimit: headLimit)
            + marker
            + suffix(text, tokenLimit: tailLimit)
    }

    /// Heuristic estimate identical to `ContextTokenEstimator`'s
    /// byte convention so prefix/suffix accounting matches the caller's
    /// whole-text estimate.
    static func estimate(_ utf8Bytes: Int) -> Int {
        (utf8Bytes + 2) / 3
    }

    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }
}
