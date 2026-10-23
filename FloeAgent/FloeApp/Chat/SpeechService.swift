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

/// Bounded PCM supply for one spoken answer.
///
/// The previous player scheduled one 4 KiB buffer at a time and waited for it
/// to finish playing before pulling the next chunk, so the output device had
/// zero look-ahead: every MainActor hop, decode and generation hiccup landed
/// as an audible gap every ~40 ms. This supply batches sample-aligned audio
/// (≈0.8 s), primes playback with a short bounded lead, and asks for a full
/// refill batch after a starvation gap so playback resumes continuously
/// instead of chopping per chunk. All byte/counter logic is device-free.
@MainActor
final class SpeechPlaybackSupply {
    struct Limits {
        /// Audio queued before playback starts (or shorter when the answer ends).
        var primeSeconds: Double = 1.2
        /// Batch size handed to the player, and the refill target after a gap.
        var batchSeconds: Double = 0.8
        /// A short first sentence still starts once it reaches this length.
        var shortSegmentPrimeSeconds: Double = 0.6
        /// Depth at which the player is treated as starving.
        var starvationSeconds: Double = 0.15
        /// Refill target after a starvation gap. Larger than one steady batch
        /// so output resumes with a longer continuous run instead of chopping
        /// again on the next shortfall.
        var starvationRefillSeconds: Double = 1.0
        /// Bounded audio held by the player plus this supply at any moment.
        var maxBufferedSeconds: Double = 3.0
        static let standard = Limits()
    }

    let sampleRate: Double
    let limits: Limits
    let format: AVAudioFormat
    private var pending: [UInt8] = []
    private var carryByte: UInt8?
    private(set) var scheduledFrames = 0
    private(set) var playedFrames = 0
    private(set) var primed = false
    private(set) var segmentFinal = false
    private(set) var ended = false

    init(sampleRate: Double, limits: Limits = .standard) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(Int(sampleRate)),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TTSSynthesisError.invalidConfiguration("Unsupported speech sample rate")
        }
        self.sampleRate = sampleRate
        self.limits = limits
        self.format = format
    }

    /// Odd bytes are carried to the next chunk so every scheduled buffer is
    /// whole 16-bit samples even when a provider splits one sample.
    var carry: UInt8? { carryByte }
    var pendingFrames: Int { pending.count / 2 }
    var depthFrames: Int { max(0, scheduledFrames - playedFrames) }
    func seconds(_ frames: Int) -> Double { Double(frames) / sampleRate }
    var depthSeconds: Double { seconds(depthFrames) }
    var pendingSeconds: Double { seconds(pendingFrames) }
    var bufferedSeconds: Double { depthSeconds + pendingSeconds }
    var canScheduleMore: Bool { depthSeconds < limits.maxBufferedSeconds }
    var isStarving: Bool { primed && depthSeconds < limits.starvationSeconds }
    /// Drain/pull loops must only suspend when a played callback is the sole
    /// way forward. Pending audio with lead room is schedulable immediately;
    /// with no pending audio re-checking cannot make progress.
    var hasSchedulableAudio: Bool { pendingFrames > 0 && canScheduleMore }
    var isDrained: Bool { ended && pendingFrames == 0 && scheduledFrames > 0 && playedFrames >= scheduledFrames }
    var canStartPlayback: Bool {
        guard !primed, scheduledFrames > 0 else { return false }
        if ended { return true }
        if seconds(scheduledFrames) >= limits.primeSeconds { return true }
        return segmentFinal && seconds(scheduledFrames) >= limits.shortSegmentPrimeSeconds
    }

    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        var incoming = [UInt8]()
        incoming.reserveCapacity(pcm.count + 1)
        if let carryByte { incoming.append(carryByte); self.carryByte = nil }
        incoming.append(contentsOf: pcm)
        if incoming.count % 2 == 1 { carryByte = incoming.removeLast() }
        pending.append(contentsOf: incoming)
    }

    /// Frames the player may take now, capped by the bounded lead. At the end
    /// of a segment everything that fits is flushed in order; otherwise one
    /// full batch (the priming amount before playback, the refill target after
    /// a starvation gap).
    func takeScheduleFrames(final: Bool) -> Int? {
        guard pendingFrames > 0 else { return nil }
        let room = max(0, Int(((limits.maxBufferedSeconds - depthSeconds) * sampleRate).rounded(.down)))
        guard room > 0 else { return nil }
        if final { return min(pendingFrames, room) }
        let threshold: Double
        if !primed { threshold = limits.primeSeconds }
        else if depthSeconds < limits.starvationSeconds { threshold = limits.starvationRefillSeconds }
        else { threshold = limits.batchSeconds }
        guard pendingSeconds >= threshold else { return nil }
        let batch = max(1, min(pendingFrames, Int((threshold * sampleRate).rounded())))
        return min(batch, room)
    }

    func takeBytes(frames: Int) -> [UInt8] {
        let count = min(max(0, frames) * 2, pending.count)
        guard count > 0 else { return [] }
        let bytes = Array(pending.prefix(count))
        pending.removeFirst(count)
        return bytes
    }

    func didSchedule(frames: Int) { scheduledFrames += frames }
    func didPlay(frames: Int) { playedFrames += frames }
    func markPrimed() { primed = true }
    func markSegmentFinal() { segmentFinal = true }
    func markEnded() { ended = true }
    func resetSegmentFinal() { segmentFinal = false }
}

