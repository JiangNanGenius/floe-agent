// FloeAppTests — Continuous voice: conservative barge-in safety (2026-10-25).
//
// SPDX-License-Identifier: MPL-2.0
//
// USER-REPORTED FAILURE this suite pins: the answer stopped while the user
// was completely silent. The confirmed mechanics are covered here with the
// deterministic virtual clock and faked stack from `VoiceConversationTests`:
//   - a tentative barge candidate pauses for AT MOST 1.2 s and then resumes
//     at the SAME position, never dropping queued units or regenerating;
//   - only a genuinely NEW valid ASR result that arrived after the candidate
//     opened can cancel; the current round's own late final/re-accumulation
//     never can (current-round-only anchoring — no cross-round blacklist);
//   - rejected ambiguous text is discarded, so a silent late partial can
//     never be auto-RE-ASKED when the round finishes naturally (zero new
//     model requests — the self-reply loop closure);
//   - played-output echo of ANY length ("好的", "你好") never confirms;
//     deliberate short interruption commands ("停", "不对", "stop") do;
//   - a slow genuine Whisper-class partial arriving after the pause resumed
//     still interrupts inside the bounded identity window;
//   - superseded candidates cannot be hijacked by late text, and sustained
//     noise/echo cannot cycle pauses endlessly (bounded strikes).
//
// These are kernel-level rules with fake I/O; real microphone/AEC behavior
// remains the primary's device acceptance.
//
// SECOND REPORT this suite also pins (2026-10-27, duplicate utterance): ONE
// spoken weather question persisted TWICE — once Simplified, once
// Traditional, with two separate answers. The recognition path re-decodes the
// whole uncommitted window, so the same speech can return later as a
// non-prefix rewrite in the other Han script; that rewrite staged as a fresh
// draft, survived the round, and the round-end re-arm auto-submitted it
// because the accumulated microphone quiet already satisfied the joint gate.
// The repair is a per-session, per-UTTERANCE pre-auto-submit idempotency
// anchor (one remembered utterance + real microphone freshness), never a
// global cross-round text blacklist: a folded-equal callback without fresh
// speech can neither cancel nor queue a turn, while a genuine repeat spoken
// after fresh microphone speech and an explicit manual/typed send stay fully
// usable. Traditional→Simplified folding exists ONLY in the comparison form;
// displayed and submitted text is untouched.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

// MARK: - Fixture

@MainActor
private enum BargeFixture {
    /// Canonical production shape: question endpoints, the ONE confirmed
    /// final body is queued and partially played (half of the first unit).
    static func startAnswer(_ rig: VoiceRig, question: String, answer: String) async {
        await rig.say(question)
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal(answer)
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 50)
        await rig.settle()
    }

    /// Two 0.1 s voiced buffers = a 0.2 s run ≥ the 0.18 s suspect window.
    static func openCandidate(_ rig: VoiceRig) async {
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        await rig.settle()
    }

    static func silence(_ rig: VoiceRig, seconds: Double = 0.3) async {
        rig.stack.yieldLevel(0, speech: false, duration: seconds)
        await rig.settle()
    }
}

// MARK: - Pure arbiter rules

@Suite("Barge-in arbiter rules")
struct VoiceBargeArbiterTests {

