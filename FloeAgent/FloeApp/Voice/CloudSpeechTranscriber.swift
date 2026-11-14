// FloeApp — Cloud speech transcriber behind the existing `SpeechTranscribing`
// seam, shared by dictation and continuous voice.
//
// SPDX-License-Identifier: MPL-2.0
//
// Design rules:
// - The microphone tap hands us a REUSED AVAudioPCMBuffer. `feed` copies and
//   converts SYNCHRONOUSLY on the tap call, then pushes one bounded frame into
//   an ordered queue. Exactly ONE producer task consumes that queue; no Task
//   is created per buffer, so audio can never be reordered or corrupted.
// - One cloud live session is one committed utterance (the core contract).
//   The App wrapper keeps one continuous `transcripts` stream across
//   successive utterances: client VAD on real capture quiet commits each
//   utterance, the final replaces its partial, and the cumulative text stays
//   monotonic. Ordinary stop drains the final with a bounded deadline;
//   cancellation is immediate and never manufactures text.
// - Profiles without a live adapter (for example Alibaba Token Plan) buffer
//   the utterance in bounded RAM and call the file adapter once on real
//   quiet/manual stop. They intentionally emit no partials while speaking;
//   `recognitionProgressMode == .batchFile` lets the conversation watchdog
//   use a batch-aware health bound instead of treating quiet partials as a
//   dead recognizer.
// - A transient cloud live failure is retried for the SAME uncommitted
//   utterance with bounded, cancellable backoff. Capture keeps queueing new
//   frames while the worker waits, and the complete captured utterance is
//   replayed into the fresh request before new audio continues, so a socket
//   blip cannot drop the middle of a sentence. A committed final is never
//   replayed, stale events from a failed request never reach the transcript,
//   and a permanent auth/config error or an ordinary stop never loops.
// - If live recovery is exhausted (or the failure is permanent), ONLY the
//   uncommitted utterance is replayed through a local-only factory (Whisper
//   then Apple as supplied). The partial cloud text is replaced, never
//   appended, and the wrapper never recursively selects another cloud route.
// - Cancellation is not a provider failure and never triggers local fallback.

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import FloeCore

/// Adapter seams. Production injects `ASRAdapterFactory`; focused tests inject
/// scripted adapters without networking or credentials.
struct CloudSpeechAdapters: Sendable {
    var file: @Sendable (ASRProfile) throws -> any ASRTranscribing
    var live: @Sendable (ASRProfile) throws -> (any ASRLiveTranscribing)?
}

private enum CloudSpeechFailure: Error, Equatable {
    case configuration
    case credential
    case transport
    case rejected
    case emptyFinal
    case finalTimeout
    case audioOverflow
    case cancelled
}

/// Bounded reconnect policy for ONE live utterance. Production values keep a
/// transient network blip inside the same dictation without turning a dead
/// endpoint into an unbounded reconnect loop. Tests may inject an immediate
/// policy; production callers use `.standard`.
struct CloudSpeechRecoveryPolicy: Sendable, Equatable {
    /// Fresh request attempts allowed AFTER a transient failure. The initial
    /// request is always attempted and is not charged to this budget; zero
    /// therefore disables reconnection but still allows one initial request.
    var maximumReconnects: Int
    var initialBackoffSeconds: Double
    var maximumBackoffSeconds: Double

    static let standard = CloudSpeechRecoveryPolicy(
        maximumReconnects: 2,
        initialBackoffSeconds: 0.35,
        maximumBackoffSeconds: 1.5)

    static let immediate = CloudSpeechRecoveryPolicy(
        maximumReconnects: 2,
        initialBackoffSeconds: 0,
        maximumBackoffSeconds: 0)
}

/// Conservative classification: only a genuine transient transport/provider
/// condition may start another request. Authentication, configuration,
/// malformed requests/results and local cancellation never loop.
private enum CloudLiveRetry {
    static func isTransient(_ failure: ASRTranscriptionError) -> Bool {
        switch failure {
        case .transport(let reason):
            switch reason {
            case .cannotResolveHost, .cannotConnect, .timedOut,
                 .notReachable, .unknown:
                return true
            case .tlsFailure, .cancelled:
                return false
            }
        case .quotaOrRateLimited:
            return true
        case .httpStatus(let code):
            return code == 408 || code == 425 || code == 429
                || (500...599).contains(code)
        case .invalidConfiguration, .credentialMissing, .authentication,
             .providerRejected, .emptyResult, .responseTooLarge:
            return false
        }
    }
}

