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

enum VoiceRecognitionLanguage: String, CaseIterable, Sendable {
    case automatic
    case simplifiedChinese
    case traditionalChinese
    case english

    static let defaultsKey = "org.floeagent.voice.recognitionLanguage"

    var locale: Locale {
        switch self {
        case .automatic: .current
        case .simplifiedChinese: Locale(identifier: "zh-CN")
        case .traditionalChinese: Locale(identifier: "zh-TW")
        case .english: Locale(identifier: "en-US")
        }
    }
}

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
    func voiceAudioBufferAccepted(frameCount: AVAudioFrameCount)
    func voiceAnalyzerInputProduced(count: Int)
    func voiceConverterFlushed(count: Int)
    func voiceTranscriptReceived(first: Bool)
}

extension VoiceInputDiagnostics {
    func voiceAudioBufferAccepted(frameCount: AVAudioFrameCount) {}
    func voiceAnalyzerInputProduced(count: Int) {}
    func voiceConverterFlushed(count: Int) {}
    func voiceTranscriptReceived(first: Bool) {}
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
    var failure: VoiceInputFailure? { get }
    /// Streams one captured buffer into the analyzer.
    /// This is deliberately synchronous: AVAudioEngine may reuse its tap
    /// buffer after the callback returns, and spawning one Task per buffer
    /// can reorder or corrupt the audio stream.
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?)
    /// Signals end of audio and lets the transcriber finish.
    func finishAudio() async
}

extension SpeechTranscribing {
    var failure: VoiceInputFailure? { nil }
}

/// One real capture-level observation from the microphone seam.
///
/// `level` is the smoothed display amplitude in 0...1; `isSpeech` is the
/// raw noise-gate decision for that sample. A seam with no metering (tests,
/// non-audio fallbacks) reports the silent value.
struct VoiceAudioLevel: Sendable, Equatable {
    var level: Float
    var isSpeech: Bool

    static let silent = VoiceAudioLevel(level: 0, isSpeech: false)
}

/// Pure audio-activity analysis: measured RMS → gated, smoothed display
/// amplitude. The waveform must never animate on a timer: silence decays to
/// exactly zero so the bars stay static until real speech crosses the gate,
/// and while the user speaks the level follows the measured amplitude with a
/// fast attack and a slower release.
struct VoiceActivityMeter: Sendable, Equatable {
    /// RMS below this is noise/silence, not speech.
    static let gate: Float = 0.012
    /// RMS mapped to full scale; conversational speech sits well below 1.
    static let reference: Float = 0.22
    static let attackSeconds: Float = 0.06
    static let releaseSeconds: Float = 0.28
    /// Levels below this snap to exactly zero so idle bars are static.
    static let silenceFloor: Float = 0.02

    private(set) var level: Float = 0

    /// Feeds one measured RMS sample and returns the smoothed display value.
    /// `duration` is the wall-clock span of the sample (frames / sample rate),
    /// keeping the envelope independent of the capture buffer size.
    mutating func process(rms: Float, duration: Float) -> VoiceAudioLevel {
        let clamped = max(0, min(1, rms))
        let isSpeech = clamped >= Self.gate
        let target: Float
        if isSpeech {
            let normalized = (clamped - Self.gate) / (Self.reference - Self.gate)
            target = min(1, max(0, normalized).squareRoot())
        } else {
            target = 0
        }
        let dt = max(0, min(duration, 0.5))
        let timeConstant = max(target >= level ? Self.attackSeconds : Self.releaseSeconds, 0.001)
        let coefficient = 1 - exp(-dt / timeConstant)
        level += (target - level) * coefficient
        if level < Self.silenceFloor, target == 0 { level = 0 }
        return VoiceAudioLevel(level: level, isSpeech: isSpeech)
    }

    mutating func reset() { level = 0 }
}

/// Bounded, allocation-free RMS measurement over an AVAudioPCMBuffer.
/// Never throws or traps: unusable buffers report silence. Interleaved
/// layouts expose one AudioBuffer holding `frames × channels` samples;
/// deinterleaved layouts expose one buffer per channel.
enum VoiceBufferMeter {
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        let isInterleaved = buffer.format.isInterleaved
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let liveBuffers = min(isInterleaved ? 1 : channelCount, audioBuffers.count)
        guard liveBuffers > 0 else { return 0 }
        let samplesPerBuffer = isInterleaved ? frames * channelCount : frames

        if let channels = buffer.floatChannelData {
            var sum: Float = 0
            var total = 0
            for channel in 0..<liveBuffers {
                let samples = channels[channel]
                let count = min(samplesPerBuffer, Int(audioBuffers[channel].mDataByteSize) / MemoryLayout<Float>.stride)
                for index in 0..<count {
                    let sample = samples[index]
                    guard sample.isFinite else { return 0 }
                    sum += sample * sample
                }
                total += count
            }
            return total > 0 ? (sum / Float(total)).squareRoot() : 0
        }
        if let channels = buffer.int16ChannelData {
            var sum: Float = 0
            var total = 0
            for channel in 0..<liveBuffers {
                let samples = channels[channel]
                let count = min(samplesPerBuffer, Int(audioBuffers[channel].mDataByteSize) / MemoryLayout<Int16>.stride)
                for index in 0..<count {
                    let sample = Float(samples[index]) / 32_768
                    sum += sample * sample
                }
                total += count
            }
            return total > 0 ? (sum / Float(total)).squareRoot() : 0
        }
        return 0
    }
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
    /// Real capture-level observations for the duration of this capturer's
    /// session. The production tap yields one value per captured buffer.
    var levels: AsyncStream<VoiceAudioLevel> { get }
}

extension VoiceAudioCapturing {
    /// Seams without metering report an immediately-finished stream; the
    /// waveform then stays at its static baseline (never a timer).
    var levels: AsyncStream<VoiceAudioLevel> {
        AsyncStream { $0.finish() }
    }
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
