import Foundation
import Synchronization
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
        "Inspect a video/audio/GIF file in the workspace: container, duration, video dimensions, frame rate, track count and rotation. Animated GIFs are reported through ImageIO (frame count, loop count, per-frame timing) because AVFoundation cannot open them. Use this before editing so every parameter you pass is grounded in the actual source."
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
        "Edit a video using one source trim, synchronized speed, volume, mute and non-overlapping audio fades. Other operations fail before processing. A plan containing exactly one gif(fps,width) operation converts an animated GIF source into an H.264 mp4/mov through ImageIO with bounded memory; this is a deterministic local conversion, not AI generation, and it resamples the source to the requested constant frame rate (the reported duration stays truthful; use video.inspect for the original per-frame timing). Export supports mp4/mov/m4v, H.264/HEVC and AAC; optional dimensions, frame rate and bitrates are applied to the actual file. quality, export range and forced hardware selection are unsupported. Output is staged and verified before replacement; source files are preserved. This tool does not imply shared background-media job support."
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
        guard hasTimestamps != hasInterval, (args.timestamps != nil) != (args.everySeconds != nil) else {
            throw FloeError.validationFailed("provide timestamps or everySeconds")
        }
        guard (1...10000).contains(args.maximumFrames) else {
            throw FloeError.validationFailed("maximumFrames must be positive")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        var timestamps = args.timestamps ?? []
        if timestamps.isEmpty, let every = args.everySeconds {
            guard let start = args.start, let end = args.end, start.isFinite, end.isFinite, every.isFinite, every > 0, start >= 0, end > start else {
                throw FloeError.validationFailed("everySeconds requires explicit start and end")
            }
            let count = floor((end - start) / every) + 1
            guard count.isFinite, count > 0, count <= Double(args.maximumFrames) else {
                throw FloeError.validationFailed("Requested interval exceeds maximumFrames")
            }
            timestamps = (0..<Int(count)).map { start + Double($0) * every }
        }
        let renderer = MediaRenderer(rootProvider: { context.workspaceRootURL })
        let written = try await renderer.extractFrames(
            path: args.path,
            timestamps: timestamps,
            outputDirectory: args.outputDirectory,
            format: args.format,
            maximumFrames: args.maximumFrames, cancellation: context.cancellation
        )
        var lines = ["status=ok frames=\(written.count)"]
        lines.append(contentsOf: written.prefix(50).map { "frame=\($0)" })
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}
#endif

/// One enhancement call as the tools see it: explicit operation, explicit
/// engine, quality no longer dropped, overwrite consent and cancellation.
public struct FrameProcessingRequest: Sendable {
    public var operation: MediaEnhancementOperation
    public var input: URL
    public var output: URL
    public var mode: String
    public var modelID: String?
    public var quality: String?
    public var overwrite: Bool
    /// Immutable workspace scope snapshotted by the caller (ToolContext or a
    /// task/UI adapter) when the request is built. The service resolves both
    /// paths against exactly this value and refuses requests without one; a
    /// concurrent selection change can never redirect a queued job.
    public var workspaceRoot: URL?
    public var progress: @Sendable (MediaEnhancementProgress) -> Void
    public var cancellation: CancellationToken?

    public init(
        operation: MediaEnhancementOperation,
        input: URL,
        output: URL,
        mode: String,
        modelID: String? = nil,
        quality: String? = nil,
        overwrite: Bool = false,
        workspaceRoot: URL? = nil,
        progress: @escaping @Sendable (MediaEnhancementProgress) -> Void = { _ in },
        cancellation: CancellationToken? = nil
    ) {
        self.operation = operation
        self.input = input
        self.output = output
        self.mode = mode
        self.modelID = modelID
        self.quality = quality
        self.overwrite = overwrite
        self.workspaceRoot = workspaceRoot
        self.progress = progress
        self.cancellation = cancellation
    }
}

/// Frame-processor pipeline seam. The app injects the shared
/// `MediaEnhancementService`; the default reports honest unavailability.
public protocol FrameProcessing: Sendable {
    func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String
    func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String
    func process(_ request: FrameProcessingRequest) async throws -> String
}

/// Task-scoped progress channel for one media job execution.
///
/// The job service injects `ToolContext.taskProgress` for registry-run jobs;
/// an app-side job adapter may instead install this task-local reporter around
/// the exact tool execution. Media tools read whichever is present ONCE and
/// forward the real processor updates (`MediaEnhancementProgress` from the
/// frame pipeline); with neither present, no progress is invented.
public enum MediaJobProgressScope {
    /// Set with `MediaJobProgressScope.$reporter.withValue(...) { ... }` so the
    /// value propagates to the tool executing inside the closure.
    @TaskLocal public static var reporter: (@Sendable (MediaEnhancementProgress) -> Void)?