/// Pull a stream chunk while bounding how long the answer may wait. A cold
/// local mount plus first frame is the slowest legitimate case; anything past
/// these bounds is a stalled pipeline, not progress, and must surface instead
/// of spinning forever.
enum SpeechSupplyDeadline {
    static let firstChunk: Duration = .seconds(90)
    static let nextChunk: Duration = .seconds(45)
    /// A primed player that never reports one played buffer is an output
    /// stall, not slow synthesis.
    static let firstPlayout: Duration = .seconds(20)
}

enum SpeechPlaybackFailure: Error {
    case firstChunkTimeout
    case supplyStalled
}

/// Single-consumer iterator box so one pull can be raced against a deadline.
/// The task group always completes its pull child before the box is reused.
private final class TTSChunkIteratorBox: @unchecked Sendable {
    private var iterator: TTSAudioChunkStream.Iterator
    init(_ iterator: TTSAudioChunkStream.Iterator) { self.iterator = iterator }
    func next() async throws -> TTSAudioChunk? { try await iterator.next() }
}

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isPaused = false
    @Published private(set) var speakingText: String?
    @Published private(set) var failureKey: String?
    @Published private(set) var failedText: String?
    @Published private(set) var activeOwnerID: UUID?
    @Published private(set) var failureOwnerID: UUID?
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
    /// Parked once the supply holds its bounded lead and no buffer has
    /// finished playing yet; resumed by a played buffer, stop, or cancellation.
    private var supplyWaiter: CheckedContinuation<Void, Error>?
    private var ownsAudioSession = false
    private var lastManualText: String?
    private var receivedCharacters = 0
    private var currentReadText = ""
    private var manualMessageText: String?
    private var playerSampleRate: Double?
    private var retrySettings: TTSSettingsSnapshot?
    private var retryOwnerID: UUID?
    private var notifications = Set<AnyCancellable>()
    private var localRuntime: LocalSpeechRuntime?
    private var localSessionID: UUID?
    private(set) var activeLocalModelID: String?
    /// Supply owned by the current utterance; played callbacks update played
    /// progress here without capturing the supply across actor boundaries.
    private var activeSupply: SpeechPlaybackSupply?
    /// Bounds the wait for the first audible buffer after priming.
    private var playoutWatchdog: Task<Void, Never>?

    /// Per-utterance playback state shared across its ordered segments.
    @MainActor
    private final class UtterancePlayback {
        var supply: SpeechPlaybackSupply?
    }

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
                    let owner = self.activeOwnerID
                    self.stop()
                    self.failedText = text
                    self.failureOwnerID = owner
                    self.failureKey = "voice.error.playback"
                }
            }.store(in: &notifications)
    }

    func configure(settings: TTSSettingsService, speech: TTSSpeechService, localRuntime: LocalSpeechRuntime? = nil) {
        self.settings = settings
        self.speech = speech
        self.localRuntime = localRuntime
    }

    func speak(_ text: String, ownerID: UUID? = nil) {
        if isSpeaking, activeOwnerID == ownerID, let speakingText, AnswerSpeechText.plainText(speakingText) == AnswerSpeechText.plainText(text) { stop(); return }
        preview(text, settings: settings?.snapshot ?? .systemDefault, ownerID: ownerID)
    }

    func preview(_ text: String, settings: TTSSettingsSnapshot, credential: String? = nil, ownerID: UUID? = nil) {
        let handle = beginStream(id: ownerID ?? UUID(), override: settings, credential: credential)
        lastManualText = text
        manualMessageText = text
        speakingText = text
        handle.append(AnswerSpeechText.plainText(text))
        handle.finish()
    }

    func retry() {
        if let text = lastManualText, let settings = retrySettings { preview(text, settings: settings, ownerID: retryOwnerID) }
    }

    func useSystemVoice() {
        guard let lastManualText else { return }
        speakSystem(lastManualText)
    }

    private func speakSystem(_ text: String) {
        let handle = beginStream(id: retryOwnerID ?? UUID(), override: .systemDefault)
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
        failureOwnerID = nil
        activeOwnerID = logicalID
        retryOwnerID = logicalID
        currentReadText = ""
        manualMessageText = nil
        generation = id
        guard let settings, let speech else {
            finishPlayback()
            failureOwnerID = logicalID
            failureKey = "voice.error.configuration"
            return TTSSpeechStreamHandle(append: { _ in }, finish: {}, cancel: {})
        }
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
                let playback = UtterancePlayback()
                for await addition in texts {
                    try Task.checkCancellation()
                    for segment in segmenter.append(addition) {
                        try await self.play(segment, index: index, owner: id, source: source, playback: playback)
                        index += 1
                    }
                }
                for segment in segmenter.finish() {
                    try Task.checkCancellation()
                    try await self.play(segment, index: index, owner: id, source: source, playback: playback)
                    index += 1
                }
                // The answer is complete only when every scheduled buffer has
                // actually been played, so progress and speaking state track
                // audible output rather than generation.
                try await self.drainUtterance(playback, owner: id)
                if generation == id { finishPlayback() }
            } catch {
                guard generation == id else { return }
                let cancelled = Task.isCancelled || error is CancellationError || (error as? TTSSynthesisError) == .cancelled
                finishPlayback()
                if !cancelled {
                    if error is SpeechPlaybackFailure {
                        FloeLogger(category: .providers).warning("speechPlaybackStalled key=\(SpeechFailureCopy.key(for: error))")
                    }
                    failureKey = SpeechFailureCopy.key(for: error)
                    failedText = lastManualText
                    failureOwnerID = logicalID
                }
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
                    self.failureOwnerID = logicalID
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
            isPaused = false
            player?.play()
        } catch {
            let text = lastManualText
            let owner = activeOwnerID
            stop()
            failedText = text
            failureOwnerID = owner
            failureKey = "voice.error.playback"
        }
    }

    func stopAndWait() async {
        let id = localSessionID
        let stoppedTask = task
        stop()
        await stoppedTask?.value
        if let id, let localRuntime { await localRuntime.endSession(id) }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        input?.finish(); input = nil
        finishPlayback()
        clearFailure()
    }

    func clearFailure(ownerID: UUID? = nil) {
        guard ownerID == nil || failureOwnerID == ownerID else { return }
        failureKey = nil
        failedText = nil
        failureOwnerID = nil
    }

    /// Keep foreground state through an active run so background retirement
    /// happens after that run ends, without unloading underneath playback.
    func setLocalSpeechForeground(_ isForeground: Bool) async {
        await localRuntime?.setForeground(isForeground)
    }

    /// Pack replacement/deletion handshake: stop, join the ended session and
    /// release the warm lease so the store no longer reports the pack busy.
    func releaseLocalModelForPackManagement() async {
        await stopAndWait()
        await localRuntime?.releaseForPackManagement()
    }

    private func finishPlayback() {
        isPreparing = false
        activeOwnerID = nil
        activeLocalModelID = nil
        if let localSessionID, let localRuntime {
            self.localSessionID = nil
            Task { await localRuntime.endSession(localSessionID) }
        }
        let waiter = supplyWaiter
        supplyWaiter = nil
        waiter?.resume(throwing: CancellationError())
        activeSupply = nil
        playoutWatchdog?.cancel()
        playoutWatchdog = nil
        player?.stop()
        engine?.stop()
        player = nil; engine = nil; playerSampleRate = nil
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
        // Playback starts from the supply once a bounded lead is queued.
        return player
    }

    /// Synthesize one ordered segment and feed the utterance supply. Returns
    /// as soon as the segment's audio is fully generated and scheduled, so the
    /// next segment starts generating while this one is still playing.
    private func play(_ text: String, index: Int, owner: UUID,
                      source: ConfiguredTTSSpeechSource, playback: UtterancePlayback) async throws {
        let prepared = source.synthesize(text: text, sessionID: owner, segmentIndex: index)
        // Deterministic close on every exit (cancel, failure, stall, EOF): an
        // abandoned forwarding channel would otherwise leave its producer
        // parked and wedge the next utterance's session join.
        defer { prepared.closeStream() }
        playback.supply?.resetSegmentFinal()
        let iterator = TTSChunkIteratorBox(prepared.stream.makeAsyncIterator())
        var sawFinal = false
        var sequence = -1
        var sampleRate: Int?
        var audioBytes = 0
        while true {
            // Schedule whatever the lead can hold before waiting for playback:
            // the pending queue must never depend on a *new* chunk arriving,
            // otherwise a full lead plus unscheduled pending could deadlock
            // against an empty player.
            if let supply = playback.supply {
                try await flush(supply, owner: owner, final: supply.ended)
                // The lead is full: only a finished buffer can open room.
                if !supply.canScheduleMore {
                    try await waitForPlayedProgress(owner: owner, supply: supply)
                }
            }
            let firstChunk = sequence < 0
            guard let chunk = try await Self.nextChunk(iterator,
                deadline: firstChunk ? SpeechSupplyDeadline.firstChunk : SpeechSupplyDeadline.nextChunk,
                phase: firstChunk ? "firstChunk" : "stream") else { break }
            try Task.checkCancellation()
            guard generation == owner, chunk.sessionID == owner, chunk.segmentIndex == index,
                  chunk.sequence > sequence, !sawFinal,
                  (8_000...192_000).contains(chunk.sampleRate),
                  sampleRate == nil || sampleRate == chunk.sampleRate,
                  chunk.pcm.count <= 256_000 else {
                throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider)
            }
            sequence = chunk.sequence
            sampleRate = chunk.sampleRate
            audioBytes += chunk.pcm.count
            guard audioBytes <= 8 * 1024 * 1024 else { throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider) }
            let supply = try supply(for: playback, sampleRate: chunk.sampleRate)
            supply.append(chunk.pcm)
            if chunk.isFinal { sawFinal = true; supply.markSegmentFinal() }
            try await flush(supply, owner: owner, final: sawFinal)
        }
        guard sawFinal, audioBytes > 0, playback.supply?.carry == nil else {
            throw TTSSynthesisError.streamTruncated(provider: source.snapshot.provider)
        }
    }

    private func supply(for playback: UtterancePlayback, sampleRate: Int) throws -> SpeechPlaybackSupply {
        if let supply = playback.supply {
            guard Int(supply.sampleRate) == sampleRate else {
                throw TTSSynthesisError.invalidConfiguration("Audio format changed")
            }
            return supply
        }
        _ = try preparePlayer(sampleRate: Double(sampleRate))
        let supply = try SpeechPlaybackSupply(sampleRate: Double(sampleRate))
        playback.supply = supply
        activeSupply = supply
        return supply
    }

    /// Hand ready batches to the player while respecting the bounded lead.
    /// Returns immediately when the lead is full; the remaining pending audio
    /// stays in the supply and is drained as playback progresses.
    private func flush(_ supply: SpeechPlaybackSupply, owner: UUID, final: Bool) async throws {
        while supply.hasSchedulableAudio {
            guard let frames = supply.takeScheduleFrames(final: final) else { break }
            try schedule(supply.takeBytes(frames: frames), frames: frames, supply: supply, owner: owner)
        }
        startPlaybackIfReady(supply)
    }

    private func startPlaybackIfReady(_ supply: SpeechPlaybackSupply) {
        guard supply.canStartPlayback, !isPaused, let player else { return }
        supply.markPrimed()
        player.play()
        armPlayoutWatchdog(supply)
        FloeLogger(category: .providers).debug(
            "speechPlaybackPrimed seconds=\(String(format: "%.2f", supply.seconds(supply.scheduledFrames)))")
    }

    /// A primed player that never reports one played buffer would otherwise
    /// leave a silent "speaking" state with no recovery; surface it as a
    /// playback failure. A user pause is not a stall.
    private func armPlayoutWatchdog(_ supply: SpeechPlaybackSupply) {
        playoutWatchdog?.cancel()
        playoutWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SpeechSupplyDeadline.firstPlayout)
                guard !Task.isCancelled, let self else { return }
                if self.isPaused { continue }
                guard supply.primed, supply.playedFrames == 0, !supply.isDrained, self.isSpeaking else { return }
                let text = self.lastManualText
                let owner = self.activeOwnerID
                self.generation = UUID()
                self.finishPlayback()
                self.failedText = text
                self.failureOwnerID = owner
                self.failureKey = "voice.error.playback"
                FloeLogger(category: .providers).warning("speechPlaybackStalled key=voice.error.playback phase=playout")
                return
            }
        }
    }

    private func schedule(_ bytes: [UInt8], frames: Int, supply: SpeechPlaybackSupply, owner: UUID) throws {
        guard frames > 0, let player, bytes.count >= frames * 2 else { throw CancellationError() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: supply.format, frameCapacity: AVAudioFrameCount(frames)),
              let floats = buffer.floatChannelData?[0] else { throw CancellationError() }
        buffer.frameLength = AVAudioFrameCount(frames)
        for offset in 0..<frames {
            let value = UInt16(bytes[offset * 2]) | UInt16(bytes[offset * 2 + 1]) << 8
            floats[offset] = Float(Int16(bitPattern: value)) / 32768
        }
        if supply.isStarving {
            // Diagnostics only: a refill after starvation explains an audible gap.
            FloeLogger(category: .providers).debug("speechPlaybackRefill seconds=\(String(format: "%.2f", supply.seconds(frames)))")
        }
        supply.didSchedule(frames: frames)
        isPreparing = false
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == owner else { return }
                self.activeSupply?.didPlay(frames: frames)
                self.releaseSupplyWaiter()
            }
        }
    }

    /// Suspend until a scheduled buffer actually finishes playing.
    ///
    /// Played frames only advance from the player's completion callback on the
    /// MainActor, so a drain/pull loop must always yield here rather than
    /// re-evaluating a scheduling predicate: a predicate that is already true
    /// (pending audio with lead room) would spin forever and starve the very
    /// callback that updates `playedFrames`. Registration re-checks the
    /// baseline so a completion that landed in the same MainActor turn cannot
    /// strand the waiter; stop/cancel paths resume it through `finishPlayback`.
    private func waitForPlayedProgress(owner: UUID, supply: SpeechPlaybackSupply) async throws {
        let baseline = supply.playedFrames
        guard generation == owner, !Task.isCancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard generation == owner, !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            if supply.playedFrames != baseline { continuation.resume(); return }
            supplyWaiter = continuation
        }
        try Task.checkCancellation()
    }

    private func releaseSupplyWaiter() {
        let waiter = supplyWaiter
        supplyWaiter = nil
        waiter?.resume()
    }

    /// Play out every scheduled buffer of a completed answer before the
    /// player is torn down, tracking real played progress.
    private func drainUtterance(_ playback: UtterancePlayback, owner: UUID) async throws {
        guard let supply = playback.supply else { return }
        supply.markEnded()
        while !supply.isDrained {
            // Hand over everything the bounded lead holds, including a short
            // final batch; the remainder stays pending for the next round.
            while supply.hasSchedulableAudio {
                guard let frames = supply.takeScheduleFrames(final: supply.ended) else { break }
                try schedule(supply.takeBytes(frames: frames), frames: frames, supply: supply, owner: owner)
            }
            startPlaybackIfReady(supply)
            if supply.isDrained { return }
            // No audio will ever be scheduled in this answer (nothing was
            // generated that converts to samples): never wait on playout.
            if supply.scheduledFrames == 0 { return }
            // Everything ready is already in the player; only a played buffer
            // can advance the loop. Suspending here is what lets the MainActor
            // run the completion callback that updates played progress.
            try await waitForPlayedProgress(owner: owner, supply: supply)
        }
    }

    /// Race one stream pull against a bounded supply deadline. On timeout the
    /// group cancels the parked pull, which closes the provider channel and
    /// unwinds its producer instead of leaving the spinner running forever.
    private static func nextChunk(_ box: TTSChunkIteratorBox, deadline: Duration,
                                  phase: String) async throws -> TTSAudioChunk? {
        try await withThrowingTaskGroup(of: TTSAudioChunk?.self) { group in
            group.addTask { try await box.next() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw phase == "firstChunk" ? SpeechPlaybackFailure.firstChunkTimeout : SpeechPlaybackFailure.supplyStalled
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SpeechPlaybackFailure.supplyStalled }
            return first
        }
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
        if error is SpeechPlaybackFailure { return "voice.error.playback" }
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
            case .thermal: return "voice.local.error.thermal"
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
