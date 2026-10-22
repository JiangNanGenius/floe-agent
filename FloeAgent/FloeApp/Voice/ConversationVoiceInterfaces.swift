// FloeApp — Continuous voice conversation: shared interface definitions.
//
// SPDX-License-Identifier: MPL-2.0
//
// Ownership: this file defines the cross-lane contract for the continuous
// foreground voice session (task chat-voice-tts-20261022). It deliberately
// uses only Foundation types so the coordinator and every fake compile in a
// host unit-test context without AVFoundation, Speech, UIKit or SwiftUI.
//
// The dictation stack (`VoiceInputController`, `SpeechService`, the composer
// microphone) is a SEPARATE product surface; nothing here repurposes or
// changes its behavior. One microphone owner at a time: the app layer stops
// dictation before starting a conversation session.
//
// Guarantees this contract pins down:
// - Turn events are cumulative REPLACEMENTS of visible assistant text only
//   (never reasoning/tool payloads), so subscription races cannot duplicate
//   the same audio twice.
// - Speech receipts describe audio that ACTUALLY played to a sentence end,
//   never what the TTS producer merely synthesized or flagged final.
// - Every async callback carries a `VoiceConversationRoundToken` or session
//   attempt; superseded tokens are fenced and can never resume output.

// No UIKit/SwiftUI guard here ON PURPOSE: unlike the dictation files, this
// contract and the coordinator kernel are Foundation(+Combine)-only so they
// compile and run in host unit-test contexts without any audio framework.

import Foundation

// MARK: - Round identity

/// Identifies one model round launched from the voice session. The session
/// generation fences callbacks that arrive after a newer session started.
struct VoiceConversationRoundToken: Hashable, Sendable {
    let id: UUID
    let sessionGeneration: UInt64
}

// MARK: - Turn driving (coordinator → app/LLM layer)

/// One finalized spoken user turn.
struct VoiceConversationTurnRequest: Sendable {
    let token: VoiceConversationRoundToken
    /// Trimmed, validated utterance text — never empty, never noise-only.
    let text: String
    /// The previous answer the user talked over, when one exists. The app
    /// layer decides whether to feed it back to the model or into history.
    let previousInterruptedAnswer: VoiceConversationInterruptedRound?
}

/// What the app layer reports back about a round.
/// `answerUpdated` carries the cumulative VISIBLE round text (display truth —
/// may include intermediate assistant commentary). SPEECH never follows it
/// directly. `finalAnswerUpdated` carries the cumulative text of the
/// FINAL-ANSWER turn only, decided structurally (no keyword guessing): the
/// driver streams it live while no interaction boundary has sealed the
/// segment, and confirms it at completion from the durable last assistant
/// segment. Tool progress and intermediate commentary are displayed but are
/// NEVER spoken; if the driver later discovers the live segment was actually
/// intermediate (a boundary sealed it), `finalAnswerRetracted` stops and
/// clears the spoken pipeline. Completed carries ONLY the final-answer text,
/// so the whole round is never replayed into speech.
enum VoiceConversationTurnEvent: Sendable, Equatable {
    case answerUpdated(cumulativeText: String)
    case finalAnswerUpdated(cumulativeText: String)
    case finalAnswerRetracted
    case completed(fullText: String)
    case failed(message: String?)
    case cancelled
}

typealias VoiceConversationTurnSender = @MainActor @Sendable (VoiceConversationTurnEvent) -> Void

/// The seam the voice coordinator uses to run model turns. The production
/// implementation is `VoiceConversationRunDriver` (real ConversationCenter
/// launches); unit tests substitute a recorder.
@MainActor
protocol VoiceConversationTurnDriving: AnyObject {
    /// Launches exactly one owned round. Every event the implementation
    /// later produces must go through `send` for `request.token`; events for
    /// superseded tokens must not reach the coordinator at all where avoidable.
    func startTurn(_ request: VoiceConversationTurnRequest, send: @escaping VoiceConversationTurnSender)
    /// Cancels the exact owned round. This call is the barrier: after it
    /// returns, the implementation must not deliver further events for the
    /// token, and a new launch may begin.
    func cancelTurn(_ token: VoiceConversationRoundToken) async
    /// Persists playback evidence for a round. Default: ignore.
    func reportSpeech(_ receipt: VoiceConversationSpeechReceipt) async
}

