// FloeApp — Live voice input implementations (SpeechAnalyzer, iOS 26+).
//
// SPDX-License-Identifier: MPL-2.0
//
// The production implementations behind the voice seams:
// - `SystemSpeechAuthorizationProvider` wraps the system permission
//   prompts (microphone + speech recognition).
// - `SpeechAnalyzerTranscriber` drives the modern Speech framework:
//   a SpeechAnalyzer fed by one SpeechTranscriber module, preferring
//   on-device recognition when the locale's assets support it.
// - `AudioEngineCapturer` is the only owner of AVAudioEngine. It validates
//   the input format (sampleRate > 0, channelCount > 0) BEFORE installing
//   a tap — an invalid format surfaces as a friendly error instead of the
//   crash the legacy controller hit. Stop is idempotent; one tap max.
//
// No audio is persisted anywhere. The analyzer runs in memory and is
// released with the session.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Speech
import AVFoundation
import FloeCore

// MARK: - Authorization

/// System authorization prompts behind the testable seam.
struct SystemSpeechAuthorizationProvider: SpeechAuthorizationProviding {
    func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Transcription (SpeechAnalyzer / SpeechTranscriber)

/// One SpeechAnalyzer-backed transcription session.
final class SpeechAnalyzerTranscriber: SpeechTranscribing, @unchecked Sendable {

    private let analyzer: SpeechAnalyzer
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let transcriptContinuation: AsyncStream<String>.Continuation

    let transcripts: AsyncStream<String>

    /// Builds the analyzer for the given locale. Throws
    /// `VoiceSessionError` (never traps) when the locale is unsupported or
    /// the on-device assets are missing and cannot be used right now.
    init(locale: Locale = .current) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceSessionError.failure(.localeUnsupported)
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        // Prefer on-device recognition: install the assets if needed, and
        // require them — dictation must not silently route audio to a
        // server the user never agreed to.
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(supported) {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
        }
        guard await SpeechTranscriber.installedLocales.contains(supported) else {
            throw VoiceSessionError.failure(.modelNotReady)
        }

        var continuation: AsyncStream<AnalyzerInput>.Continuation!
        inputSequence = AsyncStream { continuation = $0 }
        inputContinuation = continuation

        var transcriptStreamContinuation: AsyncStream<String>.Continuation!
        transcripts = AsyncStream { transcriptStreamContinuation = $0 }
        transcriptContinuation = transcriptStreamContinuation

        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .whileInUse
            )
        )

        // Forward ordered results into the transcript stream. The analyzer
        // delivers results in audio order, so the composer never sees a
        // transcript older than the one it already has.
        Task { [transcripts = self.transcriptContinuation] in
            do {
                for try await result in transcriber.results {
                    transcripts.yield(String(result.text.characters))
                }
                transcripts.finish()
            } catch {
                transcripts.finish()
            }
        }
    }

    func startAnalysis() async throws {
        // Last-buffer time is unknown until capture ends; the analyzer
        // finishes when the input sequence does.
        try await analyzer.start(inputSequence: inputSequence)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finishAudio() async {
        inputContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}

// MARK: - Audio capture (sole AVAudioEngine owner)

/// Captures microphone audio into a transcriber. All engine state lives
/// here; teardown is idempotent and defensive — no force unwraps, no
/// preconditions on runtime audio state.
final class AudioEngineCapturer: VoiceAudioCapturing, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var sessionActivated = false
    private let lock = NSLock()

    func start(into transcriber: any SpeechTranscribing) async throws {
        let alreadyInstalled = lock.withLock { tapInstalled }
        // One session max: a second start while capturing is a no-op,
        // never a second tap.
        guard !alreadyInstalled else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            lock.withLock { sessionActivated = true }
        } catch {
            throw VoiceSessionError.failure(.noAudioInput)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The legacy crash: installing a tap with an invalid format (no
        // microphone input, a torn-down route) throws an Objective-C
        // exception. Validate first and fail friendly instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw VoiceSessionError.failure(.noAudioInput)
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            transcriber.feed(buffer)
        }
        lock.withLock { tapInstalled = true }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw VoiceSessionError.failure(.noAudioInput)
        }
    }

    /// Idempotent teardown: stops the engine, removes the tap exactly
    /// once, releases the audio session. Safe from any thread context.
    func stop() {
        lock.lock()
        let hadTap = tapInstalled
        tapInstalled = false
        let hadSession = sessionActivated
        sessionActivated = false
        lock.unlock()

        if engine.isRunning { engine.stop() }
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        if hadSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Factory used by the composer

extension VoiceInputController {
    /// The production controller: system permissions, SpeechAnalyzer
    /// transcription, single-tap audio capture, structured diagnostics
    /// forwarded into the app log (no audio, no transcript bodies).
    static func live(diagnostics: (any VoiceInputDiagnostics)? = FloeVoiceDiagnostics()) -> VoiceInputController {
        VoiceInputController(
            authorization: SystemSpeechAuthorizationProvider(),
            makeTranscriber: {
                let transcriber = try await makeSpeechAnalyzerTranscriber()
                try await transcriber.startAnalysis()
                return transcriber
            },
            makeCapturer: { AudioEngineCapturer() },
            diagnostics: diagnostics
        )
    }
}

/// Isolated factory so the controller's @MainActor closure can await the
/// transcriber's nonisolated async initializer.
private func makeSpeechAnalyzerTranscriber() async throws -> SpeechAnalyzerTranscriber {
    try await SpeechAnalyzerTranscriber()
}

/// Forwards voice lifecycle diagnostics into FloeLogger with the exact
/// structured event names. Messages carry state and reason codes only.
struct FloeVoiceDiagnostics: VoiceInputDiagnostics {
    private let logger = FloeLogger(category: .app)

    func voicePermissionRequested() { logger.info("permissionRequested domain=voice") }
    func voicePermissionDenied(kind: String) { logger.info("permissionDenied domain=voice kind=\(kind)") }
    func voiceSessionPreparing() { logger.info("sessionPreparing domain=voice") }
    func voiceListeningStarted() { logger.info("listeningStarted domain=voice") }
    func voiceInterrupted(reason: String) { logger.info("interruption domain=voice reason=\(reason)") }
    func voiceRouteChanged() { logger.info("routeChanged domain=voice") }
    func voiceListeningStopped() { logger.info("listeningStopped domain=voice") }
    func voiceFailed(reason: VoiceInputFailure) { logger.warning("speechFailed reason=\(reason.rawValue)") }
}
#endif
