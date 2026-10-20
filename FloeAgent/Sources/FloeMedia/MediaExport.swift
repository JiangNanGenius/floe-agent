import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
#endif

/// S3-D helper: run-output publication at verified media write boundaries.
/// Snapshots live only in the core `RunOutputSnapshotStore`; this adds the
/// post-write stat + streamed digest the media engines do not already emit
/// and applies the fixed failure policy: bound-run publication failures
/// throw an observable tool error (the written media original is preserved),
/// genuine legacy direct and temporary contexts keep byte-identical legacy
/// results, partially bound contexts fail.
enum RunOutputMediaPublication {
    enum State {
        case required
        case legacyDirect
        case temporaryExempt
        case partiallyBound
    }

    static func state(_ context: ToolContext) -> State {
        let hasCall = context.toolCallID?.isEmpty == false
        let hasTask = context.conversationID != nil
        if !hasCall && !hasTask { return .legacyDirect }
        if hasCall != hasTask { return .partiallyBound }
        if context.temporaryReadOnly { return .temporaryExempt }
        return .required
    }

    static var partialBindingFailure: FloeError {
        FloeError.validationFailed(
            "run output publication requires both the tool-call and task binding")
    }

    static func publicationFailure(_ error: RunOutputSnapshotError) -> FloeError {
        switch error {
        case .bindingMissing: return FloeError.validationFailed("run output publication failed (unbound)")
        case .policyRefused: return FloeError.validationFailed("run output publication refused by policy")
        case .identityInvalid: return FloeError.validationFailed("run output publication failed (invalid identity)")
        case .sourceUnavailable: return FloeError.validationFailed("run output publication failed (source unavailable)")
        case .commitIdentityStale: return FloeError.validationFailed("run output publication failed (stale commit identity)")
        case .conflict(let name): return FloeError.validationFailed("run output publication failed (conflict: \(name))")
        case .overCap: return FloeError.validationFailed("run output publication failed (over cap)")
        case .snapshotAliased: return FloeError.validationFailed("run output publication failed (aliased snapshot)")
        case .ioFailure: return FloeError.storageCorrupted("run output publication failed (storage)")
        }
    }

    static func mimeType(container: String, fallback: String) -> String {
        switch container.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "m4a": return "audio/x-m4a"
        case "png": return "image/png"
        default: return fallback
        }
    }

    /// Publishes the successfully written media file with a post-write
    /// streamed digest (the media engines hand over no commit digest today).
    /// Cancellation propagates; any other identity/IO problem is reported as
    /// an observable failure without touching the written original.
    static func publish(
        summary: String,
        url: URL,
        producerTool: String,
        slot: String,
        mimeType: String,
        using context: ToolContext
    ) throws -> ToolExecutionOutput {
        let digest = try FloeDigest.sha256Hex(ofFileAt: url,
                                              isCancelled: { context.cancellation.isCancelled })
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw FloeError.validationFailed("media output is not a regular file")
        }
        do {
            let published = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: producerTool,
                    slot: slot,
                    commit: RunOutputCommit(
                        sourceURL: url,
                        sha256: digest,
                        byteCount: size,
                        displayName: url.lastPathComponent,
                        mimeType: mimeType
                    )
                ),
                using: context
            )
            return ToolExecutionOutput(digesting: summary, exitStatus: 0, outputFiles: [published])
        } catch let error as RunOutputSnapshotError {
            throw publicationFailure(error)
        }
    }
}

#if canImport(AVFoundation)
/// Export-oriented media tools with verified outputs. Unspecified video dimensions
/// and frame rate follow the source; encoding defaults to H.264 and AAC.
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

    public func thumbnail(input: String, timeSeconds: Double, output: String, maximumDimension: Int, cancellation: CancellationToken? = nil) async throws -> String {
        let inputURL = try resolve(input)
        let outputURL = try resolveOutput(output)
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        guard inputURL != outputURL, outputURL.pathExtension.lowercased() == "png",
              timeSeconds.isFinite, timeSeconds >= 0, (16...8192).contains(maximumDimension) else {
            throw FloeError.validationFailed("Thumbnail needs a separate PNG output, finite time and dimension 16...8192")
        }
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration).seconds
        guard timeSeconds < duration else { throw FloeError.validationFailed("Thumbnail time is outside the video") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        let image = try await generator.image(at: CMTime(seconds: timeSeconds, preferredTimescale: 600)).image
        guard let data = MediaImageEncoding.png(image) else { throw FloeError.internalError("could not encode thumbnail") }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        "Transcode video to mp4, mov or m4v with optional codecs, dimensions, frame rate and bitrates. Defaults: source dimensions and frame rate, H.264 video and AAC audio. remuxOnly=true copies streams and rejects encoding parameters. Unsupported combinations fail before replacing the output."
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
        switch RunOutputMediaPublication.state(context) {
        case .legacyDirect, .temporaryExempt:
            return ToolExecutionOutput(digesting: result, exitStatus: 0)
        case .partiallyBound:
            throw RunOutputMediaPublication.partialBindingFailure
        case .required:
            let outputURL = try await engine.resolveOutput(args.output)
            return try RunOutputMediaPublication.publish(
                summary: result,
                url: outputURL,
                producerTool: Self.name,
                slot: "video",
                mimeType: RunOutputMediaPublication.mimeType(
                    container: args.container, fallback: "application/octet-stream"),
                using: context)
        }
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
            maximumDimension: args.maximumDimension, cancellation: context.cancellation
        )
        switch RunOutputMediaPublication.state(context) {
        case .legacyDirect, .temporaryExempt:
            return ToolExecutionOutput(digesting: result, exitStatus: 0)
        case .partiallyBound:
            throw RunOutputMediaPublication.partialBindingFailure
        case .required:
            let outputURL = try await engine.resolveOutput(args.output)
            return try RunOutputMediaPublication.publish(
                summary: result,
                url: outputURL,
                producerTool: Self.name,
                slot: "image",
                mimeType: "image/png",
                using: context)
        }
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
        switch RunOutputMediaPublication.state(context) {
        case .legacyDirect, .temporaryExempt:
            return ToolExecutionOutput(digesting: result, exitStatus: 0)
        case .partiallyBound:
            throw RunOutputMediaPublication.partialBindingFailure
        case .required:
            let outputURL = try await engine.resolveOutput(args.output)
            return try RunOutputMediaPublication.publish(
                summary: result,
                url: outputURL,
                producerTool: Self.name,
                slot: "audio",
                mimeType: RunOutputMediaPublication.mimeType(
                    container: args.container, fallback: "application/octet-stream"),
                using: context)
        }
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}
