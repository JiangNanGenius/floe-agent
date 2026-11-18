// SPDX-License-Identifier: MPL-2.0
//
// Deterministic unit tests for the short-lived run fence, the task epoch
// carried into side-effecting tools, and the host tool gate. These do not
// touch a database, provider or filesystem.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-core run fence and task epoch")
struct FenceAndTaskEpochTests {

    private func makeEpoch(_ admissionEpoch: UInt64 = 3) -> FloeMacSelfTaskEpoch {
        FloeMacSelfTaskEpoch(
            conversationID: UUID(),
            runID: UUID(),
            admissionEpoch: admissionEpoch
        )
    }

    @Test("A stop before dispatch prevents the durable prepared run from starting")
    func stopBeforeDispatchPreventsCommit() {
        let fence = FloeMacSelfRunFence(taskEpoch: makeEpoch())
        #expect(!fence.prepareDispatch())
        #expect(fence.markPrepared())
        #expect(fence.prepareDispatch())
        _ = fence.recordStopIntent()
        #expect(fence.isStopRequested)
        #expect(!fence.prepareDispatch())
        #expect(!fence.commitDispatch())
        #expect(!fence.dispatchHasStarted)
        #expect(!fence.permitsSideEffectExecution)
    }

    @Test("Approval tokens are invalidated by stop and by settlement")
    func approvalTokensAreFenced() {
        let fence = FloeMacSelfRunFence(taskEpoch: makeEpoch())
        #expect(fence.markPrepared())
        #expect(fence.beginApprovalDecision() == nil)
        #expect(fence.prepareDispatch())
        #expect(fence.commitDispatch())
        let token = fence.beginApprovalDecision()
        #expect(token != nil)
        guard let token else { return }
        #expect(fence.validateApprovalDecision(token))
        _ = fence.recordStopIntent()
        #expect(!fence.validateApprovalDecision(token))
        #expect(fence.beginApprovalDecision() == nil)

        let settledFence = FloeMacSelfRunFence(taskEpoch: makeEpoch())
        _ = settledFence.markPrepared()
        _ = settledFence.prepareDispatch()
        _ = settledFence.commitDispatch()
        let settledToken = settledFence.beginApprovalDecision()
        #expect(settledToken != nil)
        #expect(settledFence.beginSettlement())
        #expect(settledFence.beginApprovalDecision() == nil)
        if let settledToken {
            #expect(!settledFence.validateApprovalDecision(settledToken))
        }
        settledFence.settle(confirmed: false)
        #expect(!settledFence.beginSettlement())
    }

    @Test("The task-epoch wrapper executes once and denies after stop or a stale epoch")
    func wrapperEnforcesEpochAndStop() async throws {
        let epoch = makeEpoch(7)
        let fence = FloeMacSelfRunFence(taskEpoch: epoch)
        #expect(fence.markPrepared())
        #expect(fence.prepareDispatch())
        #expect(fence.commitDispatch())

        let executor = RecordingToolExecutor(descriptors: [SelfCoreFixture.fixtureDescriptor])
        let wrapper = FloeMacSelfFencedToolExecutor(
            wrapping: executor,
            allowedToolNames: [SelfCoreFixture.fixtureToolName],
            fence: fence,
            epoch: epoch
        )
        let call = try SelfCoreFixture.fixtureCall()
        let context = ToolContext(runID: epoch.runID, cancellation: CancellationToken())

        let first = try await wrapper.execute(call, context: context)
        #expect(first.status == .ok)
        #expect(executor.executedCalls.count == 1)

        _ = fence.recordStopIntent()
        let deniedAfterStop = try await wrapper.execute(call, context: context)
        #expect(deniedAfterStop.status == .denied)
        #expect(executor.executedCalls.count == 1)

        let staleEpoch = FloeMacSelfTaskEpoch(
            conversationID: epoch.conversationID,
            runID: epoch.runID,
            admissionEpoch: epoch.admissionEpoch + 1
        )
        let staleWrapper = FloeMacSelfFencedToolExecutor(
            wrapping: executor,
            allowedToolNames: [SelfCoreFixture.fixtureToolName],
            fence: fence,
            epoch: staleEpoch
        )
        let deniedStale = try await staleWrapper.execute(call, context: context)
        #expect(deniedStale.status == .denied)
        #expect(executor.executedCalls.count == 1)
    }

    @Test("A stop after dispatch retains dispatch-started truth for unknown classification")
    func dispatchStartedTruthIsRetained() {
        let fence = FloeMacSelfRunFence(taskEpoch: makeEpoch())
        _ = fence.markPrepared()
        #expect(fence.prepareDispatch())
        #expect(fence.commitDispatch())
        #expect(fence.dispatchHasStarted)
        _ = fence.recordStopIntent()
        #expect(fence.dispatchHasStarted)
        #expect(!fence.permitsSideEffectExecution)
        let snapshot = fence.snapshot
        #expect(snapshot.dispatchStarted)
        #expect(snapshot.stopRequested)
        #expect(snapshot.stopEpoch > 0)
    }

    @Test("Host gate structural validation rejects empty or unbounded provenance")
    func hostGateStructuralValidation() {
        let valid = FloeMacSelfHostGate(
            workspaceID: UUID(),
            workspaceRootPath: "/tmp/fixture-workspace",
            approvalPolicySource: "host.policy.v1",
            toolCorpusIdentifier: "host.tools.v1",
            approvedToolNames: ["fixture.write"],
            issuer: "fixture-tests"
        )
        #expect(valid.isStructurallyValid)

        let emptyTools = FloeMacSelfHostGate(
            workspaceID: valid.workspaceID,
            workspaceRootPath: valid.workspaceRootPath,
            approvalPolicySource: valid.approvalPolicySource,
            toolCorpusIdentifier: valid.toolCorpusIdentifier,
            approvedToolNames: [],
            issuer: valid.issuer
        )
        #expect(!emptyTools.isStructurallyValid)

        let emptyIssuer = FloeMacSelfHostGate(
            workspaceID: valid.workspaceID,
            workspaceRootPath: valid.workspaceRootPath,
            approvalPolicySource: valid.approvalPolicySource,
            toolCorpusIdentifier: valid.toolCorpusIdentifier,
            approvedToolNames: valid.approvedToolNames,
            issuer: ""
        )
        #expect(!emptyIssuer.isStructurallyValid)
    }
}
