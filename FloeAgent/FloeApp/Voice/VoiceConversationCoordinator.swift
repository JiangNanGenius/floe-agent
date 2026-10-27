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
//   the injected scheduling seam, never a hidden wall clock. Since 2026-10-25
//   the SAME armed window is the required actual microphone-quiet window,
//   JOINTLY with transcript stability: a window that expires while the real
//   capture stream has not yet shown that much continuous non-speech DEFERS
//   the decision and releases it event-driven at the exact quiet crossing —
//   never a forced submit into ongoing speech, never a shorter invented
//   quiet rule, never a longer timeout, never a poll. Evidence spans the whole
//   capture stretch, so speech seen before a late partial re-arm still
//   blocks submission. A stretch with no real level samples at all keeps the
//   original transcript-only latency (legacy level-less hosts), and the
//   recognition-health bounds escalate sustained voice-without-text exactly
//   as before.
// - Barge-in: persistent echo-processed speech TENTATIVELY PAUSES playback at
//   its exact position for AT MOST the bounded candidate pause window
//   (1.2 s, 2026-10-25); only a genuinely NEW valid ASR turn that arrived
//   after this candidate opened CONFIRMS and cancels the owned round —
//   late re-accumulations of already-submitted words and mirrors of the
//   actually-played output never do (amplitude alone never discards a
//   generation, similarity alone never confirms one). An unconfirmed pause
//   resumes at the SAME position inside the window without dropping queued
//   output or regenerating the answer, a bounded number of false-start
//   pauses per round keeps sustained noise/echo from pause-cycling, and the
//   candidate's identity stays open past the pause for a slow real partial.
//   Capture keeps streaming during the pause so the pre-roll / first
//   syllable is retained.
// - Mute stops physical mic collection; no hidden capture, no auto-submit of
//   a muted draft, and answer playback stays available.
// - ONE auto-submit idempotency anchor per session (2026-10-27 duplicate
//   utterance): the recognition path re-decodes the whole uncommitted window,
//   so the SAME spoken utterance can return later as a non-prefix rewrite —
//   typically flipped between Simplified and Traditional Han. Automatic paths
//   (staging, the round-end re-arm and the endpoint decision itself) refuse a
//   draft that is the folded form of the utterance already handed to the
//   driving seam while NO real microphone speech has arrived since that
//   submit. Exactly one utterance is remembered per session, never a text
//   history: the same words spoken again after fresh microphone speech stay
//   fully usable, a typed `submitText` or `sendNow` is deliberate intent and
//   launches, and a launch that produced nothing hands the draft back
//   unre-fenced. Late partials, finals, stream restarts and superseded-session
//   callbacks can never mint a turn without a new utterance.
// - Background/lock/interruption/route loss pause the session and cancel the
//   current generation and audio. Resume is manual only. The pending unsent
//   transcript survives.
// - Receipts come from engine played-frames (true drain), never from the TTS
//   producer's own final flags.

import Foundation
import Combine

@MainActor
final class VoiceConversationCoordinator: ObservableObject, VoiceConversationSpeechOutput {

    /// Bounded drain-tail confirmation cadence. These are poll bounds for a
    /// DEAD pipeline, never a success delay: success is defined only by real
    /// rendered-frame growth in the stack's output tap.
    private static let outputSettleInterval: Double = 0.05
    private static let maxOutputSettleAttempts = 12

