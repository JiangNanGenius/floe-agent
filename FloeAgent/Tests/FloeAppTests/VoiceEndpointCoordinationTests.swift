// FloeAppTests — Continuous voice: endpoint co-gating on REAL microphone
// quiet (2026-10-25 premature-submit repair).
//
// SPDX-License-Identifier: MPL-2.0
//
// USER-REPORTED FAILURE this suite pins: "sometimes the app submits halfway
// through while I am STILL speaking". The settled source facts: the endpoint
// timer was armed 0.9/1.6 s from the last ASR PARTIAL and consults only
// state/mute/validity — a Whisper-slow frozen partial auto-submitted even
// though the microphone was measurably still voiced (`consume(level)` never
// reached the endpoint timer).
//
// Contract verified here with the deterministic rig from VoiceConversationTests
// and EXPLICIT true/false `VoiceConversationLevel` sequences (the rig's
// `say()` intentionally emits transcripts only; existing level-less tests keep
// their original latency):
//   - frozen partial + continuing voiced capture → NEVER auto-submits;
//   - the SAME armed 0.9/1.6 window is the required REAL quiet window
//     (no separate shorter quiet constant), released event-driven exactly once;
//   - voiced samples seen BEFORE a late partial still block: a re-arm with no
//     new samples is never proof of quiet;
//   - an incomplete utterance needs its full 1.6 s of real quiet, so a brief
//     quiet pause never submits it;
//   - a valid short turn with real quiet keeps the ORIGINAL 0.9 s latency and
//     produces zero deferrals (no blanket timeout bump);
//   - sustained voice escalates through the EXISTING recognition-health bound
//     (8 s voiced-without-text), never through a forced submit;
//   - a newer partial during a deferral re-arms the full window (quiet alone
//     never short-circuits transcript stability);
//   - sendNow / typed submit bypass as before, exactly once;
//   - mute fences the deferral and positive→quiet frames after unmute never
//     revive the PRE-MUTE draft without NEW transcript activity;
//   - scene pause fences the deferral; the explicit resume prefix keeps its
//     intentional re-arm (and ongoing voice still defers).

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

// MARK: - Diagnostics recorder

/// Counts diagnostic CODES only (never detail content) so the bounded
/// transition-only deferral line is observable without parsing logs.
final class EndpointDiagnosticRecorder: VoiceConversationDiagnostics, @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String] = []

    func voiceConversation(_ code: String, _ detail: String) {
        lock.withLock { codes.append(code) }
    }

    func count(_ code: String) -> Int {
        lock.withLock { codes.filter { $0 == code }.count }
    }

    func contains(_ code: String) -> Bool {
        lock.withLock { codes.contains(code) }
    }
}

@MainActor
@Suite("Voice endpoint co-gating (real quiet + transcript stability)")
struct VoiceEndpointCoordinationTests {

