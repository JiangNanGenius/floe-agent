// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import FloeMeetings
import FloeMeetingsAV

/// Adapts the existing single AVAudioEngine capture seam. The host already
/// holds NativeCreativeAudioSession; this adapter cannot request permission,
/// set the category or create another microphone engine.
actor MeetingSharedPCMBackend: MeetingCaptureBackend {
    private var epoch = 0
    private var session: CaptureSessionID?
    private var capturer: AudioEngineCapturer?
    private var tap: MeetingPCMStreamTap?
    private var writer: MeetingPCMChunkRecorder?
    private var pump: Task<Void, Never>?
    private var sink: (@Sendable (CaptureEvent) -> Void)?
    /// Second consumer of the same copied frames (the continuous live-ASR
    /// coordinator). Lock-protected so the pump calls it without an actor hop;
    /// the closure itself is non-blocking, so a slow or absent recognizer can
    /// never backpressure the microphone, the lossless original or the chunks.
    private nonisolated let asrFeed = MeetingASRFeedBox()

    func setASRFeed(_ feed: (@Sendable (MeetingPCMFrame) -> Void)?) {
        asrFeed.set(feed)
    }

    nonisolated private func feedASR(_ frame: MeetingPCMFrame) {
        asrFeed.get()?(frame)
    }

    func begin(session: CaptureSessionID, configuration: CaptureConfiguration,
               sink: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        guard self.session == nil else { throw MeetingError.captureAlreadyActive(self.session!) }
        epoch += 1; let generation = epoch
        self.session = session; self.sink = sink
        // Bound by real audio duration, not by a transient disk/encoder stall:
        // 128 copied frames cover roughly 2.7 s at a typical tap size. An
        // overflow still fails honestly rather than silently dropping audio.
        let channel = AsyncStream<MeetingPCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(128))
        // The VAD flush owns ordinary sentence boundaries. The time cap is a
        // safety bound for truly continuous speech, not a 3 s sentence
        // cutter; 12 s keeps one request sentence-shaped while still bounding
        // a single decode.
        let chunkSeconds: Double = 12
        let writer = try MeetingPCMChunkRecorder(
            configuration: configuration, session: session, chunkSeconds: chunkSeconds)
        self.writer = writer
        let tap = MeetingPCMStreamTap(continuation: channel.continuation) { [weak self] reason in
            Task { await self?.fail(reason, generation: generation) }
        }
        self.tap = tap
        let capturer = AudioEngineCapturer(managesAudioSession: false)
        self.capturer = capturer
        pump = Task { [weak self] in
            var utterance = VoiceConversationUtteranceGate()
            do {
                for await frame in channel.stream {
                    try Task.checkCancellation()
                    // Reuse the voice pipeline's measured-RMS pause gate in
                    // this source's actual sample-rate domain. The recorder
                    // always writes every frame to the continuous original.
                    utterance.voicedSamplesRequired = max(1, Int(frame.sampleRate * 0.35))
                    utterance.silenceTailSamplesRequired = max(1, Int(frame.sampleRate * 0.55))
                    utterance.process(rms: frame.rms, samples: frame.frameCount)
                    if let chunk = try await writer.append(frame, endOfUtterance: utterance.shouldFlush) {
                        // A VAD flush is a sentence boundary; a time-capped
                        // chunk is not. Only the former resets the gate, so
                        // a pause just after the cap still flushes the same
                        // utterance instead of merging it into the next cap.
                        if chunk.range.duration < chunkSeconds - 0.05 {
                            utterance.noteDecoded()
                        }
                        await self?.deliver(chunk, generation: generation)
                    }
                    // No actor hop: the box's short lock is the only shared
                    // state, and the recognizer queues a bounded frame.
                    self?.feedASR(frame)
                }
            } catch { await self?.fail(error.localizedDescription, generation: generation) }
        }
        do {
            try await capturer.start(into: tap)
            try await capturer.waitUntilReady()
            guard self.epoch == generation, self.session == session else { throw CancellationError() }
            sink(.started(session: session))
        } catch { await cancel(); throw error }
    }
    func requestStop() async {
        guard let session, let writer else { return }
        let generation = epoch
        capturer?.stop(); await tap?.finishAudio()
        await pump?.value
        guard generation == epoch, self.session == session else { return }
        do {
            if let chunk = try await writer.finish() { sink?(.chunkFinalized(session: session, file: chunk.file, range: chunk.range)) }
            sink?(.stopped(session: session, reason: .userStopped))
        } catch { sink?(.failed(session: session, message: error.localizedDescription)) }
        clear()
    }
    func cancel() async {
        guard let old = session else { return }
        epoch += 1; let callback = sink
        capturer?.stop(); await tap?.cancelAudio(); pump?.cancel(); await pump?.value
        await writer?.cancel(); clear()
        callback?(.cancelled(session: old))
    }
    func currentTime() async -> Double? { await writer?.currentTime }
    private func deliver(_ chunk: MeetingPCMChunk, generation: Int) {
        guard generation == epoch, let session else { return }
        sink?(.chunkFinalized(session: session, file: chunk.file, range: chunk.range))
    }
    private func fail(_ reason: String, generation: Int) async {
        guard generation == epoch, let old = session else { return }
        epoch += 1
        capturer?.stop(); await tap?.cancelAudio(); await writer?.cancel()
        sink?(.failed(session: old, message: reason)); clear()
    }
    private func clear() {
        session = nil; sink = nil; capturer = nil; tap = nil; writer = nil; pump = nil
        asrFeed.set(nil)
    }
}

private final class MeetingASRFeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: (@Sendable (MeetingPCMFrame) -> Void)?
    func set(_ value: (@Sendable (MeetingPCMFrame) -> Void)?) {
        lock.withLock { feed = value }
    }
    func get() -> (@Sendable (MeetingPCMFrame) -> Void)? {
        lock.withLock { feed }
    }
}

private final class MeetingPCMStreamTap: SpeechTranscribing, @unchecked Sendable {
    let transcripts = AsyncStream<String> { $0.finish() }
    private let continuation: AsyncStream<MeetingPCMFrame>.Continuation
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var closed = false
    init(continuation: AsyncStream<MeetingPCMFrame>.Continuation, onFailure: @escaping @Sendable (String) -> Void) {
        self.continuation = continuation; self.onFailure = onFailure
    }
    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard !lock.withLock({ closed }) else { return }
        do {
            guard buffer.frameLength > 0 else { return }
            if case .dropped = continuation.yield(try MeetingPCMFrame(copying: buffer)) {
                fail("Audio recording could not keep up; captured files have been preserved.")
            }
        } catch { fail(error.localizedDescription) }
    }
    func finishAudio() async { close() }
    func cancelAudio() async { close() }
    private func close() {
        let finish = lock.withLock { let prior = closed; closed = true; return !prior }
        if finish { continuation.finish() }
    }
    private func fail(_ reason: String) {
        let first = lock.withLock { let prior = closed; closed = true; return !prior }
        if first { continuation.finish(); onFailure(reason) }
    }
}
#endif
