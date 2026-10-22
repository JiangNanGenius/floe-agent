// FloeApp — Final-answer speech with one cancellable streaming PCM player.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import SwiftUI
import Combine
import FloeCore
import FloeProviders

@MainActor
struct TTSSpeechStreamHandle {
    let append: (String) -> Void
    let finish: () -> Void
    let cancel: () -> Void
}

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isPaused = false
    @Published private(set) var speakingText: String?
    @Published private(set) var failureKey: String?
    @Published private(set) var failedText: String?
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var pitch: Float = 1
    @Published var voiceIdentifier: String?
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    private var settings: TTSSettingsService?
    private var speech: TTSSpeechService?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var input: AsyncStream<String>.Continuation?
    private var playbackWaiter: CheckedContinuation<Void, Error>?
    private var ownsAudioSession = false
    private var lastManualText: String?
    private var receivedCharacters = 0
    private var currentReadText = ""
    private var manualMessageText: String?
    private var playerSampleRate: Double?
    private var retrySettings: TTSSettingsSnapshot?
    private var notifications = Set<AnyCancellable>()
    private var localRuntime: LocalSpeechRuntime?
    private var localSessionID: UUID?
    private(set) var activeLocalModelID: String?

    override init() {
        super.init()
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated { self?.pause() }
            }.store(in: &notifications)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                MainActor.assumeIsolated { self?.pause() }
            }.store(in: &notifications)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isSpeaking else { return }
                    let text = self.lastManualText
                    self.stop()
                    self.failedText = text
                    self.failureKey = "voice.error.playback"
                }
            }.store(in: &notifications)
    }

    func configure(settings: TTSSettingsService, speech: TTSSpeechService, localRuntime: LocalSpeechRuntime? = nil) {
        self.settings = settings
        self.speech = speech
        self.localRuntime = localRuntime
    }

    func speak(_ text: String) {
        if isSpeaking, let speakingText, AnswerSpeechText.plainText(speakingText) == AnswerSpeechText.plainText(text) { stop(); return }
        preview(text, settings: settings?.snapshot ?? .systemDefault)
    }

    func preview(_ text: String, settings: TTSSettingsSnapshot, credential: String? = nil) {
        let handle = beginStream(id: UUID(), override: settings, credential: credential)
        lastManualText = text
        manualMessageText = text
        speakingText = text
        handle.append(AnswerSpeechText.plainText(text))
        handle.finish()
    }

    func retry() {
        if let text = lastManualText, let settings = retrySettings { preview(text, settings: settings) }
    }

    func useSystemVoice() {
        guard let lastManualText else { return }
        speakSystem(lastManualText)
    }

    private func speakSystem(_ text: String) {
        let handle = beginStream(id: UUID(), override: .systemDefault)
        lastManualText = text
        manualMessageText = text
        speakingText = text
        handle.append(AnswerSpeechText.plainText(text))
        handle.finish()
    }

    func beginStream(id: UUID) -> TTSSpeechStreamHandle { beginStream(id: id, override: nil) }

    private func beginStream(id logicalID: UUID, override: TTSSettingsSnapshot?, credential: String? = nil) -> TTSSpeechStreamHandle {
        stop()
        isPreparing = true
        // A reused logical run id must never revive callbacks from an older player.
        let id = UUID()
        failureKey = nil
        failedText = nil
        currentReadText = ""
        manualMessageText = nil
        generation = id
        guard let settings, let speech else { return TTSSpeechStreamHandle(append: { _ in }, finish: {}, cancel: {}) }
        let frozen = override ?? settings.snapshot
        retrySettings = frozen
        localSessionID = frozen.provider == .onDevice ? id : nil
        activeLocalModelID = frozen.provider == .onDevice ? frozen.modelID : nil
        let source = ConfiguredTTSSpeechSource(snapshot: frozen, settings: settings, service: speech, overrideCredential: credential)
        let (texts, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        setSpeaking(true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var segmenter = TTSTextSegmenter()
                var index = 0
                for await addition in texts {
                    try Task.checkCancellation()
                    for segment in segmenter.append(addition) {
                        try await self.play(segment, index: index, owner: id, source: source)
                        index += 1
                    }
                }
                for segment in segmenter.finish() {
                    try Task.checkCancellation()
                    try await self.play(segment, index: index, owner: id, source: source)
                    index += 1
                }
                if generation == id { finishPlayback() }
            } catch {
                guard generation == id else { return }
                let cancelled = Task.isCancelled || (error as? TTSSynthesisError) == .cancelled
                finishPlayback()
                if !cancelled { failureKey = SpeechFailureCopy.key(for: error); failedText = lastManualText }
                generation = UUID()
            }
        }
        return TTSSpeechStreamHandle(
            append: { [weak self] text in
                guard let self, self.generation == id else { return }
                guard self.receivedCharacters + text.count <= 64_000 else {
                    let failed = self.lastManualText
                    self.stop()
                    self.failedText = failed
                    self.failureKey = "voice.error.too_long"
                    return
                }
                self.receivedCharacters += text.count
                self.currentReadText += text
                if self.manualMessageText == nil {
                    self.lastManualText = self.currentReadText
                    self.speakingText = self.currentReadText
                }
                continuation.yield(text)
            },
            finish: { continuation.finish() },
            cancel: { [weak self] in if self?.generation == id { self?.stop() } }
        )
    }

    func pause() { guard isSpeaking else { return }; player?.pause(); isPaused = true }
    func resume() {
        guard isSpeaking, isPaused else { return }
        do {
            if let engine, !engine.isRunning {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
            }
            player?.play()
            isPaused = false
        } catch {
            let text = lastManualText
            stop()
            failedText = text
            failureKey = "voice.error.playback"
        }
    }

    func stopAndWait() async {
        let id = localSessionID
        stop()
        if let id, let localRuntime { await localRuntime.endSession(id) }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        input?.finish(); input = nil
        finishPlayback()
    }

    private func finishPlayback() {
        isPreparing = false
        activeLocalModelID = nil
        if let localSessionID, let localRuntime {
            self.localSessionID = nil
            Task { await localRuntime.endSession(localSessionID) }
        }
        player?.stop()
        engine?.stop()
        player = nil; engine = nil; playerSampleRate = nil
        let waiter = playbackWaiter
        playbackWaiter = nil
        waiter?.resume(throwing: CancellationError())
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        isPaused = false
        speakingText = nil
        receivedCharacters = 0
        input = nil
        setSpeaking(false)
    }

    private func setSpeaking(_ value: Bool) {
        guard value != isSpeaking else { return }
        isSpeaking = value
        onSpeakingChanged?(value)
    }

    private func preparePlayer(sampleRate: Double) throws -> AVAudioPlayerNode {
        if let player {
            guard playerSampleRate == sampleRate else { throw TTSSynthesisError.invalidConfiguration("Audio format changed") }
            return player
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        ownsAudioSession = true
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw CancellationError() }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.engine = engine; self.player = player; playerSampleRate = sampleRate
        try engine.start()
        if !isPaused { player.play() }
        return player
    }

    private func play(_ text: String, index: Int, owner: UUID, source: ConfiguredTTSSpeechSource) async throws {
        var carry: UInt8?
        var sawFinal = false
        var sequence = -1
        var sampleRate: Int?
        var audioBytes = 0
        for try await chunk in source.synthesize(text: text, sessionID: owner, segmentIndex: index) {
            try Task.checkCancellation()
            guard generation == owner, chunk.sessionID == owner, chunk.segmentIndex == index,
                  chunk.sequence > sequence, !sawFinal,
                  (8_000...192_000).contains(chunk.sampleRate),
                  sampleRate == nil || sampleRate == chunk.sampleRate,
                  chunk.pcm.count <= 256_000 else { throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider) }
            sequence = chunk.sequence
            sampleRate = chunk.sampleRate
            audioBytes += chunk.pcm.count
            guard audioBytes <= 8 * 1024 * 1024 else { throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider) }
            var bytes = [UInt8]()
            if let carry { bytes.append(carry) }
            bytes.append(contentsOf: chunk.pcm)
            carry = bytes.count.isMultiple(of: 2) ? nil : bytes.removeLast()
            guard !bytes.isEmpty else { sawFinal = chunk.isFinal; continue }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count / 2)),
                  let floats = buffer.floatChannelData?[0] else { throw CancellationError() }
            buffer.frameLength = buffer.frameCapacity
            for offset in 0..<Int(buffer.frameLength) {
                let value = UInt16(bytes[offset * 2]) | UInt16(bytes[offset * 2 + 1]) << 8
                floats[offset] = Float(Int16(bitPattern: value)) / 32768
            }
            let player = try preparePlayer(sampleRate: Double(chunk.sampleRate))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playbackWaiter = continuation
                isPreparing = false
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == owner else { return }
                        let pending = self.playbackWaiter
                        self.playbackWaiter = nil
                        pending?.resume()
                    }
                }
            }
            sawFinal = chunk.isFinal
        }
        guard sawFinal, audioBytes > 0, carry == nil else { throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider) }
    }
}

