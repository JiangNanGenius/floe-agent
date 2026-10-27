import Foundation
import Testing
@testable import FloeAgentRuntime

@Suite("Tool-call preparation presentation")
struct ToolCallPreparationPresentationTests {
    @Test("Preparation cannot mask a stopped or executing run")
    @available(macOS 15.4, iOS 26.0, *)
    func stateAuthority() {
        let progress = AgentLivenessSnapshot(phase: .preparingToolCall, message: "Preparing")
        #expect(ConversationRunService.presentationStateName(
            state: .streamingModel(.init(modelRemoteID: "fixture")),
            isReviewingApproval: false, liveness: progress
        ) == "preparingToolCall")
        let parked = AgentState.checkpointed(.init(reason: "Stopped"))
        #expect(ConversationRunService.presentationStateName(
            state: parked, isReviewingApproval: false, liveness: progress
        ) == "checkpointed")
        #expect(ConversationRunService.presentationStateName(
            state: .cancelling, isReviewingApproval: false, liveness: progress
        ) == "cancelling")
        #expect(ConversationRunService.presentationStateName(
            state: .idle, isReviewingApproval: false, liveness: progress
        ) == "idle")
    }
}
