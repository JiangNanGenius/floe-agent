// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import AVFoundation
import Speech
import FloeCore
@preconcurrency import WhisperKit

struct TimedSpeechSegment: Sendable, Codable {
    struct Word: Sendable, Codable { let start: Double; let end: Double; let text: String }
    let start: Double
    let end: Double
    let text: String
    let words: [Word]
}

enum FileSpeechEngine: String, Sendable, Equatable {
    case enhanced
    case apple
}

struct FileSpeechResult: Sendable {
    let segments: [TimedSpeechSegment]
    let engine: FileSpeechEngine
}

enum FileSpeechError: Error, LocalizedError, Sendable {
    case invalidAudio, unavailable, timedOut, empty
    var errorDescription: String? {
        switch self {
        case .invalidAudio: FloeL10n.l("voice.file_speech_transcriber.could_not_read_the_asset_s")
        case .unavailable: FloeL10n.l("voice.file_speech_transcriber.whisper_is_unavailable_and_apple_speech")
        case .timedOut: FloeL10n.l("voice.file_speech_transcriber.apple_speech_recognition_timed_out_please")
        case .empty: FloeL10n.l("voice.file_speech_transcriber.no_usable_speech_recognized")
        }
    }
}

/// One file/caption decode pass. The worker returns this instead of throwing
/// across the runtime worker boundary, so the actor can report the correct
/// warm-model health even when cancellation interrupts a decoder fault.
private enum FileDecodeOutcome: Sendable {
    case success(segments: [TimedSpeechSegment], engine: FileSpeechEngine, decoderFault: Bool)
    case failure(FileSpeechError, decoderFault: Bool)
    case cancelled(decoderFault: Bool)
}

/// Writes the worker outcome exactly once. The worker is attached to the
/// runtime lease so memory pressure can cancel and join it before unmount.
private final class FileDecodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FileDecodeOutcome?

    func set(_ value: FileDecodeOutcome) {
        lock.withLock { stored = value }
    }

    var value: FileDecodeOutcome? { lock.withLock { stored } }
}

