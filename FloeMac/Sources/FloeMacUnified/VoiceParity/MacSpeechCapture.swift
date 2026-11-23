// SPDX-License-Identifier: MPL-2.0

import AVFoundation
import Foundation
import Speech

enum MacVoiceCaptureError: Error {
    case microphoneDenied, speechDenied, unsupportedLocale, noInput, recognitionFailed

    var message: String {
        switch self {
        case .microphoneDenied: String(localized: "mac.voice.microphoneDenied")
        case .speechDenied: String(localized: "mac.voice.speechDenied")
        case .unsupportedLocale: String(localized: "mac.voice.languageUnavailable")
        case .noInput: String(localized: "mac.voice.noMicrophone")
        case .recognitionFailed: String(localized: "mac.voice.recognitionFailed")
        }
    }
}

enum MacVoiceInputUpdate: Sendable {
    case text(String, final: Bool)
    case speechDetected
    case failed
}

@MainActor
protocol MacVoiceCapturing {
    func start(locale: Locale, receive: @escaping @MainActor (MacVoiceInputUpdate) -> Void) async throws
    func finishInput()
    func cancel()
}

/// The audio tap owns synchronous buffer delivery. Shutdown removes the
/// tap before ending the request, so no buffer is retained by a UI task.
private final class MacSpeechAudioRequest: @unchecked Sendable {
    let value = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var ended = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { if !ended { value.append(buffer) } }
    }

    func end() {
        let shouldEnd = lock.withLock {
            guard !ended else { return false }
            ended = true
            return true
        }
        if shouldEnd { value.endAudio() }
    }
}

@MainActor
final class MacSpeechCapture: MacVoiceCapturing {
    private let engine = AVAudioEngine()
    private var request: MacSpeechAudioRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var metering: Task<Void, Never>?
    private var watchingInput: Task<Void, Never>?
    private var installedTap = false
    private var generation = UUID()

    func start(locale: Locale, receive: @escaping @MainActor (MacVoiceInputUpdate) -> Void) async throws {
        cancel()
        let owner = generation
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MacVoiceCaptureError.microphoneDenied }
        try Task.checkCancellation()
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw MacVoiceCaptureError.speechDenied }
        try Task.checkCancellation()
        guard owner == generation else { throw CancellationError() }
        guard let speech = SFSpeechRecognizer(locale: locale), speech.isAvailable else {
            throw MacVoiceCaptureError.unsupportedLocale
        }
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw MacVoiceCaptureError.noInput
        }
        let audio = MacSpeechAudioRequest()
        audio.value.shouldReportPartialResults = true
        audio.value.requiresOnDeviceRecognition = speech.supportsOnDeviceRecognition
        audio.value.taskHint = .dictation
        request = audio
        recognizer = speech
        recognition = speech.recognitionTask(with: audio.value) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil && !final
            Task { @MainActor [weak self] in
                guard self?.generation == owner else { return }
                if let text { receive(.text(text, final: final)) }
                if failed { receive(.failed) }
            }
        }
        let (levels, levelSender) = AsyncStream<(Float, Float)>.makeStream(bufferingPolicy: .bufferingNewest(4))
        node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard VoiceBufferValidator.isUsable(buffer) else { return }
            audio.append(buffer)
            _ = levelSender.yield((VoiceBufferMeter.rms(of: buffer),
                                   Float(buffer.frameLength) / Float(buffer.format.sampleRate)))
        }
        installedTap = true
        metering = Task {
            var meter = VoiceActivityMeter()
            for await (rms, duration) in levels {
                if Task.isCancelled { break }
                if meter.process(rms: rms, duration: duration).isSpeech { receive(.speechDetected) }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw MacVoiceCaptureError.noInput
        }
        let ownedEngine = engine
        watchingInput = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: ownedEngine) {
                guard self?.generation == owner, !Task.isCancelled else { return }
                receive(.failed)
                return
            }
        }
    }

    func finishInput() {
        stopEngine()
        request?.end()
    }

    func cancel() {
        generation = UUID()
        stopEngine()
        request?.end()
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        request = nil
    }

    private func stopEngine() {
        watchingInput?.cancel()
        watchingInput = nil
        metering?.cancel()
        metering = nil
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        engine.stop()
    }
}

@MainActor
protocol MacVoiceSpeaking {
    func speak(_ text: String, locale: Locale) async -> Bool
    func stop()
}

@MainActor
final class MacVoiceSpeaker: NSObject, MacVoiceSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?
    private var completion: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, locale: Locale) async -> Bool {
        stop()
        guard !Task.isCancelled, !text.isEmpty else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier.replacingOccurrences(of: "_", with: "-"))
        current = ObjectIdentifier(utterance)
        return await withCheckedContinuation { continuation in
            completion = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if let current {
            complete(current, played: false)
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in complete(id, played: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in complete(id, played: false) }
    }

    private func complete(_ id: ObjectIdentifier, played: Bool) {
        guard current == id else { return }
        current = nil
        let continuation = completion
        completion = nil
        continuation?.resume(returning: played)
    }
}
