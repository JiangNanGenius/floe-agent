// FloeAppTests — Continuous voice microphone activation: focused regressions.
//
// SPDX-License-Identifier: MPL-2.0
//
// USER-REPORTED FACTS this round addresses (2026-10-24, Build 291 1.7.50):
//   - iPhone: continuous voice failed with the `.noAudioInput`
//     "未找到麦克风" copy while ordinary Whisper dictation worked.
//   - Fresh unpatched 291 iPhone (later): empty-New-Task continuous voice
//     reached Connecting then failed with the DISTINCT
//     "语音识别暂不可用" (`voice.error.recognition`) copy — a recognizer/
//     factory-start failure class, NOT the no-microphone class — while the
//     SAME device's ordinary dictation, started right afterwards, reached
//     正在听 with real levels (A/B preserved as valid input).
//   - M4 iPad: dictation ALSO failed after TTS previews / a voice session
//     stop.
// The physical root cause is NOT yet device-proven. The repairs these tests
// pin are SOURCE-DERIVED defect candidates:
//   A. Bring-up order: dictation (working) installs the mic tap BEFORE
//      engine start; the continuous stack previously installed it on an
//      ALREADY-STARTED voice-processed engine.
//   B. Shared-session last-holder discipline: every component toggles the
//      ONE `AVAudioSession`; a late or bounded-handoff-abandoned stop from
//      one component used to deactivate it under a newer owner.
//   C. Build sequence alignment: the coordinator now creates the
//      recognizer backend BEFORE arming the microphone graph (matching
//      working dictation), and a recognizer factory failure must never
//      arm the microphone.
// Meaningful coverage here is the BEHAVIOR the runtime decides on —
// `VoiceCaptureRecoveryGate` (the object the live stack funnels every
// recovery through) under failure, cancellation, config-change and
// late-stop conditions, and `FloeAudioSessionOwnership` under superseded
// and late-release races. The bring-up order assertion is contract
// hygiene (a drift guard for the list the runtime executes), not a
// readiness proof — real tap buffers, AEC and the iPhone route stay the
// app owner's fixed-App device work; these fakes cannot prove a buffer
// exists, they prove the machine the stack obeys.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

// MARK: - Fakes (unique names — sibling voice test fakes live in this module)

final class MicActivationAuth: VoiceConversationAuthorizationProviding, @unchecked Sendable {
    func requestMicrophoneAccess() async -> Bool { true }
    func requestSpeechRecognitionAccess() async -> Bool { true }
}

@MainActor
final class MicActivationClock: VoiceConversationScheduling {
    final class Item: VoiceConversationScheduled {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }
    private(set) var scheduled: [Item] = []
    func schedule(after seconds: Double, action: @escaping @MainActor () -> Void) -> any VoiceConversationScheduled {
        // Inert on purpose: these tests never advance virtual timers, so
        // the preparation watchdog cannot fire mid-assertion.
        let item = Item()
        scheduled.append(item)
        return item
    }
}

@MainActor
final class MicActivationDriving: VoiceConversationTurnDriving {
    private(set) var starts: [VoiceConversationTurnRequest] = []
    func startTurn(_ request: VoiceConversationTurnRequest, send: @escaping VoiceConversationTurnSender) {
        starts.append(request)
    }
    func cancelTurn(_ token: VoiceConversationRoundToken) async {}
}

/// Scripted capture path. `captureFailuresRemaining` counts `startCapture`
/// calls that throw `.noAudioInput` before the path becomes provable. From
/// the coordinator's view an in-stack recovery that EVENTUALLY proves is
/// invisible (the single call simply takes longer and returns); a
/// recovery-exhausted path is one thrown `.noAudioInput`.
final class MicActivationStack: VoiceConversationStack, @unchecked Sendable {
    var captureFailuresRemaining: Int
    var beginFailure: VoiceConversationFailure?
    var activateFailure: VoiceConversationFailure?
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var callLog: [String] = []
    private var storedTranscripts: AsyncStream<String>
    private var transcriptSink: AsyncStream<String>.Continuation
    private let micLevels: AsyncStream<VoiceConversationLevel>
    private let micSink: AsyncStream<VoiceConversationLevel>.Continuation
    private let played: AsyncStream<VoiceConversationLevel>
    private let playedSink: AsyncStream<VoiceConversationLevel>.Continuation
    private let engine: AsyncStream<VoiceConversationEngineEvent>
    private let engineSink: AsyncStream<VoiceConversationEngineEvent>.Continuation
    private let system: AsyncStream<VoiceConversationSystemEvent>
    private let systemSink: AsyncStream<VoiceConversationSystemEvent>.Continuation

