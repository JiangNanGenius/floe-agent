// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

/// Frozen public route choices for one conversation; resolve the key again immediately before each provider request.
public struct MacTaskImageTools: Sendable {
    struct Route: Sendable {
        var configuration: MacMediaProviderConfiguration
        var profile: ProviderProfile
        var model: ModelProfile
        var contract: ImageGenerationPresetResolver.ParameterContract {
            ImageGenerationPresetResolver.parameterContract(provider: profile, model: model, operation: .generate)
        }
    }
    let conversationID: UUID
    let autonomous: Bool
    let preferredID: UUID?
    let routes: [Route]
    let available: @MainActor @Sendable (Route) -> Bool
    let request: @Sendable (Route, RemoteImageRequest) async throws -> RemoteImageResult

    struct Attempt: Sendable {
        let route: Route
        let selection: ImageGenerationSelection
        let plan: ImageGenerationBatchPlan
    }

    func attempts(for args: MacTaskImageGenerateTool.Arguments) async throws -> [Attempt] {
        let chosen: UUID?
        if let text = args.model {
            chosen = try ImageModelRouteResolver.resolve(selection: text, models: routes.map(\.model)).id
        } else { chosen = args.modelID }
        guard autonomous || chosen == nil || chosen == preferredID else {
            throw FloeError.validationFailed("Autonomous image routing is disabled. Use the preferred image model.")
        }
        let selected = chosen ?? (autonomous ? nil : preferredID)
        let count = args.count ?? 1
        var attempts: [Attempt] = []
        for route in routes {
            guard selected == nil || selected == route.model.id, await available(route) else { continue }
            if let first = attempts.first, !ImageRouteFallbackPolicy.allowsFallback(explicitSelection: chosen != nil, autonomous: autonomous,
                initialProvider: first.route.profile, candidateProvider: route.profile) { continue }
            let selection = ImageGenerationPresetResolver.applyingDefaults(
                .init(aspectRatio: args.aspectRatio, resolution: args.resolution, quality: args.quality, nativeSizeOverride: args.size),
                provider: route.profile, model: route.model, operation: .generate)
            do {
                try ImageGenerationPresetResolver.validateSelection(selection, provider: route.profile, model: route.model,
                                                                    operation: .generate, count: count, referenceCount: 0)
                let plan = try ImageGenerationBatchPlan(contract: route.contract, requestedCount: count)
                attempts.append(.init(route: route, selection: selection, plan: plan))
            } catch { if selected != nil { throw error } }
            if selected != nil || attempts.count == 2 { break }
        }
        guard !attempts.isEmpty else { throw FloeError.validationFailed("No available image model accepts these parameters. Check image.models.") }
        return attempts
    }
}

