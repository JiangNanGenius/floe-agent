// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent (model-facing) generation tools — Android bindings for the
// original image.models / image.generate / video.models / video.generate /
// video.status / video.cancel contracts (job-8e175eef3cea48d3 bindings;
// job-6b686caa5ffe4761 integration/correctness closure).
//
// These are thin, honest AgentTool shells over
// `G09R2AgentGenerationService`, which reuses the EXISTING G09R2 generation
// backend (route catalog, provider adapters, credential resolution, durable
// `media_generation_jobs`) with conversation ownership. Tool semantics mirror
// the immutable iOS donors (36f63bf400dfaa3a127259eac006b38d72516390,
// FloeApp/Files/RemoteImageTools.swift and
// FloeApp/Conversations/RemoteVideoTools.swift) without any UIKit/App state:
// public candidate selection (model, one-of with the legacy modelID), exact
// selection (never remapped), no automatic resubmission of running/unknown
// jobs, replay idempotency on the submitting tool call, and a clear
// separation between a submitted/unknown job and a delivered readable
// artifact in the task workspace.
//
// Status/cancel naming follows the donor contract: `video.status` and
// `video.cancel` are the ONE status/cancel surface for BOTH image and video
// conversation jobs (the service projects either media kind). There are no
// separate image status tools and no duplicate general-jobs tools.
import Foundation
import FloeCore
import FloeTools
import FloePersistence

private func agentGenerationEpoch() async -> UInt64? {
    await BridgeV5.service.r2BoundCluster()?.epoch
}

/// Deterministic digest of one exact tool request. Used ONLY to mint a
/// stable replay identity when the runtime context carries no provider call
/// id: a replayed identical call attaches to the SAME durable job, while a
/// distinct request produces a distinct key. Never a random UUID.
private func agentGenerationRequestDigest(_ fields: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(fields),
          let data = try? JSONSerialization.data(
              withJSONObject: fields, options: [.sortedKeys]) else {
        return FloeDigest.sha256Hex(Data("agent-generation-invalid".utf8))
    }
    return FloeDigest.sha256Hex(data)
}

// MARK: - image.models

public struct G09R2AgentImageModelsTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var operation: String?
        public var offset: Int?
        public var limit: Int?
    }

    public static let name = "image.models"
    public static let toolDescription =
        "List configured image suppliers, the public selection name (`model`, its remote model ID), exact model IDs, priority order and the parameters accepted by image.generate. Inspect before selecting a route. `model` and `modelID` are a mutually exclusive one-of; the public `model` is preferred and the internal modelID must never be requested from the user. An explicit selection is exact: a 401/404/429 is returned and never silently remapped. Never resubmit a running, timed-out or outcome-unknown generation."
    public static let parametersJSON = #"{"type":"object","properties":{"operation":{"type":"string","enum":["generate","edit"]},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard args.operation == nil || ["generate", "edit"].contains(args.operation ?? ""),
              (args.offset ?? 0) >= 0, (1...50).contains(args.limit ?? 25) else {
            throw FloeError.validationFailed("Invalid image catalog operation or pagination")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let catalog = try await G09R2AgentGenerationService.shared.catalog(epoch: epoch)
        let routes = args.operation == "edit"
            ? catalog.image.filter { $0.parameters.maxReferenceImages > 0 }
            : catalog.image
        let offset = min(args.offset ?? 0, routes.count)
        let end = min(offset + (args.limit ?? 25), routes.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries: [[String: Any]] = try routes[offset..<end].enumerated().map { index, route in
            let parameters = try JSONSerialization.jsonObject(
                with: encoder.encode(route.parameters))
            let reference: [String: Any] = [
                "supported": route.referenceImagePolicy.maxImages > 0,
                "maximum": route.referenceImagePolicy.maxImages,
                "maxBytesPerImage": route.referenceImagePolicy.maxBytesPerImage,
                "acceptedMimeTypes": route.referenceImagePolicy.acceptedMimeTypes,
            ]
            return [
                "model": route.remoteModelID,
                "modelID": route.routeID,
                "remoteModelID": route.remoteModelID,
                "providerID": route.providerID,
                "providerName": route.providerName,
                "preferred": index + offset == 0,
                "priority": offset + index + 1,
                "enabled": route.enabled,
                "available": route.available,
                "unavailableReason": route.unavailableReason ?? NSNull(),
                "referenceImage": reference,
                "parameters": parameters,
            ]
        }
        let output: [String: Any] = [
            "total": routes.count,
            "models": entries,
            "nextOffset": end < routes.count ? end : NSNull(),
            "policy": "These are the only usable image routes. Pass a public candidate (`model`, its remote model ID) to image.generate; the internal modelID is the legacy alternative and must never be requested from the user. `model` and `modelID` are a mutually exclusive one-of: pass at most one. An explicit selection is exact and never remapped. Only when no selection is given is the preferred route used. Never resubmit a running or outcome-unknown generation; a replayed identical tool call returns the existing durable job.",
        ]
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        guard text.utf8.count <= 262_144 else {
            throw FloeError.validationFailed("Image catalog page is too large; request a smaller limit")
        }
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(text.utf8)),
            exitStatus: 0,
            maximumSummaryCharacters: 262_144)
    }
}

// MARK: - image.generate

public struct G09R2AgentImageGenerateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var prompt: String
        public var count: Int?
        /// Public candidate from image.models (`model` remote ID).
        public var model: String?
        /// Legacy internal UUID; one-of with the public `model`.
        public var modelID: UUID?
        public var size: String?
        public var aspectRatio: String?
        public var resolution: String?
        public var quality: String?
        /// Workspace-relative PNG/JPEG reference image (edit route).
        public var referenceImagePath: String?
    }

    public static let name = "image.generate"
    public static let toolDescription =
        "Generate standalone images with a configured cloud route. Inspect image.models first for the public candidate names (`model`), parameter limits and reference-image support, then pass the public `model` value; only the legacy `modelID` UUID is the alternative, never both. Results are durable: the job survives relaunches, finishes in the background, and delivers readable image files into the task workspace (GeneratedMedia) with measured bytes and SHA-256. Track the returned jobID with video.status (the one status tool covers image and video jobs) and stop it with video.cancel if still non-terminal; a replayed identical call returns the existing job instead of paying twice. Never resubmit a running or outcome-unknown job."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "prompt":{"type":"string","description":"Detailed description of the image to create"},
      "count":{"type":"integer","minimum":1,"maximum":4,"description":"Number of images; default 1"},
      "model":{"type":"string","description":"Public candidate from image.models: its `model` remote ID. One-of with the legacy `modelID`."},
      "modelID":{"type":"string","format":"uuid","description":"Optional legacy internal id from image.models; one-of with the public `model`"},
      "size":{"type":"string","description":"Advanced native size override; use only when supported by image.models"},
      "aspectRatio":{"type":"string","description":"Allowed aspect ratio from image.models"},
      "resolution":{"type":"string","description":"Allowed resolution from image.models"},
      "quality":{"type":"string","description":"Allowed quality from image.models"},
      "referenceImagePath":{"type":"string","description":"Workspace-relative PNG/JPEG reference image; only when image.models reports reference support"}
    },"required":["prompt"],"additionalProperties":false,
    "allOf":[{"not":{"required":["model","modelID"]},"description":"`model` and `modelID` are a mutually exclusive one-of: pass at most one."}]}
    """#
    public static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("prompt must not be empty")
        }
        guard (1...4).contains(args.count ?? 1) else {
            throw FloeError.validationFailed("count must be 1...4")
        }
        if args.model != nil, args.modelID != nil {
            throw FloeError.validationFailed("Use either the public `model` or the legacy `modelID`, not both")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Image generation requires a conversation context")
        }
        guard let root = context.workspaceRootURL else {
            throw FloeError.invalidConfiguration("Image generation requires a task workspace")
        }
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let digest = agentGenerationRequestDigest([
            "prompt": args.prompt,
            "count": args.count ?? 1,
            "model": args.model ?? NSNull(),
            "modelID": args.modelID?.uuidString ?? NSNull(),
            "size": args.size ?? NSNull(),
            "aspectRatio": args.aspectRatio ?? NSNull(),
            "resolution": args.resolution ?? NSNull(),
            "quality": args.quality ?? NSNull(),
            "referenceImagePath": args.referenceImagePath ?? NSNull(),
        ])
        let idempotencyKey = G09R2AgentGenerationService.idempotencyKey(
            runID: context.runID, toolCallID: context.toolCallID,
            requestDigest: digest)
        let summary = try await G09R2AgentGenerationService.shared.submitImage(
            epoch: epoch,
            conversationID: conversationID,
            runID: context.runID,
            idempotencyKey: idempotencyKey,
            workspaceRootURL: root.standardizedFileURL,
            prompt: args.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            selection: args.model,
            legacyModelID: args.modelID,
            count: args.count ?? 1,
            size: args.size,
            aspectRatio: args.aspectRatio,
            resolution: args.resolution,
            quality: args.quality,
            referenceRelativePath: args.referenceImagePath)
        var lines = [
            "status=\(summary.deduplicated ? "existing-job" : "submitted") jobID=\(summary.jobID.uuidString)",
            "state=\(summary.state.rawValue) provider=\(summary.providerName) model=\(summary.remoteModelID)",
        ]
        if let estimate = summary.estimatedCompletionAt {
            lines.append("estimatedCompletionAt=\(ISO8601DateFormatter().string(from: estimate))")
        }
        lines.append(summary.deduplicated
            ? "note=An identical request already exists (possibly already finished); no second paid submission was made. Track the returned jobID with video.status; never resubmit it."
            : "note=Generation runs in the background and delivers into the task workspace; track the jobID with video.status and do not resubmit.")
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}

// MARK: - video.models

public struct G09R2AgentVideoModelsTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var offset: Int?
        public var limit: Int?
    }

    public static let name = "video.models"
    public static let toolDescription =
        "List the configured, enabled and adapter-backed cloud video models. Read this before video.generate: it returns each model's public selection name (`model`, its remote model ID), display name, parameter contract (aspect ratios, resolutions, duration limits, reference-image policy) and availability. Choose the public candidate that fits the request yourself; never ask the user for an internal UUID. Models whose provider has no native video adapter are never listed."
    public static let parametersJSON = #"{"type":"object","properties":{"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard (args.offset ?? 0) >= 0, (1...50).contains(args.limit ?? 25) else {
            throw FloeError.validationFailed("Invalid video catalog pagination")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let catalog = try await G09R2AgentGenerationService.shared.catalog(epoch: epoch)
        let routes = catalog.video
        let offset = min(args.offset ?? 0, routes.count)
        let end = min(offset + (args.limit ?? 25), routes.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries: [[String: Any]] = try routes[offset..<end].enumerated().map { index, route in
            let contract = try JSONSerialization.jsonObject(
                with: encoder.encode(route.parameters))
            let reference: [String: Any] = [
                "supported": route.referenceImagePolicy.maxImages > 0,
                "maximum": route.referenceImagePolicy.maxImages,
                "maxBytesPerImage": route.referenceImagePolicy.maxBytesPerImage,
                "acceptedMimeTypes": route.referenceImagePolicy.acceptedMimeTypes,
            ]
            return [
                "model": route.remoteModelID,
                "modelID": route.routeID,
                "remoteModelID": route.remoteModelID,
                "providerID": route.providerID,
                "providerName": route.providerName,
                "preferred": index + offset == 0,
                "priority": offset + index + 1,
                "enabled": route.enabled,
                "available": route.available,
                "unavailableReason": route.unavailableReason ?? NSNull(),
                "referenceImage": reference,
                "parameters": contract,
            ]
        }
        let output: [String: Any] = [
            "total": routes.count,
            "models": entries,
            "nextOffset": end < routes.count ? end : NSNull(),
            "policy": "These are the only usable video routes. Pass a public candidate (`model` or `modelName`) to video.generate; the internal modelID is optional and must never be requested from the user. Call video.generate once per request and track it with video.status; a replayed identical call returns the existing durable job instead of paying twice, while a new user request creates a new job. Never resubmit a running, timed-out or outcome-unknown job. Reference images are read from the task workspace and sent inline when referenceImage.supported is true.",
        ]
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        guard text.utf8.count <= 262_144 else {
            throw FloeError.validationFailed("Video catalog page is too large; request a smaller limit")
        }
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(text.utf8)),
            exitStatus: 0,
            maximumSummaryCharacters: 262_144)
    }
}

// MARK: - video.generate

public struct G09R2AgentVideoGenerateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var prompt: String
        /// Public candidate from video.models (`model` remote ID).
        public var model: String?
        /// Legacy internal UUID; one-of with the public `model`.
        public var modelID: UUID?
        public var aspectRatio: String?
        public var resolution: String?
        public var durationSeconds: Int?
        public var includeAudio: Bool?
        public var watermark: Bool?
        public var seed: Int?
        /// Workspace-relative PNG/JPEG/WebP reference image.
        public var referenceImagePath: String?
    }

    public static let name = "video.generate"
    public static let toolDescription =
        "Submit one durable cloud video generation job for the current conversation and return its jobID immediately. Read video.models first for the public candidate names (`model`/`modelName`), allowed parameters and reference-image support, then choose the candidate that fits the request yourself; when only one route exists you may omit the selection. Never ask the user for an internal modelID or UUID. Supply at most one workspace-relative reference image (PNG/JPEG/WebP); models without reference support reject it instead of ignoring it. The job survives relaunches: polling resumes and the finished video is delivered into the task workspace (GeneratedMedia). Use video.status to check progress and video.cancel to stop it. A replayed identical call returns the existing job; a distinct later request creates a new job."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "prompt":{"type":"string","description":"Detailed description of the video to create"},
      "model":{"type":"string","description":"Public candidate from video.models: its `model` remote ID or its modelName. One-of with the legacy `modelID`."},
      "modelID":{"type":"string","format":"uuid","description":"Optional legacy internal id from video.models; one-of with the public `model`, which is always preferred"},
      "aspectRatio":{"type":"string","description":"Allowed aspect ratio from video.models"},
      "resolution":{"type":"string","description":"Allowed resolution from video.models"},
      "durationSeconds":{"type":"integer","minimum":1,"maximum":60,"description":"Allowed duration from video.models"},
      "includeAudio":{"type":"boolean","description":"Only when video.models reports audio support"},
      "watermark":{"type":"boolean","description":"Only when video.models reports watermark support"},
      "seed":{"type":"integer","description":"Only when video.models reports seed support"},
      "referenceImagePath":{"type":"string","description":"Workspace-relative PNG/JPEG/WebP reference/first-frame image; only when video.models reports referenceImage.supported"}
    },"required":["prompt"],"additionalProperties":false,
    "allOf":[{"not":{"required":["model","modelID"]},"description":"`model` and `modelID` are a mutually exclusive one-of: pass at most one."}]}
    """#
    public static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("prompt must not be empty")
        }
        if args.model != nil, args.modelID != nil {
            throw FloeError.validationFailed("Use either the public `model` or the legacy `modelID`, not both")
        }
        if let duration = args.durationSeconds, !(1...60).contains(duration) {
            throw FloeError.validationFailed("durationSeconds must be within 1...60")
        }
        if let seed = args.seed, seed < 0 {
            throw FloeError.validationFailed("seed must not be negative")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Video generation requires a conversation context")
        }
        guard let root = context.workspaceRootURL else {
            throw FloeError.invalidConfiguration("Video generation requires a task workspace")
        }
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let digest = agentGenerationRequestDigest([
            "prompt": args.prompt,
            "model": args.model ?? NSNull(),
            "modelID": args.modelID?.uuidString ?? NSNull(),
            "aspectRatio": args.aspectRatio ?? NSNull(),
            "resolution": args.resolution ?? NSNull(),
            "durationSeconds": args.durationSeconds ?? NSNull(),
            "includeAudio": args.includeAudio ?? NSNull(),
            "watermark": args.watermark ?? NSNull(),
            "seed": args.seed ?? NSNull(),
            "referenceImagePath": args.referenceImagePath ?? NSNull(),
        ])
        let idempotencyKey = G09R2AgentGenerationService.idempotencyKey(
            runID: context.runID, toolCallID: context.toolCallID,
            requestDigest: digest)
        var prompt = args.prompt
        prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try await G09R2AgentGenerationService.shared.submitVideo(
            epoch: epoch,
            conversationID: conversationID,
            runID: context.runID,
            idempotencyKey: idempotencyKey,
            workspaceRootURL: root.standardizedFileURL,
            prompt: prompt,
            selection: args.model,
            legacyModelID: args.modelID,
            aspectRatio: args.aspectRatio,
            resolution: args.resolution,
            durationSeconds: args.durationSeconds,
            includeAudio: args.includeAudio,
            watermark: args.watermark,
            seed: args.seed,
            referenceRelativePath: args.referenceImagePath)
        var lines = [
            "status=\(summary.deduplicated ? "existing-job" : "submitted") jobID=\(summary.jobID.uuidString)",
            "state=\(summary.state.rawValue) provider=\(summary.providerName) model=\(summary.remoteModelID)",
        ]
        if let providerTaskID = summary.providerTaskID {
            lines.append("providerTaskID=\(providerTaskID)")
        }
        if let estimate = summary.estimatedCompletionAt {
            lines.append("estimatedCompletionAt=\(ISO8601DateFormatter().string(from: estimate))")
        }
        lines.append(summary.deduplicated
            ? "note=An identical request already exists (possibly already finished); no second paid submission was made. Track the returned jobID with video.status; never resubmit it."
            : "note=Generation runs in the background; poll video.status only as needed and do not resubmit.")
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
    }
}

