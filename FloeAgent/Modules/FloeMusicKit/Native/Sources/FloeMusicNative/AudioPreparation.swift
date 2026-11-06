import AVFoundation
import CryptoKit
import Foundation
import FloeMusicCore

public struct ResolvedMusicSource: Sendable {
    public let asset: MusicAsset
    public let url: URL
    /// The host owns file/security-scope access. Model sourceLocator is never opened.
    public init(asset: MusicAsset, url: URL) { self.asset = asset; self.url = url }
}

public enum MusicAudioPreparation {
    public static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func inspect(url: URL, projectSampleRate: Int = 48_000) throws -> MusicAsset {
        guard url.isFileURL else { throw MusicNativeError.invalid("host must resolve a local file") }
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, (8_000...192_000).contains(projectSampleRate),
              file.length > 0, (1...2).contains(file.processingFormat.channelCount) else {
            throw MusicNativeError.unsupported("audio format or channel layout")
        }
        let samples = (Double(file.length) * Double(projectSampleRate) / rate).rounded()
        guard samples.isFinite, samples > 0, samples < Double(Int64.max) else { throw MusicNativeError.invalid("source length") }
        let kind: MusicAssetKind
        switch url.pathExtension.lowercased() {
        case "mp3": kind = .audioMP3
        case "m4a": kind = .audioM4A
        case "wav", "caf", "aif", "aiff": kind = .audioPCM
        default: kind = .unsupportedRaw(url.pathExtension.lowercased())
        }
        return try MusicAsset(sourceLocator: "host-resolved", contentHash: hashFile(url), kind: kind,
                              durationSamples: MusicSampleTime(Int64(samples)), name: url.lastPathComponent)
    }

    /// Streaming conversion on a service executor, outside the realtime graph.
    /// The destination is a new task-owned derivative; source bytes stay unchanged.
    public static func prepare(_ source: ResolvedMusicSource, sampleRate: Int, destination: URL) throws {
        var phase = "verify source"
        do { try convert(source, sampleRate: sampleRate, destination: destination, phase: &phase) }
        catch let error as MusicNativeError { throw error }
        catch { throw MusicNativeError.render("\(phase): \(String(reflecting: error))") }
    }

    private static func convert(_ source: ResolvedMusicSource, sampleRate: Int, destination: URL, phase: inout String) throws {
        guard !FileManager.default.fileExists(atPath: destination.path),
              try hashFile(source.url) == source.asset.contentHash else { throw MusicNativeError.invalid("source identity or derivative destination") }
        phase = "open source decoder"
        let input = try AVAudioFile(forReading: source.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard (1...2).contains(input.processingFormat.channelCount),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw MusicNativeError.unsupported("audio conversion")
        }
        phase = "open PCM derivative writer"
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: musicPCMFileSettings(format))
        var ended = false
        var readFailure: (any Error)?
        var emptyIterations = 0
        while true {
            try Task.checkCancellation()
            outputBuffer.frameLength = 0
            var conversionFailure: NSError?
            phase = "convert decoded PCM"
            let status = converter.convert(to: outputBuffer, error: &conversionFailure) { requested, inputStatus in
                // Some compressed-file decoders report a failed read with no
                // NSError when asked to read at their exact known EOF.
                if ended || input.framePosition >= input.length { ended = true; inputStatus.pointee = .endOfStream; return nil }
                guard requested > 0 else { inputStatus.pointee = .noDataNow; return nil }
                let count = min(AVAudioFrameCount(min(8192, input.length - input.framePosition)), requested)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                    readFailure = MusicNativeError.invalid("input buffer"); ended = true
                    inputStatus.pointee = .endOfStream; return nil
                }
                do { try input.read(into: buffer) }
                catch {
                    readFailure = MusicNativeError.render("read source PCM at \(input.framePosition)/\(input.length), requested \(requested), capacity \(buffer.frameCapacity), format \(input.processingFormat): \(String(reflecting: error))")
                    ended = true; inputStatus.pointee = .endOfStream; return nil
                }
                guard buffer.frameLength > 0 else {
                    readFailure = MusicNativeError.render("source decoder ended before its declared length")
                    ended = true; inputStatus.pointee = .endOfStream; return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readFailure { throw readFailure }
            if let conversionFailure { throw conversionFailure }
            if outputBuffer.frameLength > 0 {
                phase = "write PCM derivative"
                try output?.write(from: outputBuffer)
                emptyIterations = 0
            } else { emptyIterations += 1 }
            if status == .endOfStream { break }
            guard status != .error, emptyIterations < 8 else { throw MusicNativeError.render("converter made no progress") }
        }
        output = nil
    }
}

func musicStagingURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(".music-\(UUID().uuidString).partial")
        .appendingPathExtension(destination.pathExtension.isEmpty ? "caf" : destination.pathExtension)
}

func musicSynchronize(_ url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
}

func musicPCMFileSettings(_ format: AVAudioFormat) -> [String: Any] {
    var settings = format.settings
    // WAV/CAF file frames are interleaved; the processing buffers remain
    // planar Float32 through AVAudioFile's ordinary conversion boundary.
    settings[AVLinearPCMIsNonInterleaved] = false
    return settings
}
