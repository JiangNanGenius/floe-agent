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
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 3)
        #expect(rig.driving.starts[2].request.text == "讲个故事")
    }
}
#endif
