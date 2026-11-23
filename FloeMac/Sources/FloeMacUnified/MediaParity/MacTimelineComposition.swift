// SPDX-License-Identifier: MPL-2.0

// AVFoundation composition, custom compositing and export for the Mac
// timeline editor.
//
// The builder turns a validated `MacTimelineDraft` plus probed asset info
// into an `AVMutableComposition` (video/audio tracks in draft stack order),
// an `AVMutableAudioMix` with per-track volume, and an
// `AVMutableVideoComposition` tiled into constant "scene" segments. The
// custom `MacTimelineCompositor` renders each segment: source video frames,
// still-image clips (synthesized, aspect-filled, graded) and burned-in
// caption cues, stacked in draft track order exactly like the iPad
// prepared-video renderer.
//
// Export uses AVAssetExportSession with the custom video composition, writes
// through the shared staged/verified/atomic `MacMediaEditCommit`, and never
// touches the input bytes.
//
// The instruction/compositor follow the exact SDK contract proven by the
// shipping iPad `WorkbenchVideoRenderer.WorkbenchVideoCompositor`: the
// compositor receives frames through `sourceFrame(byTrackID:)` after the
// instruction declares its source tracks via `layerInstructions`, and each
// rendered frame is drawn into a pixel buffer from
// `renderContext.newPixelBuffer()`.

import AppKit
import AVFoundation
import CoreImage
import FloeCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Errors

enum MacTimelineExportError: Error, Hashable, LocalizedError {
    case emptyTimeline
    case unsupportedSource(String)
    case exporterUnavailable
    case exportFailed(String)
    case verificationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return MacTimelineExportStrings.emptyTimeline
        case .unsupportedSource(let path):
            return String(format: MacTimelineExportStrings.unsupportedSourceFormat, path)
        case .exporterUnavailable:
            return MacTimelineExportStrings.exporterUnavailable
        case .exportFailed(let detail):
            return String(format: MacTimelineExportStrings.exportFailedFormat, detail)
        case .verificationFailed:
            return MacMediaEditStrings.verificationFailed
        case .cancelled:
            return MacMediaEditStrings.cancelled
        }
    }
}

// MARK: - Asset probing

/// Verified per-URL facts the composition builder needs. Probed once by the
/// UI layer (or tests) before building; the builder composes only through
/// these values plus AVFoundation track references.
struct MacTimelineAssetInfo: Sendable, Hashable {
    /// Playable duration in seconds (0 for still images).
    var duration: Double
    /// Pixel size of the first video track (nil for audio/images).
    var videoSize: CGSize?
    /// `preferredTransform` of the first video track; the compositor applies
    /// it so rotated phone video lands upright.
    var preferredTransform: CGAffineTransform?
    /// Pixel size for still-image sources (nil for movies/audio).
    var imageSize: CGSize?
    var hasAudio: Bool

    var isVisualMovie: Bool { videoSize != nil }
    var isStillImage: Bool { imageSize != nil }
}

enum MacTimelineAssetProber {
    static let maximumSourceBytes = MacVideoEditExporter.maximumSourceBytes

    /// Probes a user-picked media file. Throws with a localized reason when
    /// the file is not usable timeline input.
    static func probe(_ url: URL) async throws -> MacTimelineAssetInfo {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumSourceBytes else {
            throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
            }
            let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map { CGFloat(truncating: $0) } ?? CGFloat(image.width)
            let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map { CGFloat(truncating: $0) } ?? CGFloat(image.height)
            guard pixelWidth >= 2, pixelHeight >= 2 else {
                throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
            }
            return MacTimelineAssetInfo(duration: 0, videoSize: nil, preferredTransform: nil,
                                        imageSize: CGSize(width: pixelWidth, height: pixelHeight),
                                        hasAudio: false)
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
            throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var dimensions = CGSize.zero
        var transform: CGAffineTransform? = nil
        if let firstVideo = videoTracks.first {
            dimensions = (try? await firstVideo.load(.naturalSize)) ?? .zero
            transform = try? await firstVideo.load(.preferredTransform)
        }
        guard videoTracks.isEmpty || (dimensions.width >= 2 && dimensions.height >= 2) else {
            throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
        }
        return MacTimelineAssetInfo(
            duration: duration,
            videoSize: videoTracks.isEmpty ? nil : CGSize(width: abs(dimensions.width), height: abs(dimensions.height)),
            preferredTransform: transform,
            imageSize: nil,
            hasAudio: !audioTracks.isEmpty)
    }
}