extension VoiceConversationTurnDriving {
    func reportSpeech(_ receipt: VoiceConversationSpeechReceipt) async {}
}

// MARK: - Playback evidence

enum VoiceConversationPlaybackStatus: String, Sendable, Equatable {
    /// All queued speech for the round played to the end.
    case completed
    /// The round was interrupted (barge-in, manual stop, system pause, end).
    case interrupted
}

/// Receipt of what the user actually HEARD. `spokenText` contains only text
/// whose audio finished playing; a sentence interrupted mid-way does not
/// count. Bounded and mapped to `VoicePlaybackReceipt` by the run driver.
struct VoiceConversationSpeechReceipt: Sendable, Equatable {
    let token: VoiceConversationRoundToken
    let status: VoiceConversationPlaybackStatus
    let spokenText: String
    /// Known answer text at the time of the receipt (full visible text for
    /// completed rounds, last cumulative for interrupted ones).
    let answerText: String
}

/// Retained playback interruption metadata for the primary's history/context
/// bridge. Cleared only when consumed by the next turn or a new session.
struct VoiceConversationInterruptedRound: Sendable, Equatable {
    let roundToken: VoiceConversationRoundToken
    let answerText: String
    let spokenText: String
    /// Fraction (0...1) of the round's queued audio that actually played.
    let speechFraction: Double
    /// Whether playback was tentatively paused by barge-in detection when
    /// the round was cancelled.
    let pausedForBargeIn: Bool
}

/// What the session hands to the app layer when it ends (close/navigation).
struct VoiceConversationSessionSummary: Sendable {
    let pendingTranscript: String
    let interruptedRound: VoiceConversationInterruptedRound?
    let wasMuted: Bool
}

// MARK: - Audio chunk format adapter (TTS bridge contract)

/// One PCM chunk routed into the shared engine's player node, so synthesized
/// speech (system `AVSpeechSynthesizer.write(PCMBuffer:to:)` output or the
/// TTS worker's s16le mono 24 kHz chunks) passes through the SAME AEC output
/// reference as capture. Float32 linear PCM, interleaved; the live sink
/// resamples to the engine output format.
struct VoiceConversationAudioChunk: Sendable, Equatable {
    /// Interleaved Float32 samples in -1...1.
    let samples: [Float]
    let channelCount: Int
    let sampleRate: Double

    var frameCount: Int { samples.count / max(1, channelCount) }

    init(samples: [Float], channelCount: Int, sampleRate: Double) {
        self.samples = samples
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    /// Bridge for the TTS worker contract: s16 little-endian mono PCM
    /// (24 kHz published format) converted to the sink's Float32 form.
    init(int16Samples: [Int16], channelCount: Int = 1, sampleRate: Double) {
        var floats = [Float]()
        floats.reserveCapacity(int16Samples.count)
        floats.append(contentsOf: int16Samples.map { Float($0) / 32_768 })
        self.init(samples: floats, channelCount: channelCount, sampleRate: sampleRate)
    }

    /// Structural validation every consumer applies before enqueuing.
    var isValid: Bool {
        guard channelCount == 1 || channelCount == 2 else { return false }
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return false }
        guard !samples.isEmpty, samples.count % channelCount == 0 else { return false }
        guard frameCount <= 240_000 else { return false }
        return samples.allSatisfy(\.isFinite)
    }
}

// MARK: - Speech output sink (app TTS bridge → coordinator)

/// One sentence the bridge must synthesize for the round, in order. The
/// coordinator owns sentence splitting; the bridge never re-splits text.
struct VoiceConversationSpeechUnit: Hashable, Sendable, Identifiable {
    let id: UUID
    let token: VoiceConversationRoundToken
    let index: Int
    let text: String
}

