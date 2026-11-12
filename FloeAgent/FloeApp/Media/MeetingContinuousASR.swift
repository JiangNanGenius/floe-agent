// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeMeetings
import FloeMeetingsAV

/// W7 continuous meeting recognition: ONE live-ASR request domain chain fed
/// by the same PCM frames that the chunk recorder writes to disk. Speaker
/// numbering is truthful inside one domain (across storage chunk boundaries)
/// and never leaks across domains; every rotation/reconnect mints a fresh
/// scope while media time keeps flowing from the original frame counter.
///
/// Delivery contract with the capture pump: `offer` uses a short state lock,
/// a bounded buffer and creates no tasks. A slow provider only degrades THIS
/// transcription path — the pump, the lossless original and the AAC chunks
/// are never backpressured; uncovered ranges are transcribed later by the
/// existing file-chunk queue, deduplicated against the committed coverage.
final class MeetingContinuousASR: @unchecked Sendable {
    enum SealReason: Sendable, Equatable {
        case rotation, overflow, failure, stop
    }

    /// Internal rotation budget per request domain (~10.9 minutes of 16 kHz
    /// PCM16). This is an APP-side resource policy — it bounds one request's
    /// duration and memory and exercises domain rotation; it is NOT derived
    /// from a provider-documented live byte ceiling (the 25 MiB catalog
    /// constant governs FILE uploads only and says nothing about SAUC
    /// session totals). Sealing at this budget simply starts a new request
    /// domain; media time is unaffected.
    static let domainWireLimitBytes: Int64 = 20 * 1_024 * 1_024
    static let frameBufferCapacity = 128
    static let domainFinishTimeoutSeconds: Double = 30
    /// A normal stop should not keep the file fallback waiting for the full
    /// rotation deadline when the provider is already gone.
    static let stopTailTimeoutSeconds: Double = 10
    static let degradedRetryDelaySeconds: Double = 15
    /// Speech-like source energy. Aligned with the shared voice gate so quiet
    /// speech still counts while pure silence can never become a transcript.
    static let voicedRMSThreshold: Float = 0.002
    /// A provider final from a domain with less real voiced audio than this
    /// is a silence/noise hallucination candidate, not a committed utterance.
    static let minimumVoicedSeconds: Double = 0.1

    struct Metrics: Sendable {
        var domains = 0
        var reconnects = 0
        var droppedFrames = 0
        var silentUtterances = 0
        var lastError: String?
    }

    private let meetingID: MeetingID
    private let service: MeetingService
    private let route: MeetingLiveTranscriptionRoute
    private let onChange: @MainActor @Sendable () async -> Void
    private let onDiagnostic: @MainActor @Sendable (String) -> Void

    // Feed-side state (capture pump → lock only).
    private struct QueuedFrame {
        let frame: MeetingPCMFrame
        /// Exact original-frame coordinate at offer time, including gaps
        /// caused by later refused/discarded batches.
        let startFrame: Int64
    }
    private let lock = NSLock()
    private var buffer: [QueuedFrame] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var offeredFrames: Int64 = 0
    private var sourceRate: Double?
    private var overflowSealRequested = false
    private var pumpFinished = false
    private var cancelled = false
    private var coverage = MeetingCoverageMap()
    private var liveActive = false
    private var liveSession: CaptureSessionID?
    private var metrics = Metrics()

    // Engine-side state (single engine task only; the lease value is
    // captured before the task starts and then engine-owned).
    private var engine: Task<Void, Never>?
    private var currentSession: (any ASRLiveSession)?
    private var currentDomain: MeetingLiveASRDomain?
    private var eventBoxes: [UUID: DomainEventBox] = [:]
    private var resampler: MeetingPCMDownsampler?
    // Engine-owned measured voice activity for the CURRENT request domain.
    // It filters provider utterances that were placed in a silent tail even
    // when another part of the domain contained speech.
    private var voiceWindows: [Bool] = []
    private var voiceWindowRate: Double = 16_000
    private var voiceWindowSamples = 0
    private var voiceWindowVoiced = false
    private var voiceSourceSamples: Int64 = 0
    private var lease: LiveTranscriptionLease?
    private let wireLimitBytes: Int64
    private var consecutiveOpenFailures = 0
    private var reportedDegraded = false

