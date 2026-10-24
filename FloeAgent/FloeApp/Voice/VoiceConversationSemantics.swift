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
//   SAME position; amplitude alone never cancels a generation. The tentative
//   PAUSE is additionally bounded by a hard 1.2 s window (product decision
//   2026-10-25 after reports of the answer stopping while the user was
//   silent): without a valid confirmation the pause ends inside the window
//   at the SAME position, and a bounded number of false-start pauses per
//   round keeps sustained noise/echo from ever entering pause cycles. The
//   audio candidate's IDENTITY stays open longer so a genuinely slow real
//   ASR partial can still confirm after the pause resumed; see
//   `VoiceConversationBargeArbiter` for the confirmation rules.
//
// Turn rules are deterministic Foundation logic. Sentence grouping reuses
// the shared provider policy; host harnesses can compile TextSegmenter.swift
// alongside this file without loading any model or audio framework.

import Foundation
#if canImport(FloeProviders)
import FloeProviders
#endif

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

// MARK: - Barge-in confirmation arbiter

/// The verdict for one staged draft observed while a barge-in audio candidate
/// is open. Only `.confirm` may cancel the answer; every rejection keeps the
/// generation alive (the candidate itself has already done nothing more than
/// pause the output).
enum VoiceBargeConfirmDecision: Equatable, Sendable {
    case confirm
    /// Not a sendable utterance (hesitation/noise-only text).
    case rejectedInvalid
    /// Nothing new: identical to the draft snapshot taken when the current
    /// candidate opened — pre-candidate text alone never confirms.
    case rejectedNotFresh
    /// The text equals or is the tail of the CURRENT round's own submitted
    /// utterance: ambiguous with a late final, so it neither auto-cancels
    /// nor survives as a draft that could be auto-resent.
    case rejectedStaleASR
    /// The text mirrors speech that actually played (or is playing): output
    /// echo, not user intent. Discarded — a mirror of our own answer must
    /// neither cancel it nor come back as a fresh question.
    case rejectedOutputEcho
}

/// Settled conservative confirmation rules for an automatic barge-in
/// interruption (product decision 2026-10-25, after field reports of the
/// answer stopping while the user was completely silent).
///
/// A confirmed automatic interruption requires ALL of:
/// 1. persistent microphone speech — a `VoiceConversationBargeGate` edge
///    opened (or refreshed) the audio candidate; AND
/// 2. a genuinely NEW valid ASR result that arrived after this candidate
///    started: text different from the draft snapshot taken when the
///    candidate opened; AND
/// 3. the text is not just the tail of the CURRENT round's submitted
///    utterance (a late final/re-accumulation of what this answer was asked
///    with can never cancel this answer); AND
/// 4. the text is not a mirror of the speech that actually played (output
///    echo through the imperfect AEC path).
///
/// BOUNDED-CONSERVATIVE by design (explicit, honest limits):
/// - Amplitude alone never confirms, and similarity alone only ever REJECTS.
/// - NO cross-round history of any kind: every rule is anchored to the
///   CURRENT round's own submitted text and the CURRENT round's actually
///   played reference. Repeating the previous round's words is new text for
///   this round and confirms normally — there is no multi-round blacklist.
/// - Provenance cannot be established from strings when the user speaks
///   EXACTLY (or the tail of) the current round's own question: that shape
///   is indistinguishable from a late final of that utterance. Bounded
///   resolution (primary-settled 2026-10-25): for THIS round it neither
///   auto-cancels NOR auto-resends — the draft is discarded so a silent
///   late partial can never re-ask the old question after the answer
///   finishes. Any genuinely new words are a different shape, stage
///   normally, and confirm/interrupt as usual; the same words are fully
///   usable again the moment the round is over.
/// - The same rule applies to text arriving OUTSIDE a candidate: a late
///   re-accumulation of the current question or a mirror of the played
///   answer must not survive as a draft that the natural endpoint would
///   auto-send (the silent self-reply loop). This is a staging fence, so it
///   cannot rely on an audio edge; the constraint is explicit, not a claim
///   that string identity proves provenance.
/// - Output echo rejects at ANY text length: a two-character ASR mirror of
///   self-playback ("好的", "你好") is exactly the reported silent shape.
///   Deliberate interruption commands (`bargeCommands`) are exempt from the
///   echo rule so real short instructions keep working even when the answer
///   says the same characters. Residual, explicitly accepted ambiguity:
///   echo of a command word spoken BY the answer can still confirm (intent
///   priority), and a genuine short utterance that is contained in the
///   played answer is treated as echo and dropped.
/// - Slow real recognition stays usable: the coordinator keeps the candidate
///   identity open past its 1.2 s pause bound for a bounded freshness
///   window; snapshot comparison is punctuation-free, so incremental
///   replacement of the same utterance still counts as new text.
enum VoiceConversationBargeArbiter {
    /// Deliberate, bounded spoken-interruption command set (product-settled
    /// 2026-10-25). These are IMPERATIVE instructions whose user intent is
    /// the interruption itself, so the echo rule NEVER swallows them — a
    /// real user can still stop an answer that happens to contain the same
    /// characters. Everything not on this list is judged against the
    /// actually-played reference, at ANY length: a two-character ASR mirror
    /// of self-playback ("好的", "你好") is exactly the shape the reported
    /// silent self-interruption took (very common answer openings), so
    /// short conversational text is NOT automatically treated as intent.
    /// Stored normalized; deterministic and easy to extend.
    static let bargeCommands: Set<String> = [
        // Chinese stop/correction instructions.
        "停", "停停", "停止", "暂停", "先停", "停一下", "别说了", "别讲了",
        "别说话", "先别讲", "先别说", "等等", "等一下", "慢点", "慢一点",
        "不对", "错", "重来",
        // English equivalents (normalized: lowercase, letters/digits only).
        "stop", "wait", "pause", "holdon", "enough",
    ]