enum VoiceConversationSpeechAppendResult: Sendable, Equatable {
    case accepted
    /// Stale round/unit (interrupted, superseded session, or unit already
    /// ended): the chunk is dropped, never replayed.
    case rejectedStale
    case rejectedInvalidFormat
    /// Queue bound reached (≈45 s at the engine output rate): throttle until
    /// `unitProgress` / `unitCompleted` events arrive.
    case rejectedOverCapacity
}

enum VoiceConversationStopReason: String, Sendable, Equatable {
    case bargeIn
    case manualInterrupt
    case systemPause
    case sessionEnded
    case roundFailed
    /// The app layer called `stopNow()` / paused this round's audio itself.
    case appInitiated
}

enum VoiceConversationResumeReason: String, Sendable, Equatable {
    /// A tentative barge-in pause was cleared because no valid utterance
    /// followed: playback continues at the SAME position.
    case falseStart
    /// App-initiated resume (the counterpart of `appInitiated` pause).
    case manual
}

enum VoiceConversationSpeechEvent: Sendable, Equatable {
    case roundStarted(VoiceConversationRoundToken)
    /// Synthesize and append this unit; append with `endUnit` when done.
    case unitQueued(VoiceConversationSpeechUnit)
    /// The round's text is final: exactly `unitCount` units exist. Call
    /// `endRoundAudio` once the last unit's audio has been appended.
    case roundTextCompleted(token: VoiceConversationRoundToken, unitCount: Int)
    case unitProgress(unit: VoiceConversationSpeechUnit, fraction: Double)
    case unitCompleted(VoiceConversationSpeechUnit)
    case outputPaused(reason: VoiceConversationStopReason)
    case outputResumed(reason: VoiceConversationResumeReason)
    case outputStopped(token: VoiceConversationRoundToken, reason: VoiceConversationStopReason)
    /// All queued audio for the round played to the end (true drain — the
    /// producer's own final flag is NOT evidence of playback).
    case outputDrained(token: VoiceConversationRoundToken)
}

/// The sink the app TTS bridge feeds. `VoiceConversationCoordinator`
/// implements it; the bridge holds only this protocol.
@MainActor
protocol VoiceConversationSpeechOutput: AnyObject {
    func appendAudio(_ chunk: VoiceConversationAudioChunk, to unit: VoiceConversationSpeechUnit)
        -> VoiceConversationSpeechAppendResult
    func endUnit(_ unit: VoiceConversationSpeechUnit)
    func endRoundAudio(_ token: VoiceConversationRoundToken)
    /// Sink-level playback controls (distinct from the SESSION's async
    /// `VoiceConversationCoordinator.resume()`). Position-preserving:
    /// pause/resume keep the exact audio position; `stopNow` clears the
    /// queue and fences the round's output.
    func pauseOutput()
    func resumeOutput()
    func stopNow()
    /// Single-consumer event channel for the bridge.
    var speechEvents: AsyncStream<VoiceConversationSpeechEvent> { get }
    /// Text whose audio played to the sentence end, for the current round.
    var completedSpokenText: String { get }
}

// MARK: - Session state machine vocabulary

enum VoiceConversationState: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case listening
    /// Endpoint reached; the turn is being handed to the driving seam.
    case submitting
    /// Round owns an active generation; no visible text yet.
    case waitingModel
    /// Visible text arriving, being spoken, or tentatively paused for barge-in.
    case answering
    /// Paused by background/lock/interruption/route loss. Manual resume only.
    case paused
    case ending
    case failed(VoiceConversationFailure)

    /// A capture/session exists or is being built. The app layer maps this
    /// to its recording gates (PiP ducking, dictation exclusion).
    var hasSession: Bool {
        switch self {
        case .preparing, .listening, .submitting, .waitingModel, .answering, .ending:
            return true
        case .idle, .requestingPermission, .paused, .failed:
            return false
        }
    }
}

