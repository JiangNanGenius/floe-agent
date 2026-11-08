// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The hosted DeepSeek/Ark Chat APIs return native `tool_calls`, not commands
/// embedded in assistant content (api-docs.deepseek.com/guides/tool_calls/).
/// Hold split DSML prefixes before publication and reject naked protocol text.
/// This scanner NEVER reads a function name/argument or constructs a ToolCall.
/// It is fed only the selected provider's assistant content, never history,
/// user messages, reasoning or tool results. Markdown source quotes stay text.
struct DeepSeekAssistantProtocolGuard: Sendable {
    struct Output: Sendable, Equatable {
        var text: String
        /// True exactly once per response, including a truncated DSML prefix.
        var rejected: Bool
    }

    private static let markers = ["<｜DSML｜", "</｜DSML｜", "<|DSML|", "</|DSML|"]
    let enabled: Bool
    private(set) var isRejected = false
    private var held = ""
    var hasHeldProtocolPrefix: Bool { held.contains("DSML") }
    private var fence: (mark: Character, count: Int)?
    private var inlineTicks: Int?
    private var runMark: Character?
    private var runCount = 0
    private var runAtStart = false
    private var atStart = true
    private var indentation = 0
    private var quotedLine = false
    private var closingFence = false
    private var escaped = false

    init(enabled: Bool) { self.enabled = enabled }

    mutating func consume(_ text: String) -> Output {
        guard enabled else { return .init(text: text, rejected: false) }
        guard !isRejected else { return .init(text: "", rejected: false) }
        var output = ""
        for character in text {
            accept(character, into: &output)
            if isRejected { break }
        }
        return .init(text: output, rejected: isRejected)
    }

    mutating func finish() -> Output {
        guard enabled, !isRejected else { return .init(text: "", rejected: false) }
        // A truncated machine identifier must not be published at EOF.
        if held.contains("DSML") {
            held = ""; isRejected = true
            return .init(text: "", rejected: true)
        }
        let remainder = held; held = ""
        return .init(text: remainder, rejected: false)
    }

    private mutating func accept(_ character: Character, into output: inout String) {
        if !held.isEmpty {
            let candidate = held + String(character)
            if Self.markers.contains(candidate) {
                held = ""; isRejected = true; return
            }
            if Self.markers.contains(where: { $0.hasPrefix(candidate) }) {
                held = candidate; return
            }
            // The held prefix contains no Markdown delimiter. Replay it as
            // literal text, then reconsider this character (which may be '<').
            let literal = held; held = ""
            for value in literal { emit(value, into: &output) }
        }
        finishRun(before: character)
        if character == "<", fence == nil, inlineTicks == nil,
           !quotedLine, indentation < 4, !escaped {
            held = "<"; return
        }
        emit(character, into: &output)
    }

    private mutating func finishRun(before next: Character) {
        guard let mark = runMark, next != mark else { return }
        if let fence {
            if runAtStart, mark == fence.mark, runCount >= fence.count { closingFence = true }
        } else if mark == "`", let ticks = inlineTicks {
            if runCount == ticks { inlineTicks = nil }
        } else if runAtStart, !quotedLine, indentation < 4, runCount >= 3 {
            fence = (mark, runCount)
        } else if mark == "`" { inlineTicks = runCount }
        runMark = nil; runCount = 0
    }

    private mutating func emit(_ character: Character, into output: inout String) {
        output.append(character)
        if character == "\n" {
            finishRun(before: character)
            if closingFence { fence = nil }
            atStart = true; indentation = 0; quotedLine = false
            closingFence = false; escaped = false
            return
        }
        if character == " " || character == "\t" {
            if atStart { indentation += character == "\t" ? 4 : 1 }
            escaped = false
            return
        }
        if closingFence { closingFence = false }
        if escaped { escaped = false; atStart = false; return }
        if character == "\\" { escaped = true; atStart = false; return }
        if atStart, character == ">" { quotedLine = true }
        if character == "`" || (character == "~" && (atStart || runMark == "~")) {
            if runMark == character { runCount += 1 }
            else { runMark = character; runCount = 1; runAtStart = atStart }
        }
        atStart = false
    }
}