/// Redacted mapping for errors that escape a session seam. Provider adapters
/// already map their own failures; this preserves that category and gives a
/// safe transient class to anything else.
private enum CloudSpeechErrorMapping {
    static func failure(from error: Error) -> ASRTranscriptionError {
        if let error = error as? ASRTranscriptionError { return error }
        if error is CancellationError { return .transport(.cancelled) }
        if let failure = error as? CloudSpeechFailure {
            switch failure {
            case .configuration:
                return .invalidConfiguration("cloud speech configuration is unavailable")
            case .credential:
                return .credentialMissing
            case .transport:
                return .transport(.notReachable)
            case .rejected:
                return .providerRejected
            case .emptyFinal:
                return .emptyResult
            case .finalTimeout:
                return .transport(.timedOut)
            case .audioOverflow:
                return .invalidConfiguration("captured audio exceeds the live limit")
            case .cancelled:
                return .transport(.cancelled)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .transport(.cannotResolveHost)
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return .transport(.cannotConnect)
            case NSURLErrorTimedOut:
                return .transport(.timedOut)
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return .transport(.notReachable)
            case NSURLErrorCancelled:
                return .transport(.cancelled)
            default:
                return .transport(.unknown)
            }
        }
        return .transport(.unknown)
    }

    /// Prefer the session's own terminal failure. An adapter that rejects a
    /// write because its receive side already ended reports a configuration
    /// message, but the real cause is the transport failure carried by the
    /// event stream; only when that is absent is the ended session transient.
    static func failure(
        from error: Error,
        snapshot: CloudLiveUtterance.Snapshot?
    ) -> ASRTranscriptionError {
        if let existing = snapshot?.failure { return existing }
        let mapped = Self.failure(from: error)
        if case .invalidConfiguration = mapped, snapshot?.ended == true {
            return .transport(.notReachable)
        }
        return mapped
    }
}

/// One converted PCM16 frame with the real measured RMS/duration used by the
/// client VAD. `pcm` is mono little-endian PCM16 at `sampleRate`.
struct CloudAudioFrame: Sendable {
    var pcm: Data
    var sampleRate: Int
    var rms: Float
    var duration: Double

    var isVoiced: Bool { rms >= CloudSpeechTranscriber.voiceGate }
}

/// Thread-safe, self-expiring recovery flag read by the continuous-voice
/// health watchdog. A single episode is reported for at most
/// `maximumSeconds`, so a hung open/backoff can never disable the watchdog
/// indefinitely; a genuinely dead path resumes the ordinary failure bound.
private final class CloudRecoveryStatusBox: @unchecked Sendable {
    private static let maximumSeconds: Double = 15
    private let lock = NSLock()
    private var startedAt: Date?

    func begin() {
        lock.withLock {
            if startedAt == nil { startedAt = Date() }
        }
    }

    func end() {
        lock.withLock { startedAt = nil }
    }

    var isActive: Bool {
        lock.withLock {
            guard let startedAt else { return false }
            return Date().timeIntervalSince(startedAt) < Self.maximumSeconds
        }
    }
}

private final class CloudTranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VoiceInputFailure?
    private var cancelled = false

    var failure: VoiceInputFailure? { lock.withLock { stored } }

    func store(_ failure: VoiceInputFailure) {
        lock.withLock {
            guard stored == nil, !cancelled else { return }
            stored = failure
        }
    }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

final class CloudLiveEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private var finalText: String?
    private var failure: ASRTranscriptionError?
    private var ended = false

    func apply(_ event: ASRLiveEvent) {
        lock.withLock {
            switch event.kind {
            case .partial:
                if event.replacesPartial {
                    partial = event.text
                } else {
                    partial.append(event.text)
                }
            case .final:
                finalText = event.text
            case .failed:
                failure = event.failure ?? .providerRejected
            }
        }
    }

    func markEnded() {
        lock.withLock { ended = true }
    }

    func store(failure: ASRTranscriptionError) {
        lock.withLock { if self.failure == nil { self.failure = failure } }
    }

    func snapshot() -> (partial: String, final: String?, failure: ASRTranscriptionError?, ended: Bool) {
        lock.withLock { (partial, finalText, failure, ended) }
    }
}

