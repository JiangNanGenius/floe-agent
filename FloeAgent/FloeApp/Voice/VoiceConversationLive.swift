// FloeApp — Continuous voice conversation: production duplex audio stack.
//
// SPDX-License-Identifier: MPL-2.0
//
// ONE shared AVAudioEngine owns both directions so synthesized speech is
// ALWAYS the AEC output reference the microphone voice processing cancels
// against — the requirement behind barge-in on speakerphone:
//
//   inputNode (setVoiceProcessingEnabled → Apple echo cancellation + noise
//   suppression) --tap--> [AEC-cleaned mic] → meter → `levels` AND the
//   REUSED transcription backend (same selection as dictation: Whisper
//   local when installed, stable SFSpeechRecognizer otherwise; no new ASR
//   service, no extra cloud ASR)
//   playerNode --(mixed)--> mainMixerNode --tap--> `playedLevels` REAL
//   speaker-bound PCM amplitude (what the orb animates from) --> output
//
// The microphone is NEVER connected to the output; the player feeds the same
// engine whose output Apple's voice processing uses as the echo reference.
//
// Session discipline:
// - `.playAndRecord` + `.voiceChat` with `.defaultToSpeaker` /
//   `.allowBluetoothA2DP`.
// - OBSERVED USER FACTS (2026-10-24, iPhone + M4 reports): continuous voice
//   failed with the `.noAudioInput` "未找到麦克风" copy while ordinary
//   Whisper dictation worked; later, dictation ALSO failed after TTS
//   previews and a voice-session stop on the M4. PHYSICAL root cause is NOT
//   yet device-proven — the two source-derived defect candidates repaired
//   here (pending fixed-App device evidence) are:
//   1. BRING-UP ORDER: dictation (working) installs its mic tap BEFORE
//      `engine.prepare()`/`engine.start()`; this stack previously installed
//      the mic tap only later, on an ALREADY-STARTED voice-processed engine
//      — an ordering that can silently never deliver buffers. The ordered
//      steps now live in `VoiceCaptureGraphOrder.bringUp` and BOTH bring-up
//      AND in-place recovery execute that same list.
//   2. SHARED-SESSION LAST-HOLDER DISCIPLINE: every component toggles the
//      ONE `AVAudioSession`; a late/abandoned stop (the handoff explicitly
//      abandons drains past 2 s) previously deactivated the session under a
//      newer owner. Deactivation now happens only for the LAST holder in
//      `FloeAudioSessionOwnership` (continuous stacks AND the dictation
//      capturer participate; SpeechService playback adoption is handed off
//      to its owner). Counting never made category SWITCHING safe — see the
//      lane handoff for the remaining playback-adoption gap.
// - RECOVERY, bounded: a readiness timeout or an engine reconfiguration
//   (voice processing can fire `AVAudioEngineConfigurationChange` after
//   start and stop the engine — iPhone behavior to confirm on device)
//   `VoiceCaptureRecoveryBudget.limit` consecutive in-place restarts per
//   capture stretch — engine stop, tap+format re-probe, tap BEFORE
//   restart, re-prove the first buffer. Any real buffer refreshes the
//   budget. Recovery is never an invisible restart loop: exhaustion
//   surfaces `.noAudioInput` / `.captureStalled` so the coordinator
//   rebuilds once and then fails visibly with actionable copy.
// - A superseded stack instance NEVER deactivates the shared
//   `AVAudioSession`: deactivation requires releasing the LAST holder in
//   the app-wide `FloeAudioSessionOwnership` registry (dictation and TTS
//   playback participate — a late abandoned stop can no longer silence a
//   newer owner mid-stretch). No callback into AppEnvironment; the app
//   layer already ORs the presentation's activity into its PiP gates.
// - Simulator: mirrors the PROVEN dictation guard — `noAudioInput` is thrown
//   BEFORE touching `engine.inputNode`, because the simulator RemoteIO
//   service can abort the process below Swift error handling when no host
//   microphone is routed. Simulator UI acceptance therefore injects fake
//   stacks and never claims real capture/AEC from this file.
// - No audio is ever persisted. Buffers flow through memory only.
//
// Played-progress truth: per-scheduled-buffer completion callbacks with an
// epoch guard. `pause()` freezes the position, `play()` continues it,
// `stop()` fences the epoch BEFORE flushing the player, then clears the queue
// and resets the counter so a finished/cancelled round can never leak
// progress into the next. Every played-frame event carries the scheduling
// epoch through the stream; the coordinator drops an event whose epoch is not
// the stack's current one. Receipts and drain decisions derive ONLY from
// these real played frames — never from a TTS producer's final flag.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import FloeCore
import FloeProviders

// MARK: - Authorization bridge (reuses the exact dictation prompts)

extension SystemSpeechAuthorizationProvider: VoiceConversationAuthorizationProviding {}

// MARK: - Live stack

/// Nonisolated `@unchecked Sendable`, exactly like the proven dictation
/// `AudioEngineCapturer`: render-thread tap and schedule-completion callbacks
/// touch internal lock-protected state only. The coordinator — the sole
/// caller of the protocol methods — runs on the main actor.
final class VoiceConversationLiveStack: VoiceConversationStack, @unchecked Sendable {

    // Engine graph
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Shared playback rate/intonation unit, inserted ONLY on the duplex
    /// OUTPUT edge (player → timePitch → mixer). The microphone/VPIO input
    /// path never touches it, so echo cancellation still references the real
    /// speaker output. One unit is reused across rounds; its configuration is
    /// frozen per round and written only while the output queue is idle.
    private let speechEffect = SpeechPlaybackEffectGraph()
    /// Round-consistent controls delivered by the coordinator before the
    /// round's first chunk (applied once at an idle queue).
    private var appliedPlaybackControls = VoicePlaybackControls.neutral
    /// REAL mixer-rendered output frames in the current epoch (output tap).
    /// This is a frame clock, not progress and not a content census.
    private var renderedOutputFrames = 0
    private var renderedOutputSampleRate: Double = 0
    private var inputFormat: AVAudioFormat?
    private var playerFormat: AVAudioFormat?
    private var tapInstalled = false
    private var outputTapInstalled = false
    private var playerConnected = false
    private var engineStarted = false
    private var sessionActivated = false
    private let stackID = UUID()
    private let graphLock = NSLock()

    // Streams
    let levels: AsyncStream<VoiceConversationLevel>
    let playedLevels: AsyncStream<VoiceConversationLevel>
    let engineEvents: AsyncStream<VoiceConversationEngineEvent>
    let systemEvents: AsyncStream<VoiceConversationSystemEvent>
    private let levelContinuation: AsyncStream<VoiceConversationLevel>.Continuation
    private let playedLevelContinuation: AsyncStream<VoiceConversationLevel>.Continuation
    private let engineEventContinuation: AsyncStream<VoiceConversationEngineEvent>.Continuation
    private let systemEventContinuation: AsyncStream<VoiceConversationSystemEvent>.Continuation