    init(captureFailuresRemaining: Int = 0) {
        self.captureFailuresRemaining = captureFailuresRemaining
        (micLevels, micSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (played, playedSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (storedTranscripts, transcriptSink) = AsyncStream.makeStream(of: String.self)
        (engine, engineSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (system, systemSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    var outputSampleRate: Double { 48_000 }
    var levels: AsyncStream<VoiceConversationLevel> { micLevels }
    var playedLevels: AsyncStream<VoiceConversationLevel> { played }
    var transcripts: AsyncStream<String> { lock.withLock { storedTranscripts } }
    var engineEvents: AsyncStream<VoiceConversationEngineEvent> { engine }
    var systemEvents: AsyncStream<VoiceConversationSystemEvent> { system }

    private func increment(_ key: String) {
        lock.withLock { counts[key, default: 0] += 1; callLog.append(key) }
    }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    var order: [String] { lock.withLock { callLog } }
    func yieldSystem(_ event: VoiceConversationSystemEvent) { systemSink.yield(event) }

    func activate() async throws(VoiceConversationFailure) {
        increment("activate")
        if let activateFailure { throw activateFailure }
    }

    func startCapture() async throws(VoiceConversationFailure) {
        increment("startCapture")
        if captureFailuresRemaining > 0 {
            captureFailuresRemaining -= 1
            throw .noAudioInput
        }
    }

    func stopCapture() { increment("stopCapture") }

    func beginTranscription() async throws(VoiceConversationFailure) {
        increment("begin")
        lock.withLock {
            (storedTranscripts, transcriptSink) = AsyncStream.makeStream(of: String.self)
        }
        if let beginFailure { throw beginFailure }
    }

    func finishTranscription() async {
        increment("finish")
        lock.withLock { transcriptSink }.finish()
    }

    func transcriptionFailureSnapshot() -> VoiceConversationFailure? { nil }

    @discardableResult
    func scheduleChunk(_ chunk: VoiceConversationAudioChunk) -> Bool { true }
    func endQueuedAudio() {}
    func pausePlayback() {}
    func resumePlayback() {}
    func stopPlayback() { increment("stopPlayback") }

    func deactivate() {
        increment("deactivate")
        micSink.finish(); playedSink.finish(); engineSink.finish(); systemSink.finish()
    }
}

final class MicActivationFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [MicActivationStack] = []
    var failuresPerStack: Int = 0
    var injectBeginFailure: VoiceConversationFailure?
    var injectActivateFailure: VoiceConversationFailure?
    func make() -> MicActivationStack {
        let stack = MicActivationStack(captureFailuresRemaining: failuresPerStack)
        stack.beginFailure = injectBeginFailure
        stack.activateFailure = injectActivateFailure
        lock.withLock { made.append(stack) }
        return stack
    }
    var all: [MicActivationStack] { lock.withLock { made } }
    var last: MicActivationStack { all[all.count - 1] }
}

@MainActor
final class MicActivationRig {
    let factory = MicActivationFactory()
    let driving = MicActivationDriving()
    let coordinator: VoiceConversationCoordinator

    init() {
        let clock = MicActivationClock()
        let driving = MicActivationDriving()
        let factory = MicActivationFactory()
        self.driving = driving
        self.factory = factory
        coordinator = VoiceConversationCoordinator(
            authorization: MicActivationAuth(),
            makeStack: { factory.make() },
            driving: driving,
            clock: clock,
            diagnostics: nil
        )
    }

    func settle(_ milliseconds: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        await Task.yield()
    }
}

// MARK: - B: Shared-session last-holder registry (the late-stop defect)

@Suite(.serialized)
struct AudioSessionOwnershipRegistryTests {

    @Test("Deactivation is granted ONLY to the LAST holder's release; a still-held release is inert")
    func lastHolderOnly() {
        let a = UUID()
        let b = UUID()
        FloeAudioSessionOwnership.resetForTesting()
        FloeAudioSessionOwnership.claim(a)
        FloeAudioSessionOwnership.claim(b)
        var deactivations = 0
        // A releasing while B still holds must NOT deactivate — this is the
        // superseded-stack / late dictation-stop case that silenced owners.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(a) { deactivations += 1 }
        #expect(deactivations == 0)
        #expect(FloeAudioSessionOwnership.isHolder(b))
        // B's normal finish IS the last holder → deactivation runs.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(b) { deactivations += 1 }
        #expect(deactivations == 1)
        #expect(FloeAudioSessionOwnership.holderCount == 0)
        FloeAudioSessionOwnership.resetForTesting()
    }

    @Test("Idempotent teardown: a never-claimed or already-released id is inert, and can never deactivate another holder's session")
    func doubleReleaseAndStrangerRelease() {
        let a = UUID()
        let b = UUID()
        FloeAudioSessionOwnership.resetForTesting()
        FloeAudioSessionOwnership.claim(a)
        var deactivations = 0
        FloeAudioSessionOwnership.releaseAndDeactivateLast(a) { deactivations += 1 } // last: legitimate
        FloeAudioSessionOwnership.claim(b)                                            // newer owner activates
        FloeAudioSessionOwnership.releaseAndDeactivateLast(a) { deactivations += 1 }   // late double stop: inert
        let stranger = UUID()
        FloeAudioSessionOwnership.releaseAndDeactivateLast(stranger) { deactivations += 1 } // never claimed: inert
        #expect(deactivations == 1)
        #expect(FloeAudioSessionOwnership.isHolder(b))
        FloeAudioSessionOwnership.releaseAndDeactivateLast(b) { deactivations += 1 }
        #expect(deactivations == 2)
        FloeAudioSessionOwnership.resetForTesting()
    }

    /// Lock-protected race log (Swift 6: shared mutable state across the
    /// concurrent queues lives in one `@unchecked Sendable` box).
    private final class SessionRaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var eventsLog: [String] = []
        // Mirrors the real AVAudioSession activation state at the moment
        // each toggle runs.
        private(set) var active = false
        func claimActivate(id: UUID) {
            // `claim` itself serializes against `releaseAndDeactivateLast`
            // inside the registry; the toggle below models the component's
            // own `setActive(true)` right after it.
            FloeAudioSessionOwnership.claim(id)
            lock.withLock { active = true; eventsLog.append("activate") }
        }
        func deactivateIfLast(_ id: UUID) {
            FloeAudioSessionOwnership.releaseAndDeactivateLast(id) {
                lock.withLock { active = false; eventsLog.append("deactivate") }
            }
        }
        var snapshot: (events: [String], active: Bool) {
            lock.withLock { (eventsLog, active) }
        }
    }

    @Test("TOCTOU closure: a claim/activation can NEVER land between 'last release' and the actual deactivation")
    func lateStopCannotInterleaveNewerActivation() async {
        // The dangerous historical interleaving:
        //   1. old owner: release(...) returns true  (it WAS last)
        //   2. new owner: claim + setActive(true)     (activates)
        //   3. old owner: setActive(false)            (SILENCES the new owner)
        // `releaseAndDeactivateLast` serializes 1+3 under one lock, so the
        // only legal outcomes are: the deactivation never runs (claim was
        // first, set still held), or it runs strictly BEFORE the newer
        // owner's activation. Assert the invariant across many races.
        for _ in 0..<64 {
            let stale = UUID()
            let fresh = UUID()
            FloeAudioSessionOwnership.resetForTesting()
            FloeAudioSessionOwnership.claim(stale)
            // The box runs the newer owner's claim + activation through the
            // SAME registry calls the production paths use.
            let box = SessionRaceBox()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.deactivateIfLast(stale)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    box.claimActivate(id: fresh)
                    group.leave()
                }
                group.notify(queue: .global()) { done.resume() }
            }
            let snapshot = box.snapshot
            // Whenever a deactivation DID run, it necessarily ran before the
            // newer owner's activation (claims serialize behind it).
            if let deactivation = snapshot.events.firstIndex(of: "deactivate"),
               let activation = snapshot.events.firstIndex(of: "activate") {
                #expect(deactivation < activation,
                        "late stop interleaved between last-release and activation: \(snapshot.events)")
            }
            // The new owner's activation is always the final word.
            #expect(snapshot.active, "a stale teardown silenced the newer owner: \(snapshot.events)")
            #expect(FloeAudioSessionOwnership.holderCount == 1)
            FloeAudioSessionOwnership.releaseAndDeactivateLast(fresh) {}
        }
        FloeAudioSessionOwnership.resetForTesting()
    }
}

