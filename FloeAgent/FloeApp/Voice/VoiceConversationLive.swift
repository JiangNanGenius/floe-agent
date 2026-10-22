// FloeApp — Continuous voice conversation: production duplex audio stack.
//
// SPDX-License-Identifier: MPL-2.0
//
// ONE shared AVAudioEngine owns both directions so synthesized speech is
// ALWAYS the AEC output reference the microphone voice processing cancels
// against — the requirement behind barge-in on speakerphone:
//
//   inputNode (setVoiceProcessingEnabled → Apple echo cancellation + noise
//   suppression) --tap--> [AEC-cleaned mic] → meter → `levels` AND the
//   REUSED transcription backend (same selection as dictation: Whisper
//   local when installed, stable SFSpeechRecognizer otherwise; no new ASR
//   service, no extra cloud ASR)
//   playerNode --(mixed)--> mainMixerNode --tap--> `playedLevels` REAL
//   speaker-bound PCM amplitude (what the orb animates from) --> output
//
// The microphone is NEVER connected to the output; the player feeds the same
// engine whose output Apple's voice processing uses as the echo reference.
//
// Session discipline:
// - `.playAndRecord` + `.voiceChat` with `.defaultToSpeaker` /
//   `.allowBluetoothA2DP`.
// - A superseded stack instance NEVER deactivates the shared
//   `AVAudioSession`: ownership is a class-level generation token. No
//   callback into AppEnvironment; the app layer already ORs the
//   presentation's activity into its PiP gates.
// - Simulator: mirrors the PROVEN dictation guard — `noAudioInput` is thrown
//   BEFORE touching `engine.inputNode`, because the simulator RemoteIO
//   service can abort the process below Swift error handling when no host
//   microphone is routed. Simulator UI acceptance therefore injects fake
//   stacks and never claims real capture/AEC from this file.
// - No audio is ever persisted. Buffers flow through memory only.
//
// Played-progress truth: per-scheduled-buffer completion callbacks with an
// epoch guard. `pause()` freezes the position, `play()` continues it,
// `stop()` bumps the epoch, clears the queue and resets the counter so a
// finished/cancelled round can never leak progress into the next. Receipts
// and drain decisions derive ONLY from these real played frames — never from
// a TTS producer's final flag.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import FloeCore

// MARK: - Authorization bridge (reuses the exact dictation prompts)

extension SystemSpeechAuthorizationProvider: VoiceConversationAuthorizationProviding {}

// MARK: - Shared session ownership (never deactivated by a superseded owner)

/// One holder at a time. `claim` supersedes; `release` reports whether the
/// releasing id still owned the session — only then is deactivation allowed,
/// so an old session finishing late can never knock a newer owner off the
/// shared `AVAudioSession`.
enum VoiceConversationSessionOwnership {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentOwner: UUID?

    static func claim(_ id: UUID) {
        lock.withLock { currentOwner = id }
    }

    static func release(_ id: UUID) -> Bool {
        lock.withLock {
            guard currentOwner == id else { return false }
            currentOwner = nil
            return true
        }
    }
}

// MARK: - Live stack

/// Nonisolated `@unchecked Sendable`, exactly like the proven dictation
/// `AudioEngineCapturer`: render-thread tap and schedule-completion callbacks
/// touch internal lock-protected state only. The coordinator — the sole
/// caller of the protocol methods — runs on the main actor.
final class VoiceConversationLiveStack: VoiceConversationStack, @unchecked Sendable {

    // Engine graph
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputFormat: AVAudioFormat?
    private var playerFormat: AVAudioFormat?
    private var tapInstalled = false
    private var outputTapInstalled = false
    private var playerConnected = false
    private var engineStarted = false
    private var sessionActivated = false
    private let stackID = UUID()
    private let graphLock = NSLock()

    // Streams
    let levels: AsyncStream<VoiceConversationLevel>
    let playedLevels: AsyncStream<VoiceConversationLevel>
    let engineEvents: AsyncStream<VoiceConversationEngineEvent>
    let systemEvents: AsyncStream<VoiceConversationSystemEvent>
    private let levelContinuation: AsyncStream<VoiceConversationLevel>.Continuation
    private let playedLevelContinuation: AsyncStream<VoiceConversationLevel>.Continuation
    private let engineEventContinuation: AsyncStream<VoiceConversationEngineEvent>.Continuation
    private let systemEventContinuation: AsyncStream<VoiceConversationSystemEvent>.Continuation

