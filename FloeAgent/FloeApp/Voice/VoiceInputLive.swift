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
        #if canImport(WhisperKit)
        if VoiceRecognitionPreferences.method == .enhanced { return true }
        if VoiceRecognitionPreferences.method == .automatic, await WhisperModelStore.shared.isInstalled() { return true }
        #endif
        return await Self.requestAppleAccess()
    }
    static func requestAppleAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Transcription (SpeechAnalyzer / SpeechTranscriber)

/// Stable Speech framework backend used by Auto mode. It has shipped for
/// years and provides partial results directly from the same ordered audio
/// buffers as the modern analyzer backend.
final class StreamingSpeechRecognizerTranscriber: SpeechTranscribing, @unchecked Sendable {
    private final class FirstResultFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var received = false

        func consume() -> Bool {
            lock.withLock {
                defer { received = true }
                return !received
            }
        }
    }

    /// Why the recognition task ENDED WITH AN ERROR, so consumers can tell a
    /// healthy stream end (`.isFinal` after recognized speech, or a
    /// no-speech auto-end) from a dead recognizer. Without this the
    /// continuous session restarts invisibly forever and drops tap audio on
    /// every rebuild window. Shared file-wide: both Speech-framework
    /// transcribers report through it.
    fileprivate final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: VoiceInputFailure?

        var value: VoiceInputFailure? {
            lock.withLock { stored }
        }
        func store(_ failure: VoiceInputFailure) {
            lock.withLock {
                guard stored == nil else { return }
                stored = failure
            }
        }
    }

    /// True only for BENIGN stream endings, which are legitimate session
    /// renewals, never failures (see the authoritative table in
    /// `SFSpeechRecognitionTask.h`, iOS 27 SDK):
    /// - `kAFAssistantErrorDomain` 1110 — "Failed to recognize any speech":
    ///   the recognizer gave up on a stretch that contained no speech.
    /// - `kLSRErrorDomain` 301 — "Request was canceled": our own retirement
    ///   /teardown cancel surfacing through the callback.
    /// Everything else (1101/1107 speech-process connection loss, 203
    /// recognition failure, 1100 overlapping instance, 1700 unauthorized,
    /// 102/201/300 asset/Siri/initialization problems…) means the recognizer
    /// path is NOT working and surfaces as `.recognizerFailed`, so the
    /// session fails visibly with a retry affordance instead of silently
    /// restarting forever on dropped audio (airplane mode included).
    static func isBenignStreamEnd(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 { return true }
        if nsError.domain == "kLSRErrorDomain", nsError.code == 301 { return true }
        return false
    }

    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let continuation: AsyncStream<String>.Continuation
    private let diagnostics: (any VoiceInputDiagnostics)?
    private let failureBox = FailureBox()
    let transcripts: AsyncStream<String>
    var failure: VoiceInputFailure? { failureBox.value }

    init(locale: Locale = .current, diagnostics: (any VoiceInputDiagnostics)? = nil) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceSessionError.failure(.localeUnsupported)
        }
        self.diagnostics = diagnostics
        var streamContinuation: AsyncStream<String>.Continuation!
        transcripts = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Auto mode prioritizes reliability. Requiring the local asset here
        // makes an otherwise available recognizer silently produce no
        // result while the asset is absent or being evicted.
        request.requiresOnDeviceRecognition = false
        let firstResult = FirstResultFlag()
        recognitionTask = recognizer.recognitionTask(with: request) { [continuation, diagnostics, firstResult, failureBox] result, error in
            if let result {
                diagnostics?.voiceTranscriptReceived(first: firstResult.consume())
                continuation.yield(result.bestTranscription.formattedString)
                if result.isFinal { continuation.finish() }
            }
            if let error {
                let benign = StreamingSpeechRecognizerTranscriber.isBenignStreamEnd(error)
                let nsError = error as NSError
                FloeLogger(category: .app).warning(
                    "speechRecognizerEnded domain=voice benign=\(benign ? 1 : 0) code=\(nsError.code)"
                )
                if !benign { failureBox.store(.recognizerFailed) }
                continuation.finish()
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard VoiceBufferValidator.isUsable(buffer) else { return }
        diagnostics?.voiceAudioBufferAccepted(frameCount: buffer.frameLength)
        request.append(buffer)
    }

    func finishAudio() async {
        request.endAudio()
    }

    deinit {
        recognitionTask?.cancel()
        continuation.finish()
    }
}

/// One SpeechAnalyzer-backed transcription session.
final class SpeechAnalyzerTranscriber: SpeechTranscribing, @unchecked Sendable {