/// Bounded FIFO between the tap and the single producer. `push` never blocks
/// the audio thread; overflow is a terminal, visible failure rather than
/// silently dropping or reordering captured speech.
final class CloudFrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CloudAudioFrame] = []
    private var head = 0
    private var bytes = 0
    private let capacityBytes: Int
    private var closed = false
    private var overflowed = false
    private var waiter: CheckedContinuation<CloudAudioFrame?, Never>?

    init(capacityBytes: Int) {
        self.capacityBytes = max(64 * 1024, capacityBytes)
    }

    var isOverflowed: Bool { lock.withLock { overflowed } }

    @discardableResult
    func push(_ frame: CloudAudioFrame) -> Bool {
        lock.lock()
        guard !closed, !overflowed else {
            lock.unlock()
            return false
        }
        guard bytes + frame.pcm.count <= capacityBytes else {
            overflowed = true
            closed = true
            frames = []
            head = 0
            bytes = 0
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(returning: nil)
            return false
        }
        // A waiting consumer is only possible while the FIFO is empty. Hand
        // it the frame DIRECTLY (never append-then-resume-nil), preserving
        // FIFO order and exactly-once delivery.
        if let consumer = waiter {
            waiter = nil
            lock.unlock()
            consumer.resume(returning: frame)
            return true
        }
        frames.append(frame)
        bytes += frame.pcm.count
        lock.unlock()
        return true
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    func cancel() {
        lock.lock()
        closed = true
        frames = []
        head = 0
        bytes = 0
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    func pop() async -> CloudAudioFrame? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if head < frames.count {
                let frame = frames[head]
                frames[head] = CloudAudioFrame(pcm: Data(), sampleRate: 0, rms: 0, duration: 0)
                head += 1
                bytes -= frame.pcm.count
                if head > 64, head * 2 > frames.count {
                    frames.removeFirst(head)
                    head = 0
                }
                lock.unlock()
                continuation.resume(returning: frame)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

private final class CloudPCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputDescription = ""

    init?(sampleRate: Int) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false) else { return nil }
        outputFormat = format
    }

    func convert(_ input: AVAudioPCMBuffer) -> CloudAudioFrame? {
        lock.withLock {
            let key = input.format.description
            if key != inputDescription || converter == nil {
                converter = AVAudioConverter(from: input.format, to: outputFormat)
                converter?.primeMethod = .none
                inputDescription = key
            }
            guard let converter else { return nil }
            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let estimated = max(1, Int(ceil(Double(input.frameLength) * ratio)) + 4_096)
            guard estimated <= Int(UInt32.max),
                  let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(estimated)) else { return nil }
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard error == nil else { return nil }
            return Self.frame(from: output, sampleRate: Int(outputFormat.sampleRate))
        }
    }

    /// One frame from an already-converted Float32 mono buffer.
    static func frame(from buffer: AVAudioPCMBuffer, sampleRate: Int) -> CloudAudioFrame? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }
        let samples = channels[0]
        var sum: Float = 0
        var pcm = Data(capacity: frames * 2)
        pcm.count = frames * 2
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for index in 0..<frames {
                let sample = samples[index]
                guard sample.isFinite else { continue }
                sum += sample * sample
                let clamped = max(-1, min(1, sample))
                let value = Int16((clamped * 32_767).rounded())
                out[index] = UInt16(bitPattern: value).littleEndian
            }
        }
        let duration = Double(frames) / Double(max(sampleRate, 1))
        let rms = frames > 0 ? (sum / Float(frames)).squareRoot() : 0
        return CloudAudioFrame(pcm: pcm, sampleRate: sampleRate, rms: rms, duration: duration)
    }
}

private struct CloudUtteranceState {
    var frames: [CloudAudioFrame] = []
    var bytes = 0
    var duration: Double = 0
    var voicedDuration: Double = 0
    var quietRun: Double = 0
    var sampleRate: Int

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    init(frames: [CloudAudioFrame]) {
        self.init(sampleRate: frames.last?.sampleRate ?? 16_000)
        for frame in frames { append(frame) }
    }

    mutating func append(_ frame: CloudAudioFrame) {
        frames.append(frame)
        bytes += frame.pcm.count
        duration += frame.duration
        if frame.isVoiced {
            voicedDuration += frame.duration
            quietRun = 0
        } else {
            quietRun += frame.duration
        }
    }

    var wavData: Data {
        CloudPCMCodec.wav(
            pcm16: frames.reduce(into: Data()) { $0.append($1.pcm) },
            sampleRate: sampleRate)
    }
}

/// Per-utterance live recovery accounting. `retries` counts only fresh
/// requests started AFTER a failure; the initial request is not a retry, so
/// `maximumReconnects == 2` still means one initial request plus two real
/// reconnects. Reset when a new utterance/segment starts.
private struct CloudLiveRecoveryState {
    var retries = 0
    var lastFailure: ASRTranscriptionError?
}

private struct CloudLiveStart {
    let session: CloudLiveUtterance
    /// Number of frames the fresh request actually accepted. An early server
    /// final can stop a replay before every frame was sent; those unsent
    /// frames stay with the next segment and are never sent twice.
    let fedFrames: Int
}

private final class CloudLocalTranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func store(_ text: String) { lock.withLock { value = text } }
    var text: String { lock.withLock { value } }
}

final class CloudSpeechTranscriber: SpeechTranscribing, @unchecked Sendable {
    static let voiceGate: Float = 0.008
    static let vadSilenceSeconds: Double = 0.8
    static let minimumVoicedSeconds: Double = 0.08
    static let prerollSeconds: Double = 0.25
    static let maximumUtteranceBytes = 8 * 1024 * 1024
    static let maximumQueueBytes = 16 * 1024 * 1024
    static let finalTimeoutSeconds: Double = 20

    enum Mode: Sendable {
        case live
        case batch
    }

    let transcripts: AsyncStream<String>
    let mode: Mode
    var recognitionProgressMode: VoiceRecognitionProgressMode {
        mode == .batch ? .batchFile : .streaming
    }
    var finalDrainTimeout: Duration { .seconds(Self.finalTimeoutSeconds) }

    var failure: VoiceInputFailure? { box.failure }

    /// Bounded reconnect/replay visibility for the continuous-voice watchdog.
    var recognitionRecoveryActive: Bool { recoveryStatus.isActive }

