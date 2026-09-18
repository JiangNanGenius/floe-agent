// FloeApp — Agent-facing durable video generation tools (ordinary chat).
//
// The cloud video suppliers (Google Veo/Omni, Volcengine Ark Seedance and
// Alibaba DashScope Wan) are exposed here as `video.models`,
// `video.generate`, `video.status` and `video.cancel`. Submissions become
// durable `media_generation_jobs` owned by the conversation, are polled by the
// background coordinator across relaunches, and are downloaded atomically into
// the conversation workspace. Canvas keeps its own manual entry points and is
// not required for any of this.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeTools
import FloeWorkspace

struct RemoteVideoModelsTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var offset: Int?
        var limit: Int?
    }

    static let name = "video.models"
    static let toolDescription =
        "List the configured, enabled and adapter-backed cloud video models (Google Veo/Omni, Volcengine Ark Seedance, Alibaba DashScope Wan). Read this before video.generate: it returns exact modelID values, the preferred route, each model's parameter contract (aspect ratios, resolutions, duration limits, audio/watermark/seed support) and its reference-image policy. Models whose provider has no native video adapter are never listed. Models with referenceImage.supported=true accept exactly one workspace-relative referenceImagePath or a conversation referenceImageAttachmentID; the image is read locally and sent to the provider inline as base64 (never as a local path), and unsupported models reject the argument instead of ignoring it."
    static let parametersJSON = #"{"type":"object","properties":{"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let list: @MainActor @Sendable (Arguments) throws -> String

    init(center: FilesCenter) {
        list = { args in
            let conversation = center.environment.conversationCenter
            let routes = conversation.agentVideoRoutes()
            let offset = min(max(0, args.offset ?? 0), routes.count)
            let end = min(offset + (args.limit ?? 25), routes.count)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let entries: [[String: Any]] = try routes[offset..<end].enumerated().map { index, route in
                let contractData = try encoder.encode(route.contract)
                let contract = try JSONSerialization.jsonObject(with: contractData)
                let referenceSupported = VideoReferenceImagePolicy.supportsReferenceImages(
                    providerKind: route.providerKind, modelRemoteID: route.remoteModelID
                ) && route.contract.maximumReferenceAssets > 0
                var referenceImage: [String: Any] = [
                    "supported": referenceSupported,
                    "maximum": referenceSupported
                        ? min(VideoReferenceImagePolicy.maximumAssets, route.contract.maximumReferenceAssets)
                        : 0,
                    "upload": "inline-base64"
                ]
                referenceImage["mode"] = route.contract.referenceMode ?? NSNull()
                return [
                    "modelID": route.modelID.uuidString,
                    "remoteModelID": route.remoteModelID,
                    "modelName": route.displayName,
                    "providerID": route.providerID.uuidString,
                    "providerName": route.providerName,
                    "providerKind": route.providerKind.rawValue,
                    "preferred": route.preferred,
                    "priority": offset + index + 1,
                    "referenceImage": referenceImage,
                    "parameters": contract
                ]
            }
            let output: [String: Any] = [
                "total": routes.count,
                "models": entries,
                "nextOffset": end < routes.count ? end as Any : NSNull(),
                "policy": "These are the only usable video routes. Call video.generate once per request and track it with video.status; a replayed tool call for the same request returns the existing job instead of paying twice, while a new user request always creates a new job. Never resubmit a running, timed-out or outcome-unknown job. Reference images are read from the task workspace or a conversation attachment and sent inline when referenceImage.supported is true. Completion is downloaded automatically into the conversation workspace and announced with a notification."
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func validate(_ args: Arguments) throws {
        guard (args.offset ?? 0) >= 0, (1...50).contains(args.limit ?? 25) else {
            throw FloeError.validationFailed("Invalid video catalog pagination")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let text = try await list(args)
        let data = Data(text.utf8)
        guard data.count <= 262_144 else {
            throw FloeError.validationFailed("Video catalog page is too large; request a smaller limit")
        }
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: 0,
            maximumSummaryCharacters: 262_144
        )
    }
}

struct RemoteVideoGenerateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var prompt: String
        var modelID: UUID?
        var aspectRatio: String?
        var resolution: String?
        var durationSeconds: Int?
        var includeAudio: Bool?
        var watermark: Bool?
        var seed: Int?
        /// Workspace-relative path of a PNG/JPEG/WebP reference image. Read
        /// through the task's guarded workspace root; never uploaded as a
        /// local path.
        var referenceImagePath: String?
        /// Conversation attachment ID of a reference image. Ownership is
        /// checked against the current conversation before the bytes are read.
        var referenceImageAttachmentID: UUID?
    }

    static let name = "video.generate"
    static let toolDescription =
        "Submit one durable video generation job for the current conversation and return its jobID immediately. Read video.models first for exact modelID values, allowed parameters and referenceImage support. Supply at most one reference image: referenceImagePath (workspace-relative PNG/JPEG/WebP) or referenceImageAttachmentID (an image attached to this conversation). The image is read locally and sent to the provider inline as base64; models without reference support reject it instead of ignoring it, and local paths are never uploaded silently. The job survives relaunches: polling resumes automatically and the finished video is downloaded into the conversation workspace with a notification. Use video.status to check progress and video.cancel to stop it. A replayed tool call for the same request returns the existing job; a distinct later request creates a new job. This tool is for real provider video generation, not for local GIF/animation conversion (use video.edit for a timed GIF source)."
    static let parametersJSON = #"""
    {"type":"object","properties":{
      "prompt":{"type":"string","description":"Detailed description of the video to create"},
      "modelID":{"type":"string","format":"uuid","description":"Exact modelID from video.models; omit to use the preferred route"},
      "aspectRatio":{"type":"string","description":"Allowed aspect ratio from video.models"},
      "resolution":{"type":"string","description":"Allowed resolution from video.models"},
      "durationSeconds":{"type":"integer","minimum":1,"maximum":60,"description":"Allowed duration from video.models. Veo reference images require 8"},
      "includeAudio":{"type":"boolean","description":"Only when video.models reports supportsAudio"},
      "watermark":{"type":"boolean","description":"Only when video.models reports supportsWatermark"},
      "seed":{"type":"integer","description":"Only when video.models reports supportsSeed"},
      "referenceImagePath":{"type":"string","description":"Workspace-relative PNG/JPEG/WebP image to use as the reference or first frame; only when video.models reports referenceImage.supported"},
      "referenceImageAttachmentID":{"type":"string","format":"uuid","description":"Image attachment from this conversation to use as the reference or first frame; mutually exclusive with referenceImagePath"}},
     "required":["prompt"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .networkAccess, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let submit: @MainActor @Sendable (Arguments, ToolContext) async throws -> MediaVideoSubmissionSummary

    init(center: FilesCenter) {
        submit = { args, context in
            guard let conversationID = context.conversationID else {
                throw FloeError.invalidConfiguration("Video generation requires a conversation context")
            }
            let conversation = center.environment.conversationCenter
            let (route, _, model) = try conversation.resolveAgentVideoRoute(modelID: args.modelID)
            let options = try VideoRequestValidator.validate(
                VideoGenerationOptions(
                    aspectRatio: args.aspectRatio,
                    resolution: args.resolution,
                    durationSeconds: args.durationSeconds,
                    includeAudio: args.includeAudio,
                    seed: args.seed,
                    watermark: args.watermark
                ),
                route: route
            )
            let referenceURL = try await RemoteVideoReferenceImage.resolve(
                path: args.referenceImagePath,
                attachmentID: args.referenceImageAttachmentID,
                context: context,
                center: center,
                route: route,
                options: options
            )
            let request = RemoteVideoRequest(
                prompt: args.prompt,
                modelRemoteID: model.remoteModelID,
                options: options,
                referenceAssetURLs: referenceURL.map { [$0] } ?? []
            )
            // The durable operation identity is the submitting tool call, so
            // a replay attaches to the existing job while a new user request
            // in a later run is never merged into it.
            let idempotencyKey = context.toolCallID.map { "\(context.runID.uuidString):\($0)" }
            let result = try await center.environment.mediaGenerationService.submitVideo(
                modelID: model.id,
                owner: .conversation(conversationID),
                originRunID: context.runID,
                request: request,
                idempotencyKey: idempotencyKey
            )
            return MediaVideoSubmissionSummary(
                jobID: result.job.id,
                state: result.job.state.rawValue,
                providerTaskID: result.job.providerTaskID,
                providerName: route.providerName,
                remoteModelID: route.remoteModelID,
                deduplicated: result.deduplicated,
                estimatedCompletionAt: result.job.estimatedCompletionAt
            )
        }
    }

    func validate(_ args: Arguments) throws {
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("prompt must not be empty")
        }
        if let duration = args.durationSeconds, !(1...60).contains(duration) {
            throw FloeError.validationFailed("durationSeconds must be within 1...60")
        }
        if let seed = args.seed, seed < 0 {
            throw FloeError.validationFailed("seed must not be negative")
        }
        if args.referenceImagePath != nil, args.referenceImageAttachmentID != nil {
            throw FloeError.validationFailed("Use either referenceImagePath or referenceImageAttachmentID, not both")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        var args = args
        args.prompt = args.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try await submit(args, context)
        var lines = [
            "status=\(summary.deduplicated ? "existing-active-job" : "submitted") jobID=\(summary.jobID.uuidString)",
            "state=\(summary.state) provider=\(summary.providerName) model=\(summary.remoteModelID)"
        ]
        if let taskID = summary.providerTaskID { lines.append("providerTaskID=\(taskID)") }
        if let estimate = summary.estimatedCompletionAt {
            lines.append("estimatedCompletionAt=\(ISO8601DateFormatter().string(from: estimate))")
        }
        if summary.deduplicated {
            lines.append("note=An identical active request already exists; no second paid submission was made.")
        } else {
            lines.append("note=Generation runs in the background. Poll video.status only as needed; do not resubmit.")
        }
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}

struct RemoteVideoStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var jobID: UUID
        var refresh: Bool?
    }

    static let name = "video.status"
    static let toolDescription =
        "Report the truthful durable state of one video job owned by this conversation: state, provider task ID, result URL and its expiry, local asset, next poll time and the last error. By default it also polls the provider once so the answer is current; set refresh=false to read only the stored state. A job may be preparing, submitted, running, completed, downloading, ready, failed, cancelled or expired."
    static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"},"refresh":{"type":"boolean"}},"required":["jobID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let report: @MainActor @Sendable (Arguments, ToolContext) async throws -> String

    init(center: FilesCenter) {
        report = { args, context in
            let environment = center.environment
            let owned = try await RemoteVideoJobAccess.ownedConversationJob(
                jobID: args.jobID, context: context, environment: environment
            )
            var refreshError: String?
            if args.refresh != false, !owned.job.state.isTerminal {
                do {
                    _ = try await environment.mediaGenerationService.refreshVideoJob(jobID: args.jobID)
                } catch {
                    refreshError = error.localizedDescription
                }
            }
            let refreshed = try await RemoteVideoJobAccess.ownedConversationJob(
                jobID: args.jobID, context: context, environment: environment
            )
            let current = refreshed.job
            var output: [String: Any] = [
                "jobID": current.id.uuidString,
                "state": current.state.rawValue,
                "mediaKind": current.mediaKind.rawValue,
                "terminated": current.state.isTerminal,
                "canCancel": !current.state.isTerminal,
                "ready": current.state == .ready
            ]
            if let taskID = current.providerTaskID { output["providerTaskID"] = taskID }
            if let url = current.resultURL { output["resultURL"] = url.absoluteString }
            if let expires = current.resultURLExpiresAt {
                output["resultURLExpiresAt"] = ISO8601DateFormatter().string(from: expires)
                output["resultURLExpired"] = expires <= Date()
            }
            if let localAssetID = current.localAssetID { output["localAssetID"] = localAssetID.uuidString }
            if let nextPoll = current.nextPollAt { output["nextPollAt"] = ISO8601DateFormatter().string(from: nextPoll) }
            if let error = current.lastError { output["lastError"] = error }
            if let refreshError { output["refreshError"] = refreshError }
            output["note"] = current.state == .ready
                ? "The result is saved in the conversation workspace (GeneratedMedia) and the material library."
                : "Do not resubmit; the durable job is polled automatically, including after a relaunch."
            return String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let text = try await report(args, context)
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }
}

struct RemoteVideoCancelTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var jobID: UUID
    }

    static let name = "video.cancel"
    static let toolDescription =
        "Cancel one non-terminal video job owned by this conversation. The provider is asked to cancel first; the local job is only marked cancelled after the provider confirms, or closed honestly when no provider task ID was persisted. A cancel that races with completion reports the real outcome instead of claiming success. Cancelling a finished job is an error, not a silent no-op."
    static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"}},"required":["jobID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let cancel: @MainActor @Sendable (Arguments, ToolContext) async throws -> String

    init(center: FilesCenter) {
        cancel = { args, context in
            let environment = center.environment
            _ = try await RemoteVideoJobAccess.ownedConversationJob(
                jobID: args.jobID, context: context, environment: environment
            )
            try await environment.mediaGenerationService.cancelVideo(jobID: args.jobID)
            let cancelled = try await RemoteVideoJobAccess.ownedConversationJob(
                jobID: args.jobID, context: context, environment: environment
            )
            let current = cancelled.job
            var output: [String: Any] = [
                "jobID": current.id.uuidString,
                "state": current.state.rawValue
            ]
            if let error = current.lastError { output["note"] = error }
            return String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let text = try await cancel(args, context)
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }
}

/// Shared ownership guard: chat tools only operate on jobs owned by the same
/// conversation. Canvas-owned jobs belong to their canvas UI.
enum RemoteVideoJobAccess {
    @MainActor
    static func ownedConversationJob(
        jobID: UUID,
        context: ToolContext,
        environment: AppEnvironment
    ) async throws -> OwnedMediaGenerationJob {
        guard let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Video jobs require a conversation context")
        }
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw FloeError.notFound("video job \(jobID.uuidString)")
        }
        guard owned.owner.kind == .conversation, owned.owner.id == conversationID else {
            throw FloeError.validationFailed("This video job is not owned by the current conversation")
        }
        return owned
    }
}