/// The file path used by captions and file tools. No microphone, exported audio copy,
/// API key or cloud vendor SDK is needed. Each decoder retains at most 25 seconds.
actor FileSpeechTranscriber {
    static let shared = FileSpeechTranscriber()
    private var active = false

    func transcribe(url: URL, language: VoiceRecognitionLanguage,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TimedSpeechSegment] {
        try await transcribeResult(url: url, language: language,
            allowAppleFallback: true, progress: progress).segments
    }

    /// File path used by assistant tools. `engine` reports the recognizer that
    /// actually produced the segments; a hidden Apple fallback is never
    /// presented as the enhanced model. `allowAppleFallback` keeps the
    /// historical automatic behavior when true and fails honestly when false.
    func transcribeResult(url: URL, language: VoiceRecognitionLanguage,
                          allowAppleFallback: Bool = true,
                          preferApple: Bool = false,
                          progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> FileSpeechResult {
        guard !active else { throw WhisperModelStore.Failure.busy }
        active = true; defer { active = false }
        guard url.isFileURL else { throw FileSpeechError.invalidAudio }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FileSpeechError.invalidAudio }

        // A file/caption pass is a REAL exclusive session on the same model
        // owner as dictation and continuous voice. Its decode runs inside a
        // runtime-attached worker, so memory pressure cancels and joins the
        // worker before the model is unmounted. A healthy end keeps the
        // foreground warm model; this path never unloads it directly.
        if preferApple {
            let outcome = await Self.decodeFile(
                asset: asset, track: track, duration: duration, language: language,
                allowAppleFallback: allowAppleFallback, lease: nil, progress: progress)
            return try await finish(outcome, lease: nil)
        }

        var lease: SpeechRecognitionLease?
        do {
            lease = try await SpeechRecognitionRuntime.live.acquireForTimedTranscription()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }
        guard let lease else {
            // Model unavailable or busy: the Apple fallback below decides
            // honestly when the caller allows it.
            let outcome = await Self.decodeFile(
                asset: asset, track: track, duration: duration, language: language,
                allowAppleFallback: allowAppleFallback, lease: nil, progress: progress)
            return try await finish(outcome, lease: nil)
        }

        let box = FileDecodeBox()
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task<Void, Never> {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            guard !Task.isCancelled else {
                box.set(.cancelled(decoderFault: false))
                return
            }
            // AVAsset/AVAssetTrack are not Sendable. This worker owns its own
            // handles; the actor retains the preflight handles solely for the
            // joined-worker rejection/fallback branch below.
            let workerAsset = AVURLAsset(url: url)
            do {
                guard let workerTrack = try await workerAsset.loadTracks(withMediaType: .audio).first else {
                    box.set(.failure(.invalidAudio, decoderFault: false))
                    return
                }
                let outcome = await Self.decodeFile(
                    asset: workerAsset, track: workerTrack, duration: duration, language: language,
                    allowAppleFallback: allowAppleFallback, lease: lease, progress: progress)
                box.set(outcome)
            } catch is CancellationError {
                box.set(.cancelled(decoderFault: false))
            } catch {
                box.set(.failure(.invalidAudio, decoderFault: false))
            }
        }
        let start = gateContinuation
        guard await lease.attachWorker(worker, start: { start.finish() }) else {
            // The claim was retired between acquire and attachment. The
            // runtime already cancelled the worker and opened its gate; join
            // it, then use the honest Apple-only path.
            await worker.value
            try Task.checkCancellation()
            let outcome = await Self.decodeFile(
                asset: asset, track: track, duration: duration, language: language,
                allowAppleFallback: allowAppleFallback, lease: nil, progress: progress)
            return try await finish(outcome, lease: nil)
        }

        let outcome = await withTaskCancellationHandler {
            await worker.value
            return box.value ?? .cancelled(decoderFault: false)
        } onCancel: {
            // Consumer cancellation must reach the attached worker; the
            // runtime retirement paths cancel it directly too.
            worker.cancel()
        }
        if Task.isCancelled {
            await lease.sessionEnded(healthy: true)
            throw CancellationError()
        }
        return try await finish(outcome, lease: lease)
    }

    /// Reports the worker's exit once with the correct warm-model health.
    /// Cancellation is not decoder corruption; a real model error is.
    private func finish(_ outcome: FileDecodeOutcome,
                        lease: SpeechRecognitionLease?) async throws -> FileSpeechResult {
        switch outcome {
        case .success(let segments, let engine, let decoderFault):
            await lease?.sessionEnded(healthy: !decoderFault)
            return FileSpeechResult(segments: segments, engine: engine)
        case .failure(let error, let decoderFault):
            await lease?.sessionEnded(healthy: !decoderFault)
            throw error
        case .cancelled(let decoderFault):
            await lease?.sessionEnded(healthy: !decoderFault)
            throw CancellationError()
        }
    }

    /// The actual chunk loop. It runs inside the attached worker for the
    /// model path, so a memory-pressure cancel reaches it and the runtime
    /// joins it before unmount. It never unloads the model itself.
    private static func decodeFile(
        asset: AVAsset,
        track: AVAssetTrack,
        duration: Double,
        language: VoiceRecognitionLanguage,
        allowAppleFallback: Bool,
        lease: SpeechRecognitionLease?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> FileDecodeOutcome {
        var output: [TimedSpeechSegment] = []
        var offset = 0.0
        var appleAuthorized = false
        var usedEngine: FileSpeechEngine?
        var decoderFault = false

        do {
            while offset < duration {
                try Task.checkCancellation()
                let length = min(25, duration - offset)
                let audio: [Float]
                do {
                    audio = try SpeechAudioChunk.read(asset: asset, track: track, start: offset, duration: length)
                } catch is CancellationError {
                    return .cancelled(decoderFault: decoderFault)
                } catch let error as FileSpeechError {
                    return .failure(error, decoderFault: decoderFault)
                } catch {
                    return .failure(.invalidAudio, decoderFault: decoderFault)
                }

                let energy = audio.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, audio.count))
                if energy >= 0.000_01 {
                    var segments: [TimedSpeechSegment]?
                    if let lease, !decoderFault {
                        do {
                            let decoded = try await lease.model.transcribeTimed(
                                audio: audio,
                                decoding: SpeechRecognitionDecoding(
                                    languageCode: language.recognitionCode,
                                    detectLanguage: language.recognitionCode == nil))
                            guard !decoded.isEmpty else { throw FileSpeechError.empty }
                            segments = decoded.map { segment in
                                let value = segment.offsetting(by: offset)
                                return TimedSpeechSegment(
                                    start: value.start, end: value.end, text: value.text,
                                    words: value.words.map { .init(start: $0.start, end: $0.end, text: $0.text) })
                            }
                            usedEngine = .enhanced
                        } catch is CancellationError {
                            return .cancelled(decoderFault: decoderFault)
                        } catch {
                            if Task.isCancelled {
                                return .cancelled(decoderFault: decoderFault)
                            }
                            // An empty decode is no-speech, not decoder
                            // corruption. A real model error marks the lease
                            // unhealthy, but the file path never unloads the
                            // model directly.
                            if let speechError = error as? FileSpeechError,
                               case .empty = speechError {
                                decoderFault = false
                            } else {
                                decoderFault = true
                            }
                        }
                    }
                    if segments == nil {
                        guard allowAppleFallback else {
                            return .failure(.unavailable, decoderFault: decoderFault)
                        }
                        if !appleAuthorized {
                            guard await SystemSpeechAuthorizationProvider.requestAppleAccess() else {
                                return .failure(.unavailable, decoderFault: decoderFault)
                            }
                            appleAuthorized = true
                        }
                        do {
                            let words = try await AppleSpeechChunk().recognize(audio: audio, locale: language.locale)
                            segments = Self.captionGroups(words: words, offset: offset, length: length)
                            if usedEngine == nil { usedEngine = .apple }
                        } catch is CancellationError {
                            return .cancelled(decoderFault: decoderFault)
                        } catch let error as FileSpeechError {
                            return .failure(error, decoderFault: decoderFault)
                        } catch {
                            return .failure(.unavailable, decoderFault: decoderFault)
                        }
                    }
                    output.append(contentsOf: segments ?? [])
                    // Text is bounded too; an enormous asset must be split explicitly.
                    guard output.count <= 100_000 else {
                        return .failure(.invalidAudio, decoderFault: decoderFault)
                    }
                }
                offset += length
                progress(min(1, offset / duration))
            }
            try Task.checkCancellation()
            guard !output.isEmpty else {
                return .failure(.empty, decoderFault: decoderFault)
            }
            return .success(segments: output, engine: usedEngine ?? .apple, decoderFault: decoderFault)
        } catch is CancellationError {
            return .cancelled(decoderFault: decoderFault)
        } catch let error as FileSpeechError {
            return .failure(error, decoderFault: decoderFault)
        } catch {
            return .failure(.invalidAudio, decoderFault: decoderFault)
        }
    }

    private static func captionGroups(words: [TimedSpeechSegment.Word], offset: Double, length: Double) -> [TimedSpeechSegment] {
        var groups: [[TimedSpeechSegment.Word]] = []
        for word in words where word.start.isFinite && word.end.isFinite && word.end > word.start && word.start < length {
            let item = TimedSpeechSegment.Word(start: offset + max(0, word.start), end: offset + min(length, word.end), text: word.text)
            if let last = groups.last, let first = last.first, item.end - first.start <= 5, last.count < 12 {
                groups[groups.count - 1].append(item)
            } else { groups.append([item]) }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return .init(start: first.start, end: last.end, text: group.map(\.text).joined(separator: " "), words: group)
        }
    }
}

