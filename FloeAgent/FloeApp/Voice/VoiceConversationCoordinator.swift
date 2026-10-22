// FloeApp — Continuous voice conversation coordinator (session state machine).
//
// SPDX-License-Identifier: MPL-2.0
//
// An INDEPENDENT continuous voice session for chat mode — deliberately NOT
// a repurposed `VoiceInputController` (that stays the composer dictation
// surface with `.record`/`.measurement` behavior). This coordinator owns the
// conversation session: authorization, one stack (mic + ASR + player) at a
// time, utterance endpointing, barge-in, mute, pause/resume and the speech
// output ledger the app TTS bridge feeds.
//
// Foundation + Combine only, with no guard: the kernel must compile and run
// in host unit tests with faked I/O and a fake clock (see
// ConversationVoiceInterfaces.swift for why).
//
// Session-safety rules enforced here:
// - A monotonic session generation fences EVERY async callback. A superseded
//   round or stack can never change state or resume output.
// - Endpointing (~900 ms silence / ~1.6 s trailing-incomplete extension) uses
//   the injected scheduling seam, never a hidden wall clock.
// - Barge-in: persistent echo-processed speech TENTATIVELY PAUSES playback at
//   its exact position; only a valid ASR turn CONFIRMS and cancels the owned
//   round (amplitude alone never discards a generation). Capture keeps
//   streaming during the pause so the pre-roll / first syllable is retained.
// - Mute stops physical mic collection; no hidden capture, no auto-submit of
//   a muted draft, and answer playback stays available.
// - Background/lock/interruption/route loss pause the session and cancel the
//   current generation and audio. Resume is manual only. The pending unsent
//   transcript survives.
// - Receipts come from engine played-frames (true drain), never from the TTS
//   producer's own final flags.

import Foundation
import Combine

@MainActor
final class VoiceConversationCoordinator: ObservableObject, VoiceConversationSpeechOutput {

    /// Settled timing constants (product-fixed; injectable for tests).
    struct Timing: Sendable {
        var endpointSilence: Double = 0.9
        var endpointIncomplete: Double = 1.6
        var bargeSuspect: Double = 0.18
        var bargeClear: Double = 0.25
        var preparationWatchdog: Double = 25
        var drainWatchdog: Double = 20
        var maxQueuedSeconds: Double = 45
        /// Bounded lookahead: at most this many emitted-but-not-yet-played
        /// units are outstanding. Remaining split text stays in the round's
        /// `pendingUnitTexts` cursor and refills only on `unitCompleted`, so
        /// a fast model can never burst-drop control events on the bridge
        /// channel (the primary bridge queue cap of 64 stays comfortably
        /// above this window).
        var lookaheadUnits: Int = 16
        /// Hard cap on text handed to the splitter for synthesis; visible
        /// answer text beyond it is displayed but never spoken (the durable
        /// history/ordinary answer retains everything).
        var answerTextCap: Int = 64_000
        /// `unitProgress` is a droppable display sample: emitted at most
        /// once per quant step per unit so it cannot crowd the control
        /// events on the shared channel.
        var progressQuant: Double = 0.25
    }

    // MARK: - Published surface (voice UI reads only these)

    @Published private(set) var state: VoiceConversationState = .idle
    /// The current utterance being staged (incremental REPLACE). Survives
    /// pause; never auto-submitted while muted.
    @Published private(set) var stagedTranscript = ""
    /// Visible assistant text of the current round (cumulative).
    @Published private(set) var answerText = ""
    /// Real measured amplitude 0...1; static at silence, never timer-driven.
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isSpeechDetected = false
    /// REAL played-output amplitude 0...1 (PCM that actually reached the
    /// speaker through the shared AEC output). The orb animates from this
    /// while answering — never a timer, never a synthesis claim.
    @Published private(set) var outputLevel: Float = 0
    /// True while a tentative barge-in pause is active.
    @Published private(set) var suspectingSpeech = false
    @Published private(set) var isMuted = false
    @Published private(set) var pausedReason: VoiceConversationFailure?
    @Published private(set) var turnErrorMessage: String?
    @Published private(set) var currentRound: VoiceConversationRoundToken?
    @Published private(set) var playingUnitProgress: (index: Int, fraction: Double)?
    /// The text of the unit currently PLAYING: the caption follows actual
    /// playback, never the tail of the generated answer.
    @Published private(set) var currentSpokenText = ""

    /// Delivered exactly once when a session fully ends (close/navigation).
    var onSessionEnded: (@MainActor (VoiceConversationSessionSummary) -> Void)?

    /// Barge-in is ON by default (settled UX). The settings owner wires this
    /// from user preference; when false, playback is never tentatively
    /// paused or cancelled by speech — an utterance spoken during an answer
    /// still stages and submits after the round ends naturally.
    var allowBargeIn = true

    /// Playback interruption metadata retained for the primary's history /
    /// context bridge until a newer interruption replaces it.
    private(set) var interruptedRoundContext: VoiceConversationInterruptedRound?
    func consumeInterruptedRound() -> VoiceConversationInterruptedRound? { interruptedRoundContext }

    // MARK: - Seams

    private let authorization: any VoiceConversationAuthorizationProviding
    private let makeStack: @MainActor () -> any VoiceConversationStack
    private let driving: any VoiceConversationTurnDriving
    private let clock: any VoiceConversationScheduling
    private let diagnostics: (any VoiceConversationDiagnostics)?
    private let timing: Timing
    /// Normalizes the WHOLE final-answer body before sentence splitting
    /// (markdown → plain; identity in the pure kernel, `AnswerSpeechText
    /// .plainText` in the live wiring). Never applied per unit: fenced code
    /// spans sentence boundaries.
    private let speechNormalizer: @Sendable (String) -> String

    // MARK: - Round bookkeeping

    private struct UnitLedger {
        let unit: VoiceConversationSpeechUnit
        var expectedFrames = 0   // output-rate frames accepted for this unit
        var ended = false        // bridge finished appending this unit
        var completed = false    // audio of this unit played to its end offset
        var lastProgressFraction: Double = -1  // quantized progress emission memory
    }