struct MacTaskImageModelsTool: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable { let operation: String?; let offset: Int?; let limit: Int? }
    static let name = "image.models"
    static let toolDescription = "List the configured image generation models, public model names, preferred route and supported generation parameters. Select a candidate before calling image.generate."
    static let parametersJSON = #"{"type":"object","properties":{"operation":{"type":"string","enum":["generate"]},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let access: MacTaskImageTools

    func validate(_ args: Arguments) throws {
        guard args.operation == nil || args.operation == "generate", (args.offset ?? 0) >= 0,
              (1...50).contains(args.limit ?? 25) else { throw FloeError.validationFailed("Invalid image catalog parameters.") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard context.conversationID == access.conversationID else { throw FloeError.validationFailed("Wrong conversation.") }
        var entries: [[String: Any]] = []
        for (index, route) in access.routes.enumerated() where await access.available(route) {
            entries.append(["model": route.model.remoteModelID, "modelName": route.model.displayName, "modelID": route.model.id.uuidString,
                            "providerID": route.profile.id.uuidString, "providerName": route.profile.displayName ?? route.profile.kind.rawValue,
                            "providerKind": route.profile.kind.rawValue, "preferred": route.model.id == access.preferredID, "priority": index + 1, "selectable": access.autonomous || route.model.id == access.preferredID,
                            "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(route.contract))])
        }
        let start = min(args.offset ?? 0, entries.count)
        let end = min(start + (args.limit ?? 25), entries.count)
        let data = try JSONSerialization.data(withJSONObject: ["operation":"generate", "autonomyEnabled":access.autonomous, "total":entries.count,
            "models":Array(entries[start..<end]), "nextOffset": end < entries.count ? end as Any : NSNull()], options: [.sortedKeys])
        return ToolExecutionOutput(digesting: String(decoding: data, as: UTF8.self), maximumSummaryCharacters: 262_144)
    }
}

struct MacTaskImageGenerateTool: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable {
        let prompt: String
        let model: String?
        let modelID: UUID?
        let count: Int?
        let aspectRatio: String?
        let resolution: String?
        let quality: String?
        let size: String?
    }
    static let name = "image.generate"
    static let toolDescription = "Generate images with a configured supplier and save the verified files to this conversation's workspace. The request sends the prompt and may incur charges. Choose a public model from image.models. Do not resubmit when a request's outcome is unknown."
    static let parametersJSON = #"""
    {"type":"object","properties":{"prompt":{"type":"string"},"model":{"type":"string","description":"Public candidate from image.models"},"modelID":{"type":"string","format":"uuid"},"count":{"type":"integer","minimum":1,"maximum":4},"size":{"type":"string"},"aspectRatio":{"type":"string"},"resolution":{"type":"string"},"quality":{"type":"string"}},"required":["prompt"],"additionalProperties":false,"allOf":[{"not":{"required":["model","modelID"]}}]}
    """#
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let access: MacTaskImageTools
    private let root: MacAgentWorkspaceRoot
    init(access: MacTaskImageTools, rootURL: URL) { self.access = access; root = .init(rootURL) }

    func validate(_ args: Arguments) throws {
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.prompt.utf8.count <= 32_768, (1...4).contains(args.count ?? 1),
              args.model == nil || args.modelID == nil else {
            throw FloeError.validationFailed("Supply a prompt, 1–4 images and at most one model selector.")
        }
    }
    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        guard argumentsJSON.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
              Set(object.keys).isSubset(of: ["prompt","model","modelID","count","size","aspectRatio","resolution","quality"]),
              context.runtimeAuthority?.payloadDigest == RuntimeAuthorityDigest.payloadDigest(argumentsJSON) else {
            throw FloeError.validationFailed("Image generation requires the approved request parameters.")
        }
        let args = try JSONDecoder().decode(Arguments.self, from: argumentsJSON)
        return try await execute(args, context: context)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard case .local = context.scope, !context.temporaryReadOnly, !context.publicWebOnly,
              let physical = root.physicalPath, let workspaceRoot = context.workspaceRootURL,
              MacAgentWorkspacePinSupport.physicalPath(workspaceRoot.path) == physical,
              context.conversationID == access.conversationID,
              let grant = context.approvalGrantID, let callID = context.toolCallID, !callID.isEmpty,
              let authority = context.runtimeAuthority, authority.toolName == Self.name,
              authority.runID == context.runID, authority.taskID == access.conversationID,
              authority.operationID == callID, authority.idempotencyKey == context.toolIdempotencyKey,
              authority.approvalGrantID == grant, authority.expiresAt > Date(),
              authority.environmentBinding == RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: workspaceRoot, conversationID: access.conversationID),
              context.allowedToolNames?.contains(Self.name) != false else {
            throw FloeError.validationFailed("Image generation requires approval for this call and workspace.")
        }
        let attempts = try await access.attempts(for: args)
        let batch = try MacTaskImageFiles(root: root, context: context, callID: callID, count: args.count ?? 1)
        guard batch.newRequest else { return try batch.replay(context: context) }
        do {
            let (outcome, used) = try await withThrowingTaskGroup(of: (ImageGenerationBatchOutcome, Int).self) { group in
                group.addTask {
                    for (index, attempt) in attempts.enumerated() {
                        let route = attempt.route
                        do {
                            let result = try await ImageGenerationBatchRunner.run(plan: attempt.plan, isCancelled: { context.cancellation.isCancelled || Task.isCancelled }) { chunk in
                                try context.cancellation.throwIfCancelled()
                                let result = try await access.request(route, RemoteImageRequest(operation: .generate, prompt: args.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                    sourceImages: [], selection: attempt.selection, count: chunk, modelRemoteID: route.model.remoteModelID))
                                return .init(images: result.images, revisedPrompt: result.revisedPrompt, metadata: result.metadata)
                            }
                            return (result, index)
                        } catch let error as RemoteImageError where error.allowsRouteFallback && index + 1 < attempts.count {
                            continue
                        }
                    }
                    throw MacImageGeneration.MacImageGenerationError.unsupportedResult
                }
                group.addTask {
                    while !context.cancellation.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            return try batch.save(outcome.images, model: attempts[used].route.model.remoteModelID, fallback: used > 0, context: context)
        } catch let RemoteImageError.providerRejected(status, _) {
            return .init(digesting: MacImageWorkbenchText.t("图像供应商返回 HTTP \(status)。", "The image provider returned HTTP \(status)."), exitStatus: 1, outcomeUnknown: status >= 500 || status == 408)
        } catch {
            if context.cancellation.isCancelled || Task.isCancelled || error is CancellationError { throw CancellationError() }
            return .init(digesting: MacImageWorkbenchText.t("未取得完整的生图结果。请先检查 \(batch.relative)，避免重复计费。", "Image generation stopped before a complete receipt was available. Check \(batch.relative) before submitting again."),
                         exitStatus: 1, outcomeUnknown: true)
        }
    }
}