// MARK: - Recovery gate: the live stack's REAL policy object

struct CaptureRecoveryGateTests {

    @Test("A recovery is allowed once; a config change arriving mid-restart is refused (single flight, never a double restart)")
    func singleFlight() {
        let gate = VoiceCaptureRecoveryGate(limit: 2)
        #expect(gate.beginAttempt(armed: true, stopped: false, holder: true))
        // iPhone reconfiguration fires while the readiness restart runs.
        #expect(!gate.beginAttempt(armed: true, stopped: false, holder: true))
        gate.endAttempt()
        #expect(gate.beginAttempt(armed: true, stopped: false, holder: true))
    }

    @Test("Late stop / supersession / mute refuse recovery even with budget left — cancellation fencing")
    func refusalConditions() {
        var gate = VoiceCaptureRecoveryGate(limit: 2)
        // A stop (pause/close) raced in: never restart a retired stretch.
        #expect(!gate.beginAttempt(armed: true, stopped: true, holder: true))
        // Superseded instance (ownership released): must not touch the
        // shared session/engine.
        gate = VoiceCaptureRecoveryGate(limit: 2)
        #expect(!gate.beginAttempt(armed: true, stopped: false, holder: false))
        // Muted (no armed stretch): the unmute path owns the next proof.
        gate = VoiceCaptureRecoveryGate(limit: 2)
        #expect(!gate.beginAttempt(armed: false, stopped: false, holder: true))
        // None of those consumed budget.
        #expect(gate.attemptsUsed == 0)
    }