    private struct Round {
        let token: VoiceConversationRoundToken
        var cumulativeText = ""
        // --- final-answer speech projection ---
        /// Raw live final-answer stream (sealedCount == 0 while it holds).
        var finalBasisRaw = ""
        /// The NORMALIZED whole body last fed to the splitter. Normalization
        /// runs on the entire basis (never per unit): a fenced code block
        /// spans sentence boundaries.
        var speechBasis = ""
        /// `.finalAnswerRetracted` observed: commentary was mis-projected;
        /// audio stopped, no new units until the durable final body arrives.
        var speechRetracted = false
        /// Normalization of the growing basis stopped being prefix-stable
        /// (a fence opened then closed): freeze new splitting; the spoken
        /// portion stays honest, the tail may remain unspoken.
        var speechFrozenShift = false
        /// The tail of the confirmed answer was never emitted (retraction
        /// without recovery or a frozen normalization shift): a “drained”
        /// finish must still be receipted as INTERRUPTED, never completed.
        var speechTailLost = false
        /// Text whose audio completed BEFORE a projection retraction: the
        /// ledger is reset when the speculative projection is discarded, so
        /// the receipt keeps the actually-heard prefix separately.
        var spokenPrefix = ""
        var splitter = VoiceConversationSentenceSplitter()
        /// Split but NOT yet emitted: held here while the lookahead window is
        /// full. Control events therefore never burst past the bridge's
        /// channel; they refill only as units complete.
        var pendingUnitTexts: [String] = []
        var pendingCharacters = 0
        var units: [UnitLedger] = []
        var totalQueuedFrames = 0
        var playedFrames = 0
        var modelCompleted = false
        var fullText: String?
        var endRoundAudioReceived = false
        var roundTextCompletedEmitted = false
        var outputPausedByBarge = false
        var appPaused = false
        var outputStoppedByApp = false
        var roundStartedEmitted = false
        var drained = false
        var finishScheduled = false
        var completedSpokenCache = ""
        var drainWatchdog: (any VoiceConversationScheduled)?
        var watchdogPlayedSnapshot = 0

        var playbackBegan: Bool { playedFrames > 0 }
        var pendingUnits: Bool { units.contains { !$0.completed } }
        /// Emitted-but-not-yet-played units — the bounded lookahead window.
        var outstandingUnits: Int { units.filter { !$0.completed }.count }
        /// All split text has been handed to the bridge.
        var allUnitsEmitted: Bool { pendingUnitTexts.isEmpty }
    }

    // MARK: - Session bookkeeping

    /// Monotonic fence: every async observation captures an attempt value.
    private var sessionGeneration: UInt64 = 0
    private var activeAttempt: UInt64 = 0
    private var stack: (any VoiceConversationStack)?
    private var round: Round?
    private var observationTasks: [Task<Void, Never>] = []
    private var endpointTimer: (any VoiceConversationScheduled)?
    private var preparationTimer: (any VoiceConversationScheduled)?
    /// True while a deliberate pause/end drains the ASR stream; suppresses
    /// the "stream ended unexpectedly" failure path.
    private var teardownInFlight = false
    private var bargeGate = VoiceConversationBargeGate()

    /// Backend session text is cumulative across the whole transcription
    /// session (dictation-compatible). The coordinator presents it relative
    /// to `transcriptBaseline`, which advances when an utterance is submitted
    /// or discarded, so a new utterance never re-sends or merges stale text.
    private var rawTranscript = ""
    private var transcriptBaseline = ""
    /// The exact text handed to the driving seam on the last submit; lets a
    /// pre-launch failure re-stage the user's recognized words.
    private var lastSubmittedText = ""
    /// Text kept across a manual pause; prepended to the first partial of the
    /// rebuilt transcription session so the pending utterance completes.
    private var resumePrefix: String?

    // Speech event channel (single consumer: the app TTS bridge).
    private let speechContinuation: AsyncStream<VoiceConversationSpeechEvent>.Continuation
    let speechEvents: AsyncStream<VoiceConversationSpeechEvent>

    // MARK: - Init

    init(
        authorization: any VoiceConversationAuthorizationProviding,
        makeStack: @escaping @MainActor () -> any VoiceConversationStack,
        driving: any VoiceConversationTurnDriving,
        clock: any VoiceConversationScheduling,
        diagnostics: (any VoiceConversationDiagnostics)? = nil,
        timing: Timing = Timing(),
        speechNormalizer: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.authorization = authorization
        self.makeStack = makeStack
        self.driving = driving
        self.clock = clock
        self.diagnostics = diagnostics
        self.timing = timing
        self.speechNormalizer = speechNormalizer
        var continuation: AsyncStream<VoiceConversationSpeechEvent>.Continuation!
        self.speechEvents = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.speechContinuation = continuation
    }

    private func report(_ code: String, _ detail: String = "") {
        diagnostics?.voiceConversation(code, detail)
    }

    private func isCurrent(_ attempt: UInt64) -> Bool { attempt == activeAttempt }

    // MARK: - Session lifecycle

    /// Reserves and launches a session synchronously (mirrors the proven
    /// dictation reservation pattern: a UI tap can never leave a suspended
    /// start that captures audio after the view disappeared).
    func requestStart() {
        guard let attempt = reserveStart() else { return }
        Task { [weak self] in await self?.prepareSession(attempt: attempt) }
    }

    func start() async {
        guard let attempt = reserveStart() else { return }
        await prepareSession(attempt: attempt)
    }

    private func reserveStart() -> UInt64? {
        guard !state.hasSession, state != .requestingPermission, state != .ending else { return nil }
        sessionGeneration &+= 1
        let attempt = sessionGeneration
        activeAttempt = attempt
        teardownInFlight = false
        // A previous round should already be fenced away; belt-and-braces:
        if let stale = round {
            round = nil
            currentRound = nil
            let driving = self.driving
            Task { [driving] in await driving.cancelTurn(stale.token) }
        }
        stagedTranscript = ""
        rawTranscript = ""
        transcriptBaseline = ""
        resumePrefix = nil
        answerText = ""
        turnErrorMessage = nil
        audioLevel = 0
        isSpeechDetected = false
        outputLevel = 0
        currentSpokenText = ""
        suspectingSpeech = false
        bargeGate = VoiceConversationBargeGate(
            suspectAfter: timing.bargeSuspect, clearAfter: timing.bargeClear
        )
        pausedReason = nil
        isMuted = false
        interruptedRoundContext = nil
        playingUnitProgress = nil
        lastSubmittedText = ""
        state = .requestingPermission
        return attempt
    }

