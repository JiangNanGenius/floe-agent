// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import AVFoundation
import Speech
@preconcurrency import WhisperKit

struct TimedSpeechSegment: Sendable, Codable {
    struct Word: Sendable, Codable { let start: Double; let end: Double; let text: String }
    let start: Double
    let end: Double
    let text: String
    let words: [Word]
}

enum FileSpeechError: Error, LocalizedError {
    case invalidAudio, unavailable, timedOut, empty
    var errorDescription: String? {
        switch self {
        case .invalidAudio: "无法读取素材的音轨。"
        case .unavailable: "Whisper 不可用，Apple 语音识别也无法启动。请检查模型和语音权限。"
        case .timedOut: "Apple 语音识别超时，请重试。"
        case .empty: "没有识别到可用语音。"
        }
    }
}

/// The file path used by captions and file tools. No microphone, exported audio copy,
/// API key or cloud vendor SDK is needed. Each decoder retains at most 25 seconds.
actor FileSpeechTranscriber {
    static let shared = FileSpeechTranscriber()
    private var active = false

    func transcribe(url: URL, language: VoiceRecognitionLanguage,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TimedSpeechSegment] {
        guard !active else { throw WhisperModelStore.Failure.busy }
        active = true; defer { active = false }
        guard url.isFileURL else { throw FileSpeechError.invalidAudio }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FileSpeechError.invalidAudio }
        var kit: WhisperKit?
        var lease: UUID?
        do {
            let acquired = try await WhisperModelStore.shared.acquire()
            lease = acquired.0
            kit = try await WhisperKit(WhisperKitConfig(modelFolder: acquired.1.appendingPathComponent("model").path,
                tokenizerFolder: acquired.1.appendingPathComponent("tokenizer"), verbose: false, prewarm: false, load: true, download: false))
        } catch {
            if let lease { await WhisperModelStore.shared.release(lease) }
            lease = nil
            try Task.checkCancellation()
        }
        do {
            var output: [TimedSpeechSegment] = []
            var offset = 0.0
            var appleAuthorized = false
            while offset < duration {
                try Task.checkCancellation()
                let length = min(25, duration - offset)
                let audio = try SpeechAudioChunk.read(asset: asset, track: track, start: offset, duration: length)
                let energy = audio.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, audio.count))
                if energy >= 0.000_01 {
                    var segments: [TimedSpeechSegment]?
                    if let whisper = kit {
                        do {
                            let code: String? = language == .automatic ? nil : language == .english ? "en" : "zh"
                            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: DecodingOptions(
                                language: code, detectLanguage: code == nil, skipSpecialTokens: true,
                                withoutTimestamps: false, wordTimestamps: true))
                            let decoded = results.flatMap(\.segments).compactMap { item -> TimedSpeechSegment? in
                                let start = max(0, Double(item.start)), end = min(length, Double(item.end))
                                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard start.isFinite, end.isFinite, end > start, !text.isEmpty else { return nil }
                                let words = (item.words ?? []).compactMap { word -> TimedSpeechSegment.Word? in
                                    let a = max(start, Double(word.start)), b = min(end, Double(word.end))
                                    guard a.isFinite, b.isFinite, b > a else { return nil }
                                    return .init(start: offset + a, end: offset + b, text: word.word)
                                }
                                return .init(start: offset + start, end: offset + end, text: text, words: words)
                            }
                            guard !decoded.isEmpty else { throw FileSpeechError.empty }
                            segments = decoded
                        } catch {
                            try Task.checkCancellation()
                            // Keep the lease until the inference and unload have both returned.
                            await whisper.unloadModels(); kit = nil
                            if let lease { await WhisperModelStore.shared.release(lease) }
                            lease = nil
                        }
                    }
                    if segments == nil {
                        if !appleAuthorized {
                            guard await SystemSpeechAuthorizationProvider.requestAppleAccess() else { throw FileSpeechError.unavailable }
                            appleAuthorized = true
                        }
                        let words = try await AppleSpeechChunk().recognize(audio: audio, locale: language.locale)
                        segments = Self.captionGroups(words: words, offset: offset, length: length)
                    }
                    output.append(contentsOf: segments ?? [])
                    // Text is bounded too; an enormous asset must be split explicitly.
                    guard output.count <= 100_000 else { throw FileSpeechError.invalidAudio }
                }
                offset += length
                progress(min(1, offset / duration))
            }
            try Task.checkCancellation()
            guard !output.isEmpty else { throw FileSpeechError.empty }
            if let kit { await kit.unloadModels() }
            if let lease { await WhisperModelStore.shared.release(lease) }
            return output
        } catch {
            if let kit { await kit.unloadModels() }
            if let lease { await WhisperModelStore.shared.release(lease) }
            throw error
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
