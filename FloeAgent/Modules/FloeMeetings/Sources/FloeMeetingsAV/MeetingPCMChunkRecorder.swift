// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation)
import AVFoundation
import Foundation
import FloeMeetings

/// A copied, bounded mono frame. No AVAudioPCMBuffer/pointer crosses an
/// actor hop after AVAudioEngine is allowed to reuse its tap buffer.
public struct MeetingPCMFrame: Sendable {
    public let data: Data
    public let frameCount: Int
    public let sampleRate: Double
    /// Native measured energy for the existing utterance gate. No second
    /// microphone, recognizer or timeline is involved.
    public var rms: Float {
        guard frameCount > 0, data.count == frameCount * MemoryLayout<Float>.size else { return 0 }
        return data.withUnsafeBytes { bytes in
            var sum: Float = 0
            for index in 0..<frameCount {
                let sample = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                sum += sample * sample
            }
            return sqrt(sum / Float(frameCount))
        }
    }
    public init(copying buffer: AVAudioPCMBuffer) throws {
        let count = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard (1...16_384).contains(count), (1...16).contains(channels),
              buffer.format.sampleRate.isFinite, (8_000...192_000).contains(buffer.format.sampleRate) else {
            throw MeetingError.captureBackendFailed("Invalid PCM format.")
        }
        let audio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let interleaved = buffer.format.isInterleaved
        let live = interleaved ? 1 : channels
        guard audio.count >= live else { throw MeetingError.captureBackendFailed("Incomplete PCM buffer.") }
        var mono = [Float](repeating: 0, count: count)
        if let planes = buffer.floatChannelData {
            for channel in 0..<channels {
                let plane = interleaved ? 0 : channel
                guard Int(audio[plane].mDataByteSize) >= count * (interleaved ? channels : 1) * MemoryLayout<Float>.size else {
                    throw MeetingError.captureBackendFailed("Incomplete PCM samples.")
                }
                for frame in 0..<count {
                    let sample = planes[plane][interleaved ? frame * channels + channel : frame]
                    guard sample.isFinite else { throw MeetingError.captureBackendFailed("Invalid PCM sample.") }
                    mono[frame] += sample / Float(channels)
                }
            }
        } else if let planes = buffer.int16ChannelData {
            for channel in 0..<channels {
                let plane = interleaved ? 0 : channel
                guard Int(audio[plane].mDataByteSize) >= count * (interleaved ? channels : 1) * MemoryLayout<Int16>.size else {
                    throw MeetingError.captureBackendFailed("Incomplete PCM samples.")
                }
                for frame in 0..<count {
                    mono[frame] += Float(planes[plane][interleaved ? frame * channels + channel : frame]) / 32_768 / Float(channels)
                }
            }
        } else { throw MeetingError.captureBackendFailed("Unsupported PCM format.") }
        data = mono.withUnsafeBytes { Data($0) }; frameCount = count; sampleRate = buffer.format.sampleRate
    }
}

public struct MeetingPCMChunk: Sendable {
    public let file: URL
    public let range: MediaTimeRange
}

/// One PCM source writes one continuous lossless original and independent
/// finalized AAC chunks for the host's EXISTING file-ASR service. Rotating a
/// chunk never stops/restarts the microphone or changes the audio session.
public actor MeetingPCMChunkRecorder {
    public let originalURL: URL
    private let directory: URL
    private let session: CaptureSessionID
    private let chunkSeconds: Double
    private var original: AVAudioFile?
    private var chunk: AVAudioFile?
    private var sampleRate: Double?
    private var frames: Int64 = 0
    private var chunkStart: Int64 = 0
    private var chunkIndex = 0
    private var closed = false
    public init(configuration: CaptureConfiguration, session: CaptureSessionID, chunkSeconds: Double = 15) throws {
        guard chunkSeconds.isFinite, (3...60).contains(chunkSeconds) else { throw MeetingError.captureBackendFailed("Invalid chunk duration.") }
        self.originalURL = try Self.originalURL(configuration: configuration, session: session)
        self.directory = configuration.directory.appendingPathComponent("Chunks/" + session.description)
        self.session = session; self.chunkSeconds = chunkSeconds
    }
    public nonisolated static func originalURL(configuration: CaptureConfiguration, session: CaptureSessionID) throws -> URL {
        guard !configuration.filePrefix.isEmpty, !configuration.filePrefix.contains("/"),
              !configuration.filePrefix.contains("\\"), !configuration.filePrefix.contains("\0") else {
            throw MeetingError.captureBackendFailed("Invalid recording filename.")
        }
        return configuration.directory.appendingPathComponent("\(configuration.filePrefix)-\(session.description)-pcm.m4a")
    }
    public var currentTime: Double { sampleRate.map { Double(frames) / $0 } ?? 0 }
    public func append(_ frame: MeetingPCMFrame, endOfUtterance: Bool = false) throws -> MeetingPCMChunk? {
        guard !closed else { throw MeetingError.captureSessionEnded(session) }
        guard frame.data.count == frame.frameCount * MemoryLayout<Float>.size else { throw MeetingError.captureBackendFailed("Invalid PCM data length.") }
        if let sampleRate, sampleRate != frame.sampleRate {
            throw MeetingError.captureBackendFailed("Audio route format changed. The recording so far was preserved.")
        }
        if original == nil {
            sampleRate = frame.sampleRate
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            original = try AVAudioFile(forWriting: originalURL, settings: [
                AVFormatIDKey: Int(kAudioFormatAppleLossless), AVSampleRateKey: frame.sampleRate, AVNumberOfChannelsKey: 1
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let output = buffer.floatChannelData?[0] else { throw MeetingError.captureBackendFailed("Unable to allocate PCM buffer.") }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        frame.data.copyBytes(to: UnsafeMutableRawBufferPointer(start: output, count: frame.data.count))
        if chunk == nil {
            chunkIndex += 1; chunkStart = frames
            let file = directory.appendingPathComponent(String(format: "%06d.m4a", chunkIndex))
            chunk = try AVAudioFile(forWriting: file, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: frame.sampleRate,
                // Let the encoder choose a supported rate for the actual
                // source. A fixed 64 kbps is rejected for some mono routes,
                // including the valid 16 kHz input used by live recovery.
                AVNumberOfChannelsKey: 1
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try original?.write(from: buffer); try chunk?.write(from: buffer)
        frames += Int64(frame.frameCount)
        let elapsed = Double(frames - chunkStart) / frame.sampleRate
        if elapsed >= chunkSeconds || (endOfUtterance && elapsed >= 0.75) { return try closeChunk() }
        return nil
    }
    public func finish() throws -> MeetingPCMChunk? {
        guard !closed else { return nil }
        closed = true
        let final = try closeChunk(); original = nil
        return final
    }
    public func cancel() { closed = true; chunk = nil; original = nil }
    private func closeChunk() throws -> MeetingPCMChunk? {
        guard let file = chunk?.url, let sampleRate, frames > chunkStart else { chunk = nil; return nil }
        chunk = nil // Finalize the container before ASR can open its URL.
        return .init(file: file, range: try .init(start: Double(chunkStart) / sampleRate, end: Double(frames) / sampleRate))
    }
}
#endif