    /// ONE stream per transcription session: the coordinator RESTARTS ASR
    /// in place (recognizers may end their own streams), and a resubscribed
    /// consumer must never see the previous, already-finished stream.
    var transcripts: AsyncStream<String> {
        backendLock.withLock { currentTranscripts }
    }
    private var currentTranscripts: AsyncStream<String>
    private var transcriptContinuation: AsyncStream<String>.Continuation

    // Meters (mic after voice processing, and the mixed output bus)
    private let micLock = NSLock()
    private var micMeter = VoiceActivityMeter()
    private let playedLock = NSLock()
    private var playedMeter = VoiceActivityMeter()

    // Transcription backend (existing seams only)
    private let language: VoiceRecognitionLanguage
    private let backendLock = NSLock()
    private var backend: (any SpeechTranscribing)?
    private var backendFeed: Task<Void, Never>?
    private var audioFinished = false
    private var terminalFailure: VoiceConversationFailure?

    // Capture readiness + stall detection (same proof the dictation
    // `AudioEngineCapturer` requires: installing a tap is NOT readiness;
    // at least one REAL buffer arriving is).
    private let captureLock = NSLock()
    private var receivedFirstBuffer = false
    private var readinessStopped = false
    private var readinessWaiter: CheckedContinuation<Void, Error>?
    private var readinessTimeout: Task<Void, Never>?
    private var captureActive = false
    private var lastBufferUptimeNanos: UInt64 = 0
    private var stallTask: Task<Void, Never>?
    /// Bounded in-place graph recovery policy (see the file header). The
    /// gate owns its own lock and its own single-flight/budget state; the
    /// live stack routes EVERY recovery decision through it.
    private let recoveryGate = VoiceCaptureRecoveryGate()
    private var recoveryInFlight: Bool { recoveryGate.isInFlight }
    /// Silence ALSO delivers buffers. If NO tap buffer arrives for this long
    /// while capture is active, the microphone path is dead: one bounded
    /// in-place recovery is attempted first; if that fails, report
    /// `.captureStalled` so the coordinator fails visibly.
    fileprivate let captureStallSeconds: Double = 10
    fileprivate let captureReadinessSeconds: Double = 3

    // Played-frame accounting (epoch-fenced)
    private let playbackLock = NSLock()
    private var epoch: UInt64 = 0
    private var scheduledFrames = 0
    private var completedFrames = 0
    /// EXPLICIT pause intent (2026-10-25): consulted by every auto-start
    /// site so accepted-during-pause buffers queue instead of silently
    /// resuming output. Guarded by `playbackLock` with the epoch it is
    /// scoped to.
    private var playbackIntent = VoicePlaybackIntentGate()
    /// Last closed-vocabulary scheduling refusal cause, for transition-only
    /// diagnostics (never one line per retry). Guarded by `playbackLock`.
    private var lastScheduleRejectCause: String?
    private static let engineMaxPendingSeconds = 60.0

    // Resampling cache (protocol calls are serialized by the coordinator)
    private var converterCache: [String: AVAudioConverter] = [:]

    /// Diagnostics/tests only: number of retained resampler AUs.
    var converterCacheCount: Int { converterCache.count }

    private var observers: [NSObjectProtocol] = []

    var outputSampleRate: Double {
        graphLock.withLock { playerFormat?.sampleRate ?? 48_000 }
    }

