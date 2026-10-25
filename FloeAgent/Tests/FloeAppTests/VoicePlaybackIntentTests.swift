// FloeAppTests — Continuous voice: explicit playback pause intent
// (2026-10-25 pause-defeat repair).
//
// SPDX-License-Identifier: MPL-2.0
//
// CONFIRMED SOURCE DEFECT: a tentative barge pause or a deliberate
// `pauseOutput()` called `playerNode.pause()`, but the producer kept
// appending and every ACCEPTED buffer ended in `if !playerNode.isPlaying
// { playerNode.play() }` — the next streaming chunk silently resumed
// output over the user's voice, burned false-start strikes, and defeated
// interruption. The pause was a player STATE, never an intent.
//
// The production decision lives in the pure `VoicePlaybackIntentGate`,
// consulted by `VoiceConversationLiveStack` at every auto-start site
// (`scheduleChunk` arrival, capture-recovery restart), with stop/flush
// opening a fresh epoch. These tests exercise that exact production
// decision and the live-stack seam (no engine/microphone required on the
// Simulator), plus the COORDINATOR guards that fence a stale resume in
// production (the protocol method carries no caller epoch). Audible
// position-preserving behavior on a physical device remains the primary's
// acceptance.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@MainActor
@Suite("Voice playback intent (autoplay veto + production fences)")
struct VoicePlaybackIntentTests {

    @Test("A pause vetoes chunk-arrival auto-start until a legitimate resume")
    func pauseSurvivesChunkArrival() {
        var gate = VoicePlaybackIntentGate()
        #expect(gate.mayAutoStartPlayback(currentEpoch: 0))
        gate.pause(epoch: 0)
        // Every accepted-buffer check while paused: queue, never start.
        for _ in 0..<5 { #expect(!gate.mayAutoStartPlayback(currentEpoch: 0)) }
        gate.resume(epoch: 0)
        #expect(gate.mayAutoStartPlayback(currentEpoch: 0))
        #expect(!gate.isPauseIntended)
    }

    @Test("Stop/flush opens a fresh epoch: the old pause never gates the next answer")
    func stopClearsIntentForNextRound() {
        var gate = VoicePlaybackIntentGate()
        gate.pause(epoch: 3)
        gate.beginEpoch(4)
        #expect(gate.mayAutoStartPlayback(currentEpoch: 4))
        // A stale pause tagged to the superseded epoch never gates the new one.
        gate.pause(epoch: 3)
        #expect(gate.mayAutoStartPlayback(currentEpoch: 4))
        // A stale resume of an older epoch cannot clear a CURRENT pause
        // (gate-level defense; the production fence is the coordinator).
        gate.beginEpoch(5)
        gate.pause(epoch: 5)
        gate.resume(epoch: 4)
        #expect(!gate.mayAutoStartPlayback(currentEpoch: 5))
        gate.resume(epoch: 5)
        #expect(gate.mayAutoStartPlayback(currentEpoch: 5))
    }

    @Test("False-start cycles are exact and repeatable; a resume after a stop is inert")
    func falseStartCyclesStayExact() {
        var gate = VoicePlaybackIntentGate()
        for cycle in 0..<3 {
            gate.pause(epoch: 7)
            #expect(!gate.mayAutoStartPlayback(currentEpoch: 7), "cycle \(cycle)")
            gate.resume(epoch: 7)
            #expect(gate.mayAutoStartPlayback(currentEpoch: 7), "cycle \(cycle)")
        }
        // Confirmed interrupt stop then restart: new epoch starts free.
        gate.pause(epoch: 7)
        gate.beginEpoch(8)
        gate.resume(epoch: 7)                 // late/stale: must not matter
        #expect(gate.mayAutoStartPlayback(currentEpoch: 8))
    }

    @Test("The live stack routes pause/resume/stop through the production intent seam")
    func liveStackSeam() {
        let stack = VoiceConversationLiveStack(language: .automatic)
        // No engine is required: intent bookkeeping is pure state, and the
        // simulator path never reaches the audio graph.
        #expect(stack.mayAutoStartPlayback())
        stack.pausePlayback()
        #expect(!stack.mayAutoStartPlayback())      // next chunk may not start
        stack.resumePlayback()                      // false-start / manual resume
        #expect(stack.mayAutoStartPlayback())
        stack.pausePlayback()
        #expect(!stack.mayAutoStartPlayback())
        stack.stopPlayback()                        // confirmed interrupt / new round
        #expect(stack.mayAutoStartPlayback())       // fresh epoch renders again
    }

    @Test("Producer chunks accepted during a tentative pause queue and play after the false-start resume")
    func chunksQueueDuringBargePause() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("念两段")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("第一段。第二段。")
        let units = rig.log.units
        #expect(units.count == 2)
        guard units.count == 2 else { return }
        let chunk = VoiceConversationAudioChunk(
            samples: [Float](repeating: 0.2, count: 100), channelCount: 1, sampleRate: 8_000
        )
        _ = rig.coordinator.appendAudio(chunk, to: units[0])
        rig.stack.stepPlayed(frames: 40)
        await rig.settle()

        // Tentative barge pause (two 0.1 s voiced samples ≥ 0.18 s).
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        await rig.settle()
        #expect(rig.stack.count("pause") == 1)

        // The producer keeps delivering DURING the pause: chunks MUST be
        // accepted and retained (queued under the bounds), never dropped and
        // never relabelled as engine failure.
        #expect(rig.coordinator.appendAudio(chunk, to: units[0]) == .accepted)
        rig.coordinator.endUnit(units[0])
        #expect(rig.coordinator.appendAudio(chunk, to: units[1]) == .accepted)
        rig.coordinator.endUnit(units[1])
        if let token = rig.coordinator.currentRound {
            rig.coordinator.endRoundAudio(token)
        }

        // No confirmation: the hard 1.2 s bound resumes at the SAME position
        // (no stop/flush, no dropped units, no regeneration).
        rig.clock.advance(by: 1.2)
        await rig.settle()
        #expect(rig.stack.count("resume") == 1)
        #expect(rig.stack.count("stopPlayback") == 0)

        rig.stack.stepPlayed(frames: 300)
        #expect(await rig.waitUntil { rig.coordinator.state == .listening })
        await rig.settle(30)
        #expect(rig.driving.receipts.last?.status == .completed)
        #expect(rig.driving.receipts.last?.spokenText == "第一段。第二段。")
    }

    @Test("A cancelled round is never resumed by a later candidate timer (coordinator fence)")
    func cancelledRoundNeverResumes() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("讲个故事")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("从前。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 50)
        await rig.settle()

        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        await rig.settle()
        #expect(rig.stack.count("pause") == 1)

        // Manual interrupt replaces the round while the tentative pause is
        // active: the cancellation path stops output — it never "resumes".
        rig.coordinator.interruptNow()
        await rig.settle(30)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.stack.count("resume") == 0)
        #expect(rig.stack.count("stopPlayback") >= 1)

        // A stale barge candidate timer can never resurrect output later.
        rig.clock.advance(by: 3.0)
        await rig.settle()
        #expect(rig.stack.count("resume") == 0)
        #expect(rig.stack.count("pause") == 1)
    }
}
#endif