    private let profile: ASRProfile
    private let language: VoiceRecognitionLanguage
    private let credentialProvider: @Sendable () async throws -> String
    private let fileAdapter: any ASRTranscribing
    private let liveAdapter: (any ASRLiveTranscribing)?
    private let localFallback: @Sendable () async throws -> (any SpeechTranscribing)?
    private let diagnostics: (any VoiceInputDiagnostics)?
    private let recoveryPolicy: CloudSpeechRecoveryPolicy
    private let recoveryStatus = CloudRecoveryStatusBox()
    private let continuation: AsyncStream<String>.Continuation
    private let queue = CloudFrameQueue(capacityBytes: CloudSpeechTranscriber.maximumQueueBytes)
    private let converter: CloudPCMConverter?
    private let box = CloudTranscriptBox()
    private let lifecycleLock = NSLock()
    private var worker: Task<Void, Never>?
    private var completedFinals = 0
    private var finishRequested = false

    init(
        profile: ASRProfile,
        language: VoiceRecognitionLanguage,
        adapters: CloudSpeechAdapters,
        credentialProvider: @escaping @Sendable () async throws -> String,
        localFallback: @escaping @Sendable () async throws -> (any SpeechTranscribing)?,
        diagnostics: (any VoiceInputDiagnostics)? = nil,
        recoveryPolicy: CloudSpeechRecoveryPolicy = .standard
    ) throws {
        self.profile = profile
        self.language = language
        self.credentialProvider = credentialProvider
        self.localFallback = localFallback
        self.diagnostics = diagnostics
        self.recoveryPolicy = recoveryPolicy
        self.fileAdapter = try adapters.file(profile)
        let live = try adapters.live(profile)
        self.liveAdapter = live
        self.mode = live == nil ? .batch : .live
        let sampleRate = profile.provider == .openaiCompatible ? 24_000 : 16_000
        self.converter = CloudPCMConverter(sampleRate: sampleRate)
        var streamContinuation: AsyncStream<String>.Continuation!
        self.transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
            streamContinuation = $0
        }
        self.continuation = streamContinuation
        guard converter != nil else {
            throw CloudSpeechFailure.configuration
        }
        self.worker = Task { [weak self] in
            await self?.run()
        }
    }

    // MARK: - Capture seam

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard !box.isCancelled, lifecycleLock.withLock({ !finishRequested }) else { return }
        guard VoiceBufferValidator.isUsable(buffer) else { return }
        guard let converter, let frame = converter.convert(buffer) else { return }
        diagnostics?.voiceAudioBufferAccepted(frameCount: buffer.frameLength)
        guard queue.push(frame) else {
            if queue.isOverflowed {
                box.store(.recognizerFailed)
                continuation.finish()
            }
            return
        }
    }

    func finishAudio() async {
        let shouldFinish = lifecycleLock.withLock { () -> Bool in
            guard !finishRequested else { return false }
            finishRequested = true
            return true
        }
        guard shouldFinish else {
            await worker?.value
            return
        }
        queue.close()
        await worker?.value
        continuation.finish()
    }

    func cancelAudio() async {
        lifecycleLock.withLock { finishRequested = true }
        box.markCancelled()
        queue.cancel()
        worker?.cancel()
        await worker?.value
        continuation.finish()
    }

    // MARK: - Producer

    private var isStopRequested: Bool {
        lifecycleLock.withLock { finishRequested }
    }

    private func run() async {
        var committed: [String] = []
        var utterance: CloudUtteranceState?
        var preroll: [CloudAudioFrame] = []
        var live: CloudLiveUtterance?
        var fedFrames = 0
        var recovery = CloudLiveRecoveryState()
        var pendingFailure: ASRTranscriptionError?
        var lastEmitted = ""

        func emit(partial: String = "") {
            guard !Task.isCancelled, !box.isCancelled else { return }
            let parts = committed.filter { !$0.isEmpty } + (partial.isEmpty ? [] : [partial])
            let text = parts.joined(separator: " ")
            if !text.isEmpty, text != lastEmitted {
                lastEmitted = text
                continuation.yield(text)
            }
        }

        func recordFinal(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            committed.append(trimmed)
            completedFinals += 1
            emit()
        }

        func startUtterance(with frames: [CloudAudioFrame]) {
            var state = CloudUtteranceState(sampleRate: frames.last?.sampleRate ?? 16_000)
            for frame in frames { state.append(frame) }
            utterance = state
            fedFrames = 0
            recovery = CloudLiveRecoveryState()
            pendingFailure = nil
        }

        /// Fresh request for the SAME profile/credential route. The caller
        /// replays the captured segment into it before any new live frame.
        func makeLiveSession() async throws -> CloudLiveUtterance {
            guard mode == .live, let adapter = liveAdapter else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "cloud live transcription is unavailable for this profile")
            }
            let credential: String
            do {
                credential = try await credentialProvider()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A keychain/read failure is a configuration state, not a
                // reason to loop against the provider.
                throw ASRTranscriptionError.credentialMissing
            }
            try Task.checkCancellation()
            let request = ASRLiveSessionRequest(
                profile: profile,
                turnID: UUID(),
                inputSampleRate: profile.provider == .openaiCompatible ? 24_000 : 16_000,
                languages: language.recognitionCode.map { [$0] } ?? [],
                finishTimeoutSeconds: Self.finalTimeoutSeconds)
            do {
                let session = try await adapter.startLiveSession(
                    request, credential: credential)
                return CloudLiveUtterance(session: session)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CloudSpeechErrorMapping.failure(from: error)
            }
        }

        func waitBeforeReconnect(attempt: Int) async -> Bool {
            let exponent = max(0, attempt - 1)
            let base = recoveryPolicy.initialBackoffSeconds
                * pow(2, Double(exponent))
            let seconds = max(0, min(base, recoveryPolicy.maximumBackoffSeconds))
            guard seconds > 0 else { return true }
            let steps = max(1, Int((seconds / 0.1).rounded(.up)))
            for _ in 0..<steps {
                if Task.isCancelled || box.isCancelled || isStopRequested {
                    return false
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return false }
            }
            return true
        }

        /// Bounded fresh request with replay. Capture keeps queueing on the
        /// audio thread while this awaits. The initial request is NOT charged
        /// to `maximumReconnects`; only requests after a failure are retries.
        func recoverLive(frames: [CloudAudioFrame]) async -> CloudLiveStart? {
            recoveryStatus.begin()
            defer { recoveryStatus.end() }
            var initial = recovery.lastFailure == nil && recovery.retries == 0
            while true {
                if Task.isCancelled || box.isCancelled { return nil }
                if let failure = recovery.lastFailure,
                   !CloudLiveRetry.isTransient(failure) {
                    return nil
                }
                if !initial {
                    guard !isStopRequested,
                          recovery.retries < max(0, recoveryPolicy.maximumReconnects) else {
                        return nil
                    }
                    guard await waitBeforeReconnect(
                        attempt: recovery.retries + 1) else { return nil }
                    recovery.retries += 1
                }
                initial = false
                do {
                    let session = try await makeLiveSession()
                    var accepted = 0
                    do {
                        for frame in frames {
                            try Task.checkCancellation()
                            if session.hasFinal {
                                return CloudLiveStart(
                                    session: session, fedFrames: accepted)
                            }
                            try await session.session.feed(frame.pcm)
                            accepted += 1
                            // The provider can finalize before every frame is
                            // sent; unsent frames stay with the next segment.
                            if session.hasFinal {
                                return CloudLiveStart(
                                    session: session, fedFrames: accepted)
                            }
                        }
                        recovery.lastFailure = nil
                        return CloudLiveStart(session: session, fedFrames: accepted)
                    } catch is CancellationError {
                        let snapshot = await session.settledSnapshot()
                        if snapshot.final != nil {
                            return CloudLiveStart(
                                session: session, fedFrames: accepted)
                        }
                        await session.cancelTransport()
                        if Task.isCancelled || box.isCancelled { return nil }
                        recovery.lastFailure = snapshot.failure
                            ?? .transport(.cancelled)
                    } catch {
                        let snapshot = await session.settledSnapshot()
                        if snapshot.final != nil {
                            // A normal early server final is a complete
                            // result even if the adapter then refuses audio.
                            return CloudLiveStart(
                                session: session, fedFrames: accepted)
                        }
                        await session.cancelTransport()
                        recovery.lastFailure = CloudSpeechErrorMapping.failure(
                            from: error, snapshot: snapshot)
                    }
                } catch is CancellationError {
                    return nil
                } catch {
                    recovery.lastFailure = CloudSpeechErrorMapping.failure(
                        from: error, snapshot: nil)
                }
            }
        }

        func dropLive(_ failure: ASRTranscriptionError?) async {
            if let failure {
                pendingFailure = failure
                recovery.lastFailure = failure
            }
            fedFrames = 0
            guard let session = live else { return }
            live = nil
            await session.cancelTransport()
        }

        /// One shared failure path for feed and commit: preserve a real final,
        /// otherwise map and release the failed socket, then use the single
        /// bounded reconnect budget.
        func handleLiveFailure(
            _ error: Error,
            session: CloudLiveUtterance,
            state: CloudUtteranceState
        ) async -> Bool {
            let snapshot = await session.settledSnapshot()
            if snapshot.final != nil { return true }
            let failure = CloudSpeechErrorMapping.failure(
                from: error, snapshot: snapshot)
            await dropLive(failure)
            guard !Task.isCancelled, !box.isCancelled,
                  CloudLiveRetry.isTransient(failure), !isStopRequested,
                  recovery.retries < max(0, recoveryPolicy.maximumReconnects),
                  let start = await recoverLive(frames: state.frames) else {
                return false
            }
            live = start.session
            fedFrames = start.fedFrames
            pendingFailure = nil
            return true
        }

        /// Settle a provider final exactly once. Only frames the finalizing
        /// request actually accepted are consumed. Every unfed frame — the
        /// rejected current frame included — remains in a fresh utterance and
        /// is replayed once to the next controlled request.
        func settleEarlyFinal(
            _ session: CloudLiveUtterance,
            state: CloudUtteranceState
        ) async -> Bool {
            guard let final = session.snapshot.final else { return false }
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await dropLive(.providerRejected)
                return false
            }
            let accepted = min(fedFrames, state.frames.count)
            guard accepted > 0 else {
                await dropLive(.providerRejected)
                return false
            }
            await session.cancelTransport()
            if live === session { live = nil }
            fedFrames = 0
            recordFinal(trimmed)
            let remaining = Array(state.frames.dropFirst(accepted))
            recovery = CloudLiveRecoveryState()
            pendingFailure = nil
            if remaining.isEmpty {
                utterance = nil
                return true
            }
            utterance = CloudUtteranceState(frames: remaining)
            return true
        }

        /// Feed newly captured frames and settle any provider early final.
        /// Returns true when `utterance` was replaced/closed, so the caller
        /// must re-read it instead of using its stale local copy.
        func syncLive(_ initialState: CloudUtteranceState) async -> Bool {
            guard mode == .live else { return false }
            var state = initialState
            var changed = false
            var settlements = 0
            syncLoop: while true {
                if Task.isCancelled || box.isCancelled { return changed }
                if live == nil {
                    if let failure = pendingFailure,
                       !CloudLiveRetry.isTransient(failure) {
                        return changed
                    }
                    if state.voicedDuration < Self.minimumVoicedSeconds {
                        return changed
                    }
                    let isInitial = recovery.lastFailure == nil
                        && recovery.retries == 0
                    guard isInitial || (!isStopRequested
                        && recovery.retries < max(0, recoveryPolicy.maximumReconnects)) else {
                        return changed
                    }
                    guard let start = await recoverLive(frames: state.frames) else {
                        pendingFailure = recovery.lastFailure ?? pendingFailure
                            ?? .transport(.notReachable)
                        return changed
                    }
                    live = start.session
                    fedFrames = start.fedFrames
                    pendingFailure = nil
                }
                guard let session = live else { return changed }
                if session.hasFinal {
                    guard await settleEarlyFinal(session, state: state) else {
                        return changed
                    }
                    changed = true
                    settlements += 1
                    guard settlements <= 8 else { return changed }
                    guard let updated = utterance else { return true }
                    state = updated
                    continue
                }
                while fedFrames < state.frames.count {
                    if Task.isCancelled || box.isCancelled { return changed }
                    do {
                        try await session.session.feed(state.frames[fedFrames].pcm)
                        fedFrames += 1
                    } catch {
                        if await handleLiveFailure(
                            error, session: session, state: state) {
                            continue syncLoop
                        }
                        return changed
                    }
                    if session.hasFinal { break }
                }
                if session.hasFinal { continue }
                return changed
            }
        }

        func commit(_ initialState: CloudUtteranceState) async throws -> String {
            if mode == .batch {
                return try await transcribeBatch(initialState)
            }
            var state = initialState
            var settlements = 0
            while true {
                if Task.isCancelled || box.isCancelled { throw CancellationError() }
                if let session = live, session.hasFinal {
                    guard await settleEarlyFinal(session, state: state) else {
                        throw pendingFailure ?? ASRTranscriptionError.providerRejected
                    }
                    settlements += 1
                    guard settlements <= 8 else {
                        throw ASRTranscriptionError.providerRejected
                    }
                    guard let updated = utterance else { return "" }
                    state = updated
                    if state.voicedDuration < Self.minimumVoicedSeconds {
                        // Only silence followed the provider's endpoint.
                        utterance = nil
                        return ""
                    }
                    if isStopRequested {
                        // Ordinary stop never starts another request. The
                        // remaining tail still goes through local fallback
                        // when one exists; the settled final is never lost.
                        if let text = await recoverLocally(state) {
                            recordFinal(text)
                        }
                        utterance = nil
                        return ""
                    }
                    continue
                }
                if live == nil {
                    let isInitial = recovery.lastFailure == nil
                        && recovery.retries == 0
                    let retryable = recovery.lastFailure
                        .map(CloudLiveRetry.isTransient) ?? true
                    let hasBudget = recovery.retries
                        < max(0, recoveryPolicy.maximumReconnects)
                    if isStopRequested, !isInitial {
                        throw pendingFailure ?? recovery.lastFailure
                            ?? ASRTranscriptionError.transport(.notReachable)
                    }
                    guard retryable, isInitial || hasBudget else {
                        throw pendingFailure ?? recovery.lastFailure
                            ?? ASRTranscriptionError.transport(.notReachable)
                    }
                    guard let start = await recoverLive(frames: state.frames) else {
                        throw recovery.lastFailure ?? pendingFailure
                            ?? ASRTranscriptionError.transport(.notReachable)
                    }
                    live = start.session
                    fedFrames = start.fedFrames
                    pendingFailure = nil
                    if start.session.hasFinal { continue }
                }
                guard let session = live else {
                    throw recovery.lastFailure ?? pendingFailure
                        ?? ASRTranscriptionError.transport(.notReachable)
                }
                do {
                    return try await transcribeLive(session: session)
                } catch is CancellationError {
                    await dropLive(nil)
                    throw CancellationError()
                } catch {
                    let snapshot = await session.settledSnapshot()
                    if snapshot.final != nil {
                        continue
                    }
                    let failure = CloudSpeechErrorMapping.failure(
                        from: error, snapshot: snapshot)
                    await dropLive(failure)
                    guard !Task.isCancelled, !box.isCancelled,
                          CloudLiveRetry.isTransient(failure),
                          !isStopRequested,
                          recovery.retries < max(0, recoveryPolicy.maximumReconnects),
                          let start = await recoverLive(frames: state.frames) else {
                        throw recovery.lastFailure ?? failure
                    }
                    live = start.session
                    fedFrames = start.fedFrames
                    pendingFailure = nil
                }
            }
        }

        func endUtterance(_ state: CloudUtteranceState) async {
            // An early-final split can replace the utterance after the caller
            // captured its argument; always commit the current one.
            let current = utterance ?? state
            guard current.voicedDuration >= Self.minimumVoicedSeconds else {
                if let session = live { await session.cancel() }
                live = nil
                fedFrames = 0
                utterance = nil
                emit()
                return
            }
            do {
                let text = try await commit(current)
                try Task.checkCancellation()
                if !text.isEmpty { recordFinal(text) }
                utterance = nil
                if let session = live { await session.cancel() }
                live = nil
                fedFrames = 0
                emit()
            } catch is CancellationError {
                if let session = live { await session.cancel() }
                live = nil
                fedFrames = 0
                utterance = nil
            } catch {
                if let session = live { await session.cancel() }
                live = nil
                fedFrames = 0
                let fallbackState = utterance ?? current
                utterance = nil
                if let text = await recoverLocally(fallbackState) {
                    recordFinal(text)
                } else if !box.isCancelled {
                    box.store(.recognizerFailed)
                    continuation.finish()
                }
            }
        }

        while let frame = await queue.pop() {
            if Task.isCancelled || box.isCancelled { break }
            if utterance == nil {
                if frame.isVoiced {
                    // Start with the bounded pre-roll plus the first voiced
                    // frame. Every captured frame enters the utterance ONCE,
                    // and the complete ordered frame list is what a reconnect
                    // replays, so the opening is never duplicated.
                    preroll.append(frame)
                    let opening = preroll
                    preroll = []
                    startUtterance(with: opening)
                    if mode == .live {
                        // Open the initial request immediately. Even a stop
                        // that arrives before the worker drains the queue can
                        // still commit this short dictation.
                        if let start = await recoverLive(frames: opening) {
                            live = start.session
                            fedFrames = start.fedFrames
                            pendingFailure = nil
                        } else {
                            pendingFailure = recovery.lastFailure
                                ?? .transport(.notReachable)
                        }
                    }
                    // Do NOT append the current frame again below.
                } else {
                    preroll.append(frame)
                    var total = preroll.reduce(0.0) { $0 + $1.duration }
                    while total > Self.prerollSeconds, preroll.count > 1 {
                        total -= preroll.removeFirst().duration
                    }
                    continue
                }
            } else if var state = utterance {
                state.append(frame)
                utterance = state
            }
            guard let state = utterance else { continue }
            if mode == .live {
                if await syncLive(state) { continue }
            }
            guard let current = utterance else { continue }
            if current.bytes > Self.maximumUtteranceBytes {
                // Bounded speculation: commit what was actually captured
                // rather than growing without limit or dropping audio.
                await endUtterance(current)
                continue
            }
            if mode == .live, let session = live {
                let partial = session.partial
                if !partial.isEmpty { emit(partial: partial) }
            }
            if current.quietRun >= Self.vadSilenceSeconds,
               current.voicedDuration >= Self.minimumVoicedSeconds {
                await endUtterance(current)
            }
        }

        if let state = utterance, !Task.isCancelled, !box.isCancelled {
            await endUtterance(state)
        }
        if let session = live { await session.cancel() }
        emit()
    }

    /// Commit one live request and wait for its single final. An early final
    /// is returned as-is instead of forcing a second commit (which the
    /// adapter correctly rejects once its stream is terminal).
    private func transcribeLive(session: CloudLiveUtterance) async throws -> String {
        recoveryStatus.begin()
        defer { recoveryStatus.end() }
        var snapshot = session.snapshot
        if let final = snapshot.final { return final }
        if let failure = snapshot.failure { throw failure }
        do {
            try await session.session.endUtterance()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            snapshot = await session.settledSnapshot()
            if let final = snapshot.final { return final }
            if let failure = snapshot.failure { throw failure }
            throw CloudSpeechErrorMapping.failure(from: error, snapshot: snapshot)
        }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await session.eventTask.value
                return true
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(Self.finalTimeoutSeconds)) }
                catch { return false }
                return false
            }
            let first = await group.next() ?? false
            // A cancelled waiter cannot cancel an unstructured event task.
            // Close the transport before joining that child on timeout/cancel.
            if !first { await session.cancelTransport() }
            group.cancelAll()
            return first
        }
        await session.cancelTransport()
        try Task.checkCancellation()
        guard finished else { throw ASRTranscriptionError.transport(.timedOut) }
        snapshot = session.snapshot
        if let final = snapshot.final { return final }
        if let failure = snapshot.failure { throw failure }
        if snapshot.ended {
            // The server closed without the documented final event. Treat it
            // as a lost request, not a provider rejection, so one bounded
            // reconnect can still recover the utterance.
            throw ASRTranscriptionError.transport(.notReachable)
        }
        throw ASRTranscriptionError.providerRejected
    }

    private func transcribeBatch(_ state: CloudUtteranceState) async throws -> String {
        let credential = try await credentialProvider()
        try Task.checkCancellation()
        let duration = max(state.duration, 0.01)
        let request = ASRFileTranscriptionRequest(
            profile: profile,
            audio: state.wavData,
            filename: "utterance.wav",
            mimeType: "audio/wav",
            languages: language.recognitionCode.map { [$0] } ?? [],
            sourceDurationSeconds: duration)
        let result = try await CloudSpeechTimeout.run(seconds: Self.finalTimeoutSeconds) {
            try await self.fileAdapter.transcribe(request, credential: credential)
        }
        return result.text
    }

    // MARK: - Local recovery

    private func recoverLocally(
        _ state: CloudUtteranceState
    ) async -> String? {
        guard !box.isCancelled, !Task.isCancelled else { return nil }
        recoveryStatus.begin()
        defer { recoveryStatus.end() }
        do {
            guard let local = try await localFallback() else { return nil }
            try Task.checkCancellation()
            let pcm = state.frames.reduce(into: Data()) { $0.append($1.pcm) }
            guard let buffer = CloudPCMCodec.buffer(pcm16: pcm, sampleRate: state.sampleRate) else {
                await local.cancelAudio()
                return nil
            }
            local.feed(buffer, at: nil)
            let box = CloudLocalTranscriptBox()
            let reader = Task {
                for await text in local.transcripts { box.store(text) }
            }
            _ = try? await CloudSpeechTimeout.run(seconds: 10) {
                await local.finishAudio()
                return true
            }
            _ = await CloudSpeechTimeout.runOptional(seconds: 6) {
                await reader.value
            }
            reader.cancel()
            await local.cancelAudio()
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard !Task.isCancelled, !self.box.isCancelled else { return nil }
            return text
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }
}

