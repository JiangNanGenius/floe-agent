// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import FloeMusicCore

public struct MusicDJBeatEstimate: Sendable, Codable, Hashable {
    public let bpm: Double?
    public let firstBeatSample: Int64
    public let confidence: Double
    public let analyzedSeconds: Double
    public let assetID: MusicAssetID
    public let assetContentHash: String
}

/// Bounded onset-envelope analysis of the verified audio, never the song's
/// arrangement BPM. An ambiguous or silent source remains manually editable;
/// no synthetic beat grid is presented as a detected result.
public enum MusicDJBeatAnalysis {
    public static func analyze(_ prepared: MusicDJPreparedSource, projectSampleRate: Int,
                               maximumSeconds: Double = 180) async throws -> MusicDJBeatEstimate {
        guard maximumSeconds.isFinite, maximumSeconds >= 4, maximumSeconds <= 600,
              projectSampleRate >= MusicTempoMap.minSampleRate, projectSampleRate <= MusicTempoMap.maxSampleRate else {
            throw MusicNativeError.invalid("DJ beat analysis range")
        }
        let job = Task.detached(priority: .utility) {
            let file = try prepared.open()
            let rate = file.processingFormat.sampleRate
            guard file.processingFormat.commonFormat == .pcmFormatFloat32,
                  !file.processingFormat.isInterleaved,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
                throw MusicNativeError.unsupported("DJ beat analysis PCM format")
            }
            let limit = min(file.length, Int64(maximumSeconds * rate))
            let binFrames = max(1, Int(rate / 100))
            var energy: [Double] = []; energy.reserveCapacity(Int(maximumSeconds * 101))
            var sum = 0.0, binCount = 0, read: Int64 = 0
            while read < limit {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4_096, limit - read)))
                guard buffer.frameLength > 0, let pcm = buffer.floatChannelData else { break }
                for index in 0..<Int(buffer.frameLength) {
                    var mono = 0.0
                    for channel in 0..<Int(file.processingFormat.channelCount) { mono += Double(pcm[channel][index]) }
                    mono /= Double(file.processingFormat.channelCount)
                    guard mono.isFinite else { throw MusicNativeError.invalid("non-finite DJ source samples") }
                    sum += mono * mono; binCount += 1
                    if binCount == binFrames { energy.append(sqrt(sum / Double(binCount))); sum = 0; binCount = 0 }
                }
                read += Int64(buffer.frameLength)
            }
            let binRate = rate / Double(binFrames)
            var onset = Array(repeating: 0.0, count: energy.count)
            for i in energy.indices {
                let previous = energy[max(0, i - 3)..<i]
                let baseline = previous.isEmpty ? 0 : previous.reduce(0, +) / Double(previous.count)
                onset[i] = max(0, energy[i] - baseline)
            }
            let onsetPower = onset.reduce(0) { $0 + $1 * $1 }
            var bestLag = 0, bestScore = 0.0, bestCorrelation = 0.0
            if onsetPower > 1e-8, onset.count >= Int(binRate * 4) {
                for lag in Int(60 * binRate / 240)...Int(60 * binRate / 40) where lag < onset.count / 2 {
                    try Task.checkCancellation()
                    var cross = 0.0, a = 0.0, b = 0.0
                    for i in lag..<onset.count {
                        cross += onset[i] * onset[i - lag]; a += onset[i] * onset[i]; b += onset[i - lag] * onset[i - lag]
                    }
                    let correlation = a > 0 && b > 0 ? cross / sqrt(a * b) : 0
                    let bpm = 60 * binRate / Double(lag)
                    let score = correlation - 0.025 * abs(log2(bpm / 120))
                    if score > bestScore { bestScore = score; bestLag = lag; bestCorrelation = correlation }
                }
            }
            var first = 0
            if bestLag > 0 {
                let threshold = (onset.max() ?? 0) * 0.25
                first = onset.indices.first(where: { onset[$0] >= threshold && onset[$0] > 0 }) ?? 0
            }
            let confidence = min(1, max(0, bestCorrelation))
            return MusicDJBeatEstimate(bpm: bestLag > 0 && confidence >= 0.3 ? 60 * binRate / Double(bestLag) : nil,
                firstBeatSample: Int64((Double(first) / binRate * Double(projectSampleRate)).rounded()),
                confidence: confidence, analyzedSeconds: Double(read) / rate,
                assetID: prepared.source.asset.id, assetContentHash: prepared.source.asset.contentHash)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
