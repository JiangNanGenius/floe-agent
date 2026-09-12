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
