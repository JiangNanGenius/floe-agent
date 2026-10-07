// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import FloeCore

/// Audio waveform extraction for timeline visualization.
///
/// Reads the asset's audio track through AVAssetReader and reduces it to a
/// bounded array of per-bucket peak amplitudes in 0...1. Decoding failures
/// surface as errors so the UI can keep the placeholder instead of drawing a
/// fake waveform.
public enum MediaWaveformSampler {
    public enum SampleError: Error, LocalizedError, Equatable {
        case noAudioTrack
        case unreadable
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "该素材没有音频轨。"
            case .unreadable: return "无法解码音频素材。"
            case .cancelled: return "已取消。"
            }
        }
    }

    public static let maximumBuckets = 2048
    private static let maximumSeconds: Double = 600

    /// Peak amplitude per bucket across the asset's audio. `bucketCount` is
    /// clamped to `maximumBuckets`; the result always has exactly the
    /// requested count (silent tails pad with 0) so the UI layout is stable.
    public static func peaks(from url: URL, bucketCount: Int = 256) async throws -> [Float] {
        let buckets = max(1, min(bucketCount, maximumBuckets))
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SampleError.noAudioTrack
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0 else { throw SampleError.unreadable }
        // Bounded work: very long audio is sampled from its start segment.
        let readDuration = min(duration, maximumSeconds)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: readDuration, preferredTimescale: 600))
        guard reader.startReading() else { throw SampleError.unreadable }

        let totalFrames = AVAudioFrameCount(readDuration * 44100)
        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var bucketIndex = 0
        var framesInBucket = 0
        var peak: Float = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            let frameCount = length / (2 * 2) // 16-bit stereo interleaved
            var data = Data(count: length)
            var status: OSStatus = noErr
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == noErr else { continue }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for frame in 0..<frameCount {
                    let left = abs(Float(base[frame * 2]))
                    let right = abs(Float(base[frame * 2 + 1]))
                    let sample = max(left, right) / Float(Int16.max)
                    if sample > peak { peak = sample }
                    framesInBucket += 1
                    if framesInBucket >= framesPerBucket, bucketIndex < buckets {
                        peaks[bucketIndex] = peak
                        bucketIndex += 1
                        framesInBucket = 0
                        peak = 0
                    }
                }
            }
            if reader.status == .failed { break }
        }
        if reader.status == .failed, bucketIndex == 0 { throw SampleError.unreadable }
        if bucketIndex < buckets {
            peaks[bucketIndex] = peak
        }
        reader.cancelReading()
        return peaks
    }
}