private final class CloudLiveUtterance: @unchecked Sendable {
    struct Snapshot: Sendable {
        let partial: String
        let final: String?
        let failure: ASRTranscriptionError?
        let ended: Bool
    }

    let session: any ASRLiveSession
    let eventTask: Task<Void, Never>
    private let box = CloudLiveEventBox()

    init(session: any ASRLiveSession) {
        self.session = session
        let box = self.box
        self.eventTask = Task {
            do {
                for try await event in session.events {
                    box.apply(event)
                    if event.kind == .failed { break }
                }
            } catch is CancellationError {
                // Cancellation is not a provider failure.
            } catch {
                box.store(failure: CloudSpeechErrorMapping.failure(from: error))
            }
            box.markEnded()
        }
    }

    var partial: String { box.snapshot().partial }

    var hasFinal: Bool { box.snapshot().final != nil }

    var snapshot: Snapshot {
        let snapshot = box.snapshot()
        return Snapshot(
            partial: snapshot.partial,
            final: snapshot.final,
            failure: snapshot.failure,
            ended: snapshot.ended)
    }

    /// Terminal event delivery is asynchronous relative to a failing
    /// `feed`/`endUtterance` call. Give the event task a short, bounded moment
    /// to publish the real final/failure instead of guessing from the write
    /// error ("the session has already ended").
    func settledSnapshot() async -> Snapshot {
        let deadline = Date().addingTimeInterval(0.1)
        while true {
            let value = snapshot
            if value.final != nil || value.failure != nil || value.ended {
                return value
            }
            if Date() >= deadline { return value }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return value }
        }
    }

    /// Release the failed request and its event task. Awaiting the event task
    /// here keeps stale callbacks from outliving the request they belong to.
    func cancel() async {
        await cancelTransport()
    }

    func cancelTransport() async {
        eventTask.cancel()
        await session.cancel()
        _ = await eventTask.value
    }
}

enum CloudPCMCodec {
    static func wav(pcm16: Data, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + pcm16.count)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        appendLE(UInt32(36 + pcm16.count))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(max(8_000, sampleRate)))
        appendLE(UInt32(max(8_000, sampleRate) * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(Data("data".utf8))
        appendLE(UInt32(pcm16.count))
        data.append(pcm16)
        return data
    }

    static func buffer(pcm16: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
        guard pcm16.count >= 2, pcm16.count % 2 == 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(max(8_000, sampleRate)),
                channels: 1,
                interleaved: false) else { return nil }
        let frames = pcm16.count / 2
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: UInt16.self)
            for index in 0..<frames {
                let value = Int16(bitPattern: UInt16(littleEndian: samples[index]))
                channels[0][index] = Float(value) / 32_768
            }
        }
        return buffer
    }
}

private enum CloudSpeechTimeout {
    static func run<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CloudSpeechFailure.finalTimeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw CloudSpeechFailure.finalTimeout
            }
            return value
        }
    }

    static func runOptional<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}

private extension ASRTranscriptionError {
    static var transportCategory: ASRTranscriptionError { .transport(.notReachable) }
}
#endif
