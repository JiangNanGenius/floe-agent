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

// MARK: - End-of-utterance gate (short-speech flush)

/// Pure voice-activity tracker behind the transcription backends' END-OF-
/// UTTERANCE FLUSH decision. Chunked local recognizers (Whisper path) decode
/// on fixed windows; without this gate a SHORT utterance ("你好", ~1 s) that
/// ends before the next 3 s boundary — or quiet speech under the coarse
/// energy gate — never produces a staged transcript, so the conversation
/// endpoint never fires and "speaking does nothing".
///
/// The gate observes the REAL converted audio energy per appended buffer:
/// once at least `voicedSamplesRequired` samples of speech-like energy have
/// accumulated AND the tail has been quiet for `silenceTailSamplesRequired`
/// samples (the utterance ended), `shouldFlush` asks the decode loop to run
/// the window immediately, even below the regular chunk boundary. Pure
/// Foundation + deterministic counts — host tests drive exact sample runs.
struct VoiceConversationUtteranceGate: Sendable, Equatable {
    /// 16 kHz domain thresholds.
    var sampleRate: Int = 16_000
    /// Speech-like tail energy: RMS at/above this counts a buffer as voiced.
    /// Deliberately below the display noise gate so quiet speakers still
    /// count; the decode-side energy gate still skips pure silence.
    var voicedRMS: Float = 0.002
    /// Minimum voiced samples inside the pending region before a flush is
    /// meaningful (~0.5 s at 16 kHz).
    var voicedSamplesRequired: Int = 8_000
    /// Trailing quiet samples that mark the utterance as ended (~0.5 s).
    var silenceTailSamplesRequired: Int = 8_000

    private(set) var voicedSamplesSinceDecode = 0
    private(set) var silenceTailSamples = 0

    /// One converted buffer observed at the append point (tap thread, under
    /// the caller's lock). `rms` is the buffer's measured RMS, `samples` its
    /// frame count in the recognizer's domain rate.
    mutating func process(rms: Float, samples: Int) {
        guard samples > 0 else { return }
        if rms.isFinite, rms >= voicedRMS {
            voicedSamplesSinceDecode += samples
            silenceTailSamples = 0
        } else {
            silenceTailSamples += samples
        }
    }

    /// True when a REAL utterance appears to have just ended: enough voiced
    /// audio pending and a quiet tail. Pure silence never flushes (silence is
    /// legitimate; flushing it would only burn inference on nothing).
    var shouldFlush: Bool {
        voicedSamplesSinceDecode >= voicedSamplesRequired
            && silenceTailSamples >= silenceTailSamplesRequired
    }

    /// The pending region's minimum duration for a VAD flush decode.
    var minimumFlushSamples: Int { voicedSamplesRequired }

    /// A decode consumed the window up to the current tail: both runs restart
    /// from zero so the same utterance is never flushed twice in a row.
    mutating func noteDecoded() {
        voicedSamplesSinceDecode = 0
        silenceTailSamples = 0
    }

    mutating func reset() { noteDecoded() }
}

// MARK: - Bounded drain race

/// Exactly-once resolution for a drain/deadline race. Three events compete —
/// operation completion, deadline elapse and caller cancellation — and only
/// the FIRST one to write is recorded; every later event is ignored. A drain
/// released after its deadline therefore can never complete the race twice.
/// Foundation-only (one NSLock, no clock, no frameworks), so the pure gate
/// and the async race below are deterministic and host-testable.
final class VoiceConversationDrainGate: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        /// The drain finished before the deadline.
        case completed
        /// The deadline fired first. The drain was cancellation-requested
        /// (best effort) and then ABANDONED — it is never awaited.
        case deadline
        /// The awaiting task was cancelled (e.g. a cancelled start). The
        /// race resolves promptly; a noncooperative drain is abandoned
        /// exactly like the deadline case.
        case cancelled
    }

    private let lock = NSLock()
    private var settled: Outcome?

    /// True only for the FIRST event; later events return false and change
    /// nothing.
    @discardableResult
    func resolve(_ candidate: Outcome) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard settled == nil else { return false }
        settled = candidate
        return true
    }

    var outcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }
}