// MARK: - video.status (the ONE status surface for image and video jobs)

public struct G09R2AgentVideoStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: UUID
        public var refresh: Bool?
    }

    public static let name = "video.status"
    public static let toolDescription =
        "Report the truthful durable state of one image or video generation job owned by this conversation: state, provider task ID, result URL and expiry, and the delivered workspace artifacts — the `artifacts` array gives each file's real path, MIME type, byte count and individual SHA-256 (for a single-artifact result the legacy workspaceArtifact/deliveredBytes/deliveredSHA256 fields mirror it) — plus next poll time and last error. Set refresh=false to read only the stored state. A job may be preparing, submitted, running, downloading, ready, failed, cancelled or expired. A submitted or unknown job is NOT a delivered artifact: only state=ready with workspace artifacts marks the result readable."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"},"refresh":{"type":"boolean"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Video status requires a conversation context")
        }
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let status = try await G09R2AgentGenerationService.shared.status(
            epoch: epoch, conversationID: conversationID,
            jobID: args.jobID, refresh: args.refresh ?? true)
        let iso = ISO8601DateFormatter()
        var output: [String: Any] = [
            "jobID": status.jobID.uuidString,
            "state": status.state.rawValue,
            "terminated": status.terminated,
            "canCancel": status.canCancel,
            "ready": status.ready,
        ]
        if let providerTaskID = status.providerTaskID {
            output["providerTaskID"] = providerTaskID
        }
        if let url = status.resultURL {
            output["resultURL"] = url.absoluteString
        }
        if let expires = status.resultURLExpiresAt {
            output["resultURLExpiresAt"] = iso.string(from: expires)
            output["resultURLExpired"] = expires <= Date()
        }
        if let artifacts = status.artifacts, !artifacts.isEmpty {
            // The typed per-artifact receipt is the authoritative delivery
            // record for one or many outputs.
            output["artifacts"] = artifacts.map { artifact in
                [
                    "path": artifact.relativePath,
                    "mimeType": artifact.mimeType,
                    "bytes": artifact.byteCount,
                    "sha256": artifact.sha256,
                ]
            }
        }
        if let path = status.workspaceRelativePath {
            output["workspaceArtifact"] = path
        }
        if let bytes = status.deliveredByteCount {
            output["deliveredBytes"] = bytes
        }
        if let sha = status.deliveredSHA256 {
            output["deliveredSHA256"] = sha
        }
        if let nextPoll = status.nextPollAt {
            output["nextPollAt"] = iso.string(from: nextPoll)
        }
        if let error = status.lastError {
            output["lastError"] = error
        }
        if status.ready {
            output["note"] = "The result is saved in the conversation workspace (GeneratedMedia) with measured bytes and SHA-256."
        } else if status.state == .expired, status.lastError == "outcomeUnknown",
                  status.mediaKind == "image" {
            // A local interruption is not proof the provider failed. Keep the
            // unknown outcome explicit and never invite a paid resubmission;
            // verified image bytes already in the pinned workspace are
            // reconciled by the durable refresh path.
            output["note"] = "Do not resubmit. The provider outcome is unknown. Any verified output already written by this job is reconciled into the task workspace on refresh; an unknown job is not a delivered artifact."
        } else if status.mediaKind == "image" {
            output["note"] = "Do not resubmit; the durable image job is reconciled on refresh. A submitted or unknown job is not a delivered artifact."
        } else {
            output["note"] = "Do not resubmit; the durable job is polled automatically, including after a relaunch. A submitted or unknown job is not a delivered artifact."
        }
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        return ToolExecutionOutput(digesting: text, exitStatus: status.toolExitStatus)
    }
}