    @Test("Budget: bounded consecutive restarts WITHOUT buffers, then visible-failure only; a real buffer refreshes")
    func budgetBoundAndRefresh() {
        let gate = VoiceCaptureRecoveryGate(limit: 2)
        #expect(gate.beginAttempt(armed: true, stopped: false, holder: true))
        gate.endAttempt()
        #expect(gate.beginAttempt(armed: true, stopped: false, holder: true))
        gate.endAttempt()
        // Third consecutive attempt with no delivered buffer: REFUSED —
        // readiness throws / `.captureStalled` surfaces; no silent retry.
        #expect(!gate.beginAttempt(armed: true, stopped: false, holder: true))
        #expect(gate.isExhausted)
        // Real tap buffers arriving refresh the policy for later problems.
        gate.noteProgress()
        #expect(!gate.isExhausted)
        #expect(gate.beginAttempt(armed: true, stopped: false, holder: true))
    }

    @Test("A dead path (no buffer ever) ends exhausted: exactly two restarts attempted, then visible failure only")
    func deadPathTerminates() {
        let gate = VoiceCaptureRecoveryGate(limit: 2)
        var allowed = 0
        for _ in 0..<6 {
            if gate.beginAttempt(armed: true, stopped: false, holder: true) {
                allowed += 1
                gate.endAttempt()
            }
        }
        #expect(allowed == 2) // bounded; the loop terminates visibly
    }
}

// MARK: - A: Bring-up order — drift guard for the list the runtime executes

struct MicGraphOrderContractTests {

    @Test("The executed bring-up sequence installs the mic tap BEFORE prepare/start, like the working dictation capturer (contract hygiene: this list IS what bringUpGraph runs)")
    func inputTapPrecedesEngineStart() {
        let order = VoiceCaptureGraphOrder.recoverySteps // exactly what the live loop iterates
        guard let formats = order.firstIndex(of: .queryInputFormat),
              let outputTap = order.firstIndex(of: .installOutputTap),
              let inputTap = order.firstIndex(of: .installInputTap),
              let prepare = order.firstIndex(of: .prepareEngine),
              let start = order.firstIndex(of: .startEngine) else {
            Issue.record("bring-up sequence is missing a required step")
            return
        }
        #expect(formats < inputTap)
        #expect(outputTap < prepare)
        #expect(inputTap < prepare)
        #expect(prepare < start)
        #expect(Set(order).count == order.count) // no duplicates
    }

    @Test("In-place recovery reuses the SAME ordered steps — a restart can never drift back to tap-after-start")
    func recoveryReusesCanonicalSteps() {
        #expect(VoiceCaptureGraphOrder.recoverySteps
                == Array(VoiceCaptureGraphOrder.bringUp.dropFirst(2)))
        #expect(!VoiceCaptureGraphOrder.recoverySteps.contains(.sessionCategory))
        #expect(!VoiceCaptureGraphOrder.recoverySteps.contains(.sessionActivate))
    }
}

// MARK: - Coordinator contracts around the repaired activation

@MainActor
struct MicActivationCoordinatorTests {

