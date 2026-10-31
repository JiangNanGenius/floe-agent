// FloeApp — Bounded native audio extraction, chunking and timed assembly for
// cloud file/video transcription.
//
// SPDX-License-Identifier: MPL-2.0
//
// The App never uploads an arbitrary movie as raw PCM and never requires a
// public staging URL. AVFoundation decodes the first audio track into a
// bounded 16 kHz mono PCM16 extraction file, then the pipeline uploads
// WAV/PCM chunks of at most four minutes (below Alibaba's five-minute
// synchronous limit and comfortably below the shared byte caps). Chunks are
// assembled in source order with TRUE provider timestamps plus the chunk's
// real offset. A text-only model result is never turned into caption
// alignment: the caller may fall back to the local timed model for a
// timing-required request, otherwise only plain text is returned.

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import FloeCore

struct PreparedCloudAudio: Sendable {
    let url: URL
    let sampleRate: Int
    let frameCount: Int
    let byteCount: Int

    var duration: Double {
        Double(frameCount) / Double(max(sampleRate, 1))
    }

    func removeExtractionFile() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum CloudASRFileError: Error, Equatable {
    case noAudioTrack
    case emptyAudio
    case tooLarge
    case decodeFailed
    case readFailed
    case invalidChunk
}

enum CloudASRAudioExtractor {
    static let maximumExtractedBytes = 192 * 1024 * 1024

    /// Decodes the first audio track to 16 kHz mono PCM16 in an App-private
    /// temporary file. RAM stays bounded by one AVAssetReader sample buffer;
    /// the caller owns the returned file and must remove it.
    static func extract(
        url: URL,
        targetSampleRate: Int = 16_000
    ) async throws -> PreparedCloudAudio {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudASRFileError.decodeFailed
        }
        guard let track = tracks.first else { throw CloudASRFileError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CloudASRFileError.decodeFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(targetSampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CloudASRFileError.decodeFailed }
        reader.add(output)
        guard reader.startReading() else { throw CloudASRFileError.decodeFailed }
        defer { reader.cancelReading() }

        let directory = FileManager.default.temporaryDirectory
        let extraction = directory.appendingPathComponent(
            ".floe-cloud-asr-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: extraction.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: extraction) else {
            try? FileManager.default.removeItem(at: extraction)
            throw CloudASRFileError.readFailed
        }
        var byteCount = 0
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { break }
                defer { CMSampleBufferInvalidate(sample) }
                let data = try Self.pcm16Data(from: sample)
                if !data.isEmpty {
                    byteCount += data.count
                    guard byteCount <= maximumExtractedBytes else {
                        throw CloudASRFileError.tooLarge
                    }
                    try handle.write(contentsOf: data)
                }
            }
            if reader.status == .failed { throw CloudASRFileError.decodeFailed }
            if reader.status == .cancelled { throw CancellationError() }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: extraction)
            throw error
        }
        do {
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: extraction)
            throw CloudASRFileError.readFailed
        }
        guard byteCount >= 2 else {
            try? FileManager.default.removeItem(at: extraction)
            throw CloudASRFileError.emptyAudio
        }
        return PreparedCloudAudio(
            url: extraction,
            sampleRate: targetSampleRate,
            frameCount: byteCount / 2,
            byteCount: byteCount)
    }

    private static func pcm16Data(from sample: CMSampleBuffer) throws -> Data {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 0,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { throw CloudASRFileError.decodeFailed }
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var data = Data()
        for buffer in buffers {
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            data.append(base.assumingMemoryBound(to: UInt8.self),
                        count: Int(buffer.mDataByteSize))
        }
        return data
    }
}

struct CloudASRFileChunk: Sendable {
    let index: Int
    let offsetSeconds: Double
    let durationSeconds: Double
    let wavData: Data
}

enum CloudASRFileChunker {
    /// Four minutes: below the documented five-minute synchronous limit and
    /// ~7.68 MiB at 16 kHz PCM16, well under both provider upload caps.
    static let defaultMaximumSeconds: Double = 240

    static func chunkCount(for prepared: PreparedCloudAudio, maximumSeconds: Double = defaultMaximumSeconds) -> Int {
        let framesPerChunk = max(1, Int(maximumSeconds * Double(prepared.sampleRate)))
        return max(1, (prepared.frameCount + framesPerChunk - 1) / framesPerChunk)
    }

