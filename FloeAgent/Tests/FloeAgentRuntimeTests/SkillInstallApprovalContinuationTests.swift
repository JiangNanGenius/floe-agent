// FloeAgentRuntimeTests — nested (mid-execution) approval continuation for
// the task-path Skill install exact-delta decision (build-303 repair).
//
// Proves the canonical lifecycle participation the standalone broker could
// NOT provide: a still-executing tool call re-enters the runtime's ONE
// `.waitingApproval` state machine through `escalateNestedApproval`, so the
// SAME inline card surface, the SAME `resolveApproval` entry, the durable
// decision receipt, liveness publication and cancellation interruption all
// behave exactly like a pre-dispatch approval — and the SAME tool call then
// resumes in place with the outcome. No second approval store, no tool
// parked outside the run lifecycle, no duplicate durable result on cancel.
//
// Every wait is bounded so a regression reports a failed expectation instead
// of wedging the shared SwiftPM build.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

/// Executor whose side-effecting probe tool consumes the runtime-issued
/// nested-approval seam exactly like the repaired Skill install bridge:
/// it records the issued approval origin, requests ONE nested decision and
/// turns the outcome into its honest tool result — the same call, never a
/// re-dispatch.
private final class NestedProbeExecutor: ToolExecutor, @unchecked Sendable {
    private struct Storage {
        var descriptors: [String: ToolCatalog.Descriptor] = [:]
        var executedCalls: [ToolCall] = []
        var origins: [String] = []
        var nestedOutcomes: [String] = []
        var surfacePresent: [Bool] = []
    }

    private let storage = AsyncLock(Storage())
    /// Reason the probe passes to the nested request; tests assert the run's
    /// waiting payload carries it verbatim.
    var nestedReason: String = "EXACT-DELTA-REASON"
    /// When false the probe only records the issued facts (policy-origin run)
    /// and must never touch the handle.
    var callsNested: Bool = true

    var descriptors: [String: ToolCatalog.Descriptor] {
        get { storage.withLock { $0.descriptors } }
        set { storage.withLock { $0.descriptors = newValue } }
    }
    var executedCalls: [ToolCall] { storage.withLock { $0.executedCalls } }
    var origins: [String] { storage.withLock { $0.origins } }
    var nestedOutcomes: [String] { storage.withLock { $0.nestedOutcomes } }
    var surfacePresent: [Bool] { storage.withLock { $0.surfacePresent } }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        storage.withLock { $0.descriptors[name] }
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        storage.withLock { state in state.descriptors.values.sorted { $0.name < $1.name } }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try context.cancellation.throwIfCancelled()
        let originText: String
        switch context.approvalOrigin {
        case .humanCard: originText = "humanCard"
        case .policy(let name): originText = "policy:\(name)"
        case nil: originText = "nil"
        }
        storage.withLock {
            $0.executedCalls.append(call)
            $0.origins.append(originText)
            $0.surfacePresent.append(context.nestedApproval != nil)
        }
        guard callsNested, let handle = context.nestedApproval else {
            return ToolResult(callID: call.id, status: .ok,
                              outputSummary: "completed-without-nested-prompt", outputDigest: "d")
        }
        let outcome = await handle.request(reason: nestedReason)
        switch outcome {
        case .allowed:
            storage.withLock { $0.nestedOutcomes.append("allowed") }
            return ToolResult(callID: call.id, status: .ok,
                              outputSummary: "installed-after-approval", outputDigest: "d")
        case .denied(let reason):
            storage.withLock { $0.nestedOutcomes.append("denied") }
            return ToolResult(callID: call.id, status: .failed,
                              outputSummary: "declined:\(reason)", outputDigest: "d")
        case .cancelled:
            storage.withLock { $0.nestedOutcomes.append("cancelled") }
            return ToolResult(callID: call.id, status: .cancelled,
                              outputSummary: "cancelled-while-parked", outputDigest: "d")
        case .unavailable:
            storage.withLock { $0.nestedOutcomes.append("unavailable") }
            return ToolResult(callID: call.id, status: .failed,
                              outputSummary: "surface-unavailable", outputDigest: "d")
        }
    }
}

