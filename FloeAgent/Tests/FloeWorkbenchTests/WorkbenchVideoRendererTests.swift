// FloeWorkbench — Real video composition/export tests with synthesized media.

#if canImport(AVFoundation)
import Foundation
import Testing
import AVFoundation
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("Workbench video rendering")
struct WorkbenchVideoRendererTests {
    // MARK: Synthetic media

    private func movie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                       tone: Double, withAudio: Bool) async throws {
        let silent = url.deletingLastPathComponent()
            .appendingPathComponent("silent-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: silent) }
        try await silentMovie(at: silent, width: width, height: height, fps: fps,
                              seconds: seconds, tone: tone)
        guard withAudio else {
            try FileManager.default.moveItem(at: silent, to: url)
            return
        }
        // Mux a generated tone into the video so audio/video sync can be
        // asserted on the exported result.
        let toneURL = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: toneURL) }
        try audioFile(at: toneURL, seconds: seconds, frequency: 440)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: toneURL)
        if let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)),
                                           of: sourceVideo, at: .zero)
        }
        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)),
                                           of: sourceAudio, at: .zero)
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try await exporter.export(to: url, as: url.pathExtension == "mov" ? .mov : .mp4)
    }

    private func silentMovie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                             tone: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(videoInput)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int(seconds * Double(fps))
        for frame in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            #expect(status == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = CVPixelBufferGetBaseAddress(pixel)!
            let bytes = CVPixelBufferGetBytesPerRow(pixel)
            for row in 0..<height {
                let ptr = base.advanced(by: row * bytes).assumingMemoryBound(to: UInt32.self)
                let value: UInt32 = tone > 0.5 ? 0xFF0000FF : 0xFFFF0000
                for column in 0..<width { ptr[column] = value }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private func audioFile(at url: URL, seconds: Double, frequency: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(Double(index) * frequency * 2 * .pi / 44_100) * 0.3)
        }
        try file.write(from: buffer)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func project(assets: [(MediaAssetReference, URL)], clips: [VideoClip],
                         fps: Double = 30, width: Int = 640, height: Int = 360,
                         music: [MusicClip] = [], captions: [CaptionSegment] = []) -> MediaProject {
        var project = MediaProject(kind: .video, name: "V", canvas: MediaCanvas(width: width, height: height, frameRate: fps))
        project.assets = assets.map(\.0)
        project.sourceAssetID = assets.first?.0.id
        project.videoTimeline = VideoTimeline(clips: clips, music: music, captions: captions)
        return project
    }

    // MARK: Tests

    @Test func mixedOrientationAndFrameRateClipsNormalizeToExplicitCanvas() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let landscapeURL = root.appendingPathComponent("landscape.mp4")
        let portraitURL = root.appendingPathComponent("portrait.mov")
        try await movie(at: landscapeURL, width: 640, height: 360, fps: 24, seconds: 1.5, tone: 0.2, withAudio: false)
        try await movie(at: portraitURL, width: 360, height: 640, fps: 30, seconds: 1.5, tone: 0.8, withAudio: false)
        let a = MediaAssetReference(kind: .video, relativePath: "landscape.mp4", originalName: "landscape.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 1.5, frameRate: 24))
        let b = MediaAssetReference(kind: .video, relativePath: "portrait.mov", originalName: "portrait.mov",
                                    metadata: MediaAssetMetadata(durationSeconds: 1.5, frameRate: 30))
        let clips = [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 1.5),
                     VideoClip(assetID: b.id, trimStart: 0, trimEnd: 1.5)]
        let project = project(assets: [(a, landscapeURL), (b, portraitURL)], clips: clips)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 640, height: 360, frameRate: 30,
                                        quality: 0.8, fileName: "mixed"),
            to: "mixed.mp4")
        #expect(receipt.width == 640 && receipt.height == 360)
        #expect(abs(receipt.durationSeconds - 3.0) < 0.25)
        #expect(FileManager.default.fileExists(atPath: receipt.url.path))
        #expect(receipt.byteCount > 0)
        let asset = AVURLAsset(url: receipt.url)
        #expect(try await asset.load(.isPlayable))
    }

    @Test func perClipTrimAndSpeedChangeTimelineDuration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mp4")
        try await movie(at: url, width: 640, height: 360, fps: 30, seconds: 2, tone: 0.2, withAudio: false)
        let a = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 30))
        // trim 0.5...1.5 (1s source) at speed 2 => 0.5s on the timeline.
        let clip = VideoClip(assetID: a.id, trimStart: 0.5, trimEnd: 1.5, speed: 2)
        let project = project(assets: [(a, url)], clips: [clip])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 640, height: 360, frameRate: 30, fileName: "speed"),
            to: "speed.mp4")
        #expect(abs(receipt.durationSeconds - 0.5) < 0.2, "trim+speed must retime to 0.5s")
    }

    @Test func crossDissolveContractsTimelineAndRenders() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mp4")
        try await movie(at: url, width: 320, height: 180, fps: 30, seconds: 2, tone: 0.2, withAudio: false)
        let a = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 30))
        let clips = [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 1.5),
                     VideoClip(assetID: a.id, trimStart: 0.5, trimEnd: 2,
                               leadingTransition: .crossDissolve, transitionDuration: 0.4)]
        let project = project(assets: [(a, url)], clips: clips, width: 320, height: 180)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30, fileName: "dissolve"),
            to: "dissolve.mp4")
        // 1.5 + 1.5 - 0.4 = 2.6s
        #expect(abs(receipt.durationSeconds - 2.6) < 0.25)
    }

    @Test func musicMixAndOriginalAudioStaySynced() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("with-audio.mp4")
        let musicURL = root.appendingPathComponent("music.m4a")
        try await movie(at: videoURL, width: 320, height: 180, fps: 30, seconds: 2, tone: 0.2, withAudio: true)
        try audioFile(at: musicURL, seconds: 4, frequency: 220)
        let video = MediaAssetReference(kind: .video, relativePath: "with-audio.mp4", originalName: "with-audio.mp4",
                                        metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 30, audioTracks: 1))
        let music = MediaAssetReference(kind: .audio, relativePath: "music.m4a", originalName: "music.m4a",
                                        metadata: MediaAssetMetadata(durationSeconds: 4, audioTracks: 1))
        let clip = VideoClip(assetID: video.id, trimStart: 0, trimEnd: 2)
        let musicClip = MusicClip(assetID: music.id, offsetSeconds: 0.2, trimStart: 0.5,
                                  lengthSeconds: 1.5, volume: 0.5, fadeInSeconds: 0.2, fadeOutSeconds: 0.2)
        let project = project(assets: [(video, videoURL), (music, musicURL)], clips: [clip],
                              width: 320, height: 180, music: [musicClip])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30, fileName: "music"),
            to: "music.mp4")
        let asset = AVURLAsset(url: receipt.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!audioTracks.isEmpty, "music mix must produce an audio track")
        let videoDuration = try await videoTracks[0].load(.timeRange).duration.seconds
        let audioDuration = try await audioTracks[0].load(.timeRange).duration.seconds
        #expect(abs(videoDuration - audioDuration) < 0.2, "audio and video must stay in sync")
        #expect(abs(videoDuration - 2.0) < 0.25)
    }

    @Test func captionsOverrunValidationRejects() {
        let a = MediaAssetReference(kind: .video, relativePath: "v.mp4", originalName: "v.mp4")
        var timeline = VideoTimeline(clips: [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 1)])
        timeline.captions = [CaptionSegment(start: 0, end: 2, text: "too long")]
        #expect(throws: (any Error).self) {
            try MediaExportValidation.validateVideo(
                VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30),
                timeline: timeline)
        }
        timeline.captions = [CaptionSegment(start: 0, end: 0.9, text: "ok")]
        try? MediaExportValidation.validateVideo(
            VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30),
            timeline: timeline)
    }

    @Test func captionsRenderIntoExportedFrames() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mp4")
        try await movie(at: url, width: 320, height: 180, fps: 30, seconds: 1.5, tone: 0.2, withAudio: false)
        let a = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 1.5, frameRate: 30))
        let caption = CaptionSegment(start: 0, end: 1.5, text: "字幕测试", source: .manual)
        let project = project(assets: [(a, url)],
                              clips: [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 1.5)],
                              width: 320, height: 180, captions: [caption])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30, fileName: "caps"),
            to: "caps.mp4")
        // Restrict to the caption band and check for bright text pixels above
        // the white-ish background of the caption box over the red frame.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: receipt.url))
        let frame = try await generator.image(at: CMTime(seconds: 0.7, preferredTimescale: 600)).image
        #expect(brightPixels(in: frame, yRange: Int(Double(frame.height) * 0.82)..<frame.height) > 40,
                "burned captions must be visible in the lower band")
    }

    @Test func cancelledExportDoesNotLeaveAnOutputFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("clip.mp4")
        try await movie(at: url, width: 640, height: 360, fps: 30, seconds: 2, tone: 0.2, withAudio: false)
        let a = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 30))
        let project = project(assets: [(a, url)], clips: [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 2)])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: (any Error).self) {
            try await renderer.export(
                project: project,
                options: VideoExportOptions(codec: .h264, width: 640, height: 360, frameRate: 30, fileName: "cancelled"),
                to: "cancelled.mp4",
                cancellation: token)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.mp4").path),
                "cancelled export must not leave a misleading success file")
    }

    @Test func failedExportPreservesExistingOutput() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("keep.mp4")
        try Data("precious".utf8).write(to: existing)
        // Missing source asset: export must fail before touching the output.
        let a = MediaAssetReference(kind: .video, relativePath: "missing.mp4", originalName: "missing.mp4",
                                    metadata: MediaAssetMetadata(durationSeconds: 2))
        let project = project(assets: [(a, existing)], clips: [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 2)])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        await #expect(throws: (any Error).self) {
            try await renderer.export(
                project: project,
                options: VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30, fileName: "keep"),
                to: "keep.mp4")
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "precious")
    }

    @Test func pathEscapeIsRejected() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = MediaAssetReference(kind: .video, relativePath: "../outside.mp4", originalName: "outside.mp4")
        let project = project(assets: [(a, root)], clips: [VideoClip(assetID: a.id, trimStart: 0, trimEnd: 1)])
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        await #expect(throws: (any Error).self) {
            try await renderer.export(
                project: project,
                options: VideoExportOptions(codec: .h264, width: 320, height: 180, frameRate: 30),
                to: "out.mp4")
        }
    }

    // MARK: Pixel helpers

    private func brightPixels(in image: CGImage, yRange: Range<Int>) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for y in yRange where y < height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let r = Int(data[index]), g = Int(data[index + 1]), b = Int(data[index + 2])
                if r > 200 && g > 200 && b > 200 { count += 1 }
            }
        }
        return count
    }
}
#endif
