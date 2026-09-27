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
        audit: MockAuditSink = MockAuditSink()
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
            sink: MockSink()
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
}