    init(language: VoiceRecognitionLanguage = .automatic) {
        self.language = language
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (playedLevels, playedLevelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (currentTranscripts, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        (engineEvents, engineEventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (systemEvents, systemEventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        engine.attach(playerNode)
    }

    // MARK: - Activation

    func activate() async throws(VoiceConversationFailure) {
        if graphLock.withLock({ engineStarted }) { return }
        // PROVEN simulator guard (same rationale as dictation's
        // AudioEngineCapturer): NEVER touch engine.inputNode on the
        // simulator — RemoteIO can abort the process below Swift errors.
        #if targetEnvironment(simulator)
        throw .noAudioInput
        #else
        FloeAudioSessionOwnership.claim(stackID)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
        } catch {
            Self.logGraphFailure(.sessionCategory, error)
            _ = FloeAudioSessionOwnership.release(stackID)
            throw .noAudioInput
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logGraphFailure(.sessionActivate, error)
            _ = FloeAudioSessionOwnership.release(stackID)
            throw .noAudioInput
        }
        graphLock.withLock { sessionActivated = true }

        do {
            try bringUpGraph()
        } catch let failure {
            rollbackActivation()
            throw failure
        }
        installSystemObservers()
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Executes the canonical bring-up sequence for the audio graph.
    /// `sessionCategory`/`sessionActivate` belong to `activate()` (they are
    /// tied to session OWNERSHIP); everything after them — INCLUDING the
    /// input tap installation before `prepareEngine`/`startEngine` — runs
    /// from `VoiceCaptureGraphOrder.bringUp`, the same list an in-place
    /// recovery re-executes. The order is asserted by
    /// ContinuousVoiceMicrophoneActivationTests: this is the fix for the
    /// iPhone-only `.noAudioInput` (a tap installed on an already-started
    /// voice-processed engine could silently never fire) and it must not
    /// drift back.
    private func bringUpGraph() throws(VoiceConversationFailure) {
        for step in VoiceCaptureGraphOrder.recoverySteps {
            try runGraphStep(step)
        }
    }

    private func runGraphStep(_ step: VoiceCaptureGraphStep) throws(VoiceConversationFailure) {
        switch step {
        case .sessionCategory, .sessionActivate:
            break // activate()/recoverCaptureGraph() own the session steps.
        case .enableVoiceProcessing:
            // Apple voice-processing IO: echo cancellation against the
            // engine's OWN output (the player below rides the same engine),
            // plus noise suppression. Output is NEVER fed back to input.
            // Idempotent — safe to re-run inside a recovery restart.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                Self.logGraphFailure(.enableVoiceProcessing, error)
                throw .noAudioInput
            }
        case .queryInputFormat:
            try resolveGraphFormats()
        case .connectPlayer:
            guard let playerFmt = graphLock.withLock({ playerFormat }) else {
                Self.logGraphStepFailed(.connectPlayer, "format=0")
                throw .noAudioInput
            }
            if graphLock.withLock({ playerConnected }) {
                engine.disconnectNodeInput(playerNode)
            }
            // Same production wiring as ordinary read-aloud: the shared unit
            // sits between the player and the mixer, so AEC still cancels
            // against the ACTUAL output and the level tap stays post-effect.
            speechEffect.install(in: engine, from: playerNode,
                                 to: engine.mainMixerNode, format: playerFmt)
            graphLock.withLock { playerConnected = true }
        case .installOutputTap:
            guard let playerFmt = graphLock.withLock({ playerFormat }) else {
                Self.logGraphStepFailed(.installOutputTap, "format=0")
                throw .noAudioInput
            }
            // Output-side metering: the mixer bus that feeds the speaker — the
            // REAL played PCM amplitude. During player pause the graph renders
            // silence, so the meter decays honestly to zero.
            if graphLock.withLock({ outputTapInstalled }) {
                engine.mainMixerNode.removeTap(onBus: 0)
            }
            engine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 4_096,
                format: playerFmt
            ) { [weak self] buffer, _ in
                self?.publishPlayedLevel(of: buffer)
                self?.countRenderedOutput(of: buffer)
            }
            graphLock.withLock { outputTapInstalled = true }
        case .installInputTap:
            // THE ROOT-CAUSE STEP. Tap BEFORE start (proven dictation order),
            // never on a running engine during bring-up.
            guard let micFormat = graphLock.withLock({ inputFormat }) else {
                Self.logGraphStepFailed(.installInputTap, "format=0")
                throw .noAudioInput
            }
            installInputTap(format: micFormat)
        case .prepareEngine:
            engine.prepare()
        case .startEngine:
            do {
                try engine.start()
                graphLock.withLock { engineStarted = true }
            } catch {
                Self.logGraphFailure(.startEngine, error)
                throw .noAudioInput
            }
        }
        Self.logGraphStep(step)
    }

    /// Validates and stores BOTH graph formats (microphone after voice
    /// processing, engine output for the player). Counts-only diagnostics:
    /// an invalid format is named by step, never by route/device labels.
    private func resolveGraphFormats() throws(VoiceConversationFailure) {
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            Self.logGraphStepFailed(
                .queryInputFormat,
                "input=\(Int(micFormat.sampleRate))x\(Int(micFormat.channelCount))"
            )
            throw .noAudioInput
        }
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        guard let playerFmt = outFormat.sampleRate > 0
            ? outFormat
            : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        else {
            Self.logGraphStepFailed(.queryInputFormat, "player=0")
            throw .noAudioInput
        }
        graphLock.withLock {
            inputFormat = micFormat
            playerFormat = playerFmt
        }
    }

    /// Installs (or replaces) the microphone tap on the input node.
    private func installInputTap(format: AVAudioFormat) {
        let input = engine.inputNode
        if graphLock.withLock({ tapInstalled }) {
            input.removeTap(onBus: 0)
        }
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self] buffer, time in
            guard buffer.frameLength > 0 else { return }
            self?.markCaptureBuffer()
            self?.publishMicLevel(of: buffer)
            self?.feedBackend(buffer, at: time)
        }
        graphLock.withLock { tapInstalled = true }
    }

    private func rollbackActivation() {
        graphLock.lock()
        let hadTap = tapInstalled
        let hadOutputTap = outputTapInstalled
        let connected = playerConnected
        let started = engineStarted
        tapInstalled = false
        outputTapInstalled = false
        playerConnected = false
        engineStarted = false
        let activate = sessionActivated
        sessionActivated = false
        graphLock.unlock()
        if hadTap { engine.inputNode.removeTap(onBus: 0) }
        if hadOutputTap { engine.mainMixerNode.removeTap(onBus: 0) }
        if connected { engine.disconnectNodeInput(playerNode) }
        if started { engine.stop() }
        // A failed bring-up may already have inserted the shared unit; detach
        // it so a later activation starts from a clean graph (the engine,
        // microphone and voice-processing configuration are unaffected).
        speechEffect.uninstall()
        // ATOMIC last-holder release + deactivation: a newer component
        // cannot claim/activate in the gap and then be silenced by this
        // rollback (the release->Bool + setActive(false) two-step had
        // exactly that TOCTOU).
        if activate {
            FloeAudioSessionOwnership.releaseAndDeactivateLast(stackID) {
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation
                )
            }
        }
    }
    #endif

    // MARK: - Capture

    /// Returns ONLY after the first REAL buffer arrives (≤3 s, the proven
    /// dictation readiness pattern). A tap that never fires is a dead capture
    /// path — BUT before declaring it dead, exactly ONE bounded in-place
    /// restart runs (`recoverCaptureGraph`: engine stop, tap reinstalled
    /// BEFORE the engine restarts, fresh proof window), because on iPhone an
    /// engine that stopped/reconfigured after start leaves a running-engine
    /// installed tap silently dead. A path still unproven after the
    /// tap-before-start restart throws `.noAudioInput` so the coordinator can
    /// rebuild once and then fail visibly. The stall watchdog keeps watching
    /// for the rest of the capture stretch — a tap that goes quiet mid-
    /// session gets the same bounded recovery before `.captureStalled`.
    func startCapture() async throws(VoiceConversationFailure) {
        #if targetEnvironment(simulator)
        throw .noAudioInput
        #else
        let readiness = graphLock.withLock {
            (started: engineStarted, installed: tapInstalled, format: inputFormat)
        }
        guard readiness.started, let micFormat = readiness.format else {
            Self.logGraphStepFailed(
                .installInputTap,
                "startCapture=0 started=\(readiness.started ? 1 : 0) formatMissing=\(readiness.format == nil ? 1 : 0)"
            )
            throw .noAudioInput
        }
        if !readiness.installed {
            // Re-arm after mute: the engine stays running for answer playback
            // while muted, so this installation necessarily happens on a
            // running engine. The proof below and the single restart recovery
            // backstop it — only proven buffers may present "Listening".
            installInputTap(format: micFormat)
        }
        resetCaptureReadiness()
        do {
            try await waitCaptureReady()
        } catch {
            let recovered = await requestCaptureRecovery(reason: "readiness")
            guard recovered else {
                Self.logGraphEvent("event=readinessFailed reason=startup recovery=0")
                stopCapture()
                throw .noAudioInput
            }
            do {
                try await waitCaptureReady()
            } catch {
                Self.logGraphEvent("event=readinessFailed reason=startup recovery=1")
                stopCapture()
                throw .noAudioInput
            }
        }
        startCaptureStallWatchdog()
        #endif
    }

    func stopCapture() {
        #if !targetEnvironment(simulator)
        captureLock.withLock {
            captureActive = false
            readinessStopped = true
        }
        stallTask?.cancel()
        stallTask = nil
        finishReadiness(.failure(VoiceSessionError.failure(.noAudioInput)))
        let hadTap = graphLock.withLock {
            let value = tapInstalled
            tapInstalled = false
            return value
        }
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        #endif
    }

    // MARK: - Capture readiness (real first-buffer proof)

    private func resetCaptureReadiness() {
        captureLock.withLock {
            captureActive = true
            receivedFirstBuffer = false
            readinessStopped = false
            lastBufferUptimeNanos = DispatchTime.now().uptimeNanoseconds
        }
    }

    private nonisolated func markCaptureBuffer() {
        captureLock.withLock {
            receivedFirstBuffer = true
            lastBufferUptimeNanos = DispatchTime.now().uptimeNanoseconds
        }
        // A REAL buffer is proof of life: a later problem gets the full
        // bounded recovery budget again (gate owns its own lock; never
        // nested under captureLock).
        recoveryGate.noteProgress()
        finishReadiness(.success(()))
    }

    private func waitCaptureReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                captureLock.lock()
                if readinessStopped || Task.isCancelled {
                    captureLock.unlock()
                    waiter.resume(throwing: VoiceSessionError.failure(.noAudioInput))
                    return
                }
                if receivedFirstBuffer {
                    captureLock.unlock()
                    waiter.resume()
                    return
                }
                guard readinessWaiter == nil else {
                    // A readiness wait is already running (only reachable by
                    // racing callers): never overwrite the live continuation.
                    captureLock.unlock()
                    waiter.resume(throwing: VoiceSessionError.failure(.noAudioInput))
                    return
                }
                readinessWaiter = waiter
                readinessTimeout = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: .seconds(self.captureReadinessSeconds)) }
                    catch { return }
                    self.finishReadiness(.failure(VoiceSessionError.failure(.noAudioInput)))
                }
                captureLock.unlock()
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            let pending = self.captureLock.withLock { () -> Bool in
                self.readinessStopped = true
                return self.readinessWaiter != nil
            }
            if pending {
                self.finishReadiness(.failure(VoiceSessionError.failure(.noAudioInput)))
            }
        }
    }

    private func finishReadiness(_ result: Result<Void, Error>) {
        captureLock.lock()
        let waiter = readinessWaiter
        readinessWaiter = nil
        let timeout = readinessTimeout
        readinessTimeout = nil
        captureLock.unlock()
        timeout?.cancel()
        waiter?.resume(with: result)
    }

    /// Bounded, single-flight in-place recovery of the capture graph, shared
    /// by EVERY dead-tap surface: a readiness timeout during start/unmute, an
    /// engine reconfiguration, and the stall watchdog. It stops the engine,
    /// drops both taps and re-executes the canonical `bringUpGraph()`
    /// sequence — the input tap goes back on BEFORE `prepareEngine` /
    /// `startEngine`, the proven dictation ordering — then hands the caller a
    /// fresh readiness window. Refused (budget, teardown race, another
    /// recovery in flight) returns false: recovery is bounded and can NEVER
    /// become an invisible restart loop; the caller fails visibly.
    private func recoverCaptureGraph(reason: String) async -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let preconditions = captureLock.withLock { (armed: captureActive, stopped: readinessStopped) }
        let holder = graphLock.withLock { sessionActivated }
            && FloeAudioSessionOwnership.isHolder(stackID)
        let mayAttempt = recoveryGate.beginAttempt(
            armed: preconditions.armed,
            stopped: preconditions.stopped,
            holder: holder
        )
        guard mayAttempt else {
            Self.logGraphEvent("event=recoverySkipped reason=\(reason)")
            return false
        }
        defer { recoveryGate.endAttempt() }
        // A route/format settle can leave the session momentarily inactive on
        // iPhone; re-assert FIRST (holder gate above proved this instance is
        // still a live owner — a superseded instance never gets here).
        do {
            try AVAudioSession.sharedInstance().setActive(
                true, options: .notifyOthersOnDeactivation
            )
        } catch {
            Self.logGraphFailure(.sessionActivate, error)
            return false
        }
        engine.stop()
        graphLock.withLock { engineStarted = false }
        if graphLock.withLock({ tapInstalled }) {
            engine.inputNode.removeTap(onBus: 0)
            graphLock.withLock { tapInstalled = false }
        }
        if graphLock.withLock({ outputTapInstalled }) {
            engine.mainMixerNode.removeTap(onBus: 0)
            graphLock.withLock { outputTapInstalled = false }
        }
        do {
            try bringUpGraph()
        } catch let failure {
            rollbackActivation()
            Self.logGraphEvent("event=recoveryFailed reason=\(reason) failure=\(failure.rawValue)")
            return false
        }
        // Final ownership gate: `stopCapture`/`deactivate` may have landed
        // WHILE the restart ran. A retired stack must never leave a live
        // engine with taps attached — roll the fresh graph straight back and
        // let the coordinator's own teardown own the outcome.
        let stillOwned = graphLock.withLock { sessionActivated }
        let stopped = captureLock.withLock { readinessStopped }
        guard stillOwned, !stopped else {
            rollbackActivation()
            Self.logGraphEvent(
                "event=recoveryAbandoned reason=\(reason) owned=\(stillOwned ? 1 : 0) stopped=\(stopped ? 1 : 0)"
            )
            return false
        }
        // The restart interrupted answer playback; resume rendering ONLY
        // when no explicit pause intent is active — a barge or app pause
        // must survive an in-place graph restart, and the queued buffers
        // wait for the legitimate resume instead of silently starting.
        // Played-frame truth is unaffected — completion callbacks of
        // dropped buffers are epoch-fenced and never credit a newer round.
        //
        // COMMAND ORDERING (primary review 2026-10-25): this recovery runs
        // on a non-MainActor executor (watchdog/config-change tasks), while
        // every coordinator-driven pause/resume/stop/schedule control lands
        // on the MainActor. Re-checking the veto and issuing `play()` on a
        // bare lock would leave a window where a pause landing between the
        // check and the call is undone by this replay. Inside the hop the
        // decision and the command form ONE unit serialized with all other
        // playback controls (the lock itself is released before the
        // CoreAudio call inside `mayAutoStartPlayback`).
        await MainActor.run {
            if self.mayAutoStartPlayback() { self.playerNode.play() }
        }
        resetCaptureReadiness()
        Self.logGraphEvent("event=recoveryRestarted reason=\(reason)")
        return true
        #endif
    }

    /// Serialize on the single-flight flag: `recoveryInFlight` spans ONLY the
    /// physical restart (sub-second), never the proof wait, so yielding here
    /// is short. Without this, a config-change recovery and a stall-triggered
    /// recovery could cross into each other's proof window and surface a
    /// false `.captureStalled` / `readinessWaiter` collision.
    private func requestCaptureRecovery(reason: String) async -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        var waited = 0
        while captureLock.withLock({ recoveryInFlight }) && waited < 24 {
            try? await Task.sleep(for: .milliseconds(125))
            waited += 1
        }
        return await recoverCaptureGraph(reason: reason)
        #endif
    }

    /// Engine reconfiguration (route/format settle — iPhone voice processing
    /// fires this and STOPS the engine) must not leave a silently dead tap.
    /// Runs the shared bounded recovery and re-proves real buffers; only a
    /// failed re-proof while the session still owns an armed stretch surfaces
    /// `.captureStalled`. A config change with no armed capture (bring-up
    /// race, mute) is left to `startCapture`'s own recovery. A stretch whose
    /// proof window is already owned by `startCapture`/watchdog is left to
    /// that owner — never a second waiter over the same tap.
    private func recoverAfterConfigurationChange() async {
        #if !targetEnvironment(simulator)
        let armed = captureLock.withLock {
            captureActive && !recoveryInFlight && !readinessStopped && readinessWaiter == nil
        }
        guard armed else { return }
        guard await requestCaptureRecovery(reason: "configChange") else { return }
        do {
            try await waitCaptureReady()
            Self.logGraphEvent("event=configRecovery ok=1")
        } catch {
            let owned = captureLock.withLock {
                captureActive && !readinessStopped && !recoveryInFlight && readinessWaiter == nil
            }
            guard owned else { return } // pause/teardown or another owner decides
            Self.logGraphEvent("event=configRecovery ok=0")
            systemEventContinuation.yield(.captureStalled)
            captureLock.withLock { captureActive = false }
        }
        #endif
    }

    private func startCaptureStallWatchdog() {
        stallTask?.cancel()
        let limitNanos = UInt64(captureStallSeconds * 1_000_000_000)
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.captureLock.withLock {
                    (
                        active: self.captureActive,
                        last: self.lastBufferUptimeNanos,
                        inRecovery: self.recoveryInFlight
                    )
                }
                guard snapshot.active else { return }
                let elapsed = DispatchTime.now().uptimeNanoseconds &- snapshot.last
                if elapsed < limitNanos { continue }
                if snapshot.inRecovery { continue } // the restart owns the window
                // Silence ALSO delivers buffers, so a full gap means the tap
                // DIED mid-session. One bounded in-place restart runs BEFORE
                // declaring it: an iPhone reconfiguration must not become a
                // false "no microphone". If the restart cannot prove fresh
                // buffers, fail visibly — never an indefinite Listening.
                let recovered = await self.requestCaptureRecovery(reason: "stalled")
                if recovered {
                    do {
                        try await self.waitCaptureReady()
                        continue // alive again; the reset clock keeps watching
                    } catch {
                        // Fall through to the ownership check below.
                    }
                }
                let decision = self.captureLock.withLock {
                    (
                        active: self.captureActive,
                        stopped: self.readinessStopped,
                        inRecovery: self.recoveryInFlight,
                        proofOwned: self.readinessWaiter != nil
                    )
                }
                guard decision.active, !decision.stopped else { return } // pause/teardown owns the outcome
                if decision.inRecovery || decision.proofOwned { continue } // another owner is proving now
                self.systemEventContinuation.yield(.captureStalled)
                self.captureLock.withLock { self.captureActive = false }
                return
            }
        }
    }

    // MARK: - Graph diagnostics (sanitized: step names + OS codes only)

    private static func logGraphStep(_ step: VoiceCaptureGraphStep) {
        FloeLogger(category: .app).info("voiceLiveGraph step=\(step.rawValue) ok=1")
    }

    private static func logGraphFailure(_ step: VoiceCaptureGraphStep, _ error: Error) {
        let nsError = error as NSError
        FloeLogger(category: .app).warning(
            "voiceLiveGraph step=\(step.rawValue) ok=0 domain=\(nsError.domain) code=\(nsError.code)"
        )
    }

    private static func logGraphStepFailed(_ step: VoiceCaptureGraphStep, _ detail: String) {
        FloeLogger(category: .app).warning("voiceLiveGraph step=\(step.rawValue) ok=0 \(detail)")
    }

    private static func logGraphEvent(_ message: String) {
        FloeLogger(category: .app).info("voiceLiveGraph \(message)")
    }

    // MARK: - Transcription (existing backends through existing seams)

    func beginTranscription() async throws(VoiceConversationFailure) {
        await retireBackend()
        let fresh: any SpeechTranscribing
        do {
            fresh = try await Self.makeBackend(language: language)
        } catch let failure as VoiceConversationFailure {
            throw failure
        } catch is CancellationError {
            throw .recognizerFailed
        } catch {
            throw .recognizerFailed
        }
        // Scoped locking: NSLock.lock()/unlock() are unavailable from async
        // contexts in Swift 6; the critical section itself is synchronous.
        backendLock.withLock {
            audioFinished = false
            terminalFailure = nil
            backend = fresh
            // Fresh stream for the fresh backend session (see property docs).
            (currentTranscripts, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        }
        backendFeed = Task { [weak self, fresh] in
            for await text in fresh.transcripts {
                guard let self else { return }
                let sink = self.backendLock.withLock { self.transcriptContinuation }
                sink.yield(text)
            }
            if let failure = fresh.failure {
                self?.backendLock.withLock { self?.terminalFailure = Self.map(failure) }
            }
            let sink = self?.backendLock.withLock { self?.transcriptContinuation }
            sink?.finish()
        }
    }

    func finishTranscription() async {
        let retire = backendLock.withLock { () -> (any SpeechTranscribing)? in
            guard !audioFinished else { return nil }
            audioFinished = true
            return backend
        }
        if let retire {
            await retire.finishAudio()
        }
        backendFeed?.cancel()
        backendFeed = nil
        backendLock.withLock { transcriptContinuation }.finish()
    }

    func transcriptionFailureSnapshot() -> VoiceConversationFailure? {
        backendLock.withLock { terminalFailure }
    }

    private func retireBackend() async {
        let previous = backendLock.withLock { () -> (any SpeechTranscribing)? in
            let value = backend
            backend = nil
            return value
        }
        let feed = backendLock.withLock { () -> Task<Void, Never>? in
            let value = backendFeed
            backendFeed = nil
            return value
        }
        if let previous {
            await previous.finishAudio()
        }
        feed?.cancel()
        _ = await feed?.value
    }

    /// Tap-thread safe: the backend reference may be retired mid-buffer;
    /// dropping buffers during a retire window is safe and never corrupts
    /// the analyzer (same rule as the dictation capturer).
    private nonisolated func feedBackend(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let current = backendLock.withLock { backend }
        current?.feed(buffer, at: time)
    }

    /// REUSES the dictation-owned canonical factory
    /// (`VoiceInputController.makePreferredTranscriber`) so continuous voice
    /// and dictation never diverge: it honors `VoiceRecognitionPreferences
    /// .method` (automatic/system/enhanced) and the exact existing
    /// Whisper → Apple fallback. No new ASR library and no parallel selector
    /// lives here.
    @MainActor
    private static func makeBackend(language: VoiceRecognitionLanguage) async throws -> any SpeechTranscribing {
        do {
            let transcriber = try await VoiceInputController.makePreferredTranscriber(
                language: language,
                diagnostics: nil
            )
            FloeLogger(category: .app).info("voiceConversationBackendSelected domain=voice")
            return transcriber
        } catch let error as VoiceSessionError {
            throw VoiceConversationLiveStack.map(error.failure)
        } catch is CancellationError {
            throw VoiceConversationFailure.interrupted
        }
    }

    private static func map(_ failure: VoiceInputFailure) -> VoiceConversationFailure {
        switch failure {
        case .microphonePermissionDenied: return .microphonePermissionDenied
        case .speechPermissionDenied: return .speechPermissionDenied
        case .localeUnsupported: return .localeUnsupported
        case .modelNotReady: return .modelNotReady
        case .noAudioInput: return .noAudioInput
        case .recognizerFailed: return .recognizerFailed
        case .interrupted: return .interrupted
        }
    }

    // MARK: - Playback

    @discardableResult
    func scheduleChunk(_ chunk: VoiceConversationAudioChunk) -> VoiceConversationScheduleResult {
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        guard chunk.isValid else { return reject(.invalid) }
        guard graphLock.withLock({ engineStarted }) else { return reject(.notStarted) }
        guard let playerFmt = graphLock.withLock({ playerFormat }) else { return reject(.noFormat) }
        let outFrames = Self.convertedFrames(
            chunkFrames: chunk.frameCount,
            chunkRate: chunk.sampleRate,
            outRate: playerFmt.sampleRate
        )
        guard outFrames >= 0 else { return reject(.format) }
        let capacity = Int(Self.engineMaxPendingSeconds * playerFmt.sampleRate)
        let pending = playbackLock.withLock { scheduledFrames - completedFrames }
        guard pending + outFrames <= capacity else { return reject(.pending) }
        guard let source = Self.buffer(from: chunk) else { return reject(.buffer) }
        guard let converted = convert(source, to: playerFmt) else { return reject(.convert) }
        let frames = Int(converted.frameLength)
        // A zero-frame conversion is a CONSUMED chunk: the resampler is
        // holding the input for a later output block. Report it as scheduled
        // with 0 frames — never as capacity (that would retry consumed input)
        // and never as a receipt (no output existed yet).
        guard frames > 0 else {
            clearRejectCause()
            return .scheduled(frames: 0)
        }
        let capturedEpoch = playbackLock.withLock { () -> UInt64 in
            scheduledFrames += frames
            return epoch
        }
        clearRejectCause()
        // Completion is requested for `.dataPlayedBack` — the buffer has
        // ACTUALLY finished playing through the output device — never
        // `.dataConsumed`: played-frame progress must stay honest.
        playerNode.scheduleBuffer(
            converted,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] _ in
                guard let self else { return }
                let advance = self.playbackLock.withLock { () -> Int? in
                    guard self.epoch == capturedEpoch else { return nil }
                    self.completedFrames += frames
                    return self.completedFrames
                }
                if let advance {
                    // Keep the SCHEDULING epoch on the event: the coordinator
                    // drops it if a stop fenced a newer epoch after this
                    // buffer was queued. Without the tag, a receipt already
                    // buffered in the stream could credit the next round.
                    self.engineEventContinuation.yield(
                        .playedFramesTagged(frames: advance, epoch: capturedEpoch)
                    )
                }
            }
        )
        // Auto-start is INTENT-gated (2026-10-25): an accepted buffer may
        // queue while an explicit pause holds, but it can never silently
        // resume rendering — the legitimate `resumePlayback()` (false-start
        // at the same position / manual resume / fresh-epoch start) is the
        // only path that releases the veto.
        if !playerNode.isPlaying, mayAutoStartPlayback() { playerNode.play() }
        return .scheduled(frames: frames)
        #endif
    }

    /// Closed-vocabulary scheduling refusal causes. Logged only on a cause
    /// TRANSITION, never per retry: a stuck producer retrying the same chunk
    /// at audio rate must not flood the diagnostics with identical lines.
    private enum ScheduleRejectCause: String {
        case invalid, notStarted, noFormat, format, pending, buffer, convert
    }

    private func reject(_ cause: ScheduleRejectCause) -> VoiceConversationScheduleResult {
        let shouldLog = playbackLock.withLock { () -> Bool in
            guard lastScheduleRejectCause != cause.rawValue else { return false }
            lastScheduleRejectCause = cause.rawValue
            return true
        }
        if shouldLog {
            Self.logGraphEvent("event=scheduleReject cause=\(cause.rawValue)")
        }
        switch cause {
        case .pending:
            return .transientCapacity
        case .notStarted, .noFormat:
            return .unavailable
        case .invalid, .format, .buffer, .convert:
            return .failed
        }
    }

    private func clearRejectCause() {
        playbackLock.withLock {
            if lastScheduleRejectCause != nil { lastScheduleRejectCause = nil }
        }
    }

    /// No engine action: drain truth is played frames reaching the
    /// coordinator's queued total. Kept for seam symmetry.
    func endQueuedAudio() {}

    /// Production decision seam: EXPLICIT pause intent for the CURRENT
    /// epoch vetoes every auto-start site (scheduleChunk arrival, graph
    /// recovery). Queueing and played-frame truth are untouched: a paused
    /// player keeps its scheduled buffers and its position. COMMAND
    /// ORDERING: every site pairs this check with its `play()` inside one
    /// MainActor job — `scheduleChunk`/`pause`/`resume`/`stop` are called
    /// synchronously from the @MainActor coordinator, and the only
    /// off-actor consumer (the capture-recovery restart) issues check+play
    /// through a `MainActor.run` hop — so a pause can never land between
    /// the veto read and the command. Tests exercise the real gate and the
    /// stack seam; the simulator cannot run the AVAudio graph.
    func mayAutoStartPlayback() -> Bool {
        playbackLock.withLock { playbackIntent.mayAutoStartPlayback(currentEpoch: epoch) }
    }

    func pausePlayback() {
        // Record the EXPLICIT intent before touching the player: the next
        // accepted buffer must queue, never silently resume (2026-10-25
        // defect: scheduleChunk's `!isPlaying → play()` undid every pause).
        playbackLock.withLock { playbackIntent.pause(epoch: epoch) }
        playerNode.pause()
    }

    func resumePlayback() {
        // The legitimate release of the veto. FENCE TRUTH (primary review
        // 2026-10-25): this protocol method carries NO caller epoch, so the
        // live path always passes the CURRENT epoch and clears any current
        // pause. What fences a stale resume in production is the
        // COORDINATOR: `endBargePause` runs only while the live round still
        // owns `outputPausedByBarge`, `resumeOutput` only while it owns
        // `appPaused`, and every cancelled/finished round goes through
        // `finishRound` → `stopPlayback` (fresh epoch, cleared intent)
        // instead — pinned by VoicePlaybackIntentTests at the coordinator
        // seam, not by a claim this signature cannot honor.
        playbackLock.withLock { playbackIntent.resume(epoch: epoch) }
        #if !targetEnvironment(simulator)
        if graphLock.withLock({ engineStarted }) { playerNode.play() }
        #endif
    }

    func stopPlayback() {
        // Fence FIRST, flush second. `playerNode.stop()` drains the scheduled
        // queue and may run `.dataPlayedBack` completion handlers inline;
        // bumping the epoch before that guarantees those handlers (and any
        // handler that already passed its check but has not yielded yet)
        // can never credit the cancelled round. Only then discard the
        // time-pitch look-ahead and zero the counters for the new epoch. The
        // shared duplex engine, microphone and VPIO graph are never reset.
        playbackLock.lock()
        epoch &+= 1
        let fencedEpoch = epoch
        // A stop is a NEW round/session boundary: any pause intent of the
        // cancelled round must never gate the next answer, and the trailing
        // explicit re-play below is the legitimate fresh-epoch start.
        playbackIntent.beginEpoch(fencedEpoch)
        playbackLock.unlock()
        playerNode.stop()
        playerNode.reset()
        speechEffect.reset()
        // A new epoch is a NEW answer: drop every cached resampler's retained
        // filter history so stale priming frames from the cancelled round can
        // never surface as the next round's leading audio.
        for converter in converterCache.values { converter.reset() }
        playbackLock.lock()
        scheduledFrames = 0
        completedFrames = 0
        renderedOutputFrames = 0
        renderedOutputSampleRate = 0
        appliedPlaybackControls = .neutral
        playbackLock.unlock()
        // Fresh epoch, fresh zero. Stale completions are epoch-fenced both
        // here (the handler check) and in the coordinator (the event tag).
        // The reset frame counter is a clock for the NEXT round only; its
        // baseline is taken after the next last-receipt, so any in-flight old
        // tap buffer can never stand in for new-round tail progress.
        engineEventContinuation.yield(.playedFramesTagged(frames: 0, epoch: fencedEpoch))
        #if !targetEnvironment(simulator)
        if graphLock.withLock({ engineStarted }) { playerNode.play() }
        #endif
    }

    /// The epoch current receivers must match. Fenced before every player
    /// flush by `stopPlayback()`; read by the coordinator to reject progress
    /// events that were queued in an older epoch.
    var playbackEpoch: UInt64 { playbackLock.withLock { epoch } }

    /// Freezes one round's controls. The node is written only when the output
    /// queue is idle (fresh epoch / everything already consumed), which is
    /// exactly "before the first buffer of a new round after the previous
    /// output flush". Later units of the same round or a queued old answer
    /// never retune the shared unit at a player receipt.
    func applySpeechControls(_ controls: VoicePlaybackControls, for unitID: UUID) {
        playbackLock.lock()
        guard scheduledFrames == completedFrames,
              controls != appliedPlaybackControls else {
            playbackLock.unlock()
            return
        }
        appliedPlaybackControls = controls
        playbackLock.unlock()
        speechEffect.apply(controls)
    }

    /// REAL mixer-rendered output frames since the current epoch (tap clock).
    var outputRenderedFrames: Int { playbackLock.withLock { renderedOutputFrames } }

    /// Frame growth needed to flush the time-pitch look-ahead after the last
    /// player receipt. Uses the tap's ACTUAL output rate when known; the SDK
    /// reports latency 0 as "unknown", so the measured bound supplies it.
    var outputDrainFrames: Int {
        let tapRate = playbackLock.withLock { renderedOutputSampleRate }
        let fallback = graphLock.withLock { playerFormat?.sampleRate ?? 48_000 }
        return SpeechPlaybackEffectRender.drainFrameCount(
            nodeLatencySeconds: speechEffect.reportedLatencySeconds,
            sampleRate: tapRate > 0 ? tapRate : fallback)
    }

    // MARK: - Chunk ↔ buffer

    private static func buffer(from chunk: VoiceConversationAudioChunk) -> AVAudioPCMBuffer? {
        let frames = chunk.frameCount
        guard frames > 0, frames <= 240_000,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: AVAudioChannelCount(chunk.channelCount),
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if chunk.channelCount == 1 {
            // `floatChannelData` is nullable but its channel pointers are
            // non-null in the iOS 27 SDK — no optional binding needed.
            let mono = channels[0]
            chunk.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { mono.update(from: base, count: source.count) }
            }
        } else if chunk.channelCount == 2 {
            let left = channels[0]
            let right = channels[1]
            // Deinterleave the caller's interleaved stereo into planar.
            chunk.samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for index in 0..<frames {
                    left[index] = base[index * 2]
                    right[index] = base[index * 2 + 1]
                }
            }
        } else {
            return nil
        }
        return buffer
    }

    /// One converter per SOURCE→DESTINATION FORMAT PAIR. The cache key is
    /// built from semantic format properties: `AVAudioFormat.description`
    /// embeds the object address, so keying on it (the previous behavior)
    /// never matched and silently created a fresh converter per chunk — every
    /// resampler cold start discarded its held frames (audible gaps) and
    /// allocated a new AU on the main thread. Reuse keeps filter history
    /// continuous across chunks (native probe: stable reuse + `.none` priming
    /// reproduces exact 24k→48k frame counts).
    static func converterCacheKey(from source: AVAudioFormat, to destination: AVAudioFormat) -> String {
        func token(_ format: AVAudioFormat) -> String {
            "\(format.sampleRate.bitPattern):\(format.channelCount):\(format.commonFormat.rawValue):\(format.isInterleaved ? 1 : 0)"
        }
        return "\(token(source))->\(token(destination))"
    }

    /// Output capacity for one conversion. `+1 render quantum` (4096) leaves
    /// room for the converter's own quantum rounding on fractional rates and
    /// channel up-mix; the old +32 margin could undershoot a 4096-frame
    /// processing quantum and fail the whole chunk.
    static func conversionCapacity(sourceFrames: Int,
                                   from source: AVAudioFormat,
                                   to destination: AVAudioFormat) -> Int {
        guard sourceFrames > 0, source.sampleRate > 0, destination.sampleRate > 0 else { return 0 }
        let ratio = destination.sampleRate / source.sampleRate
        let estimate = Int(ceil(Double(sourceFrames) * ratio))
        let bounded = max(0, min(estimate, Int(UInt32.max) - 4_096))
        return bounded + 4_096
    }

    /// Internal seam for focused tests: the live conversion path used by
    /// `scheduleChunk`. The cache and converter state are owned by this
    /// (MainActor-serialized) stack; tests call this directly without an
    /// engine, microphone or audio output.
    func convert(_ buffer: AVAudioPCMBuffer, to output: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = Self.converterCacheKey(from: buffer.format, to: output)
        let converter: AVAudioConverter
        if let cached = converterCache[key] {
            converter = cached
        } else if let created = AVAudioConverter(from: buffer.format, to: output) {
            // `.none` priming was verified by the native probe: the resampler
            // no longer holds an initial block (fresh 16-frame chunks used to
            // produce 0 forever) and totals match rate arithmetic exactly.
            created.primeMethod = .none
            // Bound the pool: distinct provider formats are few; anything
            // beyond this means a pathological format churn, and recreating
            // one converter is cheaper than unbounded retention.
            if converterCache.count >= 8 { converterCache.removeAll(keepingCapacity: true) }
            converterCache[key] = created
            converter = created
        } else {
            return nil
        }
        let estimated = Self.conversionCapacity(
            sourceFrames: Int(buffer.frameLength),
            from: buffer.format,
            to: output
        )
        guard estimated > 0,
              let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(estimated))
        else { return nil }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { return nil }
        return out
    }

    private static func convertedFrames(chunkFrames: Int, chunkRate: Double, outRate: Double) -> Int {
        guard chunkFrames > 0, chunkRate.isFinite, chunkRate > 0,
              outRate.isFinite, outRate > 0 else { return 0 }
        return Int((Double(chunkFrames) * outRate / chunkRate).rounded())
    }

    // MARK: - Metering (render thread)

    private nonisolated func publishMicLevel(of buffer: AVAudioPCMBuffer) {
        let rms = VoiceBufferMeter.rms(of: buffer)
        let duration = Double(buffer.frameLength) / Double(max(buffer.format.sampleRate, 1))
        let output = micLock.withLock {
            micMeter.process(rms: rms, duration: Float(duration))
        }
        levelContinuation.yield(
            VoiceConversationLevel(level: output.level, isSpeech: output.isSpeech, duration: duration)
        )
    }

    private nonisolated func publishPlayedLevel(of buffer: AVAudioPCMBuffer) {
        let rms = VoiceBufferMeter.rms(of: buffer)
        let duration = Double(buffer.frameLength) / Double(max(buffer.format.sampleRate, 1))
        let output = playedLock.withLock {
            playedMeter.process(rms: rms, duration: Float(duration))
        }
        playedLevelContinuation.yield(
            VoiceConversationLevel(level: output.level, isSpeech: output.isSpeech, duration: duration)
        )
    }

    /// Epoch-local count of REAL mixer frames for the post-input tail drain.
    /// Counts frames (never sample content): silent stretches are legitimate
    /// and must not be mistaken for a finished/absent tail.
    private nonisolated func countRenderedOutput(of buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        playbackLock.withLock {
            renderedOutputFrames += frames
            if rate.isFinite, rate > 0 { renderedOutputSampleRate = rate }
        }
    }

    // MARK: - System observation

    private func installSystemObservers() {
        let notes = NotificationCenter.default
        let interruptionToken = notes.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.systemEventContinuation.yield(.interruptionBegan)
        }
        let routeToken = notes.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  Self.interruptsForRouteChange(reason) else { return }
            // No silent rerouting after unplug — report the LOSS; the
            // coordinator pauses and cancels output instead of switching.
            self.systemEventContinuation.yield(.routeLost)
        }
        let mediaToken = notes.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.systemEventContinuation.yield(.mediaServicesReset)
        }
        let configToken = notes.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.systemEventContinuation.yield(.engineConfigurationChanged)
            // The notification is information for the coordinator; the
            // reconfiguration itself STOPS the engine on iPhone. Recover
            // in-place with the bounded tap-before-start restart and demand
            // fresh real buffers — only a failed re-proof surfaces as
            // `.captureStalled`.
            Task { [weak self] in await self?.recoverAfterConfigurationChange() }
        }
        observers.append(contentsOf: [interruptionToken, routeToken, mediaToken, configToken])
    }

    /// Same predicate the dictation controller uses: only removal of the
    /// active input/output device or an unusable route interrupts a session.
    static func interruptsForRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory: true
        default: false
        }
    }

    private func removeSystemObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    // MARK: - Teardown

    func deactivate() {
        stopCapture()
        #if !targetEnvironment(simulator)
        let hadOutputTap = graphLock.withLock {
            let value = outputTapInstalled
            outputTapInstalled = false
            return value
        }
        if hadOutputTap { engine.mainMixerNode.removeTap(onBus: 0) }
        let wasConnected = graphLock.withLock {
            let value = playerConnected
            playerConnected = false
            return value
        }
        if wasConnected { engine.disconnectNodeInput(playerNode) }
        #endif
        playerNode.stop()
        let wasStarted = graphLock.withLock {
            let value = engineStarted
            engineStarted = false
            return value
        }
        if wasStarted { engine.stop() }
        // Engine teardown discards every scheduled buffer and the unit's held
        // look-ahead; detaching the unit guarantees no old tail survives a
        // later re-activation of this instance.
        speechEffect.uninstall()
        removeSystemObservers()
        graphLock.withLock { sessionActivated = false }
        // Unconditional atomic release: `releaseAndDeactivateLast` only
        // deactivates when removing THIS instance's claim empties the
        // registry (never-claimed or already-released ids are inert), and
        // the deactivation is serialized against new claims — no gap where
        // a just-activated owner could still be silenced by this teardown.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(stackID) {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        levelContinuation.finish()
        playedLevelContinuation.finish()
        engineEventContinuation.finish()
        systemEventContinuation.finish()
        let pending = backendLock.withLock { () -> (any SpeechTranscribing)? in
            let value = backend
            backend = nil
            return value
        }
        if let pending {
            Task { [pending] in await pending.finishAudio() }
        }
        let feed = backendLock.withLock { () -> Task<Void, Never>? in
            let value = backendFeed
            backendFeed = nil
            return value
        }
        feed?.cancel()
        backendLock.withLock { transcriptContinuation }.finish()
    }

    deinit {
        // Ownership token guarantees a superseded instance never touches the
        // shared session even if the coordinator failed to deactivate it.
        removeSystemObservers()
    }
}

