// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

@MainActor
struct MacTaskVideoTools {
    typealias AttachmentLookup = @Sendable (UUID, UUID) async throws -> AttachmentRef?
    let service: MacVideoGeneration
    let admittedRoutes: [(VideoModelRoute, MacVideoGeneration.Configuration)]
    let conversationID: UUID
    let workspace: WorkspaceRecord
    let privateTaskRootBase: URL
    let attachment: AttachmentLookup

    static func make(service: MacVideoGeneration, conversationID: UUID, workspace: WorkspaceRecord,
                     privateTaskRootBase: URL, attachment: @escaping AttachmentLookup) -> [AnyAgentTool] {
        let admittedRoutes = service.taskRoutes
        let access = Self(service: service, admittedRoutes: admittedRoutes, conversationID: conversationID, workspace: workspace,
                          privateTaskRootBase: privateTaskRootBase, attachment: attachment)
        let configured = !admittedRoutes.isEmpty
        return VideoOperation.allCases.compactMap { op in
            guard configured || (op.isTracking && service.hasTaskJobs(conversationID)) else { return nil }
            return AnyAgentTool(descriptor: op.descriptor, run: { data, context in
                let args = try op.decode(data)
                return try await access.run(op, args: args, payload: data, context: context)
            }, validateArguments: { _ = try op.decode($0) })
        }
    }

    private var availableRoutes: [(VideoModelRoute, MacVideoGeneration.Configuration)] {
        let live = service.taskRoutes
        return admittedRoutes.filter { entry in live.contains { $0.0.modelID == entry.0.modelID && $0.1 == entry.1 } }
    }

    private func run(_ op: VideoOperation, args: VideoArguments, payload: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard context.conversationID == conversationID, !context.temporaryReadOnly, !context.publicWebOnly,
              context.childExecution == nil, case .local = context.scope,
              context.callOrigin?.authorizesMainOnlyCapability(toolName: op.rawValue, runID: context.runID, callID: context.toolCallID) == true,
              context.allowedToolNames?.contains(op.rawValue) != false else { throw CocoaError(.fileReadNoPermission) }
        if op.isMutation {
            guard let grant = context.approvalGrantID, let callID = context.toolCallID, !callID.isEmpty,
                  let authority = context.runtimeAuthority, authority.toolName == op.rawValue,
                  authority.runID == context.runID, authority.taskID == conversationID, authority.operationID == callID,
                  authority.approvalGrantID == grant, authority.idempotencyKey == context.toolIdempotencyKey,
                  authority.environmentBinding == RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: context.workspaceRootURL, conversationID: conversationID),
                  authority.payloadDigest == RuntimeAuthorityDigest.payloadDigest(payload) else {
                throw FloeError.validationFailed("Video generation and cancellation require approval for the exact request.")
            }
        }
        switch op {
        case .models:
            let routes = availableRoutes
            let start = min(args.offset ?? 0, routes.count), end = min(start + (args.limit ?? 25), routes.count)
            let models: [[String: Any]] = try routes[start..<end].enumerated().map { index, entry in
                let (route, config) = entry
                let supported = route.contract.maximumReferenceAssets > 0 && VideoReferenceImagePolicy.supportsReferenceImages(
                    providerKind: route.providerKind, modelRemoteID: route.remoteModelID, baseURL: URL(string: config.endpoint))
                let reference: [String: Any] = ["supported": supported, "maximum": supported ? 1 : 0,
                    "mode": route.contract.referenceMode as Any? ?? NSNull(), "upload": "inline-base64"]
                return ["model": route.publicModelID, "modelID": route.modelID.uuidString, "modelName": route.displayName,
                    "remoteModelID": route.remoteModelID, "providerID": route.providerID.uuidString, "providerName": route.providerName,
                    "providerKind": route.providerKind.rawValue, "preferred": route.preferred, "priority": start + index + 1,
                    "referenceImage": reference, "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(route.contract))]
            }
            return try Self.output(["total": routes.count, "models": models, "nextOffset": end < routes.count ? end as Any : NSNull()])
        case .generate:
            return try await submit(args, context: context, digest: RuntimeAuthorityDigest.payloadDigest(payload))
        case .status, .cancel:
            guard let id = args.jobID else { throw FloeError.validationFailed("Missing jobID") }
            let item = try service.ownedTaskJob(id, conversationID: conversationID)
            if op == .cancel {
                let result = try await service.cancelTaskVideo(id, conversationID: conversationID)
                return try await report(result, context: context)
            }
            var providerState: String?, refreshFailed = false
            if args.refresh != false {
                do { providerState = try await service.refreshTaskVideo(item)?.state.rawValue }
                catch { refreshFailed = true }
            }
            return try await report(service.ownedTaskJob(id, conversationID: conversationID), context: context, providerState: providerState, refreshFailed: refreshFailed)
        }
    }