    @Test("Fresh different text confirms; current-question tails and echo never do")
    func decisionMatrix() {
        // Genuine new short command during an answer about something else.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "停", openedWith: "", submitted: "讲个故事",
            playedReference: "从前有座山。"
        ) == .confirm)
        // A late tail of the CURRENT round's own question: never confirms.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "怎么样", openedWith: "", submitted: "今天天气怎么样",
            playedReference: "晴。"
        ) == .rejectedStaleASR)
        // The exact current question re-accumulated wholesale: never confirms.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "今天天气怎么样", openedWith: "", submitted: "今天天气怎么样",
            playedReference: "晴。"
        ) == .rejectedStaleASR)
        // TWO-character self-playback ("好的", very common answer opening):
        // rejected at any length — no short-text floor.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "好的", openedWith: "", submitted: "讲个故事",
            playedReference: "好的，我来讲个故事。"
        ) == .rejectedOutputEcho)
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "你好", openedWith: "", submitted: "讲个故事",
            playedReference: "你好，我是今天的讲述人。"
        ) == .rejectedOutputEcho)
        // Same text NOT contained in what actually played: genuine input.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "好的", openedWith: "", submitted: "讲个故事",
            playedReference: "从前有座山。"
        ) == .confirm)
        // An explicit command is echo-exempt even when the answer says it.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "停", openedWith: "", submitted: "讲个故事",
            playedReference: "请停一下听我说。"
        ) == .confirm)
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "等一下", openedWith: "", submitted: "讲个故事",
            playedReference: "等一下再说。"
        ) == .confirm)
        // Nothing newer than the snapshot: never confirms.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "等一下", openedWith: "等一下", submitted: "讲个故事",
            playedReference: "从前有座山。"
        ) == .rejectedNotFresh)
        // Hesitation-only text is never a turn.
        #expect(VoiceConversationBargeArbiter.decide(
            staged: "嗯。", openedWith: "", submitted: "讲个故事",
            playedReference: "从前有座山。"
        ) == .rejectedInvalid)
    }

    @Test("The stale anchor is the CURRENT round only — earlier rounds stay usable")
    func staleAnchorIsCurrentRoundOnly() {
        #expect(VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
            "讲个故事", submitted: "等一下"
        ) == false)
        #expect(VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
            "等一下", submitted: "等一下"
        ) == true)
        // A command set is deliberate and normalized.
        #expect(VoiceConversationBargeArbiter.isBargeCommand("停"))
        #expect(VoiceConversationBargeArbiter.isBargeCommand("不对"))
        #expect(VoiceConversationBargeArbiter.isBargeCommand("Stop."))
        #expect(VoiceConversationBargeArbiter.isBargeCommand("hold on"))
        #expect(VoiceConversationBargeArbiter.isBargeCommand("好的") == false)
        #expect(VoiceConversationBargeArbiter.isBargeCommand("你好") == false)
    }

    @Test("Han script folds in the COMPARISON form only (2026-10-27 duplicate report)")
    func hanScriptFoldsForComparisonOnly() {
        // The reported shape: identical speech, different script — one
        // question, two recognized forms.
        let simplified = "今天天气怎么样"
        let traditional = "今天天氣怎麼樣"
        #expect(VoiceConversationBargeArbiter.normalized(traditional)
                    == VoiceConversationBargeArbiter.normalized(simplified))
        // The current-round stale anchor therefore catches a script rewrite
        // exactly like a character-identical re-accumulation.
        #expect(VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
            traditional, submitted: simplified) == true)
        #expect(VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
            "天氣怎麼樣", submitted: simplified) == true)
        #expect(VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
            "明天會下雨嗎", submitted: simplified) == false)
        // A Simplified input is byte-identical through the fold, and non-Han
        // text never enters the transform: the comparison form is a fold, not
        // a rewrite of what the user sees. Nothing here touches staged,
        // submitted or displayed text — the coordinator compares, never
        // replaces.
        #expect(VoiceConversationBargeArbiter.foldedHan(simplified) == simplified)
        #expect(VoiceConversationBargeArbiter.foldedHan("漢字") == "汉字")
        #expect(VoiceConversationBargeArbiter.foldedHan("Stop.") == "Stop.")
        #expect(VoiceConversationBargeArbiter.foldedHan("") == "")
        // Punctuation/spacing still do not break the folded identity.
        #expect(VoiceConversationBargeArbiter.normalized("今天天氣，怎麼樣？")
                    == VoiceConversationBargeArbiter.normalized("今天天气怎么样"))
    }

    @Test("The identity blocks a folded replay only while no fresh microphone speech arrived")
    func identityBlocksReplayUntilFreshSpeech() {
        var identity = VoiceConversationUtteranceIdentity()
        // Nothing submitted yet: nothing can be fenced (a session's first
        // utterance always launches).
        #expect(identity.isActive == false)
        #expect(identity.blocksAutomaticSubmit("今天天气怎么样") == false)

        identity.noteSubmit("今天天气怎么样")
        #expect(identity.isActive)
        #expect(identity.hasFreshSpeech == false)
        // Whole-utterance script flip, a growing partial, a tail and a
        // punctuation-only variant are the SAME recognized utterance.
        #expect(identity.blocksAutomaticSubmit("今天天氣怎麼樣") == true)
        #expect(identity.blocksAutomaticSubmit("今天天氣") == true)
        #expect(identity.blocksAutomaticSubmit("天氣怎麼樣") == true)
        #expect(identity.blocksAutomaticSubmit("今天天气怎么样。") == true)
        // Merged re-accumulation of the same window: also the same utterance.
        #expect(identity.blocksAutomaticSubmit("今天天气怎么样今天天气怎么样") == true)
        // Different words are a different utterance, fence or no fence.
        #expect(identity.blocksAutomaticSubmit("明天會下雨嗎") == false)
        // Empty/hesitation-only text never asserts anything.
        #expect(identity.blocksAutomaticSubmit("，。") == false)

        // REAL microphone speech releases it immediately: the same words
        // spoken again out loud stay fully usable (no history blacklist).
        identity.noteSpeech()
        #expect(identity.hasFreshSpeech)
        #expect(identity.blocksAutomaticSubmit("今天天氣怎麼樣") == false)

        // A new submit anchors the new utterance and forgets freshness.
        identity.noteSubmit("今天天气怎么样")
        #expect(identity.hasFreshSpeech == false)
        #expect(identity.blocksAutomaticSubmit("今天天氣怎麼樣") == true)
        // Session boundary / recovered failure draft: forget everything.
        identity.reset()
        #expect(identity.isActive == false)
        #expect(identity.blocksAutomaticSubmit("今天天氣怎麼樣") == false)
    }

    @Test("A rebuilt stream that re-recognizes the carried draft is not a second sentence")
    func carryReRecognitionRule() {
        // Same script and across a script flip: the rebuilt stream already
        // contains the carried words at its own start.
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(
            carry: "今天天气", in: "今天天气怎么样") == true)
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(
            carry: "今天天气", in: "今天天氣怎麼樣") == true)
        // A genuine continuation is NOT a re-recognition.
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(
            carry: "这句话没说完", in: "继续说下去") == false)
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(
            carry: "你好", in: "今天如何") == false)
        // Nothing to compare against.
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(carry: "", in: "你好") == false)
        #expect(VoiceConversationUtteranceIdentity.rerecognizesCarry(carry: "你好", in: "") == false)
    }
}

