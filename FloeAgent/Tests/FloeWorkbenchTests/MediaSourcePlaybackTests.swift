// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import AVFoundation
import CoreGraphics
@testable import FloeWorkbench

@Suite("M30 M31 M42 source playback products", .serialized)
struct MediaSourcePlaybackTests {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-source-playback-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func record(_ name: String, _ data: Data) throws {
        guard let path = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    func color(_ image: CGImage) throws -> (Int, Int, Int) {
        let pixels = try MediaNativeSelection.rgba(image).pixels
        let at = (image.height / 2 * image.width + image.width / 2) * 4
        return (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
    }
    @Test func actualVideoReverseAndHoldMatchPreviewAndExportWithoutChangingSource() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let rate = try PreparedVideoFrameRate(numerator: 8, denominator: 1)
        let whole = try PreparedVideoTimeRange(startSeconds: 0, durationSeconds: 1, timescale: 600)
        let settings = try PreparedVideoOutputSettings(width: 64, height: 64, frameRate: rate)
        let sourcePlan = try PreparedVideoPlan(id: .init(projectID: UUID(), revision: 1), timeScale: 600,
            frameRate: rate, duration: whole.duration, canvas: .init(width: 64, height: 64), assets: [], visualTracks: [
                .init(id: UUID(), name: "Two real source shots", clips: [
                    .init(id: UUID(), content: .graphic(.init(shape: .rectangle, width: 1, height: 1, fillColor: try .init(hex: "#FF0000"))), timelineRange: try .init(startSeconds: 0, durationSeconds: 0.5, timescale: 600)),
                    .init(id: UUID(), content: .graphic(.init(shape: .rectangle, width: 1, height: 1, fillColor: try .init(hex: "#0000FF"))), timelineRange: try .init(startSeconds: 0.5, durationSeconds: 0.5, timescale: 600))
                ])])
        let source = folder.appendingPathComponent("original.mp4"), exporter = PreparedVideoExporter()
        _ = try await exporter.renderWindow(plan: sourcePlan, window: .init(range: whole, frameRate: rate), settings: settings, destination: source, overwrite: false, cancellation: .none, progress: { _ in })
        let original = try Data(contentsOf: source), asset = PreparedVideoAsset(id: UUID(), url: source, kind: .video, duration: whole.duration, frameRate: rate)
        for (name, playback) in [("M30", MediaSourcePlayback(isReversed: true)), ("M31", .init(holdSeconds: 0.75))] {
            let clip = PreparedVideoClip(id: UUID(), content: .video(assetID: asset.id), timelineRange: whole, sourceRange: whole,
                sourcePlayback: playback, sourceFrameDuration: 0.125)
            let plan = try PreparedVideoPlan(id: .init(projectID: UUID(), revision: 2), timeScale: 600, frameRate: rate,
                duration: whole.duration, canvas: .init(width: 64, height: 64), assets: [asset], visualTracks: [.init(id: UUID(), name: name, clips: [clip])])
            let renderer = PreparedVideoFrameRenderer()
            let first = try await renderer.renderFrame(plan: plan, frameIndex: 0, settings: settings)
            let last = try await renderer.renderFrame(plan: plan, frameIndex: 7, settings: settings)
            let a = try color(first.image), b = try color(last.image)
            #expect(a.2 > a.0 + 100)
            if name == "M30" { #expect(b.0 > b.2 + 100) } else { #expect(b.2 > b.0 + 100) }
            try record(name + "-preview.png", try #require(WorkbenchPNG.encode(first.image)))
            let destination = folder.appendingPathComponent(name + ".mp4")
            let receipt = try await exporter.renderWindow(plan: plan, window: .init(range: whole, frameRate: rate), settings: settings, destination: destination, overwrite: false, cancellation: .none, progress: { _ in })
            #expect(receipt.frameCount == 8 && abs(receipt.durationSeconds - 1) < 0.001)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let decoded = try await generator.image(at: CMTime(value: 7, timescale: 8)).image
            let c = try color(decoded)
            if name == "M30" { #expect(c.0 > c.2 + 100) } else { #expect(c.2 > c.0 + 100) }
            try record(name + ".mp4", Data(contentsOf: destination))
        }
        #expect(try Data(contentsOf: source) == original)
    }
    @Test func reverseAudioUsesCorrectSourceWindowAtOneAndTwoX() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)); buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(i) / 48_000 * 0.4 }
        let source = folder.appendingPathComponent("original.wav")
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        for speed in [1.0, 2.0] {
            let whole = try PreparedVideoTimeRange(startSeconds: 0, durationSeconds: 1 / speed, timescale: 600)
            let windowRange = try PreparedVideoTimeRange(startSeconds: 0.2 / speed, durationSeconds: 0.4 / speed, timescale: 600), id = UUID()
            let plan = try PreparedVideoPlan(id: .init(projectID: UUID(), revision: 1), timeScale: 600,
                frameRate: .init(numerator: 30, denominator: 1), duration: whole.duration, canvas: .init(width: 16, height: 16),
                assets: [.init(id: id, url: source, kind: .audio, duration: try .init(seconds: 1, timescale: 600))],
                visualTracks: [.init(id: UUID(), name: "Reference", clips: [.init(id: UUID(), content: .graphic(.init(shape: .rectangle, width: 1, height: 1, fillColor: .black)), timelineRange: whole)])],
                audio: .init(tracks: [.init(id: UUID(), name: "Reversed", clips: [.init(id: UUID(), assetID: id, timelineRange: whole, sourceRange: try .init(startSeconds: 0, durationSeconds: 1, timescale: 600), speed: speed, isReversed: true)])]))
            let destination = folder.appendingPathComponent("M30-audio-\(speed).wav")
            let receipt = try await PreparedVideoAudioMixer().mix(.init(plan: plan, window: .init(range: windowRange, frameRate: plan.frameRate), sampleRate: 48_000, channelCount: 1, destination: destination))
            let file = try AVAudioFile(forReading: destination)
            let result = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))); try file.read(into: result)
            #expect(receipt.deliveredFrames == Int((windowRange.duration.seconds * 48_000).rounded()))
            for fraction in [0.1, 0.5, 0.9] {
                let frame = Int(Double(result.frameLength) * fraction), expected = Float(0.8 - 0.4 * fraction) * 0.4
                #expect(abs(result.floatChannelData![0][frame] - expected) < 0.01)
            }
            try record(destination.lastPathComponent, Data(contentsOf: destination))
        }
    }
    @Test func playbackFieldsPersistUndoAndHeldAudioIsSilentWithoutLosingMuteState() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let p = MediaProject(kind: .video, name: "Playback", canvas: .init(width: 64, height: 64, frameRate: 30))
        let store = MediaProjectStore(directory: folder), c = MediaPreparedCoordinator(store: store)
        try await store.save(p); _ = try await c.upgradeDocument(id: p.id)
        let asset = MediaAssetReference(kind: .video, relativePath: "source.mp4", originalName: "Source"), audio = MediaAssetReference(kind: .audio, relativePath: "source.wav", originalName: "Audio")
        let range = try MediaTimeRange(start: .init(value: 0, timescale: 600), duration: .init(value: 600, timescale: 600))
        let visual = MediaPreparedClip(assetID: asset.id, timelineRange: range, sourceRange: range, isMuted: true)
        let sound = MediaPreparedClip(assetID: audio.id, timelineRange: range, sourceRange: range, sourceVisualClipID: visual.id)
        let picture = MediaPreparedTrack(kind: .visual, name: "Video", clips: [visual]), track = MediaPreparedTrack(kind: .audio, name: "Source", clips: [sound])
        _ = try await c.applyUserOperations([.init(action: .insertAsset(asset)), .init(action: .insertAsset(audio)), .init(action: .insertTrack(track: picture, index: nil)), .init(action: .insertTrack(track: track, index: nil))], to: p.id)
        let d = try await c.loadDocument(id: p.id)
        var held = try #require(d.trackGraph.clip(id: visual.id)?.clip), quiet = try #require(d.trackGraph.clip(id: sound.id)?.clip)
        held.sourcePlayback = .init(holdSeconds: 0.5); quiet.sourcePlayback = held.sourcePlayback
        let edit = try await c.applyUserOperations([.init(action: .replaceClip(trackID: picture.id, clipID: held.id, expectedRevision: held.revision, clip: held)), .init(action: .replaceClip(trackID: track.id, clipID: quiet.id, expectedRevision: quiet.revision, clip: quiet))], to: p.id)
        let reloaded = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: folder)).loadDocument(id: p.id)
        #expect(reloaded.trackGraph.clip(id: visual.id)?.clip.sourcePlayback?.holdSeconds == 0.5)
        #expect(reloaded.trackGraph.clip(id: sound.id)?.clip.isMuted == false)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reloaded, assetURLs: [asset.id: folder.appendingPathComponent("source.mp4"), audio.id: folder.appendingPathComponent("source.wav")])
        #expect(plan.audio.tracks.allSatisfy { $0.clips.isEmpty })
        _ = try await c.undoGroup(edit.groupID, in: p.id)
        #expect(try await c.loadDocument(id: p.id).trackGraph.clip(id: visual.id)?.clip.sourcePlayback == nil)
        _ = try await c.redoGroup(edit.groupID, in: p.id)
        #expect(try await c.loadDocument(id: p.id).trackGraph.clip(id: visual.id)?.clip.sourcePlayback == held.sourcePlayback)
        let legacy = MediaPreparedClip(timelineRange: range, sourceRange: range)
        #expect(try JSONDecoder().decode(MediaPreparedClip.self, from: JSONEncoder().encode(legacy)).sourcePlayback == nil)
        #expect(throws: MediaPreparedCoreError.self) { try MediaSourcePlaybackMath.sourceSeconds(sourceStart: 0, sourceDuration: 1, speed: 1, localTime: 0, playback: .init(holdSeconds: 1), frameDuration: 1 / 30) }
        let reverseTrim = try MediaSourcePlaybackMath.sourceTrim(sourceStart: 2, sourceDuration: 4, speed: 2, offset: 0.5, duration: 1, playback: .init(isReversed: true))
        #expect(reverseTrim.start == 3 && reverseTrim.duration == 2)
    }
    @Test func captionStyleActuallyRendersAtRequestedPositionAndColor() async throws {
        let range = try PreparedVideoTimeRange(startSeconds: 0, durationSeconds: 1, timescale: 600), rate = try PreparedVideoFrameRate(numerator: 30, denominator: 1)
        let settings = try PreparedVideoOutputSettings(width: 128, height: 128, frameRate: rate)
        let plan = try PreparedVideoPlan(id: .init(projectID: UUID(), revision: 1), timeScale: 600, frameRate: rate,
            duration: range.duration, canvas: .init(width: 128, height: 128), assets: [],
            visualTracks: [.init(id: UUID(), name: "Black", clips: [.init(id: UUID(), content: .graphic(.init(shape: .rectangle, width: 1, height: 1, fillColor: .black)), timelineRange: range)])],
            captions: [.init(id: UUID(), timelineRange: range, text: "Caption")],
            captionStyle: .init(fontSize: 18, color: try .init(hex: "#FF0000"), backgroundColor: nil, positionY: 0.25))
        let frame = try await PreparedVideoFrameRenderer().renderFrame(plan: plan, frameIndex: 0, settings: settings)
        let pixels = try MediaNativeSelection.rgba(frame.image).pixels
        let reds = stride(from: 0, to: pixels.count, by: 4).filter { Int(pixels[$0]) > Int(pixels[$0 + 1]) + 60 }
        #expect(reds.count > 40)
        // RGBA snapshot is top-leading, as the native canvas coordinates are.
        var yTotal = 0.0
        for index in reds { yTotal += Double(index / 4 / 128) }
        let meanY = yTotal / Double(max(1, reds.count))
        #expect(meanY < 70)
        try record("M42-caption-style.png", try #require(WorkbenchPNG.encode(frame.image)))
    }
}
