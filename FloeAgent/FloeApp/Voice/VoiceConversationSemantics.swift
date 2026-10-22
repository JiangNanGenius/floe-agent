// FloeApp — Continuous voice conversation: pure turn semantics.
//
// SPDX-License-Identifier: MPL-2.0
//
// Endpointing, turn validity, barge-in gate and sentence splitting are
// settled product rules (chat-voice-tts-20261022) with NO model classifier:
// - ~900 ms of silence after the last transcript activity ends an utterance;
// - an obviously incomplete trailing phrase extends the window to ~1.6 s;
// - hesitation/noise-only text is never sent; short valid turns ("好",
//   "不对") are accepted;
// - persistent echo-processed speech (≥ ~180 ms) tentatively pauses output,
//   ~250 ms of continuous non-speech without a valid ASR turn resumes at the
//   SAME position; amplitude alone never cancels a generation.
//
// Everything here is pure Foundation and deterministic: tests drive exact
// sample durations and string inputs without any clock or audio framework.

import Foundation

// MARK: - Endpoint windows

enum VoiceConversationEndpointPolicy {
    static let baseSilence: Double = 0.9
    static let incompleteExtension: Double = 1.6

    /// Trailing tokens that make a phrase obviously unfinished. Conservative:
    /// a false positive only delays sending by ~0.7 s; the extended window
    /// still finalizes on its own timeout.
    private static let trailingConnectives: Set<String> = [
        // Chinese connectives / determiners / prepositions / auxiliaries.
        "和", "与", "或", "但", "但是", "而", "而且", "就", "还", "还有", "然后",
        "因为", "所以", "如果", "虽然", "以及", "把", "被", "给", "对", "从", "向",
        "为了", "关于", "我的", "你的", "他的", "她的", "它的", "我们的", "这个",
        "那个", "这些", "那些", "一个", "一种", "可以", "需要", "比较", "特别",
        "非常", "有点", "一些", "什么时", "为什",
        // English function words that dangle mid-phrase.
        "and", "or", "but", "so", "then", "because", "if", "although", "the",
        "a", "an", "to", "of", "in", "on", "for", "with", "that", "this",
        "these", "those", "is", "are", "was", "were", "my", "your", "his",
        "her", "our", "their", "it", "we", "you", "they", "he", "she", "at",
        "by", "as", "not",
    ]

    private static let danglingPunctuation: Set<Character> = [
        "，", ",", "、", "：", ":", "；", ";", "-", "—", "…",
    ]

    /// True when the staged text obviously trails off unfinished. Conservative:
    /// a false positive only delays sending by ~0.7 s; the extended window
    /// still finalizes on its own timeout. No model classifier by design.
    static func isProbablyIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if danglingPunctuation.contains(last) { return true }
        // Latin word boundary: last whitespace-delimited token.
        if let latinToken = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last,
           latinToken.allSatisfy({ $0.isLetter || $0.isNumber }),
           trailingConnectives.contains(latinToken.lowercased()) {
            return true
        }
        // CJK has no spaces: check the final 1-2 characters against the set.
        if trimmed.allSatisfy({ !$0.isASCII }) {
            let tail = Array(trimmed)
            return trailingConnectives.contains(String(tail.suffix(2)))
                || trailingConnectives.contains(String(tail.suffix(1)))
        }
        return false
    }

    /// Convenience window for the default timing (the coordinator applies its
    /// injected `Timing` values instead).
    static func silenceWindow(for text: String) -> Double {
        isProbablyIncomplete(text) ? incompleteExtension : baseSilence
    }
}

// MARK: - Turn validity

enum VoiceConversationTurnValidity {
    /// CJK hesitation characters: only noise when EVERY core character is one.
    private static let chineseHesitations: Set<Character> = [
        "嗯", "呃", "啊", "哦", "额", "唔", "噢", "喔", "咳", "呐", "嗨", "哈", "呵", "嘛",
    ]
    private static let latinHesitations: Set<String> = [
        "um", "ums", "uh", "uhh", "uhhh", "er", "erm", "err", "ah", "aha", "oh",
        "hmm", "hm", "mm", "mmm", "mhm", "mhmm", "haha", "hehe", "huhu", "teehee",
    ]
    private static let allowedFillerPunctuation: Set<Character> = [
        "。", "，", "、", "．", "！", "？", "：", "；", "…", "~", "～", ".", ",", "!", "?",
        ":", ";", "'", "\"", "“", "”", "‘", "’", "(", ")", "「", "」",
    ]

    /// True when the text is a sendable utterance: non-empty, and not only
    /// hesitations/punctuation. Short valid answers ("好", "不对", "5", "ok")
    /// pass; multi-word hesitation ("um uh") does not; a mixed phrase with
    /// any real token ("嗯好") does. Latin runs are kept whole so whitespace
    /// never merges two hesitation tokens into apparent content.
    static func isValidTurn(_ raw: String) -> Bool {
        var pendingASCII = ""
        var foundReal = false

        func flushASCII() {
            guard !pendingASCII.isEmpty else { return }
            if !latinHesitations.contains(pendingASCII.lowercased()) { foundReal = true }
            pendingASCII = ""
        }

        for character in raw {
            if character.isASCII, character.isLetter || character.isNumber {
                pendingASCII.append(character)
                continue
            }
            flushASCII()
            if character.isWhitespace || allowedFillerPunctuation.contains(character) {
                continue
            }
            // Non-ASCII: a known CJK hesitation, or real content (other
            // scripts and symbols count as content).
            if !chineseHesitations.contains(character) { foundReal = true }
        }
        flushASCII()
        return foundReal
    }
}

// MARK: - Barge-in persistence gate

