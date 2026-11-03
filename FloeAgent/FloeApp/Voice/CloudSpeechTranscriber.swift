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
// - A cloud failure replays ONLY the uncommitted utterance through a
//   local-only factory (Whisper then Apple as supplied). The partial cloud
//   text is replaced, never appended, and the wrapper never recursively
//   selects another cloud route.
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

/// One converted PCM16 frame with the real measured RMS/duration used by the
/// client VAD. `pcm` is mono little-endian PCM16 at `sampleRate`.
struct CloudAudioFrame: Sendable {
    var pcm: Data
    var sampleRate: Int
    var rms: Float
    var duration: Double

    var isVoiced: Bool { rms >= CloudSpeechTranscriber.voiceGate }
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
    var frames: [Data] = []
    var bytes = 0
    var duration: Double = 0
    var voicedDuration: Double = 0
    var quietRun: Double = 0
    var sampleRate: Int

    mutating func append(_ frame: CloudAudioFrame) {
        frames.append(frame.pcm)
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
        CloudPCMCodec.wav(pcm16: frames.reduce(into: Data()) { $0.append($1) },
                          sampleRate: sampleRate)
    }
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

    private let profile: ASRProfile
    private let language: VoiceRecognitionLanguage
    private let credentialProvider: @Sendable () async throws -> String
    private let fileAdapter: any ASRTranscribing
    private let liveAdapter: (any ASRLiveTranscribing)?
    private let localFallback: @Sendable () async throws -> (any SpeechTranscribing)?
    private let diagnostics: (any VoiceInputDiagnostics)?
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
        diagnostics: (any VoiceInputDiagnostics)? = nil
    ) throws {
        self.profile = profile
        self.language = language
        self.credentialProvider = credentialProvider
        self.localFallback = localFallback
        self.diagnostics = diagnostics
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

    private func run() async {
        var committed: [String] = []
        var utterance: CloudUtteranceState?
        var preroll: [CloudAudioFrame] = []
        var live: CloudLiveUtterance?
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

        func startUtterance(with frames: [CloudAudioFrame]) {
            let sampleRate = frames.last?.sampleRate ?? 16_000
            var state = CloudUtteranceState(sampleRate: sampleRate)
            for frame in frames { state.append(frame) }
            utterance = state
        }

        func commit(_ state: CloudUtteranceState) async throws -> String {
            if mode == .batch {
                return try await transcribeBatch(state)
            }
            guard let live else { throw CloudSpeechFailure.configuration }
            return try await transcribeLive(state, session: live)
        }

        func endUtterance(_ state: CloudUtteranceState) async {
            guard state.voicedDuration >= Self.minimumVoicedSeconds else {
                if let live { await live.cancel() }
                utterance = nil
                emit()
                return
            }
            do {
                let text = try await commit(state)
                try Task.checkCancellation()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    committed.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    completedFinals += 1
                }
                utterance = nil
                if let live { await live.cancel() }
                emit()
            } catch is CancellationError {
                if let live { await live.cancel() }
                utterance = nil
            } catch {
                if let live { await live.cancel() }
                utterance = nil
                if let text = await recoverLocally(state) {
                    committed.append(text)
                    emit()
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
                    // and the same ordered frames are fed to the live session
                    // (the session may have opened after the pre-roll).
                    preroll.append(frame)
                    let opening = preroll
                    preroll = []
                    startUtterance(with: opening)
                    live = await openLiveIfNeeded()
                    if mode == .live, let live {
                        for captured in opening {
                            await feedLiveFrame(captured, session: live)
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
                if mode == .live, let live {
                    await feedLiveFrame(frame, session: live)
                }
            }
            guard let state = utterance else { continue }
            if state.bytes > Self.maximumUtteranceBytes {
                // Bounded speculation: commit what was actually captured
                // rather than growing without limit or dropping audio.
                await endUtterance(state)
                live = nil
                continue
            }
            if mode == .live, let live {
                let partial = live.partial
                if !partial.isEmpty { emit(partial: partial) }
            }
            if state.quietRun >= Self.vadSilenceSeconds,
               state.voicedDuration >= Self.minimumVoicedSeconds {
                await endUtterance(state)
                live = nil
            }
        }

        if let state = utterance, !Task.isCancelled, !box.isCancelled {
            await endUtterance(state)
        }
        if let live { await live.cancel() }
        emit()
    }

    private func openLiveIfNeeded() async -> CloudLiveUtterance? {
        guard mode == .live, let adapter = liveAdapter else { return nil }
        do {
            let credential = try await credentialProvider()
            try Task.checkCancellation()
            let request = ASRLiveSessionRequest(
                profile: profile,
                turnID: UUID(),
                inputSampleRate: profile.provider == .openaiCompatible ? 24_000 : 16_000,
                languages: language.recognitionCode.map { [$0] } ?? [],
                finishTimeoutSeconds: Self.finalTimeoutSeconds)
            let session = try await adapter.startLiveSession(request, credential: credential)
            return CloudLiveUtterance(session: session)
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private func feedLiveFrame(_ frame: CloudAudioFrame, session: CloudLiveUtterance) async {
        do {
            try await session.session.feed(frame.pcm)
        } catch is CancellationError {
            return
        } catch {
            session.note(error: .transport(.notReachable))
        }
    }

    private func transcribeLive(
        _ state: CloudUtteranceState,
        session: CloudLiveUtterance
    ) async throws -> String {
        if let failure = session.snapshot.failure { throw failure }
        do {
            try await session.session.endUtterance()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudSpeechFailure.transport
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
        guard finished else { throw CloudSpeechFailure.finalTimeout }
        let snapshot = session.snapshot
        if let failure = snapshot.failure { throw failure }
        guard let final = snapshot.final else { throw CloudSpeechFailure.rejected }
        return final
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
        do {
            guard let local = try await localFallback() else { return nil }
            try Task.checkCancellation()
            let pcm = state.frames.reduce(into: Data()) { $0.append($1) }
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
    let session: any ASRLiveSession
    let eventTask: Task<Void, Never>
    private let box = CloudLiveEventBox()
    private let lock = NSLock()
    private var storedFailure: ASRTranscriptionError?

    init(session: any ASRLiveSession) {
        self.session = session
        let box = self.box
        self.eventTask = Task {
            do {
                for try await event in session.events {
                    box.apply(event)
                    if event.kind == .failed { break }
                }
            } catch {
                box.markEnded()
            }
            box.markEnded()
        }
    }

    func note(error: ASRTranscriptionError) {
        lock.withLock { if storedFailure == nil { storedFailure = error } }
    }

    var partial: String { box.snapshot().partial }

    var snapshot: (final: String?, failure: ASRTranscriptionError?) {
        let snapshot = box.snapshot()
        let stored = lock.withLock { storedFailure }
        return (snapshot.final, snapshot.failure ?? stored)
    }

    func cancel() async {
        eventTask.cancel()
        await session.cancel()
    }

    func cancelTransport() async {
        eventTask.cancel()
        await session.cancel()
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
