// FloeWorkbench — Multi-track video renderer.
//
// One primary track (many clips), music tracks and a burned-in caption track.
// Clips are aspect-fitted into a unified canvas initialized from the first
// clip; mixed orientation/frame-rate sources normalize at export to the
// user's explicit width/height/fps. The SAME composition builder drives the
// in-app AVPlayer preview and the verified atomic export, so edits are
// audible/visible before export.
//
// Timeline semantics (see MediaTimelineMath): a leading cross-dissolve
// overlaps the clip head with the predecessor tail and contracts the
// timeline like a real non-linear editor; every time base (playhead,
// captions, music, export verification) uses those placements.
//
// Each clip gets its own composition track pair (clips are capped by command
// validation), which makes per-clip trim/speed time mapping exact and keeps
// dissolve overlaps legal. A custom Core Image compositor applies crop,
// rotation, aspect-fit, dissolve opacity and captions. Export stages,
// verifies (playable, dimensions, duration, audio/video tracks), then
// atomically replaces the destination; failure never leaves a success file.

import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#endif

public struct WorkbenchVideoExportReceipt: Sendable, Hashable {
    public var url: URL
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: String
    public var hasAudio: Bool
    public var byteCount: Int64
}

/// Rendered preview proxy: a small H.264 file produced by the export
/// renderer and played back by AVPlayer.
public struct WorkbenchPreviewReceipt: Sendable, Hashable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
}

public struct WorkbenchThumbnail: Sendable, Hashable {
    public var clipID: UUID
    public var timeSeconds: Double
    public var pngData: Data
}