    /// Settled timing constants (product-fixed; injectable for tests).
    struct Timing: Sendable {
        var endpointSilence: Double = 0.9
        var endpointIncomplete: Double = 1.6
        // JOINT end-of-utterance rule (2026-10-25, premature-submit fix):
        // the armed `endpointSilence`/`endpointIncomplete` window is the
        // required ACTUAL microphone-quiet window as well as the transcript-
        // stability window — deliberately no separate shorter quiet constant.
        // The transcript window measures ASR partial cadence, not mic
        // silence; a Whisper-slow frozen partial could otherwise send while
        // the user was measurably still speaking (the reported "submits
        // halfway through"). A clean end-of-utterance already shows ≥ the
        // window of quiet when its timer fires, so normal latency is
        // UNCHANGED. Ongoing voice DEFERS event-driven; there is deliberately
        // NO forced-submit cap (never submit into actual speech) — sustained
        // voiced-without-recognition stays bounded by the existing
        // recognition-health failure, and manual send bypasses as before.
        var bargeSuspect: Double = 0.18
        var bargeClear: Double = 0.25
        /// HARD upper bound on ONE tentative barge-in pause (product
        /// decision 2026-10-25): without a valid confirmation the output
        /// MUST resume from the original playback position within this
        /// window. Never a stop/flush — the queue and the answer survive.
        var bargeCandidateWindow: Double = 1.2
        /// How long the audio candidate's confirmation IDENTITY stays open
        /// after its suspect edge (measured from the edge, so it extends
        /// past the pause bound). Sized generously because the 1.2 s bound
        /// is a maximum PAUSE, not an ASR deadline: a genuine Whisper-class
        /// partial slower than the pause must still be able to confirm.
        /// After the window closes only a NEW suspect edge can re-open
        /// confirmation — late text can never hijack a stale candidate.
        var bargeConfirmationWindow: Double = 4.0
        /// Consecutive unconfirmed barge pauses allowed for one round before
        /// further candidates stop pausing the output (bounded so sustained
        /// noise/echo can never enter endless pause cycles). Fresh valid ASR
        /// can still confirm and cancel while suppressed — natural
        /// interruption never depends on a tentative pause existing.
        var maxBargeFalseStartPauses: Int = 2
        var preparationWatchdog: Double = 25
        var drainWatchdog: Double = 20
        var maxQueuedSeconds: Double = 45
        /// Cumulative SECONDS of voiced microphone audio that may pass with
        /// zero ASR text inside one listening stretch before the recognizer
        /// is declared dead. Silence costs nothing (silence is legitimate);
        /// speech-with-no-recognition is not indefinitely survivable.
        var voicedWithoutTextLimit: Double = 8
        /// Consecutive transcription-stream restarts that carried SPEECH but
        /// produced NO text before the session fails visibly.
        var maxTextlessSpeechRestarts: Int = 2
        /// Consecutive restarts of streams that died WITHOUT speech and
        /// WITHOUT text FASTER than this (a stream that lived longer is a
        /// healthy Apple auto-end after a quiet period, NOT an error: pure
        /// silence renewals must never become a failure). Chosen well below
        /// the real auto-end window (~35–60 s) so even if the droppable
        /// levels stream undercounts durations under load, a healthy renewal
        /// is not misclassified.
        var rapidStreamWindow: Double = 5
        /// Consecutive rapid empty terminations before the session fails.
        var maxRapidEmptyRestarts: Int = 2
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
        /// The staged draft when the CURRENT barge audio candidate opened.
        /// Confirmation requires text genuinely newer than this snapshot —
        /// pre-candidate (and therefore stale/echo) text alone never
        /// cancels the answer (settled 2026-10-25).
        var bargeCandidateSnapshot = ""
        /// True from a suspect edge until the bounded confirmation-identity
        /// window closes. The tentative PAUSE is `bargeCandidateWindow`;
        /// confirmation may still arrive until `bargeConfirmationWindow` so
        /// a slow genuine utterance is not made unusable by the pause bound.
        var bargeCandidatePending = false
        var bargeCandidateTimer: (any VoiceConversationScheduled)?
        var bargeCandidateFreshTimer: (any VoiceConversationScheduled)?
        /// Consecutive tentative barge pauses this round has already paid
        /// for without confirmation. Past `maxBargeFalseStartPauses` new
        /// candidates stop pausing (never cycle); confirmation still works.
        var bargeFalseStartStrikes = 0
        var appPaused = false
        var outputStoppedByApp = false
        var roundStartedEmitted = false
        var drained = false
        var finishScheduled = false
        var completedSpokenCache = ""
        var drainWatchdog: (any VoiceConversationScheduled)?
        var watchdogPlayedSnapshot = 0
        /// The round's ONE frozen playback configuration. The bridge freezes
        /// a value per unit before its first chunk; the FIRST value wins so
        /// every unit of an answer uses the same tempo/intonation even if
        /// settings change mid-answer. Nil until the bridge delivers it (old
        /// sinks/tests never do, which is neutral).
        var frozenPlaybackControls: VoicePlaybackControls?
        /// Rendered-frame baseline captured at the LAST player receipt; the
        /// post-input effect tail is measured as growth from here.
        var outputDrainBaseline: Int?
        var outputSettleAttempts = 0

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
    /// True once the armed transcript window fired while the real capture
    /// stream had not yet shown the required microphone-quiet window: the
    /// decision is deferred and released event-driven from `consume(level)`
    /// at the first genuine-quiet crossing — never a forced submit into
    /// ongoing speech, never a poll task. Cleared by every re-arm/lifecycle
    /// fence (identity fences).
    private var endpointDeferralActive = false
    /// The SAME 0.9/1.6 window that armed the deferred decision, in seconds:
    /// the deferred release must observe this much continuous real quiet.
    /// Stored at deferral time because a new partial re-arms a new window.
    private var endpointDeferralWindow: Double = 0
    /// True once ANY real level sample arrived in this capture stretch. A
    /// re-arm must never erase it: after samples were seen, a late partial
    /// or a route gap with no further samples is NOT evidence of quiet. A
    /// stretch that never delivers level samples (legacy level-less hosts)
    /// keeps the original transcript-only latency exactly.
    private var micSamplesSeen = false
    /// Continuous non-speech seconds integrated from REAL capture sample
    /// durations (the same stream the barge gate and the health clocks
    /// already consume): no wall clock, no polling task, deterministic for
    /// the injectable-clock rig. Reset to 0 by any voiced sample, and at the
    /// boundary of a capture stretch (start/resume/mute).
    private var micQuietRun: Double = 0
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
    /// pre-launch failure re-stage the user's recognized words, and anchors
    /// the ONE stale-provenance rule of the barge arbiter: text equal to or
    /// the tail of the CURRENT round's own submitted utterance is
    /// indistinguishable from a late final of that utterance, so it can
    /// never auto-cancel this answer (settled 2026-10-25). Never a history:
    /// the same words stay fully usable in every later round.
    private var lastSubmittedText = ""
    /// The session's pre-auto-submit idempotency anchor: the folded identity
    /// of the ONE utterance already handed to the driving seam, plus whether
    /// real microphone speech arrived since. Automatic paths consult it before
    /// arming or launching an endpoint; `sendNow()` and typed `submitText(_:)`
    /// are deliberate intent and never do (2026-10-27 duplicate-utterance
    /// repair — a Whisper re-decode of the same window, often in the other Han
    /// script, must never mint a second turn).
    private var autoSubmitIdentity = VoiceConversationUtteranceIdentity()
    /// True once real microphone speech arrived after a draft was carried
    /// across a transcription restart or a manual resume. Without such speech,
    /// a rebuilt stream that re-recognizes the carried sentence is the SAME
    /// utterance and must not be joined into a doubled draft.
    private var carriedDraftFreshSpeech = false
    /// Text kept across a manual pause; prepended to the first partial of the
    /// rebuilt transcription session so the pending utterance completes.
    private var resumePrefix: String?

    // Recognition-health bookkeeping (per backend stream / per attempt).
    // Silence is legitimate; speech that produces NO recognition is not
    // indefinitely survivable. These counters turn a silent dead ASR path
    // into a visible, actionable failure.
    /// True once ANY transcript text arrived on the current backend stream.
    private var transcriptTextSeen = false
    /// Cumulative duration of voiced (isSpeech) capture samples since the
    /// last transcript text — resets on text, restart, mute-off and when a
    /// listening stretch re-arms. Silence never adds to this.
    private var voicedSecondsWithoutText: Double = 0
    /// Cumulative duration of ALL capture samples since the last transcript
    /// text — the stream's observed age, used to tell a healthy long-silence
    /// Apple auto-end (RENEWAL) from a rapid dying backend.
    private var observedSecondsWithoutText: Double = 0
    /// Consecutive restarts that had speech but no text (capped).
    private var textlessSpeechRestarts = 0
    /// Consecutive rapid no-speech no-text terminations (capped). A healthy
    /// silence renewal RESETS this — silence alone never becomes an error.
    private var rapidEmptyRestarts = 0

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

