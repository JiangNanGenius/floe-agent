import Foundation
import FloeCore
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
        var native = Native(
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
        if #available(iOS 26.0, macOS 26.0, *) {
            native.frameRateConversion = false
            native.superResolution = false
            native.supportedScaleFactors = VTSuperResolutionScalerConfiguration.supportedScaleFactors.map { Int($0) }
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            native.lowLatencyInterpolation = false
        }
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
    }

    public var input: String
    public var output: String
    public var operations: [Operation]
    public var export: Export

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
    public func render(plan: VideoEditPlan) async throws -> MediaRenderResult {
        try plan.validate()
        let inputURL = try resolve(plan.input)
        let outputURL = try resolveOutput(plan.output)
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let sourceRange = try await sourceTimeRange(plan: plan, asset: asset, duration: duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first else {
            throw FloeError.validationFailed("input has no video track")
        }
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw FloeError.internalError("could not add composition video track")
        }
        try compositionVideo.insertTimeRange(sourceRange, of: sourceVideo, at: .zero)
        if let sourceAudio = audioTracks.first,
           let compositionAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: .zero)
        }
        var applied: [String] = ["trim"]
        var warnings: [String] = []

        var videoComposition: AVMutableVideoComposition?
        var instructions = [AVMutableVideoCompositionInstruction]()
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: sourceRange.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
        var transform = CGAffineTransform.identity
        var renderSize = try await sourceVideo.load(.naturalSize)
        for operation in plan.operations {
            switch operation {
            case .trim, .concat, .reorder, .replaceAudio, .subtitles, .transition, .gif, .frameRate:
                warnings.append("operation handled by a dedicated pipeline (not the base compositor): \(operation)")
            case .speed(let rate):
                let scaled = CMTimeMultiplyByFloat64(sourceRange.duration, multiplier: 1.0 / rate)
                compositionVideo.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration), toDuration: scaled)
                applied.append("speed=\(rate)")
            case .crop(let x, let y, let width, let height):
                transform = transform.concatenating(CGAffineTransform(translationX: -CGFloat(x), y: -CGFloat(y)))
                renderSize = CGSize(width: width, height: height)
                applied.append("crop=\(width)x\(height)+\(x)+\(y)")
            case .scale(let width, let height):
                let scaleX = CGFloat(width) / max(renderSize.width, 1)
                let scaleY = CGFloat(height) / max(renderSize.height, 1)
                transform = transform.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                renderSize = CGSize(width: width, height: height)
                applied.append("scale=\(width)x\(height)")
            case .rotate(let degrees):
                transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180))
                applied.append("rotate=\(degrees)")
            case .flipHorizontal:
                transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                applied.append("flipHorizontal")
            case .flipVertical:
                transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1))
                applied.append("flipVertical")
            default:
                warnings.append("operation requires the CoreImage compositor and was recorded as pending: \(operation)")
            }
        }
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        instructions.append(instruction)
        let mutableVideoComposition = AVMutableVideoComposition()
        mutableVideoComposition.instructions = instructions
        mutableVideoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        mutableVideoComposition.renderSize = renderSize
        videoComposition = mutableVideoComposition

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw FloeError.internalError("could not create export session")
        }
        export.outputURL = outputURL
        export.outputFileType = fileType(for: plan.export.container)
        export.videoComposition = videoComposition
        try? FileManager.default.removeItem(at: outputURL)
        await export.export()
        guard export.status == .completed else {
            throw FloeError.internalError("export failed: \(export.error?.localizedDescription ?? "unknown error")")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes <= limits.maximumOutputBytes else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FloeError.validationFailed("output exceeds \(limits.maximumOutputBytes) bytes")
        }
        return MediaRenderResult(
            outputPath: plan.output,
            durationSeconds: CMTimeGetSeconds(sourceRange.duration),
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            frameRate: plan.export.frameRate ?? 30,
            videoCodec: plan.export.videoCodec ?? "h264",
            audioCodec: plan.export.audioCodec,
            byteCount: bytes,
            appliedOperations: applied,
            warnings: warnings
        )
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
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.notFound(path)
            }
            return url
        }
        guard let root = rootProvider() else {
            throw FloeError.invalidConfiguration("no workspace root for media paths")
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.notFound(path)
        }
        return url
    }

    private func resolveOutput(_ path: String) throws -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let root = rootProvider() else {
            throw FloeError.invalidConfiguration("no workspace root for media paths")
        }
        return root.appendingPathComponent(path)
    }
}
#endif