// MARK: - Composition build

struct MacTimelineBuild: @unchecked Sendable {
    // AVFoundation composition objects are thread-safe for the read-only
    // use the exporter makes of them; the session renders on its own queue.
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: Double
}

/// One visual layer inside a frame instruction.
struct MacTimelineVisualLayer: Sendable {
    /// Composition track carrying this clip's video; nil for still images
    /// (synthesized by the compositor).
    var sourceTrackID: CMPersistentTrackID?
    /// Still-image source; nil for movie layers.
    var imageURL: URL?
    /// Aspect-fill fit transform (includes the source preferredTransform).
    var transform: CGAffineTransform
    var grade: MacVideoGrade?
}

/// One caption cue occurrence inside a frame instruction.
struct MacTimelineCaptionCue: Sendable {
    var text: String
    /// 0 = bottom-most slot when cues stack.
    var stackIndex: Int
}

/// Video-composition instruction carrying the parity layer data. Subclasses
/// the mutable AVFoundation instruction so the system tiling code sees a
/// genuine `AVVideoCompositionInstruction`; source tracks are declared
/// through `layerInstructions` (an empty list makes the export pipeline
/// deliver only the first track's frames). The extra payload is carried
/// through `copy(with:)`/`mutableCopy(with:)` because the export pipeline
/// duplicates instructions before rendering.
final class MacTimelineFrameInstruction: AVMutableVideoCompositionInstruction, @unchecked Sendable {
    var renderSize: CGSize
    var layers: [MacTimelineVisualLayer]
    var captionCues: [MacTimelineCaptionCue]

    init(timeRange: CMTimeRange, sourceTracks: [AVAssetTrack],
         renderSize: CGSize, layers: [MacTimelineVisualLayer], captionCues: [MacTimelineCaptionCue]) {
        self.renderSize = renderSize
        self.layers = layers
        self.captionCues = captionCues
        super.init()
        self.timeRange = timeRange
        self.enablePostProcessing = false
        self.layerInstructions = sourceTracks.map {
            AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
        }
    }

    /// NSCoding conformance kept inert: the builder always creates
    /// instructions directly and never archives them.
    required init?(coder: NSCoder) {
        self.renderSize = .zero
        self.layers = []
        self.captionCues = []
        super.init(coder: coder)
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let typed = copy as? MacTimelineFrameInstruction {
            typed.renderSize = renderSize
            typed.layers = layers
            typed.captionCues = captionCues
        }
        return copy
    }

    override func mutableCopy(with zone: NSZone? = nil) -> Any {
        let copy = super.mutableCopy(with: zone)
        if let typed = copy as? MacTimelineFrameInstruction {
            typed.renderSize = renderSize
            typed.layers = layers
            typed.captionCues = captionCues
        }
        return copy
    }
}

