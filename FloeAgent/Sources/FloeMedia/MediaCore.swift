import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import VideoToolbox
import CoreImage
#endif

/// Probed media capabilities. The model reads this instead of relying on
/// presets; nothing here is a default, only what this device can do.
public struct MediaCapabilities: Sendable, Codable {
    public struct Native: Sendable, Codable {
        public var frameRateConversion: Bool
        public var lowLatencyInterpolation: Bool
        public var superResolution: Bool
        public var lowLatencySuperResolution: Bool
        public var opticalFlow: Bool
        public var temporalNoiseFilter: Bool
        public var motionBlur: Bool
        public var metalFXFrameInterpolator: Bool
        public var hardwareEncodeH264: Bool
        public var hardwareEncodeHEVC: Bool
        public var hardwareDecodeAV1: Bool
        public var personSegmentation: Bool
        public var supportedScaleFactors: [Int]
        public var maximumDimension: Int
    }

    public struct Model: Sendable, Codable {
        public var id: String
        public var capability: String
        public var installed: Bool
        public var kind: String
        public var license: String?
        public var runnable: Bool
        public var unavailableReason: String?

        public init(id: String, capability: String, installed: Bool, kind: String, license: String?,
                    runnable: Bool = false, unavailableReason: String? = "Model inference runner has not been qualified") {
            self.id = id
            self.capability = capability
            self.installed = installed
            self.kind = kind
            self.license = license
            self.runnable = runnable
            self.unavailableReason = unavailableReason
        }
    }

    public var osVersion: String
    public var appBuild: String
    public var native: Native
    public var installedModels: [Model]
    public var availableModels: [Model]
    public var containers: [String]
    public var notes: [String]

    #if canImport(AVFoundation)
    private static func supportsHardwareEncoding(_ codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64,
            codecType: codec, encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }
    #endif

    public static func probe(appBuild: String) -> MediaCapabilities {
        #if canImport(AVFoundation)
        let native = Native(
            frameRateConversion: false,
            lowLatencyInterpolation: false,
            superResolution: false,
            lowLatencySuperResolution: false,
            opticalFlow: false,
            temporalNoiseFilter: false,
            motionBlur: false,
            metalFXFrameInterpolator: false,
            hardwareEncodeH264: supportsHardwareEncoding(kCMVideoCodecType_H264),
            hardwareEncodeHEVC: supportsHardwareEncoding(kCMVideoCodecType_HEVC),
            hardwareDecodeAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            personSegmentation: false,
            supportedScaleFactors: [],
            maximumDimension: 0
        )
        return MediaCapabilities(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appBuild: appBuild,
            native: native,
            installedModels: [],
            availableModels: [],
            containers: [],
            notes: ["Parameters are never defaulted; read this capability report and pass explicit values."]
        )
        #else
        return MediaCapabilities(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appBuild: appBuild,
            native: Native(
                frameRateConversion: false, lowLatencyInterpolation: false,
                superResolution: false, lowLatencySuperResolution: false,
                opticalFlow: false, temporalNoiseFilter: false, motionBlur: false,
                metalFXFrameInterpolator: false, hardwareEncodeH264: false,
                hardwareEncodeHEVC: false, hardwareDecodeAV1: false,
                personSegmentation: false, supportedScaleFactors: [], maximumDimension: 0
            ),
            installedModels: [],
            availableModels: [],
            containers: [],
            notes: ["AVFoundation is unavailable on this platform."]
        )
        #endif
    }
}

/// Non-destructive edit plan. Every operation carries explicit parameters;
/// the renderer validates them and reports exactly what it applied.
public struct VideoEditPlan: Sendable, Codable {
    public enum Operation: Sendable, Codable {
        case trim(start: Double, end: Double)
        case concat(paths: [String])
        case reorder(indices: [Int])
        case speed(rate: Double)
        case crop(x: Int, y: Int, width: Int, height: Int)
        case scale(width: Int, height: Int)
        case rotate(degrees: Double)
        case flipHorizontal
        case flipVertical
        case color(brightness: Double?, contrast: Double?, saturation: Double?, warmth: Double?)
        case volume(level: Double)
        case fadeAudioIn(seconds: Double)
        case fadeAudioOut(seconds: Double)
        case mute
        case replaceAudio(path: String)
        case overlayImage(path: String, x: Double, y: Double, width: Double, height: Double)
        case overlayText(text: String, x: Double, y: Double, fontSize: Double, colorHex: String)
        case watermark(path: String, corner: String, width: Double)
        case transition(kind: String, seconds: Double)
        case subtitles(path: String, burnIn: Bool)
        case gif(fps: Int, width: Int)
        case frameRate(fps: Double)
    }