    private func submit(_ args: VideoArguments, context: ToolContext, digest: String) async throws -> ToolExecutionOutput {
        guard let prompt = args.prompt, let callID = context.toolCallID else { throw FloeError.validationFailed("Missing video prompt or tool call.") }
        let id = MacTaskVideoOwner.stableID(conversationID.uuidString + "/" + context.runID.uuidString + "/" + callID)
        if let existing = try service.replayedTaskJob(id, conversationID: conversationID, requestDigest: digest) {
            return try await report(existing, context: context, submitted: false)
        }
        let entries = availableRoutes
        let route = try VideoModelRegistry.resolve(modelID: args.modelID, selection: args.model, routes: entries.map { $0.0 })
        guard let config = entries.first(where: { $0.0.modelID == route.modelID })?.1 else { throw MacVideoGeneration.MacVideoGenerationError.invalidConfiguration }
        let options = try VideoRequestValidator.validate(.init(aspectRatio: args.aspectRatio, resolution: args.resolution,
            durationSeconds: args.durationSeconds, includeAudio: args.includeAudio, seed: args.seed, watermark: args.watermark), route: route)
        if args.referenceImagePath != nil || args.referenceImageAttachmentID != nil {
            guard route.contract.maximumReferenceAssets > 0,
                  VideoReferenceImagePolicy.supportsReferenceImages(providerKind: route.providerKind,
                      modelRemoteID: route.remoteModelID, baseURL: URL(string: config.endpoint)) else {
                throw MacVideoGeneration.MacVideoGenerationError.referenceUnsupported
            }
        }
        let reference = try await referenceBytes(args, context: context)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        let owner = try MacTaskVideoOwner.capture(context: context, jobID: id, digest: digest, workspace: workspace, base: privateTaskRootBase)
        let item = try service.startTaskVideo(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options, config: config, reference: reference, owner: owner)
        return try await report(item, context: context, submitted: true)
    }

