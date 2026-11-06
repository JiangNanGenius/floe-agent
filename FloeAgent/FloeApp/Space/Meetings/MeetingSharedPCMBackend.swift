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
    func begin(session: CaptureSessionID, configuration: CaptureConfiguration,
               sink: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        guard self.session == nil else { throw MeetingError.captureAlreadyActive(self.session!) }
        epoch += 1; let generation = epoch
        self.session = session; self.sink = sink
        let channel = AsyncStream<MeetingPCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let writer = try MeetingPCMChunkRecorder(configuration: configuration, session: session)
        self.writer = writer
        let tap = MeetingPCMStreamTap(continuation: channel.continuation) { [weak self] reason in
            Task { await self?.fail(reason, generation: generation) }
        }
        self.tap = tap
        let capturer = AudioEngineCapturer(managesAudioSession: false)
        self.capturer = capturer
        pump = Task { [weak self] in
            do {
                for await frame in channel.stream {
                    try Task.checkCancellation()
                    if let chunk = try await writer.append(frame) { await self?.deliver(chunk, generation: generation) }
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
    private func clear() { session = nil; sink = nil; capturer = nil; tap = nil; writer = nil; pump = nil }
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
