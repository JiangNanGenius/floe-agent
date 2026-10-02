// FloeAppTests — VoiceInputController state machine: idempotent start/stop,
// single-session guarantee, permission/format/failure safety, ordered
// transcript merge. All hardware seams are faked — no real microphone.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import Testing
@testable import FloeApp

@Suite("FloeApp.VoiceInputController")
struct VoiceInputControllerTests {

    // MARK: - Fakes

    private final class FakeAuthorization: SpeechAuthorizationProviding, @unchecked Sendable {
        var microphoneGranted = true
        var speechGranted = true
        private(set) var microphoneRequests = 0
        private(set) var speechRequests = 0

        func requestMicrophoneAccess() async -> Bool {
            microphoneRequests += 1
            return microphoneGranted
        }

        func requestSpeechRecognitionAccess() async -> Bool {
            speechRequests += 1
            return speechGranted
        }
    }

    private final class FakeTranscriber: SpeechTranscribing, @unchecked Sendable {
        private let continuation: AsyncStream<String>.Continuation
        let transcripts: AsyncStream<String>
        private(set) var finishCount = 0
        var finalTextOnFinish: String?

        init() {
            var c: AsyncStream<String>.Continuation!
            transcripts = AsyncStream { c = $0 }
            continuation = c
        }

        func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {}

        func finishAudio() async {
            finishCount += 1
            if let finalTextOnFinish { continuation.yield(finalTextOnFinish) }
            continuation.finish()
        }

        func emit(_ text: String) { continuation.yield(text) }
        func end() { continuation.finish() }
    }

    private final class FakeCapturer: VoiceAudioCapturing, @unchecked Sendable {
        enum Behavior { case ok, invalidFormat, startThrows }
        var behavior: Behavior = .ok
        private(set) var startCount = 0
        private(set) var stopCount = 0

        private let levelContinuation: AsyncStream<VoiceAudioLevel>.Continuation
        let levels: AsyncStream<VoiceAudioLevel>

        init() {
            var continuation: AsyncStream<VoiceAudioLevel>.Continuation!
            levels = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
            levelContinuation = continuation
        }

        func start(into transcriber: any SpeechTranscribing) async throws {
            startCount += 1
            switch behavior {
            case .ok:
                return
            case .invalidFormat:
                throw VoiceSessionError.failure(.noAudioInput)
            case .startThrows:
                throw VoiceSessionError.failure(.recognizerFailed)
            }
        }

        func stop() { stopCount += 1 }

        func emitLevel(_ level: VoiceAudioLevel) { levelContinuation.yield(level) }
        func finishLevels() { levelContinuation.finish() }
    }

    private final class FakeDiagnostics: VoiceInputDiagnostics, @unchecked Sendable {
        private(set) var events: [String] = []
        func voicePermissionRequested() { events.append("permissionRequested") }
        func voicePermissionDenied(kind: String) { events.append("permissionDenied.\(kind)") }
        func voiceSessionPreparing() { events.append("sessionPreparing") }
        func voiceListeningStarted() { events.append("listeningStarted") }
        func voiceInterrupted(reason: String) { events.append("interruption.\(reason)") }
        func voiceRouteChanged() { events.append("routeChanged") }
        func voiceListeningStopped() { events.append("listeningStopped") }
        func voiceFailed(reason: VoiceInputFailure) { events.append("speechFailed.\(reason.rawValue)") }
    }

    @MainActor
    private struct Harness {
        let authorization: FakeAuthorization
        let transcriber: FakeTranscriber
        let capturer: FakeCapturer
        let diagnostics: FakeDiagnostics
        let controller: VoiceInputController

        init(transcriberError: Error? = nil) {
            let authorization = FakeAuthorization()
            let transcriber = FakeTranscriber()
            let capturer = FakeCapturer()
            let diagnostics = FakeDiagnostics()
            self.authorization = authorization
            self.transcriber = transcriber
            self.capturer = capturer
            self.diagnostics = diagnostics
            self.controller = VoiceInputController(
                authorization: authorization,
                makeTranscriber: {
                    if let transcriberError { throw transcriberError }
                    return transcriber
                },
                makeCapturer: { capturer },
                diagnostics: diagnostics
            )
        }
    }

    // MARK: - Tests

