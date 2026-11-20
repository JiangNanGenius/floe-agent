// SPDX-License-Identifier: MPL-2.0
#if FLOE_MAC_HOST_SMOKE
import Foundation
import FloeCore
import FloeProviders

enum MacTaskMediaWorkbenchSmoke {
    @MainActor
    private final class FinderFile { var url: URL? }

    @MainActor
    static func verify(in agent: HostAgentWorkspace, endpoint: URL, root: URL,
                       approve: @MainActor () -> Bool) async -> [String: Any] {
        let prompt = "Create one PNG for the task-media-workbench fixture. Inspect image.models, use the configured image model, and save the result to this project."
        let folder = root.appendingPathComponent("Task Media Workbench", isDirectory: true)
        let deadline = ContinuousClock.now + .seconds(45)
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil else {
            return ["error": "Expected a loopback fixture."]
        }
        await agent.select(nil)
        agent.smokeApprovalFrames.removeAll()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder),
              agent.addProvider(name: "Workbench image fixture", endpoint: endpoint.absoluteString,
                  protocolKind: .openAIChatCompletions, modelID: "gpt-image-fixture", key: "floe-image-fixture",
                  presetID: ProviderTemplateID.openAI.rawValue, allowsPlainHTTP: true, role: .image),
              await agent.setApprovalMode(.ask, asDefault: false),
              agent.startNamedAgentFixture(prompt, modelID: "task-media-workbench-fixture", endpoint: endpoint, projectID: project.id)
        else { return ["error": "Failed to start an Agent task with the configured image provider.", "diagnostics": agent.smokeRunDiagnostics] }

        var original: HostAgentApproval?
        var attempts: [Bool] = []
        var cardCleared = false
        func failure(_ message: String) -> [String: Any] {
            func describe(_ card: HostAgentApproval?) -> [String: String] {
                guard let card else { return [:] }
                return ["tool": card.toolName, "call": card.callID, "run": card.runID.uuidString,
                        "conversation": card.conversationID.uuidString, "workspace": card.workspaceID.uuidString,
                        "requestedAt": card.requestedAt.ISO8601Format()]
            }
            let steps = original.flatMap { agent.runToolActivity[$0.runID] } ?? []
            let report: [String: Any] = [
                "error": message, "pending": describe(agent.pendingApproval), "original": describe(original),
                "selected": agent.selectedID?.uuidString ?? "", "selectedProject": agent.selectedConversationWorkspace?.id.uuidString ?? "",
                "windowShowsTask": agent.windowShowsTask, "isSending": agent.isSending, "resolving": agent.isResolvingApproval,
                "phase": String(describing: agent.runPhase), "allowFrame": agent.smokeApprovalFrames[true].map { String(describing: $0) } ?? "",
                "clickDispatch": attempts, "cardCleared": cardCleared, "notice": agent.notice ?? "",
                "steps": steps.map { [$0.id, $0.toolName, $0.state, $0.summary ?? ""] }, "diagnostics": agent.smokeRunDiagnostics
            ]
            if agent.isSending { agent.stop() }
            return report
        }

        while ContinuousClock.now < deadline, agent.isSending {
            if let card = agent.pendingApproval {
                original = card
                guard card.toolName == "image.generate", card.callID == "workbench-generate", card.workspaceID == project.id,
                      agent.selectedID == card.conversationID, agent.selectedConversationWorkspace?.id == project.id,
                      card.canAllow, card.cardRequest.isSideEffecting,
                      card.cardRequest.riskLabels == Set(["sendsDataToProvider","writesFiles"]),
                      let fields = (try? JSONSerialization.jsonObject(with: card.toolCall.argumentsJSON)) as? [String: Any],
                      fields["model"] as? String == "gpt-image-fixture", fields["prompt"] as? String == "Draw the workbench fixture.",
                      fields["count"] as? Int == 1,
                      !FileManager.default.fileExists(atPath: folder.appendingPathComponent("GeneratedImages").path)
                else { return failure("Unexpected approval, task ownership, or workspace contents.") }
                break
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard let approved = original else { return failure("The image generation request never reached the workbench.") }
        var nextClick = ContinuousClock.now
        while ContinuousClock.now < deadline {
            guard agent.selectedID == approved.conversationID, agent.selectedConversationWorkspace?.id == project.id else {
                return failure("The workbench left the approval's owning task.")
            }
            guard let pending = agent.pendingApproval else {
                cardCleared = attempts.contains(true)
                break
            }
            guard pending == approved else { return failure("Another request replaced the original approval.") }
            if agent.windowShowsTask, agent.smokeApprovalFrames[true]?.isEmpty == false,
               !agent.isResolvingApproval, ContinuousClock.now >= nextClick {
                guard attempts.count < 2 else { return failure("The original approval remained after both UI clicks.") }
                attempts.append(approve())
                nextClick = ContinuousClock.now + .seconds(2)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard cardCleared else { return failure("The workbench did not clear the mounted approval after a UI click.") }
        while agent.isSending && ContinuousClock.now < deadline {
            if agent.pendingApproval != nil { return failure("An approval returned after the original card cleared.") }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !agent.isSending, agent.selectedID == approved.conversationID else {
            return failure("Approved run did not settle in the owning conversation.")
        }
        let owner = approved.conversationID
        await agent.select(nil)
        await agent.select(owner)
        await agent.loadVisibleToolActivity(runID: approved.runID, conversationID: owner)
        let steps = agent.runToolActivity[approved.runID] ?? []
        guard let generation = steps.first(where: { $0.id == approved.callID && $0.toolName == "image.generate" }),
              generation.state == "ok", generation.outputWorkspaceID == project.id, generation.mediaArtifacts.count == 1,
              let artifact = generation.mediaArtifacts.first else {
            return ["error": "Reopened execution record has no successful image receipt.",
                    "steps": steps.map { [$0.toolName, $0.state, $0.summary ?? ""] }, "diagnostics": agent.smokeRunDiagnostics]
        }
        let finder = FinderFile()
        await agent.withOutputFile(generation, artifact: artifact) { finder.url = $0 }
        guard let url = finder.url, let bytes = try? Data(contentsOf: url),
              let transcript = try? await agent.transcript(conversationID: owner) else {
            return ["error": "The workspace could not resolve the saved item through the Finder action."]
        }
        let digest = FloeDigest.sha256Hex(bytes)
        let checks = [
            "modelListedImageRoute": steps.contains { $0.id == "workbench-models" && $0.toolName == "image.models" && $0.state == "ok" },
            "paidApprovalClicked": attempts.contains(true) && cardCleared,
            "restoredExecutionArtifact": artifact.relativePath.hasPrefix("GeneratedImages/" + owner.uuidString + "/")
                && artifact.mimeType == "image/png" && artifact.byteCount == bytes.count,
            "finderResolvedOriginalFile": url.resolvingSymlinksInPath() == folder.appendingPathComponent(artifact.relativePath).resolvingSymlinksInPath(),
            "receiptMatchesFileSHA256": digest == artifact.sha256 && bytes.starts(with: [137,80,78,71,13,10,26,10]),
            "modelReceivedToolResult": transcript.contains { $0.role == "assistant" && $0.content.contains("Task media receipt confirmed.") }
        ]
        return ["checks": checks, "conversation": owner.uuidString, "run": approved.runID.uuidString,
                "artifactPath": artifact.relativePath, "receiptSHA256": artifact.sha256, "fileSHA256": digest,
                "byteCount": bytes.count, "clickDispatch": attempts, "cardCleared": cardCleared, "diagnostics": agent.smokeRunDiagnostics]
    }
}
#endif