    public struct Export: Sendable, Codable {
        public var container: String
        public var videoCodec: String?
        public var audioCodec: String?
        public var videoBitrate: Int?
        public var audioBitrate: Int?
        public var width: Int?
        public var height: Int?
        public var frameRate: Double?
        public var quality: Double?
        public var range: [Double]?
        public var hardwareAcceleration: Bool?

        public init(container: String, videoCodec: String? = nil, audioCodec: String? = nil,
                    videoBitrate: Int? = nil, audioBitrate: Int? = nil, width: Int? = nil,
                    height: Int? = nil, frameRate: Double? = nil, quality: Double? = nil,
                    range: [Double]? = nil, hardwareAcceleration: Bool? = nil) {
            self.container = container
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.quality = quality
            self.range = range
            self.hardwareAcceleration = hardwareAcceleration
        }
    }

    public var input: String
    public var output: String
    public var operations: [Operation]
    public var export: Export

    public init(input: String, output: String, operations: [Operation], export: Export) {
        self.input = input
        self.output = output
        self.operations = operations
        self.export = export
    }

    public func validate() throws {
        guard !input.isEmpty, !output.isEmpty else {
            throw FloeError.validationFailed("input and output are required")
        }
        for operation in operations {
            switch operation {
            case .trim(let start, let end):
                guard start >= 0, end > start else { throw FloeError.validationFailed("trim requires 0 <= start < end") }
            case .speed(let rate):
                guard rate > 0.1, rate < 16 else { throw FloeError.validationFailed("speed rate must be within 0.1...16") }
            case .crop(_, _, let width, let height):
                guard width > 0, height > 0 else { throw FloeError.validationFailed("crop requires positive dimensions") }
            case .scale(let width, let height):
                guard width > 0, height > 0 else { throw FloeError.validationFailed("scale requires positive dimensions") }
            case .volume(let level):
                guard level >= 0, level <= 4 else { throw FloeError.validationFailed("volume must be within 0...4") }
            case .fadeAudioIn(let seconds), .fadeAudioOut(let seconds):
                guard seconds > 0 else { throw FloeError.validationFailed("fade duration must be positive") }
            case .gif(let fps, let width):
                guard fps > 0, width > 0 else { throw FloeError.validationFailed("gif requires positive fps and width") }
            case .frameRate(let fps):
                guard fps > 0, fps <= 240 else { throw FloeError.validationFailed("frameRate must be within 0...240") }
            case .reorder(let indices):
                guard !indices.isEmpty else { throw FloeError.validationFailed("reorder requires at least one index") }
            default:
                break
            }
        }
    }
}

/// Result of a render, including the effective parameters (never silent).
public struct MediaRenderResult: Sendable {
    public var outputPath: String
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoCodec: String
    public var audioCodec: String?
    public var byteCount: Int64
    public var appliedOperations: [String]
    public var warnings: [String]
}