    @Test("Frozen partial while the mic is voiced never auto-submits; real quiet releases exactly once")
    func frozenPartialHoldsUntilRealQuiet() async {
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()
        await rig.say("帮我查一下明天的天气")

        // The partial freezes (Whisper-slow) while capture stays VOICED.
        for _ in 0..<8 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.1) }
        rig.stack.yieldLevel(0.62, speech: true, duration: 0.1)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.62 })

        // The transcript window expires DURING ongoing speech.
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)                       // never submit into voice
        #expect(rig.coordinator.state == .listening)
        #expect(rig.coordinator.stagedTranscript == "帮我查一下明天的天气")
        #expect(recorder.count("endpointDeferredVoiced") == 1)     // transition-only line

        // More speech and time: still no forced submit, still one line.
        for _ in 0..<8 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.1) }
        rig.stack.yieldLevel(0.63, speech: true, duration: 0.1)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.63 })
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        #expect(recorder.count("endpointDeferredVoiced") == 1)

        // 0.5 s of silence is still SHORT of the SAME armed 0.9 s window
        // (the joint rule is the original window, not a shorter invented one).
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        // 0.75 s: still not enough.
        rig.stack.yieldLevel(0.01, speech: false, duration: 0.25)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        // 1.0 s of continuous quiet crosses the joint 0.9 s window: the
        // release is EVENT-DRIVEN (no further clock advance) and commits the
        // frozen text once.
        rig.stack.yieldLevel(0.01, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.driving.starts.count == 1 })
        #expect(rig.driving.starts[0].request.text == "帮我查一下明天的天气")

        // A released deferral can never double-commit.
        for _ in 0..<6 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(recorder.count("endpointDeferredVoiced") == 1)
    }

    @Test("A valid short turn with genuine quiet keeps the original latency and zero deferrals")
    func shortTurnKeepsOriginalLatency() async {
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()

        // Real utterance shape: voiced run, sustained quiet, then the
        // (late) Whisper partial — the common production ordering.
        for _ in 0..<3 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        for _ in 0..<6 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        rig.stack.yieldLevel(0.02, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.02 })

        await rig.say("好")
        rig.clock.advance(by: 0.95)              // the ORIGINAL 0.9 s window
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "好")
        #expect(!recorder.contains("endpointDeferredVoiced"))   // zero added latency
    }

    @Test("Sustained voice never force-submits; the EXISTING health bound stays visible")
    func sustainedVoiceBoundedByHealthOnly() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("先看一下")

        // Ten seconds of voiced capture with no new recognition: the
        // deferral must not fabricate a submit, reset the health clocks or
        // hang — the settled 8 s voiced-without-text failure escalates.
        for index in 0..<40 {
            rig.stack.yieldLevel(index == 39 ? 0.69 : 0.6, speech: true, duration: 0.25)
        }
        #expect(await rig.waitUntil {
            if case .failed = rig.coordinator.state { return true }
            return false
        })
        guard case .failed(let failure) = rig.coordinator.state else { return }
        #expect(failure == .recognizerFailed)
        #expect(rig.driving.starts.isEmpty)

        // Fenced with the failure: quiet frames and time never submit.
        for _ in 0..<6 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
    }

    @Test("sendNow bypasses a voiced deferral exactly once")
    func manualSendBypassesDeferral() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("换个说法")
        for _ in 0..<6 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        rig.stack.yieldLevel(0.68, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.68 })
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // deferred

        rig.coordinator.sendNow()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "换个说法")

        // The fenced deferral must not double-commit after the manual send.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("Mute fences the deferral; unmuted levels alone never revive the pre-mute draft")
    func muteFencesDeferralAndUnmuteNeedsNewText() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("旧草稿")
        for _ in 0..<6 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        rig.stack.yieldLevel(0.66, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.66 })
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // deferral active

        await rig.coordinator.setMuted(true)
        await rig.settle()
        await rig.coordinator.setMuted(false)
        await rig.settle()
        #expect(rig.coordinator.stagedTranscript == "旧草稿")

        // Settled mute contract: ONLY new transcript activity continues
        // automatic endpointing for the pre-mute draft. Positive→quiet mic
        // frames alone (real capture level sequences) must never schedule or
        // send it.
        for _ in 0..<2 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        for _ in 0..<8 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        rig.stack.yieldLevel(0.04, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.04 })
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        #expect(rig.coordinator.stagedTranscript == "旧草稿")

        // New transcript restores the normal endpoint exactly.
        await rig.say("旧草稿，再说一句")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "旧草稿，再说一句")
    }

    @Test("Scene pause fences a deferral; the explicit resume prefix re-arms and still defers on voice")
    func scenePauseFencesDeferralAndResumeKeepsIntent() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("先说完再走")
        for _ in 0..<6 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        rig.stack.yieldLevel(0.67, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.67 })
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // deferred

        rig.coordinator.pauseForScene(.background)
        await rig.settle(40)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.stagedTranscript == "先说完再走")
        rig.clock.advance(by: 5)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // fenced, not submitted

        // Settled transition: an explicit user resume re-arms the preserved
        // prefix; the composite gate still applies to the new window.
        await rig.coordinator.resume()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)   // user is speaking now
        await rig.settle()
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // deferred again
        // The explicit resume re-armed the full original 0.9 s window; the
        // joint gate then needs that much real quiet (two 0.25 s samples are
        // not enough on their own).
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.driving.starts.count == 1 })
        #expect(rig.driving.starts[0].request.text == "先说完再走")
    }

    @Test("A newer partial during a deferral re-arms the full window; quiet alone never submits early")
    func newerPartialRearmsFullWindow() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("上半句")
        for _ in 0..<6 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.25) }
        rig.stack.yieldLevel(0.64, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.64 })
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // deferred

        await rig.say("上半句下半句")                      // re-arm: full 0.9 s window
        // Real continuous quiet for the WHOLE re-armed window: quiet alone
        // still never short-circuits transcript stability (no clock has
        // advanced, so the re-armed timer has not fired).
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        rig.clock.advance(by: 1.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "上半句下半句")
    }

    @Test("Speech seen BEFORE a late partial still blocks; a re-arm without new samples is not quiet")
    func preArmVoicedLatePartialNeverTrustsSilenceGap() async {
        let recorder = EndpointDiagnosticRecorder()
        let rig = VoiceRig(diagnostics: recorder)
        await rig.coordinator.start()

        // The user has measurably spoken for a full second BEFORE any
        // transcript exists (pre-arm voiced evidence in this stretch).
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)
        rig.stack.yieldLevel(0.61, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.61 })

        // A Whisper-slow FIRST partial arrives only now: it arms a fresh
        // 0.9 s transcript window with NO capture sample after the arm.
        await rig.say("慢半拍的第一句")
        rig.clock.advance(by: 0.95)
        await rig.settle()

        // The pre-arm evidence spans the capture stretch: "no samples since
        // the arm" is NOT proof of quiet, so the armed window defers.
        #expect(rig.driving.starts.isEmpty)
        #expect(rig.coordinator.state == .listening)
        #expect(recorder.count("endpointDeferredVoiced") == 1)

        // More elapsed time — or a partial/route gap with no further
        // samples — still proves nothing.
        rig.clock.advance(by: 5.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        // Only NEW continuous real quiet for the SAME 0.9 s window releases.
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)               // 0.5 s < 0.9 s
        rig.stack.yieldLevel(0.02, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0.02, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.driving.starts.count == 1 })
        #expect(rig.driving.starts[0].request.text == "慢半拍的第一句")

        // A released deferral can never double-commit.
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(recorder.count("endpointFired") == 1)
    }

    @Test("An incomplete utterance needs the full 1.6 s quiet; a brief quiet pause never submits")
    func incompleteUtteranceRequiresFullQuietWindow() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // Trailing connective: the settled incomplete window is 1.6 s.
        await rig.say("我先查一下，然后")

        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.25)
        rig.stack.yieldLevel(0.61, speech: true, duration: 0.25)
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.61 })

        // A real but BRIEF quiet pause: 1.0 s — longer than the complete
        // window, still shorter than THIS utterance's 1.6 s requirement.
        for _ in 0..<4 { rig.stack.yieldLevel(0, speech: false, duration: 0.25) }
        await rig.settle()

        // The 1.6 s transcript window expires with only 1.0 s of real
        // quiet: the joint gate must NOT submit.
        rig.clock.advance(by: 1.65)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        #expect(rig.coordinator.state == .listening)

        // 1.5 s: still short of the incomplete window.
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        rig.stack.yieldLevel(0, speech: false, duration: 0.25)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        // 1.75 s of continuous real quiet crosses it: release once with the
        // whole incomplete utterance text.
        rig.stack.yieldLevel(0.01, speech: false, duration: 0.25)
        #expect(await rig.waitUntil { rig.driving.starts.count == 1 })
        #expect(rig.driving.starts[0].request.text == "我先查一下，然后")
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }
}
#endif
