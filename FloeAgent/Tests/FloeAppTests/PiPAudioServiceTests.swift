// FloeAppTests — task PiP audio lifecycle contract.
//
// These tests drive the REAL `PiPAudioService` state machine and the REAL
// procedural synthesizer through injected seams (fake playback/speech/cue/
// session), so they exercise actual owner, pause, route, interruption,
// bounded-preview, batch-terminal, session-lease and stale-callback
// behavior — not mirrors of the implementation. The AVFoundation backends
// themselves (root-owned PiPAudioBackendAppTests) and full-App compilation
// are root-owned gates.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import AVFoundation
import FloeCore
@testable import FloeApp

// MARK: - Fakes

@MainActor
private final class FakeAmbientPlayer: PiPAmbientPlaying {
    private(set) var isPlaying = false
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var lastSound: PiPAmbientSound?
    private(set) var lastGain: Double = -1
    var failNextPlay = false

    func play(sound: PiPAmbientSound, gain: Double) -> Bool {
        guard !failNextPlay else { return false }
        playCount += 1
        lastSound = sound
        lastGain = gain
        isPlaying = true
        return true
    }

    func setGain(_ gain: Double) {
        lastGain = gain
    }

    func pause() {
        pauseCount += 1
        isPlaying = false
    }

    func resume() -> Bool {
        resumeCount += 1
        isPlaying = true
        return true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}

@MainActor
private final class FakeSpeechPlayer: PiPSpeechPlaying {
    private(set) var isSpeaking = false
    private(set) var spokenTexts: [String] = []
    private(set) var spokenVolumes: [Double] = []
    private var pendingCompletion: (@MainActor () -> Void)?

    func speak(
        text: String,
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !isSpeaking else { return false }
        isSpeaking = true
        spokenTexts.append(text)
        spokenVolumes.append(volume)
        pendingCompletion = completion
        return true
    }

    func stopAll() {
        let pending = pendingCompletion
        pendingCompletion = nil
        isSpeaking = false
        pending?()
    }

    /// Simulates AVFoundation's didFinish for the accepted utterance.
    func finishSpeaking() {
        let pending = pendingCompletion
        pendingCompletion = nil
        isSpeaking = false
        pending?()
    }
}

/// Mirrors the real cue contract: exactly-once bounded completion on
/// natural end (`finishCue`), replacement (a newer `playCue`) or `stop()`.
@MainActor
private final class FakeCuePlayer: PiPCuePlaying {
    private(set) var playCount = 0
    private(set) var lastVolume: Double?
    private(set) var stopCount = 0
    private(set) var isPlaying = false
    private(set) var deliveredCompletions = 0
    private var pendingCompletion: (@MainActor () -> Void)?

    func playCue(
        volume: Double,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        deliverPending() // replaced cue completes exactly once
        playCount += 1
        lastVolume = volume
        isPlaying = true
        pendingCompletion = completion
        return true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
        deliverPending()
    }

    /// Simulates the finite chime reaching its natural end.
    func finishCue() {
        isPlaying = false
        deliverPending()
    }

    private func deliverPending() {
        let pending = pendingCompletion
        pendingCompletion = nil
        if pending != nil { deliveredCompletions += 1 }
        pending?()
    }
}

@MainActor
private final class FakeSessionController: PiPAudioSessionControlling {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var adoptCount = 0
    var activateFails = false
    var externalOutputPresent = true
    var canReleaseSession: (@MainActor () -> Bool)?

    func activate() throws {
        activateCount += 1
        if activateFails {
            throw NSError(domain: "FakePiPAudioSession", code: 1)
        }
    }

    func adoptActivation() {
        adoptCount += 1
    }

    func deactivateIfOwned() {
        deactivateCount += 1
    }

    var isExternalOutputPresent: Bool { externalOutputPresent }
}

@MainActor
private final class HarnessBox {
    var preferences: PiPAudioPreferences
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var recordingActive = false
    init(_ preferences: PiPAudioPreferences) {
        self.preferences = preferences
    }
}

@MainActor
private struct PiPAudioHarness {
    let service: PiPAudioService
    let ambient: FakeAmbientPlayer
    let speech: FakeSpeechPlayer
    let cue: FakeCuePlayer
    let session: FakeSessionController
    let box: HarnessBox