    /// Runs `body` with `reporter` installed for this task subtree.
    public static func withReporter<T>(_ reporter: (@Sendable (MediaEnhancementProgress) -> Void)?,
                                       _ body: () async throws -> T) async rethrows -> T {
        try await $reporter.withValue(reporter, operation: body)
    }
}

/// Bounded synchronous→async bridge from per-frame media progress into the
/// runtime/app `TaskProgressReporting` contract. At most one report is in
/// flight; intermediate frame updates coalesce to the latest observation, so
/// a 60 fps pipeline never queues 60 tasks per second.
public final class MediaTaskProgressForwarder: @unchecked Sendable {
    private struct State: Sendable {
        var pending: TaskProgressUpdate?
        var scheduled = false
    }

    private let state = Mutex(State())
    private let reporter: any TaskProgressReporting

    public init(reporter: any TaskProgressReporting) {
        self.reporter = reporter
    }

    public func submit(_ update: MediaEnhancementProgress) {
        let mapped = TaskProgressUpdate(
            stage: Self.stage(for: update.phase),
            phase: update.phase.rawValue,
            completedUnits: update.completedUnits,
            totalUnits: update.totalUnits)
        let shouldSchedule = state.withLock { state -> Bool in
            state.pending = mapped
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task.detached { [weak self] in
            await self?.pump()
        }
    }

    static func stage(for phase: MediaEnhancementProgress.Phase) -> String {
        switch phase {
        case .committing: return NativeJobProgressStageNames.finalizing
        case .validating: return NativeJobProgressStageNames.verifying
        default: return NativeJobProgressStageNames.running
        }
    }

    private func pump() async {
        while true {
            let next = state.withLock { state -> TaskProgressUpdate? in
                let value = state.pending
                state.pending = nil
                if value == nil { state.scheduled = false }
                return value
            }
            guard let next else { return }
            await reporter.report(next)
        }
    }
}

/// Stage literals shared with the job progress document (`NativeJobProgress`
/// stage raw values) without making FloeMedia depend on FloeExecution.
public enum NativeJobProgressStageNames {
    public static let preparing = "preparing"
    public static let running = "running"
    public static let finalizing = "finalizing"
    public static let verifying = "verifying"
    public static let cancelling = "cancelling"
}

/// Routes real media progress to the runtime/app reporter when one is
/// injected, otherwise to an adapter-installed media job scope, otherwise
/// nowhere.
public enum MediaProgressRouting {
    public static func closure(for context: ToolContext) -> @Sendable (MediaEnhancementProgress) -> Void {
        if let reporter = context.taskProgress {
            let forwarder = MediaTaskProgressForwarder(reporter: reporter)
            return { update in forwarder.submit(update) }
        }
        if let reporter = MediaJobProgressScope.reporter {
            return { update in reporter(update) }
        }
        return { _ in }
    }
}

/// Freezes one media enhancement job into an immutable, replay-safe plan.
///
/// The job payload's input/output paths are resolved against the workspace
/// root FROZEN AT SUBMISSION (never the currently selected project), the
/// request carries that same root for the service's own guard, and progress
/// flows through `MediaJobProgressScope`. The app-side adapter turns this plan
/// into a prepared operation; the plan is reconstructible from the durable job
/// record after a relaunch (the payload and frozen root are both persisted).
public struct MediaJobOperationPlan: Sendable {
    public var operationID: String
    public var serviceLabel: String
    public var frozenRevision: String?
    public var request: FrameProcessingRequest
    public var expectedOutputURL: URL

    public init(operationID: String, serviceLabel: String, frozenRevision: String? = nil,
                request: FrameProcessingRequest, expectedOutputURL: URL) {
        self.operationID = operationID
        self.serviceLabel = serviceLabel
        self.frozenRevision = frozenRevision
        self.request = request
        self.expectedOutputURL = expectedOutputURL
    }
}

public enum MediaJobEnhancementPreparation {
    public enum PreparationError: Error, CustomStringConvertible {
        case unsupportedPayload(String)
        case missingWorkspace

        public var description: String {
            switch self {
            case .unsupportedPayload(let detail): return detail
            case .missingWorkspace: return "media jobs require the task workspace frozen at submission"
            }
        }
    }

