// SPDX-License-Identifier: MPL-2.0
#if FLOE_MAC_HOST_SMOKE
import Foundation

enum MacPeerWorkbenchSmoke {
    @MainActor
    static func verify(in agent: HostAgentWorkspace, endpoint: URL, root: URL) async -> [String: Any] {
        let folder = root.appendingPathComponent("Sibling collaboration", isDirectory: true)
        let prompt = "Delegate the two independent peer-workbench checks in parallel. Collect both findings."
        await agent.select(nil)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder),
              await agent.setApprovalMode(.ask, asDefault: false),
              agent.startNamedAgentFixture(prompt, modelID: "peer-workbench-fixture", endpoint: endpoint, projectID: project.id)
        else { return ["error": "Failed to start the project fixture"] }

        let permitted = Set(["delegate", "delegate.peers", "delegate.message"])
        var reviewed = Set<String>()
        var unexpected: String?
        let deadline = ContinuousClock.now + .seconds(55)
        while agent.isSending && ContinuousClock.now < deadline {
            if let card = agent.pendingApproval, reviewed.insert(card.callID).inserted {
                guard permitted.contains(card.toolName), card.canAllow else {
                    unexpected = card.toolName
                    await agent.resolveApproval(card, allow: false)
                    break
                }
                await agent.resolveApproval(card, allow: true)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if agent.isSending {
            agent.stop()
            return ["error": unexpected ?? "Peer run did not settle", "reviews": reviewed.sorted(),
                    "diagnostics": agent.smokeRunDiagnostics]
        }
        guard let owner = agent.selectedID, let transcript = try? await agent.transcript(conversationID: owner) else {
            return ["error": "Missing persisted root transcript"]
        }
        let children = await agent.childSubagents(of: owner)
        let users = transcript.filter { $0.role == "user" }.map(\.content)
        let checks = [
            "sameParent": children.count == 2 && Set(children.map(\.id)).count == 2
                && Set(children.map(\.parentRunID)).count == 1 && children.allSatisfy { $0.conversationID == owner },
            "childrenCompleted": children.count == 2 && children.allSatisfy { $0.status == .completed }
                && ["alpha", "beta"].allSatisfy { label in
                    children.contains { $0.findings?.contains("Peer receipt verified by " + label) == true }
                },
            "rootUserInputPreserved": users == [prompt],
            "parentCollectedBoth": transcript.contains { $0.role == "assistant" && $0.content.contains("Parent verified both sibling receipts.") }
        ]
        return ["checks": checks, "root": owner.uuidString, "children": children.map { $0.id.uuidString },
                "childStates": children.map { $0.status.rawValue }, "reviews": reviewed.sorted(),
                "diagnostics": agent.smokeRunDiagnostics]
    }
}
#endif