    /// ONE stream per transcription session: the coordinator RESTARTS ASR
    /// in place (recognizers may end their own streams), and a resubscribed
    /// consumer must never see the previous, already-finished stream.
    var transcripts: AsyncStream<String> {
        backendLock.withLock { currentTranscripts }
    }
    private var currentTranscripts: AsyncStream<String>
    private var transcriptContinuation: AsyncStream<String>.Continuation

    // Meters (mic after voice processing, and the mixed output bus)
    private let micLock = NSLock()
    private var micMeter = VoiceActivityMeter()
    private let playedLock = NSLock()
    private var playedMeter = VoiceActivityMeter()

    // Transcription backend (existing seams only)
    private let language: VoiceRecognitionLanguage
    private let backendLock = NSLock()
    private var backend: (any SpeechTranscribing)?
    private var backendFeed: Task<Void, Never>?
    private var audioFinished = false
    private var terminalFailure: VoiceConversationFailure?

    // Played-frame accounting (epoch-fenced)
    private let playbackLock = NSLock()
    private var epoch: UInt64 = 0
    private var scheduledFrames = 0
    private var completedFrames = 0
    private static let engineMaxPendingSeconds = 60.0

    // Resampling cache (protocol calls are serialized by the coordinator)
    private var converterCache: [String: AVAudioConverter] = [:]

    private var observers: [NSObjectProtocol] = []

    var outputSampleRate: Double {
        graphLock.withLock { playerFormat?.sampleRate ?? 48_000 }
    }

