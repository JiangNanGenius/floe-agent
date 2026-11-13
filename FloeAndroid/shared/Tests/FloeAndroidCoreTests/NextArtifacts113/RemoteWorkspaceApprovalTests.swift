// FloeAndroidCoreTests — N113 approval boundary for remote workspace writes.
//
// Source-only: authored, NOT compiled/executed in this lane. Ordinary
// task-authorized LOCAL text edits keep their deterministic automatic
// approval. A write through an existing network workspace mount (`Network/`)
// is a REMOTE mutation: it must reach the configured reviewer, and when no
// reviewer exists it must escalate to the human instead of silently using the
// local carve-out.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools

private func n113WorkspaceCall(tool: String, path: String) throws -> ToolCall {
    let arguments = try JSONSerialization.data(withJSONObject: ["path": path])
    return try ToolCall(
        id: "call-\(UUID().uuidString)",
        toolName: tool,
        argumentsJSON: arguments,
        scope: .local
    )
}

private func n113Action(tool: String, path: String) throws -> ProposedAction {
    ProposedAction(
        toolCall: try n113WorkspaceCall(tool: tool, path: path),
        riskLabels: ["writesFiles"],
        userGoal: "write the requested text file",
        hostAndPathScope: .local
    )
}

private func n113IsAllow(_ decision: ApprovalDecision) -> Bool {
    if case .allow = decision { return true }
    return false
}

private func n113IsHuman(_ decision: ApprovalDecision) -> Bool {
    if case .escalateToHuman = decision { return true }
    return false
}

struct N113DenyBackend: ModelApprovalPolicy.DecisionBackend {
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .deny(reason: "reviewer refused remote write")
    }
}

struct N113FailingBackend: ModelApprovalPolicy.DecisionBackend {
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        throw FloeError.validationFailed("reviewer unavailable")
    }
}

@Suite("N113 remote workspace write approval")
struct RemoteWorkspaceApprovalTests {

    @Test("ordinary local text edits stay deterministically automatic")
    func localTextEditsRemainAutomatic() async throws {
        let policy = AutomaticApprovalPolicy()
        for tool in ["workspace.createFile", "workspace.writeFile",
                     "workspace.appendFile", "workspace.replaceText",
                     "workspace.applyPatch"] {
            let action = try n113Action(tool: tool, path: "notes/plain.txt")
            let decision = try await policy.decide(action)
            #expect(n113IsAllow(decision), "\(tool) local edit")
            #expect(!policy.requiresModelReview(action))
        }
    }

    @Test("network-mounted workspace writes never use the local automatic carve-out")
    func remoteWorkspaceWritesEscalateWithoutReviewer() async throws {
        let policy = AutomaticApprovalPolicy()
        for tool in ["workspace.createFile", "workspace.writeFile",
                     "workspace.appendFile", "workspace.replaceText",
                     "workspace.applyPatch", "workspace.moveFile"] {
            let action = try n113Action(tool: tool, path: "Network/share/report.txt")
            let decision = try await policy.decide(action)
            #expect(n113IsHuman(decision), "\(tool) remote write")
            #expect(policy.requiresModelReview(action), "\(tool) must request review")
        }
        // Reads are still harmless inspection.
        let read = try n113Action(tool: "workspace.readFile",
                                  path: "Network/share/report.txt")
        let readDecision = try await policy.decide(read)
        #expect(n113IsAllow(readDecision))
    }

    @Test("a configured reviewer is the only automatic path for remote writes")
    func remoteWorkspaceWritesUseConfiguredReviewer() async throws {
        let denied = try await AutomaticApprovalPolicy(backend: N113DenyBackend())
            .decide(n113Action(tool: "workspace.writeFile",
                               path: "Network/share/report.txt"))
        guard case .deny(let reason) = denied else {
            Issue.record("expected the reviewer's deny, got \(denied)")
            return
        }
        #expect(reason.contains("remote"))

        let failed = try await AutomaticApprovalPolicy(backend: N113FailingBackend())
            .decide(n113Action(tool: "workspace.writeFile",
                               path: "Network/share/report.txt"))
        #expect(n113IsHuman(failed))
    }

    @Test("Windows-style separators cannot bypass the remote mount classification")
    func remotePathNormalizationIsStrict() async throws {
        let policy = AutomaticApprovalPolicy()
        let decision = try await policy.decide(
            n113Action(tool: "workspace.writeFile", path: "Network\\share\\report.txt"))
        #expect(n113IsHuman(decision))
    }
}
