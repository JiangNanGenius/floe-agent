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
    enum SealReason: Sendable {
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
    static let degradedRetryDelaySeconds: Double = 15

    struct Metrics: Sendable {
        var domains = 0
        var reconnects = 0
        var droppedFrames = 0
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
    private var metrics = Metrics()

    // Engine-side state (single engine task only; the lease value is
    // captured before the task starts and then engine-owned).
    private var engine: Task<Void, Never>?
    private var currentSession: (any ASRLiveSession)?
    private var currentDomain: MeetingLiveASRDomain?
    private var eventBoxes: [UUID: DomainEventBox] = [:]
    private var resampler: MeetingPCMDownsampler?
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
            lock.withLock { liveActive = false }
            return
        }
        self.lease = lease
        engine = Task { [weak self] in
            await self?.runEngine(lease: lease)
        }
    }

    /// The capture pump delivered everything and stopped. The engine drains
    /// the buffered tail, commits the genuine finish tail of the last domain,
    /// then closes the lease. Concurrency with the capture controller is
    /// safe: the lease is exactly the trusted same-capture tail path.
    func captureDidStop() async {
        let parked = lock.withLock {
            pumpFinished = true
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume()
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
                    currentDomain?.account(frameCount: frame.frameCount, wireBytes: pcm.count)
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
        lock.withLock { liveActive = false }
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
        // Cancellation-aware: throws immediately when the engine is cancelled.
        try? await Task.sleep(nanoseconds: UInt64(Self.degradedRetryDelaySeconds * 1_000_000_000))
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
            do {
                for try await event in session.events {
                    switch event.kind {
                    case .partial:
                        try? await self.service.updateLivePartial(lease, text: event.text)
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
            let deadline = Date().addingTimeInterval(Self.domainFinishTimeoutSeconds)
            var final: ASRLiveEvent?
            var failure: ASRTranscriptionError?
            while Date() < deadline {
                let snapshot = box?.snapshot()
                if let value = snapshot?.final { final = value; break }
                if let value = snapshot?.failure { failure = value; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if let final {
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
            liveActive = false
        }
        // A sealed domain leaves no visible partial behind.
        try? await service.updateLivePartial(lease, text: "")
    }

    func commitFinal(
        _ event: ASRLiveEvent,
        domain: MeetingLiveASRDomain,
        lease: LiveTranscriptionLease
    ) async {
        // Honest timing boundary (same policy as file work): without real
        // per-utterance times there is NO commit. Fabricating a [0, fedSpan]
        // row from the fed-audio length would invent provider timestamps;
        // the uncovered range stays for the file fallback path instead.
        guard let separated = event.utterances, !separated.isEmpty else { return }
        let mediaLimit = domain.startMediaSeconds + domain.fedMediaSeconds
        for utterance in separated {
            guard !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = domain.mediaSeconds(wireMilliseconds: utterance.startMilliseconds)
            let end = min(domain.mediaSeconds(wireMilliseconds: utterance.endMilliseconds), mediaLimit)
            guard start.isFinite, end.isFinite, end > start,
                  let range = try? MediaTimeRange(start: start, end: end) else { continue }
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

    /// Explicit diagnostics for the meeting diagnostics surface: domain and
    /// reconnect counts stay visible without touching the ordinary UI.
    nonisolated var metricsDescription: String {
        let snapshot = metricsSnapshot
        let reconnects = snapshot.reconnects
        let dropped = snapshot.droppedFrames
        guard snapshot.domains > 0 || reconnects > 0 || dropped > 0 || snapshot.lastError != nil else { return "" }
        var parts: [String] = []
        parts.append(IDELanguageRunText.t("实时转写域 \(snapshot.domains)", "live domains \(snapshot.domains)"))
        if reconnects > 0 { parts.append(IDELanguageRunText.t("重连 \(reconnects)", "reconnects \(reconnects)")) }
        if dropped > 0 { parts.append(IDELanguageRunText.t("丢帧 \(dropped)", "dropped frames \(dropped)")) }
        if let lastError = snapshot.lastError {
            parts.append(IDELanguageRunText.t("最近错误", "last error") + ": \(lastError)")
        }
        return parts.joined(separator: " · ")
    }
}
#endif