    init(
        meetingID: MeetingID,
        service: MeetingService,
        route: MeetingLiveTranscriptionRoute,
        domainWireLimitBytes: Int64 = MeetingContinuousASR.domainWireLimitBytes,
        onChange: @escaping @MainActor @Sendable () async -> Void,
        onDiagnostic: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.meetingID = meetingID
        self.service = service
        self.route = route
        self.wireLimitBytes = max(4_096, domainWireLimitBytes)
        self.onChange = onChange
        self.onDiagnostic = onDiagnostic
        self.resampler = try? MeetingPCMDownsampler(targetSampleRate: 16_000)
    }

    deinit {
        lock.lock(); let parked = waiter; lock.unlock()
        parked?.resume()
    }

    // MARK: - Feed seam (capture pump; bounded, ordered)

    nonisolated func offer(_ frame: MeetingPCMFrame) {
        lock.lock()
        if cancelled || pumpFinished {
            lock.unlock()
            return
        }
        if sourceRate == nil { sourceRate = frame.sampleRate }
        if buffer.count >= Self.frameBufferCapacity {
            // Refuse the newest frame and ask for a domain seal. Mid-domain
            // wire audio must stay contiguous, so the overflow becomes a
            // clean boundary and the un-fed span is left for file fallback.
            metrics.droppedFrames &+= 1
            overflowSealRequested = true
        } else {
            buffer.append(QueuedFrame(frame: frame, startFrame: offeredFrames))
        }
        offeredFrames &+= Int64(frame.frameCount)
        let parked = waiter
        waiter = nil
        lock.unlock()
        parked?.resume()
    }

    /// Committed live coverage in capture media time. Read by the file queue
    /// to skip already-transcribed ranges after stop/degradation.
    nonisolated func coveredSnapshot() -> [MediaTimeRange] {
        lock.lock(); defer { lock.unlock() }
        return coverage.intervals
    }