enum VoiceConversationFailure: String, Equatable, Sendable, Error {
    case microphonePermissionDenied
    case speechPermissionDenied
    case localeUnsupported
    case modelNotReady
    case noAudioInput
    case recognizerFailed
    case interrupted
    case routeLost
}

/// Coarse events the live audio layer reports; the coordinator maps them to
/// pause/failure policy. No AVFAudio types cross this boundary.
enum VoiceConversationSystemEvent: Sendable, Equatable {
    case interruptionBegan
    case routeLost
    case mediaServicesReset
    case engineConfigurationChanged
}

enum VoiceConversationSceneEvent: Sendable, Equatable {
    case background
    case inactive
}

/// One metered capture observation: smoothed display amplitude 0...1, the
/// noise-gate decision, and the wall-clock span of the sample. Duration
/// keeps barge-in persistence independent of buffer size.
struct VoiceConversationLevel: Sendable, Equatable {
    var level: Float
    var isSpeech: Bool
    var duration: Double
}

enum VoiceConversationEngineEvent: Sendable, Equatable {
    /// Cumulative frames rendered by the player sink since this stack began
    /// playback (reset by stop/clear, frozen by pause). The ONLY basis for
    /// spoken progress and receipts.
    case playedFrames(Int)
}

// MARK: - Session stack seam (one object owns mic + ASR + player)

/// A single session's audio stack. The production implementation is
/// `VoiceConversationLiveStack` (one shared AVAudioEngine: voice-processed
/// mic tap + player-node output through the same AEC reference). Fakes
/// script everything without AVFoundation.
///
/// NOT `@MainActor`: the engine owns render-thread tap and completion
/// callbacks (exactly like the proven dictation `AudioEngineCapturer`); the
/// implementation is `@unchecked Sendable` with internal locks. The
/// coordinator — its only caller — invokes the methods from the main actor.
protocol VoiceConversationStack: AnyObject, Sendable {
    /// Engine output rate used to convert chunk frames for accounting.
    var outputSampleRate: Double { get }
    /// Real microphone-side levels AFTER voice processing (AEC): what the
    /// remote end would "hear" — this is the input that drives the waveform
    /// and the barge-in persistence gate.
    var levels: AsyncStream<VoiceConversationLevel> { get }
    /// REAL played-output amplitude: metered on the mixer bus that feeds the
    /// speaker, i.e. the PCM that actually reached the AEC output reference.
    /// The orb may animate from this, never from a timer and never from the
    /// TTS producer's claim that it finished synthesizing.
    var playedLevels: AsyncStream<VoiceConversationLevel> { get }
    var transcripts: AsyncStream<String> { get }
    var engineEvents: AsyncStream<VoiceConversationEngineEvent> { get }
    var systemEvents: AsyncStream<VoiceConversationSystemEvent> { get }

    /// Audio session + engine activation. Typed failures only; a simulator
    /// with no host microphone must throw `.noAudioInput` BEFORE touching
    /// the input node (RemoteIO can abort the process below Swift errors).
    func activate() async throws(VoiceConversationFailure)
    /// Begin/stop physical microphone collection (mute uses these). Idempotent.
    func startCapture() throws(VoiceConversationFailure)
    func stopCapture()
    /// Create the ASR session (reuses the installed/system transcription
    /// backends). May download locale assets, hence async + typed failure.
    func beginTranscription() async throws(VoiceConversationFailure)
    /// Signal end of audio and drain the final transcript with a bounded wait.
    func finishTranscription() async
    func transcriptionFailureSnapshot() -> VoiceConversationFailure?

    /// Enqueue one PCM chunk on the shared player output. False = the
    /// engine's own bound refused it (the coordinator restores accounting).
    @discardableResult
    func scheduleChunk(_ chunk: VoiceConversationAudioChunk) -> Bool
    /// No more chunks will be scheduled until the next round (drain truth).
    func endQueuedAudio()
    /// Position-preserving: the played-frame counter keeps its value.
    func pausePlayback()
    /// Continue at the SAME position.
    func resumePlayback()
    /// Clear the queue AND reset the played-frame counter/epoch: every round
    /// starts its progress accounting from zero, and completions of dropped
    /// buffers can never credit the new round.
    func stopPlayback()

