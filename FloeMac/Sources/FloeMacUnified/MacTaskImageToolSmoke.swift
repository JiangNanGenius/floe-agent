// SPDX-License-Identifier: MPL-2.0
#if FLOE_MAC_HOST_SMOKE
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

enum MacTaskImageToolSmoke {
    /// A single request through the production OpenAI-compatible adapter to the explicitly supplied local fixture.
    @MainActor static func verify(endpoint: URL, directory: URL) async throws -> [String: Bool] {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let suite = "floe.fixture.task-image." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        defer { prefs.removePersistentDomain(forName: suite) }
        let root = directory.appendingPathComponent(suite)
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = MacImageGeneration(directory: root.appendingPathComponent("Workbench"), namespace: suite,
                                         useKeychain: false, preferences: prefs, admitWork: { {} })
        let task = UUID()
        var checks = ["unconfiguredHidden": service.taskTools(conversationID: task) == nil]
        try service.save(.init(presetID: .openAI, endpoint: endpoint.absoluteString, modelID: "gpt-image-fixture"),
                         apiKey: "floe-image-fixture")
        guard let access = service.taskTools(conversationID: task), let route = access.routes.first else { throw CocoaError(.fileReadUnknown) }
        let catalog = MacTaskImageModelsTool(access: access)
        let tool = MacTaskImageGenerateTool(access: access, rootURL: project)
        let data = try JSONSerialization.data(withJSONObject: ["prompt": "Synthetic task image", "model": "gpt-image-fixture"])
        var context = ToolContext(runID: UUID(), toolCallID: UUID().uuidString, toolIdempotencyKey: "image-call-1",
            approvalGrantID: UUID(), scope: .local, allowedToolNames: [MacTaskImageModelsTool.name, MacTaskImageGenerateTool.name],
            workspaceRootURL: project, cancellation: .init(), conversationID: task)
        context.runtimeAuthority = authority(context: context, payload: data)
        let metadata = try await catalog.run(argumentsJSON: Data("{}".utf8), context: context)
        guard let decoded = try JSONSerialization.jsonObject(with: Data(metadata.summary.utf8)) as? [String: Any],
              let models = decoded["models"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        checks["modelSelectionAndContract"] = models.first?["model"] as? String == "gpt-image-fixture"
            && models.first?["modelID"] as? String == route.model.id.uuidString && models.first?["parameters"] != nil
        var denied = context
        denied.approvalGrantID = nil
        do { _ = try await tool.run(argumentsJSON: data, context: denied); checks["requiresApproval"] = false }
        catch { checks["requiresApproval"] = true }
        denied = context; denied.conversationID = UUID()
        do { _ = try await tool.run(argumentsJSON: data, context: denied); checks["otherConversationDenied"] = false }
        catch { checks["otherConversationDenied"] = true }
        do {
            _ = try await tool.run(argumentsJSON: Data(#"{"prompt":"different"}"#.utf8), context: context)
            checks["payloadBoundToApproval"] = false
        } catch { checks["payloadBoundToApproval"] = true }
        let result = try await tool.run(argumentsJSON: data, context: context)
        guard let artifact = result.artifacts.first, result.exitStatus != 1 else {
            throw FloeError.validationFailed(result.summary)
        }
        let bytes = try Data(contentsOf: project.appendingPathComponent(artifact.relativePath))
        let verifiedFormat = try MacImageGeneration.taskImageFormat(bytes)
        checks["taskFileAndDigest"] = artifact.relativePath.hasPrefix("GeneratedImages/" + task.uuidString + "/")
            && verifiedFormat.mimeType == artifact.mimeType && FloeDigest.sha256Hex(bytes) == artifact.sha256
        checks["workbenchIndependent"] = service.history.isEmpty && !service.isGenerating
        let replay = try await tool.run(argumentsJSON: data, context: context)
        checks["replaySameFile"] = replay.artifacts == result.artifacts
        try Data("Later user edit".utf8).write(to: project.appendingPathComponent(artifact.relativePath))
        let changed = try await tool.run(argumentsJSON: data, context: context)
        let editedFile = try Data(contentsOf: project.appendingPathComponent(artifact.relativePath))
        checks["editedFileNotOverwritten"] = changed.outcomeUnknown && changed.artifacts.isEmpty
            && editedFile == Data("Later user edit".utf8)

        let media = try MacTaskMediaDirectory(root: .init(project), relativeDirectory: "VideoFixture", context: context)
        let sampleURL = root.appendingPathComponent("Input.png")
        try bytes.write(to: sampleURL)
        let source = try FileHandle(forReadingFrom: sampleURL)
        defer { try? source.close() }
        let copy = try media.commit(name: "Source.png", mimeType: "image/png", source: source, maximumBytes: bytes.count, context: context)
        let reopened = try MacTaskMediaDirectory(root: .init(project), relativeDirectory: "VideoFixture", context: context)
        let copyBytes = try reopened.read(name: "Source.png", maximumBytes: bytes.count, context: context)
        checks["streamedExportReopened"] = reopened.identity == media.identity && copy.sha256 == artifact.sha256
            && copyBytes == bytes
        do { _ = try media.commit(name: "Source.png", mimeType: "image/png", data: bytes, context: context); checks["exclusiveCreate"] = false }
        catch { checks["exclusiveCreate"] = true }

        let before = UUID()
        let privateRoot = root.appendingPathComponent("OtherWorkspace")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: privateRoot.appendingPathComponent("GeneratedImages"), withDestinationURL: root)
        var escaped = context
        escaped.workspaceRootURL = privateRoot
        escaped.toolCallID = before.uuidString
        escaped.runtimeAuthority = authority(context: escaped, payload: data)
        do {
            _ = try await MacTaskImageGenerateTool(access: access, rootURL: privateRoot).run(argumentsJSON: data, context: escaped)
            checks["symlinkOutputRefused"] = false
        } catch { checks["symlinkOutputRefused"] = true }

        var alternative = route
        alternative.model.id = UUID()
        alternative.model.remoteModelID = "gpt-image-alternative"
        alternative.model.displayName = "Alternative Fixture"
        let preferredOnly = MacTaskImageTools(conversationID: task, autonomous: false, preferredID: route.model.id,
                                             routes: [route, alternative], available: { _ in true }, request: access.request)
        let explicit = try JSONDecoder().decode(MacTaskImageGenerateTool.Arguments.self,
            from: Data(#"{"prompt":"fixture","model":"alternative fixture"}"#.utf8))
        do { _ = try await preferredOnly.attempts(for: explicit); checks["preferredOnlyEnforced"] = false }
        catch { checks["preferredOnlyEnforced"] = true }
        let attempts = MacTaskImageRequestLog()
        let sameAccount = MacTaskImageTools(conversationID: task, autonomous: true, preferredID: route.model.id,
                                          routes: [route, alternative], available: { _ in true }, request: { chosen, _ in
            await attempts.add(chosen.model.remoteModelID)
            if chosen.model.id == route.model.id { throw RemoteImageError.providerRejected(statusCode: 401, message: "fixture") }
            return RemoteImageResult(images: [bytes])
        })
        let choice = try await sameAccount.attempts(for: explicit)
        checks["publicModelExact"] = choice.count == 1 && choice.first?.route.model.id == alternative.model.id
        let automatic = Data(#"{"prompt":"fixture"}"#.utf8)
        var fallback = context
        fallback.toolCallID = "billing-test"; fallback.toolIdempotencyKey = "billing-test"
        fallback.runtimeAuthority = authority(context: fallback, payload: automatic)
        let fallbackResult = try await MacTaskImageGenerateTool(access: sameAccount, rootURL: project).run(argumentsJSON: automatic, context: fallback)
        let used = await attempts.names
        checks["sameAccountAuthRefusalFallback"] = fallbackResult.artifacts.count == 1
            && used == [route.model.remoteModelID, alternative.model.remoteModelID]
        let delayed = MacTaskImageTools(conversationID: task, autonomous: false, preferredID: route.model.id, routes: [route], available: { _ in true }, request: { _, _ in
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        })
        var cancellable = context
        cancellable.toolCallID = "image-timeout"; cancellable.toolIdempotencyKey = "image-timeout"
        cancellable.cancellation = CancellationToken()
        cancellable.runtimeAuthority = authority(context: cancellable, payload: data)
        let slowContext = cancellable
        let clock = ContinuousClock.now
        let inFlight = Task {
            try await MacTaskImageGenerateTool(access: delayed, rootURL: project).run(argumentsJSON: data, context: slowContext)
        }
        try await Task.sleep(for: .milliseconds(200))
        slowContext.cancellation.cancel()
        do { _ = try await inFlight.value; checks["cancelledInFlight"] = false }
        catch { checks["cancelledInFlight"] = clock.duration(to: .now) < .seconds(3) }
        return checks
    }

    private static func authority(context: ToolContext, payload: Data) -> RuntimeTaskAuthority {
        .init(id: UUID(), runID: context.runID, taskID: context.conversationID,
              environmentBinding: RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: context.workspaceRootURL,
                                                                            conversationID: context.conversationID),
              canonicalTarget: MacTaskImageGenerateTool.name, toolName: MacTaskImageGenerateTool.name, operation: "execute",
              operationID: context.toolCallID!, idempotencyKey: context.toolIdempotencyKey, baseRevision: nil,
              payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload), approvalGrantID: context.approvalGrantID,
              issuedAt: .now, expiresAt: Date(timeIntervalSinceNow: 120))
    }
}
private actor MacTaskImageRequestLog {
    private(set) var names: [String] = []
    func add(_ value: String) { names.append(value) }
}
#endif