enum MacTimelineCompositionBuilder {
    /// Builds the full playback/export plan. `assets` must contain a probed
    /// entry for every media URL on the draft; missing entries make the
    /// affected clips render silent/invisible rather than failing the whole
    /// build, except when no visual content remains.
    static func build(draft: MacTimelineDraft,
                      assets: [URL: MacTimelineAssetInfo]) async throws -> MacTimelineBuild {
        guard draft.hasRenderableVideo else { throw MacTimelineExportError.emptyTimeline }
        let duration = draft.totalDurationSeconds
        guard duration > 0, duration.isFinite else { throw MacTimelineExportError.emptyTimeline }

        let canvas = CGSize(width: draft.canvasWidth, height: draft.canvasHeight)
        let composition = AVMutableComposition()

        // One composition track per unmuted draft visual/audio track, in
        // stack order, so the compositor can stack frames deterministically.
        var videoTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var videoCompositionTracks: [UUID: AVMutableCompositionTrack] = [:]
        var layerData: [UUID: (transform: CGAffineTransform, isImage: Bool, url: URL?)] = [:]
        var insertedAnyVideo = false

        for track in draft.tracks where track.kind == .visual && !track.isMuted {
            // Lazily created on the first movie insert: an empty video
            // track breaks the export pipeline the same way an empty audio
            // track does, and image-only tracks never need one.
            var compositionTrack: AVMutableCompositionTrack? = nil
            for clip in track.clips where !clip.isMuted {
                guard let url = clip.sourceURL, let info = assets[url] else { continue }
                if info.isVisualMovie {
                    let asset = AVURLAsset(url: url)
                    let sourceTrack = try await asset.loadTracks(withMediaType: .video).first
                    guard let sourceTrack else {
                        throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
                    }
                    if compositionTrack == nil {
                        compositionTrack = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    guard let compositionTrack else {
                        throw MacTimelineExportError.exporterUnavailable
                    }
                    do {
                        try compositionTrack.insertTimeRange(
                            cmRange(clip.sourceRange), of: sourceTrack, at: cmTime(clip.timelineRange.start))
                    } catch {
                        throw MacTimelineExportError.exportFailed(error.localizedDescription)
                    }
                    let naturalSize = (try? await sourceTrack.load(.naturalSize)) ?? (info.videoSize ?? canvas)
                    // `??` takes an autoclosure, so the async load must live
                    // in its own statement.
                    let probedTransform = try? await sourceTrack.load(.preferredTransform)
                    let preferredTransform = info.preferredTransform ?? probedTransform ?? .identity
                    videoTrackIDs[clip.id] = compositionTrack.trackID
                    videoCompositionTracks[clip.id] = compositionTrack
                    layerData[clip.id] = (
                        fitTransform(source: naturalSize,
                                     preferredTransform: preferredTransform,
                                     canvas: canvas),
                        false, nil)
                    insertedAnyVideo = true
                } else if info.isStillImage {
                    layerData[clip.id] = (
                        fitTransform(source: info.imageSize ?? canvas, preferredTransform: nil, canvas: canvas),
                        true, url)
                    insertedAnyVideo = true
                }
            }
        }

        guard insertedAnyVideo else { throw MacTimelineExportError.emptyTimeline }

        // Audio: audio tracks, plus clip audio from unmuted visual clips.
        // Composition tracks are created lazily on the first successful
        // insert: an EMPTY audio track makes the export pipeline fail with
        // "operation not supported for this media" (OSStatus -16976), which
        // would break image-only or audio-less timelines.
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        for track in draft.tracks where track.kind != .caption && !track.isMuted && track.volume > 0 {
            var compositionTrack: AVMutableCompositionTrack?
            var inputParameters: AVMutableAudioMixInputParameters?
            for clip in track.clips where !clip.isMuted && clip.volume > 0 {
                guard let url = clip.sourceURL, assets[url]?.hasAudio == true else { continue }
                let asset = AVURLAsset(url: url)
                guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                if compositionTrack == nil {
                    compositionTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let compositionTrack else { break }
                let start = cmTime(clip.timelineRange.start)
                do {
                    try compositionTrack.insertTimeRange(cmRange(clip.sourceRange), of: sourceTrack, at: start)
                } catch {
                    continue
                }
                let parameters = inputParameters ?? AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(Float(track.volume * clip.volume), at: start)
                inputParameters = parameters
            }
            if let inputParameters {
                audioMixParams.append(inputParameters)
            } else if let compositionTrack {
                composition.removeTrack(compositionTrack)
            }
        }

        // Scene tiling: one instruction per maximal constant segment.
        var boundaries = Set<Double>([0, duration])
        for track in draft.tracks where !track.isMuted {
            for clip in track.clips where !clip.isMuted {
                boundaries.insert(clip.timelineRange.startSeconds)
                boundaries.insert(clip.timelineEnd)
            }
        }
        let points = boundaries.sorted()
        var instructions: [MacTimelineFrameInstruction] = []
        for (start, end) in zip(points, points.dropFirst()) where end - start > 0.000_1 {
            let mid = (start + end) / 2
            var layers: [MacTimelineVisualLayer] = []
            var sourceTracks: [AVAssetTrack] = []
            for track in draft.tracks where track.kind == .visual && !track.isMuted {
                guard let clip = track.clips.first(where: {
                    $0.timelineRange.startSeconds <= mid && mid < $0.timelineEnd
                }), let data = layerData[clip.id] else { continue }
                if let compositionTrack = videoCompositionTracks[clip.id],
                   !sourceTracks.contains(where: { $0.trackID == compositionTrack.trackID }) {
                    sourceTracks.append(compositionTrack)
                }
                layers.append(MacTimelineVisualLayer(
                    sourceTrackID: videoTrackIDs[clip.id],
                    imageURL: data.isImage ? data.url : nil,
                    transform: data.transform,
                    grade: clip.grade))
            }
            var cues: [MacTimelineCaptionCue] = []
            var stack = 0
            for track in draft.tracks where track.kind == .caption && !track.isMuted {
                for clip in track.clips {
                    guard !clip.isMuted, let text = clip.captionText,
                          clip.timelineRange.startSeconds <= mid, mid < clip.timelineEnd else { continue }
                    cues.append(.init(text: text, stackIndex: stack))
                    stack += 1
                }
            }
            instructions.append(MacTimelineFrameInstruction(
                timeRange: CMTimeRange(start: cmTime(try .seconds(start)),
                                       duration: cmTime(try .seconds(end - start))),
                sourceTracks: sourceTracks, renderSize: canvas, layers: layers, captionCues: cues))
        }
        guard !instructions.isEmpty else { throw MacTimelineExportError.emptyTimeline }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MacTimelineCompositor.self
        videoComposition.frameDuration = frameDuration(rate: draft.frameRate)
        videoComposition.renderSize = canvas
        videoComposition.instructions = instructions

        let audioMix = audioMixParams.isEmpty ? nil : AVMutableAudioMix()
        audioMix?.inputParameters = audioMixParams

        return MacTimelineBuild(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: audioMix,
                                duration: duration)
    }

    /// Maps the source pixel rectangle into the canvas with aspect fill,
    /// applying the track preferredTransform first (when present) so rotated
    /// video lands upright, then center-cropping.
    static func fitTransform(source: CGSize, preferredTransform: CGAffineTransform?, canvas: CGSize) -> CGAffineTransform {
        let basis = preferredTransform ?? .identity
        let sourceRect = CGRect(origin: .zero, size: source)
        let displayRect = sourceRect.applying(basis)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let scale = max(canvas.width / max(displaySize.width, 1), canvas.height / max(displaySize.height, 1))
        let dx = (canvas.width - displaySize.width * scale) / 2
        let dy = (canvas.height - displaySize.height * scale) / 2
        // p_canvas = T(offset) * S(scale) * T(-displayRect.origin) * basis * p_raw
        // `concatenating` applies the receiver before its argument, so the
        // chain starts with the basis and ends with the canvas offset.
        return basis
            .concatenating(CGAffineTransform(translationX: -displayRect.origin.x, y: -displayRect.origin.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    private static func cmTime(_ time: MacRationalTime) -> CMTime {
        CMTime(value: time.value, timescale: time.timescale)
    }

    private static func cmRange(_ range: MacTimeRange) -> CMTimeRange {
        CMTimeRange(start: cmTime(range.start), duration: cmTime(range.duration))
    }

    private static func frameDuration(rate: Double) -> CMTime {
        let scaled = max(1, Int((rate * 1000).rounded()))
        return CMTime(value: 1000, timescale: Int32(scaled))
    }
}

// MARK: - Custom compositor

/// Renders timeline frames: source video frames (aspect-filled, graded),
/// still-image clips and burned-in caption cues, stacked in draft track
/// order. Follows the exact SDK contract of the shipping iPad
/// `WorkbenchVideoCompositor`: frames come from
/// `sourceFrame(byTrackID:)`, output comes from
/// `renderContext.newPixelBuffer()`, and caches are thread-safe value types
/// behind a `@unchecked Sendable` class.
final class MacTimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var renderContext: AVVideoCompositionRenderContext?
    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var supportsWideColorSourceFrames = true
    var canConformColorOfSourceFrames = true

    private let context = CIContext()
    private let imageCache = NSCache<NSURL, CIImage>()
    private let captionCache = NSCache<NSString, CIImage>()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? MacTimelineFrameInstruction,
              let output = renderContext?.newPixelBuffer() else {
            request.finish(with: MacTimelineExportError.exportFailed("compositor unavailable"))
            return
        }
        let size = instruction.renderSize
        var canvas = CIImage(color: CIColor.black)
            .cropped(to: CGRect(origin: .zero, size: size))
        for layer in instruction.layers {
            guard var image = frameImage(for: layer, request: request) else { continue }
            image = image.transformed(by: layer.transform)
            if let grade = layer.grade, let graded = try? grade.apply(to: image) {
                image = graded
            }
            canvas = image.composited(over: canvas)
        }
        canvas = overlayCaptions(captionCues: instruction.captionCues, canvas: canvas, size: size)
        context.render(canvas, to: output)
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Frame requests are rendered synchronously; nothing is queued.
    }

    private func frameImage(for layer: MacTimelineVisualLayer,
                            request: AVAsynchronousVideoCompositionRequest) -> CIImage? {
        if let trackID = layer.sourceTrackID {
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            return CIImage(cvPixelBuffer: buffer)
        }
        guard let url = layer.imageURL else { return nil }
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = CIImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    private func overlayCaptions(captionCues: [MacTimelineCaptionCue],
                                 canvas: CIImage, size: CGSize) -> CIImage {
        guard !captionCues.isEmpty else { return canvas }
        var result = canvas
        let ordered = captionCues.sorted { $0.stackIndex < $1.stackIndex }
        for cue in ordered {
            guard let strip = Self.captionImage(text: cue.text, canvas: size, cache: captionCache) else { continue }
            let marginX = size.width * 0.05
            let bottomMargin = size.height * 0.06
            let gap = size.height * 0.015
            let y = bottomMargin + CGFloat(cue.stackIndex) * (strip.extent.height + gap)
            let x = marginX + (size.width - 2 * marginX - strip.extent.width) / 2
            result = strip.transformed(by: CGAffineTransform(translationX: x, y: y))
                .composited(over: result)
        }
        return result
    }

    /// Renders one cue into a tightly-sized strip (white text, dark outline),
    /// cached per text and canvas size.
    static func captionImage(text: String, canvas: CGSize, cache: NSCache<NSString, CIImage>) -> CIImage? {
        let key = "\(text)|\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let fontSize = max(10, canvas.height / 16)
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -(fontSize / 12),
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let maxWidth = canvas.width * 0.9
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = max(2, Int((bounds.width + fontSize * 0.6).rounded()))
        let height = max(2, Int((bounds.height + fontSize * 0.35).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attributed.draw(in: CGRect(x: fontSize * 0.3, y: fontSize * 0.175,
                                   width: bounds.width, height: bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Export

final class MacTimelineExporter: @unchecked Sendable {
    nonisolated static let maximumOutputBytes = MacVideoEditExporter.maximumOutputBytes

    /// Renders the draft to `destination` (mp4). Progress is reported on a
    /// background thread; cancellation stops the export and removes staging.
    func export(draft: MacTimelineDraft,
                assets: [URL: MacTimelineAssetInfo],
                to destination: URL,
                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let build = try await MacTimelineCompositionBuilder.build(draft: draft, assets: assets)
        let asset = build.composition
        let preset = await Self.preset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MacTimelineExportError.exporterUnavailable
        }
        session.videoComposition = build.videoComposition
        if let audioMix = build.audioMix { session.audioMix = audioMix }
        session.fileLengthLimit = Int64(Self.maximumOutputBytes)

        let staging = MacMediaEditCommit.stagingURL(near: destination, pathExtension: "mp4")
        let states = session.states(updateInterval: 0.2)
        let progressTask = Task { @Sendable in
            for await state in states {
                if case .exporting(let value) = state {
                    progress?(value.fractionCompleted)
                }
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await session.export(to: staging, as: .mp4)
            } onCancel: {}
            progressTask.cancel()
            try await MacMediaEditCommit.commitFile(at: staging, to: destination) { url in
                await Self.verify(url, expectedDuration: build.duration)
            }
        } catch is CancellationError {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: staging)
            throw MacTimelineExportError.cancelled
        } catch let error as MacTimelineExportError {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: staging)
            throw MacTimelineExportError.exportFailed(error.localizedDescription)
        }
    }

    /// Read-back verification: the committed file must open as a movie whose
    /// playable duration matches the built timeline within a frame.
    static func verify(_ url: URL, expectedDuration: Double) async -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumOutputBytes else { return false }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return false }
        return abs(duration - expectedDuration) < 0.35
    }

    private static func preset(for asset: AVAsset) async -> String {
        // Passthrough cannot carry a custom video composition; use the
        // highest compatible re-encode instead.
        let candidates = [
            AVAssetExportPresetHighestQuality,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPreset640x480,
        ]
        for candidate in candidates {
            if await AVAssetExportSession.compatibility(ofExportPreset: candidate, with: asset, outputFileType: .mp4) {
                return candidate
            }
        }
        return AVAssetExportPresetMediumQuality
    }
}

// MARK: - Bilingual strings

enum MacTimelineExportStrings {
    static var emptyTimeline: String {
        t(en: "The timeline has no visible frames to export. Add a video or image clip and make it visible.",
           zh: "时间线还没有可导出的画面。请先加入并显示视频或图片片段。")
    }
    static var unsupportedSourceFormat: String {
        t(en: "%@ is not a supported media file.", zh: "%@ 不是受支持的媒体文件。")
    }
    static var exporterUnavailable: String { t(en: "The video exporter is unavailable.", zh: "视频导出器不可用。") }
    static var exportFailedFormat: String { t(en: "Export failed: %@.", zh: "导出失败：%@。") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