    /// Full teardown. A superseded stack instance must NEVER deactivate an
    /// audio session a newer owner already claimed (generation-guarded).
    func deactivate()
}

/// Microphone + speech authorization seam (same prompts dictation uses).
protocol VoiceConversationAuthorizationProviding: Sendable {
    func requestMicrophoneAccess() async -> Bool
    func requestSpeechRecognitionAccess() async -> Bool
}

// MARK: - Scheduling seam (deterministic endpointing/barge timers)

@MainActor
protocol VoiceConversationScheduled: AnyObject {
    func cancel()
}

/// One-shot timer seam. Production sleeps; tests advance a virtual clock so
/// 900 ms / 1.6 s / barge windows are exercised without wall-clock waits.
@MainActor
protocol VoiceConversationScheduling: AnyObject {
    func schedule(after seconds: Double, action: @escaping @MainActor () -> Void) -> any VoiceConversationScheduled
}

// MARK: - Diagnostics (redacted; never transcript bodies or audio)

protocol VoiceConversationDiagnostics: Sendable {
    func voiceConversation(_ code: String, _ detail: String)
}

// MARK: - Cumulative segment aggregation

/// Rebuilds a monotonic cumulative answer string from provider segments that
/// legitimately RESET at interaction boundaries. `ConversationRunService
/// .snapshot().streamedText` is the CURRENT live segment only: it empties
/// when a tool round starts, when reasoning resumes, or when a steer is
/// consumed (the sealed text is durable in the store by then). Forwarding
/// the raw value would make the voice cumulative stream shrink; the
/// coordinator (correctly) rejects non-prefix updates, and web/tool-extended
/// answers would silently stop streaming. The driver therefore seals the
/// live segment at boundary events and publishes `sealed + live` joined.
/// Pure and Foundation-only so tests can pin the reconciliation.
struct VoiceConversationSegmentAggregator: Sendable {
    private var sealed: [String] = []
    private(set) var live = ""

    /// The cumulative value to publish (monotonic by construction, except
    /// when the store-truth `completed` event replaces everything).
    var cumulative: String {
        let parts = sealed.filter { !$0.isEmpty } + [live]
        return parts.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The live segment currently in `streamedText` form.
    var currentLive: String { live }
    /// How many segments have been sealed so far. Zero means the live
    /// segment is still the round's ONLY text so far — structurally the
    /// final-answer candidate (chat mode streams speech immediately).
    /// The first seal reveals the projected segment was intermediate
    /// commentary: speech must be retracted until the durable final is known.
    var sealedCount: Int { sealed.count }

    /// Called with each authoritative snapshot value. A snapshot that still
    /// extends the live segment replaces it; a shrink is ignored (never
    /// duplicate); anything else is a boundary reset that seals the previous
    /// live segment first, so text is neither replayed nor dropped.
    mutating func applySnapshot(_ streamedText: String) {
        if streamedText.hasPrefix(live) {
            live = streamedText
            return
        }
        if live.hasPrefix(streamedText) {
            // A snapshot that shrank inside the live segment: keep the
            // fuller local value. A reset publishes the NEW segment
            // directly, which is never a prefix of the old live text.
            return
        }
        seal()
        live = streamedText
    }

    /// A durable-boundary event (tool requested / steer consumed / reasoning
    /// restarted after visible text) seals the live segment.
    mutating func boundary() {
        seal()
        live = ""
    }

    /// After the boundary seal the live segment legitimately restarts.
    mutating func applySnapshotAfterBoundary(_ streamedText: String) {
        live = streamedText
    }

    mutating func seal() {
        let trimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sealed.append(trimmed) }
        live = ""
    }

    /// Store-truth final replacement (the `completed` path).
    mutating func finalize(_ fullText: String) {
        sealed = []
        live = fullText
    }
}