    /// True while a live domain can still transcribe uncovered audio; the
    /// file queue holds its chunks while this is true and the capture runs.
    nonisolated var isLiveActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return liveActive
    }

    /// The capture session whose media timeline this live coverage belongs to.
    nonisolated var liveCaptureSession: CaptureSessionID? {
        lock.lock(); defer { lock.unlock() }
        return liveSession
    }

    nonisolated var metricsSnapshot: Metrics {
        lock.lock(); defer { lock.unlock() }
        return metrics
    }

    // MARK: - Lifecycle (MeetingProjectSession, MainActor)

    func start(captureSession: CaptureSessionID) async {
        let lease: LiveTranscriptionLease?
        do {
            lease = try await service.beginLiveTranscription(
                meeting: meetingID, session: captureSession)
        } catch {
            lease = nil
        }
        guard let lease else {
            lock.withLock {
                liveActive = false
                liveSession = nil
            }
            return
        }
        self.lease = lease
        lock.withLock { liveSession = captureSession }
        // Strong ownership for the engine lifetime: replacing the session's
        // coordinator while an old drain is still committing the final tail
        // must not deallocate the object (and leak its service lease). The
        // task releases the coordinator when the engine finishes.
        engine = Task { [self] in
            await runEngine(lease: lease)
        }
    }

    /// The capture pump delivered everything and stopped. The engine drains
    /// the buffered tail, commits the genuine finish tail of the last domain,
    /// then closes the lease. Concurrency with the capture controller is
    /// safe: the lease is exactly the trusted same-capture tail path.
    ///
    /// Joining here is the fence between the live tail and the file fallback:
    /// the chunk queue may only start covering gaps after every final of this
    /// capture has been offered to the database. The caller is normally the
    /// MainActor; awaiting the engine suspends it, so the engine's own
    /// `onChange` callback can re-enter that actor.
    func captureDidStop() async {
        let parked = lock.withLock {
            pumpFinished = true
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume()
        await engine?.value
    }

    /// Join a normally stopped coordinator without revoking its finish tail.
    func waitUntilFinished() async {
        await engine?.value
    }

    /// Cancellation/deletion fencing: the engine observes the flag, discards
    /// queued frames, cancels its session and closes the lease — no late
    /// writes, and only this coordinator's own workers are joined here.
    func cancelAndWait() async {
        let parked = lock.withLock {
            cancelled = true
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume()
        // Revoke before joining the engine: it may already be suspended in a
        // final's database call. Setting the pump flag alone cannot fence it.
        if let lease { await service.endLiveTranscription(lease) }
        if let engine {
            await engine.value
        }
    }

    // MARK: - Engine

    private enum Claim: Sendable {
        case frame(MeetingPCMFrame)
        case park
        case finish
        case sealOverflow
    }

    private func runEngine(lease: LiveTranscriptionLease) async {
        while !Task.isCancelled {
            // Lazy domain open: the first connection starts with the first
            // audio instead of idling before the microphone produces frames;
            // after a seal the loop top reopens exactly once per iteration.
            if currentDomain == nil {
                // A stopped pump with nothing left to feed must not open a
                // pointless provider request just to close it again.
                if pumpIsFinished, peekFrame() == nil, !overflowSealPending {
                    await finishEngine(lease: lease)
                    return
                }
                guard await openDomain(lease: lease) else {
                    if lockAnchorForDomain().sourceRate == nil {
                        await park()
                    } else {
                        await pauseWhileDegraded()
                    }
                    continue
                }
            }
            // Byte-budget rotation is decided BEFORE claiming the head frame:
            // the resampler is stateful, so a frame must be pushed exactly
            // once, and the buffered head belongs to the next domain.
            if let head = peekFrame(),
               let domain = currentDomain,
               domain.willExceed(wireBytes: wireBound(for: head)) {
                await sealDomain(reason: .rotation, lease: lease)
                continue
            }
            switch claim() {
            case .park:
                await park()
            case .finish:
                // Cancellation discards everything queued; only a genuine
                // pump finish commits the tail of the last domain.
                if !cancellationRequested {
                    // Flush the resampler tail into the last domain BEFORE the
                    // utterance commit so every accepted source sample is covered.
                    if let session = currentSession, let domain = currentDomain,
                       domain.framesFed > 0, let tail = resampler?.flush(), !tail.isEmpty {
                        try? await session.feed(tail)
                        currentDomain?.account(frameCount: 0, wireBytes: tail.count)
                    }
                    if currentDomain != nil {
                        await sealDomain(reason: .stop, lease: lease)
                    }
                }
                await finishEngine(lease: lease)
                return
            case .sealOverflow:
                // Invariant: a domain's wire audio is contiguous. The
                // buffered tail is discarded so the next domain starts at a
                // clean frame boundary; the gap is left for file fallback.
                discardBuffer()
                await sealDomain(reason: .overflow, lease: lease)
            case .frame(let frame):
                let pushed = try? resampler?.push(frame.data, sourceSampleRate: frame.sampleRate)
                guard let pcm = (pushed ?? nil), !pcm.isEmpty,
                      let session = currentSession, currentDomain != nil else {
                    // Degraded discard keeps memory bounded; coverage does
                    // not advance, so the file queue will cover this span.
                    continue
                }
                do {
                    try await session.feed(pcm)
                    let voicedFrames = frame.rms >= Self.voicedRMSThreshold
                        ? frame.frameCount : 0
                    currentDomain?.account(
                        frameCount: frame.frameCount,
                        wireBytes: pcm.count,
                        voicedFrameCount: voicedFrames)
                    accountVoice(frame)
                } catch {
                    await sealDomain(reason: .failure, lease: lease)
                }
            }
        }
        await finishEngine(lease: lease)
    }

    /// Engine teardown: join the live session and the lease on the engine
    /// task itself, so `cancelAndWait` observes a fully fenced coordinator
    /// with no own workers left.
    private func finishEngine(lease: LiveTranscriptionLease) async {
        if let session = currentSession {
            await session.cancel()
        }
        currentSession = nil
        currentDomain = nil
        await service.endLiveTranscription(lease)
        lock.withLock {
            liveActive = false
            liveSession = nil
        }
        await onChange()
    }

    /// Upper bound of the wire bytes one frame can produce after resampling.
    private func wireBound(for frame: MeetingPCMFrame) -> Int {
        let ratio = max(1, (frame.sampleRate / 16_000).rounded(.up))
        return Int(Double(frame.frameCount) * 2 * ratio) + 2
    }

    private func claim() -> Claim {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return .finish }
        if overflowSealRequested {
            overflowSealRequested = false
            return .sealOverflow
        }
        guard !buffer.isEmpty else {
            return pumpFinished ? .finish : .park
        }
        return .frame(buffer.removeFirst().frame)
    }

    private func peekFrame() -> MeetingPCMFrame? {
        lock.lock(); defer { lock.unlock() }
        return buffer.first?.frame
    }

    private func discardBuffer() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    private var cancellationRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private var overflowSealPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return overflowSealRequested
    }

    private var pumpIsFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return pumpFinished
    }

    private func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled || pumpFinished || overflowSealRequested || !buffer.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private struct DomainAnchor: Sendable {
        let startFrame: Int64
        let sourceRate: Double?
    }

    private func lockAnchorForDomain() -> DomainAnchor {
        lock.lock(); defer { lock.unlock() }
        return DomainAnchor(
            startFrame: buffer.first?.startFrame ?? offeredFrames,
            sourceRate: sourceRate)
    }

    private func resetVoiceProfile(rate: Double) {
        voiceWindows = []
        voiceWindowRate = rate.isFinite && rate > 0 ? rate : 16_000
        voiceWindowSamples = 0
        voiceWindowVoiced = false
        voiceSourceSamples = 0
    }

    /// Build 50 ms activity windows from the exact source frames accepted by
    /// the current request domain. Only a real voiced frame marks its window,
    /// so provider text in an all-silent window is rejected later.
    private func accountVoice(_ frame: MeetingPCMFrame) {
        guard voiceWindowRate.isFinite, voiceWindowRate > 0, frame.frameCount > 0 else { return }
        let windowSize = max(1, Int(voiceWindowRate * 0.05))
        var remaining = frame.frameCount
        let voiced = frame.rms >= Self.voicedRMSThreshold
        while remaining > 0 {
            let take = min(remaining, max(1, windowSize - voiceWindowSamples))
            voiceWindowSamples += take
            remaining -= take
            if voiced { voiceWindowVoiced = true }
            voiceSourceSamples += Int64(take)
            if voiceWindowSamples >= windowSize {
                voiceWindows.append(voiceWindowVoiced)
                voiceWindowSamples = 0
                voiceWindowVoiced = false
            }
        }
    }

    private var voiceProfile: MeetingVoiceProfile? {
        guard !voiceWindows.isEmpty, voiceWindowRate > 0 else { return nil }
        return MeetingVoiceProfile(
            windows: voiceWindows,
            duration: Double(voiceSourceSamples) / voiceWindowRate)
    }

    @discardableResult
    private func openDomain(lease: LiveTranscriptionLease) async -> Bool {
        let anchor = lockAnchorForDomain()
        guard let rate = anchor.sourceRate, resampler != nil else {
            // No audio yet: the caller parks until frames arrive.
            return false
        }
        let scope = UUID()
        let request = ASRLiveSessionRequest(
            profile: route.profile,
            turnID: scope,
            inputSampleRate: 16_000,
            languages: route.profile.languages,
            prompt: route.profile.prompt,
            keywords: route.profile.keywords,
            maximumAudioBytes: Int(wireLimitBytes + 4 * 1_024 * 1_024),
            finishTimeoutSeconds: Self.domainFinishTimeoutSeconds,
            enableSpeakerAttribution: true)
        do {
            let session = try await route.adapter.startLiveSession(
                request, credential: route.credential)
            let box = DomainEventBox()
            eventBoxes[scope] = box
            currentSession = session
            resetVoiceProfile(rate: rate)
            currentDomain = MeetingLiveASRDomain(
                scope: scope,
                sourceSampleRate: rate,
                startFrame: anchor.startFrame,
                wireLimitBytes: wireLimitBytes)
            consecutiveOpenFailures = 0
            lock.withLock {
                metrics.domains += 1
                liveActive = true
            }
            consumeEvents(of: session, box: box, lease: lease)
            return true
        } catch {
            consecutiveOpenFailures += 1
            if consecutiveOpenFailures == 3 {
                reportDegraded(error: error)
            }
            return false
        }
    }

    private func pauseWhileDegraded() async {
        lock.withLock { liveActive = false }
        // Cancellation/stop-aware bounded wait. A single unstructured sleep
        // would make cancel/deletion wait the full backoff; this loop observes
        // the flags every 100 ms.
        let steps = max(1, Int(Self.degradedRetryDelaySeconds * 10))
        for _ in 0..<steps {
            if cancellationRequested || pumpIsFinished { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func reportDegraded(error: Error) {
        guard !reportedDegraded else { return }
        reportedDegraded = true
        lock.lock()
        metrics.lastError = String(describing: error)
        lock.unlock()
        Task { [onDiagnostic] in
            await onDiagnostic(IDELanguageRunText.t(
                "实时转写暂时不可用，未覆盖的片段将稍后继续转写；原录音不受影响。",
                "Live transcription is temporarily unavailable; uncovered chunks will be transcribed later. The recording is unaffected."))
        }
    }

    // MARK: - Domain events

    private final class DomainEventBox: @unchecked Sendable {
        let lock = NSLock()
        var final: ASRLiveEvent?
        var failure: ASRTranscriptionError?
        func snapshot() -> (final: ASRLiveEvent?, failure: ASRTranscriptionError?) {
            lock.lock(); defer { lock.unlock() }
            return (final, failure)
        }
    }

    private func consumeEvents(
        of session: any ASRLiveSession,
        box: DomainEventBox,
        lease: LiveTranscriptionLease
    ) {
        Task { [weak self, weak box] in
            guard let self, let box else { return }
            var partial = MeetingLivePartialBuffer()
            do {
                for try await event in session.events {
                    switch event.kind {
                    case .partial:
                        // Provider deltas are not drafts by themselves. Keep
                        // the full hypothesis in this request domain and only
                        // publish a prefix that a later hypothesis confirmed,
                        // so a revision never becomes a flickering one-word
                        // transcript.
                        if let text = partial.ingest(
                            event.text, replacesPartial: event.replacesPartial),
                           !text.isEmpty {
                            try? await self.service.updateLivePartial(
                                lease, text: text)
                        }
                    case .final:
                        box.lock.withLock { box.final = event }
                    case .failed:
                        box.lock.withLock { box.failure = event.failure }
                    }
                    if event.kind == .final || event.kind == .failed { break }
                }
            } catch {
                box.lock.withLock { box.failure = .transport(.notReachable) }
            }
        }
    }

    // MARK: - Seal & commit

    private func sealDomain(reason: SealReason, lease: LiveTranscriptionLease) async {
        guard let session = currentSession, let domain = currentDomain else { return }
        let box = eventBoxes[domain.scope]
        if domain.framesFed > 0 {
            try? await session.endUtterance()
            let timeout = reason == .stop
                ? Self.stopTailTimeoutSeconds : Self.domainFinishTimeoutSeconds
            let deadline = Date().addingTimeInterval(timeout)
            var final: ASRLiveEvent?
            var failure: ASRTranscriptionError?
            while Date() < deadline {
                // Cancellation/deletion must not wait for a dead provider's
                // finish deadline. Stop is NOT cancellation: it keeps waiting
                // for the genuine tail within the bounded stop-tail budget.
                if cancellationRequested { break }
                let snapshot = box?.snapshot()
                if let value = snapshot?.final { final = value; break }
                if let value = snapshot?.failure { failure = value; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if let final, !cancellationRequested {
                await commitFinal(final, domain: domain, lease: lease)
            } else if reason != .stop {
                lock.withLock {
                    metrics.lastError = failure.map { String(describing: $0) } ?? "final timed out"
                }
            }
        }
        await session.cancel()
        eventBoxes[domain.scope] = nil
        currentSession = nil
        currentDomain = nil
        lock.withLock {
            if reason != .stop { metrics.reconnects += 1 }
            // Keep live ownership across a rotation/overflow while the pump
            // is still running. Otherwise the file fallback can start on a
            // chunk that the next domain is about to transcribe. A failed
            // domain or a finished capture releases the gate immediately.
            if reason == .stop || reason == .failure {
                liveActive = false
            }
        }
        // A sealed domain leaves no visible partial behind.
        try? await service.updateLivePartial(lease, text: "")
    }

    func commitFinal(
        _ event: ASRLiveEvent,
        domain: MeetingLiveASRDomain,
        lease: LiveTranscriptionLease
    ) async {
        // Silence/noise is not speech. A provider can emit a plausible final
        // for an empty or non-human segment; committing it would create the
        // same repeated-video-outro and bracket-sound hallucinations that are
        // visible in saved transcripts. Only client-measured voiced audio may
        // become a row. Quiet speech above the shared voice gate still counts.
        guard domain.voicedMediaSeconds >= Self.minimumVoicedSeconds else {
            lock.withLock { metrics.lastError = "final without voiced audio ignored" }
            return
        }
        let mediaLimit = domain.startMediaSeconds + domain.fedMediaSeconds
        let separated = event.utterances ?? []
        let measuredVoice = voiceProfile
        if separated.isEmpty {
            // Some real live engines (the OpenAI-compatible realtime path)
            // provide a final transcript without provider utterance timings.
            // The client opened the request on the first fed frame and ended
            // it explicitly, so [request start, fed source span] is a real
            // client-known utterance boundary, not an invented provider
            // timestamp. Providers that promise utterance timing keep the
            // stricter behavior below and leave a missing result to the file
            // fallback.
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unwrap before comparing: `.none` on an optional timing value
            // means Optional.none and would reject every configured engine
            // whose actual timing provenance is ASRTimingProvenance.none.
            guard let timing = route.profile.liveCapabilities?.timing,
                  timing == .none,
                  !text.isEmpty,
                  let range = try? MediaTimeRange(
                    start: domain.startMediaSeconds, end: mediaLimit) else { return }
            let speaker: SpeakerID?
            if let label = event.speaker {
                speaker = try? await service.resolveEngineSpeaker(
                    meeting: meetingID, scope: domain.scope.uuidString, label: label)
            } else {
                speaker = nil
            }
            let key = "\(domain.scope.uuidString)|whole|\(domain.framesFed)"
            do {
                let saved = try await service.commitLiveFinal(
                    lease, text: text, range: range,
                    speaker: speaker, language: nil, utteranceKey: key)
                if let saved {
                    lock.withLock { try? coverage.commit(saved.range) }
                }
                await onChange()
            } catch {
                lock.withLock { metrics.lastError = String(describing: error) }
            }
            return
        }
        for utterance in separated {
            guard !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = domain.mediaSeconds(wireMilliseconds: utterance.startMilliseconds)
            let end = min(domain.mediaSeconds(wireMilliseconds: utterance.endMilliseconds), mediaLimit)
            guard start.isFinite, end.isFinite, end > start,
                  let range = try? MediaTimeRange(start: start, end: end) else { continue }
            // A provider can return an utterance for a silent tail. The
            // client's own source-frame activity decides whether this exact
            // span contains voice; real short/quiet speech stays above the
            // shared gate and is retained.
            if let measuredVoice,
               !measuredVoice.hasVoice(
                   start: start - domain.startMediaSeconds,
                   end: end - domain.startMediaSeconds,
                   margin: 0.25) {
                lock.withLock { metrics.silentUtterances += 1 }
                continue
            }
            let speaker: SpeakerID?
            if let label = utterance.speaker {
                speaker = try? await service.resolveEngineSpeaker(
                    meeting: meetingID, scope: domain.scope.uuidString, label: label)
            } else {
                speaker = nil
            }
            // The stable identity of this utterance inside its ONE trusted
            // request domain: a replay/revision adopts in the same DB
            // transaction (user-corrected fields always win); an overlapping
            // range from a different key is rejected and returns nil. Its
            // existing rows may cover only part of this utterance.
            let key = "\(domain.scope.uuidString)|\(utterance.startMilliseconds)|\(utterance.endMilliseconds)"
            do {
                let saved = try await service.commitLiveFinal(
                    lease, text: utterance.text, range: range,
                    speaker: speaker, language: nil, utteranceKey: key)
                if let saved {
                    lock.withLock { try? coverage.commit(saved.range) }
                }
                // A nil outcome contributes no coverage here. The file queue
                // reads the actual lineage rows into its reserved map, so
                // any uncovered remainder still gets real audio fallback.
                await onChange()
            } catch {
                lock.withLock { metrics.lastError = String(describing: error) }
            }
        }
    }

    /// Provider live events are hypotheses, not display-ready sentences.
    /// Deltas are accumulated; a replacement replaces the current hypothesis.
    /// Only the longest common prefix of the last two hypotheses is published,
    /// so an unconfirmed trailing token never appears as a one-word flicker.
    /// The final event still commits the complete provider text.
    struct MeetingLivePartialBuffer: Sendable {
        private var hypothesis = ""
        private var previous = ""
        private var published = ""

        mutating func ingest(_ text: String, replacesPartial: Bool) -> String? {
            if replacesPartial {
                hypothesis = text
            } else {
                hypothesis += text
            }
            let stable = Self.commonPrefix(previous, hypothesis)
            previous = hypothesis
            let value = stable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != published else { return nil }
            published = value
            return value
        }

        static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
            var result = String()
            result.reserveCapacity(min(lhs.count, rhs.count))
            var left = lhs.startIndex
            var right = rhs.startIndex
            while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
                result.append(lhs[left])
                lhs.formIndex(after: &left)
                rhs.formIndex(after: &right)
            }
            return result
        }
    }

    /// Explicit diagnostics for the meeting diagnostics surface: domain and
    /// reconnect counts stay visible without touching the ordinary UI.
    nonisolated var metricsDescription: String {
        let snapshot = metricsSnapshot
        let reconnects = snapshot.reconnects
        let dropped = snapshot.droppedFrames
        let silent = snapshot.silentUtterances
        guard snapshot.domains > 0 || reconnects > 0 || dropped > 0
            || silent > 0 || snapshot.lastError != nil else { return "" }
        var parts: [String] = []
        parts.append(IDELanguageRunText.t("实时转写域 \(snapshot.domains)", "live domains \(snapshot.domains)"))
        if reconnects > 0 { parts.append(IDELanguageRunText.t("重连 \(reconnects)", "reconnects \(reconnects)")) }
        if dropped > 0 { parts.append(IDELanguageRunText.t("丢帧 \(dropped)", "dropped frames \(dropped)")) }
        if silent > 0 { parts.append(IDELanguageRunText.t("忽略静音片段 \(silent)", "silent segments ignored \(silent)")) }
        if let lastError = snapshot.lastError {
            parts.append(IDELanguageRunText.t("最近错误", "last error") + ": \(lastError)")
        }
        return parts.joined(separator: " · ")
    }
}
#endif