    @Test("A capture path that fails after its in-stack restart fails visibly after EXACTLY one full rebuild, fencing every built stack")
    func deadCaptureFailsAfterOneRebuild() async {
        let rig = MicActivationRig()
        rig.factory.failuresPerStack = Int.max // readiness never proves
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .failed(.noAudioInput))
        // One initial build + exactly one full rebuild — no restart loops.
        #expect(rig.factory.all.count == 2)
        for stack in rig.factory.all {
            #expect(stack.count("activate") == 1)
            #expect(stack.count("startCapture") == 1)
            #expect(stack.count("deactivate") == 1) // fencing: never left holding the session
        }
        // The failed state keeps the retry affordance: a fresh, provable
        // path reaches listening through the same start machine.
        rig.factory.failuresPerStack = 0
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        #expect(rig.factory.all.count == 3)
    }

    @Test("engineConfigurationChanged is INFORMATION ONLY: the stack owns bounded recovery; the coordinator never fails a live session on a route/format settle")
    func configurationChangeAloneKeepsListening() async {
        let rig = MicActivationRig()
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        let stack = rig.factory.last
        stack.yieldSystem(.engineConfigurationChanged)
        await rig.settle()
        // Only a FAILED re-proof surfaces — as `.captureStalled` (covered
        // by the sibling stall tests). A bare reconfiguration must never
        // stop capture or fail the session from the coordinator side.
        #expect(rig.coordinator.state == .listening)
        #expect(stack.count("stopCapture") == 0)
        #expect(stack.count("deactivate") == 0)
        #expect(rig.factory.all.count == 1)
    }

    @Test("Ending while the session is still building fences every built stack: no mic/engine survives an abandoned start")
    func endDuringBuildFencesLateStack() async {
        let rig = MicActivationRig()
        // Exact UI shape: a tap RESERVES + launches synchronously
        // (`requestStart` mirrors the button), then the sheet is closed
        // while permission/graph awaits are still in flight. (An
        // `async let start()` would defer reservation until after `end()`
        // and test nothing.)
        rig.coordinator.requestStart()
        rig.coordinator.end()
        await rig.settle(120)
        #expect(rig.coordinator.state == .idle)
        for stack in rig.factory.all {
            // Whichever guard caught the superseded attempt, nothing may
            // stay activated: every built stack was deactivated exactly
            // once and never resumed listening.
            #expect(stack.count("deactivate") == stack.count("activate"))
        }
    }

    @Test("Build sequence mirrors working dictation: recognizer backend FIRST, graph bring-up second, capture proof last")
    func buildOrderMatchesDictation() async {
        // Same-device iPhone A/B (unpatched 291): dictation — which creates
        // its transcriber before any engine/session — reached 正在听 while
        // the continuous build, which created the backend AFTER activate,
        // failed `voice.error.recognition`. The build order was the last
        // remaining sequence divergence; this pins the alignment.
        let rig = MicActivationRig()
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        let order = rig.factory.last.order
        guard let beginIndex = order.firstIndex(of: "begin"),
              let activateIndex = order.firstIndex(of: "activate"),
              let captureIndex = order.firstIndex(of: "startCapture") else {
            Issue.record("full build sequence recorded: \(order)")
            return
        }
        #expect(beginIndex < activateIndex)
        #expect(activateIndex < captureIndex)
        rig.coordinator.end()
        await rig.settle()
    }

    @Test("A recognizer factory failure surfaces its class and NEVER arms the microphone graph")
    func factoryFailureNeverArmsMicrophone() async {
        // The fresh 291 iPhone failure class: beginTranscription threw a
        // factory/recognizer error while the mic path was fine (dictation
        // proved it). Classification must reach the view unchanged AND the
        // aborted build must not leave a live session/engine behind.
        let rig = MicActivationRig()
        rig.factory.injectBeginFailure = .localeUnsupported
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .failed(.localeUnsupported))
        #expect(rig.factory.all.count == 1) // not rebuild-recoverable: no retry storm
        let stack = rig.factory.last
        #expect(stack.count("begin") == 1)
        #expect(stack.count("activate") == 0) // microphone never armed
        #expect(stack.count("startCapture") == 0)
        #expect(stack.count("deactivate") == 1) // fenced off
        rig.coordinator.end()
        await rig.settle()
    }

    @Test("Unmute re-proves capture through the same readiness machine: a dead path fails visibly, never silently 'listening'")
    func unmuteDeadPathFailsVisibly() async {
        let rig = MicActivationRig()
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        await rig.coordinator.setMuted(true)
        await rig.settle()
        #expect(rig.coordinator.state == .listening) // muted keeps the session, capture stopped
        #expect(rig.factory.last.count("stopCapture") == 1)
        rig.factory.last.captureFailuresRemaining = Int.max // mic path died while muted
        await rig.coordinator.setMuted(false)
        await rig.settle()
        #expect(rig.coordinator.state == .failed(.noAudioInput))
        // No full rebuild over a muted-stretch death decision: unmute
        // failure surfaces on the SAME stack (the live stack already used
        // its bounded internal restart before throwing).
        #expect(rig.factory.all.count == 1)
        #expect(rig.factory.last.count("deactivate") == 1)
    }
}
#endif