/// Places decoded samples using their presentation timestamps, including delayed tracks
/// and gaps, so captions stay in the original video's time coordinate system.
enum SpeechAudioChunk {
    static func read(asset: AVAsset, track: AVAssetTrack, start: Double, duration: Double) throws -> [Float] {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 25 else { throw FileSpeechError.invalidAudio }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: CMTime(seconds: duration, preferredTimescale: 16000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileSpeechError.invalidAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FileSpeechError.invalidAudio }
        var samples = [Float](repeating: 0, count: Int(ceil(duration * 16000)))
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(buffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard count > 0, count <= 400_000, timestamp.isFinite,
                  let block = CMSampleBufferGetDataBuffer(buffer), CMBlockBufferGetDataLength(block) == count * 4 else { throw FileSpeechError.invalidAudio }
            var decoded = [Float](repeating: 0, count: count)
            let status = decoded.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw FileSpeechError.invalidAudio }
            let delta = (timestamp - start) * 16000
            guard delta >= -Double(count), delta <= Double(samples.count) else { continue }
            let position = Int(delta.rounded())
            let lower = max(0, -position), upper = min(count, samples.count - position)
            if lower < upper {
                for index in lower..<upper { samples[position + index] = decoded[index].isFinite ? decoded[index] : 0 }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? FileSpeechError.invalidAudio }
        return samples
    }
}

/// Completion, timeout and cancellation share exactly one continuation. A callback
/// arriving after cancellation cannot resume the caller again or retain its audio.
private final class AppleSpeechChunk: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<[TimedSpeechSegment.Word], any Error>?
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?

    func recognize(audio: [Float], locale: Locale) async throws -> [TimedSpeechSegment.Word] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock { () -> Bool in
                    guard !finished else { return true }
                    self.continuation = continuation; return false
                }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
                      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
                      let channel = buffer.floatChannelData?[0] else { complete(.failure(FileSpeechError.unavailable)); return }
                buffer.frameLength = AVAudioFrameCount(audio.count)
                audio.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress { channel.update(from: base, count: source.count) }
                }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = false
                request.taskHint = .dictation
                let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    if let result, result.isFinal {
                        let words = result.bestTranscription.segments.map { segment in
                            TimedSpeechSegment.Word(start: segment.timestamp, end: segment.timestamp + segment.duration, text: segment.substring)
                        }
                        self?.complete(.success(words))
                    } else if let error { self?.complete(.failure(error)) }
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)); self?.complete(.failure(FileSpeechError.timedOut)) }
                    catch { }
                }
                let ended = lock.withLock { () -> Bool in
                    guard !finished else { return true }
                    self.recognizer = recognizer; self.task = task; self.timeout = timeout; return false
                }
                if ended { timeout.cancel(); task.cancel() }
                else { request.append(buffer); request.endAudio() }
            }
        } onCancel: { self.complete(.failure(CancellationError())) }
    }
    private func complete(_ result: Result<[TimedSpeechSegment.Word], any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<[TimedSpeechSegment.Word], any Error>?, SFSpeechRecognitionTask?, Task<Void, Never>?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let value = (continuation, task, timeout)
            continuation = nil; task = nil; timeout = nil; recognizer = nil
            return value
        }
        pending.2?.cancel(); pending.1?.cancel(); pending.0?.resume(with: result)
    }
}
#endif
