// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import FloeCore
import FloeTools

public struct AudioPCMSourceSelection: Sendable {
    public let url: URL
    public var startSeconds: Double
    public var durationSeconds: Double?
    public var sampleRate: Double?
    public var channelCount: Int?
    public var expectedSHA256: String?
    public init(url: URL, startSeconds: Double = 0, durationSeconds: Double? = nil,
        sampleRate: Double? = nil, channelCount: Int? = nil, expectedSHA256: String? = nil) {
        self.url = url; self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate; self.channelCount = channelCount; self.expectedSHA256 = expectedSHA256
    }
}

public struct AudioPCMFileResult: Sendable {
    public let outputURL: URL
    public let outputSHA256: String
    public let outputBytes: Int
    public let sourceSHA256: String
    public let secondarySourceSHA256: String?
    public let measurement: AudioPCMMeasurement
    public let engine: String
    public let metrics: [String: Double]
    public let limitations: [String]
}

public struct AudioStemFileResult: Sendable {
    public let directory: URL
    public let vocals: AudioPCMFileResult
    public let accompaniment: AudioPCMFileResult
    public let modelID: String
    public let modelVersion: String
    public let modelFingerprint: String
    public let predictionCount: Int
}

/// Existing workspace ownership is supplied by the caller. This service owns
/// decoding, bounded native work, staging and the existing atomic file commit;
/// the editor still owns its original/revision/CAS/journal transaction.
public actor AudioPCMFileService {
    private let root: URL
    private let maximumPCMBytes: Int
    public init(workspaceRoot: URL, maximumPCMBytes: Int = 64 * 1_024 * 1_024) throws {
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard root.isFileURL, FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              maximumPCMBytes > 0, maximumPCMBytes <= 128 * 1_024 * 1_024 else { throw AudioPCMProcessingError.invalidInput("an explicit workspace directory and bounded PCM budget are required") }
        self.root = root; self.maximumPCMBytes = maximumPCMBytes
    }
    public func denoise(_ source: AudioPCMSourceSelection, destination: URL, overwrite: Bool = false,
        settings: AudioSpectralDenoiseSettings = .init(), work: AudioPCMWork = .init()) throws -> AudioPCMFileResult {
        let decoded = try decode(source, work: work)
        let result = try AudioSpectralDenoiser.process(decoded.pcm, settings: settings,
            work: .init(isCancelled: work.isCancelled, progress: { work.progress(0.1 + 0.7 * $0) }))
        return try publish(result.pcm, source: decoded, secondary: nil, destination: destination, overwrite: overwrite, engine: "native-spectral-wiener",
            metrics: ["profileFrames": Double(result.profileFrames), "fftLength": Double(result.fftLength), "hopLength": Double(result.hopLength)], limitations: result.limitations, work: work)
    }
    public func duck(_ target: AudioPCMSourceSelection, sidechain: AudioPCMSourceSelection, sidechainStartSeconds: Double = 0,
        destination: URL, overwrite: Bool = false, settings: AudioDuckingSettings = .init(), work: AudioPCMWork = .init()) throws -> AudioPCMFileResult {
        let music = try decode(target, work: work)
        var voiceSelection = sidechain; voiceSelection.sampleRate = music.pcm.sampleRate
        let voice = try decode(voiceSelection, work: work)
        let result = try AudioSidechainDucker.process(target: music.pcm, sidechain: voice.pcm, sidechainStartSeconds: sidechainStartSeconds,
            settings: settings, work: .init(isCancelled: work.isCancelled, progress: { work.progress(0.2 + 0.6 * $0) }))
        return try publish(result.pcm, source: music, secondary: voice, destination: destination, overwrite: overwrite, engine: "native-rms-sidechain-duck",
            metrics: ["minimumGain": result.minimumGain, "attenuatedFrames": Double(result.attenuatedFrames), "sidechainStartSeconds": sidechainStartSeconds], limitations: [], work: work)
    }
    public func separate(_ source: AudioPCMSourceSelection, modelID: String, modelService: AudioStemCoreMLService,
        destinationDirectory: URL, work: AudioPCMWork = .init()) async throws -> AudioStemFileResult {
        let contract = try await modelService.contract(modelID: modelID)
        var selection = source; selection.sampleRate = contract.sampleRate; selection.channelCount = contract.channelCount
        let decoded = try decode(selection, work: work)
        let separated = try await modelService.separate(decoded.pcm, modelID: modelID,
            work: .init(isCancelled: work.isCancelled, progress: { work.progress(0.1 + 0.65 * $0) }))
        let destination = try scoped(destinationDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AudioPCMProcessingError.invalidInput("choose a new stem output directory") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".floe-audio-stems-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let a = staging.appendingPathComponent("vocals.wav"), b = staging.appendingPathComponent("accompaniment.wav")
        try write(separated.vocals, to: a, work: work); try write(separated.accompaniment, to: b, work: work)
        let first = try outputIdentity(a, expected: separated.vocals, work: work), second = try outputIdentity(b, expected: separated.accompaniment, work: work)
        let metadata: [String: Any] = ["engine": "coreml-audio-waveform", "modelID": separated.modelID, "modelVersion": separated.modelVersion,
            "modelFingerprint": separated.modelFingerprint, "sourceSHA256": decoded.sourceSHA256, "predictionCount": separated.predictionCount,
            "reconstructionErrorRMS": separated.reconstructionErrorRMS, "vocalsSHA256": first.sha256, "accompanimentSHA256": second.sha256,
            "sampleRate": decoded.pcm.sampleRate, "frames": decoded.pcm.frameCount, "channels": decoded.pcm.channels.count, "qualityNotes": separated.qualityNotes]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: staging.appendingPathComponent("stems.json"), options: .atomic)
        try validate(decoded, work: work); try work.check()
        // Both files and their metadata become visible together. The new
        // destination must not exist; a failed move cannot replace old data.
        try FileManager.default.moveItem(at: staging, to: destination)
        return .init(directory: destination,
            vocals: .init(outputURL: destination.appendingPathComponent("vocals.wav"), outputSHA256: first.sha256, outputBytes: first.bytes, sourceSHA256: decoded.sourceSHA256,
                secondarySourceSHA256: nil, measurement: .init(separated.vocals), engine: "coreml-audio-waveform", metrics: ["reconstructionErrorRMS": separated.reconstructionErrorRMS], limitations: separated.qualityNotes),
            accompaniment: .init(outputURL: destination.appendingPathComponent("accompaniment.wav"), outputSHA256: second.sha256, outputBytes: second.bytes, sourceSHA256: decoded.sourceSHA256,
                secondarySourceSHA256: nil, measurement: .init(separated.accompaniment), engine: "coreml-audio-waveform", metrics: ["reconstructionErrorRMS": separated.reconstructionErrorRMS], limitations: separated.qualityNotes),
            modelID: separated.modelID, modelVersion: separated.modelVersion, modelFingerprint: separated.modelFingerprint, predictionCount: separated.predictionCount)
    }
    private struct Decoded {
        let url: URL
        let sourceSHA256: String
        let pcm: AudioPCM
    }
    private func scoped(_ url: URL) throws -> URL {
        let value = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.isFileURL, value.path.hasPrefix(root.path + "/") else { throw AudioPCMProcessingError.invalidInput("audio path is outside the captured workspace") }
        return value
    }
    private func decode(_ selection: AudioPCMSourceSelection, work: AudioPCMWork) throws -> Decoded {
        try work.check()
        let url = try scoped(selection.url)
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, let size = resource.fileSize, size > 0, size <= 512 * 1_024 * 1_024 else { throw AudioPCMProcessingError.limitExceeded("audio source must be a regular file no larger than 512 MiB") }
        let digest = try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: work.isCancelled)
        if let expected = selection.expectedSHA256 { guard expected == digest else { throw AudioPCMProcessingError.changedSource } }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false), sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate, sourceChannels = Int(sourceFormat.channelCount)
        let rate = selection.sampleRate ?? sourceRate, channels = selection.channelCount ?? sourceChannels
        guard sourceRate.isFinite, sourceRate > 0, sourceRate <= 384_000, (1...8).contains(sourceChannels), file.length > 0,
              rate.isFinite, (8_000...192_000).contains(rate), (1...2).contains(channels), selection.startSeconds.isFinite, selection.startSeconds >= 0 else { throw AudioPCMProcessingError.invalidInput("source rate/channels or requested audio interval are invalid") }
        let start = selection.startSeconds, duration = selection.durationSeconds ?? (Double(file.length) / sourceRate - start)
        guard duration.isFinite, duration > 0, start + duration <= Double(file.length) / sourceRate + 0.5 / sourceRate,
              duration * rate <= Double(maximumPCMBytes / (channels * 4)) else { throw AudioPCMProcessingError.limitExceeded("select an audio interval within the source and the PCM budget") }
        let lower = Int64((start * sourceRate).rounded()), upper = min(file.length, Int64(((start + duration) * sourceRate).rounded()))
        let expectedFrames = Int((Double(upper - lower) * rate / sourceRate).rounded())
        guard expectedFrames > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: UInt32(channels), interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8_192), let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw AudioPCMProcessingError.invalidInput("audio converter rejected the requested source clock") }
        // Offline conversion uses normal trailing priming, which has no
        // output latency. .none is the live-input latency mode and can lose
        // the resampler's tail at the selected interval boundary.
        converter.primeMethod = .normal
        file.framePosition = lower
        var samples = [[Float]](repeating: [], count: channels), done = false, readError: (any Error)?
        for c in samples.indices { samples[c].reserveCapacity(expectedFrames) }
        while !done {
            try work.check()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                if file.framePosition >= upper { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity, UInt32(min(Int64(UInt32.max), upper - file.framePosition))))
                    guard input.frameLength > 0 else { throw AudioPCMProcessingError.invalidInput("audio decoder stopped before its declared interval") }
                    state.pointee = .haveData; return input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }; if let conversionError { throw conversionError }
            guard status != .error else { throw AudioPCMProcessingError.invalidInput("audio conversion failed") }
            if output.frameLength > 0 {
                guard let data = output.floatChannelData else { throw AudioPCMProcessingError.invalidInput("audio converter returned non-float PCM") }
                for c in samples.indices { samples[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: Int(output.frameLength))) }
                guard samples[0].count <= expectedFrames + 8_192 else { throw AudioPCMProcessingError.limitExceeded("audio converter exceeded its duration bound") }
            }
            done = status == .endOfStream
            guard done || output.frameLength > 0 else { throw AudioPCMProcessingError.invalidInput("audio converter made no progress") }
        }
        let delta = samples[0].count - expectedFrames
        guard abs(delta) <= 1 else { throw AudioPCMProcessingError.invalidInput("decoded audio duration differs from its selected interval (expected \(expectedFrames), actual \(samples[0].count))") }
        for c in samples.indices { if delta > 0 { samples[c].removeLast(delta) }; if delta < 0 { samples[c].append(0) } }
        let pcm = try AudioPCM(sampleRate: rate, channels: samples); try pcm.validate(maximumBytes: maximumPCMBytes)
        let value = Decoded(url: url, sourceSHA256: digest, pcm: pcm); try validate(value, work: work); return value
    }
    private func validate(_ source: Decoded, work: AudioPCMWork) throws {
        try work.check()
        guard try FloeDigest.sha256Hex(ofFileAt: source.url, isCancelled: work.isCancelled) == source.sourceSHA256 else { throw AudioPCMProcessingError.changedSource }
    }
    private func write(_ pcm: AudioPCM, to url: URL, work: AudioPCMWork) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.sampleRate, channels: UInt32(pcm.channels.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw AudioPCMProcessingError.invalidInput("could not allocate output PCM") }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for start in stride(from: 0, to: pcm.frameCount, by: 8_192) {
            try work.check(); let count = min(8_192, pcm.frameCount - start); buffer.frameLength = UInt32(count)
            for channel in pcm.channels.indices { pcm.channels[channel].withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress! + start, count: count) } }
            try file.write(from: buffer); work.progress(0.8 + 0.15 * Double(start + count) / Double(pcm.frameCount))
        }
    }
    private func outputIdentity(_ url: URL, expected pcm: AudioPCM, work: AudioPCMWork) throws -> (sha256: String, bytes: Int) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length == pcm.frameCount, file.processingFormat.sampleRate == pcm.sampleRate, Int(file.processingFormat.channelCount) == pcm.channels.count,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else { throw AudioPCMProcessingError.invalidInput("written audio failed its frame/rate/channel read-back") }
        var offset = 0
        while file.framePosition < file.length {
            try work.check(); try file.read(into: buffer, frameCount: UInt32(min(8_192, file.length - file.framePosition)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw AudioPCMProcessingError.invalidInput("written audio decoder made no progress") }
            for channel in pcm.channels.indices { for frame in 0..<Int(buffer.frameLength) {
                guard data[channel][frame].isFinite, data[channel][frame] == pcm.channels[channel][offset + frame] else { throw AudioPCMProcessingError.invalidInput("written Float32 audio differs from processed PCM") }
            } }
            offset += Int(buffer.frameLength)
        }
        guard offset == pcm.frameCount, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw AudioPCMProcessingError.invalidInput("written audio length verification failed") }
        return (try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: work.isCancelled), size)
    }
    private func publish(_ pcm: AudioPCM, source: Decoded, secondary: Decoded?, destination: URL, overwrite: Bool, engine: String,
        metrics: [String: Double], limitations: [String], work: AudioPCMWork) throws -> AudioPCMFileResult {
        let destination = try scoped(destination)
        guard destination.pathExtension.lowercased() == "wav", destination != source.url, destination != secondary?.url else { throw AudioPCMProcessingError.invalidInput("choose a separate WAV output") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".floe-audio-process-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(pcm, to: staging, work: work)
        let verified = try outputIdentity(staging, expected: pcm, work: work)
        try validate(source, work: work); if let secondary { try validate(secondary, work: work) }
        let receipt = try AtomicFileCommitter.commit(stagedFile: staging, to: destination,
            policy: .init(conflict: overwrite ? .replaceAtomically(consent: true) : .failIfExists, maxBytes: maximumPCMBytes + 65_536, checkCancellation: { try work.check() }))
        guard receipt.sha256 == verified.sha256, receipt.byteCount == verified.bytes else { throw AudioPCMProcessingError.changedSource }
        return .init(outputURL: destination, outputSHA256: receipt.sha256, outputBytes: receipt.byteCount, sourceSHA256: source.sourceSHA256,
            secondarySourceSHA256: secondary?.sourceSHA256, measurement: .init(pcm), engine: engine, metrics: metrics, limitations: limitations)
    }
}