    init(language: VoiceRecognitionLanguage = .automatic) {
        self.language = language
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (playedLevels, playedLevelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (currentTranscripts, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        (engineEvents, engineEventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (systemEvents, systemEventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        engine.attach(playerNode)
    }

    // MARK: - Activation

    func activate() async throws(VoiceConversationFailure) {
        if graphLock.withLock({ engineStarted }) { return }
        // PROVEN simulator guard (same rationale as dictation's
        // AudioEngineCapturer): NEVER touch engine.inputNode on the
        // simulator — RemoteIO can abort the process below Swift errors.
        #if targetEnvironment(simulator)
        throw .noAudioInput
        #else
        VoiceConversationSessionOwnership.claim(stackID)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            graphLock.withLock { sessionActivated = true }
        } catch {
            _ = VoiceConversationSessionOwnership.release(stackID)
            throw .noAudioInput
        }

        do {
            try configureGraph()
        } catch let failure {
            rollbackActivation()
            throw failure
        }
        installSystemObservers()
        #endif
    }

    #if !targetEnvironment(simulator)
    private func configureGraph() throws(VoiceConversationFailure) {
        let input = engine.inputNode
        do {
            // Apple voice-processing IO: echo cancellation against the
            // engine's OWN output (the player below rides the same engine),
            // plus noise suppression. Output is NEVER fed back to input.
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw .noAudioInput
        }
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw .noAudioInput
        }
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        guard let playerFmt = outFormat.sampleRate > 0
            ? outFormat
            : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        else {
            throw .noAudioInput
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: playerFmt)
        graphLock.withLock {
            inputFormat = micFormat
            playerFormat = playerFmt
            playerConnected = true
        }

        // Output-side metering: the mixer bus that feeds the speaker — the
        // REAL played PCM amplitude. During player pause the graph renders
        // silence, so the meter decays honestly to zero.
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: playerFmt
        ) { [weak self] buffer, _ in
            self?.publishPlayedLevel(of: buffer)
        }
        graphLock.withLock { outputTapInstalled = true }

        engine.prepare()
        do {
            try engine.start()
            graphLock.withLock { engineStarted = true }
        } catch {
            throw .noAudioInput
        }
    }

    private func rollbackActivation() {
        graphLock.lock()
        let hadTap = outputTapInstalled
        let connected = playerConnected
        let started = engineStarted
        outputTapInstalled = false
        playerConnected = false
        engineStarted = false
        let activate = sessionActivated
        sessionActivated = false
        graphLock.unlock()
        if hadTap { engine.mainMixerNode.removeTap(onBus: 0) }
        if connected { engine.disconnectNodeInput(playerNode) }
        if started { engine.stop() }
        if activate, VoiceConversationSessionOwnership.release(stackID) {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }
    #endif

    // MARK: - Capture

    func startCapture() throws(VoiceConversationFailure) {
        #if targetEnvironment(simulator)
        throw .noAudioInput
        #else
        graphLock.lock()
        guard engineStarted, !tapInstalled, let inputFormat else {
            let started = engineStarted
            graphLock.unlock()
            if !started { throw .noAudioInput }
            return
        }
        tapInstalled = true
        graphLock.unlock()
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, time in
            guard buffer.frameLength > 0 else { return }
            self?.publishMicLevel(of: buffer)
            self?.feedBackend(buffer, at: time)
        }
        #endif
    }

    func stopCapture() {
        #if !targetEnvironment(simulator)
        let hadTap = graphLock.withLock {
            let value = tapInstalled
            tapInstalled = false
            return value
        }
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        #endif
    }

    // MARK: - Transcription (existing backends through existing seams)

    func beginTranscription() async throws(VoiceConversationFailure) {
        await retireBackend()
        let fresh: any SpeechTranscribing
        do {
            fresh = try await Self.makeBackend(language: language)
        } catch let failure as VoiceConversationFailure {
            throw failure
        } catch is CancellationError {
            throw .recognizerFailed
        } catch {
            throw .recognizerFailed
        }
        // Scoped locking: NSLock.lock()/unlock() are unavailable from async
        // contexts in Swift 6; the critical section itself is synchronous.
        backendLock.withLock {
            audioFinished = false
            terminalFailure = nil
            backend = fresh
            // Fresh stream for the fresh backend session (see property docs).
            (currentTranscripts, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        }
        backendFeed = Task { [weak self, fresh] in
            for await text in fresh.transcripts {
                guard let self else { return }
                let sink = self.backendLock.withLock { self.transcriptContinuation }
                sink.yield(text)
            }
            if let failure = fresh.failure {
                self?.backendLock.withLock { self?.terminalFailure = Self.map(failure) }
            }
            let sink = self?.backendLock.withLock { self?.transcriptContinuation }
            sink?.finish()
        }
    }

    func finishTranscription() async {
        let retire = backendLock.withLock { () -> (any SpeechTranscribing)? in
            guard !audioFinished else { return nil }
            audioFinished = true
            return backend
        }
        if let retire {
            await retire.finishAudio()
        }
        backendFeed?.cancel()
        backendFeed = nil
        backendLock.withLock { transcriptContinuation }.finish()
    }

    func transcriptionFailureSnapshot() -> VoiceConversationFailure? {
        backendLock.withLock { terminalFailure }
    }

    private func retireBackend() async {
        let previous = backendLock.withLock { () -> (any SpeechTranscribing)? in
            let value = backend
            backend = nil
            return value
        }
        let feed = backendLock.withLock { () -> Task<Void, Never>? in
            let value = backendFeed
            backendFeed = nil
            return value
        }
        if let previous {
            await previous.finishAudio()
        }
        feed?.cancel()
        _ = await feed?.value
    }

    /// Tap-thread safe: the backend reference may be retired mid-buffer;
    /// dropping buffers during a retire window is safe and never corrupts
    /// the analyzer (same rule as the dictation capturer).
    private nonisolated func feedBackend(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let current = backendLock.withLock { backend }
        current?.feed(buffer, at: time)
    }

    /// REUSES the dictation-owned canonical factory
    /// (`VoiceInputController.makePreferredTranscriber`) so continuous voice
    /// and dictation never diverge: it honors `VoiceRecognitionPreferences
    /// .method` (automatic/system/enhanced) and the exact existing
    /// Whisper → Apple fallback. No new ASR library and no parallel selector
    /// lives here.
    @MainActor
    private static func makeBackend(language: VoiceRecognitionLanguage) async throws -> any SpeechTranscribing {
        do {
            let transcriber = try await VoiceInputController.makePreferredTranscriber(
                language: language,
                diagnostics: nil
            )
            FloeLogger(category: .app).info("voiceConversationBackendSelected domain=voice")
            return transcriber
        } catch let error as VoiceSessionError {
            throw VoiceConversationLiveStack.map(error.failure)
        } catch is CancellationError {
            throw VoiceConversationFailure.interrupted
        }
    }

    private static func map(_ failure: VoiceInputFailure) -> VoiceConversationFailure {
        switch failure {
        case .microphonePermissionDenied: return .microphonePermissionDenied
        case .speechPermissionDenied: return .speechPermissionDenied
        case .localeUnsupported: return .localeUnsupported
        case .modelNotReady: return .modelNotReady
        case .noAudioInput: return .noAudioInput
        case .recognizerFailed: return .recognizerFailed
        case .interrupted: return .interrupted
        }
    }

    // MARK: - Playback

    @discardableResult
    func scheduleChunk(_ chunk: VoiceConversationAudioChunk) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard chunk.isValid,
              graphLock.withLock({ engineStarted }),
              let playerFmt = graphLock.withLock({ playerFormat }) else { return false }
        let outFrames = Self.convertedFrames(
            chunkFrames: chunk.frameCount,
            chunkRate: chunk.sampleRate,
            outRate: playerFmt.sampleRate
        )
        guard outFrames > 0 else { return false }
        let capacity = Int(Self.engineMaxPendingSeconds * playerFmt.sampleRate)
        let pending = playbackLock.withLock { scheduledFrames - completedFrames }
        guard pending + outFrames <= capacity else { return false }
        guard let source = Self.buffer(from: chunk),
              let converted = convert(source, to: playerFmt) else { return false }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return true }
        let capturedEpoch = playbackLock.withLock { () -> UInt64 in
            scheduledFrames += frames
            return epoch
        }
        // Completion is requested for `.dataPlayedBack` — the buffer has
        // ACTUALLY finished playing through the output device — never
        // `.dataConsumed`: played-frame progress must stay honest.
        playerNode.scheduleBuffer(
            converted,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] _ in
                guard let self else { return }
                let advance = self.playbackLock.withLock { () -> Int? in
                    guard self.epoch == capturedEpoch else { return nil }
                    self.completedFrames += frames
                    return self.completedFrames
                }
                if let advance {
                    self.engineEventContinuation.yield(.playedFrames(advance))
                }
            }
        )
        if !playerNode.isPlaying { playerNode.play() }
        return true
        #endif
    }

    /// No engine action: drain truth is played frames reaching the
    /// coordinator's queued total. Kept for seam symmetry.
    func endQueuedAudio() {}

    func pausePlayback() {
        playerNode.pause()
    }

    func resumePlayback() {
        #if !targetEnvironment(simulator)
        if graphLock.withLock({ engineStarted }) { playerNode.play() }
        #endif
    }

    func stopPlayback() {
        playbackLock.lock()
        epoch &+= 1
        scheduledFrames = 0
        completedFrames = 0
        playbackLock.unlock()
        playerNode.stop()
        // Fresh zero keeps progress honest; stale completions are
        // epoch-fenced and can never credit a newer round.
        engineEventContinuation.yield(.playedFrames(0))
        #if !targetEnvironment(simulator)
        if graphLock.withLock({ engineStarted }) { playerNode.play() }
        #endif
    }

    // MARK: - Chunk ↔ buffer

    private static func buffer(from chunk: VoiceConversationAudioChunk) -> AVAudioPCMBuffer? {
        let frames = chunk.frameCount
        guard frames > 0, frames <= 240_000,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: AVAudioChannelCount(chunk.channelCount),
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if chunk.channelCount == 1 {
            // `floatChannelData` is nullable but its channel pointers are
            // non-null in the iOS 27 SDK — no optional binding needed.
            let mono = channels[0]
            chunk.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { mono.update(from: base, count: source.count) }
            }
        } else if chunk.channelCount == 2 {
            let left = channels[0]
            let right = channels[1]
            // Deinterleave the caller's interleaved stereo into planar.
            chunk.samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for index in 0..<frames {
                    left[index] = base[index * 2]
                    right[index] = base[index * 2 + 1]
                }
            }
        } else {
            return nil
        }
        return buffer
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to output: AVAudioFormat) -> AVAudioPCMBuffer? {
        let key = buffer.format.description
        let converter: AVAudioConverter
        if let cached = converterCache[key] {
            converter = cached
        } else if let created = AVAudioConverter(from: buffer.format, to: output) {
            converterCache[key] = created
            converter = created
        } else {
            return nil
        }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let estimated = max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 32)
        guard estimated <= Int(UInt32.max),
              let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(estimated))
        else { return nil }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private static func convertedFrames(chunkFrames: Int, chunkRate: Double, outRate: Double) -> Int {
        guard chunkFrames > 0, chunkRate.isFinite, chunkRate > 0,
              outRate.isFinite, outRate > 0 else { return 0 }
        return Int((Double(chunkFrames) * outRate / chunkRate).rounded())
    }

    // MARK: - Metering (render thread)

    private nonisolated func publishMicLevel(of buffer: AVAudioPCMBuffer) {
        let rms = VoiceBufferMeter.rms(of: buffer)
        let duration = Double(buffer.frameLength) / Double(max(buffer.format.sampleRate, 1))
        let output = micLock.withLock {
            micMeter.process(rms: rms, duration: Float(duration))
        }
        levelContinuation.yield(
            VoiceConversationLevel(level: output.level, isSpeech: output.isSpeech, duration: duration)
        )
    }

    private nonisolated func publishPlayedLevel(of buffer: AVAudioPCMBuffer) {
        let rms = VoiceBufferMeter.rms(of: buffer)
        let duration = Double(buffer.frameLength) / Double(max(buffer.format.sampleRate, 1))
        let output = playedLock.withLock {
            playedMeter.process(rms: rms, duration: Float(duration))
        }
        playedLevelContinuation.yield(
            VoiceConversationLevel(level: output.level, isSpeech: output.isSpeech, duration: duration)
        )
    }

    // MARK: - System observation

    private func installSystemObservers() {
        let notes = NotificationCenter.default
        let interruptionToken = notes.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.systemEventContinuation.yield(.interruptionBegan)
        }
        let routeToken = notes.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  Self.interruptsForRouteChange(reason) else { return }
            // No silent rerouting after unplug — report the LOSS; the
            // coordinator pauses and cancels output instead of switching.
            self.systemEventContinuation.yield(.routeLost)
        }
        let mediaToken = notes.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.systemEventContinuation.yield(.mediaServicesReset)
        }
        let configToken = notes.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.systemEventContinuation.yield(.engineConfigurationChanged)
        }
        observers.append(contentsOf: [interruptionToken, routeToken, mediaToken, configToken])
    }

    /// Same predicate the dictation controller uses: only removal of the
    /// active input/output device or an unusable route interrupts a session.
    static func interruptsForRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory: true
        default: false
        }
    }

    private func removeSystemObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    // MARK: - Teardown

    func deactivate() {
        stopCapture()
        #if !targetEnvironment(simulator)
        let hadOutputTap = graphLock.withLock {
            let value = outputTapInstalled
            outputTapInstalled = false
            return value
        }
        if hadOutputTap { engine.mainMixerNode.removeTap(onBus: 0) }
        let wasConnected = graphLock.withLock {
            let value = playerConnected
            playerConnected = false
            return value
        }
        if wasConnected { engine.disconnectNodeInput(playerNode) }
        #endif
        playerNode.stop()
        let wasStarted = graphLock.withLock {
            let value = engineStarted
            engineStarted = false
            return value
        }
        if wasStarted { engine.stop() }
        removeSystemObservers()
        let wasActivated = graphLock.withLock {
            let value = sessionActivated
            sessionActivated = false
            return value
        }
        if wasActivated, VoiceConversationSessionOwnership.release(stackID) {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        levelContinuation.finish()
        playedLevelContinuation.finish()
        engineEventContinuation.finish()
        systemEventContinuation.finish()
        let pending = backendLock.withLock { () -> (any SpeechTranscribing)? in
            let value = backend
            backend = nil
            return value
        }
        if let pending {
            Task { [pending] in await pending.finishAudio() }
        }
        let feed = backendLock.withLock { () -> Task<Void, Never>? in
            let value = backendFeed
            backendFeed = nil
            return value
        }
        feed?.cancel()
        backendLock.withLock { transcriptContinuation }.finish()
    }

    deinit {
        // Ownership token guarantees a superseded instance never touches the
        // shared session even if the coordinator failed to deactivate it.
        removeSystemObservers()
    }
}

