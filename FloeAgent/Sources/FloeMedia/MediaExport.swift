import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
/// Export-oriented media tools. Every parameter is explicit; there are no
/// default codecs, resolutions or bitrates.
public actor MediaExportEngine {
    private let rootProvider: @Sendable () -> URL?

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
    }

    public struct TranscodeSpec: Sendable {
        public var input: String
        public var output: String
        public var container: String
        public var videoCodec: String?
        public var audioCodec: String?
        public var width: Int?
        public var height: Int?
        public var frameRate: Double?
        public var videoBitrate: Int?
        public var audioBitrate: Int?
        public var passthrough: Bool
    }

    public func transcode(_ spec: TranscodeSpec, cancellation: CancellationToken? = nil) async throws -> String {
        try await MediaTranscodePipeline.run(spec, input: resolve(spec.input), output: resolveOutput(spec.output), cancellation: cancellation)
    }

    public func thumbnail(input: String, timeSeconds: Double, output: String, maximumDimension: Int) async throws -> String {
        let inputURL = try resolve(input)
        let outputURL = try resolveOutput(output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: inputURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        let image = try await generator.image(at: CMTime(seconds: timeSeconds, preferredTimescale: 600)).image
        guard let data = MediaImageEncoding.png(image) else { throw FloeError.internalError("could not encode thumbnail") }
        try data.write(to: outputURL, options: .atomic)
        return "status=ok output=\(output) timeSeconds=\(timeSeconds) maxDimension=\(maximumDimension)"
    }

    private func fileType(for container: String) -> AVFileType {
        switch container.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        case "caf": return .caf
        case "wav": return .wav
        case "aiff", "aif": return .aiff
        default: return .mp4
        }
    }

    func resolve(_ path: String) throws -> URL {
        let url = try resolveOutput(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
        return url
    }

    func resolveOutput(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), let root = rootProvider() else {
            throw FloeError.validationFailed("A workspace and valid media path are required")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonicalRoot.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FloeError.validationFailed("Media path escapes the workspace")
        }
        return candidate
    }

}
#endif

public struct VideoTranscodeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var container: String
        public var videoCodec: String?
        public var audioCodec: String?
        public var width: Int?
        public var height: Int?
        public var frameRate: Double?
        public var videoBitrate: Int?
        public var audioBitrate: Int?
        public var remuxOnly: Bool?
    }

    public static let name = "video.transcode"
    public static let toolDescription =
        "Transcode or remux a video with explicit parameters: container (mp4, mov, m4v, caf, wav), optional codecs, dimensions, frame rate and bitrates. Set remuxOnly=true to copy streams without re-encoding when the container allows it. No parameters are defaulted; unsupported requests fail with the container/codec the device rejected."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"container":{"type":"string"},"videoCodec":{"type":"string"},"audioCodec":{"type":"string"},"width":{"type":"integer"},"height":{"type":"integer"},"frameRate":{"type":"number"},"videoBitrate":{"type":"integer"},"audioBitrate":{"type":"integer"},"remuxOnly":{"type":"boolean"}},"required":["input","output","container"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.input.isEmpty, !args.output.isEmpty, !args.container.isEmpty else {
            throw FloeError.validationFailed("input, output and container are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = MediaExportEngine(rootProvider: { context.workspaceRootURL })
        let result = try await engine.transcode(.init(
            input: args.input,
            output: args.output,
            container: args.container,
            videoCodec: args.videoCodec,
            audioCodec: args.audioCodec,
            width: args.width,
            height: args.height,
            frameRate: args.frameRate,
            videoBitrate: args.videoBitrate,
            audioBitrate: args.audioBitrate,
            passthrough: args.remuxOnly ?? false
        ), cancellation: context.cancellation)
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("video processing is unavailable on this platform")
        #endif
    }
}

public struct VideoThumbnailTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var timeSeconds: Double
        public var output: String
        public var maximumDimension: Int
    }

    public static let name = "video.thumbnail"
    public static let toolDescription =
        "Render one frame at an explicit timestamp to a PNG file. timeSeconds and maximumDimension are required; use video.extractFrames for multiple frames."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"timeSeconds":{"type":"number"},"output":{"type":"string"},"maximumDimension":{"type":"integer","minimum":16,"maximum":8192}},"required":["input","timeSeconds","output","maximumDimension"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard args.timeSeconds >= 0 else { throw FloeError.validationFailed("timeSeconds must be >= 0") }
        guard args.maximumDimension > 0 else { throw FloeError.validationFailed("maximumDimension must be positive") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = MediaExportEngine(rootProvider: { context.workspaceRootURL })
        let result = try await engine.thumbnail(
            input: args.input,
            timeSeconds: args.timeSeconds,
            output: args.output,
            maximumDimension: args.maximumDimension
        )
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("video processing is unavailable on this platform")
        #endif
    }
}

public struct AudioConvertTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var container: String
        public var sampleRate: Double?
        public var channels: Int?
        public var bitRate: Int?
    }

    public static let name = "audio.convert"
    public static let toolDescription =
        "Convert audio with explicit output container and optional sample rate, channel count and bit rate. Conversion re-encodes; for stream copy use video.transcode with remuxOnly."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"container":{"type":"string"},"sampleRate":{"type":"number"},"channels":{"type":"integer"},"bitRate":{"type":"integer"}},"required":["input","output","container"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.input.isEmpty, !args.output.isEmpty, !args.container.isEmpty else {
            throw FloeError.validationFailed("input, output and container are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = MediaExportEngine(rootProvider: { context.workspaceRootURL })
        let result = try await engine.convertAudio(input: args.input, output: args.output, container: args.container,
            sampleRate: args.sampleRate, channels: args.channels, bitRate: args.bitRate, cancellation: context.cancellation)
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}