/// Never reads fenced code, raw URLs or Markdown punctuation aloud. Tool and
/// reasoning exclusion happens at the typed answer projection, not by guessing
/// whether arbitrary user-visible prose sounds like a tool call.
enum AnswerSpeechText {
    static func plainText(_ markdown: String) -> String {
        var result = markdown.replacingOccurrences(of: "(?s)```.*?```", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}(?:#{1,6}|>|[-*+] |[0-9]+\\. )\\s*", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "https?://[^\\s<>()]+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SpeechFailureCopy {
    static func key(for error: Error) -> String {
        if let failure = error as? LocalSpeechRuntime.Failure {
            switch failure {
            case .unsupportedDevice: return "voice.local.error.device"
            case .voice, .language: return "voice.error.configuration"
            case .invalidAudio: return "voice.error.playback"
            }
        }
        if let failure = error as? LocalSpeechModelStore.Failure {
            switch failure {
            case .memory: return "voice.local.error.memory"
            case .busy: return "voice.local.error.busy"
            case .space: return "voice.local.error.space"
            case .unavailable: return "voice.local.error.unavailable"
            case .corrupt: return "voice.local.error.corrupt"
            }
        }
        switch error as? TTSSynthesisError {
        case .credentialMissing, .authentication: return "voice.error.credential"
        case .quotaOrRateLimited: return "voice.error.quota"
        case .invalidConfiguration: return "voice.error.configuration"
        default: return "voice.error.playback"
        }
    }
}
#endif