    static func make(
        _ preferences: PiPAudioPreferences = PiPAudioPreferences()
    ) -> PiPAudioHarness {
        let ambient = FakeAmbientPlayer()
        let speech = FakeSpeechPlayer()
        let cue = FakeCuePlayer()
        let session = FakeSessionController()
        let service = PiPAudioService(
            ambient: ambient,
            speech: speech,
            cue: cue,
            session: session
        )
        let box = HarnessBox(preferences)
        service.preferencesProvider = { box.preferences }
        service.nowProvider = { box.now }
        service.isRecordingActiveNow = { box.recordingActive }
        return PiPAudioHarness(
            service: service,
            ambient: ambient,
            speech: speech,
            cue: cue,
            session: session,
            box: box
        )
    }
}

// MARK: - Lifecycle tests

@Suite("FloeApp.PiPAudioService")
@MainActor
struct PiPAudioServiceTests {

    @Test("Ambient at gain 0 really plays; raising the gain never restarts the loop")
    func zeroGainPlaysAndRaisingGainDoesNotRestart() {
        var preferences = PiPAudioPreferences()
        preferences.ambientGain = 0
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.isPlaying)
        #expect(harness.ambient.playCount == 1)
        #expect(harness.ambient.lastGain == 0)
        #expect(harness.service.state == .muted)

        var louder = preferences
        louder.ambientGain = 0.6
        harness.service.applyPreferences(louder)
        #expect(harness.ambient.playCount == 1) // no restart
        #expect(harness.ambient.lastGain == 0.6) // instant, live
        #expect(harness.ambient.isPlaying)
        #expect(harness.service.state == .playing)
    }