    @MainActor
    private func waitForIdle(_ controller: VoiceInputController) async {
        for _ in 0..<100 where controller.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("start and stop are idempotent")
    @MainActor
    func startStopIdempotent() async {
        let harness = Harness()
        await harness.controller.start()
        #expect(harness.controller.state == .listening)
        harness.controller.stop()
        await waitForIdle(harness.controller)
        #expect(harness.controller.state == .idle)
        harness.controller.stop()
        harness.controller.stop()
        #expect(harness.controller.state == .idle)
        #expect(harness.capturer.stopCount >= 1)
    }

    @Test("Rapid toggles create at most one capture session")
    @MainActor
    func rapidTogglesSingleSession() async {
        let harness = Harness()
        var starts: [Task<Void, Never>] = []
        for _ in 0..<8 {
            starts.append(Task { await harness.controller.start() })
        }
        for start in starts {
            await start.value
        }
        #expect(harness.controller.state == .listening)
        #expect(harness.capturer.startCount == 1)
        harness.controller.stop()
    }

    @Test("Microphone permission denial fails friendly and stays operable")
    @MainActor
    func microphoneDenied() async {
        let harness = Harness()
        harness.authorization.microphoneGranted = false
        await harness.controller.start()
        #expect(harness.controller.state == .failed(reason: .microphonePermissionDenied))
        #expect(harness.diagnostics.events.contains("permissionDenied.microphone"))
        #expect(harness.capturer.startCount == 0)
        // The button recovers: a later grant can start a session.
        harness.authorization.microphoneGranted = true
        await harness.controller.start()
        #expect(harness.controller.state == .listening)
    }

    @Test("Speech permission denial fails friendly without touching audio")
    @MainActor
    func speechDenied() async {
        let harness = Harness()
        harness.authorization.speechGranted = false
        await harness.controller.start()
        #expect(harness.controller.state == .failed(reason: .speechPermissionDenied))
        #expect(harness.capturer.startCount == 0)
    }

    @Test("An unusable input format surfaces an error instead of crashing")
    @MainActor
    func invalidInputFormat() async {
        let harness = Harness()
        harness.capturer.behavior = .invalidFormat
        await harness.controller.start()
        #expect(harness.controller.state == .failed(reason: .noAudioInput))
        // The failed session was fully torn down.
        #expect(harness.capturer.stopCount >= 1)
        #expect(harness.diagnostics.events.contains("speechFailed.noAudioInput"))
    }

    @Test("A transcriber failure tears the session down before failing")
    @MainActor
    func recognizerFailure() async {
        let harness = Harness(transcriberError: VoiceSessionError.failure(.recognizerFailed))
        await harness.controller.start()
        #expect(harness.controller.state == .failed(reason: .recognizerFailed))
    }

    @Test("An unsupported locale reports unavailable, not a crash")
    @MainActor
    func unsupportedLocale() async {
        let harness = Harness(transcriberError: VoiceSessionError.failure(.localeUnsupported))
        await harness.controller.start()
        #expect(harness.controller.state == .unavailable)
    }

    @Test("Disappearance/background interruption stops the session safely")
    @MainActor
    func interruptionStopsSession() async {
        let harness = Harness()
        await harness.controller.start()
        #expect(harness.controller.state == .listening)
        harness.controller.handleInterruption(reason: .interrupted)
        await waitForIdle(harness.controller)
        #expect(harness.controller.state == .idle)
        #expect(harness.diagnostics.events.contains("interruption.interrupted"))
        #expect(harness.diagnostics.events.contains("listeningStopped"))
    }

    @Test("Route changes stop the session and log the route change")
    @MainActor
    func routeChange() async {
        let harness = Harness()
        await harness.controller.start()
        harness.controller.handleInterruption(reason: .interrupted, routeChange: true)
        await waitForIdle(harness.controller)
        #expect(harness.controller.state == .idle)
        #expect(harness.diagnostics.events.contains("routeChanged"))
    }

    @Test("Self-induced audio category changes do not stop dictation")
    @MainActor
    func categoryChangeIsIgnored() async {
        let harness = Harness()
        await harness.controller.start()
        harness.controller.handleAudioRouteChange(Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    NSNumber(value: AVAudioSession.RouteChangeReason.categoryChange.rawValue)
            ]
        ))
        #expect(harness.controller.state == .listening)
        #expect(!harness.diagnostics.events.contains("routeChanged"))