    /// Cancels the armed endpoint window AND its deferred-decision state as
    /// one unit. Every lifecycle fence (mute, pause, scene, navigation,
    /// session generation, submit) and every re-arm goes through here, so
    /// a stale deferral release can never survive into a new window, a new
    /// attempt, or a submitted turn (no duplicate commit). The capture
    /// stretch's real-level evidence (`micSamplesSeen`, `micQuietRun`) is
    /// deliberately NOT cleared here: it belongs to the stretch, not to an
    /// armed window, so a partial re-arm cannot launder ongoing speech into
    /// apparent quiet.
    private func clearEndpointTimer() {
        endpointTimer?.cancel()
        endpointTimer = nil
        endpointDeferralActive = false
        endpointDeferralWindow = 0
    }

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
        // A fresh capture stretch carries no earlier quiet evidence: the
        // joint endpoint gate must observe THIS stretch's real samples.
        micSamplesSeen = false
        micQuietRun = 0
        pausedReason = nil
        isMuted = false
        interruptedRoundContext = nil
        playingUnitProgress = nil
        lastSubmittedText = ""
        // A new session generation owns a new utterance identity: the previous
        // session's submitted words can never fence (or mint) a turn here, and
        // no carried draft survives the boundary.
        autoSubmitIdentity.reset()
        carriedDraftFreshSpeech = false
        transcriptTextSeen = false
        voicedSecondsWithoutText = 0
        observedSecondsWithoutText = 0
        textlessSpeechRestarts = 0
        rapidEmptyRestarts = 0
        state = .requestingPermission
        return attempt
    }

    /// Recovery budget for session preparation: a dead capture path is
    /// rebuilt ONCE with a fresh stack; a second failure is actionable.
    /// Permission, locale and model failures are never rebuild-recoverable —
    /// they need the user, not another engine.
    private static func recoverablePreparationFailure(_ failure: VoiceConversationFailure) -> Bool {
        switch failure {
        case .noAudioInput, .recognizerFailed: return true
        case .microphonePermissionDenied, .speechPermissionDenied,
             .localeUnsupported, .modelNotReady, .interrupted, .routeLost:
            return false
        }
    }

