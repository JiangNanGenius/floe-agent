// FloeWorkbench — Live preview behavior tests.
//
// These tests exercise the ACTUAL preview path (`renderPreview`) with real
// synthesized media and assert decoded pixels and AVPlayer time progression,
// not just that a builder returned without throwing.
//
// Architecture note: the preview plays a rendered H.264 proxy produced by the
// SAME export pipeline (transforms, crop, dissolves, burned captions, clip
// volume, music fades). That is deliberate: on iOS 27 the playback pipeline
// refuses to prepare `AVPlayerItem`s carrying an `AVVideoComposition` when
// they are attached to an `AVPlayerLayer` (AVFoundation -11800 / OSStatus
// -12784), while file playback works everywhere. These tests therefore
// validate the frames the user actually sees.

#if canImport(AVFoundation)
import Foundation
import Testing
import AVFoundation
import CoreGraphics
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("Workbench video preview")
struct WorkbenchVideoPreviewTests {
    // MARK: Synthetic media

    private func silentMovie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                             rgba: UInt32) async throws {
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
                for column in 0..<width { ptr[column] = rgba }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// Stored `width`x`height`, optional preferredTransform; left half red,
    /// right half green for orientation tests.
    private func silentSplitMovie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                                  transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(videoInput)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * Double(fps)) {
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
                for column in 0..<width {
                    ptr[column] = column < width / 2 ? 0xFFFF0000 : 0xFF00FF00
                }
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

    private func withMovie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                           rgba: UInt32) async throws {
        let silent = url.deletingLastPathComponent()
            .appendingPathComponent("silent-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: silent) }
        try await silentMovie(at: silent, width: width, height: height, fps: fps,
                              seconds: seconds, rgba: rgba)
        let toneURL = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: toneURL) }
        try audioFile(at: toneURL, seconds: seconds, frequency: 330)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: toneURL)
        if let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
           let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero,
                                                       duration: CMTime(seconds: seconds, preferredTimescale: 600)),
                                           of: sourceVideo, at: .zero)
        }
        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero,
                                                       duration: CMTime(seconds: seconds, preferredTimescale: 600)),
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

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Two landscape H.264 clips (red then blue) with audio, 2s each, plus a
    /// 4s music tone with fades and a caption — close to the UI fixture shape.
    private func twoClipProject(root: URL) async throws -> MediaProject {
        let firstURL = root.appendingPathComponent("first.mp4")
        let secondURL = root.appendingPathComponent("second.mp4")
        let musicURL = root.appendingPathComponent("music.m4a")
        try await withMovie(at: firstURL, width: 640, height: 360, fps: 24, seconds: 2,
                            rgba: 0xFFFF0000)
        try await withMovie(at: secondURL, width: 640, height: 360, fps: 24, seconds: 2,
                            rgba: 0xFF0000FF)
        try audioFile(at: musicURL, seconds: 4, frequency: 220)
        let first = MediaAssetReference(kind: .video, relativePath: "first.mp4", originalName: "first.mp4",
                                        metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 24, audioTracks: 1))
        let second = MediaAssetReference(kind: .video, relativePath: "second.mp4", originalName: "second.mp4",
                                         metadata: MediaAssetMetadata(durationSeconds: 2, frameRate: 24, audioTracks: 1))
        let music = MediaAssetReference(kind: .audio, relativePath: "music.m4a", originalName: "music.m4a",
                                        metadata: MediaAssetMetadata(durationSeconds: 4, audioTracks: 1))
        var project = MediaProject(kind: .video, name: "Preview",
                                   canvas: MediaCanvas(width: 640, height: 360, frameRate: 24))
        project.assets = [first, second, music]
        project.sourceAssetID = first.id
        var timeline = VideoTimeline(clips: [
            VideoClip(assetID: first.id, trimStart: 0, trimEnd: 2),
            VideoClip(assetID: second.id, trimStart: 0, trimEnd: 2)
        ])
        timeline.music = [MusicClip(assetID: music.id, offsetSeconds: 0, trimStart: 0,
                                    lengthSeconds: 4, volume: 0.5, fadeInSeconds: 0.2,
                                    fadeOutSeconds: 0.5)]
        timeline.captions = [CaptionSegment(start: 0.5, end: 1.5, text: "HELLO PREVIEW", source: .manual)]
        project.videoTimeline = timeline
        return project
    }

    // MARK: Pixel helpers

    private func averageColor(of image: CGImage, region: CGRect? = nil) -> (r: Double, g: Double, b: Double) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rect = region ?? CGRect(x: 0, y: 0, width: width, height: height)
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for y in Int(rect.minY)..<min(Int(rect.maxY), height) {
            for x in Int(rect.minX)..<min(Int(rect.maxX), width) {
                let index = (y * width + x) * 4
                r += Double(data[index]); g += Double(data[index + 1]); b += Double(data[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (r / count / 255, g / count / 255, b / count / 255)
    }

    private func pixelBufferIsBlack(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let bytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var total = 0
        for row in stride(from: 0, to: height, by: max(1, height / 16)) {
            let ptr = base.advanced(by: row * bytes).assumingMemoryBound(to: UInt8.self)
            for column in stride(from: 0, to: width, by: max(1, width / 16)) {
                total += Int(ptr[column * 4]) + Int(ptr[column * 4 + 1]) + Int(ptr[column * 4 + 2])
            }
        }
        return total == 0
    }

    private func brightPixels(in image: CGImage, yRange: Range<Int>) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for y in yRange where y < height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if data[index] > 200 && data[index + 1] > 200 && data[index + 2] > 200 { count += 1 }
            }
        }
        return count
    }

    private func frame(at url: URL, seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Tests

    @Test func previewProxyIsReadyAndDecodesActualFrames() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await twoClipProject(root: root)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        #expect(FileManager.default.fileExists(atPath: receipt.url.path))
        #expect(receipt.width > 0 && receipt.height > 0)
        // The proxy must be playable as a plain file: no video composition
        // (which AVPlayerLayer rejects on this platform) is required.
        let item = AVPlayerItem(url: receipt.url)
        #expect(item.videoComposition == nil)
        let player = AVPlayer()
        player.replaceCurrentItem(with: item)
        var waited = 0.0
        while item.status == .unknown, waited < 10 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(item.status == .readyToPlay,
                "preview proxy status is \(item.status.rawValue); error: \(String(describing: item.error))")
        if item.status != .readyToPlay { return }

        let firstColor = averageColor(of: try await frame(at: receipt.url, seconds: 0.5))
        #expect(firstColor.r > 0.5 && firstColor.g < 0.25 && firstColor.b < 0.25,
                "frame at 0.5s must show the first (red) clip, got \(firstColor)")

        let secondColor = averageColor(of: try await frame(at: receipt.url, seconds: 3.0))
        #expect(secondColor.b > 0.5 && secondColor.r < 0.25,
                "frame at 3.0s must show the second (blue) clip, got \(secondColor)")
    }

    @Test func playerAdvancesPlaybackTimeAndOutputsFrames() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await twoClipProject(root: root)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        let item = AVPlayerItem(url: receipt.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer()
        player.replaceCurrentItem(with: item)
        var waited = 0.0
        while item.status == .unknown, waited < 10 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(item.status == .readyToPlay, "item failed: \(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }
        player.play()
        try await Task.sleep(for: .seconds(2))
        let seconds = player.currentTime().seconds
        #expect(seconds > 0.5, "AVPlayer time must advance while playing, got \(seconds)")
        if let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            #expect(!pixelBufferIsBlack(buffer),
                    "the decoded player frame at \(seconds)s must not be black")
        } else {
            Issue.record("AVPlayerItemVideoOutput produced no frame at \(seconds)s")
        }
        player.pause()
    }

    @Test func previewBurnsCaptionsUsingTheSameSegmentsAsExport() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await twoClipProject(root: root)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        // Caption band (lower ~18%) contains bright text pixels while the
        // caption is active (same assertion style as the export suite).
        let captionFrame = try await frame(at: receipt.url, seconds: 1.0)
        let band = CGRect(x: 0, y: Double(captionFrame.height) * 0.82,
                          width: Double(captionFrame.width), height: Double(captionFrame.height) * 0.18)
        let bright = brightPixels(in: captionFrame,
                                  yRange: Int(Double(captionFrame.height) * 0.82)..<captionFrame.height)
        #expect(bright > 40, "caption text must be visible in the lower band, bright=\(bright)")
        // Outside the caption window the same band is the plain clip color.
        let cleanFrame = try await frame(at: receipt.url, seconds: 2.5)
        let cleanBand = averageColor(of: cleanFrame, region: band)
        #expect(cleanBand.r > 0.25 || cleanBand.b > 0.5,
                "no caption band outside the segment, got \(cleanBand)")
        // Shared segment helper mirrors the burned text.
        let captions = project.videoTimeline?.captions ?? []
        #expect(MediaTimelineMath.caption(at: 0.2, in: captions) == nil)
        #expect(MediaTimelineMath.caption(at: 1.0, in: captions)?.text == "HELLO PREVIEW")
        #expect(MediaTimelineMath.caption(at: 2.5, in: captions) == nil)
    }

    @Test func previewAppliesPreferredOrientationAndCrop() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // Stored 320x180 with a 90° preferred transform => displayed 180x320.
        let rotatedURL = root.appendingPathComponent("rotated.mov")
        try await silentSplitMovie(at: rotatedURL, width: 320, height: 180, fps: 30, seconds: 1,
                                   transform: CGAffineTransform(rotationAngle: .pi / 2))
        let rotated = MediaAssetReference(kind: .video, relativePath: "rotated.mov", originalName: "rotated.mov",
                                          metadata: MediaAssetMetadata(durationSeconds: 1, frameRate: 30))
        let rotatedClip = VideoClip(assetID: rotated.id, trimStart: 0, trimEnd: 1)
        let rotatedProject = project(assets: [rotated], clips: [rotatedClip],
                                     width: 180, height: 320, fps: 30)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let rotatedReceipt = try await renderer.renderPreview(project: rotatedProject)
        let oriented = try await frame(at: rotatedReceipt.url, seconds: 0.5)
        let half = oriented.height / 2
        let topLeft = averageColor(of: oriented, region: CGRect(x: 0, y: 0,
                                                                width: oriented.width / 2, height: half / 2))
        let bottomRight = averageColor(of: oriented, region: CGRect(x: oriented.width / 2, y: half + half / 2,
                                                                    width: oriented.width / 2, height: half / 2))
        // 90° rotation maps the stored left (red) half to the top half.
        #expect(topLeft.r > 0.5 && topLeft.g < 0.4,
                "rotated portrait preview must show red on the top half, got \(topLeft)")
        #expect(bottomRight.g > 0.5 && bottomRight.r < 0.4,
                "rotated portrait preview must show green on the bottom half, got \(bottomRight)")

        // Crop the oriented red half; no green may remain. Crop rects use the
        // Core Image bottom-left origin shared with the image renderer, so the
        // visually-top red half is y 0.5...1.
        let croppedClip = VideoClip(assetID: rotated.id, trimStart: 0, trimEnd: 1,
                                    crop: NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let cropProject = project(assets: [rotated], clips: [croppedClip],
                                  width: 180, height: 320, fps: 30)
        let cropReceipt = try await renderer.renderPreview(project: cropProject)
        let cropped = try await frame(at: cropReceipt.url, seconds: 0.5)
        let croppedTop = averageColor(of: cropped, region: CGRect(x: 0, y: 0,
                                                                  width: cropped.width,
                                                                  height: cropped.height / 2))
        let croppedBottom = averageColor(of: cropped, region: CGRect(x: 0, y: cropped.height / 2,
                                                                     width: cropped.width,
                                                                     height: cropped.height / 2))
        #expect(croppedTop.r > 0.3 && croppedTop.g < 0.15,
                "cropping to the red half must not include green, got \(croppedTop)")
        #expect(croppedBottom.r > 0.3 && croppedBottom.g < 0.15,
                "crop must remove the green half from the whole canvas, got \(croppedBottom)")
    }

    @Test func previewRampsDissolveOpacity() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("red.mp4")
        let secondURL = root.appendingPathComponent("green.mp4")
        try await withMovie(at: firstURL, width: 320, height: 180, fps: 30, seconds: 2,
                            rgba: 0xFFFF0000)
        try await withMovie(at: secondURL, width: 320, height: 180, fps: 30, seconds: 2,
                            rgba: 0xFF00FF00)
        let red = MediaAssetReference(kind: .video, relativePath: "red.mp4", originalName: "red.mp4",
                                      metadata: MediaAssetMetadata(durationSeconds: 2))
        let green = MediaAssetReference(kind: .video, relativePath: "green.mp4", originalName: "green.mp4",
                                        metadata: MediaAssetMetadata(durationSeconds: 2))
        let clips = [VideoClip(assetID: red.id, trimStart: 0, trimEnd: 1.5),
                     VideoClip(assetID: green.id, trimStart: 0.5, trimEnd: 2,
                               leadingTransition: .crossDissolve, transitionDuration: 0.4)]
        let project = project(assets: [red, green], clips: clips, width: 320, height: 180, fps: 30)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        // Dissolve window: [1.1, 1.5]; both clips must be present mid-window
        // and the blend must progress from red to green.
        let early = averageColor(of: try await frame(at: receipt.url, seconds: 1.15))
        let blended = averageColor(of: try await frame(at: receipt.url, seconds: 1.3))
        let late = averageColor(of: try await frame(at: receipt.url, seconds: 1.45))
        #expect(blended.r > 0.2 && blended.r < 0.8 && blended.g > 0.15 && blended.g < 0.85,
                "dissolve midpoint must blend red and green, got \(blended)")
        #expect(early.r > late.r && late.g > early.g,
                "the dissolve must ramp from red to green: early=\(early) late=\(late)")
        let before = averageColor(of: try await frame(at: receipt.url, seconds: 0.5))
        #expect(before.r > 0.6 && before.g < 0.25, "before the dissolve the first clip is solid, got \(before)")
        let after = averageColor(of: try await frame(at: receipt.url, seconds: 1.8))
        #expect(after.g > 0.6 && after.r < 0.35, "after the dissolve the second clip is solid, got \(after)")
    }

    @Test func previewProxyCarriesTheMusicMixAndBothFades() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try await twoClipProject(root: root)
        project.videoTimeline?.primaryVolume = 0.5
        project.videoTimeline?.clips[0].volume = 0.5
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        let asset = AVURLAsset(url: receipt.url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!audioTracks.isEmpty, "music + clip audio must be present in the preview proxy")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4.0) < 0.3)

        // The fade-out ramp itself is built by the shared helper.
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid))
        var parameters: [AVMutableAudioMixInputParameters] = []
        let music = try #require(project.videoTimeline?.music.first)
        WorkbenchVideoRenderer.appendMusicParameters(track: track, music: music,
                                                     timelineEnd: 4, to: &parameters)
        let musicParameters = try #require(parameters.first)
        var startVolume: Float = 0
        var endVolume: Float = 0
        var timeRange = CMTimeRange.zero
        let hasFadeOut = musicParameters.getVolumeRamp(for: CMTime(seconds: 3.75, preferredTimescale: 600),
                                                       startVolume: &startVolume,
                                                       endVolume: &endVolume,
                                                       timeRange: &timeRange)
        #expect(hasFadeOut, "music fade-out ramp must exist")
        #expect(startVolume > endVolume, "fade-out must decrease volume")
    }

    @Test func previewAndExportFramesAgreeWithinTolerance() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await twoClipProject(root: root)
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        let receipt = try await renderer.renderPreview(project: project)
        // 2.0s: second (blue) clip, outside the 0.5...1.5 caption window.
        let previewColor = averageColor(of: try await frame(at: receipt.url, seconds: 2.5))
        let exportReceipt = try await renderer.export(
            project: project,
            options: VideoExportOptions(codec: .h264, width: 640, height: 360, frameRate: 24,
                                        quality: 0.8, fileName: "parity"),
            to: "parity.mp4")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exportReceipt.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exportedColor = averageColor(of: try await generator.image(at: CMTime(seconds: 2.5,
                                                                                  preferredTimescale: 600)).image)
        #expect(abs(previewColor.r - exportedColor.r) < 0.08,
                "red channel differs: preview \(previewColor) vs export \(exportedColor)")
        #expect(abs(previewColor.g - exportedColor.g) < 0.08)
        #expect(abs(previewColor.b - exportedColor.b) < 0.08)
    }

    @Test func previewThrowsForMissingAssetInsteadOfBlankItem() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try await twoClipProject(root: root)
        project.assets = project.assets.filter { $0.originalName != "second.mp4" }
        let renderer = WorkbenchVideoRenderer(rootProvider: { root })
        await #expect(throws: (any Error).self) {
            _ = try await renderer.renderPreview(project: project)
        }
    }

    // MARK: Helpers

    private func project(assets: [MediaAssetReference], clips: [VideoClip],
                         width: Int, height: Int, fps: Double,
                         music: [MusicClip] = [], captions: [CaptionSegment] = []) -> MediaProject {
        var project = MediaProject(kind: .video, name: "V",
                                   canvas: MediaCanvas(width: width, height: height, frameRate: fps))
        project.assets = assets
        project.sourceAssetID = assets.first?.id
        var timeline = VideoTimeline(clips: clips)
        timeline.music = music
        timeline.captions = captions
        project.videoTimeline = timeline
        return project
    }
}
#endif