// MARK: - Redacted diagnostics

/// Structured lifecycle diagnostics for the conversation session. Carries
/// state codes and counts ONLY — never transcript bodies, audio, or secrets.
struct FloeVoiceConversationDiagnostics: VoiceConversationDiagnostics {
    private let logger = FloeLogger(category: .app)
    func voiceConversation(_ code: String, _ detail: String) {
        if detail.isEmpty {
            logger.info("voiceConversation domain=voiceConversation code=\(code)")
        } else {
            logger.info("voiceConversation domain=voiceConversation code=\(code) \(detail)")
        }
    }
}

// MARK: - Production factory

extension VoiceConversationCoordinator {
    /// The production wiring: same system permission prompts as dictation,
    /// one duplex live stack per session (AEC-processed mic capture + the
    /// shared player-node output the TTS bridge feeds), a real clock,
    /// markdown→plain normalization for SPEECH and redacted logging.
    ///
    /// Simulator note: capture/AEC are unavailable by design (see
    /// `VoiceConversationLiveStack.activate`); UI acceptance must inject
    /// fake stacks. Nothing here claims real microphone behavior until a
    /// physical-device run by the app owner.
    static func live(
        driving: any VoiceConversationTurnDriving,
        language: VoiceRecognitionLanguage = .automatic,
        diagnostics: (any VoiceConversationDiagnostics)? = FloeVoiceConversationDiagnostics()
    ) -> VoiceConversationCoordinator {
        VoiceConversationCoordinator(
            authorization: SystemSpeechAuthorizationProvider(),
            makeStack: { VoiceConversationLiveStack(language: language) },
            driving: driving,
            clock: VoiceConversationSystemScheduler(),
            diagnostics: diagnostics,
            speechNormalizer: { AnswerSpeechText.plainText($0) }
        )
    }
}
#endif