        harness.controller.handleAudioRouteChange(Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    NSNumber(value: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            ]
        ))
        await waitForIdle(harness.controller)
        #expect(harness.controller.state == .idle)
        #expect(harness.diagnostics.events.contains("routeChanged"))
    }

    @Test("Only interruption began stops an active voice session")
    @MainActor
    func interruptionEndIsIgnored() async {
        let harness = Harness()
        await harness.controller.start()
        harness.controller.handleAudioInterruption(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue)
            ]
        ))
        #expect(harness.controller.state == .listening)

        harness.controller.handleAudioInterruption(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)
            ]
        ))
        await waitForIdle(harness.controller)
        #expect(harness.controller.state == .idle)
    }

    @Test("Partial transcripts arrive in order and never duplicate")
    @MainActor
    func orderedTranscriptMerge() async {
        let harness = Harness()
        await harness.controller.start()
        harness.transcriber.emit("你好")
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(harness.controller.transcript == "你好")
        harness.transcriber.emit("你好世界")
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(harness.controller.transcript == "你好世界")
        harness.controller.stop()
    }

    @Test("Stopping drains and preserves the recognizer's final phrase")
    @MainActor
    func stopPreservesFinalPhrase() async {
        let harness = Harness()
        harness.transcriber.finalTextOnFinish = "停止前最后一句"
        await harness.controller.start()
        harness.controller.stop()
        await waitForIdle(harness.controller)
        #expect(harness.controller.transcript == "停止前最后一句")
        #expect(harness.transcriber.finishCount == 1)
    }

    @Test("A stop issued mid-preparation wins over the pending start")
    @MainActor
    func stopDuringPreparation() async {
        let harness = Harness()
        // Start, then immediately stop: the session must not end up
        // listening after the stop.
        harness.controller.requestStart()
        harness.controller.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(harness.controller.state != .listening)
    }

    @Test("A recognizer-ended stream stops the session cleanly")
    @MainActor
    func recognizerEndedStream() async {
        let harness = Harness()
        await harness.controller.start()
        harness.transcriber.emit("final")
        harness.transcriber.end()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(harness.controller.state == .idle)
        #expect(harness.controller.transcript == "final")
    }

    @Test("Real capture levels drive the published amplitude; silence is static")
    @MainActor
    func captureLevelDrivesPublishedAmplitude() async {
        let harness = Harness()
        await harness.controller.start()
        #expect(harness.controller.state == .listening)
        // Waiting/listening before speech: exactly the static baseline.
        #expect(harness.controller.audioLevel == 0)
        #expect(harness.controller.isSpeechDetected == false)

        harness.capturer.emitLevel(VoiceAudioLevel(level: 0.42, isSpeech: true))
        await waitForLevel(harness.controller, expected: 0.42)
        #expect(harness.controller.audioLevel == 0.42)
        #expect(harness.controller.isSpeechDetected == true)

        // Back to silence: the waveform returns to the static baseline.
        harness.capturer.emitLevel(.silent)
        await waitForLevel(harness.controller, expected: 0)
        #expect(harness.controller.audioLevel == 0)
        #expect(harness.controller.isSpeechDetected == false)

        harness.controller.stop()
        #expect(harness.controller.audioLevel == 0)
        #expect(harness.controller.isSpeechDetected == false)
        await waitForIdle(harness.controller)
    }

    @Test("Stopping clears levels even while a speech value is pending")
    @MainActor
    func stopResetsCaptureLevel() async {
        let harness = Harness()
        await harness.controller.start()
        harness.capturer.emitLevel(VoiceAudioLevel(level: 0.7, isSpeech: true))
        await waitForLevel(harness.controller, expected: 0.7)
        #expect(harness.controller.audioLevel == 0.7)
        harness.controller.stop()
        #expect(harness.controller.audioLevel == 0)
        #expect(harness.controller.isSpeechDetected == false)
        await waitForIdle(harness.controller)
    }

    @MainActor
    private func waitForLevel(_ controller: VoiceInputController, expected: Float) async {
        for _ in 0..<200 where controller.audioLevel != expected {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Pure DSP/state tests for the capture-level analyzer. Synthetic RMS frames
/// only: this proves the silence/speech state logic, not physical-device audio.
@Suite("FloeApp.VoiceActivityMeter")
struct VoiceActivityMeterTests {

    @Test("Silence and sub-gate noise stay at exact zero (static bars)")
    func silenceStaysStatic() {
        var meter = VoiceActivityMeter()
        for _ in 0..<50 {
            let output = meter.process(rms: 0.004, duration: 0.093)
            #expect(output.level == 0)
            #expect(output.isSpeech == false)
        }
    }

    @Test("Speech raises the level, then silence decays back to exact zero")
    func speechRaisesAndSilenceReturnsToStatic() {
        var meter = VoiceActivityMeter()
        let onset = meter.process(rms: 0.08, duration: 0.093)
        #expect(onset.isSpeech == true)
        #expect(onset.level > 0.2)

        // Sustained speech keeps the level high without oscillation.
        var sustained = onset
        for _ in 0..<10 {
            sustained = meter.process(rms: 0.12, duration: 0.093)
        }
        #expect(sustained.level > onset.level)
        #expect(sustained.isSpeech == true)

        // A few seconds of silence settle the baseline to exactly zero so the
        // waveform is static again (no timer keeps it moving).
        var silent = sustained
        for _ in 0..<40 {
            silent = meter.process(rms: 0.01, duration: 0.093)
        }
        #expect(silent.isSpeech == false)
        #expect(silent.level == 0)
    }

    @Test("The envelope releases to the static baseline after speech ends")
    func levelReleasesAfterSpeech() {
        var meter = VoiceActivityMeter()
        _ = meter.process(rms: 0.2, duration: 0.093)
        var output = VoiceAudioLevel.silent
        for _ in 0..<40 {
            output = meter.process(rms: 0.001, duration: 0.093)
        }
        #expect(output.level == 0)
        #expect(output.isSpeech == false)
    }
}
#endif
