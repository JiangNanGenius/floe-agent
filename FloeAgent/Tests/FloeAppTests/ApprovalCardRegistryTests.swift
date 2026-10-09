// FloeAppTests — Approval card registry: run-scoped retirement, early
// arming, and dedupe. Model call ids are not guaranteed unique across
// concurrent runs; equal callIDs in two runs must never retire each other.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.ApprovalCardRegistry")
struct ApprovalCardRegistryTests {
    private func makeApproval(runID: UUID, callID: String) -> PendingApproval {
        PendingApproval(
            runID: runID,
            conversationID: UUID(),
            toolCall: ToolCall(
                id: callID,
                toolName: "workspace.writeFile",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ),
            reason: "test",
            riskLabels: [],
            isSideEffecting: true,
            requestedAt: Date(),
            workspaceID: nil
        )
    }

    @Test("Equal call IDs in two runs never retire each other")
    func equalCallIDsAcrossRunsAreIndependent() {
        let runA = UUID(), runB = UUID()
        let cardA = makeApproval(runID: runA, callID: "call_dup")
        let cardB = makeApproval(runID: runB, callID: "call_dup")
        var registry = ApprovalCardRegistry()
        #expect(registry.beginResolution(cardA))
        #expect(registry.beginResolution(cardB))
        registry.arm(cardA)
        registry.arm(cardB)
        registry.endResolution(cardA)
        registry.endResolution(cardB)

        // A receipt for run A retires only A's card.
        let retiredA = registry.retire(runID: runA, callID: "call_dup")
        #expect(retiredA?.runID == runA)
        #expect(registry.awaiting.count == 1)
        #expect(registry.retire(runID: runB, callID: "call_dup")?.runID == runB)
        #expect(registry.awaiting.isEmpty)
    }

    @Test("A receipt cannot retire an unknown run's card")
    func unknownRunReceiptIsIgnored() {
        var registry = ApprovalCardRegistry()
        let card = makeApproval(runID: UUID(), callID: "call_x")
        registry.arm(card)
        #expect(registry.retire(runID: UUID(), callID: "call_x") == nil)
        #expect(registry.awaiting.count == 1)
    }

    @Test("Arming before suspension keeps a fast receipt from being lost")
    func earlyReceiptIsNotLost() {
        var registry = ApprovalCardRegistry()
        let card = makeApproval(runID: UUID(), callID: "call_fast")
        // Arm happens before the (simulated) suspension: the receipt racing
        // the resolution still finds the card.
        registry.arm(card)
        let retired = registry.retire(runID: card.runID, callID: card.id)
        #expect(retired?.id == card.id)
    }

    @Test("A rejected resolution disarms only its own card")
    func rejectDisarmsOnlyOwnCard() {
        var registry = ApprovalCardRegistry()
        let card = makeApproval(runID: UUID(), callID: "call_rej")
        registry.arm(card)
        registry.disarm(card)
        #expect(registry.awaiting.isEmpty)
        // Disarming an already-retired card is a harmless no-op.
        registry.disarm(card)
        #expect(registry.awaiting.isEmpty)
    }

    @Test("The moved-on sweep retires only the run whose pending call changed")
    func sweepScopesByRunAndPendingCall() {
        var registry = ApprovalCardRegistry()
        let runA = UUID(), runB = UUID()
        let movedA = makeApproval(runID: runA, callID: "call_a")
        let staysB = makeApproval(runID: runB, callID: "call_b")
        registry.arm(movedA)
        registry.arm(staysB)

        // Run A moved on to a different pending call; run B still waits on
        // its own call.
        let retired = registry.sweepMovedOn(runID: runA, pendingCallID: "call_next")
        #expect(retired.count == 1)
        #expect(retired.first?.id == "call_a")
        #expect(registry.awaiting.count == 1)
        #expect(registry.sweepMovedOn(runID: runB, pendingCallID: "call_b").isEmpty)
    }
}
#endif