#if canImport(AVFoundation)
public actor WorkbenchVideoRenderer {
    public struct Limits: Sendable {
        public var maximumDurationSeconds: Double
        public var maximumPixels: Int
        public var maximumOutputBytes: Int64
        public var maximumThumbnails: Int
        public var maximumClips: Int
        public init(maximumDurationSeconds: Double = 3600, maximumPixels: Int = 3840 * 2160,
                    maximumOutputBytes: Int64 = 8 * 1024 * 1024 * 1024, maximumThumbnails: Int = 200,
                    maximumClips: Int = 24) {
            self.maximumDurationSeconds = maximumDurationSeconds
            self.maximumPixels = maximumPixels
            self.maximumOutputBytes = maximumOutputBytes
            self.maximumThumbnails = maximumThumbnails
            self.maximumClips = maximumClips
        }
    }

    private let rootProvider: @Sendable () -> URL?
    private let limits: Limits
    private let ciContext: CIContext

    public init(limits: Limits = Limits(), rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
        self.limits = limits
        self.ciContext = CIContext()
    }

    // MARK: - Path containment

    private func resolveRoot() throws -> URL {
        guard let root = rootProvider() else {
            throw FloeError.validationFailed("A workspace root is required")
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func resolve(_ path: String, rootOverride: URL? = nil) throws -> URL {
        let canonical: URL
        if let rootOverride {
            canonical = rootOverride
        } else {
            canonical = try resolveRoot()
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonical.appendingPathComponent(path))
            .resolvingSymlinksInPath().standardizedFileURL
        guard url == canonical || url.path.hasPrefix(canonical.path + "/") else {
            throw FloeError.validationFailed("Asset path escapes workspace")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
        return url
    }

    private func resolveOutput(_ path: String, rootOverride: URL? = nil) throws -> URL {
        let canonical: URL
        if let rootOverride {
            canonical = rootOverride
        } else {
            canonical = try resolveRoot()
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonical.appendingPathComponent(path))
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/") else {
            throw FloeError.validationFailed("output path escapes workspace")
        }
        return url
    }

    // MARK: - Probe

    public func inspect(assetPath: String) async throws -> MediaAssetMetadata {
        let url = try resolve(assetPath)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first else { throw FloeError.validationFailed("file has no video track") }
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displayed = natural.applying(transform)
        let fps = Double(try await video.load(.nominalFrameRate))
        return MediaAssetMetadata(width: Int(abs(displayed.width)), height: Int(abs(displayed.height)),
                                  durationSeconds: duration, frameRate: fps,
                                  audioTracks: audios.count,
                                  rotationDegrees: Double(Self.rotationDegrees(transform: transform)),
                                  hasAlpha: false)
    }

    static func rotationDegrees(transform: CGAffineTransform) -> Int {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        return ((Int(angle.rounded()) % 360) + 360) % 360
    }

    // MARK: - Export

    public func export(project: MediaProject, options: VideoExportOptions,
                       to relativeOutput: String, cancellation: CancellationToken? = nil,
                       mediaRoot: URL? = nil,
                       progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> WorkbenchVideoExportReceipt {
        // Freeze the media root BEFORE the first await: the shared renderer's
        // rootProvider is dynamic and a project switch during export must not
        // resolve later clips or music against a different project's root.
        let root: URL
        if let mediaRoot {
            root = mediaRoot.resolvingSymlinksInPath().standardizedFileURL
        } else {
            root = try resolveRoot()
        }
        guard project.kind == .video, let timeline = project.videoTimeline else {
            throw FloeError.validationFailed("project has no video timeline")
        }
        try MediaExportValidation.validateVideo(options, timeline: timeline)
        let placed = MediaTimelineMath.placeClips(timeline.clips)
        guard let tail = placed.last?.timelineEnd, tail.isFinite, tail > 0,
              tail <= limits.maximumDurationSeconds else {
            throw FloeError.validationFailed("timeline duration is invalid or exceeds the limit")
        }
        guard timeline.clips.count <= limits.maximumClips else {
            throw FloeError.validationFailed("at most \(limits.maximumClips) clips are supported")
        }
        guard options.width * options.height <= limits.maximumPixels else {
            throw FloeError.validationFailed("export dimensions exceed the pixel limit")
        }
        let outputURL = try resolveOutput(relativeOutput, rootOverride: root)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let workDir = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".floe-workbench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. Per-clip intermediates (trim + speed + per-clip volume/mute).
        var inputs: [ClipInput] = []
        for (index, item) in placed.enumerated() {
            try cancellation?.throwIfCancelled()
            guard let assetRef = project.asset(item.clip.assetID) else {
                throw FloeError.notFound("asset \(item.clip.assetID)")
            }
            let source = try resolve(assetRef.relativePath, rootOverride: root)
            let url = workDir.appendingPathComponent("clip-\(index).mov")
            let duration = try await normalizeClip(item.clip, source: source, to: url,
                                                   cancellation: cancellation)
            inputs.append(ClipInput(clip: item.clip, url: url, sourceStart: 0,
                                    sourceDuration: duration, timelineDuration: duration,
                                    timelineStart: item.timelineStart))
        }

        // 2. Unified composition (intermediates + dissolve overlaps + music).
        let built = try await buildComposition(project: project, timeline: timeline,
                                               placed: placed, inputs: inputs,
                                               canvasSize: CGSize(width: options.width, height: options.height),
                                               rootOverride: root)
        let videoComposition = makeVideoComposition(timeline: timeline, built: built,
                                                    width: options.width, height: options.height,
                                                    frameRate: options.frameRate, duration: tail)
        built.composition.naturalSize = CGSize(width: options.width, height: options.height)

        let presetName = AVAssetExportSession.presetName(for: options.codec,
                                                         pixels: options.width * options.height)
        guard let exporter = AVAssetExportSession(asset: built.composition, presetName: presetName) else {
            throw FloeError.internalError("could not create export session")
        }
        exporter.videoComposition = videoComposition
        exporter.audioMix = built.audioMix
        exporter.shouldOptimizeForNetworkUse = true
        let staged = workDir.appendingPathComponent("export.mp4")
        try await run(exporter: exporter, to: staged,
                      cancellation: cancellation, progress: progress)
        try cancellation?.throwIfCancelled()

        // 3. Verify before atomic commit.
        let verified = try await verify(staged, expectedWidth: options.width, expectedHeight: options.height,
                                  expectedDuration: tail, timeline: timeline,
                                  codec: options.codec.rawValue)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: outputURL)
        }
        return WorkbenchVideoExportReceipt(url: outputURL, durationSeconds: verified.durationSeconds,
                                           width: options.width, height: options.height,
                                           frameRate: verified.frameRate, codec: options.codec.rawValue,
                                           hasAudio: verified.hasAudio, byteCount: verified.byteCount)
    }

    private func run(exporter: AVAssetExportSession, to url: URL,
                     cancellation: CancellationToken?,
                     progress: @Sendable @escaping (Double) -> Void) async throws {
        // The session is captured by exactly one task (FloeMedia isolation
        // pattern); the watcher only touches the task handle and never the
        // session. Progress is reported as staged fractions, not invented
        // encoder percentages.
        let exportTask = Task { try await self.finishExport(exporter, to: url) }
        let watcher = Task {
            var stage = 0.1
            while !Task.isCancelled {
                if cancellation?.isCancelled == true { exportTask.cancel(); return }
                progress(stage)
                stage = min(0.9, stage + 0.05)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        do {
            try await withTaskCancellationHandler { try await exportTask.value } onCancel: { exportTask.cancel() }
        } catch {
            watcher.cancel()
            if cancellation?.isCancelled == true { throw FloeError.cancelled }
            throw FloeError.internalError("video export failed: \(error.localizedDescription)")
        }
        progress(1)
    }

    private func normalizeClip(_ clip: VideoClip, source: URL, to output: URL,
                               cancellation: CancellationToken?) async throws -> Double {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let end = min(clip.trimEnd, CMTimeGetSeconds(duration))
        let range = CMTimeRange(start: CMTime(seconds: clip.trimStart, preferredTimescale: 600),
                                duration: CMTime(seconds: end - clip.trimStart, preferredTimescale: 600))
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FloeError.validationFailed("clip has no video track")
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var audioTrack: AVMutableCompositionTrack?
        if !clip.isMuted,
           let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
            audioTrack = audio
        }
        let renderedDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / clip.speed)
        if clip.speed != 1 {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                       toDuration: renderedDuration)
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw FloeError.internalError("could not create clip exporter")
        }
        if let audioTrack {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(Float(max(0, min(4, clip.volume))), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            exporter.audioMix = mix
        }
        let exportTask = Task { try await self.finishNormalize(exporter, output: output) }
        let watcher = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true { exportTask.cancel(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { watcher.cancel() }
        do {
            try await withTaskCancellationHandler { try await exportTask.value } onCancel: { exportTask.cancel() }
        } catch {
            watcher.cancel()
            if cancellation?.isCancelled == true { throw FloeError.cancelled }
            throw FloeError.internalError("clip normalization failed: \(error.localizedDescription)")
        }
        let exported = AVURLAsset(url: output)
        let seconds = try await exported.load(.duration).seconds
        guard seconds > 0 else { throw FloeError.internalError("clip normalization produced an empty file") }
        return seconds
    }

    // MARK: - AVFoundation transfer helpers

    /// Session interaction stays inside actor-isolated helper tasks, matching
    /// the FloeMedia isolation pattern; only the task handle crosses to the
    /// cancellation watcher.
    private func finishNormalize(_ session: AVAssetExportSession, output: URL) async throws {
        try await session.export(to: output, as: .mov)
    }

    private func finishExport(_ session: AVAssetExportSession, to url: URL) async throws {
        try await session.export(to: url, as: .mp4)
    }

    // MARK: - Unified composition

    fileprivate struct ClipInput: @unchecked Sendable {
        let clip: VideoClip
        let url: URL
        let sourceStart: Double
        let sourceDuration: Double
        let timelineDuration: Double
        let timelineStart: Double
    }

    struct Residency {
        let trackID: CMPersistentTrackID
        let track: AVAssetTrack
        let clip: VideoClip
        let start: Double
        let end: Double
        /// Shared raw-buffer → canvas geometry (orientation, crop, rotation,
        /// aspect-fit). Used by the export compositor and the preview layer
        /// instructions so both render the same frame.
        let geometry: WorkbenchClipGeometry
    }

    fileprivate struct BuiltComposition: @unchecked Sendable {
        let composition: AVMutableComposition
        let audioMix: AVMutableAudioMix
        let residencies: [Residency]
        let duration: Double
    }

    /// One video + one audio track PER CLIP. Tracks never overlap with
    /// themselves, and dissolve overlaps between neighbors land on distinct
    /// tracks, so AVFoundation mapping stays exact.
    private func buildComposition(project: MediaProject, timeline: VideoTimeline,
                                  placed: [PlacedClip], inputs: [ClipInput],
                                  canvasSize: CGSize, rootOverride: URL? = nil) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        var residencies: [Residency] = []
        var audioParameters: [AVMutableAudioMixInputParameters] = []

        for input in inputs {
            let asset = AVURLAsset(url: input.url)
            let sourceRange = CMTimeRange(start: CMTime(seconds: input.sourceStart, preferredTimescale: 600),
                                          duration: CMTime(seconds: input.sourceDuration, preferredTimescale: 600))
            let at = CMTime(seconds: input.timelineStart, preferredTimescale: 600)
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FloeError.internalError("could not create video track")
            }
            var geometry = WorkbenchClipGeometry.make(naturalSize: CGSize(width: 2, height: 2),
                                                      preferredTransform: .identity,
                                                      crop: input.clip.crop,
                                                      rotationDegrees: input.clip.rotationDegrees,
                                                      canvas: canvasSize)
            if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: at)
                if abs(input.timelineDuration - input.sourceDuration) > 0.001 {
                    videoTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                              toDuration: CMTime(seconds: input.timelineDuration, preferredTimescale: 600))
                }
                let preferredTransform = try await sourceVideo.load(.preferredTransform)
                let natural = try await sourceVideo.load(.naturalSize)
                geometry = WorkbenchClipGeometry.make(naturalSize: natural,
                                                      preferredTransform: preferredTransform,
                                                      crop: input.clip.crop,
                                                      rotationDegrees: input.clip.rotationDegrees,
                                                      canvas: canvasSize)
            }
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: at)
                if abs(input.timelineDuration - input.sourceDuration) > 0.001 {
                    audioTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration),
                                              toDuration: CMTime(seconds: input.timelineDuration, preferredTimescale: 600))
                }
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.setVolume(timeline.primaryMuted ? 0
                    : Float(max(0, min(4, timeline.primaryVolume))), at: .zero)
                audioParameters.append(params)
            }
            residencies.append(Residency(trackID: videoTrack.trackID, track: videoTrack,
                                         clip: input.clip,
                                         start: input.timelineStart,
                                         end: input.timelineStart + input.timelineDuration,
                                         geometry: geometry))
        }

        // Music: own track per entry; trim, offset, volume and fades.
        let resolvedDuration = placed.last?.timelineEnd ?? 0
        for music in timeline.music {
            guard let assetRef = project.asset(music.assetID) else {
                throw FloeError.notFound("music asset \(music.assetID)")
            }
            let url = try resolve(assetRef.relativePath, rootOverride: rootOverride)
            let asset = AVURLAsset(url: url)
            guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FloeError.validationFailed("music file has no audio track")
            }
            let end = min(music.offsetSeconds + music.lengthSeconds, resolvedDuration)
            let length = max(0, end - music.offsetSeconds)
            guard length > 0.05 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: music.trimStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: length, preferredTimescale: 600))
            let at = CMTime(seconds: music.offsetSeconds, preferredTimescale: 600)
            try track.insertTimeRange(range, of: sourceAudio, at: at)
            Self.appendMusicParameters(track: track, music: music, timelineEnd: end,
                                       to: &audioParameters)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters
        return BuiltComposition(composition: composition, audioMix: mix,
                                residencies: residencies, duration: resolvedDuration)
    }

    private func makeVideoComposition(timeline: VideoTimeline, built: BuiltComposition,
                                      width: Int, height: Int,
                                      frameRate: Double, duration: Double) -> AVVideoComposition {
        Self.makeVideoComposition(residencies: built.residencies,
                                  placed: MediaTimelineMath.placeClips(timeline.clips),
                                  captions: timeline.captions, style: timeline.captionStyle,
                                  width: width, height: height, frameRate: frameRate,
                                  duration: duration, context: ciContext)
    }

    /// Composition builder for the export path's custom compositor. Export
    /// runs in-process and receives the original instruction object with its
    /// configuration; one instruction spanning the edit is sufficient because
    /// `AVAssetExportSession` delivers every source track whose range
    /// intersects the composition time (unlike AVPlayer, which needs the
    /// serialized per-segment layer instructions used by the preview path).
    static func makeVideoComposition(residencies: [Residency], placed: [PlacedClip],
                                     captions: [CaptionSegment], style: CaptionStyle,
                                     width: Int, height: Int,
                                     frameRate: Double, duration: Double,
                                     context: CIContext) -> AVMutableVideoComposition {
        let configuration = RenderConfiguration(residencies: residencies,
                                                 windows: MediaTimelineMath.dissolveWindows(placed),
                                                 captions: captions, style: style,
                                                 width: width, height: height, context: context)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = WorkbenchVideoCompositor.self
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.frameDuration = CMTime(seconds: 1 / max(frameRate, 0.0001), preferredTimescale: 600)
        let instruction = WorkbenchCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero,
                                            duration: CMTime(seconds: duration, preferredTimescale: 600))
        instruction.enablePostProcessing = true
        instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        instruction.configuration = configuration
        // Declare every source track: `requiredSourceTrackIDs` is computed
        // from the layer instructions, and an empty list makes the export
        // pipeline deliver only the first track's frames (later clips render
        // black). The custom compositor ignores the layer instructions and
        // selects the active clip per composition time itself.
        instruction.layerInstructions = residencies.map { residency in
            AVMutableVideoCompositionLayerInstruction(assetTrack: residency.track)
        }
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    private func verify(_ url: URL, expectedWidth: Int, expectedHeight: Int,
                        expectedDuration: Double, timeline: VideoTimeline,
                        codec: String) async throws -> WorkbenchVideoExportReceipt {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw FloeError.internalError("exported file is not playable")
        }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw FloeError.internalError("exported file has no video track")
        }
        let size = try await video.load(.naturalSize)
        let actualDuration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0, bytes <= limits.maximumOutputBytes else {
            throw FloeError.internalError("exported file has an invalid size")
        }
        guard Int(size.width) == expectedWidth, Int(size.height) == expectedHeight else {
            throw FloeError.internalError("exported dimensions \(Int(size.width))x\(Int(size.height)) do not match \(expectedWidth)x\(expectedHeight)")
        }
        guard abs(actualDuration - expectedDuration) <= max(0.25, expectedDuration * 0.02) else {
            throw FloeError.internalError("exported duration \(actualDuration)s does not match timeline \(expectedDuration)s")
        }
        if !timeline.music.isEmpty {
            guard !audioTracks.isEmpty else {
                throw FloeError.internalError("music mix is missing from export")
            }
        }
        let hasPrimaryAudio = timeline.clips.contains { !$0.isMuted } && !timeline.primaryMuted
        let fpsOut = try await video.load(.nominalFrameRate)
        return WorkbenchVideoExportReceipt(url: url, durationSeconds: actualDuration,
                                           width: expectedWidth, height: expectedHeight,
                                           frameRate: Double(fpsOut), codec: codec,
                                           hasAudio: hasPrimaryAudio || !timeline.music.isEmpty,
                                           byteCount: bytes)
    }

    // MARK: - Thumbnails

    public func thumbnails(project: MediaProject, perClip: Int = 2,
                           maximumDimension: Int = 240) async throws -> [WorkbenchThumbnail] {
        guard project.kind == .video, let timeline = project.videoTimeline else {
            throw FloeError.validationFailed("project has no video timeline")
        }
        let perClip = max(1, min(perClip, 8))
        var result: [WorkbenchThumbnail] = []
        for placed in MediaTimelineMath.placeClips(timeline.clips) {
            guard let assetRef = project.asset(placed.clip.assetID) else { continue }
            let url = try resolve(assetRef.relativePath)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
            for step in 0..<perClip {
                let fraction = Double(step + 1) / Double(perClip + 1)
                let time = placed.clip.trimStart + fraction * placed.clip.sourceDuration
                guard let cg = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                      let data = WorkbenchImageIO.pngData(from: cg) else { continue }
                result.append(WorkbenchThumbnail(clipID: placed.clip.id, timeSeconds: time, pngData: data))
            }
        }
        guard result.count <= limits.maximumThumbnails else {
            throw FloeError.validationFailed("too many thumbnails requested")
        }
        return result
    }

    // MARK: - Live preview proxy

    /// Dissolve opacity of a clip at a timeline time; shared with the render
    /// configuration used by the export compositor.
    static func opacity(for clipID: UUID, at time: Double, windows: [DissolveWindow]) -> Double {
        for window in windows {
            if window.toClipID == clipID, time >= window.start, time <= window.end {
                return min(1, max(0, (time - window.start) / max(window.duration, 0.001)))
            }
            if window.fromClipID == clipID, time >= window.start, time <= window.end {
                return min(1, max(0, 1 - (time - window.start) / max(window.duration, 0.001)))
            }
        }
        return 1
    }    /// Renders a lightweight proxy of the current edit through the SAME
    /// export pipeline and returns its file URL.
    ///
    /// The in-app preview deliberately plays a rendered file instead of an
    /// `AVPlayerItem` carrying an `AVVideoComposition`: on iOS 27 the
    /// playback pipeline refuses to prepare composition items attached to an
    /// `AVPlayerLayer` (AVFoundation -11800 / OSStatus -12784) even though the
    /// same composition is valid for export and for headless players. Playing
    /// the rendered file keeps behavior identical on device and simulator and
    /// makes the preview literally the export frames (transforms, crop,
    /// dissolves, burned captions, clip volume, music fades) with no separate
    /// playback renderer to drift out of sync.
    public func renderPreview(project: MediaProject,
                              cancellation: CancellationToken? = nil) async throws -> WorkbenchPreviewReceipt {
        guard project.kind == .video, let timeline = project.videoTimeline else {
            throw FloeError.validationFailed("project has no video timeline")
        }
        guard let canvas = project.canvas, let fps = canvas.frameRate, fps > 0 else {
            throw FloeError.validationFailed("video project requires a canvas and frame rate")
        }
        let longestEdge = max(canvas.width, canvas.height)
        let scale = longestEdge > 1280 ? 1280.0 / Double(longestEdge) : 1
        let options = VideoExportOptions(codec: .h264,
                                         width: MediaResourceGuard.even(max(2, Int(Double(canvas.width) * scale))),
                                         height: MediaResourceGuard.even(max(2, Int(Double(canvas.height) * scale))),
                                         frameRate: min(max(fps, 1), 30),
                                         quality: 0.6,
                                         fileName: "preview")
        let relative = "Workbench/Previews/\(project.id.uuidString)-r\(project.revision).mp4"
        let receipt = try await export(project: project, options: options, to: relative,
                                       cancellation: cancellation)
        return WorkbenchPreviewReceipt(url: receipt.url, width: receipt.width,
                                       height: receipt.height,
                                       durationSeconds: receipt.durationSeconds)
    }

    /// Adds a music track's volume + fade-in + fade-out parameters.
    /// `timelineEnd` is the clamped end of the music on the timeline.
    static func appendMusicParameters(track: AVAssetTrack,
                                      music: MusicClip,
                                      timelineEnd: Double,
                                      to parameters: inout [AVMutableAudioMixInputParameters]) {
        let params = AVMutableAudioMixInputParameters(track: track)
        let volume = Float(max(0, min(4, music.volume)))
        let at = CMTime(seconds: music.offsetSeconds, preferredTimescale: 600)
        params.setVolume(volume, at: at)
        if music.fadeInSeconds > 0 {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                 timeRange: CMTimeRange(start: at,
                                                        duration: CMTime(seconds: music.fadeInSeconds, preferredTimescale: 600)))
        }
        if music.fadeOutSeconds > 0 {
            let fadeStart = max(music.offsetSeconds, timelineEnd - music.fadeOutSeconds)
            let fadeDuration = timelineEnd - fadeStart
            if fadeDuration > 0.001 {
                params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: CMTime(seconds: fadeStart, preferredTimescale: 600),
                                                            duration: CMTime(seconds: fadeDuration, preferredTimescale: 600)))
            }
        }
        parameters.append(params)
    }
}