    /// True for the deliberate command set (compared in normalized form).
    static func isBargeCommand(_ text: String) -> Bool {
        bargeCommands.contains(normalized(text))
    }

    /// Comparison form: casefolded, with only letters/digits kept. ASR
    /// partials and the played text differ in punctuation and spacing; they
    /// do NOT differ in the spoken characters themselves.
    static func normalized(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    /// True when `text` equals or is the tail of the CURRENT round's own
    /// submitted utterance: the one shape that is genuinely ambiguous
    /// between "late accumulation of what this answer was asked with" and
    /// "user repeated their exact words" — and the ambiguous direction is
    /// the reported silent self-interruption, so it never confirms.
    /// Anchored to the single current utterance on purpose: no history, so
    /// the same words are fully usable again in any later round.
    static func matchesCurrentSubmissionTail(_ text: String, submitted: String) -> Bool {
        let current = normalized(text)
        let old = normalized(submitted)
        guard !current.isEmpty, !old.isEmpty else { return false }
        return old.hasSuffix(current)
    }

    /// True when `text` mirrors the speech that actually played / is playing:
    /// output echo through the (imperfect) AEC path, not user intent. ANY
    /// contained text rejects confirmation at ANY length — deliberate
    /// commands are the only exemption (`isBargeCommand`). Echo can ONLY
    /// reject; containment never itself proves user intent.
    static func isOutputEcho(_ text: String, playedReference: String) -> Bool {
        let current = normalized(text)
        let reference = normalized(playedReference)
        guard !current.isEmpty, !reference.isEmpty else { return false }
        if isBargeCommand(text) { return false }
        return reference.contains(current)
    }

    /// The single confirmation rule set, pure and deterministic.
    static func decide(
        staged candidateText: String,
        openedWith snapshot: String,
        submitted: String,
        playedReference: String
    ) -> VoiceBargeConfirmDecision {
        let trimmed = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceConversationTurnValidity.isValidTurn(trimmed) else { return .rejectedInvalid }
        let current = normalized(trimmed)
        guard !current.isEmpty, current != normalized(snapshot) else { return .rejectedNotFresh }
        if matchesCurrentSubmissionTail(trimmed, submitted: submitted) {
            return .rejectedStaleASR
        }
        if isOutputEcho(trimmed, playedReference: playedReference) { return .rejectedOutputEcho }
        return .confirm
    }
}

// MARK: - Sentence splitting

/// Adapts cumulative answer text to the same whole-sentence policy used by
/// ordinary read-aloud. No punctuation or length rule is duplicated here.
struct VoiceConversationSentenceSplitter {
    private var lastCumulative = ""
    private var consumedCharacters = 0

    var consumedCount: Int { consumedCharacters }
    var consumedText: String { String(lastCumulative.prefix(consumedCharacters)) }

    mutating func feed(cumulative: String, finalize: Bool) -> [String] {
        if cumulative.hasPrefix(lastCumulative) {
            lastCumulative = cumulative
        } else if finalize, !cumulative.isEmpty {
            lastCumulative = cumulative
            consumedCharacters = min(consumedCharacters, cumulative.count)
        } else {
            lastCumulative = cumulative
            consumedCharacters = 0
        }
        // Re-scan only the unconsumed suffix, preserving the existing
        // cumulative-replacement behavior without re-emitting spoken units.
        let remaining = String(lastCumulative.dropFirst(consumedCharacters))
        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        var units = segmenter.append(remaining)
        if finalize { units += segmenter.finish() }
        consumedCharacters = lastCumulative.count - segmenter.pendingCharacterCount
        return units
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