    /// beginTranscription → activate → startCapture with the REAL
    /// first-buffer readiness proof inside `startCapture`. Returns nil when
    /// the attempt was superseded mid-build (the caller must simply stop).
    ///
    /// The recognizer/backend is created BEFORE the microphone graph is
    /// brought up, matching the working dictation controller's proven
    /// sequence (2026-10-24 same-device iPhone A/B: dictation created its
    /// transcriber with no engine running and reached 正在听, while
    /// continuous had failed `voice.error.recognition` creating the backend
    /// AFTER session activation + engine start). Backend creation needs no
    /// engine — only the tap does — so the ordering difference had no
    /// reason to exist.
    private func buildCaptureStack(attempt: UInt64) async throws(VoiceConversationFailure) -> (any VoiceConversationStack)? {
        let stack = makeStack()
        do {
            try await stack.beginTranscription()
            guard isCurrent(attempt) else { stack.deactivate(); return nil }
            try await stack.activate()
            guard isCurrent(attempt) else { stack.deactivate(); return nil }
            try await stack.startCapture()
            guard isCurrent(attempt) else { stack.deactivate(); return nil }
            return stack
        } catch let failure {
            stack.deactivate()
            throw failure
        }
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

        // TRUE readiness first: a tap that never delivers a buffer is a dead
        // microphone path, not "listening". One full recoverable rebuild,
        // then a visible actionable failure — never an indefinite silent
        // Listening state behind a cancelled preparation watchdog.
        let built: (any VoiceConversationStack)?
        do {
            built = try await buildCaptureStack(attempt: attempt)
        } catch let failure where Self.recoverablePreparationFailure(failure) {
            guard isCurrent(attempt) else { return }
            report("preparationRebuild", failure.rawValue)
            do {
                built = try await buildCaptureStack(attempt: attempt)
            } catch let second {
                guard isCurrent(attempt) else { return }
                failCurrentSession(second)
                return
            }
        } catch let failure {
            guard isCurrent(attempt) else { return }
            failCurrentSession(failure)
            return
        }
        guard let stack = built else { return }
        // FINAL currency fence AFTER the build's last internal guard: an
        // `end()`/`pauseForScene` landing between "stack built + proven"
        // and this resumption must NOT publish `.listening` over a retired
        // attempt nor assign a stack the teardown has already passed by.
        // The fresh stack is fenced off the session here; a second
        // deactivate from an already-run teardown is inert by the
        // ownership/flag discipline inside the stack.
        guard isCurrent(attempt) else {
            report("buildSuperseded")
            stack.deactivate()
            return
        }

        preparationTimer?.cancel()
        preparationTimer = nil
        self.stack = stack
        // Fresh capture + fresh backend stream: re-arm the recognition-health
        // bookkeeping for this listening stretch.
        transcriptTextSeen = false
        voicedSecondsWithoutText = 0
        observedSecondsWithoutText = 0
        textlessSpeechRestarts = 0
        rapidEmptyRestarts = 0
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
        clearEndpointTimer()
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
        // The carried draft is fresh only if the user actually speaks again.
        carriedDraftFreshSpeech = false
        rawTranscript = ""
        transcriptBaseline = ""
        pausedReason = nil
        audioLevel = 0
        isSpeechDetected = false
        suspectingSpeech = false
        bargeGate = VoiceConversationBargeGate(
            suspectAfter: timing.bargeSuspect, clearAfter: timing.bargeClear
        )
        // A fresh capture stretch carries no earlier quiet evidence: the
        // joint endpoint gate must observe THIS stretch's real samples.
        micSamplesSeen = false
        micQuietRun = 0
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
        case .captureStalled:
            // Silence ALSO delivers buffers; a long gap means the tap path
            // is dead. Fail visibly (retry affordance), never keep an
            // indefinite "Listening" over a microphone that stopped firing.
            guard state.hasSession else { return }
            report("captureStalled")
            failCurrentSession(.noAudioInput)
        }
    }

    private func pauseSession(reason: VoiceConversationFailure) {
        guard state.hasSession || state == .requestingPermission, state != .ending else { return }
        teardownInFlight = true
        // Fence synchronously: a route loss arriving mid-preparation or
        // mid-round must stop every stale async path immediately.
        activeAttempt = nextAttemptValue()
        clearEndpointTimer()
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
        clearEndpointTimer()
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
    /// Unmute re-arms capture through the SAME real first-buffer readiness
    /// proof as session start: a microphone path that died while muted fails
    /// visibly instead of silently "listening".
    func setMuted(_ on: Bool) async {
        guard state.hasSession, on != isMuted else { return }
        let attempt = activeAttempt
        isMuted = on
        if on {
            stack?.stopCapture()
            clearEndpointTimer()
            // Capture stops with the mute: the next stretch must produce its
            // own real samples. Pre-mute quiet can never vouch for the
            // post-unmute draft (which, by the settled mute contract, is
            // finalized only by NEW transcript activity).
            micSamplesSeen = false
            micQuietRun = 0
            if suspectingSpeech {
                suspectingSpeech = false
                if round?.outputPausedByBarge == true {
                    endBargePause(reason: "muted")
                }
            }
        } else {
            do {
                try await stack?.startCapture()
            } catch let failure {
                guard isCurrent(attempt), state.hasSession else { return }
                failCurrentSession(failure)
                return
            }
            guard isCurrent(attempt), state.hasSession else { return }
            // The capture window while muted proves nothing: restart the
            // recognition-health clocks for the new capture stretch.
            voicedSecondsWithoutText = 0
            observedSecondsWithoutText = 0
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
    /// Speech recognizer task auto-finalizes after ~1 minute of no speech).
    /// A live conversation session must not die with it: restart the
    /// transcription session IN PLACE, carrying the pending draft across the
    /// boundary.
    ///
    /// What is BOUNDED: rapid empty terminations and speech-without-
    /// recognition restarts — two consecutive of each are tolerated, the
    /// next fails visibly with a retry affordance. What is NOT an error:
    /// healthy Apple auto-end renewals after long quiet periods. Silence
    /// alone must never escalate into a failure; the user must still be
    /// recognized after 60+ s of quiet, so a stream that lived well past
    /// the rapid window with no speech RESETS the consecutive streaks.
    private func restartTranscription(stack: any VoiceConversationStack, attempt: UInt64) async {
        guard isCurrent(attempt), state.hasSession, !teardownInFlight else { return }
        if let failure = stack.transcriptionFailureSnapshot() {
            report("transcriptStreamFailed", failure.rawValue)
            failCurrentSession(failure)
            return
        }
        // Classify the stream that just ended BEFORE resetting its clocks.
        if transcriptTextSeen {
            textlessSpeechRestarts = 0
            rapidEmptyRestarts = 0
        } else if voicedSecondsWithoutText >= 0.25 {
            rapidEmptyRestarts = 0
            textlessSpeechRestarts += 1
            if textlessSpeechRestarts > timing.maxTextlessSpeechRestarts {
                report("transcriptRestartCapped", "speechless")
                failCurrentSession(.recognizerFailed)
                return
            }
        } else if observedSecondsWithoutText < timing.rapidStreamWindow {
            textlessSpeechRestarts = 0
            rapidEmptyRestarts += 1
            if rapidEmptyRestarts > timing.maxRapidEmptyRestarts {
                report("transcriptRestartCapped", "rapidempty")
                failCurrentSession(.recognizerFailed)
                return
            }
        } else {
            // Healthy silence renewal: clear the streaks, keep going.
            textlessSpeechRestarts = 0
            rapidEmptyRestarts = 0
        }
        report("transcriptStreamRestart")
        if !stagedTranscript.isEmpty {
            resumePrefix = stagedTranscript
            // Only NEW unmuted microphone speech after this carry makes the
            // rebuilt stream's first sentence a genuinely different utterance.
            carriedDraftFreshSpeech = false
        }
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
        // New backend stream: re-arm its recognition-health clocks.
        transcriptTextSeen = false
        voicedSecondsWithoutText = 0
        observedSecondsWithoutText = 0
        observeTranscripts(stack, attempt: attempt)
        if state == .listening, !isMuted, !stagedTranscript.isEmpty {
            scheduleEndpoint(for: stagedTranscript)
        }
    }

    private func observeEngine(_ stack: any VoiceConversationStack, attempt: UInt64) {
        observationTasks.append(Task { [weak self] in
            for await event in stack.engineEvents {
                guard let self, !Task.isCancelled, self.isCurrent(attempt), self.state.hasSession else { return }
                switch event {
                case .playedFrames(let frames):
                    // Legacy/untagged doubles carry no epoch: credit the
                    // round that is active now (historical behavior).
                    self.consumePlayedFrames(frames, taggedEpoch: nil, stack: stack)
                case .playedFramesTagged(let frames, let epoch):
                    self.consumePlayedFrames(frames, taggedEpoch: epoch, stack: stack)
                }
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
        // Recognition-health clocks. Silence contributes ONLY to the stream-
        // age accumulator; the voiced-without-text accumulator stops the
        // session when actual speech produces no recognition for too long.
        let sampleSeconds = min(max(level.duration, 0), 0.5)
        // Endpoint joint-gate evidence (2026-10-25): integrate the SAME
        // physical stream into a continuous quiet run for THIS capture
        // stretch. Any real sample records that level evidence exists, so a
        // late partial or route gap with no further samples can never be
        // mistaken for quiet (and the evidence is never reset by a re-arm).
        // Pure bookkeeping — it never touches the recognition-health clocks
        // below (a deferral cannot hide a failure).
        micSamplesSeen = true
        if level.isSpeech {
            micQuietRun = 0
            // Physical freshness for the auto-submit anchor and for a draft
            // carried across a stream restart: only a REAL voiced microphone
            // sample can make later text a new utterance. Text alone never
            // proves it — a Whisper re-decode of old audio produces text with
            // no new speech at all (2026-10-27 duplicate-utterance repair).
            // A level delivered while MUTED is queued late audio from a
            // capture the coordinator already stopped: it keeps the meter and
            // quiet bookkeeping exactly as before, but it can never release
            // the replay fence (only unmuted owned capture proves speech).
            if !isMuted {
                autoSubmitIdentity.noteSpeech()
                if resumePrefix != nil { carriedDraftFreshSpeech = true }
            }
        } else {
            micQuietRun += sampleSeconds
        }
        if !isMuted, state.hasSession {
            observedSecondsWithoutText += sampleSeconds
            if level.isSpeech { voicedSecondsWithoutText += sampleSeconds }
            if state == .listening, round == nil,
               voicedSecondsWithoutText >= timing.voicedWithoutTextLimit {
                report("voicedWithoutText", "seconds=\(Int(voicedSecondsWithoutText))")
                failCurrentSession(.recognizerFailed)
                return
            }
        }
        let roundActive = round != nil && !isMuted && (state == .waitingModel || state == .answering)
        let edge = bargeGate.process(level)
        // EVENT-DRIVEN RELEASE of a deferred endpoint: the first real
        // sample that completes the SAME armed quiet window resolves the
        // decision NOW, inside the capture callback — no re-armed poll, no
        // wall clock. Only a live deferral can release, and every lifecycle
        // fence clears it, so pre-mute/old-attempt text cannot be revived
        // by levels alone.
        if endpointDeferralActive, !level.isSpeech,
           micQuietRun >= endpointDeferralWindow,
           state == .listening, !isMuted {
            endpointDeferralActive = false
            decideEndpoint()
        }
        switch edge {
        case .suspectStarted:
            guard roundActive, allowBargeIn, let r = round else { return }
            suspectingSpeech = true
            // Open (or REFRESH) the audio candidate identity. A re-edge
            // re-snapshots the current draft, so a partial that landed
            // between edges becomes the baseline for "new" text instead of
            // being frozen into a stale candidate forever.
            openBargeCandidate(current: r)
            let mayPause = r.bargeFalseStartStrikes < timing.maxBargeFalseStartPauses
            report("bargeSuspect",
                   "pause=\(mayPause && !r.appPaused && !r.outputPausedByBarge ? 1 : 0) strikes=\(r.bargeFalseStartStrikes)")
            guard mayPause, !r.appPaused, !r.outputPausedByBarge else { return }
            // Frames rendered during a pause are silence, not effect tail
            // progress: re-anchor the drain baseline on resume.
            round?.outputPausedByBarge = true
            round?.outputDrainBaseline = nil
            stack?.pausePlayback()
            speechContinuation.yield(.outputPaused(reason: .bargeIn))
            // HARD pause bound: without a valid confirmation the output
            // resumes from the SAME position inside the window — never a
            // stop, never a discard of queued units, never a regeneration.
            let token = r.token
            round?.bargeCandidateTimer = clock.schedule(after: timing.bargeCandidateWindow) { [weak self] in
                self?.bargePauseWindowFired(token: token)
            }
        case .cleared:
            guard suspectingSpeech else { return }
            suspectingSpeech = false
            if round?.outputPausedByBarge == true {
                endBargePause(reason: "silenceCleared")
            }
            // A candidate with no valid turn is noise: drop hesitation
            // residue so stale text never becomes a draft. Genuinely new
            // valid text SURVIVES the cleared pause — a slow real partial
            // that arrives next still confirms inside the identity window;
            // after the window, genuinely new words remain the user's
            // staged utterance for the endpoint after the round, while
            // stale re-accumulations and played-output mirrors are fenced
            // at staging and can never become that draft.
            dropUnconfirmedBargeText()
        case .none:
            break
        }
    }

    // MARK: - Barge-in candidate bookkeeping (2026-10-25 conservative rules)

    /// Opens or refreshes the candidate identity for the CURRENT round:
    /// snapshot the draft as it stands, and (re-)arm the bounded
    /// confirmation-identity timer. The PAUSE bound is armed separately and
    /// only around an actual tentative pause.
    private func openBargeCandidate(current r: Round) {
        round?.bargeCandidateSnapshot = stagedTranscript
        round?.bargeCandidatePending = true
        round?.bargeCandidateFreshTimer?.cancel()
        let token = r.token
        round?.bargeCandidateFreshTimer = clock.schedule(after: timing.bargeConfirmationWindow) { [weak self] in
            self?.bargeCandidateFreshnessExpired(token: token)
        }
    }

    /// The 1.2 s PAUSE bound fired with no valid confirmation: resume from
    /// the exact position. The candidate IDENTITY stays open until its own
    /// bounded freshness window, so a Whisper-slow genuine partial arriving
    /// after the resume can still cancel the answer.
    private func bargePauseWindowFired(token: VoiceConversationRoundToken) {
        guard let r = round, r.token == token, r.outputPausedByBarge else { return }
        endBargePause(reason: "windowExpired")
    }

    /// The confirmation-identity window closed: from now on only a NEW
    /// suspect edge can open confirmation. Late text alone can never
    /// hijack this superseded candidate — including text arriving while a
    /// continuous speech run keeps the gate internally suspecting with no
    /// re-edge possible (the published tentative state is exactly the
    /// candidate's own lifetime).
    private func bargeCandidateFreshnessExpired(token: VoiceConversationRoundToken) {
        guard let r = round, r.token == token, r.bargeCandidatePending else { return }
        round?.bargeCandidatePending = false
        round?.bargeCandidateSnapshot = ""
        round?.bargeCandidateFreshTimer = nil
        suspectingSpeech = false
        report("bargeCandidateExpired", "chars=\(stagedTranscript.count)")
        // Backstop: an identity window can outlive a pause only because the
        // pause already ended; if it somehow did not, end it now — a pause
        // never survives its own candidate.
        if r.outputPausedByBarge {
            endBargePause(reason: "freshnessBackstop")
        }
        dropUnconfirmedBargeText()
    }

    /// Ends the TENTATIVE PAUSE part of the current barge candidate without
    /// a valid confirmation. Position-preserving by contract: `resumePlayback`
    /// continues at the SAME offset (never `stopPlayback`, never a queue
    /// flush, never a cancel), one bounded false-start strike is counted,
    /// and the output ledger keeps every queued unit.
    private func endBargePause(reason: String) {
        round?.bargeCandidateTimer?.cancel()
        round?.bargeCandidateTimer = nil
        guard let r = round, r.outputPausedByBarge else { return }
        round?.outputPausedByBarge = false
        stack?.resumePlayback()
        speechContinuation.yield(.outputResumed(reason: .falseStart))
        round?.bargeFalseStartStrikes += 1
        report("bargeFalseStart", "reason=\(reason) strikes=\(r.bargeFalseStartStrikes + 1)")
        recheckPlaybackProgress()
    }

    /// Hesitation/noise-only residue left by an unconfirmed candidate is
    /// dropped so it never becomes a draft; a real (valid) partially
    /// recognized utterance is KEPT — the 1.2 s bound is a maximum pause,
    /// never a deadline that discards genuine slowly arriving ASR.
    private func dropUnconfirmedBargeText() {
        guard !stagedTranscript.isEmpty else { return }
        guard !VoiceConversationTurnValidity.isValidTurn(stagedTranscript) else { return }
        discardStagedText()
    }

    /// Clears the draft AND advances the baseline past the backend's current
    /// accumulation, so the same words cannot re-stage and confirm later.
    private func discardStagedText() {
        stagedTranscript = ""
        transcriptBaseline = rawTranscript
    }

    /// The speech that ACTUALLY reached the speaker for this round: every
    /// sentence completed plus the unit currently playing. This — never the
    /// answer's unspoken tail — is the only echo reference.
    private func playedEchoReference(_ r: Round) -> String {
        let spoken = r.completedSpokenCache
        let playing = currentSpokenText
        if playing.isEmpty { return spoken }
        if !spoken.isEmpty, spoken.contains(playing) { return spoken }
        return [spoken, playing].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func consumeTranscript(_ raw: String) {
        // ANY backend text proves the recognizer path is producing output:
        // re-arm the speech-without-recognition clocks.
        if !raw.isEmpty {
            transcriptTextSeen = true
            voicedSecondsWithoutText = 0
            observedSecondsWithoutText = 0
        }
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
            if !carriedDraftFreshSpeech,
               VoiceConversationUtteranceIdentity.rerecognizesCarry(carry: prefix, in: display) {
                // The rebuilt stream re-recognized the carried sentence with
                // NO new microphone speech: joining would put the same words
                // twice into one draft. Take the fresher whole accumulation
                // instead and retire the carry (2026-10-27 restart-boundary
                // duplicate-join repair).
                report("resumeCarryRerecognized", "chars=\(prefix.count)")
                resumePrefix = nil
            } else {
                display = VoiceConversationFrameMath.joinCompletedSentences([prefix, display])
            }
        }
        stagedTranscript = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMuted {
            clearEndpointTimer()
            return
        }
        if let r = round {
            // The arbiter runs ONLY inside an open audio candidate (the
            // tentative pause or its bounded confirmation-identity window).
            // With no candidate, staging behaves exactly like the settled
            // pre-repair kernel: nothing is dropped or suppressed on string
            // identity alone — provenance cannot be claimed from text.
            // Confirmation additionally requires text genuinely newer than
            // the candidate's snapshot, so slow real ASR confirms while its
            // identity window is open, and superseded candidates can never
            // be hijacked by late arrivals (2026-10-25 rules).
            if suspectingSpeech || r.bargeCandidatePending {
                let decision = VoiceConversationBargeArbiter.decide(
                    staged: stagedTranscript,
                    openedWith: r.bargeCandidateSnapshot,
                    submitted: lastSubmittedText,
                    playedReference: playedEchoReference(r)
                )
                switch decision {
                case .confirm:
                    report("bargeConfirmed", "chars=\(stagedTranscript.count)")
                    // Close the candidate synchronously: a superseded
                    // candidate never leaves live timers behind.
                    r.bargeCandidateTimer?.cancel()
                    r.bargeCandidateFreshTimer?.cancel()
                    round?.bargeCandidateTimer = nil
                    round?.bargeCandidateFreshTimer = nil
                    round?.bargeCandidatePending = false
                    let token = r.token
                    Task { [weak self] in
                        guard let self else { return }
                        if self.round?.token == token {
                            self.suspectingSpeech = false
                        }
                        await self.finishRound(token: token, reason: .bargeIn, drained: false)
                        guard self.state == .waitingModel || self.state == .answering else { return }
                        self.resumeListeningAfterRound(roundToken: token)
                        // Keep endpointing the utterance the user is still speaking.
                        if !self.isMuted, !self.stagedTranscript.isEmpty {
                            self.scheduleEndpoint(for: self.stagedTranscript)
                        }
                    }
                case .rejectedStaleASR:
                    // Text equal to (or the tail of) THIS round's own
                    // submitted words: ambiguous between a late final of
                    // that utterance and an exact user repeat — the
                    // ambiguous direction is the reported silent
                    // self-interruption. Bounded closure (primary-settled
                    // 2026-10-25): it never auto-cancels AND it is
                    // discarded, so it can never be auto-resent as a fresh
                    // question when the round finishes naturally (the
                    // silent self-reply loop). Genuinely new words are a
                    // different shape and stage/confirm normally; no
                    // cross-round history is kept.
                    report("bargeStaleSuppressed", "chars=\(stagedTranscript.count)")
                    discardStagedText()
                case .rejectedOutputEcho:
                    // A mirror of the speech that actually reached the
                    // speaker is echo, not intent: it can neither cancel
                    // the answer nor later re-ask it as a fresh question,
                    // so the draft is fenced past this accumulation.
                    report("bargeEchoSuppressed", "chars=\(stagedTranscript.count)")
                    discardStagedText()
                case .rejectedInvalid, .rejectedNotFresh:
                    break
                }
            } else if VoiceConversationBargeArbiter.matchesCurrentSubmissionTail(
                stagedTranscript, submitted: lastSubmittedText
            ) {
                // No audio candidate, but the answer is still playing: a late
                // re-accumulation of THIS round's own question must not
                // survive as a draft that the natural endpoint would auto-send
                // (the silent self-reply loop closure). Current round only —
                // no cross-round history is consulted.
                report("staleASRFenced", "chars=\(stagedTranscript.count)")
                discardStagedText()
            } else if VoiceConversationBargeArbiter.isOutputEcho(
                stagedTranscript, playedReference: playedEchoReference(r)
            ) {
                // A mirror of the speech that actually played is echo, never
                // a fresh question: it cannot become a draft mid-answer
                // (short mirrors like a two-character "好的" included).
                report("bargeEchoSuppressed", "chars=\(stagedTranscript.count)")
                discardStagedText()
            }
            return
        }
        if state == .listening, !stagedTranscript.isEmpty {
            armEndpointOrFenceReplay(stagedTranscript, stage: "staging")
        }
    }

    /// Re-arm endpointing for a staged draft, UNLESS that draft is the same
    /// utterance this session already submitted and no real microphone speech
    /// arrived since (a late final, a re-decode or a Simplified↔Traditional
    /// script flip of already-consumed audio). Such a replay is discarded with
    /// the baseline advanced past the backend's accumulation, so it can never
    /// become the draft an armed or re-armed endpoint auto-sends after a round
    /// — the reported duplicate question with two separate answers.
    ///
    /// Deliberate intent never routes through here: `sendNow()` and typed
    /// `submitText(_:)` call `submit` directly (product decision 2026-10-27).
    private func armEndpointOrFenceReplay(_ text: String, stage: String) {
        guard state == .listening, !isMuted, !text.isEmpty else { return }
        if autoSubmitIdentity.blocksAutomaticSubmit(text) {
            report("duplicateUtteranceFenced", "stage=\(stage) chars=\(text.count)")
            discardStagedText()
            return
        }
        scheduleEndpoint(for: text)
    }

    private func scheduleEndpoint(for text: String) {
        clearEndpointTimer()
        guard state == .listening, !isMuted else { return }
        let window = VoiceConversationEndpointPolicy.isProbablyIncomplete(text)
            ? timing.endpointIncomplete
            : timing.endpointSilence
        endpointTimer = clock.schedule(after: window) { [weak self] in
            guard let self, self.state == .listening, !self.isMuted else { return }
            self.endpointTimer = nil
            // JOINT GATE (2026-10-25, premature-submit repair): the armed
            // 0.9/1.6 window is BOTH the transcript-stability window and the
            // required ACTUAL microphone-quiet window. A Whisper-slow frozen
            // partial previously auto-submitted while the mic was measurably
            // still voiced — the reported "submits halfway through while I'm
            // STILL speaking". If this capture stretch has real level
            // evidence but its continuous quiet run has not reached the SAME
            // window, the decision DEFERS event-driven (released from
            // `consume(level)` at the quiet crossing): NEVER force-submit
            // into ongoing speech, NEVER a second shorter quiet rule, NEVER
            // lengthen the settled 0.9/1.6 window, NEVER re-arm a busy poll.
            // Evidence from BEFORE a partial re-arm still counts, and a
            // re-arm with no new samples is not proof of quiet. Sustained
            // voiced-without-recognition stays bounded by the untouched
            // recognition-health escalation; manual send / typed submit
            // bypass as before. A stretch with NO real sample at all
            // (legacy level-less hosts) keeps the original transcript-only
            // latency exactly — valid short turns are never slowed.
            if self.micSamplesSeen, self.micQuietRun < window {
                self.endpointDeferralActive = true
                self.endpointDeferralWindow = window
                self.report("endpointDeferredVoiced",
                            "quietMs=\(Int(self.micQuietRun * 1000)) windowMs=\(Int(window * 1000))")
                return
            }
            self.decideEndpoint()
        }
    }

    /// The endpoint decision itself — unchanged in substance from the
    /// settled policy: hesitation/noise-only residue is discarded with the
    /// baseline advanced (never re-sent, never merged into the next draft),
    /// a valid final submits exactly once — and a valid final that is only a
    /// replay of the utterance this session already submitted (folded form,
    /// no real microphone speech since) is fenced instead of launched.
    /// Reached from an armed timer (the
    /// quiet window is already satisfied, or the stretch has no real level
    /// samples at all) and from the event-driven release of a deferred
    /// window — the joint gate changes WHEN the decision is taken, never
    /// WHAT it does.
    private func decideEndpoint() {
        let final = stagedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceConversationTurnValidity.isValidTurn(final) else {
            report("endpointDiscarded")
            stagedTranscript = ""
            transcriptBaseline = rawTranscript
            resumePrefix = nil
            return
        }
        fenceAutomaticReplayOrLaunch(final, stage: "endpoint")
    }

    /// The AUTO-submit side of the 2026-10-27 duplicate-utterance repair: the
    /// authoritative gate immediately before an automatic launch. Every armed
    /// or event-released endpoint decision passes here, whatever re-armed it,
    /// so a rewrite of the utterance this session already submitted (with no
    /// real microphone speech since) can never mint a second turn. The
    /// discarded text leaves the draft AND the baseline advances past the
    /// backend's current accumulation, so the same words cannot simply
    /// re-stage on the next partial. The allowed path keeps the settled
    /// `endpointFired` diagnostic order unchanged.
    private func fenceAutomaticReplayOrLaunch(_ final: String, stage: String) {
        if autoSubmitIdentity.blocksAutomaticSubmit(final) {
            report("duplicateUtteranceFenced", "stage=\(stage) chars=\(final.count)")
            stagedTranscript = ""
            transcriptBaseline = rawTranscript
            resumePrefix = nil
            return
        }
        report("endpointFired")
        submit(final)
    }

    // MARK: - Turn flow

    private func submit(_ text: String) {
        guard state == .listening else { return }
        clearEndpointTimer()
        // From here on, new backend text belongs to the NEXT utterance.
        transcriptBaseline = rawTranscript
        resumePrefix = nil
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: activeAttempt)
        round = Round(token: token)
        currentRound = token
        lastSubmittedText = text
        // Anchor the replay fence for this session: the SAME recognized
        // utterance arriving again — as a late final, a re-decode or a Han
        // script flip — with no real microphone speech since this submit is
        // old audio, not new intent. Deliberate manual/typed launches anchor
        // here too; they simply never consult it.
        autoSubmitIdentity.noteSubmit(text)
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
        // The sink's frame clock was reset by stopPlayback; a stale baseline
        // from the discarded projection must not leak into the fresh body.
        r.outputDrainBaseline = nil
        r.outputSettleAttempts = 0
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
        // The launch never reached the model, so this exact text was never
        // answered: it is NOT a replay of a consumed utterance. Release the
        // fence for the recovered draft — the explicit retry and the round-end
        // re-arm must still be able to send the user's words. The retry's own
        // submit re-anchors it again (2026-10-27: failure-draft
        // recoverability stays outside the duplicate fence).
        autoSubmitIdentity.reset()
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
        // Drain is now purely an engine-progress question. The watchdog owns
        // the ONLY bounded-visible failure for a dead output; long answers
        // (whose last units arrive here via the lookahead refill) must arm it
        // too, or a stalled output would hang silently forever.
        if !r.pendingUnits {
            recheckPlaybackProgress()
        }
        if !(round?.drainWatchdog != nil), !(round?.finishScheduled ?? true) {
            armDrainWatchdog(r.token)
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
        if r.appPaused || r.outputPausedByBarge {
            // A deliberate pause is not a stall: paused render frames are
            // silence by design. Keep watching without failing the round.
            round = r
            armDrainWatchdog(token)
            return
        }
        if r.totalQueuedFrames <= r.playedFrames, !r.endRoundAudioReceived {
            // GENERATION WAIT, not a playback stall: the round's model is
            // done and the player has consumed all supplied audio. The
            // selected source may be preparing either its first chunk or a
            // later sentence. The standalone read-aloud path bounds
            // this with 90 s / 45 s first/next-chunk source deadlines; the
            // continuous bridge carries the same deadlines. Never convert a
            // synthesis wait into a silent failed round here.
            report("awaitingAudioSupply", "units=\(r.units.count)")
            round = r
            armDrainWatchdog(token)
            return
        }
        // TRUE OUTPUT STALL: audio was queued (or the round's audio input
        // completed) and REAL played receipts never advanced. Never finish
        // this silently and never hang: surface an actionable pause so the
        // user can resume (a fresh capture stack is rebuilt on resume).
        report("drainTimeout", "queued=\(r.totalQueuedFrames) played=\(r.playedFrames)")
        turnErrorMessage = "voice.error.playback"
        round = r
        pauseSession(reason: .interrupted)
    }

    private func consumePlayedFrames(_ frames: Int, taggedEpoch: UInt64?, stack: any VoiceConversationStack) {
        guard var r = round else { return }
        // The sink fences its epoch synchronously BEFORE flushing the player,
        // so a progress event carrying an older epoch was produced by a
        // cancelled round (or was queued across the fence) and must never
        // credit the answer that is playing now. Untagged legacy events are
        // accepted for the current round.
        if let taggedEpoch, stack.playbackEpoch != taggedEpoch {
            report("stalePlayedFramesDropped",
                   "tag=\(taggedEpoch) current=\(stack.playbackEpoch) frames=\(frames)")
            return
        }
        guard frames >= r.playedFrames else { return }
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
        if drainedNow, let stack, let controls = round?.frozenPlaybackControls, !controls.isNeutral,
           stack.outputDrainFrames > 0 {
            // The played-frame receipts prove INPUT consumption only; the
            // shared time-pitch still holds its look-ahead. Require REAL
            // rendered output-frame GROWTH after the last receipt before the
            // round may drain (teardown must not clip the final syllable).
            // Frames — not non-silent samples — because quiet speech and
            // zero crossings are legitimate. While the output is paused the
            // mixer renders silence and the unit cannot advance; resume paths
            // re-enter this check instead of burning the bound.
            if let current = round {
                if current.appPaused || current.outputPausedByBarge {
                    return
                }
                let rendered = stack.outputRenderedFrames
                var waiting = current
                if waiting.outputDrainBaseline == nil { waiting.outputDrainBaseline = rendered }
                let baseline = waiting.outputDrainBaseline ?? rendered
                let required = max(1, stack.outputDrainFrames)
                let grown = rendered - baseline >= required
                if !grown, waiting.outputSettleAttempts < Self.maxOutputSettleAttempts {
                    waiting.outputSettleAttempts += 1
                    round = waiting
                    _ = clock.schedule(after: Self.outputSettleInterval) { [weak self] in
                        self?.recheckPlaybackProgress()
                    }
                    return
                }
                if !grown {
                    // Actionable classification: the render clock never advanced
                    // after all input was consumed (dead output), never a quiet-
                    // speech false positive.
                    report("outputTailUnsettled",
                           "rendered=\(max(0, rendered - baseline)) required=\(required)")
                }
                round = waiting
            }
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
        // A finished/cancelled round's barge candidate is superseded with
        // it: both timers fenced dead, no late expiry can touch the next
        // round's state or emit stray events, and the published tentative
        // state cannot outlive the round it belonged to.
        r.bargeCandidateTimer?.cancel()
        r.bargeCandidateFreshTimer?.cancel()
        suspectingSpeech = false
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
        // plain double-talk) keeps endpointing; noise clears on fire. A draft
        // that is only the SAME utterance re-accumulating (script flip or late
        // final, with no real microphone speech since the submit) is fenced
        // here instead — re-arming it is exactly what turned one spoken
        // question into two persisted questions (2026-10-27).
        armEndpointOrFenceReplay(stagedTranscript, stage: "roundEnd")
    }

    // MARK: - VoiceConversationSpeechOutput (the app TTS bridge feeds this)

    var completedSpokenText: String { round?.completedSpokenCache ?? "" }

    /// Freezes one unit's playback controls. Token/unit-fenced exactly like
    /// `appendAudio`: a stale, ended, completed or app-stopped unit can never
    /// pick up controls from a newer round. The FIRST accepted value is the
    /// round's single configuration — later units of the same answer cannot
    /// retune audio that is already queued, and a settings edit picked up by
    /// a later unit cannot split one answer across two tempos. The next
    /// answer (new round) freezes the changed setting instead.
    func freezeSpeechControls(_ controls: VoicePlaybackControls, for unit: VoiceConversationSpeechUnit) {
        guard var r = round, r.token == unit.token, !r.outputStoppedByApp,
              let index = r.units.firstIndex(where: { $0.unit.id == unit.id }),
              !r.units[index].ended, !r.units[index].completed else { return }
        guard r.frozenPlaybackControls == nil else { return }
        r.frozenPlaybackControls = controls
        round = r
    }

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
        // Predicted frames estimate the queue-bound
        // precheck only. They are never credited: the player reports the REAL
        // converted frame count (resampler priming/history and fractional
        // rates make the ratio wrong by frames per chunk, and crediting the
        // prediction leaves unit offsets unreachable — no unit ever completed
        // and a "drained" round could never fire).
        let predictedFrames = VoiceConversationFrameMath.outputFrames(
            chunkFrames: chunk.frameCount, chunkSampleRate: chunk.sampleRate, outputSampleRate: rate
        )
        guard predictedFrames >= 0 else {
            report("appendRejected", "format")
            return .rejectedInvalidFormat
        }
        let capacity = Int(timing.maxQueuedSeconds * rate)
        let unplayed = max(0, r.totalQueuedFrames - r.playedFrames)
        guard unplayed + predictedFrames <= capacity else {
            report("appendRejected", "capacity")
            return .rejectedOverCapacity
        }
        // The round's frozen controls are delivered to the sink immediately
        // before its first chunk. The sink applies the node write only while
        // its output queue is idle (a fresh round after the previous flush),
        // so queued old-answer audio keeps its own tuning; later units of
        // this round carry the same value and are a no-op.
        stack?.applySpeechControls(r.frozenPlaybackControls ?? .neutral, for: unit.id)
        guard let stack else {
            report("appendRejected", "engine")
            return .rejectedEngine
        }
        switch stack.scheduleChunk(chunk) {
        case .scheduled(let frames):
            // ACTUAL native queued frames, including a legitimate 0 for a
            // converter that consumed the input into its buffer. A 0 append
            // stays consumed: it is never retried.
            r.units[index].expectedFrames += frames
            r.totalQueuedFrames += frames
            round = r
            recheckPlaybackProgress()
            return .accepted
        case .transientCapacity:
            report("appendRejected", "capacity")
            return .rejectedOverCapacity
        case .unavailable:
            report("appendRejected", "engine")
            return .rejectedEngine
        case .failed:
            report("appendRejected", "unusable")
            return .rejectedUnusableAudio
        }
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
        // Paused render frames are silence; require fresh growth after resume.
        round?.outputDrainBaseline = nil
        stack?.pausePlayback()
        speechContinuation.yield(.outputPaused(reason: .appInitiated))
    }

    func resumeOutput() {
        guard let r = round, r.appPaused else { return }
        round?.appPaused = false
        stack?.resumePlayback()
        // A drain-tail check parked while paused re-enters with real frames.
        recheckPlaybackProgress()
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