// MARK: - HEVC preset selection

extension AVAssetExportSession {
    static func presetName(for codec: VideoExportCodec, pixels: Int) -> String {
        switch codec {
        case .h264:
            return AVAssetExportPresetHighestQuality
        case .hevc:
            if pixels <= 1920 * 1080 { return AVAssetExportPresetHEVC1920x1080 }
            if pixels <= 3840 * 2160 { return AVAssetExportPresetHEVC3840x2160 }
            return AVAssetExportPresetHEVCHighestQuality
        }
    }
}

// MARK: - Render configuration carried by the instruction

struct RenderConfiguration: @unchecked Sendable {
    let residencies: [WorkbenchVideoRenderer.Residency]
    let windows: [DissolveWindow]
    let captions: [CaptionSegment]
    let style: CaptionStyle
    let width: Int
    let height: Int
    let context: CIContext

    func residency(at time: Double, trackID: CMPersistentTrackID) -> WorkbenchVideoRenderer.Residency? {
        residencies.first { $0.trackID == trackID && time >= $0.start - 0.001 && time <= $0.end + 0.001 }
    }

    func opacity(for clipID: UUID, at time: Double) -> Double {
        WorkbenchVideoRenderer.opacity(for: clipID, at: time, windows: windows)
    }

    func caption(at time: Double) -> CaptionSegment? {
        MediaTimelineMath.caption(at: time, in: captions)
    }
}