    private let analyzer: SpeechAnalyzer
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let transcriptContinuation: AsyncStream<String>.Continuation
    /// Converts hardware microphone buffers into a format accepted by the
    /// analyzer. Passing the input-node format straight into `AnalyzerInput`
    /// traps inside Speech on affected iOS 27 builds instead of throwing.
    private let convertBuffer: (AVAudioPCMBuffer) throws -> [AnalyzerInput]
    private let flushConverter: () throws -> [AnalyzerInput]
    private let diagnostics: (any VoiceInputDiagnostics)?
    private let failureBox = StreamingSpeechRecognizerTranscriber.FailureBox()

    let transcripts: AsyncStream<String>
    var failure: VoiceInputFailure? { failureBox.value }

    /// Builds the analyzer for the given locale. Throws
    /// `VoiceSessionError` (never traps) when the locale is unsupported or
    /// the on-device assets are missing and cannot be used right now.
    init(
        locale: Locale = .current,
        diagnostics: (any VoiceInputDiagnostics)? = nil
    ) async throws {
        self.diagnostics = diagnostics
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

        // Keep the source buildable with the Xcode 26 SDK used by release
        // automation. AnalyzerInputConverter is an iOS 27 SDK symbol, so a
        // runtime #available check cannot make it visible to an older
        // compiler. This AVAudioConverter path is safe on iOS 26 and 27.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ), let converter = LegacyAnalyzerInputConverter(outputFormat: analyzerFormat) else {
            throw VoiceSessionError.failure(.noAudioInput)
        }
        convertBuffer = { buffer in
            guard VoiceBufferValidator.isUsable(buffer) else { return [] }
            return converter.convert(buffer)
        }
        flushConverter = { [] }

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
        Task { [transcripts = self.transcriptContinuation, diagnostics, failureBox] in
            do {
                var isFirst = true
                for try await result in transcriber.results {
                    diagnostics?.voiceTranscriptReceived(first: isFirst)
                    isFirst = false
                    transcripts.yield(String(result.text.characters))
                }
                transcripts.finish()
            } catch {
                FloeLogger(category: .app).warning(
                    "speechResultFailed domain=voice error=\(String(describing: type(of: error)))"
                )
                // A dead analyzer stream is an actionable recognizer failure,
                // never a silently invisible restart.
                failureBox.store(.recognizerFailed)
                transcripts.finish()
            }
        }
    }

    func startAnalysis() async throws {
        // Last-buffer time is unknown until capture ends; the analyzer
        // finishes when the input sequence does.
        try await analyzer.start(inputSequence: inputSequence)
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let copied = Self.copyBuffer(buffer) else {
            FloeLogger(category: .app).warning("speechBufferCopyFailed domain=voice")
            return
        }
        diagnostics?.voiceAudioBufferAccepted(frameCount: copied.frameLength)
        do {
            let converted = try convertBuffer(copied)
            diagnostics?.voiceAnalyzerInputProduced(count: converted.count)
            for input in converted { inputContinuation.yield(input) }
        } catch {
            FloeLogger(category: .app).warning(
                "speechConvertFailed domain=voice error=\(String(describing: type(of: error)))"
            )
        }
    }

    func finishAudio() async {
        do {
            let flushed = try flushConverter()
            diagnostics?.voiceConverterFlushed(count: flushed.count)
            for input in flushed { inputContinuation.yield(input) }
        } catch {
            FloeLogger(category: .app).warning(
                "speechFlushFailed domain=voice error=\(String(describing: type(of: error)))"
            )
        }
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            FloeLogger(category: .app).warning(
                "speechFinalizeFailed domain=voice error=\(String(describing: type(of: error)))"
            )
        }
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard VoiceBufferValidator.isUsable(source),
              let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
              ) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let byteCount = min(
                Int(sourceBuffer.mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            guard byteCount == 0 || (
                sourceBuffer.mData != nil && destinationBuffers[index].mData != nil
            ) else { return nil }
            if byteCount > 0 {
                memcpy(destinationBuffers[index].mData, sourceBuffer.mData, byteCount)
                destinationBuffers[index].mDataByteSize = UInt32(byteCount)
            }
        }
        return copy
    }

}

/// iOS 26 compatibility converter. iOS 27 provides
/// `AnalyzerInputConverter`; on iOS 26 we perform the equivalent format
/// conversion with AVFAudio and only construct `AnalyzerInput` from a fresh,
/// non-empty buffer. AVAudioConverter is stateful and not thread-safe, hence
/// the narrow lock even though AVAudioEngine normally serializes tap calls.
private final class LegacyAnalyzerInputConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var converterByInputDescription: [String: AVAudioConverter] = [:]

    init?(outputFormat: AVAudioFormat) {
        guard outputFormat.sampleRate.isFinite,
              outputFormat.sampleRate > 0,
              outputFormat.channelCount > 0 else { return nil }
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) -> [AnalyzerInput] {
        lock.withLock {
            let key = input.format.description
            let converter: AVAudioConverter
            if let existing = converterByInputDescription[key] {
                converter = existing
            } else {
                guard let created = AVAudioConverter(from: input.format, to: outputFormat) else {
                    return []
                }
                converterByInputDescription[key] = created
                converter = created
            }

            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let estimatedFrames = max(
                1,
                Int(ceil(Double(input.frameLength) * ratio)) + 32
            )
            guard estimatedFrames <= Int(UInt32.max),
                  let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(estimatedFrames)
                  ) else { return [] }

            var suppliedInput = false
            var conversionError: NSError?
            _ = converter.convert(to: output, error: &conversionError) { _, status in
                guard !suppliedInput else {
                    status.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                status.pointee = .haveData
                return input
            }
            guard conversionError == nil, output.frameLength > 0 else { return [] }
            return [AnalyzerInput(buffer: output)]
        }
    }
}

// MARK: - Audio capture (sole AVAudioEngine owner)

/// Captures microphone audio into a transcriber. All engine state lives
/// here; teardown is idempotent and defensive — no force unwraps, no
/// preconditions on runtime audio state.
final class AudioEngineCapturer: VoiceAudioCapturing, @unchecked Sendable {

    private var receivedFirstBuffer = false
    private var readinessStopped = false
    private var readinessWaiter: CheckedContinuation<Void, Error>?
    private var readinessTimeout: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var sessionActivated = false
    private let lock = NSLock()
    private let meterLock = NSLock()
    private var activityMeter = VoiceActivityMeter()

    /// Real capture levels for this session. Buffered newest-only: the UI
    /// only ever needs the latest measured amplitude.
    let levels: AsyncStream<VoiceAudioLevel>
    private let levelContinuation: AsyncStream<VoiceAudioLevel>.Continuation

    init() {
        var continuation: AsyncStream<VoiceAudioLevel>.Continuation!
        levels = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        levelContinuation = continuation
    }

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

        // CoreAudio's simulator RemoteIO service can abort the entire
        // process from `AVAudioEngine.inputNode` when no host microphone is
        // routed. That failure is below Swift/Objective-C exception
        // handling, so never touch the input node in the simulator. Device
        // capture continues through the exact production path below.
        #if targetEnvironment(simulator)
        stop()
        throw VoiceSessionError.failure(.noAudioInput)
        #else
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The legacy crash: installing a tap with an invalid format (no
        // microphone input, a torn-down route) throws an Objective-C
        // exception. Validate first and fail friendly instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw VoiceSessionError.failure(.noAudioInput)
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            // Some route transitions deliver an empty terminal buffer. Speech
            // treats that as a programmer error and traps, so drop it here.
            guard buffer.frameLength > 0 else { return }
            self?.markFirstBuffer()
            self?.publishLevel(of: buffer)
            transcriber.feed(buffer, at: time)
        }
        lock.withLock { tapInstalled = true }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw VoiceSessionError.failure(.noAudioInput)
        }
        #endif
    }

    func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                lock.lock()
                if readinessStopped || Task.isCancelled {
                    lock.unlock(); waiter.resume(throwing: CancellationError()); return
                }
                if receivedFirstBuffer { lock.unlock(); waiter.resume(); return }
                readinessWaiter = waiter
                readinessTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.finishReadiness(.failure(VoiceSessionError.failure(.noAudioInput)))
                }
                lock.unlock()
            }
        } onCancel: { [weak self] in self?.cancelReadiness() }
    }

    private func markFirstBuffer() {
        lock.withLock { receivedFirstBuffer = true }
        finishReadiness(.success(()))
    }
    private func cancelReadiness() {
        lock.withLock { readinessStopped = true }
        finishReadiness(.failure(CancellationError()))
    }
    private func finishReadiness(_ result: Result<Void, Error>) {
        lock.lock()
        let waiter = readinessWaiter
        readinessWaiter = nil
        let timeout = readinessTimeout
        readinessTimeout = nil
        lock.unlock()
        timeout?.cancel()
        waiter?.resume(with: result)
    }

    /// Measures the real RMS of one captured buffer, advances the noise-gated
    /// envelope and forwards the display level. Runs on the audio thread;
    /// the meter is lock-protected and the stream keeps only the newest value.
    private func publishLevel(of buffer: AVAudioPCMBuffer) {
        let rms = VoiceBufferMeter.rms(of: buffer)
        let duration = Float(buffer.frameLength) / Float(max(buffer.format.sampleRate, 1))
        let output = meterLock.withLock {
            activityMeter.process(rms: rms, duration: duration)
        }
        levelContinuation.yield(output)
    }

    /// Idempotent teardown: stops the engine, removes the tap exactly
    /// once, releases the audio session. Safe from any thread context.
    func stop() {
        cancelReadiness()
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
        levelContinuation.finish()
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
                let stored = UserDefaults.standard.string(
                    forKey: VoiceRecognitionLanguage.defaultsKey
                )
                let language = stored.flatMap(VoiceRecognitionLanguage.init(rawValue:))
                    ?? .automatic
                return try await Self.makePreferredTranscriber(language: language, diagnostics: diagnostics)
            },
            makeCapturer: { AudioEngineCapturer() },
            diagnostics: diagnostics
        )
    }
    static func makePreferredTranscriber(language: VoiceRecognitionLanguage, diagnostics: (any VoiceInputDiagnostics)? = nil) async throws -> any SpeechTranscribing {
        let method = VoiceRecognitionPreferences.method
        #if canImport(WhisperKit)
        if method != .system {
            do { return try await WhisperStreamingTranscriber.make(language: language, diagnostics: diagnostics,
                allowSystemFallback: method == .automatic) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if method == .enhanced { throw VoiceSessionError.failure(.modelNotReady) }
            }
        }
        #else
        if method == .enhanced { throw VoiceSessionError.failure(.modelNotReady) }
        #endif
        guard await SystemSpeechAuthorizationProvider.requestAppleAccess() else {
            throw VoiceSessionError.failure(.speechPermissionDenied)
        }
        return try StreamingSpeechRecognizerTranscriber(locale: language.locale, diagnostics: diagnostics)
    }

}