#if canImport(AVFoundation)
/// AVFoundation-based renderer. Applies the plan as a composition; heavy
/// frame processing (interpolation/super-resolution) is composed through
/// `FrameProcessorPipeline`.
public actor MediaRenderer {
    public struct Limits: Sendable {
        public var maximumDurationSeconds: Double
        public var maximumPixels: Int
        public var maximumOutputBytes: Int64

        public init(maximumDurationSeconds: Double = 2 * 3600, maximumPixels: Int = 3840 * 2160, maximumOutputBytes: Int64 = 8 * 1024 * 1024 * 1024) {
            self.maximumDurationSeconds = maximumDurationSeconds
            self.maximumPixels = maximumPixels
            self.maximumOutputBytes = maximumOutputBytes
        }
    }

    private let limits: Limits
    private let rootProvider: @Sendable () -> URL?

    public init(limits: Limits = Limits(), rootProvider: @escaping @Sendable () -> URL?) {
        self.limits = limits
        self.rootProvider = rootProvider
    }

    /// Inspects a media file: container, tracks, duration, dimensions.
    public func inspect(path: String) async throws -> [String: String] {
        let url = try resolve(path)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        var lines: [String: String] = [
            "path": path,
            "durationSeconds": String(format: "%.3f", CMTimeGetSeconds(duration))
        ]
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let video = videoTracks.first {
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let transformed = size.applying(transform)
            let frameRate = try await video.load(.nominalFrameRate)
            lines["videoWidth"] = String(Int(abs(transformed.width)))
            lines["videoHeight"] = String(Int(abs(transformed.height)))
            lines["videoFrameRate"] = String(format: "%.3f", frameRate)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        lines["audioTrackCount"] = String(audioTracks.count)
        return lines
    }

    /// Renders a plan to the output path. Throws when an operation cannot be
    /// honored; never falls back silently.
    public func render(plan: VideoEditPlan, cancellation: CancellationToken? = nil) async throws -> MediaRenderResult {
        try plan.validate()
        try cancellation?.throwIfCancelled()
        guard plan.export.quality == nil, plan.export.range == nil, plan.export.hardwareAcceleration == nil else {
            throw FloeError.validationFailed("quality, export range and forced hardware selection are not supported")
        }
        guard ["mp4", "mov", "m4v"].contains(plan.export.container.lowercased()),
              [nil, "h264", "hevc"].contains(plan.export.videoCodec?.lowercased()),
              [nil, "aac"].contains(plan.export.audioCodec?.lowercased()),
              (plan.export.width == nil) == (plan.export.height == nil) else {
            throw FloeError.validationFailed("Unsupported export format or incomplete dimensions")
        }
        if let fps = plan.export.frameRate, !fps.isFinite || fps <= 0 || fps > 240 {
            throw FloeError.validationFailed("Frame rate must be finite and in (0, 240]")
        }
        for value in [plan.export.width, plan.export.height, plan.export.videoBitrate, plan.export.audioBitrate].compactMap({ $0 }) {
            guard value > 0 else { throw FloeError.validationFailed("Dimensions and bitrates must be positive") }
        }
        if let width = plan.export.width, let height = plan.export.height {
            guard width <= 8192, height <= 8192, width % 2 == 0, height % 2 == 0,
                  width * height <= limits.maximumPixels else { throw FloeError.validationFailed("Export dimensions exceed limits") }
        }
        var trims = 0
        var rate = 1.0
        var volume: Float = 1
        var muted = false
        var fadeIn: Double?
        var fadeOut: Double?
        for operation in plan.operations {
            switch operation {
            case .trim: trims += 1
            case .speed(let value): rate *= value
            case .volume(let value): volume *= Float(value)
            case .mute: muted = true
            case .fadeAudioIn(let seconds): fadeIn = seconds
            case .fadeAudioOut(let seconds): fadeOut = seconds
            default: throw FloeError.validationFailed("This edit operation has no connected renderer: \(operation)")
            }
        }
        guard trims <= 1, rate.isFinite, rate > 0, volume.isFinite, volume <= 4 else {
            throw FloeError.validationFailed("Use one source trim and finite speed/volume parameters")
        }
        let inputURL = try resolve(plan.input)
        let outputURL = try resolveOutput(plan.output)
        guard inputURL != outputURL else { throw FloeError.validationFailed("Choose a separate output file") }
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let sourceRange = try await sourceTimeRange(plan: plan, asset: asset, duration: duration)
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FloeError.validationFailed("Input has no usable video track")
        }
        try video.insertTimeRange(sourceRange, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var audio: AVMutableCompositionTrack?
        if !muted, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FloeError.internalError("Could not create audio composition track")
            }
            try track.insertTimeRange(sourceRange, of: sourceAudio, at: .zero)
            audio = track
        }
        let renderedDuration = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1 / rate)
        guard renderedDuration.seconds.isFinite, renderedDuration.seconds <= limits.maximumDurationSeconds else {
            throw FloeError.validationFailed("Rendered duration exceeds the limit")
        }
        // Scale the composition, not only video, so audio keeps the same timeline.
        if rate != 1 { composition.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration), toDuration: renderedDuration) }
        let fadeInSeconds = fadeIn ?? 0
        let fadeOutSeconds = fadeOut ?? 0
        guard fadeInSeconds + fadeOutSeconds <= renderedDuration.seconds else {
            throw FloeError.validationFailed("Audio fades overlap or exceed the output duration")
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw FloeError.internalError("Could not create composition export")
        }
        if let audio {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.setVolume(volume, at: .zero)
            if fadeInSeconds > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                    timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeInSeconds, preferredTimescale: 600)))
            }
            if fadeOutSeconds > 0 {
                parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                    timeRange: CMTimeRange(start: CMTime(seconds: renderedDuration.seconds - fadeOutSeconds, preferredTimescale: 600),
                                          duration: CMTime(seconds: fadeOutSeconds, preferredTimescale: 600)))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            exporter.audioMix = mix
        }
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let intermediate = directory.appendingPathComponent(".floe-edit-\(UUID().uuidString).mov")
        let stagedOutput = directory.appendingPathComponent(".floe-edited-\(UUID().uuidString).\(plan.export.container)")
        defer {
            try? FileManager.default.removeItem(at: intermediate)
            try? FileManager.default.removeItem(at: stagedOutput)
        }
        // Transfer the exporter to one task. Cancellation crosses only the
        // Sendable Task handle, never the non-Sendable AVFoundation object.
        let compositionExport = Task { try await self.exportComposition(exporter, to: intermediate) }
        let cancellationWatcher = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true { compositionExport.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { cancellationWatcher.cancel() }
        try await withTaskCancellationHandler {
            try await compositionExport.value
        } onCancel: { compositionExport.cancel() }
        cancellationWatcher.cancel()
        try cancellation?.throwIfCancelled()
        _ = try await MediaTranscodePipeline.run(.init(input: intermediate.path, output: stagedOutput.path,
            container: plan.export.container, videoCodec: plan.export.videoCodec, audioCodec: plan.export.audioCodec,
            width: plan.export.width, height: plan.export.height, frameRate: plan.export.frameRate,
            videoBitrate: plan.export.videoBitrate, audioBitrate: plan.export.audioBitrate, passthrough: false),
            input: intermediate, output: stagedOutput, cancellation: cancellation)
        let exported = AVURLAsset(url: stagedOutput)
        guard let track = try await exported.loadTracks(withMediaType: .video).first else {
            throw FloeError.validationFailed("Edited output has no video track")
        }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let actualDuration = try await exported.load(.duration).seconds
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedOutput.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0, bytes <= limits.maximumOutputBytes,
              size.width * size.height <= Double(limits.maximumPixels),
              abs(actualDuration - renderedDuration.seconds) <= max(0.2, 2 / Double(fps)) else {
            throw FloeError.validationFailed("Edited output exceeds limits or has an unexpected duration")
        }
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagedOutput)
        } else { try FileManager.default.moveItem(at: stagedOutput, to: outputURL) }
        return MediaRenderResult(outputPath: plan.output, durationSeconds: actualDuration,
            width: Int(size.width), height: Int(size.height), frameRate: Double(fps),
            videoCodec: plan.export.videoCodec ?? "h264", audioCodec: audio == nil ? nil : "aac",
            byteCount: bytes, appliedOperations: plan.operations.map { String(describing: $0) }, warnings: [])
    }

    private func exportComposition(_ exporter: AVAssetExportSession, to url: URL) async throws {
        try await exporter.export(to: url, as: .mov)
    }

    /// Extracts frames at explicit timestamps (seconds), writing image files.
    public func extractFrames(
        path: String,
        timestamps: [Double],
        outputDirectory: String,
        format: String,
        maximumFrames: Int
    ) async throws -> [String] {
        guard timestamps.count <= maximumFrames else {
            throw FloeError.validationFailed("frame request exceeds maximumFrames=\(maximumFrames)")
        }
        let url = try resolve(path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let directory = try resolveOutput(outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for timestamp in timestamps.sorted() {
            let time = CMTime(seconds: timestamp, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
                guard let data = MediaImageEncoding.png(image) else { continue }
            let name = String(format: "frame-%010.3f.\(format)", timestamp)
            let destination = directory.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            written.append(destination.path)
        }
        return written
    }

    private func sourceTimeRange(plan: VideoEditPlan, asset: AVURLAsset, duration: CMTime) async throws -> CMTimeRange {
        var start = 0.0
        var end = CMTimeGetSeconds(duration)
        for operation in plan.operations {
            if case .trim(let from, let to) = operation {
                start = from
                end = to
            }
        }
        guard start < end, end <= CMTimeGetSeconds(duration) + 0.001 else {
            throw FloeError.validationFailed("trim range exceeds source duration")
        }
        if end - start > limits.maximumDurationSeconds {
            throw FloeError.validationFailed("trimmed duration exceeds limit \(limits.maximumDurationSeconds)s")
        }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
    }

    private func fileType(for container: String) -> AVFileType {
        switch container.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        case "caf": return .caf
        case "wav": return .wav
        default: return .mp4
        }
    }

    private func resolve(_ path: String) throws -> URL {
        let url = try resolveOutput(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
        return url
    }

    private func resolveOutput(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), let root = rootProvider() else {
            throw FloeError.validationFailed("A workspace and valid media path are required")
        }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonical.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/") else { throw FloeError.validationFailed("Media path escapes workspace") }
        return url
    }
}
#endif