final class WorkbenchCompositionInstruction: AVMutableVideoCompositionInstruction, @unchecked Sendable {
    var configuration: RenderConfiguration?

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let typed = copy as? WorkbenchCompositionInstruction {
            typed.configuration = configuration
        }
        return copy
    }

    override func mutableCopy(with zone: NSZone? = nil) -> Any {
        let copy = super.mutableCopy(with: zone)
        if let typed = copy as? WorkbenchCompositionInstruction {
            typed.configuration = configuration
        }
        return copy
    }
}

final class WorkbenchVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var renderContext: AVVideoCompositionRenderContext?
    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var supportsWideColorSourceFrames = true
    var canConformColorOfSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? WorkbenchCompositionInstruction,
              let config = instruction.configuration,
              let output = renderContext?.newPixelBuffer() else {
            request.finish(with: FloeError.internalError("compositor unavailable"))
            return
        }
        let time = request.compositionTime.seconds
        let canvas = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        var composed = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        for trackIDValue in request.sourceTrackIDs {
            let trackID = trackIDValue.int32Value
            guard let frame = request.sourceFrame(byTrackID: trackID),
                  let residency = config.residency(at: time, trackID: trackID) else { continue }
            var image = CIImage(cvPixelBuffer: frame)
            image = Self.apply(residency: residency, to: image, canvas: canvas.size)
            let opacity = config.opacity(for: residency.clip.id, at: time)
            if opacity < 0.999 {
                let alpha = CIFilter(name: "CIColorMatrix")!
                alpha.setValue(image, forKey: kCIInputImageKey)
                alpha.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)), forKey: "inputAVector")
                image = alpha.outputImage ?? image
            }
            composed = image.composited(over: composed)
        }
        if let caption = config.caption(at: time) {
            let text = Self.makeCaptionImage(caption, style: config.style, canvas: canvas.size)
            composed = text.composited(over: composed)
        }
        config.context.render(composed, to: output)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Frame requests are synchronous in this implementation; nothing is queued.
    }

    private static func apply(residency: WorkbenchVideoRenderer.Residency,
                              to source: CIImage, canvas: CGSize) -> CIImage {
        let geometry = residency.geometry
        var image = source
        if let sourceCrop = geometry.sourceCrop {
            image = image.cropped(to: sourceCrop)
        }
        image = image.transformed(by: geometry.canvasTransform)
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private static func makeCaptionImage(_ caption: CaptionSegment, style: CaptionStyle,
                                         canvas: CGSize) -> CIImage {
        let fontSize = max(10, min(style.fontSize, canvas.height * 0.12))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: WorkbenchColor.cgColor(style.colorHex),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: caption.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = canvas.width * 0.88
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil,
            CGSize(width: maxWidth, height: canvas.height * 0.4), nil)
        let padding = max(8, fontSize * 0.25)
        let box = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        guard let ctx = CGContext(data: nil, width: max(1, Int(box.width.rounded(.up))),
                                  height: max(1, Int(box.height.rounded(.up))),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }
        if let bg = style.backgroundHex, let background = WorkbenchColor.cgColor(bg).copy(alpha: 0.6) {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: box.width, height: box.height))
        }
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height),
                          transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let raw = CIImage(cgImage: cg)
        let x = (canvas.width - box.width) / 2
        let y = (1 - style.positionY) * canvas.height - box.height / 2
        return raw.transformed(by: CGAffineTransform(translationX: x - raw.extent.minX,
                                                     y: y - raw.extent.minY))
    }
}

enum WorkbenchColor {
    static func cgColor(_ hex: String) -> CGColor {
        var v = hex
        if v.hasPrefix("#") { v.removeFirst() }
        let int = UInt32(v, radix: 16) ?? 0
        return CGColor(red: CGFloat((int >> 16) & 0xFF) / 255,
                       green: CGFloat((int >> 8) & 0xFF) / 255,
                       blue: CGFloat(int & 0xFF) / 255, alpha: 1)
    }
}

enum WorkbenchImageIO {
    static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif
