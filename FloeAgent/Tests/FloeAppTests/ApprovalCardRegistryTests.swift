// FloeAppTests — Approval card registry: run-scoped retirement, early
// arming, and dedupe. Model call ids are not guaranteed unique across
// concurrent runs; equal callIDs in two runs must never retire each other.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeModels
@testable import FloeApp

@Suite("FloeApp.ApprovalCardRegistry")
@MainActor
struct ApprovalCardRegistryTests {
    private func makeApproval(runID: UUID, callID: String) throws -> PendingApproval {
        try PendingApproval(
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
    func equalCallIDsAcrossRunsAreIndependent() throws {
        let runA = UUID(), runB = UUID()
        let cardA = try makeApproval(runID: runA, callID: "call_dup")
        let cardB = try makeApproval(runID: runB, callID: "call_dup")
        var registry = ApprovalCardRegistry()
        let beganA = registry.beginResolution(cardA)
        let beganB = registry.beginResolution(cardB)
        #expect(beganA)
        #expect(beganB)
        registry.arm(cardA)
        registry.arm(cardB)
        registry.endResolution(cardA)
        registry.endResolution(cardB)

        // A receipt for run A retires only A's card.
        let retiredA = registry.retire(runID: runA, callID: "call_dup")
        let countAfterA = registry.awaiting.count
        let retiredB = registry.retire(runID: runB, callID: "call_dup")
        let countAfterB = registry.awaiting.count
        #expect(retiredA?.runID == runA)
        #expect(countAfterA == 1)
        #expect(retiredB?.runID == runB)
        #expect(countAfterB == 0)
    }

    @Test("A receipt cannot retire an unknown run's card")
    func unknownRunReceiptIsIgnored() throws {
        var registry = ApprovalCardRegistry()
        let card = try makeApproval(runID: UUID(), callID: "call_x")
        registry.arm(card)
        let retired = registry.retire(runID: UUID(), callID: "call_x")
        let remaining = registry.awaiting.count
        #expect(retired == nil)
        #expect(remaining == 1)
    }

    @Test("Arming before suspension keeps a fast receipt from being lost")
    func earlyReceiptIsNotLost() throws {
        var registry = ApprovalCardRegistry()
        let card = try makeApproval(runID: UUID(), callID: "call_fast")
        // Arm happens before the (simulated) suspension: the receipt racing
        // the resolution still finds the card.
        registry.arm(card)
        let retired = registry.retire(runID: card.runID, callID: card.id)
        #expect(retired?.id == card.id)
    }

    @Test("A rejected resolution disarms only its own card")
    func rejectDisarmsOnlyOwnCard() throws {
        var registry = ApprovalCardRegistry()
        let card = try makeApproval(runID: UUID(), callID: "call_rej")
        registry.arm(card)
        registry.disarm(card)
        let afterDisarm = registry.awaiting.isEmpty
        registry.disarm(card)
        let afterSecond = registry.awaiting.isEmpty
        #expect(afterDisarm)
        #expect(afterSecond)
    }

    @Test("The production retirement path cannot remove another run's same-id card")
    func productionRetireScopesByRunAndCall() throws {
        let runA = UUID(), runB = UUID()
        var pending = [
            try makeApproval(runID: runA, callID: "call_dup"),
            try makeApproval(runID: runB, callID: "call_dup")
        ]
        // Hoisted out of #expect autoclosures: the production helper is
        // main-actor isolated and inout mutation cannot happen inside them.
        let retired = ConversationCenter.retireApprovalCard(
            runID: runA, callID: "call_dup", from: &pending
        )
        let countAfterRetire = pending.count
        let firstRun = pending.first?.runID
        // Unknown run+call retires nothing.
        let unknownRetired = ConversationCenter.retireApprovalCard(
            runID: UUID(), callID: "call_dup", from: &pending
        )
        let countAfterUnknown = pending.count
        #expect(retired?.runID == runA)
        #expect(countAfterRetire == 1)
        #expect(firstRun == runB)
        #expect(unknownRetired == nil)
        #expect(countAfterUnknown == 1)
    }

    @Test("Pending membership checks are run-scoped, not id-scoped")
    func productionMembershipScopesByRunAndCall() throws {
        let runA = UUID(), runB = UUID()
        let cards = [
            try makeApproval(runID: runA, callID: "call_dup"),
            try makeApproval(runID: runB, callID: "call_dup")
        ]
        let containsA = cards.contains(where: { $0.matches(runID: runA, callID: "call_dup") })
        let containsUnknown = cards.contains(where: { $0.matches(runID: UUID(), callID: "call_dup") })
        #expect(containsA)
        #expect(!containsUnknown)
    }

    @Test("The moved-on sweep retires only the run whose pending call changed")
    func sweepScopesByRunAndPendingCall() throws {
        var registry = ApprovalCardRegistry()
        let runA = UUID(), runB = UUID()
        let movedA = try makeApproval(runID: runA, callID: "call_a")
        let staysB = try makeApproval(runID: runB, callID: "call_b")
        registry.arm(movedA)
        registry.arm(staysB)

        // Run A moved on to a different pending call; run B still waits on
        // its own call.
        let retired = registry.sweepMovedOn(runID: runA, pendingCallID: "call_next")
        let remaining = registry.awaiting.count
        let sweepB = registry.sweepMovedOn(runID: runB, pendingCallID: "call_b")
        #expect(retired.count == 1)
        #expect(retired.first?.id == "call_a")
        #expect(remaining == 1)
        #expect(sweepB.isEmpty)
    }
}
#endif