    private func referenceBytes(_ args: VideoArguments, context: ToolContext) async throws -> Data? {
        if let path = args.referenceImagePath {
            guard path == (try MacAgentWorkspacePinSupport.standardizedRelativePath(path)), path != "." else { throw CocoaError(.fileReadNoPermission) }
            try context.authorizeWorkspacePath(path)
            return try MacTaskVideoOwner.withRoot(workspace, base: privateTaskRootBase, conversationID: conversationID) { _, root, _ in
                guard let physical = root.physicalPath, context.workspaceRootURL.flatMap({ MacAgentWorkspacePinSupport.physicalPath($0.path) }) == physical
                else { throw CocoaError(.fileReadNoPermission) }
                return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: path, root: root) { pin in
                    let fd = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: path)
                    return try Self.imageData(fd)
                }
            }
        }
        guard let id = args.referenceImageAttachmentID else { return nil }
        guard let ref = try await attachment(conversationID, id), ref.id == id, ref.conversationID == conversationID,
              ref.storage == .securityScopedBookmark, ref.kind == .image, let bookmark = ref.urlBookmark else {
            throw FloeError.notFound("Image attachment in this conversation")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw CocoaError(.fileReadNoPermission) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let bytes = try Self.imageData(fd)
        guard ref.byteCount == bytes.count, ref.sha256 == FloeDigest.sha256Hex(bytes) else {
            throw FloeError.validationFailed("The reference attachment changed. Attach the image again.")
        }
        return bytes
    }

    private static func imageData(_ fd: Int32) throws -> Data {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let limit = VideoReferenceImagePolicy.maximumBytes
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }

    private func report(_ item: MacVideoGeneration.JobItem, context: ToolContext, submitted: Bool? = nil, providerState: String? = nil,
                        refreshFailed: Bool = false) async throws -> ToolExecutionOutput {
        var values: [String: Any] = ["jobID": item.id.uuidString, "state": item.state.rawValue, "mediaKind": "video",
            "terminated": item.state.isTerminal, "ready": item.state == .ready, "canCancel": !item.state.isTerminal]
        if let submitted { values["status"] = submitted ? "submitted" : "existing-job" }
        values["progress"] = item.progress
        values["providerState"] = providerState
        values["lastError"] = item.error
        if refreshFailed { values["refreshError"] = "Unable to refresh the original provider. Showing the saved state." }
        var artifact: ToolArtifactReference?
        if let owner = item.taskOwner, let receipt = item.artifact {
            let allowed = (try? context.authorizeWorkspacePath(receipt.relativePath)) != nil
            if allowed {
                let task = Task.detached(priority: .utility) { [workspace, privateTaskRootBase] in
                    (try? owner.artifactIsAvailable(receipt, workspace: workspace, base: privateTaskRootBase, cancellation: context.cancellation)) == true
                }
                let available = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                try context.cancellation.throwIfCancelled()
                try Task.checkCancellation()
                if available { artifact = receipt; values["localAsset"] = receipt.relativePath }
            }
            values["localAssetAvailable"] = artifact != nil
        }
        return try Self.output(values, artifacts: artifact.map { [$0] } ?? [])
    }

    private static func output(_ value: [String: Any], artifacts: [ToolArtifactReference] = []) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 262_144 else { throw FloeError.validationFailed("Video catalog page too large; reduce limit.") }
        return .init(digesting: String(decoding: data, as: UTF8.self), exitStatus: 0, artifacts: artifacts, maximumSummaryCharacters: 262_144)
    }
}

private struct VideoArguments: Decodable, Sendable {
    let offset, limit: Int?
    let prompt, model, aspectRatio, resolution, referenceImagePath: String?
    let modelID, referenceImageAttachmentID, jobID: UUID?
    let durationSeconds, seed: Int?
    let includeAudio, watermark, refresh: Bool?
}

private enum VideoOperation: String, CaseIterable, Sendable {
    case models = "video.models", generate = "video.generate", status = "video.status", cancel = "video.cancel"
    var isMutation: Bool { self == .generate || self == .cancel }
    var isTracking: Bool { self == .status || self == .cancel }

