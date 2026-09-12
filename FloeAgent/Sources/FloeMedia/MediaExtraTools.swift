import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
#endif

/// `video.remux`: container change with stream copy. Kept separate from
/// video.transcode so the intent is explicit and auditable.
public struct VideoRemuxTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var container: String
    }

    public static let name = "video.remux"
    public static let toolDescription =
        "Copy streams into a different container without re-encoding (mp4, mov, m4v). Fails when the target container cannot carry the source codecs; no parameters are defaulted."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"container":{"type":"string"}},"required":["input","output","container"],"additionalProperties":false}"#
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
            videoCodec: nil,
            audioCodec: nil,
            width: nil,
            height: nil,
            frameRate: nil,
            videoBitrate: nil,
            audioBitrate: nil,
            passthrough: true
        ), cancellation: context.cancellation)
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("video processing is unavailable on this platform")
        #endif
    }
}

/// `video.proxy`: explicit low-resolution preview render for the editor.
public struct VideoProxyTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var maximumDimension: Int
        public var container: String
    }

    public static let name = "video.proxy"
    public static let toolDescription =
        "Render a preview-quality proxy of a video with an explicit maximum dimension and container. Proxies are editing aids; never present one as the final output."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"maximumDimension":{"type":"integer","minimum":16,"maximum":4096},"container":{"type":"string"}},"required":["input","output","maximumDimension","container"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard (16...4096).contains(args.maximumDimension) else { throw FloeError.validationFailed("maximumDimension must be positive") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = MediaExportEngine(rootProvider: { context.workspaceRootURL })
        let info = try await MediaRenderer(rootProvider: { context.workspaceRootURL }).inspect(path: args.input)
        guard let width = info["videoWidth"].flatMap(Double.init), let height = info["videoHeight"].flatMap(Double.init), width > 0, height > 0 else {
            throw FloeError.validationFailed("Proxy input has no valid video dimensions")
        }
        let scale = min(1, Double(args.maximumDimension) / max(width, height))
        let result = try await engine.transcode(.init(
            input: args.input,
            output: args.output,
            container: args.container,
            videoCodec: nil,
            audioCodec: nil,
            width: max(2, Int(width * scale) / 2 * 2),
            height: max(2, Int(height * scale) / 2 * 2),
            frameRate: nil,
            videoBitrate: nil,
            audioBitrate: nil,
            passthrough: false
        ), cancellation: context.cancellation)
        return ToolExecutionOutput(digesting: "proxy \(result)", exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("video processing is unavailable on this platform")
        #endif
    }
}

/// `audio.mix`: mix two workspace audio files with explicit gains.
public struct AudioMixTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var mixPath: String
        public var output: String
        public var inputGain: Double?
        public var mixGain: Double?
    }

    public static let name = "audio.mix"
    public static let toolDescription =
        "Mix two audio files into a new output. Both inputs must have matching sample rates and channel counts. Gains in 0...16 are applied before summing; peaks clip to the normal PCM range. Use audio.inspect first to choose levels."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"mixPath":{"type":"string"},"output":{"type":"string"},"inputGain":{"type":"number"},"mixGain":{"type":"number"}},"required":["input","mixPath","output"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.input.isEmpty, !args.mixPath.isEmpty, !args.output.isEmpty else {
            throw FloeError.validationFailed("input, mixPath and output are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = AudioEngine(rootProvider: { context.workspaceRootURL })
        var operations: [String: Double] = [:]
        if let gain = args.inputGain { operations["gain"] = gain }
        if let mixGain = args.mixGain { operations["mixGain"] = mixGain }
        let path = try await engine.edit(
            path: args.input,
            outputPath: args.output,
            operations: operations,
            fadeOutSeconds: nil,
            mixPath: args.mixPath, cancellation: context.cancellation
        )
        return ToolExecutionOutput(digesting: "status=ok output=\(path)", exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}
