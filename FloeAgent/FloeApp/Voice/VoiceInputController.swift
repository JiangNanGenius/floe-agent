// FloeApp — Voice input controller (state machine, no audio internals).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns the voice lifecycle for one composer. It coordinates the
// authorization provider, the transcriber factory and the audio capturer
// — all behind protocols — so the state machine is fully unit-testable
// without a microphone, and the composer never touches AVAudioEngine.
//
// Guarantees:
// - `start()` / `stop()` are idempotent; rapid toggles create at most one
//   session (`startToken` invalidates superseded preparations).
// - Any failure mid-preparation tears the whole session down before the
//   failure surfaces; the microphone button always returns to a usable
//   state and the draft stays editable.
// - Partial transcripts replace the staged value in arrival order, so
//   text already dictated is never duplicated.
// - Scene-phase and disappearance hooks stop the session safely.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class VoiceInputController: ObservableObject {
    /// Host-owned output handoff, shared by all dictation entry points.
    var prepareForCapture: (@MainActor () async -> Void)?

    @Published private(set) var state: VoiceInputState = .idle
    /// The latest transcript of the current session (partial or final).
    /// The composer merges it into the draft after its own prefix.
    @Published private(set) var transcript = ""
    /// Smoothed, real capture amplitude in 0...1. Stays 0 until speech
    /// crosses the noise gate and returns to 0 during silence — the waveform
    /// is driven by measured audio, never a timer.
    @Published private(set) var audioLevel: Float = 0
    /// Raw noise-gate decision for the most recent captured buffer.
    @Published private(set) var isSpeechDetected = false

    private let authorization: any SpeechAuthorizationProviding
    private let makeTranscriber: @MainActor () async throws -> any SpeechTranscribing
    private let makeCapturer: @MainActor () -> any VoiceAudioCapturing
    private let diagnostics: (any VoiceInputDiagnostics)?

    private var capturer: (any VoiceAudioCapturing)?
    private var transcriber: (any SpeechTranscribing)?
    private var transcriptTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationWatchdog: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private let preparationTimeout: Duration
    /// Monotonic token: a superseded start must never activate a session.
    private var startToken: UInt64 = 0
    /// True after the user explicitly stops; suppresses failure overwrite
    /// while the transcriber drains its final result.
    private var stoppingIntentionally = false

    var isListening: Bool { state == .listening }

    init(
        authorization: any SpeechAuthorizationProviding,
        makeTranscriber: @escaping @MainActor () async throws -> any SpeechTranscribing,
        makeCapturer: @escaping @MainActor () -> any VoiceAudioCapturing,
        diagnostics: (any VoiceInputDiagnostics)? = nil,
        preparationTimeout: Duration = .seconds(20)
    ) {
        self.authorization = authorization
        self.makeTranscriber = makeTranscriber
        self.makeCapturer = makeCapturer
        self.diagnostics = diagnostics
        self.preparationTimeout = preparationTimeout
    }

    // MARK: - Public lifecycle (idempotent)

    /// Reserves and launches a voice session synchronously from a UI tap.
    /// Reserving before creating the task closes the small race where the
    /// composer could disappear before an unstructured `Task { start() }`
    /// had begun, allowing microphone capture to start off-screen.
    func requestStart() {
        guard let token = reserveStart() else { return }
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareSession(token: token)
            if self.isCurrent(token) {
                self.preparationTask = nil
            }
        }
    }

    /// Starts a session. Calling start while a session exists (including
    /// mid-permission or mid-preparation) is a no-op — one session max.
    func start() async {
        guard let token = reserveStart() else { return }
        await prepareSession(token: token)
    }

    private func reserveStart() -> UInt64? {
        guard !state.hasSession, state != .requestingPermission else { return nil }
        startToken &+= 1
        let token = startToken
        stoppingIntentionally = false
        transcript = ""
        state = .requestingPermission
        diagnostics?.voicePermissionRequested()
        return token
    }

    private func prepareSession(token: UInt64) async {
        if let prepareForCapture { await prepareForCapture() }
        guard canPrepare(token) else { return }
        // Microphone first, then speech recognition: the failure copy
        // names the exact permission the user must grant.
        guard await authorization.requestMicrophoneAccess() else {
            guard canPrepare(token) else { return }
            diagnostics?.voicePermissionDenied(kind: "microphone")
            state = .failed(reason: .microphonePermissionDenied)
            return
        }
        guard await authorization.requestSpeechRecognitionAccess() else {
            guard canPrepare(token) else { return }
            diagnostics?.voicePermissionDenied(kind: "speech")
            state = .failed(reason: .speechPermissionDenied)
            return
        }
        guard canPrepare(token) else { return }

        state = .preparing
        diagnostics?.voiceSessionPreparing()
        preparationWatchdog?.cancel()
        preparationWatchdog = Task { [weak self, preparationTimeout] in
            try? await Task.sleep(for: preparationTimeout)
            guard !Task.isCancelled, let self, self.isCurrent(token), self.state == .preparing else { return }
            // A model load or capture setup can stall. End this attempt so the
            // composer leaves its gray preparation state and can be retried.
            self.startToken &+= 1
            self.preparationTask?.cancel()
            self.preparationTask = nil
            self.preparationWatchdog = nil
            self.teardown()
            self.diagnostics?.voiceFailed(reason: .recognizerFailed)
            self.state = .failed(reason: .recognizerFailed)
        }

        // A failed predecessor must finish releasing its recognizer before a
        // fresh attempt acquires the microphone. Retry belongs to this tap.
        for attempt in 0..<2 {
            if let cleanupTask { await cleanupTask.value }
            guard canPrepare(token) else { return }
            let transcriber: any SpeechTranscribing
            do { transcriber = try await makeTranscriber() }
            catch {
                let failure = (error as? VoiceSessionError)?.failure ?? .recognizerFailed
                guard canPrepare(token) else { return }
                if attempt == 0 && Self.canRecoverStartup(failure) { continue }
                fail(with: failure, token: token)
                return
            }
            guard canPrepare(token) else {
                await transcriber.finishAudio()
                return
            }
            let capturer = makeCapturer()
            self.transcriber = transcriber
            self.capturer = capturer
            do {
                try await capturer.start(into: transcriber)
                try Task.checkCancellation()
                try await capturer.waitUntilReady()
            } catch {
                guard canPrepare(token) else {
                    capturer.stop()
                    await transcriber.finishAudio()
                    return
                }
                let failure = (error as? VoiceSessionError)?.failure ?? .recognizerFailed
                teardown()
                if let cleanupTask { await cleanupTask.value }
                guard canPrepare(token) else { return }
                if attempt == 0 && Self.canRecoverStartup(failure) { continue }
                fail(with: failure, token: token)
                return
            }
            guard canPrepare(token) else {
                capturer.stop()
                await transcriber.finishAudio()
                return
            }
            preparationWatchdog?.cancel()
            preparationWatchdog = nil
            state = .listening
            diagnostics?.voiceListeningStarted()
            observeLevels(of: capturer, token: token)
            observeTranscripts(of: transcriber, token: token)
            return
        }
    }

    private func canPrepare(_ token: UInt64) -> Bool {
        isCurrent(token) && !Task.isCancelled && (state == .requestingPermission || state == .preparing)
    }

    private static func canRecoverStartup(_ failure: VoiceInputFailure) -> Bool {
        failure == .noAudioInput || failure == .recognizerFailed
    }

    /// Stops the session. Safe to call at any time, from any state.
    func stop() {
        guard state.hasSession || state == .requestingPermission else {
            // Reset a leftover failure/unavailable state on explicit stop
            // so the microphone button returns to a clean affordance.
            if state != .idle { state = .idle }
            return
        }
        let wasListening = state == .listening
        stoppingIntentionally = true
        preparationTask?.cancel()
        preparationTask = nil
        preparationWatchdog?.cancel()
        preparationWatchdog = nil
        levelTask?.cancel()
        levelTask = nil
        audioLevel = 0
        isSpeechDetected = false
        state = .stopping
        let token = startToken
        let activeCapturer = capturer
        capturer = nil
        let activeTranscriber = transcriber
        let observation = transcriptTask
        activeCapturer?.stop()
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            if let activeTranscriber { await activeTranscriber.finishAudio() }
            if let observation {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await observation.value }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(900))
                        if !Task.isCancelled { observation.cancel() }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
            guard let self, self.isCurrent(token) else { return }
            self.transcriptTask?.cancel()
            self.transcriptTask = nil
            self.transcriber = nil
            self.startToken &+= 1
            if let failure = activeTranscriber?.failure {
                self.state = .failed(reason: failure)
                self.diagnostics?.voiceFailed(reason: failure)
            } else { self.state = .idle }
            self.stopTask = nil
            if wasListening { self.diagnostics?.voiceListeningStopped() }
        }
    }

    func stopAndWait() async {
        stop()
        if let stopTask { await stopTask.value }
        if let cleanupTask { await cleanupTask.value }
    }

    /// External interruption: scene backgrounded, page disappeared, audio
    /// interruption or route change. The session is stopped safely; the
    /// state machine reports the reason for diagnostics only.
    func handleInterruption(reason: VoiceInputFailure, routeChange: Bool = false) {
        guard state.hasSession || state == .requestingPermission else { return }
        if routeChange {
            diagnostics?.voiceRouteChanged()
        } else {
            diagnostics?.voiceInterrupted(reason: reason.rawValue)
        }
        stop()
    }

    /// Filters system audio-session notifications before they reach the
    /// state machine. Category changes and route reconfiguration caused by
    /// our own `setCategory`/`setActive` calls must not stop a session that
    /// just started.
    func handleAudioRouteChange(_ notification: Notification) {
        guard let rawValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue),
              Self.shouldInterruptForRouteChange(reason) else { return }
        handleInterruption(reason: .interrupted, routeChange: true)
    }

    /// Only interruption-began tears capture down. The matching ended event
    /// is informational and must not trigger another stop/log cycle.
    func handleAudioInterruption(_ notification: Notification) {
        guard let rawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
        handleInterruption(reason: .interrupted)
    }

    static func shouldInterruptForRouteChange(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            true
        default:
            false
        }
    }

    // MARK: - Transcript pipeline

    /// Forwards real capture-level observations from the audio seam onto the
    /// published UI state. The loop ends when the capturer's stream finishes
    /// (session teardown) or the token is superseded; `stop()`/`teardown()`
    /// reset the published values to the static baseline.
    private func observeLevels(of capturer: any VoiceAudioCapturing, token: UInt64) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            for await level in capturer.levels {
                guard let self, !Task.isCancelled else { return }
                guard self.isCurrent(token) else { return }
                self.audioLevel = level.level
                self.isSpeechDetected = level.isSpeech
            }
        }
    }

    private func observeTranscripts(of transcriber: any SpeechTranscribing, token: UInt64) {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            for await text in transcriber.transcripts {
                guard let self, !Task.isCancelled else { return }
                guard self.isCurrent(token) else { return }
                // Partial results replace the staged transcript wholesale;
                // ordering is guaranteed by the AsyncSequence, so dictated
                // text is never duplicated in the draft.
                self.transcript = text
            }
            // The transcript stream finished (recognizer ended on its own).
            guard let self, self.isCurrent(token) else { return }
            if self.state == .listening, !self.stoppingIntentionally {
                // Recognition service ended the session — stop cleanly and
                // keep whatever transcript arrived.
                self.stop()
            }
        }
    }

    // MARK: - Internals

    private func isCurrent(_ token: UInt64) -> Bool {
        token == startToken
    }

    private func fail(with failure: VoiceInputFailure, token: UInt64) {
        guard isCurrent(token) else { return }
        preparationWatchdog?.cancel()
        preparationWatchdog = nil
        teardown()
        diagnostics?.voiceFailed(reason: failure)
        state = failure == .localeUnsupported || failure == .modelNotReady
            ? .unavailable
            : .failed(reason: failure)
    }

    /// Tears down capture and observation. Idempotent: whatever exists is
    /// released exactly once; nothing traps on double-stop.
    private func teardown() {
        stopTask?.cancel()
        stopTask = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        levelTask?.cancel()
        levelTask = nil
        audioLevel = 0
        isSpeechDetected = false
        capturer?.stop()
        capturer = nil
        let activeTranscriber = transcriber
        transcriber = nil
        let previousCleanup = cleanupTask
        cleanupTask = Task {
            if let previousCleanup { await previousCleanup.value }
            if let activeTranscriber { await activeTranscriber.finishAudio() }
        }
    }
}

/// Errors thrown by the live transcriber/capturer factories, mapped to
/// user-comprehensible failure categories at the boundary.
enum VoiceSessionError: Error, Equatable {
    case failure(VoiceInputFailure)

    var failure: VoiceInputFailure {
        switch self {
        case .failure(let value): value
        }
    }
}
#endif