    static func chunk(
        prepared: PreparedCloudAudio,
        index: Int,
        maximumSeconds: Double = defaultMaximumSeconds
    ) throws -> CloudASRFileChunk {
        let framesPerChunk = max(1, Int(maximumSeconds * Double(prepared.sampleRate)))
        let startFrame = index * framesPerChunk
        guard startFrame < prepared.frameCount else { throw CloudASRFileError.invalidChunk }
        let count = min(framesPerChunk, prepared.frameCount - startFrame)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: prepared.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startFrame * 2))
            guard let data = try handle.read(upToCount: count * 2),
                  data.count == count * 2, data.count >= 2 else {
                throw CloudASRFileError.readFailed
            }
            let offset = Double(startFrame) / Double(prepared.sampleRate)
            let duration = Double(count) / Double(prepared.sampleRate)
            return CloudASRFileChunk(
                index: index,
                offsetSeconds: offset,
                durationSeconds: duration,
                wavData: CloudPCMCodec.wav(pcm16: data, sampleRate: prepared.sampleRate))
        } catch let error as CloudASRFileError {
            throw error
        } catch {
            throw CloudASRFileError.readFailed
        }
    }
}

enum CloudASRTimingPolicy {
    /// A timing-required request may use the local timed model instead of
    /// accepting text-only cloud output. The caller decides availability.
    static func requiresLocalTimedFallback(
        requiresTiming: Bool,
        result: ASRTranscriptionResult
    ) -> Bool {
        requiresTiming && result.segments.isEmpty
    }

    static func assembledTiming(
        hasProviderSegments: Bool,
        sourceDuration: Double?
    ) -> ASRTimingProvenance {
        if hasProviderSegments { return .providerSegments }
        if let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 {
            return .sourceSpanOnly
        }
        return .none
    }
}

enum CloudASRFilePipeline {
    /// Transcribes one audio/video file through the supplied profile adapter.
    /// The output keeps true provider timing only; text-only chunks produce
    /// no segments. No destructive de-duplication: legitimate repeated words
    /// and sentences survive in source order.
    static func transcribe(
        fileURL: URL,
        profile: ASRProfile,
        adapter: any ASRTranscribing,
        credential: String,
        language: VoiceRecognitionLanguage,
        requiresTiming: Bool,
        maximumChunkSeconds: Double = CloudASRFileChunker.defaultMaximumSeconds,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ASRTranscriptionResult {
        let prepared = try await CloudASRAudioExtractor.extract(url: fileURL)
        defer { prepared.removeExtractionFile() }
        let count = CloudASRFileChunker.chunkCount(
            for: prepared, maximumSeconds: maximumChunkSeconds)
        var texts: [String] = []
        var segments: [ASRTranscriptionSegment] = []
        var languages: [String] = []
        var hasProviderSegments = false
        var missingRequiredTiming = false
        for index in 0..<count {
            try Task.checkCancellation()
            let chunk = try CloudASRFileChunker.chunk(
                prepared: prepared, index: index, maximumSeconds: maximumChunkSeconds)
            let result = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: chunk.wavData,
                    filename: "floe-chunk-\(index).wav",
                    mimeType: "audio/wav",
                    languages: language.recognitionCode.map { [$0] } ?? [],
                    sourceDurationSeconds: chunk.durationSeconds),
                credential: credential)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
            let segmentCountBeforeChunk = segments.count
            if result.timing == .providerSegments || !result.segments.isEmpty {
                hasProviderSegments = true
                for segment in result.segments {
                    let start = segment.start + chunk.offsetSeconds
                    let end = segment.end + chunk.offsetSeconds
                    guard start.isFinite, end.isFinite, end > start,
                          end <= chunk.offsetSeconds + chunk.durationSeconds + 0.05 else {
                        continue
                    }
                    segments.append(ASRTranscriptionSegment(
                        start: start, end: end, text: segment.text))
                }
            }
            if requiresTiming, !text.isEmpty, segments.count == segmentCountBeforeChunk {
                missingRequiredTiming = true
            }
            if let detected = result.language, !detected.isEmpty,
               !languages.contains(detected) {
                languages.append(detected)
            }
            progress(min(1, Double(index + 1) / Double(count)))
        }
        segments.sort { $0.start < $1.start }
        return ASRTranscriptionResult(
            text: texts.joined(separator: "\n"),
            segments: missingRequiredTiming ? [] : segments,
            language: languages.first ?? language.recognitionCode,
            timing: CloudASRTimingPolicy.assembledTiming(
                hasProviderSegments: hasProviderSegments && !missingRequiredTiming,
                sourceDuration: prepared.duration),
            detectedLanguages: languages)
    }
}
#endif
