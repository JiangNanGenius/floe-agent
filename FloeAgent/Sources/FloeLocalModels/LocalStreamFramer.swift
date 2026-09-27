import Foundation

/// Incremental display framer for a streamed on-device answer.
///
/// Build 230 on-device feedback: the local adapter buffered the complete
/// generation before emitting a single `textDelta`, so a slow or stuck turn
/// produced an indefinite "no reply" wait with no progress and no terminal
/// state. The engine can now forward decoded chunks, but raw chunks cannot be
/// shown as-is:
///
/// - a `<think ...>` block may be split across chunks and must never leak
///   into the visible answer (the final pipeline still routes it to the
///   private reasoning channel);
/// - the bounded tool protocol is JSON (`{"tool_call":...}` whole-payload,
///   fenced, or one object per line) and a half-written JSON object must not
///   be displayed or parsed as prose;
/// - small templates sometimes emit a "Thinking Process:" scratchpad whose
///   visible answer only starts after a later marker.
///
/// The framer therefore holds undecided prefixes (leading markers, an open
/// think block, a JSON-looking region) and releases everything else as soon
/// as it is provably prose. It never emits reasoning, never emits a recognized
/// tool payload as answer text, and `finish(visibleAnswer:)` reconciles the
/// streamed prefix with the authoritative final answer so the same content is
/// never displayed twice.
///
/// Reconciliation relies on one invariant: everything released is a prefix of
/// the authoritative visible answer. When a potential JSON payload is seen,
/// the rest of the stream is held (`holdRest`) rather than guessed at; if the
/// final parse finds no tool call, the authoritative answer is emitted once
/// from `finish`.
///
/// Pure value/string logic: no MLX, no concurrency. Focused tests exercise it
/// on Linux as well as through the adapter.
struct LocalStreamFramer: Sendable {
    /// True when `payload` is recognized by the adapter's authoritative tool
    /// parser (strict JSON with an offered tool name). Injected so the framer
    /// shares the exact call-decoding rules instead of duplicating them.
    private let isToolCallPayload: @Sendable (String) -> Bool

    private enum Mode {
        /// Leading content not yet classified.
        case undecided
        /// Ordinary prose; release as it arrives except held run prefixes.
        case prose
        /// A possible/recognized tool payload (or anything after one): hold
        /// everything to the end. The adapter decides between tool requests
        /// and a single authoritative answer.
        case holdRest
        /// A "Thinking Process:" scratchpad: hold everything.
        case scratchpad
        /// Inside an open `<think ...>` block: hold until the close tag.
        case think
    }

    private var mode: Mode = .undecided
    /// Raw output not yet released or definitively withheld.
    private var pending = ""
    /// Offset in `pending` where a possible JSON payload begins, when one is
    /// currently undecided. Release stops at this offset.
    private var candidateStart: Int?
    /// Everything released as prose so far, in order.
    private(set) var emitted = ""

    init(isToolCallPayload: @escaping @Sendable (String) -> Bool) {
        self.isToolCallPayload = isToolCallPayload
    }

    /// Feeds one raw engine chunk. Returns the prose that is safe to display
    /// now (possibly empty). Reasoning and recognized tool payloads are never
    /// returned.
    mutating func ingest(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        pending += chunk
        drain()
        return releaseProse()
    }