@Suite("FloeAgentRuntime.SkillInstallApprovalContinuation")
struct SkillInstallApprovalContinuationTests {

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: NestedProbeExecutor,
        policy: any ApprovalPolicy,
        audit: MockAuditSink = MockAuditSink(),
        sink: MockSink = MockSink()
    ) -> (FloeAgentRuntime, MockSink, MockAuditSink) {
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                pauseTimeout: 5,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: adapter,
            policy: policy,
            executor: executor,
            auditSink: audit,
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
        return (runtime, sink, audit)
    }

    private func registerProbe(in executor: NestedProbeExecutor) {
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            riskLabels: [],
            isSideEffecting: true
        )
    }

    private func allowDecision() -> ApprovalDecision {
        .allow(scope: ApprovalScope(toolName: "test.echo", singleUse: true), expiresAt: nil)
    }

    private func startFlagged(
        _ runtime: FloeAgentRuntime,
        finished: AsyncLock<Bool>
    ) -> Task<Void, Error> {
        Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "install the skill")
        }
    }

    /// Waits until the run parks in `.waitingApproval` the SECOND time (the
    /// nested card) and returns its payload.
    private func waitNestedApproval(
        _ runtime: FloeAgentRuntime,
        sink: MockSink
    ) async -> AgentState.WaitingApproval? {
        let reached = await waitUntil {
            let state = await runtime.state
            let waitingCount = sink.transitions.filter { $0 == "waitingApproval" }.count
            if case .waitingApproval = state { return waitingCount >= 2 }
            return false
        }
        guard reached else { return nil }
        if case .waitingApproval(let waiting) = await runtime.state { return waiting }
        return nil
    }

    private func toolResult(for callID: String, in sink: MockSink) -> ToolResult? {
        for event in sink.events {
            if case .toolResult(let result) = event, result.callID == callID { return result }
        }
        return nil
    }

    @Test("A nested exact-delta request parks the run in the canonical waiting state and resumes the SAME call")
    func nestedWaitUsesCanonicalLifecycle() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_nested_ok", toolName: "test.echo")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = NestedProbeExecutor()
        registerProbe(in: executor)
        let (runtime, sink, _) = makeRuntime(adapter: adapter, executor: executor,
                                             policy: HumanApprovalPolicy())
        let finished = AsyncLock(false)
        let startTask = startFlagged(runtime, finished: finished)

        // Pre-dispatch card (manual policy) — the ONE native approval for
        // the call itself.
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested the pre-dispatch approval")
            startTask.cancel()
            return
        }
        #expect(await runtime.resolveApproval(allowDecision(), for: "call_nested_ok"))
        // The executing tool now asks its nested exact-delta question: the
        // run must re-enter the SAME canonical waiting state for the SAME
        // call, carrying the tool's reason verbatim.
        guard let waiting = await waitNestedApproval(runtime, sink: sink) else {
            Issue.record("Nested request never reached the canonical waitingApproval state")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        #expect(waiting.toolCall.id == "call_nested_ok")
        #expect(waiting.reason == "EXACT-DELTA-REASON")
        // The canonical resolution entry settles the nested card too.
        #expect(await runtime.resolveApproval(allowDecision(), for: "call_nested_ok"))

        guard await waitUntil({ finished.withLock { $0 } }) else {
            Issue.record("Run never finished after the nested approval")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        _ = try? await startTask.value

        // The SAME call executed exactly once and completed after approval.
        #expect(executor.executedCalls.map(\.id) == ["call_nested_ok"])
        #expect(executor.origins == ["humanCard"])
        #expect(executor.surfacePresent == [true])
        #expect(executor.nestedOutcomes == ["allowed"])
        let result = toolResult(for: "call_nested_ok", in: sink)
        #expect(result?.status == .ok)
        #expect(result?.outputSummary == "installed-after-approval")
        // Both decisions were durably receipted for card retirement: the
        // pre-dispatch receipt and the nested allow receipt.
        #expect(sink.approvalReceipts.filter { $0 == "call_nested_ok" }.count == 2)
        // Canonical terminal state — nothing checkpointed or paused.
        #expect(await runtime.state.name == "completed")
        // The state machine really round-tripped through executingTool.
        #expect(sink.transitions.contains("executingTool"))
        #expect(sink.transitions.filter { $0 == "waitingApproval" }.count >= 2)
    }

    @Test("A nested denial resumes the same call with the honest declined result")
    func nestedDenyResumesSameCall() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_nested_deny", toolName: "test.echo")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = NestedProbeExecutor()
        registerProbe(in: executor)
        let (runtime, sink, _) = makeRuntime(adapter: adapter, executor: executor,
                                             policy: HumanApprovalPolicy())
        let finished = AsyncLock(false)
        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested the pre-dispatch approval")
            startTask.cancel()
            return
        }
        #expect(await runtime.resolveApproval(allowDecision(), for: "call_nested_deny"))
        guard await waitNestedApproval(runtime, sink: sink) != nil else {
            Issue.record("Nested request never parked")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        #expect(await runtime.resolveApproval(.deny(reason: "user denied"), for: "call_nested_deny"))
        guard await waitUntil({ finished.withLock { $0 } }) else {
            Issue.record("Run never finished after the nested denial")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        _ = try? await startTask.value
        #expect(executor.executedCalls.count == 1, "a denial must never re-dispatch the call")
        #expect(executor.nestedOutcomes == ["denied"])
        let result = toolResult(for: "call_nested_deny", in: sink)
        #expect(result?.status == .failed)
        #expect(result?.outputSummary == "declined:user denied")
        #expect(await runtime.state.name == "completed")
    }

    @Test("Cancelling during a nested wait releases the tool promptly with exactly one durable result")
    func cancelDuringNestedWait() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_nested_cancel", toolName: "test.echo")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = NestedProbeExecutor()
        registerProbe(in: executor)
        let audit = MockAuditSink()
        let (runtime, sink, _) = makeRuntime(adapter: adapter, executor: executor,
                                             policy: HumanApprovalPolicy(), audit: audit)
        let finished = AsyncLock(false)
        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested the pre-dispatch approval")
            startTask.cancel()
            return
        }
        #expect(await runtime.resolveApproval(allowDecision(), for: "call_nested_cancel"))
        guard await waitNestedApproval(runtime, sink: sink) != nil else {
            Issue.record("Nested request never parked")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        await runtime.cancel()
        guard await waitUntil({ finished.withLock { $0 } }) else {
            Issue.record("cancel() during a nested wait never released the run — the exact hang class this seam must not reintroduce")
            startTask.cancel()
            return
        }
        _ = try? await startTask.value
        #expect(executor.nestedOutcomes == ["cancelled"])
        // The nested wait is NOT a pre-dispatch expiry: cancel() must skip
        // its "Approval expired" audit for a call that is really executing,
        // so the provider pairing keeps exactly ONE durable result.
        let expiredForCall = sink.events.filter { event in
            if case .toolResult(let result) = event,
               result.callID == "call_nested_cancel", result.status == .expired { return true }
            return false
        }
        #expect(expiredForCall.isEmpty)
        let results = sink.events.filter { event in
            if case .toolResult(let result) = event, result.callID == "call_nested_cancel" { return true }
            return false
        }
        #expect(results.count == 1)
    }

    @Test("A standing-policy grant carries its origin and needs no nested prompt")
    func policyOriginNeedsNoPrompt() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_policy_origin", toolName: "test.echo")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = NestedProbeExecutor()
        executor.callsNested = false
        registerProbe(in: executor)
        let (runtime, sink, _) = makeRuntime(adapter: adapter, executor: executor,
                                             policy: TaskFullAccessPolicy())
        let finished = AsyncLock(false)
        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ finished.withLock { $0 } }) else {
            Issue.record("Full-access run never finished")
            await runtime.cancel()
            _ = try? await startTask.value
            return
        }
        _ = try? await startTask.value
        // The runtime-issued origin tells an executing service that the
        // user's standing policy authorized this call — sufficient effective
        // authority, so no card was shown at all.
        #expect(executor.origins == ["policy:full-access"])
        #expect(executor.surfacePresent == [true], "the seam is issued for every authorized call")
        #expect(!sink.transitions.contains("waitingApproval"))
        let result = toolResult(for: "call_policy_origin", in: sink)
        #expect(result?.outputSummary == "completed-without-nested-prompt")
        #expect(await runtime.state.name == "completed")
    }
}
