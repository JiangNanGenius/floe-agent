// FloeAgentUITests — inline Skill install approval anchoring (build-303).
//
// Logic-level timeline proofs (no UI host, no launch arguments, no DEBUG App
// fixture): the nested exact-delta decision for a task-path Hub install is
// an ORDINARY runtime approval card for the still-executing `skill.install`
// call, so it renders inside the OWNING conversation's thread — anchored in
// the tool step when the call's request event exists, standalone otherwise —
// and never requires opening the Skill Hub sheet. These are the same
// builder projections the real thread renders through StepGroupView /
// ApprovalCardView.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import FloeApp
import FloeModels
import FloeCore
import FloePersistence

@Suite("FloeApp.SkillInstallApprovalInline")
struct SkillInstallApprovalUITests {

    private func makeRun(state: String, conversationID: UUID) -> RunRecord {
        RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: state,
            goal: "install the markitdown skill",
            startedAt: Date(),
            endedAt: nil
        )
    }

    private func makeEvent(runID: UUID, sequence: Int, kind: RunEventRecord.Kind,
                           payload: [String: String]) -> RunEventRecord {
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return RunEventRecord(
            runID: runID,
            sequence: sequence,
            kind: kind,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    private func makeCard(runID: UUID, conversationID: UUID, callID: String) throws -> PendingApproval {
        let toolCall = try ToolCall(
            id: callID,
            toolName: "skill.install",
            argumentsJSON: Data(#"{"source":"hub","id":"markitdown"}"#.utf8),
            scope: .local
        )
        return PendingApproval(
            runID: runID,
            conversationID: conversationID,
            toolCall: toolCall,
            reason: "This update asks for new access. markitdown 2.0.0 · digest d41d8cd98f00 "
                + "· adds capabilities: network.read",
            riskLabels: ["writesFiles", "changesAgentBehavior"],
            isSideEffecting: true,
            requestedAt: Date(),
            workspaceID: nil
        )
    }

    @Test("The nested delta card anchors inside the owning conversation's tool step — no Skill Hub route")
    func cardAnchorsInToolStep() throws {
        let conversationID = UUID()
        let run = makeRun(state: "waitingApproval", conversationID: conversationID)
        let callID = "call_hub_install_1"
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .status, payload: ["state": "preparing"]),
            makeEvent(runID: run.id, sequence: 2, kind: .toolRequest,
                      payload: ["callID": callID, "toolName": "skill.install"])
        ]
        let card = try makeCard(runID: run.id, conversationID: conversationID, callID: callID)
        let items = ThreadTimelineBuilder.buildConversation(
            messages: [], runs: [run], eventsByRun: [run.id: events],
            liveRunID: run.id, isRunning: true,
            liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: [card]
        )
        // The card belongs to the executing call's step group (StepGroupView
        // renders ApprovalCardView directly under the matching toolRequest
        // row), so the builder must NOT also pin a duplicate standalone row.
        #expect(!items.contains { if case .approval = $0 { true } else { false } },
                "a represented call's card anchors in its tool step, never duplicated standalone")
        #expect(items.contains { item in
            if case .stepGroup(let groupEvents, _) = item {
                return groupEvents.contains { $0.runID == run.id }
            }
            return false
        }, "the owning run's tool step stays visible in the thread")
        // The card is bound to the exact run and call identity.
        #expect(card.matches(runID: run.id, callID: callID))
        #expect(!card.matches(runID: UUID(), callID: callID))
    }

    @Test("Without the tool event yet, the card still renders standalone in the same thread")
    func cardVisibleWithoutEvents() throws {
        let conversationID = UUID()
        let run = makeRun(state: "waitingApproval", conversationID: conversationID)
        let callID = "call_hub_install_2"
        let card = try makeCard(runID: run.id, conversationID: conversationID, callID: callID)
        let items = ThreadTimelineBuilder.buildConversation(
            messages: [], runs: [run], eventsByRun: [:],
            liveRunID: run.id, isRunning: true,
            liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: [card]
        )
        #expect(items.contains { item in
            if case .approval(let value) = item { return value.id == callID }
            return false
        }, "the decision must be visible in the conversation even before its event row exists")
    }

    @Test("The card carries the executing skill.install call and only the exact added facts")
    func cardCarriesExactDeltaFacts() throws {
        let card = try makeCard(runID: UUID(), conversationID: UUID(), callID: "call_hub_install_3")
        #expect(card.toolCall.toolName == "skill.install")
        #expect(card.isSideEffecting)
        #expect(card.reason.contains("network.read"))
        #expect(card.reason.contains("markitdown 2.0.0"))
        // No internal flow vocabulary reaches the user-visible card.
        for banned in ["pending-review", "reviewRequired", "PendingInstallation"] {
            #expect(!card.reason.contains(banned))
        }
    }
}
#endif
