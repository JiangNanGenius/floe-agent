// FloeApp — Voice input: authorization, transcription and session seams.
//
// SPDX-License-Identifier: MPL-2.0
//
// The composer owns no audio machinery. These protocols define the seams
// the VoiceInputController drives; unit tests substitute fakes so no test
// ever touches a real microphone or the Speech framework.
//
// Lifecycle guarantees (enforced by VoiceInputController):
// - start and stop are idempotent.
// - At most one audio-capture/transcription session exists at any time.
// - Rapid microphone toggles never stack sessions.
// - A failed start tears the whole session down before surfacing an error.
// - No audio is persisted; the transcript is only staged into the draft
//   and is sent to a model solely by the user's explicit send action.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Speech
import AVFoundation

/// The composer-facing voice state machine.
enum VoiceInputState: Equatable, Sendable {
    /// No session; the microphone is ready.
    case idle
    /// Waiting on microphone/speech authorization.
    case requestingPermission
    /// Permissions granted; building the analyzer session.
    case preparing
    /// Actively capturing and transcribing.
    case listening
    /// Tearing the session down after the user stopped.
    case stopping
    /// Voice input cannot run on this device/locale right now.
    case unavailable
    /// A session error occurred; the microphone button stays usable.
    case failed(reason: VoiceInputFailure)

    /// True when a session exists or is being built — start must be a no-op.
    var hasSession: Bool {
        switch self {
        case .preparing, .listening, .stopping:
            return true
        case .idle, .requestingPermission, .unavailable, .failed:
            return false
        }
    }
}

/// User-comprehensible failure categories (never raw framework errors).
enum VoiceInputFailure: String, Equatable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case localeUnsupported
    case modelNotReady
    case noAudioInput
    case recognizerFailed
    case interrupted
}

/// Structured, redacted voice diagnostics. The app layer forwards these
/// into FloeLogger; tests capture them. No audio, no transcript body,
/// no secrets ever flow through here.
protocol VoiceInputDiagnostics: Sendable {
    func voicePermissionRequested()
    func voicePermissionDenied(kind: String)
    func voiceSessionPreparing()
    func voiceListeningStarted()
    func voiceInterrupted(reason: String)
    func voiceRouteChanged()
    func voiceListeningStopped()
    func voiceFailed(reason: VoiceInputFailure)
}

/// Microphone + speech authorization seam.
protocol SpeechAuthorizationProviding: Sendable {
    func requestMicrophoneAccess() async -> Bool
    func requestSpeechRecognitionAccess() async -> Bool
}

/// One transcription session. Buffers are pushed by the audio capture
/// side; results arrive as an ordered AsyncSequence of transcripts.
protocol SpeechTranscribing: Sendable {
    /// Ordered partial/final transcripts. Finishes when audio ends.
    var transcripts: AsyncStream<String> { get }
    /// Streams one captured buffer into the analyzer.
    /// This is deliberately synchronous: AVAudioEngine may reuse its tap
    /// buffer after the callback returns, and spawning one Task per buffer
    /// can reorder or corrupt the audio stream.
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?)
    /// Signals end of audio and lets the transcriber finish.
    func finishAudio() async
}

/// Audio capture seam (the only place AVAudioEngine may live).
protocol VoiceAudioCapturing: AnyObject, Sendable {
    /// Validates the input format, installs at most one tap, starts the
    /// engine and forwards buffers into `transcriber`.
    /// Throws a `VoiceInputFailure`-mappable error — never traps on an
    /// invalid input format.
    func start(into transcriber: any SpeechTranscribing) async throws
    /// Idempotent teardown: stops the engine, removes any tap, releases
    /// the audio session.
    func stop()
}

/// Pure validation kept outside Speech framework initializers because
/// `AnalyzerInput(buffer:)` traps on malformed or empty buffers rather than
/// reporting a Swift error.
enum VoiceBufferValidator {
    static func isUsable(_ buffer: AVAudioPCMBuffer) -> Bool {
        buffer.frameLength > 0
            && buffer.format.sampleRate.isFinite
            && buffer.format.sampleRate > 0
            && buffer.format.channelCount > 0
    }
}
#endif