    func decode(_ data: Data) throws -> VideoArguments {
        let allowed: Set<String>
        switch self {
        case .models: allowed = ["offset","limit"]
        case .generate: allowed = ["prompt","model","modelID","aspectRatio","resolution","durationSeconds","includeAudio","seed","watermark","referenceImagePath","referenceImageAttachmentID"]
        case .status: allowed = ["jobID","refresh"]
        case .cancel: allowed = ["jobID"]
        }
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw FloeError.validationFailed("Invalid arguments for " + rawValue) }
        let args = try JSONDecoder().decode(VideoArguments.self, from: data)
        switch self {
        case .models:
            guard (args.offset ?? 0) >= 0, (1...50).contains(args.limit ?? 25) else { throw FloeError.validationFailed("Invalid catalog page") }
        case .generate:
            guard let prompt = args.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32_768,
                  args.modelID == nil || args.model == nil, args.referenceImagePath == nil || args.referenceImageAttachmentID == nil,
                  (1...60).contains(args.durationSeconds ?? 1), (args.seed ?? 0) >= 0 else { throw FloeError.validationFailed("Invalid video generation parameters") }
        case .status, .cancel:
            guard args.jobID != nil else { throw FloeError.validationFailed("Provide the jobID returned by video.generate") }
        }
        return args
    }

    var descriptor: ToolCatalog.Descriptor {
        let description: String, schema: String, risks: Set<RiskLabel>
        switch self {
        case .models:
            description = "List usable video models, selection names, parameters and reference image support."
            schema = Self.modelsSchema
            risks = []
        case .generate:
            description = "Submit one paid provider video for this conversation and return its durable jobID. Select a public model from video.models. One optional reference image is sent to the provider. Completion saves to GeneratedMedia. Poll video.status; never repeat a request with an unknown outcome."
            schema = Self.generateSchema
            risks = [.sendsDataToProvider, .networkAccess, .writesFiles]
        case .status:
            description = "Read this conversation’s video job, saved artifact and provider status. Set refresh=false for a local-only lookup."
            schema = Self.statusSchema
            risks = [.networkAccess]
        case .cancel:
            description = "Request provider cancellation of one unfinished video job owned by this conversation and report the resulting state."
            schema = Self.cancelSchema
            risks = [.networkAccess]
        }
        return .init(name: rawValue, toolDescription: description, parametersJSON: schema, riskLabels: risks,
                     isSideEffecting: isMutation, effect: isMutation ? .mutating : .readOnly, executionBoundary: .mainRunOnly)
    }
    private static let modelsSchema = #"{"type":"object","properties":{"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    private static let generateSchema = #"""
    {"type":"object","properties":{
      "prompt":{"type":"string","description":"Detailed description of the video to create"},
      "model":{"type":"string","description":"Public candidate from video.models: its `model` remote ID or its modelName. One-of with the legacy `modelID`; choose it yourself when several candidates exist; never ask the user for an internal UUID."},
      "modelID":{"type":"string","format":"uuid","description":"Optional legacy internal id from video.models; one-of with the public `model` value, which is always preferred"},
      "aspectRatio":{"type":"string","description":"Allowed aspect ratio from video.models"},
      "resolution":{"type":"string","description":"Allowed resolution from video.models"},
      "durationSeconds":{"type":"integer","minimum":1,"maximum":60,"description":"Allowed duration from video.models. Veo reference images require 8"},
      "includeAudio":{"type":"boolean","description":"Only when video.models reports supportsAudio"},
      "watermark":{"type":"boolean","description":"Only when video.models reports supportsWatermark"},
      "seed":{"type":"integer","description":"Only when video.models reports supportsSeed"},
      "referenceImagePath":{"type":"string","description":"Workspace-relative PNG/JPEG/WebP image to use as the reference or first frame; only when video.models reports referenceImage.supported"},
      "referenceImageAttachmentID":{"type":"string","format":"uuid","description":"Image attachment from this conversation to use as the reference or first frame; one-of with referenceImagePath"}},
     "required":["prompt"],"additionalProperties":false,
     "allOf":[
       {"not":{"required":["model","modelID"]},"description":"`model` and `modelID` are a mutually exclusive one-of: pass at most one."},
       {"not":{"required":["referenceImagePath","referenceImageAttachmentID"]},"description":"referenceImagePath and referenceImageAttachmentID are a mutually exclusive one-of: pass at most one."}
     ]}
    """#
    private static let statusSchema = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"},"refresh":{"type":"boolean"}},"required":["jobID"],"additionalProperties":false}"#
    private static let cancelSchema = #"{"type":"object","properties":{"jobID":{"type":"string","format":"uuid"}},"required":["jobID"],"additionalProperties":false}"#
}