// MARK: - Redacted diagnostics

/// Structured lifecycle diagnostics for the conversation session. Carries
/// state codes and counts ONLY — never transcript bodies, audio, or secrets.
struct FloeVoiceConversationDiagnostics: VoiceConversationDiagnostics {
    private let logger = FloeLogger(category: .app)
    func voiceConversation(_ code: String, _ detail: String) {
        if detail.isEmpty {
            logger.info("voiceConversation domain=voiceConversation code=\(code)")
        } else {
            logger.info("voiceConversation domain=voiceConversation code=\(code) \(detail)")
        }
    }
}

// MARK: - Production factory

extension VoiceConversationCoordinator {
    /// The production wiring: same system permission prompts as dictation,
    /// one duplex live stack per session (AEC-processed mic capture + the
    /// shared player-node output the TTS bridge feeds), a real clock,
    /// provider-independent whole-body speech projection (code/tables removed,
    /// URLs retained for the selected source's own projection) and redacted
    /// logging.
    ///
    /// Simulator note: capture/AEC are unavailable by design (see
    /// `VoiceConversationLiveStack.activate`); UI acceptance must inject
    /// fake stacks. Nothing here claims real microphone behavior until a
    /// physical-device run by the app owner.
    static func live(
        driving: any VoiceConversationTurnDriving,
        language: VoiceRecognitionLanguage = .automatic,
        diagnostics: (any VoiceConversationDiagnostics)? = FloeVoiceConversationDiagnostics(),
        speechNormalizer: (@Sendable (String) -> String)? = nil
    ) -> VoiceConversationCoordinator {
        VoiceConversationCoordinator(
            authorization: SystemSpeechAuthorizationProvider(),
            makeStack: { VoiceConversationLiveStack(language: language) },
            driving: driving,
            clock: VoiceConversationSystemScheduler(),
            diagnostics: diagnostics,
            speechNormalizer: speechNormalizer ?? {
                AnswerSpeechText.spokenText($0, destination: .cloud)
            }
        )
    }
}
#endif
