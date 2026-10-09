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
        await runtime.resolveApproval(allowDecision())
        await runtime.resolveApproval(.deny(reason: "duplicate tap"))

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
        await runtime.resolveApproval(allowDecision())

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
        await runtime.resolveApproval(.deny(reason: "stale tap"))
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
    /// this exact interleaving.
    private final class GatedApprovalPublishSink: AgentEventSink, @unchecked Sendable {
        let entered = AsyncLock(false)
        let release = AsyncLock(false)
        let cancellingEntered = AsyncLock(false)
        func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
            if state.name == "cancelling" {
                cancellingEntered.withLock { $0 = true }
                return
            }
            guard state.name == "waitingApproval" else { return }
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) {
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
        guard await waitUntil({ sink.entered.withLock { $0 } }) else {
            Issue.record("Runtime never published waitingApproval")
            startTask.cancel()
            sink.release.withLock { $0 = true }
            return
        }
        // Publish still blocked: state is waitingApproval but the
        // continuation is not installed. A pre-fix runtime drops this
        // decision and parks forever.
        await runtime.resolveApproval(allowDecision())
        #expect(await runtime.state.name == "waitingApproval")
        sink.release.withLock { $0 = true }

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
        guard await waitUntil({ sink.entered.withLock { $0 } }) else {
            Issue.record("Runtime never published waitingApproval")
            startTask.cancel()
            sink.release.withLock { $0 = true }
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
        guard await waitUntil({ sink.cancellingEntered.withLock { $0 } }) else {
            Issue.record("Cancel never committed the cancelling transition")
            sink.release.withLock { $0 = true }
            startTask.cancel()
            return
        }
        // Pre-fix: the continuation is not installed when cancel expires the
        // approval, the escalation later parks forever, and cancel wedges
        // awaiting the parked stream task — the run never leaves cancelling.
        sink.release.withLock { $0 = true }

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
}