// MARK: - Coordinator: silent-user safety and bounded recovery

@MainActor
@Suite("Voice barge-in safety (deterministic clock)")
struct VoiceBargeInSafetyTests {

    @Test("Silent full playback: no pause, no cancel, no extra model request")
    func silentFullPlayback() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "念首诗", answer: "床前明月光。疑是地上霜。")
        #expect(rig.coordinator.state == .answering)

        // The user is completely silent for ~15 s of real buffers, then the
        // virtual clock jumps past every barge/endpoint window.
        for _ in 0..<50 { rig.stack.yieldLevel(0, speech: false, duration: 0.3) }
        rig.clock.advance(by: 30)
        await rig.settle(30)
        #expect(rig.stack.count("pause") == 0)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound != nil)

        // The whole answer plays out and drains honestly.
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.driving.receipts.last?.status == .completed)
        // Zero new model requests: nothing was re-asked.
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("Silent late partial of the current question: discarded, never re-asked (zero requests)")
    func silentLatePartialNeverSelfResubmits() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "今天天气怎么样", answer: "晴。转多云。")

        // A backend re-accumulation delivers the question's tail again while
        // the user is silent (no microphone audio opens any candidate).
        rig.stack.yieldTranscript("怎么样")
        await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(rig.coordinator.stagedTranscript.isEmpty)
        #expect(rig.driving.cancelled.isEmpty)

        // Natural completion must NOT schedule a new turn for the stale tail.
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        #expect(rig.coordinator.state == .listening)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("Echo candidate + late final tail: bounded pause resumes at the same position")
    func lateTailWithCandidateResumes() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "今天天气怎么样", answer: "晴。转多云。")
        let progress = rig.coordinator.playingUnitProgress

        await BargeFixture.openCandidate(rig)
        #expect(rig.coordinator.suspectingSpeech)
        #expect(rig.stack.count("pause") == 1)

        // Delayed final tail of THIS round's own question under the
        // candidate: never cancels and cannot survive as a draft.
        rig.stack.yieldTranscript("怎么样")
        await rig.settle(30)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound != nil)

        // HARD 1.2 s pause bound: resume from the SAME position, no stop.
        rig.clock.advance(by: 1.2)
        await rig.settle()
        #expect(rig.stack.count("resume") == 1)
        #expect(rig.coordinator.playingUnitProgress?.index == progress?.index)
        #expect(rig.coordinator.playingUnitProgress?.fraction == progress?.fraction)
        #expect(rig.coordinator.state == .answering)

        // Natural completion: no self-reply turn, zero new requests. A
        // completed receipt (never an interrupted one) proves the round was
        // not cancelled by any late text.
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.receipts.last?.status == .completed)
    }

    @Test("Played two-character echo (好的) never confirms and never re-asks itself")
    func playedShortEchoNeverConfirms() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // A very common answer opening: the exact two-character mirror the
        // original report produced through the AEC path.
        await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "好的，从前有座山。")
        #expect(rig.coordinator.currentSpokenText == "好的，从前有座山。")

        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("好的")
        await rig.settle(30)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound != nil)
        #expect(rig.coordinator.stagedTranscript.isEmpty)

        rig.clock.advance(by: 1.2)
        await rig.settle()
        #expect(rig.stack.count("resume") == 1)

        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.receipts.last?.status == .completed)
    }

    @Test("Genuine short commands still interrupt, even when the answer says them")
    func shortCommandsRemainUsable() async {
        for command in ["停", "不对", "stop"] {
            let rig = VoiceRig()
            await rig.coordinator.start()
            await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "请停一下听我说。")
            await BargeFixture.openCandidate(rig)
            rig.stack.yieldTranscript("讲个故事" + command)
            await rig.settle(30)
            #expect(rig.driving.cancelled.count == 1, "command \(command) must interrupt")
            #expect(rig.coordinator.state == .listening)
            #expect(rig.coordinator.stagedTranscript == command)
        }
    }

    @Test("Slow genuine ASR after the 1.2 s pause resumed still interrupts")
    func slowGenuineASRAfterResumeConfirms() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "山很高。海很远。")
        let progress = rig.coordinator.playingUnitProgress

        await BargeFixture.openCandidate(rig)
        // Whisper-class partial arrives AFTER the pause bound: the pause must
        // already have resumed at the same position...
        rig.clock.advance(by: 1.2)
        await rig.settle()
        #expect(rig.stack.count("resume") == 1)
        #expect(rig.coordinator.playingUnitProgress?.fraction == progress?.fraction)
        #expect(rig.coordinator.currentRound != nil)

        // ... and the genuinely new partial still confirms inside the
        // bounded candidate identity window.
        rig.clock.advance(by: 0.8)
        rig.stack.yieldTranscript("讲个故事等一下")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.coordinator.stagedTranscript == "等一下")
        // Real capture keeps emitting quiet buffers after speech ends.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts[1].request.text == "等一下")
    }

    @Test("Superseded candidate cannot be hijacked by late text")
    func supersededCandidateStaysFenced() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "念诗", answer: "床前明月光。疑是地上霜。")

        await BargeFixture.openCandidate(rig)
        // Past the 1.2 s pause AND the bounded identity window (4 s).
        rig.clock.advance(by: 4.5)
        await rig.settle()
        rig.stack.yieldTranscript("念诗等一下")
        await rig.settle(30)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.state == .answering)
        #expect(rig.coordinator.stagedTranscript == "等一下")

        // A NEW microphone candidate refreshes identity: identical text is
        // not newer than its snapshot...
        await BargeFixture.silence(rig)
        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("念诗等一下")
        await rig.settle(30)
        #expect(rig.driving.cancelled.isEmpty)

        // ... while genuinely extended text confirms.
        rig.stack.yieldTranscript("念诗等一下别讲了")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        // Real capture keeps emitting quiet buffers after speech ends.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts[1].request.text == "等一下别讲了")
    }

    @Test("Sustained noise/echo never cycles pauses endlessly; real speech still interrupts")
    func sustainedNoiseIsBounded() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "从前有座山。")

        // Three suspect cycles without any confirmation: only the first two
        // may pause (bounded false-start strike budget), never a loop.
        for _ in 0..<3 {
            await BargeFixture.openCandidate(rig)
            rig.clock.advance(by: 1.2)
            await rig.settle()
            await BargeFixture.silence(rig)
        }
        #expect(rig.stack.count("pause") <= 2)
        #expect(rig.stack.count("resume") <= 2)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound != nil)

        // A real utterance during the suppressed phase still cancels.
        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("讲个故事换个故事")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.coordinator.state == .listening)
    }

    @Test("Barge-in disabled: no pause and no cancel; the draft is kept for the next turn")
    func bargeDisabledNeverInterrupts() async {
        let rig = VoiceRig()
        rig.coordinator.allowBargeIn = false
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "从前有座山。")

        await BargeFixture.openCandidate(rig)
        #expect(!rig.coordinator.suspectingSpeech)
        #expect(rig.stack.count("pause") == 0)

        rig.stack.yieldTranscript("讲个故事换个")
        await rig.settle(30)
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.stagedTranscript == "换个")

        // Settled disabled-barge contract: the utterance is submitted after
        // the round ends naturally.
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        // Real capture keeps emitting quiet buffers after speech ends.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts[1].request.text == "换个")
    }

    @Test("Repeating an earlier round's exact words still interrupts (no history blacklist)")
    func earlierRoundRepeatStillInterrupts() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "讲个故事", answer: "从前有座山。")

        // Round 1 is launched by a real barge-in.
        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("等一下")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        // Real capture keeps emitting quiet buffers after speech ends.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts[1].request.text == "等一下")

        await rig.confirmFinal("山很高。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 50)
        await rig.settle()

        // Round 0's exact question, repeated during round 1's answer: not a
        // tail of THIS round's submission, so it interrupts normally.
        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("讲个故事")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 2)
        // Real capture keeps emitting quiet buffers after speech ends.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 3)
        #expect(rig.driving.starts[2].request.text == "讲个故事")
    }
}

