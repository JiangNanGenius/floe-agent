// SPDX-License-Identifier: MPL-2.0
#if FLOE_MAC_HOST_SMOKE
import Foundation
import FloeCore
import FloeModels
import FloeTools

@MainActor
enum MacTaskVideoSmoke {
    static func verify(service: MacVideoGeneration, modelID: UUID, base: URL, referenceImage: URL) async throws {
        let taskID = UUID(), other = UUID(), runID = UUID()
        let relative = "PrivateTasks/" + taskID.uuidString
        let root = try MacAgentWorkspaceTools.verifiedPersonalTaskRoot(relativePath: relative, leaseBase: base, createIfNeeded: true)
        let workspace = WorkspaceRecord(id: taskID, name: "Video fixture", rootBookmark: Data(), kind: .privateTask, internalRelativePath: relative)
        let frame = root.appendingPathComponent("frame.png")
        try FileManager.default.copyItem(at: referenceImage, to: frame)
        let tools = MacTaskVideoTools.make(service: service, conversationID: taskID, workspace: workspace, privateTaskRootBase: base) { _,_ in nil }
        let registry = Dictionary(uniqueKeysWithValues: tools.map { ($0.descriptor.name, $0) })
        let authorityStore = RuntimeAuthorityStore()
        func call(_ name: String, _ arguments: [String: Any], _ callID: String, owner: UUID? = nil,
                  approved: Bool = true) async throws -> ToolExecutionOutput {
            guard let tool = registry[name] else { throw FloeError.notFound(name) }
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            let conversation = owner ?? taskID
            let grant = UUID()
            let evidence = RuntimeAuthorityEvidence(runID: runID, taskID: conversation,
                environmentBinding: RuntimeAuthorityDigest.environmentBinding(workspaceRootURL: root, conversationID: conversation),
                canonicalTarget: root.path, toolName: name, operation: name, operationID: callID,
                idempotencyKey: callID, baseRevision: nil, payloadDigest: RuntimeAuthorityDigest.payloadDigest(data), approvalGrantID: grant)
            let authority = approved ? await authorityStore.issue(evidence) : nil
            let context = ToolContext(runID: runID, toolCallID: callID, toolIdempotencyKey: callID,
                approvalGrantID: authority?.approvalGrantID, workspaceRootURL: root, cancellation: .init(), conversationID: conversation,
                runtimeAuthority: authority, callOrigin: .init(kind: .mainRunDelegate, runID: runID, callID: callID, toolName: name))
            return try await tool.run(data, context)
        }
        func wait(_ check: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !check() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
            guard check() else { throw FloeError.validationFailed("Timed out waiting for the local video fixture.") }
        }
        let models = try await call("video.models", [:], "models")
        guard models.summary.contains(modelID.uuidString) else { throw FloeError.validationFailed("Missing video model.") }
        let generate: [String: Any] = ["prompt": "Synthetic clip", "durationSeconds": 5, "modelID": modelID.uuidString,
            "aspectRatio": "16:9", "referenceImagePath": "frame.png"]
        var denied = false
        do { _ = try await call("video.generate", generate, "no-grant", approved: false) } catch { denied = true }
        guard denied else { throw FloeError.validationFailed("Video allowed an unapproved request.") }
        _ = try await call("video.generate", generate, "clip")
        let id = MacTaskVideoOwner.stableID(taskID.uuidString + "/" + runID.uuidString + "/clip")
        try await wait { (try? service.ownedTaskJob(id, conversationID: taskID))?.state == .ready }
        let statusArgs: [String: Any] = ["jobID": id.uuidString, "refresh": false]
        let status = try await call("video.status", statusArgs, "status")
        guard let artifact = status.artifacts.first, artifact.relativePath.hasPrefix("GeneratedMedia/" + taskID.uuidString + "/"),
              FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))) == artifact.sha256 else {
            throw FloeError.validationFailed("The video is missing from its original workspace.")
        }
        let duplicate = try await call("video.generate", generate, "clip")
        guard duplicate.summary.contains("existing-job") else { throw FloeError.validationFailed("The replay lost its receipt.") }
        denied = false
        do { _ = try await call("video.status", statusArgs, "foreign", owner: other) } catch { denied = true }
        guard denied else { throw FloeError.validationFailed("Another conversation could read the job.") }
        denied = false
        do { _ = try service.ownedTaskJob(id, conversationID: other) } catch { denied = true }
        guard denied else { throw FloeError.validationFailed("A foreign job passed the service boundary.") }
        _ = try await call("video.generate", ["prompt": "Cancel fixture", "modelID": modelID.uuidString], "unfinished")
        let cancelID = MacTaskVideoOwner.stableID(taskID.uuidString + "/" + runID.uuidString + "/unfinished")
        try await wait { (try? service.ownedTaskJob(cancelID, conversationID: taskID))?.providerTaskID != nil }
        denied = false
        do { _ = try await service.cancelTaskVideo(cancelID, conversationID: other) } catch { denied = true }
        guard denied else { throw FloeError.validationFailed("Another conversation could cancel the job.") }
        _ = try await call("video.cancel", ["jobID": cancelID.uuidString], "cancel")
        guard try service.ownedTaskJob(cancelID, conversationID: taskID).state == .cancelled else {
            throw FloeError.validationFailed("The provider did not confirm cancellation.")
        }
    }
}
#endif