    private func prepareSession(attempt: UInt64) async {
        guard isCurrent(attempt) else { return }
        // Explicit permission checks first (microphone, then speech) so the
        // failure copy names exactly what the user must grant.
        guard await authorization.requestMicrophoneAccess() else {
            guard isCurrent(attempt) else { return }
            report("permissionDenied", "microphone")
            state = .failed(.microphonePermissionDenied)
            return
        }
        guard isCurrent(attempt) else { return }
        guard await authorization.requestSpeechRecognitionAccess() else {
            guard isCurrent(attempt) else { return }
            report("permissionDenied", "speech")
            state = .failed(.speechPermissionDenied)
            return
        }
        guard isCurrent(attempt) else { return }
        state = .preparing
        report("preparing")
        preparationTimer?.cancel()
        preparationTimer = clock.schedule(after: timing.preparationWatchdog) { [weak self] in
            guard let self, self.isCurrent(attempt), self.state == .preparing else { return }
            self.report("preparationTimeout")
            self.failCurrentSession(.recognizerFailed)
        }

        let stack = makeStack()
        do {
            try await stack.activate()
            guard isCurrent(attempt) else { stack.deactivate(); return }
            try await stack.beginTranscription()
            guard isCurrent(attempt) else { stack.deactivate(); return }
            try stack.startCapture()
            guard isCurrent(attempt) else { stack.deactivate(); return }
        } catch let failure {
            stack.deactivate()
            guard isCurrent(attempt) else { return }
            failCurrentSession(failure)
            return
        }

        preparationTimer?.cancel()
        preparationTimer = nil
        self.stack = stack
        startObserving(stack, attempt: attempt)
        state = .listening
        report("listeningStarted")
        // A resumed pending transcript (resume() path pre-schedules); fresh
        // sessions start with empty staged text.
    }

    /// Ends the session entirely (close / navigation). Cancels any owned
    /// round, tears the stack down and hands the summary to the app layer.
    func end() {
        guard state != .idle else { return }
        teardownInFlight = true
        // Fence synchronously before any await so no observation (including a
        // paused-session race or a late ASR restart) can act during teardown.
        activeAttempt = nextAttemptValue()
        endpointTimer?.cancel(); endpointTimer = nil
        preparationTimer?.cancel(); preparationTimer = nil
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        state = .ending
        report("ending")
        Task { [weak self] in
            guard let self else { return }
            if let r = self.round {
                await self.finishRound(token: r.token, reason: .sessionEnded, drained: false)
            }
            guard self.state == .ending else { return }
            self.teardownStack()
            let summary = VoiceConversationSessionSummary(
                pendingTranscript: self.stagedTranscript,
                interruptedRound: self.interruptedRoundContext,
                wasMuted: self.isMuted
            )
            self.stagedTranscript = ""
            self.rawTranscript = ""
            self.transcriptBaseline = ""
            self.resumePrefix = nil
            self.answerText = ""
            self.turnErrorMessage = nil
            self.audioLevel = 0
            self.isSpeechDetected = false
            self.suspectingSpeech = false
            self.pausedReason = nil
            self.isMuted = false
            self.playingUnitProgress = nil
            self.state = .idle
            self.report("ended")
            self.onSessionEnded?(summary)
        }
    }

    private func nextAttemptValue() -> UInt64 {
        sessionGeneration &+= 1
        return sessionGeneration
    }

    /// Manual resume after a system pause. Rebuilds capture + transcription;
    /// the pending unsent transcript survives as `resumePrefix`.
    func resume() async {
        guard state == .paused else { return }
        teardownInFlight = false
        resumePrefix = stagedTranscript.isEmpty ? nil : stagedTranscript
        rawTranscript = ""
        transcriptBaseline = ""
        pausedReason = nil
        audioLevel = 0
        isSpeechDetected = false
        suspectingSpeech = false
        bargeGate = VoiceConversationBargeGate(
            suspectAfter: timing.bargeSuspect, clearAfter: timing.bargeClear
        )
        sessionGeneration &+= 1
        activeAttempt = sessionGeneration
        state = .requestingPermission
        report("resumeRequested")
        await prepareSession(attempt: activeAttempt)
        guard state == .listening else { return }
        // `resumePrefix` stays set: new backend partials JOIN with the
        // pending draft until the turn submits. If the user stays silent,
        // the pending draft itself finalizes after the endpoint window.
        if let prefix = resumePrefix, !prefix.isEmpty {
            scheduleEndpoint(for: prefix)
        }
    }

    /// App/scene policy: background or resign-active pauses the session and
    /// cancels current generation + audio. Resume is manual only.
    func pauseForScene(_ event: VoiceConversationSceneEvent) {
        switch event {
        case .background, .inactive:
            pauseSession(reason: .interrupted)
        }
    }

    /// System audio events mapped by the live stack (also see the public
    /// overload for direct injection from tests).
    func handleSystemEvent(_ event: VoiceConversationSystemEvent) {
        switch event {
        case .interruptionBegan:
            pauseSession(reason: .interrupted)
        case .routeLost:
            // No silent rerouting after unplug: pause and cancel audio.
            pauseSession(reason: .routeLost)
        case .mediaServicesReset:
            pauseSession(reason: .recognizerFailed)
        case .engineConfigurationChanged:
            report("engineConfigurationChanged")
        }
    }

    private func pauseSession(reason: VoiceConversationFailure) {
        guard state.hasSession || state == .requestingPermission, state != .ending else { return }
        teardownInFlight = true
        // Fence synchronously: a route loss arriving mid-preparation or
        // mid-round must stop every stale async path immediately.
        activeAttempt = nextAttemptValue()
        endpointTimer?.cancel(); endpointTimer = nil
        preparationTimer?.cancel(); preparationTimer = nil
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        report("paused", reason.rawValue)
        Task { [weak self] in
            guard let self else { return }
            if let r = self.round {
                await self.finishRound(token: r.token, reason: .systemPause, drained: false)
            }
            guard self.state == .paused || self.state == .ending || self.state.hasSession
                || self.state == .requestingPermission else { return }
            guard self.state != .idle else { return }
            self.teardownStack()
            self.audioLevel = 0
            self.isSpeechDetected = false
            self.suspectingSpeech = false
            self.playingUnitProgress = nil
            self.pausedReason = reason
            self.state = .paused
        }
    }

    private func teardownStack() {
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        guard let stack else { return }
        stack.stopCapture()
        stack.stopPlayback()
        self.stack = nil
        // finishTranscription is bounded inside the stack implementation.
        Task { [stack] in await stack.finishTranscription() }
        stack.deactivate()
    }

    private func failCurrentSession(_ failure: VoiceConversationFailure) {
        endpointTimer?.cancel(); endpointTimer = nil
        preparationTimer?.cancel(); preparationTimer = nil
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        teardownInFlight = true
        if let r = round {
            round = nil
            currentRound = nil
            r.drainWatchdog?.cancel()
            if r.playbackBegan {
                emitReceipt(for: r, drained: false)
                interruptedRoundContext = Self.makeInterrupted(from: r, pausedForBargeIn: r.outputPausedByBarge)
            }
            let driving = self.driving
            Task { [driving] in await driving.cancelTurn(r.token) }
        }
        teardownStack()
        activeAttempt = nextAttemptValue()
        audioLevel = 0
        isSpeechDetected = false
        suspectingSpeech = false
        playingUnitProgress = nil
        report("sessionFailed", failure.rawValue)
        state = .failed(failure)
    }