// MARK: - video.cancel (the ONE cancel surface for image and video jobs)

public struct G09R2AgentVideoCancelTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: UUID
    }

    public static let name = "video.cancel"
    public static let toolDescription =
        "Cancel one non-terminal image or video generation job owned by this conversation. The provider is asked to cancel first when a provider task ID exists; the local job settles to cancelled only after the provider confirms, or closes honestly without a provider task was persisted. A cancel that races with completion reports the real outcome instead of claiming success, and a provider cancel failure is an error, not a silent local cancellation. Cancelling a finished job is an error, not a silent no-op."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let conversationID = context.conversationID else {
            throw FloeError.invalidConfiguration("Video cancel requires a conversation context")
        }
        guard let epoch = await agentGenerationEpoch() else {
            throw FloeError.invalidConfiguration("creativeDomainUnavailable")
        }
        let status = try await G09R2AgentGenerationService.shared.cancel(
            epoch: epoch, conversationID: conversationID, jobID: args.jobID)
        var output: [String: Any] = [
            "jobID": status.jobID.uuidString,
            "state": status.state.rawValue,
        ]
        if let error = status.lastError {
            output["note"] = error
        }
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }
}

// MARK: - Registration

/// Registers all six runners (and their catalog descriptors). Idempotent:
/// `ToolRunnerRegistry.register` replaces by name. The central app
/// composition owns WHERE this is called (`G02DomainServices`, next to the
/// existing G09 media-project registration); availability rides the real
/// bound creative generation, so discovery never advertises a route the
/// current build cannot run, while executions still fail honestly when no
/// provider/model route is configured (provider settings stay open without
/// any developer-funding gate).
public enum G09R2AgentGenerationRegistration {
    @discardableResult
    public static func register(
        registry: ToolRunnerRegistry = .shared
    ) -> [String] {
        var names: [String] = []
        func add<T: AgentTool>(_ type: T.Type, _ make: @escaping @Sendable () -> T) {
            ToolCatalog.register(type)
            var runner = AnyAgentTool(make())
            runner.isAvailable = {
                BridgeV5.service.generationAvailability.isAvailable
            }
            registry.register(runner)
            names.append(T.name)
        }
        add(G09R2AgentImageModelsTool.self) { G09R2AgentImageModelsTool() }
        add(G09R2AgentImageGenerateTool.self) { G09R2AgentImageGenerateTool() }
        add(G09R2AgentVideoModelsTool.self) { G09R2AgentVideoModelsTool() }
        add(G09R2AgentVideoGenerateTool.self) { G09R2AgentVideoGenerateTool() }
        add(G09R2AgentVideoStatusTool.self) { G09R2AgentVideoStatusTool() }
        add(G09R2AgentVideoCancelTool.self) { G09R2AgentVideoCancelTool() }
        return names
    }
}