    /// Reconciles the streamed prefix with the authoritative visible answer.
    /// Returns the part of `visibleAnswer` that has not been displayed yet —
    /// the caller emits it once, so the final answer is never duplicated.
    /// Returns nil when nothing remains or when the streamed text and the
    /// authoritative answer disagree structurally (the caller keeps the
    /// streamed prefix and logs the mismatch instead of displaying
    /// contradictory content twice).
    mutating func finish(visibleAnswer: String) -> String? {
        // Nothing displayed yet: the caller emits the whole authoritative
        // answer once. This covers whole-payload JSON that turned out to be
        // prose, legacy envelopes and scratchpad extraction.
        guard !emitted.isEmpty else {
            emitted = visibleAnswer
            return visibleAnswer.isEmpty ? nil : visibleAnswer
        }
        if visibleAnswer == emitted { return nil }
        if visibleAnswer.hasPrefix(emitted) {
            let remainder = String(visibleAnswer.dropFirst(emitted.count))
            emitted = visibleAnswer
            return remainder.isEmpty ? nil : remainder
        }
        // Whitespace-only divergence (trailing spaces were released while the
        // authoritative answer is trimmed): compare on the trailing-trimmed
        // prefix before declaring a mismatch.
        let trimmedEmitted = String(emitted.reversed().drop { $0.isWhitespace }.reversed())
        if !trimmedEmitted.isEmpty, visibleAnswer.hasPrefix(trimmedEmitted) {
            let remainder = String(visibleAnswer.dropFirst(trimmedEmitted.count))
            emitted = visibleAnswer
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    // MARK: - Classification

    private mutating func drain() {
        var progressed = true
        while progressed {
            progressed = false
            switch mode {
            case .undecided:
                progressed = classifyUndecided()
            case .prose:
                progressed = scanProse()
            case .think:
                progressed = consumeThink()
            case .holdRest, .scratchpad:
                // Held to the end by design; nothing can be released safely.
                progressed = false
            }
        }
    }

    /// Releases prose from the front of `pending`. Only called after `drain`
    /// has decided the leading region is safe prose.
    private mutating func releaseProse() -> String {
        guard mode == .prose, !pending.isEmpty else { return "" }
        var limit = pending.count
        if let candidateStart { limit = min(limit, candidateStart) }
        // Hold a trailing prefix that could still become a think tag or the
        // start of a new line that might be JSON.
        let holdback = Self.holdbackLength(in: pending)
        if holdback > 0 { limit = min(limit, pending.count - holdback) }
        guard limit > 0 else { return "" }
        let release = String(pending.prefix(limit))
        pending = String(pending.dropFirst(limit))
        if let candidateStart {
            self.candidateStart = max(0, candidateStart - limit)
        }
        emitted += release
        return release
    }

    /// Characters at the tail of `pending` that cannot be shown yet because
    /// they could begin a `<think` tag or a JSON token.
    private static func holdbackLength(in text: String) -> Int {
        var hold = 0
        let chars = Array(text)
        // A trailing `<` or partial `<think`/`</think` tag.
        for probe in 1...max(1, min(8, chars.count)) {
            let lowered = String(chars.suffix(probe)).lowercased()
            if lowered == "<" || "<think".hasPrefix(lowered) || "</think".hasPrefix(lowered) {
                hold = max(hold, probe)
            }
        }
        // A current line that begins with a JSON/fence marker and has not
        // completed yet, or with a possible think opener.
        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let currentLine = text[lineStart...].drop { $0 == " " || $0 == "\t" }
        if currentLine.hasPrefix("{") || currentLine.hasPrefix("[")
            || currentLine.hasPrefix("`") {
            hold = max(hold, text.distance(from: lineStart, to: text.endIndex))
        } else if currentLine.hasPrefix("<") {
            let verdict = thinkOpenerVerdict(String(currentLine))
            if verdict != .notOpener {
                hold = max(hold, text.distance(from: lineStart, to: text.endIndex))
            }
        }
        return hold
    }

    private enum ThinkOpenerVerdict {
        case opener
        case partial
        case notOpener
    }

    /// Whether `text` (anywhere from its start) begins a `<think ...>` opener,
    /// cannot yet be decided, or is definitively something else. Mirrors the
    /// authoritative `splitReasoning` regex: `<think` must be followed by a
    /// word boundary (whitespace, `>` or the end of the tag).
    private static func thinkOpenerVerdict(_ text: String) -> ThinkOpenerVerdict {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("<think") else {
            return "<think".hasPrefix(lowered) ? .partial : .notOpener
        }
        guard lowered.count > 6 else {
            // Exactly `<think` so far: the next character decides.
            return .partial
        }
        let next = lowered[lowered.index(lowered.startIndex, offsetBy: 6)]
        if next.isWhitespace || next == ">" {
            return .opener
        }
        return .notOpener
    }

    /// Classifies the leading undecided prefix. Returns true when the mode
    /// changed or pending advanced.
    private mutating func classifyUndecided() -> Bool {
        let trimmed = pending.drop { $0.isWhitespace }
        guard !trimmed.isEmpty else { return false }
        let text = String(trimmed)

        // Leading think opener (possibly split across chunks).
        if text.hasPrefix("<") {
            switch Self.thinkOpenerVerdict(text) {
            case .opener:
                pending = text
                mode = .think
                return true
            case .partial:
                return false
            case .notOpener:
                break
            }
        }
        let lowered = text.lowercased()
        for marker in ["thinking process:", "reasoning process:"] {
            if marker.hasPrefix(lowered), lowered.count < marker.count {
                return false
            }
        }
        if lowered.hasPrefix("thinking process:") || lowered.hasPrefix("reasoning process:") {
            pending = text
            mode = .scratchpad
            return true
        }
        if let first = text.first, first == "{" || first == "[" || first == "`" {
            pending = text
            mode = .holdRest
            return true
        }
        // Once a decisive non-marker character appears the rest is prose.
        pending = text
        mode = .prose
        return true
    }

    /// Scans prose for embedded think tags and undecided JSON payloads.
    /// Returns true when the mode changed.
    private mutating func scanProse() -> Bool {
        guard !pending.isEmpty else { return false }

        // An embedded think opener must never leak.
        var searchStart = pending.startIndex
        while let angle = pending[searchStart...].firstIndex(of: "<") {
            let rest = String(pending[angle...])
            switch Self.thinkOpenerVerdict(rest) {
            case .opener:
                let before = String(pending[..<angle])
                pending = rest
                candidateStart = nil
                if !before.isEmpty { emitted += before }
                mode = .think
                return true
            case .partial:
                // Held by holdbackLength until the next chunk decides it.
                return false
            case .notOpener:
                searchStart = pending.index(after: angle)
            }
        }

        // Undecided JSON candidate: find a marker that can start a payload.
        if candidateStart == nil {
            if let start = Self.payloadCandidateStart(in: pending) {
                candidateStart = start
            }
        }
        if let start = candidateStart, start < pending.count {
            let candidate = String(pending.dropFirst(start))
            switch classifyCandidate(candidate) {
            case .completeToolPayload:
                let before = String(pending.prefix(start))
                pending = candidate
                candidateStart = nil
                if !before.isEmpty { emitted += before }
                mode = .holdRest
                return true
            case .notPayload:
                candidateStart = nil
                return true
            case .undecided:
                return false
            }
        }
        return false
    }

    private enum CandidateVerdict {
        case completeToolPayload
        case notPayload
        case undecided
    }

    /// The first offset where a JSON/fence payload could begin. Braces count
    /// only when they are followed by a quote, a brace or whitespace-then
    /// quote — what a JSON object looks like — so ordinary prose braces stay
    /// cheap while inline envelopes are still caught.
    private static func payloadCandidateStart(in text: String) -> Int? {
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            guard char == "{" || char == "[" || char == "`" else { continue }
            if char == "`" {
                // Only a fence marker at a line start begins a payload,
                // not inline code spans.
                let atLineStart = index == 0 || chars[index - 1] == "\n"
                if atLineStart { return index }
                continue
            }
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if let next, next == "\"" || next == "{" || next == "[" || next == "}" || next == "]" {
                return index
            }
            var probe = index + 1
            while probe < chars.count, chars[probe] == " " || chars[probe] == "\n"
                || chars[probe] == "\t" {
                probe += 1
            }
            if probe < chars.count, probe > index + 1, chars[probe] == "\"" {
                return index
            }
        }
        return nil
    }

    private func classifyCandidate(_ candidate: String) -> CandidateVerdict {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .undecided }
        // Fenced payload: complete only when the closing fence arrived.
        if trimmed.hasPrefix("`") {
            if trimmed.hasSuffix("```"), trimmed.count > 3, trimmed != "```" {
                return isToolCallPayload(trimmed) ? .completeToolPayload : .notPayload
            }
            return .undecided
        }
        // Structural completeness: the first balanced JSON value (outside
        // strings) is what the authoritative parser would consume.
        guard let prefix = Self.balancedJSONPrefix(in: trimmed) else {
            return .undecided
        }
        return isToolCallPayload(prefix) ? .completeToolPayload : .notPayload
    }

    /// The prefix up to and including the first position where brace/bracket
    /// depth returns to zero, or nil while the value is still open.
    private static func balancedJSONPrefix(in text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, char) in text.enumerated() {
            if inString {
                if escaped { escaped = false; continue }
                if char == "\\" { escaped = true; continue }
                if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 {
                    let end = text.index(text.startIndex, offsetBy: offset + 1)
                    return String(text[..<end])
                }
            default: break
            }
        }
        return nil
    }

    /// Consumes an open `<think ...>` block. Returns true when the block
    /// closed and the mode returned to classification.
    private mutating func consumeThink() -> Bool {
        guard let closeRange = pending.range(
            of: "</think",
            options: [.caseInsensitive]
        ) else {
            return false
        }
        guard let tagEnd = pending.range(
            of: ">",
            options: [],
            range: closeRange.upperBound..<pending.endIndex
        ) else {
            return false
        }
        pending = String(pending[tagEnd.upperBound...])
        mode = .undecided
        return true
    }
}
