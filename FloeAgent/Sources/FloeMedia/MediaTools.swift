import Foundation
import FloeCore
import FloeTools

/// `media.capabilities`: read-only capability and model discovery. The model
/// decides parameters from this report; Floe never applies presets.
public struct MediaCapabilitiesTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "media.capabilities"
    public static let toolDescription =
        "Report the device's real media capabilities and installed/available models before choosing parameters. Includes Apple-native frame processors (frame rate conversion, interpolation, super-resolution, optical flow, noise filter, motion blur), MetalFX availability, hardware encode/decode, supported scale factors, system model status, container preferences, and skill-hub model availability. Parameters are never defaulted: pass explicit values to video.*/audio.* tools and expect structured errors for unsupported requests."
    public static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let appBuild: String
    private let modelProvider: @Sendable () async -> (installed: [MediaCapabilities.Model], available: [MediaCapabilities.Model])

    public init(appBuild: String, modelProvider: @escaping @Sendable () async -> (installed: [MediaCapabilities.Model], available: [MediaCapabilities.Model]) = { ([], []) }) {
        self.appBuild = appBuild
        self.modelProvider = modelProvider
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var capabilities = MediaCapabilities.probe(appBuild: appBuild)
        let models = await modelProvider()
        capabilities.installedModels = models.installed
        capabilities.availableModels = models.available
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(capabilities)
        return ToolExecutionOutput(digesting: String(decoding: data, as: UTF8.self), exitStatus: 0)
    }
}

#if canImport(AVFoundation)
/// `video.inspect`: metadata for a media file.
public struct VideoInspectTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
    }

    public static let name = "video.inspect"
    public static let toolDescription =
        "Inspect a video/audio file in the workspace: container, duration, video dimensions, frame rate, track count and rotation. Use this before editing so every parameter you pass is grounded in the actual source."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty else { throw FloeError.validationFailed("path is required") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let renderer = MediaRenderer(rootProvider: { context.workspaceRootURL })
        let report = try await renderer.inspect(path: args.path)
        let lines = report.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}