// MARK: - Coordinator: one spoken utterance submits once (2026-10-27)

/// The duplicate-utterance report reproduced as a source-level shape: the
/// backend re-decodes the SAME uncommitted window and returns it in the other
/// Han script. Automatic paths must never launch a second run for it, while
/// fresh spoken repeats, deliberate manual sends and recovered failure drafts
/// keep working exactly as before.
@MainActor
@Suite("Voice duplicate utterance safety (deterministic clock)")
struct VoiceDuplicateUtteranceSafetyTests {

    /// One spoken Simplified question, fully answered and drained.
    private static func answerOnce(_ rig: VoiceRig) async {
        await BargeFixture.startAnswer(rig, question: "今天天气怎么样", answer: "晴。转多云。")
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
    }

    @Test("Simplified→Traditional rewrite DURING the round: one launch, no cancel, no second question")
    func scriptRewriteDuringRoundSubmitsOnce() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await BargeFixture.startAnswer(rig, question: "今天天气怎么样", answer: "晴。转多云。")
        #expect(rig.driving.starts.count == 1)

        // The same window re-decoded in the other script, while the user is
        // completely silent (no microphone level opens any candidate).
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced, "a folded rewrite of this round's own question must not survive as a draft")
        #expect(rig.driving.cancelled.isEmpty)

        // The answer drains honestly; nothing re-arms a second launch.
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.driving.receipts.last?.status == .completed)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("Rewrite AFTER the round with no new microphone speech never queues the next turn")
    func scriptRewriteAfterRoundNeverQueuesNextTurn() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.driving.starts.count == 1)

        // Late re-decode of the already-consumed speech: staging refuses to
        // arm an endpoint for it at all (the shape that persisted the second
        // question with its own answer).
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("Late partial, stream restart and final callbacks of one utterance still count one launch")
    func latePartialRestartAndFinalCallbacksCountOne() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        // (a) A growing partial of the re-decode (a folded prefix of the
        //     submitted utterance) is the same speech, not a new draft.
        rig.stack.yieldTranscript("今天天氣")
        let firstFenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(firstFenced)

        // (b) The recognition stream ends on its own and restarts IN PLACE.
        rig.stack.endTranscriptStream(failure: nil)
        let restarted = await rig.waitUntil { rig.stack.count("begin") == 2 }
        #expect(restarted)
        #expect(rig.coordinator.state == .listening)

        // (c) The rebuilt stream delivers the SAME utterance again, then one
        //     late final of it. Neither may mint a turn.
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let secondFenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(secondFenced)
        rig.stack.yieldTranscript("今天天氣怎麼樣。")
        await rig.settle()
        #expect(rig.coordinator.stagedTranscript.isEmpty)

        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("The late FINAL of an already-fenced accumulation is fenced, never staged as a bare stub")
    func fencedAccumulationFinalStaysFenced() async {
        // The exact Build302 QA defect shape without a stream restart: the
        // first fence advances the baseline past the backend's whole
        // accumulation, so the one late final of the SAME speech arrives as
        // nothing but its trailing punctuation. A punctuation stub asserts no
        // new utterance — it must be fenced synchronously against the whole
        // accumulation, never left visible as the user's draft or armed.
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil {
            recorder.count("duplicateUtteranceFenced") == 1 && rig.coordinator.stagedTranscript.isEmpty
        }
        #expect(fenced)
        #expect(recorder.count("duplicateUtteranceFenced") == 1)

        // The backend's final marker of the very same accumulation.
        rig.stack.yieldTranscript("今天天氣怎麼樣。")
        let finalFenced = await rig.waitUntil {
            recorder.count("duplicateUtteranceFenced") == 2 && rig.coordinator.stagedTranscript.isEmpty
        }
        #expect(finalFenced)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
        #expect(recorder.count("duplicateUtteranceFenced") == 2)

        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("A genuinely different utterance after fresh speech still stages and launches once")
    func substantiveExtensionAfterFreshSpeechStillUsable() async {
        // Fence-release companion of the stub rule: once real microphone
        // speech has arrived, a DIFFERENT utterance stages and auto-submits
        // exactly once no matter what the previous accumulation was fenced
        // against — the stub rule never reaches a substantive diff.
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil {
            recorder.count("duplicateUtteranceFenced") == 1 && rig.coordinator.stagedTranscript.isEmpty
        }
        #expect(fenced)

        // REAL voiced capture, then a genuinely different utterance.
        await BargeFixture.openCandidate(rig)
        rig.stack.yieldTranscript("明天會下雨嗎")
        let staged = await rig.waitUntil { rig.coordinator.stagedTranscript == "明天會下雨嗎" }
        #expect(staged, "fresh speech must stage a different utterance normally")
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "明天會下雨嗎")
    }

    @Test("A genuine same-words repeat after fresh microphone speech submits exactly once")
    func genuineRepeatAfterFreshSpeechSubmitsOnce() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        // REAL voiced capture: the user says the question again out loud.
        await BargeFixture.openCandidate(rig)
        // The cumulative backend re-accumulates the repeat beyond the frozen
        // baseline, so the extension is the staged draft.
        rig.stack.yieldTranscript("今天天气怎么样今天天气怎么样")
        let staged = await rig.waitUntil { rig.coordinator.stagedTranscript == "今天天气怎么样" }
        #expect(staged, "fresh speech must keep the same words fully usable")

        // It goes out ONCE (joint quiet gate satisfied by real silence).
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "今天天气怎么样")

        // And the second utterance is now the anchored one: a folded rewrite
        // of it, with no further speech, is fenced again.
        await rig.confirmFinal("多云。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        rig.stack.yieldTranscript("今天天氣怎麼樣今天天氣怎麼樣")
        let refenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(refenced)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
    }

    @Test("Typed submit of the identical words is deliberate intent and launches")
    func typedIdenticalSubmitIsDeliberateIntent() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        // Same words, no microphone speech at all — but TYPED by the user:
        // the automatic replay fence never applies to deliberate input.
        #expect(await rig.coordinator.submitText("今天天气怎么样") == true)
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "今天天气怎么样")

        // The typed launch re-anchors, so a late folded rewrite of it is
        // fenced again instead of minting a third turn.
        await rig.confirmFinal("晴。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
    }

    @Test("A level queued while MUTED never releases the replay fence")
    func mutedLateLevelKeepsTheFenceArmed() async {
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        // Mute stops physical collection; a voiced buffer still queued from
        // the capture that just stopped is NOT fresh user speech.
        await rig.coordinator.setMuted(true)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.2)
        await rig.settle()

        // Unmuted, the same utterance arrives again as a re-decode: nothing
        // was heard, so the fence still holds and the endpoint is never armed.
        await rig.coordinator.setMuted(false)
        rig.stack.yieldTranscript("今天天氣怎麼樣。")
        let fenced = await rig.waitUntil { recorder.contains("duplicateUtteranceFenced") && rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced, "a muted level must not claim fresh speech for the auto-submit anchor")
        #expect(recorder.contains("duplicateUtteranceFenced"))
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("A muted rewrite survives as the user's draft; send-now accepts it")
    func mutedDraftSurvivesAndManualSendNowAcceptsIt() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        // Mute contract: no hidden capture, no auto-submit, but the draft is
        // the user's and survives.
        await rig.coordinator.setMuted(true)
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        await rig.settle()
        #expect(rig.coordinator.stagedTranscript == "今天天氣怎麼樣")
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1, "a muted draft is never auto-submitted")

        // Unmute arms nothing automatically (the fence would block it), and
        // the explicit send-now IS the deliberate intent: it launches once.
        await rig.coordinator.setMuted(false)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        rig.coordinator.sendNow()
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "今天天氣怎麼樣")
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("A pre-launch failure keeps the recovered draft retryable (once)")
    func failedLaunchKeepsDraftRecoverable() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("今天天气怎么样")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        guard let token = rig.coordinator.currentRound else { return }

        // The run never reached the model: the user's words are handed back
        // and must not be swallowed by the replay fence.
        rig.driving.emit(token, .failed(message: "provider busy"))
        let restored = await rig.waitUntil {
            rig.coordinator.stagedTranscript == "今天天气怎么样" && rig.coordinator.state == .listening
        }
        #expect(restored, "a pre-launch failure restores the draft")
        #expect(rig.driving.starts.count == 1)

        // The recovered draft goes out exactly once more (no double launch).
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "今天天气怎么样")

        // From that launch on the fence is armed again: a folded rewrite with
        // no new speech cannot add a third turn.
        await rig.confirmFinal("晴。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 150)
        await rig.settle(30)
        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil { rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced)
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
    }

    @Test("A new session generation is never fenced by the previous session's utterance")
    func newSessionSubmitsTheSameWordsAgain() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("今天天气怎么样")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)

        rig.coordinator.end()
        let ended = await rig.waitUntil { rig.coordinator.state == .idle }
        #expect(ended)

        // Deliberately the SAME words in a NEW session: the anchor is
        // per-session identity, never a global cross-round text blacklist.
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .listening)
        await rig.say("今天天气怎么样")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts.last?.request.text == "今天天气怎么样")
    }

    @Test("The fence names itself in the counts-only diagnostics (never silent)")
    func fenceIsDiagnosable() async {
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()
        await Self.answerOnce(rig)
        #expect(rig.driving.starts.count == 1)

        rig.stack.yieldTranscript("今天天氣怎麼樣")
        let fenced = await rig.waitUntil { recorder.contains("duplicateUtteranceFenced") && rig.coordinator.stagedTranscript.isEmpty }
        #expect(fenced)
        #expect(recorder.contains("duplicateUtteranceFenced"))
        // One launch, one fence line: the second question never existed.
        #expect(recorder.count("duplicateUtteranceFenced") == 1)
        #expect(rig.driving.starts.count == 1)
    }
}
#endif
