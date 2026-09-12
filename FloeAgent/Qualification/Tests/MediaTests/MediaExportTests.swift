import Foundation
import Testing
import AVFoundation
import FloeTools
@testable import FloeMedia

@Suite("Real media exports")
struct MediaExportTests {
    private func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            #expect(status == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 7), CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func editsApplyTrimSpeedAndExportSettingsToActualFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await movie(at: root.appendingPathComponent("input.mov"))
        let renderer = MediaRenderer(rootProvider: { root })
        let result = try await renderer.render(plan: .init(input: "input.mov", output: "edited.mp4",
            operations: [.trim(start: 0.2, end: 0.8), .speed(rate: 0.5)],
            export: .init(container: "mp4", videoCodec: "h264", videoBitrate: 150_000, width: 128, height: 96, frameRate: 15)))
        #expect(abs(result.durationSeconds - 1.2) < 0.2)
        #expect(result.width == 128 && result.height == 96)
        #expect(abs(result.frameRate - 15) < 0.1)
        #expect(result.warnings.isEmpty)
        #expect(try await AVURLAsset(url: root.appendingPathComponent("edited.mp4")).load(.isPlayable))
    }

    @Test func speedChangesAudioAndVideoOnTheSameTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("silent.mov")
        let audioURL = root.appendingPathComponent("tone.wav")
        try await movie(at: videoURL)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let samples = try #require(buffer.floatChannelData)[0]
            for index in 0..<48_000 { samples[index] = Float(sin(Double(index) * 440 * 2 * .pi / 48_000) * 0.2) }
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(videoURL, AVMediaType.video), (audioURL, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let source = try #require(await asset.loadTracks(withMediaType: type).first)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: source, at: .zero)
        }
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await exporter.export(to: root.appendingPathComponent("source.mov"), as: .mov)
        let renderer = MediaRenderer(rootProvider: { root })
        _ = try await renderer.render(plan: .init(input: "source.mov", output: "slowed.mp4",
            operations: [.speed(rate: 0.5), .volume(level: 0.5)], export: .init(container: "mp4")))
        let output = AVURLAsset(url: root.appendingPathComponent("slowed.mp4"))
        let video = try #require(await output.loadTracks(withMediaType: .video).first)
        let audio = try #require(await output.loadTracks(withMediaType: .audio).first)
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        #expect(abs(videoRange.duration.seconds - 2) < 0.15)
        #expect(abs(audioRange.duration.seconds - videoRange.duration.seconds) < 0.15)
    }

    @Test func unsupportedEditCannotReplaceExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.mp4")
        try Data("preserved".utf8).write(to: output)
        let renderer = MediaRenderer(rootProvider: { root })
        await #expect(throws: (any Error).self) {
            try await renderer.render(plan: .init(input: "missing.mov", output: "existing.mp4",
                operations: [.overlayText(text: "title", x: 0, y: 0, fontSize: 20, colorHex: "ffffff")], export: .init(container: "mp4")))
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "preserved")
    }

    @Test func requestedDimensionsAndFrameRateReachEncodedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await movie(at: root.appendingPathComponent("input.mov"))
        let engine = MediaExportEngine(rootProvider: { root })
        let result = try await engine.transcode(.init(input: "input.mov", output: "output.mp4", container: "mp4", videoCodec: "h264", width: 128, height: 96, frameRate: 15, videoBitrate: 150_000, passthrough: false))
        #expect(result.contains("status=ok"))
        let output = AVURLAsset(url: root.appendingPathComponent("output.mp4"))
        let track = try #require(await output.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 128, height: 96))
        #expect(abs(try await track.load(.nominalFrameRate) - 15) < 0.1)
        #expect(try await output.load(.isPlayable))
        let reader = try AVAssetReader(asset: output)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples); #expect(reader.startReading())
        var frameCount = 0
        while let sample = samples.copyNextSampleBuffer() { frameCount += CMSampleBufferGetNumSamples(sample) }
        #expect(frameCount == 15)
    }

    @Test func rejectedAndCancelledExportsPreserveFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await movie(at: root.appendingPathComponent("input.mov"))
        let original = Data("keep existing output".utf8)
        try original.write(to: root.appendingPathComponent("output.mp4"))
        let engine = MediaExportEngine(rootProvider: { root })
        let spec = MediaExportEngine.TranscodeSpec(input: "input.mov", output: "output.mp4", container: "unsupported", passthrough: false)
        await #expect(throws: (any Error).self) { try await engine.transcode(spec) }
        let cancellation = CancellationToken(); cancellation.cancel()
        await #expect(throws: (any Error).self) { try await engine.transcode(.init(input: "input.mov", output: "output.mp4", container: "mp4", passthrough: false), cancellation: cancellation) }
        await #expect(throws: (any Error).self) { try await engine.transcode(.init(input: "input.mov", output: "../escape.mp4", container: "mp4", passthrough: false)) }
        #expect(try Data(contentsOf: root.appendingPathComponent("output.mp4")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["input.mov", "output.mp4"])
    }
}

extension MediaExportTests {
    @Test func audioConversionAppliesRateAndChannels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        do {
            let source = try AVAudioFile(forWriting: root.appendingPathComponent("source.wav"), settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let channels = try #require(buffer.floatChannelData)
            for index in 0..<48_000 {
                let sample = Float(sin(Double(index) * 440 * 2 * .pi / 48_000) * 0.2)
                channels[0][index] = sample; channels[1][index] = sample
            }
            try source.write(from: buffer)
        }
        let engine = MediaExportEngine(rootProvider: { root })
        let result = try await engine.convertAudio(input: "source.wav", output: "mono.wav", container: "wav", sampleRate: 16_000, channels: 1, bitRate: nil, cancellation: nil)
        #expect(result.contains("status=ok"))
        let output = try AVAudioFile(forReading: root.appendingPathComponent("mono.wav"))
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        #expect(abs(output.length - 16_000) <= 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 16_000))
        try output.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)
        #expect((0..<Int(buffer.frameLength)).contains { abs(samples[0][$0]) > 0.1 })
    }
}