/// `video.edit`: non-destructive operation plan. All parameters are explicit.
public struct VideoEditTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var operations: [VideoEditPlan.Operation]
        public var exportSpec: VideoEditPlan.Export
    }

    public static let name = "video.edit"
    public static let toolDescription =
        "Edit a video using one source trim, synchronized speed, volume, mute and non-overlapping audio fades. Other operations fail before processing. Export supports mp4/mov/m4v, H.264/HEVC and AAC; optional dimensions, frame rate and bitrates are applied to the actual file. quality, export range and forced hardware selection are unsupported. Output is staged and verified before replacement; source files are preserved. This tool does not imply shared background-media job support."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "input":{"type":"string"},"output":{"type":"string"},
      "operations":{"type":"array","maxItems":64,"items":{"type":"object"}},
      "exportSpec":{"type":"object","properties":{"container":{"type":"string"},"videoCodec":{"type":"string"},"audioCodec":{"type":"string"},"videoBitrate":{"type":"integer"},"audioBitrate":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"},"frameRate":{"type":"number"},"quality":{"type":"number"},"range":{"type":"array","items":{"type":"number"}},"hardwareAcceleration":{"type":"boolean"}},"required":["container"],"additionalProperties":false}},
     "required":["input","output","operations","exportSpec"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        let plan = VideoEditPlan(input: args.input, output: args.output, operations: args.operations, export: args.exportSpec)
        try plan.validate()
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let plan = VideoEditPlan(input: args.input, output: args.output, operations: args.operations, export: args.exportSpec)
        let renderer = MediaRenderer(rootProvider: { context.workspaceRootURL })
        let result = try await renderer.render(plan: plan, cancellation: context.cancellation)
        var lines = [
            "status=ok output=\(result.outputPath)",
            "durationSeconds=\(String(format: "%.3f", result.durationSeconds)) size=\(result.width)x\(result.height) fps=\(String(format: "%.2f", result.frameRate))",
            "codecs=\(result.videoCodec)/\(result.audioCodec ?? "none") bytes=\(result.byteCount)",
            "applied=\(result.appliedOperations.joined(separator: ","))"
        ]
        for warning in result.warnings { lines.append("warning=\(warning)") }
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}

/// `video.extractFrames`: exact-frame extraction at explicit timestamps.
public struct VideoExtractFramesTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var timestamps: [Double]?
        public var everySeconds: Double?
        public var start: Double?
        public var end: Double?
        public var outputDirectory: String
        public var format: String
        public var maximumFrames: Int
    }

    public static let name = "video.extractFrames"
    public static let toolDescription =
        "Extract exact frames from a video at explicit timestamps or a fixed interval and write PNG/JPEG files into a workspace directory. Provide either timestamps or everySeconds (with explicit start/end), never rely on defaults. maximumFrames is required and enforced."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"path":{"type":"string"},"timestamps":{"type":"array","items":{"type":"number"}},"everySeconds":{"type":"number"},"start":{"type":"number"},"end":{"type":"number"},"outputDirectory":{"type":"string"},"format":{"type":"string","enum":["png","jpeg"]},"maximumFrames":{"type":"integer","minimum":1,"maximum":10000}},"required":["path","outputDirectory","format","maximumFrames"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        let hasTimestamps = !(args.timestamps ?? []).isEmpty
        let hasInterval = (args.everySeconds ?? 0) > 0
        guard hasTimestamps || hasInterval else {
            throw FloeError.validationFailed("provide timestamps or everySeconds")
        }
        guard args.maximumFrames > 0 else {
            throw FloeError.validationFailed("maximumFrames must be positive")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var timestamps = args.timestamps ?? []
        if timestamps.isEmpty, let every = args.everySeconds {
            let start = args.start ?? 0
            let end = args.end ?? start
            guard end > start else {
                throw FloeError.validationFailed("everySeconds requires explicit start and end")
            }
            var value = start
            while value <= end, timestamps.count < args.maximumFrames {
                timestamps.append(value)
                value += every
            }
        }
        let renderer = MediaRenderer(rootProvider: { context.workspaceRootURL })
        let written = try await renderer.extractFrames(
            path: args.path,
            timestamps: timestamps,
            outputDirectory: args.outputDirectory,
            format: args.format,
            maximumFrames: args.maximumFrames
        )
        var lines = ["status=ok frames=\(written.count)"]
        lines.append(contentsOf: written.prefix(50).map { "frame=\($0)" })
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}
#endif

/// Frame-processor pipeline seam. The app injects a VT/MetalFX/CoreML
/// implementation; the default reports honest unavailability.
public protocol FrameProcessing: Sendable {
    func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String
    func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String
}

public struct UnavailableFrameProcessing: FrameProcessing {
    public init() {}
    public func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String {
        throw FloeError.invalidConfiguration("frame interpolation is unavailable in this build")
    }
    public func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String {
        throw FloeError.invalidConfiguration("super resolution is unavailable in this build")
    }
}

public enum MediaToolRegistration {
    @discardableResult
    public static func register(
        registry: ToolRunnerRegistry = .shared,
        appBuild: String,
        modelProvider: @escaping @Sendable () async -> (installed: [MediaCapabilities.Model], available: [MediaCapabilities.Model]) = { ([], []) },
        modelStore: ModelArtifactStore? = nil,
        modelCatalogProvider: (@Sendable () async -> ModelArtifactCatalog?)? = nil,
        frameProcessing: (any FrameProcessing)? = nil
    ) -> Bool {
        ToolCatalog.register(MediaCapabilitiesTool.self)
        registry.register(MediaCapabilitiesTool(appBuild: appBuild, modelProvider: modelProvider))
        #if canImport(AVFoundation)
        ToolCatalog.register(VideoInspectTool.self)
        registry.register(VideoInspectTool())
        ToolCatalog.register(VideoEditTool.self)
        registry.register(VideoEditTool())
        ToolCatalog.register(VideoExtractFramesTool.self)
        registry.register(VideoExtractFramesTool())
        #endif
        if let frameProcessing {
            ToolCatalog.register(VideoInterpolateTool.self)
            registry.register(VideoInterpolateTool(processor: frameProcessing))
            ToolCatalog.register(VideoSuperResolutionTool.self)
            registry.register(VideoSuperResolutionTool(processor: frameProcessing))
        }
        ToolCatalog.register(AudioInspectTool.self)
        registry.register(AudioInspectTool())
        ToolCatalog.register(AudioEditTool.self)
        registry.register(AudioEditTool())
        ToolCatalog.register(VideoTranscodeTool.self)
        registry.register(VideoTranscodeTool())
        ToolCatalog.register(VideoThumbnailTool.self)
        registry.register(VideoThumbnailTool())
        ToolCatalog.register(AudioConvertTool.self)
        registry.register(AudioConvertTool())
        ToolCatalog.register(VideoRemuxTool.self)
        registry.register(VideoRemuxTool())
        ToolCatalog.register(VideoProxyTool.self)
        registry.register(VideoProxyTool())
        ToolCatalog.register(AudioMixTool.self)
        registry.register(AudioMixTool())
        if let modelStore, let modelCatalogProvider {
            ToolCatalog.register(MediaModelsTool.self)
            registry.register(MediaModelsTool(store: modelStore, catalogProvider: modelCatalogProvider))
        }
        return true
    }
}