/// Hysteresis over raw noise-gate decisions: emits one edge event when a
/// continuous speech run crosses `suspectAfter`, and one when a continuous
/// non-speech run crosses `clearAfter`. Built-in durations come from the
/// samples themselves, so tests are exact and the behavior never depends on
/// buffer sizes or wall clocks.
struct VoiceConversationBargeGate {
    var suspectAfter: Double = 0.18
    var clearAfter: Double = 0.25

    private(set) var speechRun: Double = 0
    private(set) var silenceRun: Double = 0
    private(set) var suspecting = false

    enum Edge: Equatable {
        case suspectStarted
        case cleared
        case none
    }

    mutating func process(_ level: VoiceConversationLevel) -> Edge {
        let duration = max(0, min(level.duration, 0.5))
        if level.isSpeech {
            speechRun += duration
            silenceRun = 0
        } else {
            silenceRun += duration
            speechRun = 0
        }
        if !suspecting, speechRun >= suspectAfter {
            suspecting = true
            return .suspectStarted
        }
        if suspecting, silenceRun >= clearAfter {
            suspecting = false
            return .cleared
        }
        return .none
    }

    mutating func reset() {
        speechRun = 0
        silenceRun = 0
        suspecting = false
    }
}

// MARK: - Sentence splitting

/// Splits cumulative visible answer text into TTS sentence units exactly
/// once. The bridge consumes unit requests; it must never re-split text.
/// Rules: terminate on 。！？!?；; and newlines; a period between digits is
/// decimal-safe ("3.5"); an over-long run without a boundary soft-flushes at
/// the previous comma/whitespace so TTS starts early on long answers.
struct VoiceConversationSentenceSplitter {
    static let softFlushCharacters = 512
    private let terminalASCIISet: Set<Character> = [".", "!", "?", ";"]
    private let terminalUnicodeSet: Set<Character> = ["。", "！", "？", "；", "\n"]
    private let softBreakSet: Set<Character> = ["，", ",", "、", " ", "\u{3000}"]

    private var lastCumulative = ""
    private var consumedCharacters = 0

    var consumedCount: Int { consumedCharacters }
    var consumedText: String { String(Array(lastCumulative).prefix(consumedCharacters)) }

    /// Returns the new complete units, if any, for the cumulative text.
    /// A non-prefix replacement resets the scan window (the coordinator
    /// keeps already-emitted units; this only affects future boundaries).
    mutating func feed(cumulative: String, finalize: Bool) -> [String] {
        if cumulative.hasPrefix(lastCumulative) {
            lastCumulative = cumulative
        } else if finalize, !cumulative.isEmpty {
            // Final authoritative text shorter/different than the stream:
            // trust the final when it still extends or equals consumption.
            lastCumulative = cumulative
            consumedCharacters = min(consumedCharacters, cumulative.count)
        } else {
            lastCumulative = cumulative
            consumedCharacters = 0
        }
        var units: [String] = []
        let characters = Array(lastCumulative)
        var index = consumedCharacters
        var runStart = consumedCharacters
        while index < characters.count {
            let character = characters[index]
            let isBoundary: Bool
            if terminalUnicodeSet.contains(character) {
                isBoundary = true
            } else if terminalASCIISet.contains(character) {
                // "3.5" must stay ONE unit: a decimal point is not a
                // sentence boundary (speaking "3." then "5" is wrong).
                isBoundary = !isDecimalGuard(characters, index)
            } else {
                isBoundary = false
            }
            if isBoundary {
                let segment = String(characters[runStart...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    units.append(segment)
                    runStart = index + 1
                    consumedCharacters = runStart
                } else {
                    consumedCharacters = index + 1
                    runStart = consumedCharacters
                }
            } else if index - runStart >= Self.softFlushCharacters {
                // Soft flush at the last soft break, otherwise a hard cut.
                var cut = index
                while cut > runStart, !softBreakSet.contains(characters[cut]) { cut -= 1 }
                if cut == runStart { cut = index }
                let segment = String(characters[runStart...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    units.append(segment)
                }
                consumedCharacters = cut + 1
                runStart = consumedCharacters
                index = cut
            }
            index += 1
        }
        if finalize {
            let tail = String(characters[min(runStart, characters.count)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { units.append(tail) }
            consumedCharacters = characters.count
        }
        return units
    }

    private func isDecimalGuard(_ characters: [Character], _ index: Int) -> Bool {
        guard characters[index] == ".", index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isNumber && characters[index + 1].isNumber
    }
}

// MARK: - Frame accounting

/// Converts a chunk's frames to the engine output-rate frame count used by
/// the played-progress ledger (round-to-nearest, matching AVAudioConverter's
/// practical output length within one frame).
enum VoiceConversationFrameMath {
    static func outputFrames(chunkFrames: Int, chunkSampleRate: Double, outputSampleRate: Double) -> Int {
        guard chunkFrames > 0, chunkSampleRate.isFinite, chunkSampleRate > 0,
              outputSampleRate.isFinite, outputSampleRate > 0 else { return 0 }
        return Int((Double(chunkFrames) * outputSampleRate / chunkSampleRate).rounded())
    }

    /// Joins completed sentence texts without mangling spacing: a Latin
    /// sentence ending (".!?;,") or a Latin word boundary needs one space
    /// before the next Latin run; CJK endings/punctuation attach directly.
    static func joinCompletedSentences(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let last = result.last, let first = trimmed.first else {
                result = trimmed
                continue
            }
            let latinEnd = ".!?;,".contains(last)
            let latinPair = last.isASCII && first.isASCII && last.isLetter && first.isLetter
            result += (latinEnd || latinPair) ? " " + trimmed : trimmed
        }
        return result
    }
}