/// Real bounded join for engines whose PHYSICAL stop already ran
/// synchronously: races an unstructured drain task against a deadline and
/// returns without ever awaiting the loser.
enum VoiceConversationBoundedDrain {
    /// Runs `operation` in an UNSTRUCTURED task and resumes the caller with
    /// the first of: completion, `seconds` elapsing, caller cancellation.
    ///
    /// This replaces a `withTaskGroup { addTask(op); addTask(sleep);
    /// group.next(); cancelAll() }` race, which is NOT bounded: a structured
    /// group scope cannot exit until EVERY child ends, `cancelAll` only sets
    /// a flag, and a drain parked on `oldTask.value` — a TTS/dictation
    /// finalization that never checks cancellation — blocks the parent
    /// forever, so "Connecting…" could stay unbounded behind one. Here the
    /// loser is cancelled and abandoned instead of awaited; resolution goes
    /// through one exactly-once gate, so a late release cannot resume the
    /// caller again, and the services' own identity fences (`isCurrent`
    /// generation tokens, the captured older session id passed to
    /// `endSession`) keep an abandoned tail from touching the new owner.
    ///
    /// Contract: `operation` must perform its synchronous physical stop
    /// BEFORE its first suspension (SpeechService.stop and
    /// VoiceInputController.stop do), so abandoning it mid-drain never leaves
    /// the old engine holding a live microphone or playback owner.
    @discardableResult
    static func race(
        seconds: Double,
        operation: @escaping @Sendable () async -> Void
    ) async -> VoiceConversationDrainGate.Outcome {
        let link = DrainLink()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<VoiceConversationDrainGate.Outcome, Never>) in
                // false: the caller was already cancelled during handler
                // registration; the continuation was resumed with .cancelled.
                guard link.attach(continuation) else { return }
                let operationTask = Task {
                    await operation()
                    link.settle(.completed)
                }
                let nanoseconds = DrainLink.deadlineNanoseconds(seconds)
                let deadlineTask = Task {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    if Task.isCancelled {
                        // Cancelled because the operation won or the caller
                        // went away; the gate keeps the first answer.
                        link.settle(.cancelled)
                    } else {
                        link.settle(.deadline)
                    }
                }
                link.install(operation: operationTask, deadline: deadlineTask)
            }
        } onCancel: {
            link.cancelChildrenAndSettle(.cancelled)
        }
    }

    /// Lock-protected wiring between the exactly-once gate and the awaiting
    /// continuation. Events may arrive from any task/thread, including caller
    /// cancellation BEFORE the continuation is attached or BEFORE the child
    /// tasks exist; whichever path first wins the gate resumes EXACTLY once
    /// and cancellation-requests the other children (never awaits them).
    private final class DrainLink: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = VoiceConversationDrainGate()
        private var continuation: CheckedContinuation<VoiceConversationDrainGate.Outcome, Never>?
        private var operationTask: Task<Void, Never>?
        private var deadlineTask: Task<Void, Never>?

        static func deadlineNanoseconds(_ seconds: Double) -> UInt64 {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return UInt64(min(seconds, 3_600) * 1_000_000_000)
        }

        /// Returns false when the race had already settled (caller cancelled
        /// during registration): the continuation was resumed immediately.
        func attach(_ continuation: CheckedContinuation<VoiceConversationDrainGate.Outcome, Never>) -> Bool {
            lock.lock()
            if let settled = gate.outcome {
                lock.unlock()
                continuation.resume(returning: settled)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func install(operation: Task<Void, Never>, deadline: Task<Void, Never>) {
            lock.lock()
            operationTask = operation
            deadlineTask = deadline
            let settled = gate.outcome != nil
            lock.unlock()
            if settled {
                operation.cancel()
                deadline.cancel()
            }
        }

        func settle(_ outcome: VoiceConversationDrainGate.Outcome) {
            lock.lock()
            guard gate.resolve(outcome) else { lock.unlock(); return }
            let pending = continuation
            continuation = nil
            var losers: [Task<Void, Never>] = []
            switch outcome {
            case .completed:
                if let deadlineTask { losers.append(deadlineTask) }
            case .deadline:
                if let operationTask { losers.append(operationTask) }
            case .cancelled:
                if let operationTask { losers.append(operationTask) }
                if let deadlineTask { losers.append(deadlineTask) }
            }
            lock.unlock()
            losers.forEach { $0.cancel() }
            pending?.resume(returning: outcome)
        }

        func cancelChildrenAndSettle(_ outcome: VoiceConversationDrainGate.Outcome) {
            lock.lock()
            let children = [operationTask, deadlineTask].compactMap { $0 }
            lock.unlock()
            children.forEach { $0.cancel() }
            settle(outcome)
        }
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