    @Test("Stored preferences survive later opens — no reset-to-zero per session")
    func storedPreferencesSurviveReopen() {
        var stored = PiPAudioPreferences()
        stored.ambientSound = .brownNoise
        stored.ambientGain = 0.6
        let harness = PiPAudioHarness.make(stored)
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.lastSound == .brownNoise)
        #expect(harness.ambient.lastGain == 0.6)
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.ambient.stopCount == 1)
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.lastSound == .brownNoise)
        #expect(harness.ambient.lastGain == 0.6)
    }

    @Test("Owner stop ends ambient; a late speech completion cannot restart or leak the session")
    func ownerStopIgnoresStaleCallbacks() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.speech.isSpeaking)
        #expect(harness.ambient.stopCount == 0) // batch not terminal yet
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.ambient.stopCount == 1)
        #expect(harness.service.state == .stopped)
        #expect(harness.session.deactivateCount == 0) // speech still finishing
        harness.speech.finishSpeaking() // stale-generation completion
        #expect(harness.ambient.playCount == 1) // never restarted
        #expect(harness.ambient.stopCount == 1)
        #expect(harness.session.deactivateCount == 1) // session handed back
    }

    @Test("Run A finishing keeps run B's ambience; only an emptied batch stops it")
    func batchTerminalStopsAmbientOnlyWhenEmpty() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID()) // B still active
        #expect(harness.ambient.isPlaying)
        #expect(harness.ambient.stopCount == 0)
        harness.service.handleRunBatchTerminal()
        #expect(harness.ambient.stopCount == 1)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.service.state == .stopped)
        // A genuinely new run re-arms ambience inside the same owner.
        harness.service.handleRunStarted()
        #expect(harness.ambient.isPlaying)
        #expect(harness.ambient.playCount == 2)
    }

    @Test("Terminal narration and cue finish bounded; the session releases only after owner end")
    func terminalSpeechIsBoundedAndSessionReleasesAfterOwner() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        preferences.taskSpeechGain = 0.7
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.speech.isSpeaking)
        #expect(harness.speech.spokenVolumes == [0.7])
        #expect(harness.cue.playCount == 1)
        #expect(harness.cue.lastVolume == 0.7) // cues share the narration volume
        harness.service.handleRunBatchTerminal()
        #expect(harness.ambient.stopCount == 1)
        #expect(harness.session.deactivateCount == 0) // cue + narration still bounded-playing
        harness.cue.finishCue()
        harness.speech.finishSpeaking()
        #expect(harness.session.deactivateCount == 0) // owner (dwell surface) still open
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("Cue-only channels hold the lease until the finite chime really ends")
    func cueOnlyTerminalReleasesAfterCueEnd() {
        var preferences = PiPAudioPreferences()
        preferences.ambientEnabled = false // no loop at all
        preferences.taskSpeechEnabled = false
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.playCount == 0)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.cue.playCount == 1)
        #expect(harness.session.activateCount == 1) // the cue owns a real session
        harness.service.handleRunBatchTerminal()
        harness.service.handleTaskPiPActiveChanged(false) // owner disappears
        #expect(harness.session.deactivateCount == 0) // cue still in flight
        harness.cue.finishCue()
        #expect(harness.session.deactivateCount == 1) // released exactly once
        harness.cue.finishCue() // a late duplicate end cannot release twice
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("A late cue completion from a superseded owner cannot release the new owner's session")
    func staleCueCannotReleaseNewOwner() {
        var preferences = PiPAudioPreferences()
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.cue.isPlaying)
        harness.service.handleTaskPiPActiveChanged(false) // old owner ends
        harness.service.handleTaskPiPActiveChanged(true) // new owner starts
        harness.cue.finishCue() // old cue's bounded completion lands late
        #expect(harness.session.deactivateCount == 0) // new owner keeps the session
        #expect(harness.service.isTaskOwnerActive)
    }

    @Test("Replacing an in-flight cue completes the old one exactly once")
    func cueReplacementCompletesOldCueOnce() {
        var preferences = PiPAudioPreferences()
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        harness.box.now = harness.box.now.addingTimeInterval(
            PiPAudioService.needsInputThrottle + 1
        )
        harness.service.handleTaskEvent(.needsInput, runID: UUID()) // replaces the cue
        #expect(harness.cue.playCount == 2)
        #expect(harness.cue.deliveredCompletions == 1) // old cue completed once
        harness.cue.finishCue()
        #expect(harness.cue.deliveredCompletions == 2)
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("Answer speech borrows the session across a PiP close and releases it exactly once")
    func answerSpeechContinuesAcrossPiPClose() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.isPlaying)
        harness.service.handleAnswerSpeechActive(true) // user tapped read-aloud
        #expect(harness.ambient.lastGain == 0) // ducked (gain 0 stays 0)
        harness.service.handleTaskPiPActiveChanged(false) // PiP closes mid-answer
        #expect(harness.ambient.stopCount == 1)
        #expect(harness.session.deactivateCount == 0) // answer keeps the session
        #expect(harness.service.holdsSharedAudioSession)
        harness.service.handleAnswerSpeechActive(false)
        #expect(harness.session.deactivateCount == 1) // released exactly once
        harness.service.handleAnswerSpeechActive(false) // idempotent
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("An adopted video-side lease is released by the audio service exactly once")
    func adoptedLeaseReleasesExactlyOnce() {
        var preferences = PiPAudioPreferences()
        preferences.ambientEnabled = false // audio never activates on its own
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleAnswerSpeechActive(true)
        // The video service deferred its deactivation to the audio service.
        harness.service.adoptDeferredSessionLease()
        harness.service.adoptDeferredSessionLease() // idempotent while held
        #expect(harness.session.adoptCount == 1)
        #expect(harness.session.activateCount == 0) // adoption never re-activates
        harness.service.handleTaskPiPActiveChanged(true) // owner without audio channels
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.session.deactivateCount == 0) // answer still speaking
        harness.service.handleAnswerSpeechActive(false)
        #expect(harness.session.deactivateCount == 1)
        // Nothing can release a lease that is already gone.
        harness.service.handleAnswerSpeechActive(false)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("All channels off leaves the video-owned session entirely to the video service")
    func allChannelsOffKeepsAudioHandsOff() {
        var preferences = PiPAudioPreferences()
        preferences.ambientEnabled = false
        preferences.taskSpeechEnabled = false
        preferences.cuesEnabled = false
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        harness.service.handleRunBatchTerminal()
        harness.service.handleTaskPiPActiveChanged(false)
        #expect(harness.session.activateCount == 0)
        #expect(harness.session.deactivateCount == 0) // no lease → no release
        #expect(!harness.service.holdsSharedAudioSession)
    }

    @Test("Cancelled runs stop ambience without narration but may chime")
    func cancelledIsSilentButCued() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.cancelled, runID: UUID())
        #expect(harness.speech.spokenTexts.isEmpty)
        #expect(harness.cue.playCount == 1)
    }

    @Test("Interruptions obey the system resume hint; explicit user play clears a stale hold")
    func interruptionLifecycle() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.isPlaying)
        harness.service.handleSessionEvent(.interruptionBegan)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.ambient.pauseCount == 1)
        #expect(harness.service.state == .paused)
        harness.service.handleSessionEvent(.interruptionEnded(shouldResume: false))
        #expect(!harness.ambient.isPlaying) // no hint → stays paused
        harness.service.handleSessionEvent(.interruptionBegan)
        harness.service.handleSessionEvent(.interruptionEnded(shouldResume: true))
        #expect(harness.ambient.isPlaying) // hint → resumes
        #expect(harness.ambient.resumeCount == 1)
        harness.service.handleSessionEvent(.interruptionBegan)
        #expect(!harness.ambient.isPlaying)
        harness.service.handlePiPTransportControlled(true) // fresh user intent
        #expect(harness.ambient.isPlaying)
    }

    @Test("Headphone removal pauses; only a real external route resumes; fresh owners use the current route")
    func headphoneRouteLifecycle() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        harness.session.externalOutputPresent = true
        harness.service.handleSessionEvent(.externalOutputLost)
        #expect(!harness.ambient.isPlaying) // no unexpected speaker output
        #expect(harness.service.state == .paused)
        harness.session.externalOutputPresent = false
        harness.service.handleSessionEvent(.externalOutputAvailable)
        #expect(!harness.ambient.isPlaying) // speaker-only is not a resume route
        harness.session.externalOutputPresent = true
        harness.service.handleSessionEvent(.externalOutputAvailable)
        #expect(harness.ambient.isPlaying)
        // Explicit transport play clears the route hold on the current route.
        harness.service.handleSessionEvent(.externalOutputLost)
        #expect(!harness.ambient.isPlaying)
        harness.service.handlePiPTransportControlled(true)
        #expect(harness.ambient.isPlaying)
        // A FRESH owner session plays on the current route — no headset rule.
        harness.service.handleTaskPiPActiveChanged(false)
        harness.session.externalOutputPresent = false
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.isPlaying)
    }

    @Test("PiP transport pause stops sound; announcements wait for a real resume")
    func transportPauseStopsEverything() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handlePiPTransportControlled(false)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.service.state == .paused)
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        #expect(harness.speech.spokenTexts.isEmpty) // nothing continues while paused
        #expect(harness.cue.playCount == 0)
        harness.service.handlePiPTransportControlled(true)
        #expect(harness.ambient.isPlaying)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.speech.spokenTexts.count == 1) // fresh events announce again
    }

    @Test("The PiP window dismissal clears transport pause but not interruption/route holds")
    func windowDismissalOnlyClearsTransport() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handlePiPTransportControlled(false)
        #expect(!harness.ambient.isPlaying)
        harness.service.handlePiPWindowDismissed() // automatic foreground collapse
        #expect(harness.ambient.isPlaying)
        #expect(harness.service.isTaskOwnerActive) // the run owner survives the collapse
        // An interruption hold is a separate system fact and must survive.
        harness.service.handleSessionEvent(.interruptionBegan)
        harness.service.handlePiPWindowDismissed()
        #expect(!harness.ambient.isPlaying)
    }

    @Test("Narration ducks the ambient loop and restores the exact gain")
    func speechDucksAmbientThenRestores() {
        var preferences = PiPAudioPreferences()
        preferences.ambientGain = 0.5
        preferences.taskSpeechEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.ambient.lastGain == 0.5)
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        #expect(harness.ambient.lastGain == 0.5 * PiPAudioService.ambientDuckFactor)
        harness.speech.finishSpeaking()
        #expect(harness.ambient.lastGain == 0.5)
        harness.service.handleAnswerSpeechActive(true)
        #expect(harness.ambient.lastGain == 0.5 * PiPAudioService.ambientDuckFactor)
        harness.service.handleAnswerSpeechActive(false)
        #expect(harness.ambient.lastGain == 0.5)
    }

    @Test("Dictation pauses the loop; it resumes only for a live owner")
    func recordingYieldsAndNeverResurrects() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.handleTaskPiPActiveChanged(true)
        // The synchronous gate is authoritative: the box mirrors the real
        // voice-input state, the publisher event is the delivery hint.
        harness.box.recordingActive = true
        harness.service.handleRecordingActive(true)
        #expect(!harness.ambient.isPlaying)
        harness.box.recordingActive = false
        harness.service.handleRecordingActive(false)
        #expect(harness.ambient.isPlaying)
        // After the owner ended, a recording end must not resurrect audio.
        harness.box.recordingActive = true
        harness.service.handleRecordingActive(true)
        harness.service.handleTaskPiPActiveChanged(false)
        harness.box.recordingActive = false
        harness.service.handleRecordingActive(false)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.service.state == .stopped)
    }

    @Test("A lagging recording observer cannot cause session or playback reconfiguration")
    func synchronousRecordingGateBlocksActivation() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        // The publisher event has NOT arrived yet, but the real voice-input
        // session is already live: the synchronous gate must catch it.
        harness.box.recordingActive = true
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.session.activateCount == 0) // zero reconfiguration
        #expect(harness.ambient.playCount == 0) // zero playback starts
        #expect(harness.service.state == .paused) // honest Pause, not an error
        #expect(harness.service.lastActionableError == nil)
        // Announcements are gated too.
        var preferences = PiPAudioPreferences()
        preferences.cuesEnabled = true
        preferences.taskSpeechEnabled = true
        harness.service.applyPreferences(preferences)
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        #expect(harness.cue.playCount == 0)
        #expect(harness.speech.spokenTexts.isEmpty)
        // When the real session ends, playback resumes correctly.
        harness.box.recordingActive = false
        harness.service.handleRecordingActive(false)
        #expect(harness.session.activateCount == 1)
        #expect(harness.ambient.isPlaying)
        #expect(harness.service.state == .muted) // gain 0 → really playing, muted
    }

    @Test("Preview plays the explicitly requested sound at the exact slider gain — including 0")
    func previewHonorsRequestedSoundAndGain() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences()) // rain, gain 0
        harness.service.startPreview(.brownNoise)
        #expect(harness.ambient.lastSound == .brownNoise) // never the stored rain
        #expect(harness.ambient.lastGain == 0) // respects gain 0, no floor override
        #expect(harness.ambient.isPlaying) // really running while muted
        #expect(harness.service.state == .muted)
        #expect(harness.service.isPreviewing)
        #expect(!harness.service.isTaskOwnerActive) // no task/PiP side effects
        // Raising the slider updates the live preview without a restart.
        var louder = PiPAudioPreferences()
        louder.ambientGain = 0.3
        harness.service.applyPreferences(louder)
        #expect(harness.ambient.playCount == 1)
        #expect(harness.ambient.lastGain == 0.3)
        #expect(harness.service.state == .playing)
        // Leaving the page stops the preview and releases the session.
        harness.service.stopPreview()
        #expect(harness.ambient.stopCount == 1)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.service.state == .stopped)
        #expect(harness.session.deactivateCount == 1)
    }

    @Test("Preview is hard-bounded in the service; a re-tap supersedes the old timer")
    func previewStopsAfterBound() async {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.service.previewBound = 0.2
        harness.service.startPreview(.rain)
        #expect(harness.service.isPreviewing)
        try? await Task.sleep(for: .milliseconds(80))
        harness.service.startPreview(.rain) // explicit re-tap re-arms the bound
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.service.isPreviewing) // first timer was superseded
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!harness.service.isPreviewing) // bounded stop
        #expect(!harness.ambient.isPlaying)
    }

    @Test("Stage events without an owner never start audio — settings and events are not owners")
    func eventsWithoutOwnerAreInert() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        preferences.cuesEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        harness.service.handleRunBatchTerminal()
        harness.service.handleRunStarted()
        #expect(harness.speech.spokenTexts.isEmpty)
        #expect(harness.cue.playCount == 0)
        #expect(harness.ambient.playCount == 0)
        #expect(harness.session.activateCount == 0)
        #expect(harness.service.state == .stopped)
    }

    @Test("Repeated attention events are throttled; terminal stages announce once per owner")
    func announcementsAreDedupedAndThrottled() {
        var preferences = PiPAudioPreferences()
        preferences.taskSpeechEnabled = true
        let harness = PiPAudioHarness.make(preferences)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        harness.service.handleTaskEvent(.needsInput, runID: UUID()) // immediate repeat
        #expect(harness.speech.spokenTexts.count == 1)
        harness.speech.finishSpeaking()
        harness.service.handleTaskEvent(.needsInput, runID: UUID()) // inside the window
        #expect(harness.speech.spokenTexts.count == 1)
        harness.box.now = harness.box.now.addingTimeInterval(
            PiPAudioService.needsInputThrottle + 1
        )
        harness.service.handleTaskEvent(.needsInput, runID: UUID())
        #expect(harness.speech.spokenTexts.count == 2)
        harness.speech.finishSpeaking()
        harness.service.handleTaskEvent(.completed, runID: UUID())
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.speech.spokenTexts.count == 3) // terminal once per owner
        harness.speech.finishSpeaking()
        // A fresh owner session re-arms announcements.
        harness.service.handleTaskPiPActiveChanged(false)
        harness.service.handleTaskPiPActiveChanged(true)
        harness.service.handleTaskEvent(.completed, runID: UUID())
        #expect(harness.speech.spokenTexts.count == 4)
    }

    @Test("A refused session reports one actionable error and is not retried per reconcile")
    func sessionFailureIsQuietAndActionable() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.session.activateFails = true
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.service.lastActionableError != nil)
        #expect(harness.session.activateCount == 1)
        var louder = PiPAudioPreferences()
        louder.ambientGain = 0.2
        harness.service.applyPreferences(louder)
        #expect(harness.session.activateCount == 1) // one attempt per owner generation
        #expect(harness.ambient.isPlaying) // the loop still really runs
    }

    @Test("A failed loop start reports an actionable error without blocking PiP")
    func playbackFailureIsActionable() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        harness.ambient.failNextPlay = true
        harness.service.handleTaskPiPActiveChanged(true)
        #expect(harness.service.lastActionableError != nil)
        #expect(!harness.ambient.isPlaying)
        #expect(harness.service.state == .stopped)
    }

    @Test("Session release honors the video-surface cross-check both ways")
    func sessionReleaseCrossCheck() {
        let harness = PiPAudioHarness.make(PiPAudioPreferences())
        var videoHoldsSession = true
        harness.service.setSessionReleaseCheck { !videoHoldsSession }
        harness.service.startPreview(.rain)
        harness.service.stopPreview()
        #expect(harness.session.deactivateCount == 0) // PiP video still owns it
        videoHoldsSession = false
        harness.service.startPreview(.rain)
        harness.service.stopPreview()
        #expect(harness.session.deactivateCount == 1)
    }

    // MARK: - Sound-owner transition chain (video-service policy)

    @Test("Sound owner survives foreground-return collapse and ends on user or system close")
    func soundOwnerPolicyChain() {
        var active = false
        var suppressed = false
        func apply(_ event: BackgroundPiPSoundOwnerEvent) {
            let next = BackgroundPiPSoundOwnerPolicy.transition(
                active: active,
                suppressed: suppressed,
                event: event
            )
            active = next.active
            suppressed = next.suppressed
        }
        apply(.runContextEstablished)
        #expect(active)
        apply(.intentionalStopCompleted(origin: .foregroundRetraction))
        #expect(active) // automatic collapse keeps the running-task owner
        apply(.controllerReplaced)
        #expect(active) // a source swap keeps the same loop
        apply(.runContextEstablished)
        #expect(active)
        apply(.intentionalStopCompleted(origin: .manualControl))
        #expect(!active)
        #expect(suppressed) // user close ends sound for the batch
        apply(.runContextEstablished)
        #expect(!active) // suppression honored for the current batch
        apply(.runSurfaceStopped)
        #expect(!active)
        #expect(!suppressed) // teardown re-arms a genuinely new batch
        apply(.runContextEstablished)
        #expect(active)
        apply(.unexpectedStopCompleted)
        #expect(!active)
        #expect(suppressed) // system close behaves like a user close
    }

    // MARK: - Pure policy

    @Test("Pure playback policy pins gain, pause and honest-state rules")
    func purePolicyContract() {
        #expect(PiPAudioPlaybackPolicy.wantsAmbientLoop(
            ownerActive: true, batchTerminal: false, ambientEnabled: true
        ))
        #expect(!PiPAudioPlaybackPolicy.wantsAmbientLoop(
            ownerActive: true, batchTerminal: true, ambientEnabled: true
        ))
        #expect(!PiPAudioPlaybackPolicy.wantsAmbientLoop(
            ownerActive: false, batchTerminal: false, ambientEnabled: true
        ))
        #expect(!PiPAudioPlaybackPolicy.wantsAmbientLoop(
            ownerActive: true, batchTerminal: false, ambientEnabled: false
        ))
        // Preview ignores the transport pause but never a recording/interruption.
        #expect(PiPAudioPlaybackPolicy.wantsLoopRunning(
            wantsAmbient: false, previewActive: true, pausedByTransport: true,
            pausedByInterruption: false, pausedByRoute: false, pausedByRecording: false
        ))
        #expect(!PiPAudioPlaybackPolicy.wantsLoopRunning(
            wantsAmbient: false, previewActive: true, pausedByTransport: false,
            pausedByInterruption: false, pausedByRoute: false, pausedByRecording: true
        ))
        // Gain: no preview floor; ducking multiplies.
        #expect(PiPAudioPlaybackPolicy.loopGain(
            ambientGain: 0, ducked: false, duckFactor: 0.15
        ) == 0)
        #expect(PiPAudioPlaybackPolicy.loopGain(
            ambientGain: 0.5, ducked: true, duckFactor: 0.15
        ) == 0.5 * 0.15)
        // Honest states.
        #expect(PiPAudioPlaybackPolicy.surfaceState(
            loopRunning: true, wantsAmbient: true, previewActive: false, gain: 0,
            pausedByTransport: false, pausedByInterruption: false,
            pausedByRoute: false, pausedByRecording: false
        ) == .muted)
        #expect(PiPAudioPlaybackPolicy.surfaceState(
            loopRunning: false, wantsAmbient: true, previewActive: false, gain: 0,
            pausedByTransport: true, pausedByInterruption: false,
            pausedByRoute: false, pausedByRecording: false
        ) == .paused)
        #expect(PiPAudioPlaybackPolicy.surfaceState(
            loopRunning: false, wantsAmbient: false, previewActive: false, gain: 0,
            pausedByTransport: false, pausedByInterruption: false,
            pausedByRoute: true, pausedByRecording: false
        ) == .stopped) // no intent → never "paused"
    }

    // MARK: - System event translation

    @Test("AVAudioSession notification translation is pure and exact")
    func systemEventTranslation() {
        #expect(PiPAudioSystemEvents.interruptionEvent(
            typeRaw: AVAudioSession.InterruptionType.began.rawValue, optionsRaw: 0
        ) == .interruptionBegan)
        #expect(PiPAudioSystemEvents.interruptionEvent(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue,
            optionsRaw: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ) == .interruptionEnded(shouldResume: true))
        #expect(PiPAudioSystemEvents.interruptionEvent(
            typeRaw: AVAudioSession.InterruptionType.ended.rawValue, optionsRaw: 0
        ) == .interruptionEnded(shouldResume: false))
        #expect(PiPAudioSystemEvents.interruptionEvent(typeRaw: nil, optionsRaw: 0) == nil)
        #expect(PiPAudioSystemEvents.routeEvent(
            reasonRaw: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            externalPresentNow: false
        ) == .externalOutputLost)
        #expect(PiPAudioSystemEvents.routeEvent(
            reasonRaw: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            externalPresentNow: true
        ) == nil) // swapped between two external devices → keep playing
        #expect(PiPAudioSystemEvents.routeEvent(
            reasonRaw: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            externalPresentNow: true
        ) == .externalOutputAvailable)
        #expect(PiPAudioSystemEvents.routeEvent(
            reasonRaw: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            externalPresentNow: false
        ) == nil)
        #expect(PiPAudioSystemEvents.routeEvent(
            reasonRaw: AVAudioSession.RouteChangeReason.unknown.rawValue,
            externalPresentNow: true
        ) == nil)
    }

    // MARK: - Procedural synthesis (real generated audio)

    @Test("Rain and brown noise are deterministic, audibly distinct, seamless and bounded")
    func synthesisIsRealDistinctSeamlessAndBounded() {
        let rain = AmbientAudioSynthesizer.loopSamples(for: .rain)
        let rainAgain = AmbientAudioSynthesizer.loopSamples(for: .rain)
        let brown = AmbientAudioSynthesizer.loopSamples(for: .brownNoise)
        #expect(rain == rainAgain) // fixed seed → byte-identical
        #expect(rain.count == Int(
            AmbientAudioSynthesizer.rainLoopSeconds * AmbientAudioSynthesizer.sampleRate
        ))
        #expect(brown.count == Int(
            AmbientAudioSynthesizer.brownLoopSeconds * AmbientAudioSynthesizer.sampleRate
        ))

        // Audibly distinct: rain keeps strong treble (droplets + hiss);
        // brown noise is a low rumble. Verified margins ≈ 23× / 0.97 vs 0.08.
        let rainHigh = AmbientAudioSynthesizer.highFrequencyEnergy(rain)
        let brownHigh = AmbientAudioSynthesizer.highFrequencyEnergy(brown)
        let rainLow = AmbientAudioSynthesizer.lowFrequencyEnergy(rain)
        let brownLow = AmbientAudioSynthesizer.lowFrequencyEnergy(brown)
        #expect(rainHigh > brownHigh * 5)
        #expect(brownLow / (brownLow + brownHigh) > rainLow / (rainLow + rainHigh))

        // Seamless: the wrap-around step stays inside the loop's natural
        // sample-to-sample variation.
        for loop in [rain, brown] {
            var maxDelta: Float = 0
            for index in 1..<loop.count {
                maxDelta = max(maxDelta, abs(loop[index] - loop[index - 1]))
            }
            let seam = abs(loop[0] - loop[loop.count - 1])
            #expect(seam <= maxDelta) // no hard discontinuity at the wrap
        }

        // Bounded rendering: exact PCM size and hard caps.
        let rainWAV = AmbientAudioSynthesizer.wavData(for: .rain)
        let brownWAV = AmbientAudioSynthesizer.wavData(for: .brownNoise)
        let cueWAV = AmbientAudioSynthesizer.cueWavData()
        #expect(rainWAV.count == 44 + rain.count * 2)
        #expect(brownWAV.count == 44 + brown.count * 2)
        #expect(rainWAV.count < 700_000)
        #expect(brownWAV.count < 900_000)
        #expect(cueWAV.count == 44 + AmbientAudioSynthesizer.cueSampleCount * 2)
        #expect(cueWAV.count < 64_000)
        #expect(rainWAV.prefix(4) == Data("RIFF".utf8))
        #expect(rainWAV.dropFirst(8).prefix(4) == Data("WAVE".utf8))
        // Rendering is cached: the second call returns identical bytes.
        #expect(AmbientAudioSynthesizer.wavData(for: .rain) == rainWAV)
    }
}
#endif
