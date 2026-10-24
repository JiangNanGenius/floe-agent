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
    case captureBusy
}

enum SpeechRecoveryAction: Equatable {
    case pause
    case none
}

/// Pure decision for a live `AVAudioSession` interruption/route notification.
/// Accepted product rule (shared with continuous voice): a system event may
/// PAUSE output, but nothing ever auto-resumes — the utterance stays in an
/// honest, actionable paused state until the USER resumes or stops it.
/// Ordinary chat read-aloud follows the SAME rule; no different documented
/// behaviour exists that would license auto-play through a newly
/// connected/disconnected route.
enum SpeechSessionRecovery {
    static func interruptionAction(typeRaw: UInt?, isSpeaking: Bool) -> SpeechRecoveryAction {
        guard isSpeaking, let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return .none }
        switch type {
        case .began:
            return .pause
        default:
            // `.ended` deliberately keeps the pause (user-resume rule).
            return .none
        }
    }

    static func routeAction(reasonRaw: UInt?, isSpeaking: Bool) -> SpeechRecoveryAction {
        guard isSpeaking, let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return .none }
        switch reason {
        case .oldDeviceUnavailable:
            return .pause
        default:
            // `.newDeviceAvailable` never auto-plays into the new route;
            // `.categoryChange` and friends belong to the engine
            // configuration observer, not to pausing.
            return .none
        }
    }
}



/// Route admission for the shared `AVAudioSession`, decided from ACTUAL
/// holder registrations in `FloeAudioSessionOwnership` (never from the
/// category alone): a stale `.playAndRecord` left by a finished capture has
/// no live holder and still needs real activation. Adopting a genuinely live
/// record route lets chat/preview playout share it instead of overriding the
/// category mid-capture — an override at that moment can silence the other
/// component's input path mid-stretch. The ledger still decides teardown
/// deactivation (last holder only), and this utterance ALWAYS holds its own
/// claim while playing, so a concurrent capture teardown cannot deactivate
/// the session under adopted speech. A `.record`/`.measurement` dictation
/// route is never adopted: its receiver-style output would make an answer
/// inaudible. A live exclusive capture must finish before playback starts;
/// a stale category with no holder can be reconfigured normally.
enum SpeechSessionAdmission {
    static func rejectsExclusiveCapture(category: AVAudioSession.Category, holdersBeforeClaim: Int) -> Bool {
        category == .record && holdersBeforeClaim > 0
    }

    static func isRecordRoute(category: AVAudioSession.Category) -> Bool {
        category == .playAndRecord || category == .multiRoute
    }
    /// `holdersBeforeClaim` is the count `claim` returned under the registry
    /// lock BEFORE this component's insertion — the only race-free liveness
    /// fact. Adoption keeps the route's CATEGORY; activation of our own claim
    /// is unconditional, so a stale record route is never silently adopted.
    static func adoptsExistingSession(recordRoute: Bool, holdersBeforeClaim: Int) -> Bool {
        recordRoute && holdersBeforeClaim > 0
    }
}

/// Bounded playout-progress sampler for one utterance. Reports a stall only
/// for the never-paused dead-output case the previous one-shot watchdog
/// missed: the pipeline is ENGAGED (playback primed, or a parked supply whose
/// bounded lead can no longer grow) yet no played-buffer receipt advanced
/// across a full watch window — including AFTER the first buffer played, so
/// a mid-utterance engine death can no longer spin silently forever.
/// A paused utterance (user- OR system-caused) is an honest actionable state
/// under the accepted user-resume rule: it is never reported as a stall.
struct SpeechPlayoutProgressMonitor {
    private var lastPlayedFrames = 0

