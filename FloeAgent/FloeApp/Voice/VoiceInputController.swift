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

    @Published private(set) var state: VoiceInputState = .idle
    /// The latest transcript of the current session (partial or final).
    /// The composer merges it into the draft after its own prefix.
    @Published private(set) var transcript = ""

    private let authorization: any SpeechAuthorizationProviding
    private let makeTranscriber: @MainActor () async throws -> any SpeechTranscribing
    private let makeCapturer: @MainActor () -> any VoiceAudioCapturing
    private let diagnostics: (any VoiceInputDiagnostics)?

    private var capturer: (any VoiceAudioCapturing)?
    private var transcriptTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
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
        diagnostics: (any VoiceInputDiagnostics)? = nil
    ) {
        self.authorization = authorization
        self.makeTranscriber = makeTranscriber
        self.makeCapturer = makeCapturer
        self.diagnostics = diagnostics
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
        // Microphone first, then speech recognition: the failure copy
        // names the exact permission the user must grant.
        guard await authorization.requestMicrophoneAccess() else {
            guard isCurrent(token) else { return }
            diagnostics?.voicePermissionDenied(kind: "microphone")
            state = .failed(reason: .microphonePermissionDenied)
            return
        }
        guard await authorization.requestSpeechRecognitionAccess() else {
            guard isCurrent(token) else { return }
            diagnostics?.voicePermissionDenied(kind: "speech")
            state = .failed(reason: .speechPermissionDenied)
            return
        }
        guard isCurrent(token) else { return }

        state = .preparing
        diagnostics?.voiceSessionPreparing()

        let transcriber: any SpeechTranscribing
        do {
            transcriber = try await makeTranscriber()
        } catch let error as VoiceSessionError {
            fail(with: error.failure, token: token)
            return
        } catch {
            fail(with: .recognizerFailed, token: token)
            return
        }

        let capturer = makeCapturer()
        self.capturer = capturer
        do {
            try await capturer.start(into: transcriber)
        } catch let error as VoiceSessionError {
            teardown()
            fail(with: error.failure, token: token)
            return
        } catch {
            teardown()
            fail(with: .recognizerFailed, token: token)
            return
        }
        guard isCurrent(token) else {
            // A stop landed while we were preparing; honor it.
            teardown()
            return
        }

        state = .listening
        diagnostics?.voiceListeningStarted()
        observeTranscripts(of: transcriber, token: token)
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
        startToken &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        state = .stopping
        teardown()
        state = .idle
        if wasListening {
            diagnostics?.voiceListeningStopped()
        }
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
        teardown()
        diagnostics?.voiceFailed(reason: failure)
        state = failure == .localeUnsupported || failure == .modelNotReady
            ? .unavailable
            : .failed(reason: failure)
    }

    /// Tears down capture and observation. Idempotent: whatever exists is
    /// released exactly once; nothing traps on double-stop.
    private func teardown() {
        transcriptTask?.cancel()
        transcriptTask = nil
        capturer?.stop()
        capturer = nil
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
