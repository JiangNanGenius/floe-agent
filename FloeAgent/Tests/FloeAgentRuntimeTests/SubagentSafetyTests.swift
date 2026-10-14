import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.SubagentSafety")
struct SubagentSafetyTests {
    @Test("delegate is effectful, main-run only and exposes no write override")
    func descriptorIsEffectful() {
        // Children may now execute with the parent's effective ceiling, so the
        // envelope must never claim read-only: a model cannot use delegation
        // as a silent write/approval bypass.
        #expect(DelegateTool.isSideEffecting)
        #expect(DelegateTool.toolEffect == .mutating)
        #expect(DelegateTool.executionBoundary == .mainRunOnly)
        #expect(!DelegateTool.parametersJSON.contains("allowWrites"))
    }

    @Test("delegate fails closed when the shared child budget has no slot")
    func missingBudgetFailsClosed() async throws {
        let provider = TestFixtures.localhostProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: MockAdapter(),
            credentials: ProviderCredentials(),
            executor: MockExecutor()
        )
        let runners = SubagentRunnerRegistry()
        let runID = UUID()
        await runners.register(runner, for: runID)
        let tool = DelegateTool(runners: runners)
        let output = try await tool.execute(
            .init(task: "inspect the workspace"),
            context: ToolContext(
                runID: runID,
                toolCallID: "delegate-budget",
                cancellation: CancellationToken(),
                callOrigin: ToolCallOrigin(
                    kind: .mainRunDelegate, runID: runID, callID: "delegate-budget", toolName: "delegate"
                )
            )
        )

        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("budget is unavailable"))
    }

    @Test("delegate type maps to subagent kind and schema ceiling follows it")
    func typeMappingAndSchemaCeiling() {
        #expect(DelegateTool.parametersJSON.contains("\"enum\": [\"explore\", \"research\", \"execute\"]"))
        let args = DelegateTool.Arguments(task: "t", type: .research)
        #expect(args.type == .research)
        #expect(DelegateTool.Arguments(task: "t", type: .execute).type == .execute)
        // explore (default) strips web/network groups from the child schema.
        #expect(SubagentRequest.Kind.explore != .research)
        #expect(SubagentRequest.Kind.execute != .explore)
        #expect(DelegateTool.Arguments(task: "t").type == nil)
    }

    @Test("child system prompt carries the self-contained handoff contract")
    func handoffContract() {
        let prompt = SubagentRunner.handoffPromptForTesting(kind: .explore, context: "ctx")
        #expect(prompt.contains("receives only your final message"))
        #expect(prompt.contains("self-contained handoff"))
        #expect(prompt.contains("Never address the end user directly"))
        #expect(prompt.contains("ctx"))
        let research = SubagentRunner.handoffPromptForTesting(kind: .research, context: nil)
        #expect(research.contains("web/network"))
    }

    // MARK: - Structured termination (R1)

    private func makeRunner(
        adapter: MockAdapter,
        executor: any ToolExecutor = MockExecutor(),
        provider: ProviderProfile = TestFixtures.localhostProvider()
    ) -> SubagentRunner {
        SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
    }

    private func budgetContext(
        reserve: @escaping @Sendable () async -> Bool = { true },
        finish: @escaping @Sendable () async -> Void = {}
    ) -> ChildBudgetContext {
        ChildBudgetContext(maximumIterations: 6, reserve: reserve, finish: finish)
    }

    private func exploreRequest(maxIterations: Int = 6, runID: UUID = UUID()) -> SubagentRequest {
        SubagentRequest(task: "inspect the workspace", maxIterations: maxIterations, runID: runID)
    }

    @Test("zero-tool completion is a real completed outcome")
    func zeroToolCompletionIsCompleted() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "final answer")), .completed(.init(stopReason: .endTurn))]]
        let runner = makeRunner(adapter: adapter)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        #expect(outcome.iterationsUsed == 1)
        #expect(outcome.findings == "final answer")
        #expect(outcome.unfinished.isEmpty)
        #expect(!outcome.truncated)
    }

    @Test("continuous tool iterations end in a partial outcome with the iteration count")
    func continuousToolCallsEndPartial() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = (0..<5).map { _ in [.toolRequest(call)] }
            + [[.textDelta(.init(text: "wrap-up summary")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .partial)
        // 5 tool iterations + 1 reserved wrap-up slot, all inside the budget.
        #expect(outcome.iterationsUsed == 6)
        #expect(outcome.findings.contains("wrap-up summary"))
        #expect(!outcome.unfinished.isEmpty)
        #expect(!outcome.evidence.isEmpty)
        // The wrap-up pass runs WITHOUT tool schemas.
        #expect(adapter.requests.last?.toolSchemas.isEmpty == true)
    }

    @Test("an exhausted shared budget is a non-success budgetExhausted outcome")
    func sharedBudgetExhaustionIsStructured() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = (0..<4).map { _ in [.toolRequest(call)] }
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        let reserves = AsyncLock(0)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: {
                let count = reserves.withLock { state -> Int in
                    state += 1
                    return state
                }
                return count <= 2
            },
            finish: {}
        )
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .budgetExhausted)
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.findings.contains("budget exhausted"))
    }

    @Test("cancellation maps to a cancelled outcome, not success")
    func cancellationIsStructured() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "never"))]]
        let runner = makeRunner(adapter: adapter)
        let token = CancellationToken()
        token.cancel()
        var context = ToolContext(runID: UUID(), cancellation: token)
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .cancelled)
    }

    @Test("a provider stream error maps to providerError")
    func providerStreamErrorIsStructured() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.error(.init(kind: .server, providerMessage: "upstream exploded"))]]
        let runner = makeRunner(adapter: adapter)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .providerError)
        #expect(outcome.findings.contains("upstream exploded"))
    }

    @Test("a harness output guard maps to toolError")
    func harnessGuardIsToolError() async throws {
        let adapter = MockAdapter()
        let huge = String(repeating: "x", count: 70 * 1024)
        adapter.script = [[.textDelta(.init(text: huge))]]
        let runner = makeRunner(adapter: adapter)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .toolError)
    }

    @Test("an over-long final summary is truncated and says so")
    func summaryTruncationIsMarked() async throws {
        let adapter = MockAdapter()
        let longText = String(repeating: "finding ", count: 3_000) // ~24 KiB
        adapter.script = [[.textDelta(.init(text: longText)), .completed(.init(stopReason: .endTurn))]]
        let runner = makeRunner(adapter: adapter)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        #expect(outcome.truncated)
        #expect(outcome.findings.contains("[summary truncated]"))
        #expect(outcome.findings.utf8.count <= SubagentRunner.maximumSummaryBytes)
    }

    @Test("delegate renders partial as a non-success receipt with diagnostics")
    func delegatePartialIsNonSuccess() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = (0..<5).map { _ in [.toolRequest(call)] }
            + [[.textDelta(.init(text: "partial findings")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let provider = TestFixtures.localhostProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
        let runID = UUID()
        let runners = SubagentRunnerRegistry()
        await runners.register(runner, for: runID)
        let tool = DelegateTool(runners: runners)
        var context = ToolContext(
            runID: runID,
            toolCallID: "delegate-partial",
            cancellation: CancellationToken(),
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate, runID: runID, callID: "delegate-partial", toolName: "delegate"
            )
        )
        context.childBudget = budgetContext()
        let output = try await tool.execute(
            .init(task: "inspect"),
            context: context
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("status=partial"))
        #expect(output.summary.contains("iterationsUsed=6"))
        #expect(output.summary.contains("unfinished:"))
        #expect(output.summary.contains("evidence:"))
    }

    @Test("delegate still reports a real zero-tool completion as ok")
    func delegateCompletedIsSuccess() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: MockExecutor()
        )
        let runID = UUID()
        let runners = SubagentRunnerRegistry()
        await runners.register(runner, for: runID)
        let tool = DelegateTool(runners: runners)
        var context = ToolContext(
            runID: runID,
            toolCallID: "delegate-complete",
            cancellation: CancellationToken(),
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate, runID: runID, callID: "delegate-complete", toolName: "delegate"
            )
        )
        context.childBudget = budgetContext()
        let output = try await tool.execute(.init(task: "answer"), context: context)
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
    }

    @Test("the child slot releases exactly once on success and on error")
    func childSlotReleasesExactlyOnce() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "ok"))]]
        let runner = makeRunner(adapter: adapter)
        let finishes = AsyncLock(0)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: { true },
            finish: { finishes.withLock { $0 += 1 } }
        )
        _ = try await runner.runStructured(exploreRequest(), context: context)
        #expect(finishes.withLock { $0 } == 1)

        let failing = MockAdapter()
        failing.script = [[.error(.init(kind: .server, providerMessage: "boom"))]]
        let failingRunner = makeRunner(adapter: failing)
        var failingContext = ToolContext(runID: UUID(), cancellation: CancellationToken())
        failingContext.childBudget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: { true },
            finish: { finishes.withLock { $0 += 1 } }
        )
        _ = try await failingRunner.runStructured(exploreRequest(), context: failingContext)
        #expect(finishes.withLock { $0 } == 2)
    }

    @Test("parallel child tool calls preserve provider order and the read-only ceiling")
    func parallelChildCallsPreserveOrderAndCeiling() async throws {
        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "read-a")
        let write = try TestFixtures.toolCall(id: "write-b", toolName: "test.write")
        adapter.script = [
            [.toolRequest(read), .toolRequest(write)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        executor.descriptors["test.write"] = .init(name: "test.write", riskLabels: [], isSideEffecting: true)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        let executed = executor.executedCalls.map(\.id)
        #expect(executed == ["read-a"])
        let requests = adapter.requests
        #expect(requests.last?.toolResults.count == 2)
        // Provider order: read result first, denied write result second.
        #expect(requests.last?.toolResults.first?.output == "ok")
        #expect(requests.last?.toolResults.last?.output.contains("Denied") == true)
    }

    // MARK: - R1 review hardening

    @Test("maxIterations 1 never spends a second wrap-up round past the request ceiling")
    func maxIterationsOneIsAHardCeiling() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        // Only ONE provider turn is ever legal; an extra wrap-up turn would
        // consume the empty script and still overrun the requested ceiling.
        adapter.script = [[.toolRequest(call)]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        let reserves = AsyncLock(0)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = ChildBudgetContext(
            maximumIterations: 6,
            reserve: {
                reserves.withLock { $0 += 1 }
                return true
            },
            finish: {}
        )
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 1), context: context)
        // Exactly one iteration (the tool turn), never a reserved wrap-up.
        #expect(outcome.iterationsUsed == 1)
        #expect(reserves.withLock { $0 } == 1)
        #expect(adapter.requests.count == 1)
        // Reaching the request ceiling without an answer is a partial result,
        // honestly — not a fabricated budget exhaustion.
        #expect(outcome.status == .partial)
        #expect(!outcome.evidence.isEmpty)
        #expect(!outcome.unfinished.isEmpty)
    }

    @Test("a second-round provider error preserves completed reads and iteration count")
    func secondRoundProviderErrorPreservesFindings() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = [
            [.toolRequest(call)],
            [.error(.init(kind: .server, providerMessage: "upstream exploded"))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .providerError)
        // The first tool iteration really happened; it is not reset to zero.
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.evidence.count == 1)
        #expect(outcome.findings.contains("upstream exploded"))
        // The route whose result is now unreturned is listed as unfinished.
        #expect(!outcome.unfinished.isEmpty)
    }

    @Test("cancellation after a read executed preserves that read instead of reporting zero")
    func cancellationAfterExecutionPreservesEvidence() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = [[.toolRequest(call)]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let token = CancellationToken()
        // The read runs to completion, then cancellation lands before the
        // next iteration can start.
        executor.executionGate = { token.cancel() }
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: token)
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .cancelled)
        #expect(outcome.iterationsUsed == 1)
        // The read ran but the token cancelled it; the transcript records the
        // real non-success status honestly instead of pretending it succeeded.
        #expect(outcome.evidence == ["test.echo \(SubagentRunner.argumentsDigestForTesting(call)) [failed]"])
    }

    @Test("a thrown adapter transport error is a providerError, not a tool guard")
    func thrownTransportErrorIsProviderError() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = [[.toolRequest(call)]]
        // The second request THROWS at the streaming boundary (transport /
        // adapter failure), not a yielded .error event.
        struct TransportFailure: Error, LocalizedError {
            var errorDescription: String? { "connection reset by peer" }
        }
        adapter.setThrow(TransportFailure(), at: 1)
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .providerError)
        #expect(outcome.iterationsUsed == 2)
        // The completed read from the first round survives.
        #expect(outcome.evidence.count == 1)
        #expect(outcome.findings.contains("connection reset by peer"))
    }

    @Test("a thrown transport error in the wrap-up slot is a providerError with preserved state")
    func wrapUpThrownTransportErrorIsProviderError() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-1")
        adapter.script = [[.toolRequest(call)]]
        struct TransportFailure: Error, LocalizedError {
            var errorDescription: String? { "tls handshake failed" }
        }
        // Index 0 is the tool round; index 1 is the reserved wrap-up pass.
        adapter.setThrow(TransportFailure(), at: 1)
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        // maxIterations 2 keeps a wrap-up slot (toolCeiling: 1).
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 2), context: context)
        #expect(outcome.status == .providerError)
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.evidence.count == 1)
        #expect(outcome.findings.contains("tls handshake failed"))
    }

    /// Deterministic executor: each tool name always returns its scripted
    /// result, independent of parallel completion order.
    private final class StatusScriptedExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var result: ToolResult
            var sideEffecting: Bool
        }
        let entries: [String: Entry]

        init(entries: [String: Entry]) {
            self.entries = entries
        }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? {
            guard let entry = entries[name] else { return nil }
            return ToolCatalog.Descriptor(name: name, riskLabels: [], isSideEffecting: entry.sideEffecting)
        }

        var allDescriptors: [ToolCatalog.Descriptor] {
            entries.map { ToolCatalog.Descriptor(name: $0.key, riskLabels: [], isSideEffecting: $0.value.sideEffecting) }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            entries[call.toolName]?.result
                ?? ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    @Test("denied and failed reads replay with their true status, never rewritten as success")
    func deniedAndFailedReadsKeepTrueStatus() async throws {
        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "read-ok")
        let write = try TestFixtures.toolCall(id: "write-denied", toolName: "test.write")
        let failing = try TestFixtures.toolCall(id: "read-fail", toolName: "test.fail")
        adapter.script = [
            [.toolRequest(read), .toolRequest(write), .toolRequest(failing)],
            [.textDelta(.init(text: "final")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = StatusScriptedExecutor(entries: [
            "test.echo": .init(
                result: ToolResult(callID: "read-ok", status: .ok, outputSummary: "ok", outputDigest: "d"),
                sideEffecting: false
            ),
            "test.write": .init(
                result: ToolResult(callID: "write-denied", status: .ok, outputSummary: "unused", outputDigest: ""),
                sideEffecting: true
            ),
            "test.fail": .init(
                result: ToolResult(callID: "read-fail", status: .failed, outputSummary: "disk error", outputDigest: "d"),
                sideEffecting: false
            )
        ])
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        // Evidence records the real non-success statuses.
        #expect(outcome.evidence.contains { $0.hasPrefix("test.write ") && $0.contains("[denied]") })
        #expect(outcome.evidence.contains { $0.hasPrefix("test.fail ") && $0.contains("[failed]") })
        // The follow-up request fed back the REAL outputs (denied output text
        // and failure summary), not a rewritten "ok".
        let followUp = try #require(adapter.requests.last)
        #expect(followUp.toolResults.count == 3)
        #expect(followUp.toolResults.contains { $0.callID == "read-fail" && $0.output.contains("disk error") })
        #expect(followUp.toolResults.contains { $0.callID == "write-denied" && $0.output.contains("Denied") })
    }

    @Test("an oversized tool output is bounded before entering the replay history with explicit truncation")
    func oversizedToolOutputIsBounded() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "big-read", toolName: "test.big")
        // Five tool-only rounds then the reserved wrap-up (the same shape as
        // the pairing test) so the wrap-up carries the full bounded archive.
        adapter.script = (0..<5).map { _ in [.toolRequest(call)] }
            + [[.textDelta(.init(text: "wrap")), .completed(.init(stopReason: .endTurn))]]
        let huge = String(repeating: "x", count: 80 * 1024)
        // The model's own default cap is 4 KiB; raise it so a genuinely huge
        // tool output reaches the child runner's byte budget.
        let executor = StatusScriptedExecutor(entries: [
            "test.big": .init(
                result: ToolResult(
                    callID: call.id, status: .ok, outputSummary: huge, outputDigest: "d",
                    maximumSummaryCharacters: 96 * 1024
                ),
                sideEffecting: false
            )
        ])
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .partial)
        let wrapUp = try #require(adapter.requests.last)
        #expect(!wrapUp.replayedToolPairs.isEmpty)
        // Every replayed output is under the per-pair cap plus its marker.
        #expect(wrapUp.replayedToolPairs.allSatisfy { $0.result.outputSummary.utf8.count <= 32 * 1024 + 64 })
        #expect(wrapUp.replayedToolPairs.contains { $0.result.outputSummary.contains("[tool output truncated]") })
        // The pair stays protocol-valid: every call id matches its result id.
        #expect(wrapUp.replayedToolPairs.allSatisfy { $0.call.id == $0.result.callID })
        // Dropped history is surfaced as an explicit truncation, never silent.
        #expect(outcome.truncated)
        #expect(outcome.findings.contains("dropped from bounded replay history"))
    }

    @Test("a read that failed then recovered keeps both the failure record and the recovery result")
    func recoveredReadKeepsFailureRecord() async throws {
        let adapter = MockAdapter()
        let first = try TestFixtures.toolCall(id: "read-attempt-1")
        let second = try TestFixtures.toolCall(id: "read-attempt-2")
        adapter.script = [
            [.toolRequest(first)],
            [.toolRequest(second)],
            [.textDelta(.init(text: "recovered")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        // First read fails, the retry succeeds.
        executor.results = [ToolResult(callID: "read-attempt-1", status: .failed, outputSummary: "transient", outputDigest: "d1")]
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        // Both attempts are individually identified by their argument digests;
        // the failed attempt keeps its [failed] marker even after recovery.
        let firstRoute = "test.echo \(SubagentRunner.argumentsDigestForTesting(first)) [failed]"
        let secondRoute = "test.echo \(SubagentRunner.argumentsDigestForTesting(second))"
        #expect(outcome.evidence.contains(firstRoute))
        #expect(outcome.evidence.contains(secondRoute))
        let finalTurn = try #require(adapter.requests.last)
        // The failed attempt is archived with its real status; the recovered
        // attempt is still the current pending pair's result.
        #expect(finalTurn.replayedToolPairs.contains {
            $0.call.id == "read-attempt-1" && $0.result.status == .failed
        })
        #expect(finalTurn.toolResults.contains { $0.callID == "read-attempt-2" && $0.output == "ok" })
    }

    @Test("the wrap-up request keeps tool_use/tool_result paired and only removes tool schemas")
    func wrapUpRequestKeepsToolPairsOnEveryWire() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "read-pair-1")
        adapter.script = (0..<5).map { _ in [.toolRequest(call)] }
            + [[.textDelta(.init(text: "wrap answer")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .partial)
        #expect(outcome.iterationsUsed == 6)

        // The wrap-up is the last request the adapter received. With the
        // settled-pair archive the wrap-up carries EVERY settled call —
        // including the newest pair archived from pending — in
        // replayedToolPairs (all 5 tool turns survive), each paired with its
        // output, and offers no tools and no pending pair.
        let wrapUp = try #require(adapter.requests.last)
        #expect(wrapUp.toolResults.isEmpty)
        #expect(wrapUp.pendingToolCalls.isEmpty)
        #expect(wrapUp.replayedToolPairs.count == 5)
        #expect(wrapUp.replayedToolPairs.allSatisfy { $0.call.id == "read-pair-1" })
        #expect(wrapUp.replayedToolPairs.allSatisfy { $0.result.callID == $0.call.id })
        #expect(wrapUp.toolSchemas.isEmpty)
        // Compat-name mapping stays total over the original ceiling even
        // though schemas are empty.
        #expect(wrapUp.allToolNames == ["test.echo"])

        // Render the archived pair through the REAL wire DTOs to prove
        // call/result pairing on every protocol (an orphan result is a
        // protocol error), then rebuild the call through WireTranslator.
        let keptCall = wrapUp.replayedToolPairs[0].call
        let keptResult = wrapUp.replayedToolPairs[0].result

        // Chat Completions: assistant tool_calls + role=tool both carry the id.
        let chatMessages = [
            ChatRequest.Message(
                role: "assistant",
                toolCalls: [ChatRequest.Message.ToolCall(
                    id: keptCall.id,
                    function: .init(name: keptCall.toolName, arguments: String(decoding: keptCall.argumentsJSON, as: UTF8.self))
                )]
            ),
            ChatRequest.Message(role: "tool", content: keptResult.outputSummary, toolCallID: keptResult.callID)
        ]
        let chatRequest = ChatRequest(model: "model", messages: chatMessages, tools: [])
        #expect(chatRequest.messages.contains { $0.toolCalls?.first?.id == "read-pair-1" })
        #expect(chatRequest.messages.contains { $0.role == "tool" && $0.toolCallID == "read-pair-1" })
        #expect(chatRequest.tools?.isEmpty == true)

        // Anthropic: assistant tool_use + user tool_result share the id.
        let anthropicBlocks: [AnthropicContent] = [
            .toolUse(id: keptCall.id, name: keptCall.toolName, inputJSON: String(decoding: keptCall.argumentsJSON, as: UTF8.self)),
            .toolResult(toolUseID: keptResult.callID, content: keptResult.outputSummary, isError: false)
        ]
        #expect(anthropicBlocks.contains {
            if case .toolUse(let id, _, _) = $0 { return id == "read-pair-1" }
            return false
        })
        #expect(anthropicBlocks.contains {
            if case .toolResult(let id, _, _) = $0 { return id == "read-pair-1" }
            return false
        })

        // Inbound sanity: WireTranslator builds a ToolCall with the same id,
        // proving the neutral call the runner kept is a real, valid call.
        let item = FunctionCallItem(
            callID: keptCall.id,
            name: keptCall.toolName,
            arguments: String(decoding: keptCall.argumentsJSON, as: UTF8.self)
        )
        guard case .toolRequest(let rebuilt) = WireTranslator.translate(.outputItemDoneFunctionCall(item)).first else {
            Issue.record("expected a tool request for the kept call")
            return
        }
        #expect(rebuilt.id == "read-pair-1")
        #expect(keptResult.callID == rebuilt.id)
    }

    @Test("settled pairs from earlier iterations stay in bounded context across a 3-turn search→readA→readB chain")
    func settledPairsPersistAcrossMultipleTurns() async throws {
        // Directly prove the archive keeps a settled pair with its reasoning
        // AND its real status into the next request, before the full chain.
        var replayed: [ReplayedToolPair] = []
        var dropped = 0
        let searchCall = try TestFixtures.toolCall(id: "search-1", toolName: "test.echo", arguments: #"{"q":"floe"}"#)
        let failedResult = ToolResult(callID: "search-1", status: .failed, outputSummary: "boom", outputDigest: "d1")
        SubagentRunner.archiveSettledPairs(
            into: &replayed, droppedCount: &dropped,
            priorSettled: [(call: searchCall, result: failedResult)],
            priorReasoning: "plan search"
        )
        #expect(replayed.map { $0.call.id } == ["search-1"])
        #expect(replayed[0].assistantReasoning == "plan search")
        #expect(replayed[0].result.callID == "search-1")
        // A failed read is NEVER rewritten as success in the replayed history.
        #expect(replayed[0].result.status == .failed)
        #expect(replayed[0].result.outputDigest == "d1")

        let adapter = MockAdapter()
        let search = try TestFixtures.toolCall(id: "search-1", toolName: "test.echo", arguments: #"{"q":"floe"}"#)
        let readA = try TestFixtures.toolCall(id: "read-a", arguments: #"{"n":"a"}"#)
        let readB = try TestFixtures.toolCall(id: "read-b", arguments: #"{"n":"b"}"#)
        adapter.script = [
            [.reasoningSummary(.init(text: "plan search")), .toolRequest(search)],
            [.reasoningSummary(.init(text: "plan read A")), .toolRequest(readA)],
            [.reasoningSummary(.init(text: "plan read B")), .toolRequest(readB)],
            [.textDelta(.init(text: "synthesized")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)

        // Turn 2 (the readA turn) must still carry the settled search pair:
        // as the CURRENT pending pair (call + its output + its reasoning).
        let turn2 = adapter.requests[1]
        #expect(turn2.pendingToolCalls.map(\.id) == ["search-1"])
        #expect(turn2.toolResults.map(\.callID) == ["search-1"])
        #expect(turn2.pendingAssistantReasoning == "plan search")
        #expect(turn2.replayedToolPairs.isEmpty)

        // Turn 3 (the readB turn) archives search into the bounded replay
        // history (with its reasoning) and keeps readA as the current pending
        // pair — so search and readA both stay in context, readB is pending.
        let turn3 = adapter.requests[2]
        #expect(turn3.replayedToolPairs.map { $0.call.id } == ["search-1"])
        #expect(turn3.replayedToolPairs[0].assistantReasoning == "plan search")
        #expect(turn3.replayedToolPairs[0].result.callID == "search-1")
        #expect(turn3.pendingToolCalls.map(\.id) == ["read-a"])
        #expect(turn3.toolResults.map(\.callID) == ["read-a"])
        #expect(turn3.pendingAssistantReasoning == "plan read A")

        // The final (success) turn carries the full bounded history: search
        // and readA replayed with reasoning, readB as the newest pending pair.
        let turn4 = adapter.requests[3]
        #expect(turn4.replayedToolPairs.map { $0.call.id } == ["search-1", "read-a"])
        #expect(turn4.replayedToolPairs.map { $0.assistantReasoning } == ["plan search", "plan read A"])
        #expect(turn4.replayedToolPairs.allSatisfy { $0.result.callID == $0.call.id })
        #expect(turn4.pendingToolCalls.map(\.id) == ["read-b"])
        #expect(turn4.toolResults.map { $0.callID } == ["read-b"])
        #expect(turn4.pendingAssistantReasoning == "plan read B")
        #expect(turn4.allToolNames == ["test.echo"])

        // Render the final request's ENTIRE replayed context through the real
        // wire DTOs the adapters consume: search's and readA's content (their
        // call ids, arguments and bounded outputs) must be present and paired
        // on the wire — not just a replay-array count.
        var chatMessages: [ChatRequest.Message] = []
        var anthropicBlocks: [AnthropicContent] = []
        for pair in turn4.replayedToolPairs {
            let arguments = String(decoding: pair.call.argumentsJSON, as: UTF8.self)
            chatMessages.append(ChatRequest.Message(
                role: "assistant",
                toolCalls: [.init(id: pair.call.id, function: .init(name: pair.call.toolName, arguments: arguments))]
            ))
            chatMessages.append(ChatRequest.Message(
                role: "tool", content: pair.result.outputSummary, toolCallID: pair.result.callID
            ))
            anthropicBlocks.append(.toolUse(id: pair.call.id, name: pair.call.toolName, inputJSON: arguments))
            anthropicBlocks.append(.toolResult(
                toolUseID: pair.result.callID, content: pair.result.outputSummary, isError: false
            ))
        }
        // readA specifically survives into the final wire-ready context with
        // its arguments and output.
        #expect(chatMessages.contains {
            $0.toolCalls?.first?.id == "read-a"
                && $0.toolCalls?.first?.function.arguments.contains(#""n":"a""#) == true
        })
        #expect(chatMessages.contains { $0.role == "tool" && $0.toolCallID == "read-a" && $0.content == .text("ok") })
        #expect(anthropicBlocks.contains {
            if case .toolUse(let id, _, let inputJSON) = $0 {
                return id == "read-a" && inputJSON.contains(#""n":"a""#)
            }
            return false
        })
        #expect(anthropicBlocks.contains {
            if case .toolResult(let id, let content, _) = $0 { return id == "read-a" && content == "ok" }
            return false
        })
    }

    // MARK: - R1 request-budget hardening (wire-ready proof)

    /// Deterministic executor returning one large output bound to the REAL
    /// call id, so call/result pairing stays assertable for big batches.
    private final class OutputBoundExecutor: ToolExecutor, @unchecked Sendable {
        let output: String
        let status: ToolResult.Status
        private let descriptors: [String: ToolCatalog.Descriptor]

        init(toolNames: [String], output: String, status: ToolResult.Status = .ok) {
            self.output = output
            self.status = status
            self.descriptors = Dictionary(uniqueKeysWithValues: toolNames.map {
                ($0, ToolCatalog.Descriptor(name: $0, riskLabels: [], isSideEffecting: false))
            })
        }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            ToolResult(
                callID: call.id,
                status: status,
                outputSummary: output,
                outputDigest: "d",
                maximumSummaryCharacters: 96 * 1024
            )
        }
    }

    /// Encodes one captured request through all three REAL wire adapters and
    /// asserts both the composer ledger and the actual JSON body stay inside
    /// the documented wire budgets. No count-only mock proof is used.
    private func assertWireReadyBounds(_ request: ProviderStreamRequest) throws {
        let contextBudget = SubagentRunner.maximumRequestContextBytes
        let schemaBudget = SubagentRunner.maximumFrozenToolSchemaBytes
        let ledger = SubagentRunner.contextWireBytes(of: request)
        #expect(ledger <= contextBudget + schemaBudget)
        #expect(SubagentRunner.frozenSchemaWireBytes(of: request) <= schemaBudget)
        let refreshed = request.refreshingRuntimeClock()
        let allowance = contextBudget + schemaBudget + SubagentRunner.wireEnvelopeAllowanceBytes
        let bodies: [(String, Data)] = [
            ("chat", try ProviderWireEncoder.encode(OpenAIChatCompletionsAdapter().buildBody(from: refreshed))),
            ("anthropic", try ProviderWireEncoder.encode(AnthropicMessagesAdapter().buildBody(from: refreshed))),
            ("responses", try ProviderWireEncoder.encode(OpenAIResponsesAdapter().buildBody(from: refreshed))),
        ]
        for (protocolName, body) in bodies {
            #expect(
                body.count <= allowance,
                "\(protocolName) body \(body.count) bytes exceeds the \(allowance)-byte envelope"
            )
            // The ledger is a true upper bound: the real body may only exceed
            // it by the fixed per-request scaffolding allowance.
            #expect(
                body.count <= ledger + SubagentRunner.wireEnvelopeAllowanceBytes,
                "\(protocolName) body \(body.count) bytes exceeds ledger \(ledger) + allowance"
            )
        }
    }

    @Test("a single replay pair larger than the archive budget falls out whole, never appended over it")
    func oversizedSinglePairFallsOutWhole() throws {
        var replayed: [ReplayedToolPair] = []
        var dropped = 0
        let small = try TestFixtures.toolCall(id: "small-1")
        SubagentRunner.archiveSettledPairs(
            into: &replayed, droppedCount: &dropped,
            priorSettled: [(
                call: small,
                result: ToolResult(callID: small.id, status: .ok, outputSummary: "ok", outputDigest: "d")
            )],
            priorReasoning: nil
        )
        #expect(replayed.map(\.call.id) == ["small-1"])

        // 63 KiB arguments + 32 KiB output + the 64 KiB required reasoning
        // exceed the stored 96 KiB replay budget as ONE indivisible pair even
        // after per-field clipping; it must fall out whole instead of being
        // appended over the limit or having its required reasoning trimmed.
        let hugeArguments = #"{"text":""# + String(repeating: "a", count: 63 * 1024) + #""}"#
        let huge = try TestFixtures.toolCall(id: "huge-1", toolName: "test.big", arguments: hugeArguments)
        SubagentRunner.archiveSettledPairs(
            into: &replayed, droppedCount: &dropped,
            priorSettled: [(
                call: huge,
                result: ToolResult(
                    callID: huge.id, status: .failed,
                    outputSummary: String(repeating: "x", count: 40 * 1024),
                    outputDigest: "d2", maximumSummaryCharacters: 96 * 1024
                )
            )],
            priorReasoning: String(repeating: "r", count: 64 * 1024)
        )
        let storedBytes = replayed.reduce(0) {
            $0 + $1.call.argumentsJSON.count + $1.result.outputSummary.utf8.count
                + ($1.assistantReasoning?.utf8.count ?? 0)
        }
        #expect(storedBytes <= SubagentRunner.maximumReplayedHistoryBytes)
        #expect(replayed.isEmpty)
        #expect(dropped == 2)
    }

    @Test("an indivisible pending pair with required reasoning and arguments fails explicitly, never over budget")
    func oversizedPendingPairFailsExplicitly() async throws {
        let adapter = MockAdapter()
        let hugeArguments = #"{"text":""# + String(repeating: "a", count: 40 * 1024) + #""}"#
        let call = try TestFixtures.toolCall(id: "huge-read", toolName: "test.big", arguments: hugeArguments)
        adapter.script = [[
            .reasoningSummary(.init(text: String(repeating: "r", count: 40 * 1024))),
            .toolRequest(call)
        ]]
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(
                toolNames: ["test.big"],
                output: String(repeating: "x", count: 30 * 1024)
            )
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .toolError)
        // The completed read and its iteration survive the guard.
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.evidence.count == 1)
        #expect(outcome.findings.contains("bounded request context"))
        // The over-budget request was never dispatched to the adapter.
        #expect(adapter.requests.count == 1)
    }

    @Test("a huge tool output is bounded on its FIRST feedback request, not only in later replay")
    func hugeOutputBoundedOnFirstFeedback() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "big-read", toolName: "test.big")
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "final")), .completed(.init(stopReason: .endTurn))]
        ]
        let huge = String(repeating: "x", count: 80 * 1024)
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(toolNames: ["test.big"], output: huge)
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        let feedback = try #require(adapter.requests.dropFirst().first)
        let output = try #require(feedback.toolResults.first?.output)
        #expect(output.utf8.count <= SubagentRunner.maximumResultBytes)
        #expect(output.hasSuffix("[tool output truncated]"))
        #expect(output.hasPrefix(String(huge.prefix(64))))
        // The result keeps its real call/status facts (pairing stays valid).
        #expect(feedback.toolResults.first?.callID == call.id)
        #expect(feedback.pendingToolCalls.map(\.id) == [call.id])
        try assertWireReadyBounds(feedback)
    }

    @Test("non-ASCII output is clipped by UTF-8 bytes without splitting characters or corrupting the wire")
    func nonASCIIOutputIsClippedByBytes() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "cjk-read", toolName: "test.cjk")
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "final")), .completed(.init(stopReason: .endTurn))]
        ]
        // 20 000 CJK characters are 60 000 UTF-8 bytes; the 32 KiB result cap
        // must cut whole characters, never a partial scalar.
        let cjk = String(repeating: "推", count: 20_000)
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(toolNames: ["test.cjk"], output: cjk)
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        let feedback = try #require(adapter.requests.dropFirst().first)
        let output = try #require(feedback.toolResults.first?.output)
        #expect(output.utf8.count <= SubagentRunner.maximumResultBytes)
        #expect(output.hasSuffix("[tool output truncated]"))
        #expect(!output.contains("\u{FFFD}"))
        // Byte round-trip: what the wire carries stays a valid UTF-8 string
        // containing only whole characters.
        #expect(String(decoding: Array(output.utf8), as: UTF8.self) == output)
        try assertWireReadyBounds(feedback)
    }

    @Test("a large parallel result batch stays paired, bounded and wire-ready")
    func largeParallelBatchStaysBounded() async throws {
        let adapter = MockAdapter()
        let calls = try (0..<6).map { index in
            try TestFixtures.toolCall(
                id: "batch-\(index)", toolName: "test.batch",
                arguments: #"{"n":"\#(index)"}"#
            )
        }
        adapter.script = [
            calls.map { .toolRequest($0) },
            [.textDelta(.init(text: "synthesized")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(
                toolNames: ["test.batch"],
                output: String(repeating: "y", count: 8 * 1024)
            )
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        let feedback = try #require(adapter.requests.dropFirst().first)
        #expect(feedback.pendingToolCalls.map(\.id) == calls.map(\.id))
        #expect(feedback.toolResults.map(\.callID) == calls.map(\.id))
        #expect(feedback.toolResults.allSatisfy { $0.output.utf8.count == 8 * 1024 })
        try assertWireReadyBounds(feedback)
    }

    @Test("an oversized parallel result batch fails explicitly with every read preserved")
    func oversizedParallelBatchFailsExplicitly() async throws {
        let adapter = MockAdapter()
        let calls = try (0..<12).map { index in
            try TestFixtures.toolCall(
                id: "bulk-\(index)", toolName: "test.bulk",
                arguments: #"{"n":"\#(index)"}"#
            )
        }
        adapter.script = [calls.map { .toolRequest($0) }]
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(
                toolNames: ["test.bulk"],
                output: String(repeating: "z", count: 20 * 1024)
            )
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.evidence.count == 12)
        #expect(outcome.findings.contains("bounded request context"))
        #expect(adapter.requests.count == 1)
    }

    @Test("accumulated assistant text is counted, dropped oldest-first and surfaced")
    func accumulatedAssistantMessagesAreBounded() async throws {
        let adapter = MockAdapter()
        let calls = try (1...4).map { try TestFixtures.toolCall(id: "assist-\($0)") }
        func turnText(_ index: Int) -> String {
            "turn-\(index)-" + String(repeating: "z", count: 25 * 1024)
        }
        adapter.script = (0..<4).map { index in
            [.textDelta(.init(text: turnText(index + 1))), .toolRequest(calls[index])]
        } + [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .completed)
        let final = try #require(adapter.requests.last)
        let assistantTexts = final.messages.filter { $0.role == "assistant" }.map(\.content)
        // ~100 KiB of assistant text cannot ride one request: the newest
        // three survive, the oldest is dropped and explicitly reported.
        #expect(assistantTexts.count == 3)
        #expect(assistantTexts.contains { $0.hasPrefix("turn-4-") })
        #expect(!assistantTexts.contains { $0.hasPrefix("turn-1-") })
        #expect(outcome.truncated)
        #expect(outcome.findings.contains("earlier assistant message(s) dropped from bounded child context"))
        for request in adapter.requests { try assertWireReadyBounds(request) }
    }

    @Test("a base task input above the wire context fails explicitly before any dispatch")
    func oversizedTaskInputFailsExplicitly() async throws {
        let adapter = MockAdapter()
        let runner = makeRunner(adapter: adapter)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let request = SubagentRequest(
            task: String(repeating: "t", count: 100 * 1024),
            maxIterations: 6,
            runID: UUID()
        )
        let outcome = try await runner.runStructured(request, context: context)
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 1)
        #expect(outcome.findings.contains("task input"))
        #expect(adapter.requests.isEmpty)
    }

    @Test("escape-heavy content is charged at its escaped wire size, not its raw count")
    func escapeHeavyContentUsesEscapedWireSize() async throws {
        // The ledger is a conservative JSON-escape upper bound: quote,
        // backslash and slash cost two bytes, control bytes six.
        #expect(SubagentRunner.wireEscapedBytes("plain") == 5)
        #expect(SubagentRunner.wireEscapedBytes("/") == 2)
        #expect(SubagentRunner.wireEscapedBytes("\"") == 2)
        #expect(SubagentRunner.wireEscapedBytes("\\") == 2)
        #expect(SubagentRunner.wireEscapedBytes("\n") == 6)
        #expect(SubagentRunner.wireEscapedBytes("推") == 3)
        struct Probe: Encodable { var a: String }
        let encoder = JSONEncoder()
        let emptyBody = try encoder.encode(Probe(a: "")).count
        for sample in ["/", "\"", "\\", "推", "a/\"\\\n\u{1f}推", String(repeating: "\u{7}", count: 64)] {
            let actual = try encoder.encode(Probe(a: sample)).count - emptyBody
            #expect(SubagentRunner.wireEscapedBytes(sample) >= actual)
        }

        // 56 KiB of raw forward slashes are 112 KiB on the wire: a raw-count
        // budget would admit the pair, the escaped accounting must refuse it.
        let adapter = MockAdapter()
        let slashes = String(repeating: "/", count: 56 * 1024)
        let call = try TestFixtures.toolCall(
            id: "slash-call", toolName: "test.slash",
            arguments: #"{"text":""# + slashes + #""}"#
        )
        adapter.script = [[.toolRequest(call)]]
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(toolNames: ["test.slash"], output: "ok")
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 2)
        #expect(outcome.findings.contains("pending tool batch"))
        #expect(adapter.requests.count == 1)
    }

    @Test("the tool-free wrap-up request uses the same wire context bound")
    func wrapUpRequestUsesSameContextBound() async throws {
        let adapter = MockAdapter()
        let call = try TestFixtures.toolCall(id: "wrap-read")
        adapter.script = (0..<5).map { _ in
            [
                .reasoningSummary(.init(text: String(repeating: "r", count: 8 * 1024))),
                .toolRequest(call)
            ]
        }
        let runner = makeRunner(
            adapter: adapter,
            executor: OutputBoundExecutor(
                toolNames: ["test.echo"],
                output: String(repeating: "o", count: 25 * 1024)
            )
        )
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .partial)
        #expect(outcome.iterationsUsed == 6)
        let wrapUp = try #require(adapter.requests.last)
        // The wrap-up keeps paired tool history, removes schemas, and stays
        // inside the SAME hard budget as every tool-bearing request.
        #expect(wrapUp.toolSchemas.isEmpty)
        #expect(!wrapUp.replayedToolPairs.isEmpty)
        #expect(wrapUp.replayedToolPairs.allSatisfy { $0.call.id == $0.result.callID })
        #expect(wrapUp.allToolNames == ["test.echo"])
        for request in adapter.requests { try assertWireReadyBounds(request) }
        #expect(outcome.findings.contains("dropped from bounded replay history"))
        #expect(outcome.truncated)
    }

    @Test("a frozen schema catalog above its explicit allowance fails before dispatch")
    func oversizedFrozenSchemasFailExplicitly() async throws {
        let adapter = MockAdapter()
        let executor = MockExecutor()
        executor.descriptors["test.hugeSchema"] = .init(
            name: "test.hugeSchema",
            toolDescription: String(repeating: "s", count: 60 * 1024),
            riskLabels: [],
            isSideEffecting: false
        )
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: context)
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 1)
        #expect(outcome.findings.contains("bounded schema allowance"))
        #expect(adapter.requests.isEmpty)
    }
}
