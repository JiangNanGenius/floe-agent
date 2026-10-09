// FloeAgentRuntimeTests — Bounded regressions for the human approval
// hand-off: a repeated (double-tap) decision must resume the approved tool
// exactly once, and a decision that arrives after the run left
// `.waitingApproval` must never execute anything.
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

@Suite("FloeAgentRuntime.ApprovalResolution")
struct ApprovalResolutionRaceTests {
    /// Polls until `condition` is true or the timeout expires.
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
        executor: MockExecutor,
        audit: MockAuditSink = MockAuditSink(),
        sink: (any AgentEventSink)? = nil
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            auditSink: audit,
            checkpointStore: MockCheckpointStore(),
            sink: sink ?? MockSink()
        )
    }

    private func registerSideEffectingEcho(in executor: MockExecutor) {
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            riskLabels: [],
            isSideEffecting: true
        )
    }

    private func allowDecision() -> ApprovalDecision {
        .allow(
            scope: ApprovalScope(toolName: "test.echo", singleUse: true),
            expiresAt: nil
        )
    }

    /// Starts a run and returns the completion flag plus the start task. The
    /// caller polls the flag instead of awaiting the task, so a regression can
    /// never turn into an unbounded test-process hang.
    private func startFlagged(
        _ runtime: FloeAgentRuntime,
        finished: AsyncLock<Bool>
    ) -> Task<Void, Error> {
        Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "do it")
        }
    }

    @Test("Repeated human decisions resume the approved tool exactly once")
    func repeatedDecisionExecutesExactlyOnce() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_repeat")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let audit = MockAuditSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested approval")
            startTask.cancel()
            return
        }
        // A double tap / duplicate delivery: the first allow is authoritative,
        // the second decision must not execute the tool again or override it.
        await runtime.resolveApproval(allowDecision(), for: "call_repeat")
        await runtime.resolveApproval(.deny(reason: "duplicate tap"), for: "call_repeat")

        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await startTask.value }

        #expect(settled, "A repeated decision must not park the approved run")
        #expect(executor.executedCalls.count == 1)
        #expect(audit.entries.filter { $0.toolName == "test.echo" && $0.decision.hasPrefix("allow") }.count == 1)
        #expect(await runtime.state.name == "completed")
    }

    @Test("A decision arriving after the run left waitingApproval executes nothing")
    func lateDecisionAfterTerminalStateDoesNotExecute() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_late")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested approval")
            startTask.cancel()
            return
        }
        await runtime.resolveApproval(allowDecision(), for: "call_late")

        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await startTask.value }
        #expect(settled, "The approved run must settle")
        #expect(await runtime.state.name == "completed")
        #expect(executor.executedCalls.count == 1)

        // A stale tap from a card that outlived its run is a no-op.
        await runtime.resolveApproval(.deny(reason: "stale tap"), for: "call_late")
        #expect(executor.executedCalls.count == 1)
        #expect(await runtime.state.name == "completed")
    }

    /// Deterministically reproduces the production stall mechanism: the
    /// runtime publishes `.waitingApproval` (state is set, the durable sink
    /// publish of the run state + approval event is still in flight) and a
    /// human decision / cancellation arrives before the escalation wait
    /// installs its continuation. Before the mailbox fix a decision was
    /// silently dropped and the run parked forever — the same *shape* as the
    /// observed evidence (approval event persisted, no execution, run later
    /// wedged in `cancelling`), though the historic logs alone do not prove
    /// this exact interleaving. The gate is generation-based so every
    /// `waitingApproval` publish blocks until its own generation is released.
    private final class GatedApprovalPublishSink: AgentEventSink, @unchecked Sendable {
        struct GateState: Sendable {
            var entered = 0
            var released = 0
            var cancellingEntered = false
        }
        let gate = AsyncLock(GateState())
        var entered: Int { gate.withLock { $0.entered } }
        var cancellingEntered: Bool { gate.withLock { $0.cancellingEntered } }
        func releaseThrough(_ generation: Int) {
            gate.withLock { $0.released = max($0.released, generation) }
        }
        func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
            if state.name == "cancelling" {
                gate.withLock { $0.cancellingEntered = true }
                return
            }
            guard state.name == "waitingApproval" else { return }
            let generation = gate.withLock { state -> Int in
                state.entered += 1
                return state.entered
            }
            while gate.withLock({ $0.released < generation }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {}
    }

    @Test("A decision racing the approval publish is applied, not dropped")
    func decisionRacingPublishIsApplied() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_race_publish")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let sink = GatedApprovalPublishSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ sink.entered >= 1 }) else {
            Issue.record("Runtime never published waitingApproval")
            startTask.cancel()
            sink.releaseThrough(1)
            return
        }
        // Publish still blocked: state is waitingApproval but the
        // continuation is not installed. A pre-fix runtime drops this
        // decision and parks forever.
        await runtime.resolveApproval(allowDecision(), for: "call_race_publish")
        #expect(await runtime.state.name == "waitingApproval")
        sink.releaseThrough(1)

        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await startTask.value }
        #expect(settled, "A decision racing the publish must not park the run")
        #expect(executor.executedCalls.count == 1)
        #expect(await runtime.state.name == "completed")
    }

    @Test("Cancellation racing the approval publish settles to checkpointed, never wedges in cancelling")
    func cancelRacingPublishSettles() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "call_race_cancel")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let audit = MockAuditSink()
        let sink = GatedApprovalPublishSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, audit: audit, sink: sink)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ sink.entered >= 1 }) else {
            Issue.record("Runtime never published waitingApproval")
            startTask.cancel()
            sink.releaseThrough(1)
            return
        }
        // Start cancellation, then gate the release of the blocked approval
        // publish on the observable cancelling transition so the
        // interleaving is deterministic: cancel commits before the parked
        // escalation resumes.
        let cancelFinished = AsyncLock(false)
        let cancelTask = Task {
            await runtime.cancel()
            cancelFinished.withLock { $0 = true }
        }
        guard await waitUntil({ sink.cancellingEntered }) else {
            Issue.record("Cancel never committed the cancelling transition")
            sink.releaseThrough(1)
            startTask.cancel()
            return
        }
        // Pre-fix: the continuation is not installed when cancel expires the
        // approval, the escalation later parks forever, and cancel wedges
        // awaiting the parked stream task — the run never leaves cancelling.
        sink.releaseThrough(1)

        let settled = await waitUntil(timeout: 8) { finished.withLock { $0 } }
        if settled { _ = try? await startTask.value }
        #expect(settled, "Cancel racing the publish must still settle the run")
        #expect(await runtime.state.name == "checkpointed")
        #expect(executor.executedCalls.isEmpty)
        // The expired approval is audited so recovery never replays it.
        #expect(audit.entries.contains { $0.decision.hasPrefix("deny:cancelled") || $0.decision.hasPrefix("deny") })
        // cancel() itself must return; a bounded wait keeps a regression
        // from wedging the whole suite.
        let cancelSettled = await waitUntil(timeout: 8) { cancelFinished.withLock { $0 } }
        #expect(cancelSettled, "cancel() must return instead of awaiting a parked run forever")
        if cancelSettled { _ = try? await cancelTask.value }
    }

    @Test("An old card's decision never reaches the next escalation: each tool needs its own decision")
    func oldCardDecisionNeverReachesSecondEscalation() async throws {
        let adapter = MockAdapter()
        let first = try TestFixtures.toolCall(id: "call_first")
        let second = try TestFixtures.toolCall(id: "call_second")
        adapter.script = [
            [.toolRequest(first)],
            [.toolRequest(second)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested the first approval")
            startTask.cancel()
            return
        }
        await runtime.resolveApproval(allowDecision(), for: "call_first")
        guard await waitUntil({ executor.executedCalls.count == 1 }) else {
            Issue.record("The approved first tool did not execute")
            startTask.cancel()
            return
        }
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Runtime never requested the second approval")
            startTask.cancel()
            return
        }
        // A stale duplicate for the first card must not authorize the
        // second tool, whether it arrives while parked…
        await runtime.resolveApproval(allowDecision(), for: "call_first")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(executor.executedCalls.count == 1)
        #expect(await runtime.state.name == "waitingApproval")
        // …and the correct decision for the second call still executes
        // exactly once.
        await runtime.resolveApproval(allowDecision(), for: "call_second")
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await startTask.value }
        #expect(settled, "The run must settle after the second decision")
        #expect(executor.executedCalls.count == 2)
        #expect(await runtime.state.name == "completed")
    }

    @Test("A stale first-card decision arriving during the second publish is rejected, not buffered")
    func staleDecisionDuringSecondPublishIsRejected() async throws {
        let adapter = MockAdapter()
        let first = try TestFixtures.toolCall(id: "call_pub_first")
        let second = try TestFixtures.toolCall(id: "call_pub_second")
        adapter.script = [
            [.toolRequest(first)],
            [.toolRequest(second)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerSideEffectingEcho(in: executor)
        let sink = GatedApprovalPublishSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)
        let finished = AsyncLock(false)

        let startTask = startFlagged(runtime, finished: finished)
        guard await waitUntil({ sink.entered >= 1 }) else {
            Issue.record("Runtime never published the first approval")
            startTask.cancel()
            sink.releaseThrough(99)
            return
        }
        await runtime.resolveApproval(allowDecision(), for: "call_pub_first")
        sink.releaseThrough(1)
        guard await waitUntil({ sink.entered >= 2 }) else {
            Issue.record("Runtime never published the second approval")
            startTask.cancel()
            sink.releaseThrough(99)
            return
        }
        // The second publish is blocked. A stale duplicate for the first
        // call arrives now: it must be rejected by call identity instead of
        // being buffered for the second escalation.
        await runtime.resolveApproval(allowDecision(), for: "call_pub_first")
        sink.releaseThrough(2)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(executor.executedCalls.count == 1)
        #expect(await runtime.state.name == "waitingApproval")
        await runtime.resolveApproval(allowDecision(), for: "call_pub_second")
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await startTask.value }
        #expect(settled, "The run must settle after the correct second decision")
        #expect(executor.executedCalls.count == 2)
        #expect(await runtime.state.name == "completed")
    }
}