/// Isolated factory so the controller's @MainActor closure can await the
/// transcriber's nonisolated async initializer.
private func makeSpeechAnalyzerTranscriber(
    diagnostics: (any VoiceInputDiagnostics)?
) async throws -> SpeechAnalyzerTranscriber {
    try await SpeechAnalyzerTranscriber(diagnostics: diagnostics)
}

/// Forwards voice lifecycle diagnostics into FloeLogger with the exact
/// structured event names. Messages carry state and reason codes only.
struct FloeVoiceDiagnostics: VoiceInputDiagnostics {
    private let logger = FloeLogger(category: .app)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var acceptedBuffers = 0
    nonisolated(unsafe) private static var analyzerInputs = 0

    func voicePermissionRequested() { logger.info("permissionRequested domain=voice") }
    func voicePermissionDenied(kind: String) { logger.info("permissionDenied domain=voice kind=\(kind)") }
    func voiceSessionPreparing() { logger.info("sessionPreparing domain=voice") }
    func voiceListeningStarted() { logger.info("listeningStarted domain=voice") }
    func voiceInterrupted(reason: String) { logger.info("interruption domain=voice reason=\(reason)") }
    func voiceRouteChanged() { logger.info("routeChanged domain=voice") }
    func voiceListeningStopped() { logger.info("listeningStopped domain=voice") }
    func voiceFailed(reason: VoiceInputFailure) { logger.warning("speechFailed reason=\(reason.rawValue)") }
    func voiceAudioBufferAccepted(frameCount: AVAudioFrameCount) {
        let count = Self.lock.withLock {
            Self.acceptedBuffers += 1
            return Self.acceptedBuffers
        }
        if count == 1 || count.isMultiple(of: 100) {
            logger.info("audioAccepted domain=voice buffers=\(count) frames=\(frameCount)")
        }
    }
    func voiceAnalyzerInputProduced(count: Int) {
        guard count > 0 else { return }
        let total = Self.lock.withLock {
            Self.analyzerInputs += count
            return Self.analyzerInputs
        }
        if total == count || total.isMultiple(of: 100) {
            logger.info("analyzerInputProduced domain=voice total=\(total)")
        }
    }
    func voiceConverterFlushed(count: Int) {
        logger.info("converterFlushed domain=voice inputs=\(count)")
    }
    func voiceTranscriptReceived(first: Bool) {
        if first { logger.info("firstTranscript domain=voice") }
    }
}
#endif