    /// Builds the immutable plan for `video.interpolate` /
    /// `video.superResolution` payloads. Returns nil when the payload is not a
    /// frame-processing request (the caller keeps its own routing).
    public static func frameProcessingPlan(
        payloadJSON: Data,
        workspaceRootPath: String,
        operationID: String
    ) throws -> MediaJobOperationPlan? {
        guard !workspaceRootPath.isEmpty else { throw PreparationError.missingWorkspace }
        let root = URL(fileURLWithPath: workspaceRootPath).standardizedFileURL.resolvingSymlinksInPath()
        let decoder = JSONDecoder()
        if let args = try? decoder.decode(VideoInterpolateTool.Arguments.self, from: payloadJSON) {
            return try plan(operation: .interpolation(targetFPS: args.targetFPS), mode: args.mode,
                            modelID: args.modelID, quality: args.quality,
                            overwrite: args.overwrite ?? false, input: args.input, output: args.output,
                            root: root, operationID: operationID, label: "media.frame-interpolation")
        }
        if let args = try? decoder.decode(VideoSuperResolutionTool.Arguments.self, from: payloadJSON) {
            return try plan(operation: .superResolution(scaleFactor: args.scaleFactor), mode: args.mode,
                            modelID: args.modelID, quality: args.quality,
                            overwrite: args.overwrite ?? false, input: args.input, output: args.output,
                            root: root, operationID: operationID, label: "media.frame-super-resolution")
        }
        return nil
    }

    private static func plan(operation: MediaEnhancementOperation, mode: String, modelID: String?,
                             quality: String?, overwrite: Bool, input: String, output: String,
                             root: URL, operationID: String, label: String) throws -> MediaJobOperationPlan {
        let inputURL = try MediaPathGuard.resolve(input, root: root)
        let outputURL = try MediaPathGuard.resolveOutput(output, root: root)
        let reporter = MediaJobProgressScope.reporter
        let request = FrameProcessingRequest(
            operation: operation,
            input: inputURL,
            output: outputURL,
            mode: mode,
            modelID: modelID,
            quality: quality,
            overwrite: overwrite,
            workspaceRoot: root,
            progress: { update in reporter?(update) }
        )
        return MediaJobOperationPlan(
            operationID: operationID,
            serviceLabel: label,
            frozenRevision: nil,
            request: request,
            expectedOutputURL: outputURL
        )
    }
}

public extension FrameProcessing {
    /// Legacy conformers keep working: the request's quality/overwrite/progress
    /// are only ignored when the conformer predates them, and an explicit
    /// overwrite request is refused instead of being silently dropped.
    func process(_ request: FrameProcessingRequest) async throws -> String {
        if request.overwrite {
            throw FloeError.validationFailed("This frame processor does not support explicit overwrite consent")
        }
        switch request.operation {
        case .interpolation(let targetFPS):
            return try await interpolate(
                input: request.input, output: request.output,
                targetFPS: targetFPS, mode: request.mode, modelID: request.modelID
            )
        case .superResolution(let scaleFactor):
            return try await superResolution(
                input: request.input, output: request.output,
                scaleFactor: scaleFactor, mode: request.mode, modelID: request.modelID
            )
        }
    }
}

public struct UnavailableFrameProcessing: FrameProcessing {
    public init() {}
    public func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String {
        throw FloeError.invalidConfiguration("frame interpolation is unavailable in this build")
    }
    public func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String {
        throw FloeError.invalidConfiguration("super resolution is unavailable in this build")
    }
    public func process(_ request: FrameProcessingRequest) async throws -> String {
        throw FloeError.invalidConfiguration("frame enhancement is unavailable in this build")
    }
}

/// Integration seam for the primary app owner: build the real shared service
/// from the same workspace-root provider and model store the media tools use,
/// then pass it to `MediaToolRegistration.register(frameProcessing:)`.
public enum MediaEnhancementIntegration {
    /// Builds the real shared service. There is deliberately no workspace
    /// provider parameter: every request must carry the caller's immutable
    /// workspace scope (`FrameProcessingRequest.workspaceRoot`), so a global
    /// or "currently selected" root can never redirect a queued job.
    public static func makeFrameProcessing(
        modelResolver: (any MediaModelResolving)? = nil,
        limits: MediaEnhancementService.Limits = MediaEnhancementService.Limits()
    ) -> any FrameProcessing {
        MediaEnhancementService(modelResolver: modelResolver, limits: limits)
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