    // MARK: - Controls

    /// Mute physically stops microphone collection — no hidden capture.
    /// Answer playback remains available; no muted draft is auto-submitted.
    func setMuted(_ on: Bool) {
        guard state.hasSession, on != isMuted else { return }
        isMuted = on
        if on {
            stack?.stopCapture()
            endpointTimer?.cancel(); endpointTimer = nil
            if suspectingSpeech {
                suspectingSpeech = false
                if let r = round, r.outputPausedByBarge {
                    round?.outputPausedByBarge = false
                    stack?.resumePlayback()
                    speechContinuation.yield(.outputResumed(reason: .falseStart))
                }
            }
        } else {
            do {
                try stack?.startCapture()
            } catch let failure {
                failCurrentSession(failure)
                return
            }
            // No endpoint timer for a pre-mute draft: only NEW transcript
            // activity continues automatic endpointing ("no auto-submit
            // muted draft" — the draft waits for the user to speak or send).
        }
        report("muteToggled", on ? "on" : "off")
    }

    /// Interrupt button: cancels the exact owned round immediately (manual
    /// override of the amplitude rules) and starts listening again.
    func interruptNow() {
        guard state == .waitingModel || state == .answering, let r = round else { return }
        let token = r.token
        Task { [weak self] in
            guard let self else { return }
            await self.finishRound(token: token, reason: .manualInterrupt, drained: false)
            self.resumeListeningAfterRound(roundToken: token)
        }
    }

    /// Send-now: bypasses the endpoint timers for the currently staged
    /// utterance. Never sends empty or hesitation-only text.
    func sendNow() {
        guard state == .listening, !isMuted else { return }
        let text = stagedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceConversationTurnValidity.isValidTurn(text) else { return }
        submit(text)
    }

    /// Typed input while the voice session is active — the SAME round
    /// scheduler.
    /// - .listening: launches the turn immediately (endpoint timers cleared).
    /// - Round active: cancels the exact owned round through the driving
    ///   barrier FIRST (no overlapping runs), then launches the typed text
    ///   once, exactly once.
    /// - anything else (idle/preparing/pre-launch permission/paused/failed):
    ///   returns false; the host keeps the draft and the normal composer
    ///   path applies.
    @discardableResult
    func submitText(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceConversationTurnValidity.isValidTurn(trimmed) else { return false }
        switch state {
        case .listening:
            submit(trimmed)
            return true
        case .submitting, .waitingModel, .answering:
            guard let token = round?.token else { return false }
            await finishRound(token: token, reason: .manualInterrupt, drained: false)
            guard state == .waitingModel || state == .answering || state == .submitting else { return false }
            resumeListeningAfterRound(roundToken: token)
            guard state == .listening else { return false }
            submit(trimmed)
            return true
        default:
            return false
        }
    }

    // MARK: - Observation

    private func startObserving(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        observeLevels(stack, attempt: attempt)
        observePlayedLevels(stack, attempt: attempt)
        observeTranscripts(stack, attempt: attempt)
        observeEngine(stack, attempt: attempt)
        observeSystem(stack, attempt: attempt)
    }