    /// `true` when the utterance must be failed as a playout stall.
    mutating func observe(scheduledFrames: Int, playedFrames: Int, engaged: Bool,
                          paused: Bool) -> Bool {
        if paused { return false }
        guard engaged, scheduledFrames > 0 else { return false }
        let stalled = playedFrames == lastPlayedFrames
        lastPlayedFrames = playedFrames
        return stalled
    }
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
    /// Playback-side rate/pitch effect for THIS utterance. Built only when the
    /// frozen controls are non-neutral, so an unchanged setting keeps exactly
    /// the historical direct player → mixer edge (and its cost/behavior).
    private var speechEffect: SpeechPlaybackEffectGraph?
    /// Frozen once per utterance from `TTSSettingsSnapshot.playbackControls`
    /// (the same value the contract's stream carrier exposes) BEFORE the
    /// first buffer is scheduled; a settings change can never retune an
    /// answer already playing. Every ordered segment of the answer shares it.
    private var utterancePlaybackControls = VoicePlaybackControls.neutral
    /// REAL mixer-rendered output-frame clock, used only for the final-tail
    /// settle. Nil on the neutral direct edge.
    private var outputMeter: SpeechPlaybackOutputMeter?
    private var input: AsyncStream<String>.Continuation?
    /// Parked once the supply holds its bounded lead and no buffer has
    /// finished playing yet; resumed by a played buffer, stop, or cancellation.
    private var supplyWaiter: CheckedContinuation<Void, Error>?
    /// This utterance's claim in the process-wide `FloeAudioSessionOwnership`
    /// ledger (shared with dictation capture and continuous voice). Claimed
    /// for EVERY utterance — including one that keeps a live record route's
    /// category — so no concurrent teardown can deactivate the session
    /// underneath adopted speech. On teardown the claim is released through
    /// the atomic `releaseAndDeactivateLast`, which deactivates the shared
    /// session only when this release removed the LAST holder, serialised
    /// against claims inside the registry lock.
    private var audioSessionClaimID: UUID?
    /// Engine configuration-change observer for the CURRENT player only;
    /// cleared whenever the graph is torn down or rebuilt.
    private var configurationNotifications = Set<AnyCancellable>()
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
                let typeRaw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Accepted product rule: system events may PAUSE output;
                    // only the USER resumes. `.ended` deliberately keeps the
                    // honest paused state instead of auto-playing over it.
                    if SpeechSessionRecovery.interruptionAction(typeRaw: typeRaw, isSpeaking: self.isSpeaking) == .pause {
                        self.pause()
                    }
                }
            }.store(in: &notifications)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if SpeechSessionRecovery.routeAction(reasonRaw: reasonRaw, isSpeaking: self.isSpeaking) == .pause {
                        self.pause()
                    }
                }
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
        // "Use System Voice" switches ONLY the source to Apple: it keeps the
        // failed utterance's frozen rate/pitch (and its reading/barge
        // preferences), never reuses a cloud credential, billing route,
        // endpoint, model or voice, and never auto-selects another provider.
        // `retrySettings` is the frozen snapshot of the failed utterance;
        // current settings are the honest fallback when no failure is live.
        let base = retrySettings ?? settings?.snapshot ?? .systemDefault
        let handle = beginStream(id: retryOwnerID ?? UUID(), override: Self.systemVoiceFallback(from: base))
        lastManualText = text
        manualMessageText = text
        speakingText = text
        handle.append(AnswerSpeechText.plainText(text))
        handle.finish()
    }

    /// Pure fallback policy (host/App-testable): Apple system voice with the
    /// SAME frozen playback controls, and none of the cloud route's identity.
    /// An already-Apple snapshot keeps its system voice/model selection; a
    /// cloud/local snapshot's voice and model IDs are NOT reused (they name a
    /// different provider's catalogue).
    nonisolated static func systemVoiceFallback(from base: TTSSettingsSnapshot) -> TTSSettingsSnapshot {
        let alreadySystemVoice = base.provider == .apple
        return TTSSettingsSnapshot(
            provider: .apple,
            billingRoute: .payAsYouGo,
            modelID: alreadySystemVoice ? base.modelID : "",
            voiceID: alreadySystemVoice ? base.voiceID : "",
            speechRateRatio: base.speechRateRatio,
            speechPitchSemitones: base.speechPitchSemitones,
            autoReadEnabled: base.autoReadEnabled,
            allowBargeIn: base.allowBargeIn,
            language: base.language)
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
        // Freeze the user's playback rate/intonation for the WHOLE utterance
        // before any audio is scheduled. The configured source generates the
        // provider request at rate 1.0, so this effect is the single
        // application of the user rate (no double rate, no provider pitch).
        utterancePlaybackControls = VoicePlaybackControls(frozen.playbackControls)
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
                // Every synthesis request downstream carries at least one
                // COMPLETE sentence: the segmenter never flushes on commas,
                // colons, semicolons, spaces or line breaks and never
                // force-cuts, so fragments/partial words cannot reach a TTS
                // model. The trailing unpunctuated answer/title/table tail is
                // emitted exactly once by `finish()`.
                var segmenter = TTSTextSegmenter(policy: .completeSentences)
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
                    FloeLogger(category: .providers).warning(
                        "speechSynthesisFailed key=\(SpeechFailureCopy.key(for: error)) detail=\(SpeechFailureCopy.diagnostic(for: error))")
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

    /// Pauses the live utterance — from the user's pause control OR from a
    /// system interruption/route event. Either way the utterance stays in an
    /// honest paused state and ONLY `resume()` (a user action) continues it:
    /// no interruption-end or newly available device auto-plays over the
    /// user's decision (accepted product rule, shared with continuous voice).
    func pause() {
        guard isSpeaking else { return }
        player?.pause()
        isPaused = true
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        do {
            if let engine, !engine.isRunning {
                // Re-asserting activation is legal only while this utterance
                // still holds its registry claim (shared-session contract).
                if let claimID = audioSessionClaimID,
                   FloeAudioSessionOwnership.isHolder(claimID) {
                    try AVAudioSession.sharedInstance().setActive(true)
                }
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
        // Tear down the per-utterance output graph before the engine objects
        // are discarded. Removing the tap first prevents any render callback
        // from touching a meter that is about to disappear; detaching the unit
        // discards its held look-ahead together with the engine. A later
        // utterance builds a fresh graph from ITS frozen controls.
        outputMeter?.remove()
        outputMeter = nil
        speechEffect?.uninstall()
        speechEffect = nil
        utterancePlaybackControls = .neutral
        configurationNotifications.removeAll()
        player = nil; engine = nil; playerSampleRate = nil
        if let claimID = audioSessionClaimID {
            audioSessionClaimID = nil
            // Ledger rule (atomic): deactivate the process-wide session ONLY
            // when this release removes the LAST holder, serialised against
            // `claim` inside the registry lock — a newer component's claim
            // queues behind the deactivation and re-activates, so a stale
            // teardown can never silence a newer owner, and a still-held
            // release (live capture or voice stack) never deactivates.
            FloeAudioSessionOwnership.releaseAndDeactivateLast(claimID) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
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
        // Always claim: chat/preview playback counts as a session borrower,
        // so a concurrent capture teardown can never deactivate the shared
        // session underneath adopted speech. `claim` returns the holder count
        // BEFORE insertion under the same lock that serialises every
        // last-holder deactivation — that returned fact, not a separate
        // count read, decides adoption (an independent read could race the
        // last holder's teardown between the two operations).
        let claimID = UUID()
        let holdersBeforeClaim = FloeAudioSessionOwnership.claim(claimID)
        audioSessionClaimID = claimID
        var activatedByUs = false
        do {
            guard !SpeechSessionAdmission.rejectsExclusiveCapture(category: session.category, holdersBeforeClaim: holdersBeforeClaim) else {
                throw SpeechPlaybackFailure.captureBusy
            }
            if !SpeechSessionAdmission.adoptsExistingSession(
                recordRoute: SpeechSessionAdmission.isRecordRoute(category: session.category),
                holdersBeforeClaim: holdersBeforeClaim) {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            // Activation ALWAYS happens for our own claim — including when the
            // record route's category is retained — so a stale or already
            // deactivated route can never be silently adopted.
            try session.setActive(true)
            activatedByUs = true
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw CancellationError() }
            engine.attach(player)
            // Final-output DSP: the frozen controls decide the graph ONCE,
            // before `start()`. Non-neutral builds player → timePitch → mixer
            // (one application of rate + semitone pitch); neutral keeps the
            // direct historical edge, so unchanged settings behave exactly as
            // before and install no effect/meter at all.
            let controls = utterancePlaybackControls
            var effect: SpeechPlaybackEffectGraph?
            if controls.isNeutral {
                engine.connect(player, to: engine.mainMixerNode, format: format)
            } else {
                let graph = SpeechPlaybackEffectGraph(controls: controls)
                graph.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
                effect = graph
            }
            self.engine = engine; self.player = player; playerSampleRate = sampleRate
            self.speechEffect = effect
            if effect != nil {
                // Count REAL rendered output frames for the final-tail settle.
                // The tap uses the MIXER's actual output format (44.1/48 kHz
                // stereo on hardware), not the provider's 24 kHz mono PCM.
                let meter = SpeechPlaybackOutputMeter()
                meter.install(on: engine.mainMixerNode)
                self.outputMeter = meter
            }
            try engine.start()
            observeEngineConfiguration(engine)
            // Playback starts from the supply once a bounded lead is queued.
            return player
        } catch {
            if !activatedByUs {
                // Rollback for a component that never brought the session up:
                // release WITHOUT deactivation (ledger contract); the later
                // finishPlayback then has no claim left to act on.
                FloeAudioSessionOwnership.release(claimID)
                audioSessionClaimID = nil
            }
            // If activation itself succeeded (e.g. only `engine.start()`
            // failed), the claim stays registered so finishPlayback performs
            // the last-holder deactivation.
            throw error
        }
    }

    /// A route, device or sample-rate change takes the engine away from under
    /// a running utterance (the engine stops and `.dataPlayedBack` receipts
    /// never arrive — the silent-forever state). Restart the graph in place;
    /// if the output really is dead, the playout monitor surfaces the stall.
    private func observeEngineConfiguration(_ engine: AVAudioEngine) {
        configurationNotifications.removeAll()
        // Capture only Sendable facts (identity + this utterance's generation):
        // a notification queued for THIS engine must never be able to act on
        // a rebuilt graph. Without both fences, an old-player notification
        // delivered after `receive(on: .main)` could restart or play the NEW
        // utterance's player and bypass its supply priming.
        let identity = ObjectIdentifier(engine)
        let owner = generation
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)
            .filter { ($0.object as? AVAudioEngine).map { ObjectIdentifier($0) == identity } ?? false }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restartEngineAfterConfigurationChange(identity: identity, owner: owner)
                }
            }
            .store(in: &configurationNotifications)
    }

    private func restartEngineAfterConfigurationChange(identity: ObjectIdentifier, owner: UUID) {
        // Fence 1: still the same utterance generation.
        // Fence 2: the CURRENT engine is still the engine this observer was
        // registered for — a late notification for a replaced graph is inert.
        guard isSpeaking, generation == owner, let engine,
              ObjectIdentifier(engine) == identity, let player = self.player else { return }
        FloeLogger(category: .providers).debug("speechEngineConfigChanged running=\(engine.isRunning)")
        do {
            if !engine.isRunning {
                // In-place recovery may re-assert activation only while this
                // utterance still holds its registry claim (contract rule 3).
                if let claimID = audioSessionClaimID,
                   FloeAudioSessionOwnership.isHolder(claimID) {
                    try AVAudioSession.sharedInstance().setActive(true)
                }
                try engine.start()
            }
            // The supply owns playback START. Only a pipeline that had already
            // primed resumes here — and never over a pause: an unprimed engine
            // recovery must not bypass the bounded-lead priming, and a paused
            // utterance stays paused until the user resumes it.
            if !isPaused, let supply = activeSupply, supply.primed {
                player.play()
            }
        } catch {
            surfacePlayoutStall(phase: "engineConfig")
        }
    }

    private func surfacePlayoutStall(phase: String) {
        let text = lastManualText
        let owner = activeOwnerID
        generation = UUID()
        finishPlayback()
        failedText = text
        failureOwnerID = owner
        failureKey = "voice.error.playback"
        FloeLogger(category: .providers).warning("speechPlaybackStalled key=voice.error.playback phase=\(phase)")
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

    /// A primed (or fully parked) player that stops reporting played buffers
    /// would otherwise leave a silent "speaking" state with no recovery —
    /// including mid-utterance engine death, which the previous one-shot
    /// pre-playout watchdog never covered. Surface it as a playback failure.
    /// A user pause is not a stall; a system pause is bounded.
    private func armPlayoutWatchdog(_ supply: SpeechPlaybackSupply) {
        playoutWatchdog?.cancel()
        startPlayoutWatchdog(supply)
    }

    /// A parked drain/pull must have a progress sentinel even when playback
    /// was never primed (a pause before priming blocks `player.play()`, and
    /// the lead can then fill without any watchdog existing).
    private func ensurePlayoutWatchdog(_ supply: SpeechPlaybackSupply) {
        guard playoutWatchdog == nil else { return }
        startPlayoutWatchdog(supply)
    }

    private func startPlayoutWatchdog(_ supply: SpeechPlaybackSupply) {
        playoutWatchdog = Task { [weak self] in
            var monitor = SpeechPlayoutProgressMonitor()
            while !Task.isCancelled {
                try? await Task.sleep(for: SpeechSupplyDeadline.firstPlayout)
                guard !Task.isCancelled, let self, self.isSpeaking, !supply.isDrained else { return }
                let stalled = monitor.observe(
                    scheduledFrames: supply.scheduledFrames,
                    playedFrames: supply.playedFrames,
                    engaged: supply.primed || !supply.canScheduleMore,
                    paused: self.isPaused)
                guard stalled else { continue }
                self.surfacePlayoutStall(phase: "playout")
                return
            }
        }
    }

    /// Builds the float32 mono schedule buffer from s16le little-endian bytes.
    /// Internal and device-free so the byte order, frame count and channel
    /// layout are covered by deterministic tests.
    static func speechBuffer(_ bytes: [UInt8], frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frames > 0, bytes.count >= frames * 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let floats = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for offset in 0..<frames {
            let value = UInt16(bytes[offset * 2]) | UInt16(bytes[offset * 2 + 1]) << 8
            floats[offset] = Float(Int16(bitPattern: value)) / 32768
        }
        return buffer
    }

    private func schedule(_ bytes: [UInt8], frames: Int, supply: SpeechPlaybackSupply, owner: UUID) throws {
        // A missing player means the graph was already torn down (stop):
        // cancellation is the honest classification. An unbuildable buffer
        // with a live player is a real playback defect and must surface —
        // classifying it as a cancellation would hide it as "no sound, no
        // error".
        guard frames > 0, let player else { throw CancellationError() }
        guard let buffer = Self.speechBuffer(bytes, frames: frames, format: supply.format) else {
            throw TTSSynthesisError.invalidConfiguration("Playback buffer unavailable")
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
        // A suspension whose only progress source is a played-buffer receipt
        // must never be unwatched: if playback was never primed (paused before
        // priming, dead route), this is the last checkpoint before an
        // otherwise permanent silent wait.
        ensurePlayoutWatchdog(supply)
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
    /// player is torn down, tracking real played progress, then let the
    /// output effect drain its held look-ahead on the REAL render clock.
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
            if supply.isDrained { break }
            // No audio will ever be scheduled in this answer (nothing was
            // generated that converts to samples): never wait on playout.
            if supply.scheduledFrames == 0 { return }
            // Everything ready is already in the player; only a played buffer
            // can advance the loop. Suspending here is what lets the MainActor
            // run the completion callback that updates played progress.
            try await waitForPlayedProgress(owner: owner, supply: supply)
        }
        try await settleRenderedTail(owner: owner)
    }

    /// The player's last `.dataPlayedBack` proves INPUT consumption only: a
    /// downstream `AVAudioUnitTimePitch` still holds its look-ahead, so
    /// tearing the graph down at that instant clips the final syllable
    /// (measured ≤ 25.4 ms at 24/48 kHz across the contract range). For a
    /// non-neutral utterance, wait for enough REAL mixer-rendered frames to
    /// have been produced after the last receipt to flush that look-ahead.
    ///
    /// This is a frame-clock wait, not a wall-clock sleep and not a content
    /// census: quiet speech, pauses and zero crossings are legitimate, so no
    /// non-silent sample count is compared against a total. `deadline` only
    /// bounds a dead render pipeline; if it is ever hit, the diagnostic is an
    /// honest "render did not advance" classification. Neutral utterances
    /// return immediately — their direct edge is unchanged.
    private func settleRenderedTail(owner: UUID) async throws {
        guard generation == owner, let meter = outputMeter, let effect = speechEffect else { return }
        guard !effect.appliedControls.isNeutral,
              let supply = activeSupply, supply.scheduledFrames > 0 else { return }
        let sampleRate = meter.sampleRate > 0
            ? meter.sampleRate
            : (engine?.mainMixerNode.outputFormat(forBus: 0).sampleRate ?? supply.sampleRate)
        let required = SpeechPlaybackEffectRender.drainFrameCount(
            nodeLatencySeconds: effect.reportedLatencySeconds, sampleRate: sampleRate)
        let deadline = SpeechPlaybackEffectRender.drainBoundSeconds(
            nodeLatencySeconds: effect.reportedLatencySeconds) + 0.30
        let baseline = meter.outputFrames
        let settled = await meter.settleTail(
            baseline: baseline,
            requiredFrames: required,
            deadline: deadline,
            pollInterval: 0.005,
            isPaused: { [weak self] in self?.isPaused ?? false })
        guard generation == owner else { return }
        if !settled {
            // Real, actionable classification for a render clock that never
            // advanced. A healthily playing output reaches the frame target;
            // quiet audio does not change the frame count and never lands here.
            FloeLogger(category: .providers).warning(
                "speechPlaybackTailUnsettled rendered=\(meter.outputFrames - baseline) required=\(required) rate=\(Int(sampleRate))")
        }
        try Task.checkCancellation()
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
        result = AnswerSpeechTableText.expanding(result)
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
        if let failure = error as? SpeechPlaybackFailure {
            switch failure {
            case .captureBusy: return "voice.error.capture_busy"
            case .firstChunkTimeout, .supplyStalled: return "voice.error.playback"
            }
        }
        if let failure = error as? LocalSpeechRuntime.Failure {
            switch failure {
            case .unsupportedDevice: return "voice.local.error.device"
            case .voice, .language: return "voice.error.configuration"
            case .invalidAudio: return "voice.error.playback"
            // Complete sentence beyond the model's real input/context limit:
            // recoverable, text preserved, no partial synthesis.
            case .sentenceTooLong: return "voice.error.too_long"
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
        case .invalidConfiguration, .providerRejected: return "voice.error.configuration"
        case .httpStatus(_, let statusCode, _):
            // 4xx (other than the auth/quota codes already classified above):
            // the service refused THIS request shape — checking the model and
            // voice is the actionable step, not "try again". 5xx is a service
            // fault; the generic retry copy stays honest.
            return statusCode < 500 ? "voice.error.configuration" : "voice.error.playback"
        default: return "voice.error.playback"
        }
    }

    /// One-token redacted diagnostic for device-log correlation: category,
    /// fixed numeric code and the sanitized trace ID only — never provider
    /// text, reason strings, endpoints or credentials.
    static func diagnostic(for error: Error) -> String {
        if let failure = error as? TTSSynthesisError {
            switch failure {
            case .credentialMissing(let provider, let route): return "credentialMissing:\(provider.rawValue).\(route.rawValue)"
            case .authentication(let provider, let route, let logID): return "authentication:\(provider.rawValue).\(route.rawValue):log=\(logID ?? "-")"
            case .quotaOrRateLimited(let provider, let route, let logID): return "quota:\(provider.rawValue).\(route.rawValue):log=\(logID ?? "-")"
            case .invalidConfiguration: return "invalidConfiguration"
            case .transport(let provider, let failure): return "transport:\(provider.rawValue).\(failure.rawValue)"
            case .httpStatus(let provider, let statusCode, let logID): return "httpStatus:\(provider.rawValue).\(statusCode):log=\(logID ?? "-")"
            case .providerRejected(let provider, let code, let logID): return "rejected:\(provider.rawValue).\(code.map(String.init) ?? "-"):log=\(logID ?? "-")"
            case .streamTruncated(let provider): return "truncated:\(provider.rawValue)"
            case .cancelled: return "cancelled"
            }
        }
        if let failure = error as? SpeechPlaybackFailure {
            return switch failure {
            case .captureBusy: "captureBusy"
            case .firstChunkTimeout, .supplyStalled: "playoutStall"
            }
        }
        return "other"
    }
}
#endif