/// Resolves one local reference image into the provider's inline `data:` URL.
///
/// Only two sources are accepted: a task-workspace file resolved through
/// `WorkspacePathGuard` (which rejects absolute paths, traversal, symlink
/// escapes, secret files and oversized reads) or a conversation attachment
/// resolved through `FilesCenter` (which only returns app-owned files or a
/// security-scoped bookmark). A raw absolute path is never read, and the
/// bytes are never uploaded to a third-party host: when the selected route
/// does not verifiably accept an inline image the call is rejected.
enum RemoteVideoReferenceImage {
    @MainActor
    static func resolve(
        path: String?,
        attachmentID: UUID?,
        context: ToolContext,
        center: FilesCenter,
        route: VideoModelRoute,
        options: VideoGenerationOptions
    ) async throws -> URL? {
        guard path != nil || attachmentID != nil else { return nil }
        guard path == nil || attachmentID == nil else {
            throw FloeError.validationFailed("Use either referenceImagePath or referenceImageAttachmentID, not both")
        }
        guard VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: route.providerKind, modelRemoteID: route.remoteModelID
        ), route.contract.maximumReferenceAssets > 0 else {
            throw FloeError.validationFailed(
                "\(route.displayName) 未提供受支持的参考图/首帧输入；请使用 video.models 中 referenceImage.supported=true 的模型。"
            )
        }
        // Veo reference images are documented as requiring an 8-second video;
        // reject a conflicting explicit duration before any paid submission.
        if route.providerKind == .googleGemini,
           !route.remoteModelID.hasPrefix("gemini-omni-"),
           let duration = options.durationSeconds, duration != 8 {
            throw FloeError.validationFailed("Veo 参考图要求 durationSeconds=8，或省略该参数使用供应商默认值。")
        }
        if let path {
            return try workspaceImage(path: path, context: context)
        }
        guard let attachmentID, let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Reference images require a conversation context")
        }
        return try await attachmentImage(
            attachmentID: attachmentID, conversationID: conversationID, center: center
        )
    }

    private static func workspaceImage(path: String, context: ToolContext) throws -> URL {
        guard let root = context.workspaceRootURL else {
            throw FloeError.invalidConfiguration("Reference images require a task workspace")
        }
        try context.authorizeWorkspacePath(path)
        let guarder = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: VideoReferenceImagePolicy.maximumBytes
        )
        let url = try guarder.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.notFound("reference image \(path)")
        }
        try guarder.assertReadableSize(url)
        let data = try Data(floeContentsOf: url)
        return try VideoReferenceImagePolicy.inlineDataURL(data: data)
    }

    @MainActor
    private static func attachmentImage(
        attachmentID: UUID,
        conversationID: UUID,
        center: FilesCenter
    ) async throws -> URL {
        guard let attachment = try await center.environment.conversationStore.attachment(id: attachmentID) else {
            throw FloeError.notFound("attachment \(attachmentID.uuidString)")
        }
        // Owner isolation: an attachment bound to another conversation can
        // never be pulled into this one. Unbound recent files (conversationID
        // nil) are app-owned staged files and remain usable.
        if let owner = attachment.conversationID, owner != conversationID {
            throw FloeError.validationFailed("该附件属于其它对话，不能作为参考图")
        }
        guard attachment.kind == .image else {
            throw FloeError.validationFailed("参考图附件必须是图片")
        }
        let url = try center.resolveURL(for: attachment)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0, Int64(fileSize) <= Int64(VideoReferenceImagePolicy.maximumBytes) else {
            throw FloeError.validationFailed(
                "参考图超过 \(VideoReferenceImagePolicy.maximumBytes) 字节上限"
            )
        }
        let accessing = attachment.storage == .securityScopedBookmark
            ? url.startAccessingSecurityScopedResource() : false
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(floeContentsOf: url)
        return try VideoReferenceImagePolicy.inlineDataURL(data: data)
    }
}

struct MediaVideoSubmissionSummary: Sendable {
    var jobID: UUID
    var state: String
    var providerTaskID: String?
    var providerName: String
    var remoteModelID: String
    var deduplicated: Bool
    var estimatedCompletionAt: Date?
}

@MainActor
func registerRemoteVideoTools(center: FilesCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(RemoteVideoModelsTool.self)
    registry.register(RemoteVideoModelsTool(center: center))
    ToolCatalog.register(RemoteVideoGenerateTool.self)
    registry.register(RemoteVideoGenerateTool(center: center))
    ToolCatalog.register(RemoteVideoStatusTool.self)
    registry.register(RemoteVideoStatusTool(center: center))
    ToolCatalog.register(RemoteVideoCancelTool.self)
    registry.register(RemoteVideoCancelTool(center: center))
}
#endif