    private func observeLevels(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await level in stack.levels {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                self.consume(level)
            }
        })
    }

    private func observePlayedLevels(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await level in stack.playedLevels {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                self.outputLevel = level.level
            }
        })
    }

    private func observeTranscripts(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await text in stack.transcripts {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                self.consumeTranscript(text)
            }
            guard let self, !Task.isCancelled, self.isCurrent(attempt), !self.teardownInFlight, self.state.hasSession else { return }
            await self.restartTranscription(stack: stack, attempt: attempt)
        })
    }

    /// Recognition backends may end their stream on their own schedule (the
    /// Speech recognizer task stops after ~1 minute of no speech). A live
    /// conversation session must not die with it: restart the transcription
    /// session in place, carrying the pending draft across the boundary.
    private func restartTranscription(stack: any VoiceConversationStack, attempt: UInt64) async {
        if let failure = stack.transcriptionFailureSnapshot() {
            report("transcriptStreamFailed", failure.rawValue)
            failCurrentSession(failure)
            return
        }
        report("transcriptStreamRestart")
        if !stagedTranscript.isEmpty { resumePrefix = stagedTranscript }
        rawTranscript = ""
        transcriptBaseline = ""
        do {
            try await stack.beginTranscription()
        } catch let failure {
            guard isCurrent(attempt), state.hasSession else { return }
            failCurrentSession(failure)
            return
        }
        guard isCurrent(attempt), state.hasSession else { return }
        observeTranscripts(stack, attempt: attempt)
        if state == .listening, !isMuted, !stagedTranscript.isEmpty {
            scheduleEndpoint(for: stagedTranscript)
        }
    }

    private func observeEngine(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await event in stack.engineEvents {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                if case .playedFrames(let frames) = event { self.consumePlayedFrames(frames) }
            }
        })
    }

    private func observeSystem(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await event in stack.systemEvents {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                self.handleSystemEvent(event)
            }
        })
    }

    private func consume(_ level: VoiceConversationLevel) {
        audioLevel = level.level
        isSpeechDetected = level.isSpeech
        let roundActive = round != nil && !isMuted && (state == .waitingModel || state == .answering)
        let edge = bargeGate.process(level)
        switch edge {
        case .suspectStarted:
            guard roundActive, allowBargeIn else { return }
            suspectingSpeech = true
            report("bargeSuspect")
            if let r = round, !r.outputPausedByBarge, !r.appPaused {
                round?.outputPausedByBarge = true
                stack?.pausePlayback()
                speechContinuation.yield(.outputPaused(reason: .bargeIn))
            }
        case .cleared:
            guard suspectingSpeech else { return }
            suspectingSpeech = false
            guard let r = round else { return }
            if r.outputPausedByBarge {
                round?.outputPausedByBarge = false
                stack?.resumePlayback()
                speechContinuation.yield(.outputResumed(reason: .falseStart))
                report("bargeFalseStart")
            }
            // A candidate with no valid turn is noise: drop it so stale text
            // never becomes a draft.
            if !VoiceConversationTurnValidity.isValidTurn(stagedTranscript) {
                stagedTranscript = ""
                transcriptBaseline = rawTranscript
            }
        case .none:
            break
        }
    }

    private func consumeTranscript(_ raw: String) {
        rawTranscript = raw
        var display: String
        if raw.hasPrefix(transcriptBaseline) {
            display = String(raw.dropFirst(transcriptBaseline.count))
        } else {
            // Backend restarted its own accumulation: adopt wholesale.
            transcriptBaseline = ""
            display = raw
        }
        if let prefix = resumePrefix, !prefix.isEmpty {
            display = VoiceConversationFrameMath.joinCompletedSentences([prefix, display])
        }
        stagedTranscript = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMuted {
            endpointTimer?.cancel(); endpointTimer = nil
            return
        }
        if round != nil {
            // Barge-in confirmation requires persistence AND a valid ASR turn.
            if suspectingSpeech, VoiceConversationTurnValidity.isValidTurn(stagedTranscript) {
                if let r = round {
                    report("bargeConfirmed", "chars=\(stagedTranscript.count)")
                    let token = r.token
                    Task { [weak self] in
                        guard let self else { return }
                        self.suspectingSpeech = false
                        await self.finishRound(token: token, reason: .bargeIn, drained: false)
                        guard self.state == .waitingModel || self.state == .answering else { return }
                        self.resumeListeningAfterRound(roundToken: token)
                        // Keep endpointing the utterance the user is still speaking.
                        if !self.isMuted, !self.stagedTranscript.isEmpty {
                            self.scheduleEndpoint(for: self.stagedTranscript)
                        }
                    }
                }
            }
            return
        }
        if state == .listening, !stagedTranscript.isEmpty {
            scheduleEndpoint(for: stagedTranscript)
        }
    }

    private func scheduleEndpoint(for text: String) {
        endpointTimer?.cancel()
        guard state == .listening, !isMuted else { endpointTimer = nil; return }
        let window = VoiceConversationEndpointPolicy.isProbablyIncomplete(text)
            ? timing.endpointIncomplete
            : timing.endpointSilence
        endpointTimer = clock.schedule(after: window) { [weak self] in
            guard let self, self.state == .listening, !self.isMuted else { return }
            self.endpointTimer = nil
            let final = self.stagedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard VoiceConversationTurnValidity.isValidTurn(final) else {
                self.report("endpointDiscarded")
                self.stagedTranscript = ""
                self.transcriptBaseline = self.rawTranscript
                self.resumePrefix = nil
                return
            }
            self.report("endpointFired")
            self.submit(final)
        }
    }

    // MARK: - Turn flow

    private func submit(_ text: String) {
        guard state == .listening else { return }
        endpointTimer?.cancel(); endpointTimer = nil
        // From here on, new backend text belongs to the NEXT utterance.
        transcriptBaseline = rawTranscript
        resumePrefix = nil
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: activeAttempt)
        round = Round(token: token)
        currentRound = token
        lastSubmittedText = text
        stagedTranscript = ""
        answerText = ""
        turnErrorMessage = nil
        suspectingSpeech = false
        bargeGate.reset()
        state = .submitting
        let request = VoiceConversationTurnRequest(
            token: token,
            text: text,
            previousInterruptedAnswer: interruptedRoundContext
        )
        driving.startTurn(request) { [weak self] event in
            self?.receiveTurnEvent(event, token: token)
        }
        report("turnSubmitted", "chars=\(text.count)")
        // If the driving seam completed/failed synchronously the state may
        // already have moved; only settle to waitingModel when still submitting.
        if state == .submitting { state = .waitingModel }
    }

    private func receiveTurnEvent(_ event: VoiceConversationTurnEvent, token: VoiceConversationRoundToken) {
        guard isCurrent(token.sessionGeneration) else { report("lateEventFenced", "session"); return }
        guard let r = round, r.token == token else { report("lateEventFenced", "round"); return }
        switch event {
        case .answerUpdated(let cumulative):
            // DISPLAY ONLY. Tool progress and intermediate commentary live
            // here and are NEVER spoken; speech follows `finalAnswerUpdated`
            // and the durable confirmed body at `.completed` only.
            if cumulative == r.cumulativeText { return }
            guard cumulative.hasPrefix(r.cumulativeText) || r.cumulativeText.isEmpty else {
                report("cumulativeResetIgnored")
                return
            }
            round?.cumulativeText = cumulative
            answerText = cumulative
            if state == .waitingModel, !cumulative.isEmpty { state = .answering }
        case .finalAnswerUpdated(let cumulative):
            projectLiveFinalAnswer(cumulative)
        case .finalAnswerRetracted:
            retractLiveSpeechProjection()
        case .completed(let full):
            // `full` is ONLY the final-answer body, already normalized as a
            // whole by the driver (plain text). The whole round is never
            // replayed into speech.
            round?.modelCompleted = true
            round?.fullText = full
            if answerText.isEmpty { answerText = full }
            // MODEL-DONE TRUTH: the durable confirmed body has arrived, so
            // "waiting for the model" is over the instant this event lands.
            // The canonical confirmed-final-body-only driver may carry its
            // FIRST content in this very event (no prior `.answerUpdated` /
            // `.finalAnswerUpdated`): without this transition the session
            // presents `.waitingModel` — "waiting" copy and the mic-driven
            // waiting orb (VoiceOrbView) — while the answer is queued or
            // even audibly playing, and a barge false-start resume would
            // keep presenting that wrong state. A synchronous driver
            // completion still inside submit's handoff is the same truth
            // (submit only settles to waitingModel when still submitting).
            // Content-free completion stays put: the round-finish path
            // settles it to listening.
            if state == .waitingModel || state == .submitting, !answerText.isEmpty {
                state = .answering
            }
            commitFinalSpeechBody(full)
            settleAfterModelCompletion(token)
        case .failed(let message):
            turnErrorMessage = message
            report("roundFailed")
            restoreStagedIfNothingProduced(r)
            scheduleRoundFinish(token: token, reason: .roundFailed, drained: false)
        case .cancelled:
            report("roundCancelledExternally")
            scheduleRoundFinish(token: token, reason: .roundFailed, drained: false)
        }
    }

    /// The splitter only ever sees the capped speech basis (a prefix), so an
    /// over-long answer's tail is displayed and durable but never synthesized.
    private func speechBasis(_ text: String) -> String {
        text.count <= timing.answerTextCap ? text : String(text.prefix(timing.answerTextCap))
    }

    // MARK: - Final-answer speech projection
    //
    // Tool progress and intermediate commentary display through
    // `.answerUpdated` and are never spoken. `.finalAnswerUpdated` carries
    // the live segment while the driver structurally knows it is the only
    // (hence final) segment — pure chat answers therefore stream into speech
    // from the first sentence. The WHOLE body is normalized before any
    // sentence splitting (identity in the kernel, markdown→plain live); the
    // splitter only advances on a prefix-stable normalized basis. A seal
    // discovered late (`.finalAnswerRetracted`) stops audio, clears
    // unemitted text and freezes splitting until the durable confirmed
    // body arrives at `.completed`.

    private func projectLiveFinalAnswer(_ rawCumulative: String) {
        guard let r = round else { return }
        guard !r.speechRetracted, !r.outputStoppedByApp else { return }
        if rawCumulative == r.finalBasisRaw { return }
        guard rawCumulative.hasPrefix(r.finalBasisRaw) || r.finalBasisRaw.isEmpty else {
            report("finalProjectionResetIgnored")
            return
        }
        round?.finalBasisRaw = rawCumulative
        if state == .waitingModel, !rawCumulative.isEmpty { state = .answering }
        feedSpeechBasis(rawCumulative, finalize: false)
    }

    private func retractLiveSpeechProjection() {
        guard var r = round else { return }
        r.speechRetracted = true
        r.speechTailLost = true
        r.pendingUnitTexts = []
        r.pendingCharacters = 0
        // Discard the mis-projected basis AND ledger: the confirmed final
        // body starts a FRESH split (its own sentences, none replayed — the
        // old projection units were stopped and are never re-queued). Text
        // actually heard is retained in `spokenPrefix` for the receipt.
        let heard = r.completedSpokenCache
        if !heard.isEmpty {
            r.spokenPrefix = [r.spokenPrefix, heard]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        r.speechBasis = ""
        r.splitter = VoiceConversationSentenceSplitter()
        r.units = []
        r.totalQueuedFrames = 0
        r.playedFrames = 0
        r.completedSpokenCache = r.spokenPrefix
        r.roundTextCompletedEmitted = false
        round = r
        playingUnitProgress = nil
        currentSpokenText = ""
        stack?.stopPlayback()
        outputLevel = 0
        speechContinuation.yield(.outputStopped(token: r.token, reason: .roundFailed))
        report("finalAnswerRetractedSpoken", "playedFrames=\(r.playedFrames)")
    }

    private func commitFinalSpeechBody(_ confirmedFinalText: String) {
        guard var r = round, !r.speechFrozenShift else { return }
        let wasRetracted = r.speechRetracted
        r.speechRetracted = false
        round = r
        if wasRetracted {
            // The fresh full split of the confirmed body recovers the tail.
            r.speechTailLost = false
            round = r
        }
        feedSpeechBasis(confirmedFinalText, finalize: true)
    }

    private func feedSpeechBasis(_ rawBasis: String, finalize: Bool) {
        guard let current = round, !current.outputStoppedByApp else { return }
        let normalized = speechNormalizer(speechBasis(rawBasis))
        if normalized.hasPrefix(current.speechBasis) {
            // Mutate the splitter ON `round` (a local struct copy would drop
            // the consumed cursor and re-split/replay the whole answer).
            round?.speechBasis = normalized
            let texts = round?.splitter.feed(cumulative: normalized, finalize: finalize) ?? []
            queue(texts)
            return
        }
        if current.speechBasis.hasPrefix(normalized), !finalize {
            // Lagging normalization of a still-growing body: keep the fuller
            // basis already split.
            return
        }
        var r = current
        // The whole-body normalization moved under already-split text (a
        // fenced block closed, for example): already-emitted sentences can
        // neither be re-verified nor re-issued without replay. Freeze new
        // splitting; the confirmed body at completion may still extend from
        // this basis if it turns out prefix-consistent.
        guard !r.speechFrozenShift else { return }
        r.speechFrozenShift = true
        r.speechTailLost = true
        r.pendingUnitTexts = []
        r.pendingCharacters = 0
        round = r
        report("speechBasisShiftFrozen")
        // If the model is already complete, nothing further will confirm a
        // longer prefix: settle with what is queued/played.
        if r.modelCompleted {
            maybeEmitRoundTextCompleted()
        }
    }

    /// A failure that reached the app BEFORE any model output existed (busy
    /// barrier, missing provider, launch validation, pre-run failure): the
    /// user's recognized words were never persisted as a run, so stage them
    /// again instead of silently dropping the utterance.
    private func restoreStagedIfNothingProduced(_ r: Round) {
        guard r.cumulativeText.isEmpty, r.fullText == nil, !r.playbackBegan else { return }
        let text = lastSubmittedText
        guard !text.isEmpty, stagedTranscript.isEmpty else { return }
        stagedTranscript = text
        report("stagedRestoredAfterFailedLaunch")
    }

    private func queue(_ texts: [String]) {
        guard var r = round, !r.outputStoppedByApp else { return }
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Explicit answer-text cap for the SPEECH pipeline: visible text
            // is retained in full by the app layer; beyond the cap the tail
            // is not synthesized (receipts stay honest about what played).
            guard r.pendingCharacters + trimmed.count <= timing.answerTextCap else {
                report("speechAnswerCapped")
                break
            }
            r.pendingUnitTexts.append(trimmed)
            r.pendingCharacters += trimmed.count
        }
        round = r
        emitWindowUnits()
    }

    /// Refills the bounded lookahead window: at most `lookaheadUnits`
    /// emitted-but-not-played units exist at any time, so `unitQueued`
    /// control events can never outrun the bridge channel.
    private func emitWindowUnits() {
        guard var r = round, !r.outputStoppedByApp else { return }
        while !r.pendingUnitTexts.isEmpty, r.outstandingUnits < timing.lookaheadUnits {
            let text = r.pendingUnitTexts.removeFirst()
            r.pendingCharacters -= text.count
            let unit = VoiceConversationSpeechUnit(
                id: UUID(), token: r.token, index: r.units.count, text: text
            )
            r.units.append(UnitLedger(unit: unit))
            if !r.roundStartedEmitted {
                r.roundStartedEmitted = true
                speechContinuation.yield(.roundStarted(r.token))
            }
            speechContinuation.yield(.unitQueued(unit))
        }
        round = r
        maybeEmitRoundTextCompleted()
    }

    /// `roundTextCompleted` fires only once ALL split text has actually been
    /// emitted — which for long answers is later than model end-of-stream.
    /// The bridge uses it (plus the final unitCount) to decide when the
    /// round's synthesis is complete and `endRoundAudio` may be called.
    private func maybeEmitRoundTextCompleted() {
        guard let r = round, r.modelCompleted, r.allUnitsEmitted,
              !r.roundTextCompletedEmitted else { return }
        round?.roundTextCompletedEmitted = true
        speechContinuation.yield(.roundTextCompleted(token: r.token, unitCount: r.units.count))
        report("roundTextCompleted", "units=\(r.units.count)")
        if r.units.isEmpty {
            // Nothing will ever be spoken for this round: settle cleanly.
            scheduleRoundFinish(token: r.token, reason: nil, drained: true)
            return
        }
        // Drain is now purely an engine-progress question.
        if !r.pendingUnits {
            recheckPlaybackProgress()
        }
    }

    private func scheduleRoundFinish(
        token: VoiceConversationRoundToken,
        reason: VoiceConversationStopReason?,
        drained: Bool
    ) {
        guard var r = round, r.token == token, !r.finishScheduled else { return }
        r.finishScheduled = true
        round = r
        Task { [weak self] in
            guard let self else { return }
            await self.finishRound(token: token, reason: reason, drained: drained)
            self.resumeListeningAfterRound(roundToken: token)
        }
    }

    private func settleAfterModelCompletion(_ token: VoiceConversationRoundToken) {
        guard let r = round, r.token == token else { return }
        if r.outputStoppedByApp {
            // The app explicitly stopped this round's audio: nothing left to
            // drain even though unsynthesized text was dropped.
            scheduleRoundFinish(token: token, reason: .appInitiated, drained: false)
            return
        }
        if !r.allUnitsEmitted {
            // Long answer, bounded window: roundTextCompleted (and the drain
            // question) arrives only once the final units have been emitted.
            return
        }
        maybeEmitRoundTextCompleted()
        if r.units.isEmpty {
            // Nothing to ever speak: maybeEmitRoundTextCompleted settled it.
            return
        }
        // Check for an already-satisfied drain (fast player), else bound the
        // wait with the progress-based watchdog.
        recheckPlaybackProgress()
        guard let r2 = round, r2.token == token, !r2.finishScheduled else { return }
        armDrainWatchdog(token)
    }

    private func armDrainWatchdog(_ token: VoiceConversationRoundToken) {
        guard var r = round, r.token == token else { return }
        r.drainWatchdog?.cancel()
        r.watchdogPlayedSnapshot = r.playedFrames
        let clock = self.clock
        r.drainWatchdog = clock.schedule(after: timing.drainWatchdog) { [weak self] in
            self?.drainWatchdogFired(token: token)
        }
        round = r
    }

    private func drainWatchdogFired(token: VoiceConversationRoundToken) {
        guard var r = round, r.token == token else { return }
        r.drainWatchdog = nil
        if r.playedFrames > r.watchdogPlayedSnapshot {
            // Output is progressing — give it another window.
            round = r
            armDrainWatchdog(token)
            return
        }
        if r.pendingUnits, !r.endRoundAudioReceived {
            report("drainTimeout")
            round = r
            Task { [weak self] in
                guard let self else { return }
                await self.finishRound(token: token, reason: .roundFailed, drained: false)
                self.resumeListeningAfterRound(roundToken: token)
            }
            return
        }
        round = r
    }

    private func consumePlayedFrames(_ frames: Int) {
        guard var r = round, frames >= r.playedFrames else { return }
        r.playedFrames = frames
        round = r
        // STATE FOLLOWS ACTUAL PLAYBACK: this round's own audio left the
        // speaker, so the assistant is answering — never present "waiting
        // for model" while confirmed output is audibly playing, whatever
        // event-order gap a pluggable driver seam may leave above.
        if frames > 0, state == .waitingModel { state = .answering }
        recheckPlaybackProgress()
    }

    private func recheckPlaybackProgress() {
        guard var r = round else { return }
        var offset = 0
        var spoken: [String] = []
        var progress: (index: Int, fraction: Double)?
        var completions: [VoiceConversationSpeechUnit] = []
        for index in r.units.indices {
            let start = offset
            offset += r.units[index].expectedFrames
            if !r.units[index].completed, r.units[index].ended, r.playedFrames >= offset {
                r.units[index].completed = true
                completions.append(r.units[index].unit)
            }
            if r.units[index].completed {
                spoken.append(r.units[index].unit.text)
            } else {
                let length = r.units[index].expectedFrames
                let fraction = length > 0
                    ? min(1, max(0, Double(r.playedFrames - start) / Double(length)))
                    : 0
                progress = (index: index, fraction: fraction)
                // Quantized: unitProgress is a droppable display sample and
                // must never crowd the bounded control events (unitQueued /
                // roundTextCompleted) out of the shared channel.
                if fraction - r.units[index].lastProgressFraction >= timing.progressQuant {
                    r.units[index].lastProgressFraction = fraction
                    round = r
                    speechContinuation.yield(.unitProgress(unit: r.units[index].unit, fraction: fraction))
                    r = round ?? r
                }
                break
            }
        }
        let allSpoken = r.spokenPrefix.isEmpty ? spoken : [r.spokenPrefix] + spoken
        r.completedSpokenCache = VoiceConversationFrameMath.joinCompletedSentences(allSpoken)
        // Drain requires the FULL truth: every split unit emitted, the model
        // done, the bridge done (endRoundAudio) and all audio played out.
        let drainedNow = r.modelCompleted
            && r.roundTextCompletedEmitted
            && r.endRoundAudioReceived
            && r.allUnitsEmitted
            && r.units.allSatisfy { $0.completed }
        round = r
        for unit in completions {
            speechContinuation.yield(.unitCompleted(unit))
        }
        if !completions.isEmpty {
            // Refill the bounded lookahead window with retained text.
            emitWindowUnits()
        }
        playingUnitProgress = progress
        if let progress {
            currentSpokenText = progress.index < r.units.count ? r.units[progress.index].unit.text : ""
        } else {
            currentSpokenText = ""
        }
        if drainedNow, !(round?.drained ?? true), !(round?.finishScheduled ?? true) {
            round?.drained = true
            report("outputDrained")
            scheduleRoundFinish(token: r.token, reason: nil, drained: true)
        }
    }

    /// Single round teardown path. Fence-first: `round` is cleared BEFORE
    /// awaiting the driving cancel barrier, so no late callback of the old
    /// round can resume output or touch state.
    private func finishRound(token: VoiceConversationRoundToken, reason: VoiceConversationStopReason?, drained: Bool) async {
        guard let r = round, r.token == token else { return }
        round = nil
        currentRound = nil
        r.drainWatchdog?.cancel()
        playingUnitProgress = nil
        currentSpokenText = ""
        outputLevel = 0
        // Always stop/reset the engine counter (epoch fence): every round's
        // played-progress accounting starts from zero. Pausing preserved the
        // position; a finished or cancelled round must not leak it.
        stack?.stopPlayback()
        if !drained {
            speechContinuation.yield(.outputStopped(token: r.token, reason: reason ?? .roundFailed))
        } else {
            speechContinuation.yield(.outputDrained(token: r.token))
        }
        if r.playbackBegan {
            emitReceipt(for: r, drained: drained && !r.speechTailLost)
        }
        if !drained || r.speechTailLost {
            interruptedRoundContext = Self.makeInterrupted(
                from: r,
                pausedForBargeIn: r.outputPausedByBarge || reason == .bargeIn
            )
        }
        let driving = self.driving
        await driving.cancelTurn(r.token)
        report("roundFinished", drained ? "drained" : (reason?.rawValue ?? "ended"))
    }

    private static func makeInterrupted(
        from r: Round, pausedForBargeIn: Bool
    ) -> VoiceConversationInterruptedRound {
        let fraction = r.totalQueuedFrames > 0
            ? min(1, max(0, Double(r.playedFrames) / Double(r.totalQueuedFrames)))
            : (r.modelCompleted ? 1 : 0)
        let answerText = r.fullText
            ?? (r.cumulativeText.isEmpty
                ? (r.finalBasisRaw.isEmpty ? r.speechBasis : r.finalBasisRaw)
                : r.cumulativeText)
        return VoiceConversationInterruptedRound(
            roundToken: r.token,
            answerText: answerText,
            spokenText: r.completedSpokenCache,
            speechFraction: fraction,
            pausedForBargeIn: pausedForBargeIn
        )
    }

    private func emitReceipt(for r: Round, drained: Bool) {
        let receipt = VoiceConversationSpeechReceipt(
            token: r.token,
            status: drained ? .completed : .interrupted,
            spokenText: r.completedSpokenCache,
            answerText: r.fullText ?? r.cumulativeText
        )
        report("receipt", "status=\(receipt.status.rawValue) chars=\(receipt.spokenText.count)")
        let driving = self.driving
        Task { [driving] in await driving.reportSpeech(receipt) }
    }

    private func resumeListeningAfterRound(roundToken: VoiceConversationRoundToken) {
        guard round?.token != roundToken, round == nil else { return }
        guard state == .waitingModel || state == .answering || state == .submitting else { return }
        state = .listening
        // A real utterance spoken while the answer played (barge candidate or
        // plain double-talk) keeps endpointing; noise clears on fire.
        if !isMuted, !stagedTranscript.isEmpty {
            scheduleEndpoint(for: stagedTranscript)
        }
    }

    // MARK: - VoiceConversationSpeechOutput (the app TTS bridge feeds this)

    var completedSpokenText: String { round?.completedSpokenCache ?? "" }

    func appendAudio(_ chunk: VoiceConversationAudioChunk, to unit: VoiceConversationSpeechUnit)
        -> VoiceConversationSpeechAppendResult
    {
        guard var r = round, r.token == unit.token, !r.outputStoppedByApp else {
            report("appendRejected", "stale")
            return .rejectedStale
        }
        guard let index = r.units.firstIndex(where: { $0.unit.id == unit.id }),
              r.units[index].unit.index == unit.index,
              !r.units[index].ended,
              !r.units[index].completed else {
            report("appendRejected", "staleUnit")
            return .rejectedStale
        }
        guard chunk.isValid else {
            report("appendRejected", "format")
            return .rejectedInvalidFormat
        }
        let rate = stack?.outputSampleRate ?? 48_000
        let frames = VoiceConversationFrameMath.outputFrames(
            chunkFrames: chunk.frameCount, chunkSampleRate: chunk.sampleRate, outputSampleRate: rate
        )
        guard frames > 0 else {
            report("appendRejected", "format")
            return .rejectedInvalidFormat
        }
        let capacity = Int(timing.maxQueuedSeconds * rate)
        let unplayed = max(0, r.totalQueuedFrames - r.playedFrames)
        guard unplayed + frames <= capacity else {
            report("appendRejected", "capacity")
            return .rejectedOverCapacity
        }
        guard stack?.scheduleChunk(chunk) ?? false else {
            report("appendRejected", "engine")
            return .rejectedOverCapacity
        }
        r.units[index].expectedFrames += frames
        r.totalQueuedFrames += frames
        round = r
        recheckPlaybackProgress()
        return .accepted
    }

    func endUnit(_ unit: VoiceConversationSpeechUnit) {
        guard var r = round, r.token == unit.token,
              let index = r.units.firstIndex(where: { $0.unit.id == unit.id }),
              !r.units[index].ended else { return }
        r.units[index].ended = true
        round = r
        recheckPlaybackProgress()
    }

    func endRoundAudio(_ token: VoiceConversationRoundToken) {
        guard var r = round, r.token == token else { return }
        r.endRoundAudioReceived = true
        stack?.endQueuedAudio()
        round = r
        recheckPlaybackProgress()
        // The model may already be done; drain check happens in recheck.
    }

    func pauseOutput() {
        guard let r = round, !r.appPaused, !r.outputPausedByBarge else { return }
        round?.appPaused = true
        stack?.pausePlayback()
        speechContinuation.yield(.outputPaused(reason: .appInitiated))
    }

    func resumeOutput() {
        guard let r = round, r.appPaused else { return }
        round?.appPaused = false
        stack?.resumePlayback()
        speechContinuation.yield(.outputResumed(reason: .manual))
    }

    /// App-level stop of the round's audio only. The model generation keeps
    /// streaming; further units for this round are no longer synthesized or
    /// queued (appends reject as stale).
    func stopNow() {
        guard var r = round else { return }
        let token = r.token
        r.outputStoppedByApp = true
        r.appPaused = false
        r.outputPausedByBarge = false
        r.pendingUnitTexts = []
        r.pendingCharacters = 0
        round = r
        stack?.stopPlayback()
        outputLevel = 0
        currentSpokenText = ""
        speechContinuation.yield(.outputStopped(token: token, reason: .appInitiated))
        report("outputStoppedByApp")
        // If the model was already done, nothing is left to drain.
        if r.modelCompleted {
            scheduleRoundFinish(token: token, reason: .appInitiated, drained: false)
        }
    }
}

// MARK: - Production scheduler

/// Wall-clock one-shot timers behind the scheduling seam.
@MainActor
final class VoiceConversationSystemScheduler: VoiceConversationScheduling {
    func schedule(after seconds: Double, action: @escaping @MainActor () -> Void) -> any VoiceConversationScheduled {
        let handle = VoiceConversationSystemTimer()
        handle.task = Task { @MainActor [weak handle] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, handle?.cancelled != true else { return }
            action()
        }
        return handle
    }
}

@MainActor
final class VoiceConversationSystemTimer: VoiceConversationScheduled {
    var task: Task<Void, Never>?
    var cancelled = false
    func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
    }
}
