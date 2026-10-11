// FloeAgentRuntimeTests — Tool-loop hardening (T12).
// See docs/ARCHITECTURE_EXECUTION.md §3.3/§6.3: maxToolSteps anti-loop
// ceiling, per-step durationMs in mirrored toolResult payloads, and the
// injected run-context system message.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

/// Adapter that requests a fresh non-side-effecting tool call on every
/// turn, forever — the infinite-loop driver. Each turn uses a distinct
/// call id so the idempotency dedup (same key → skipped) does not mask the
/// loop; the ceiling must come from maxToolSteps alone.
private final class LoopingAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let storage = AsyncLock<[ProviderStreamRequest]>([])

    var requests: [ProviderStreamRequest] {
        storage.withLock { $0 }
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let index = storage.withLock { requests -> Int in
            requests.append(request)
            return requests.count
        }
        // Unique deterministic id per turn keeps result-pairing invariants
        // testable while still exercising the independent iteration budget.
        let call = try! ToolCall( // literals only; cannot fail
            id: "loop_\(index)",
            toolName: "test.echo",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.toolRequest(call))
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

/// One-shot async gate used to park a real tool execution while the test
/// drives a concurrent steer, then release it.
private actor ExecutionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// Adapter that re-enables a capability just before the model's first retry,
/// modelling a server that was absent at restart and reconnected afterwards.
private final class RegisteringAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let storage = AsyncLock<(count: Int, requests: [ProviderStreamRequest])>((0, []))
    var requests: [ProviderStreamRequest] { storage.withLock { $0.requests } }
    private let toolName: String
    private let callIDPrefix: String
    private let onFirstRequest: @Sendable () -> Void

    init(
        toolName: String,
        callIDPrefix: String,
        onFirstRequest: @escaping @Sendable () -> Void
    ) {
        self.toolName = toolName
        self.callIDPrefix = callIDPrefix
        self.onFirstRequest = onFirstRequest
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let index = storage.withLock { state -> Int in
            state.requests.append(request)
            let index = state.count
            state.count += 1
            return index
        }
        return AsyncThrowingStream { continuation in
            if index == 0 {
                onFirstRequest()
                // Literal fixture arguments only; cannot fail.
                let call = try! ToolCall(
                    id: "\(callIDPrefix)-\(index)",
                    toolName: toolName,
                    argumentsJSON: Data("{}".utf8),
                    scope: .local
                )
                continuation.yield(.toolRequest(call))
            } else {
                continuation.yield(.completed(.init(stopReason: .endTurn)))
            }
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

@Suite("FloeAgentRuntime.ToolLoopHardening")
struct ToolLoopHardeningTests {

    @Test("A successful skill read activates exact executable tools on the next request")
    func readActivatesTools() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try ToolCall(id: "read_guide", toolName: "skill.read", argumentsJSON: Data(#"{"id":"guide"}"#.utf8), scope: .local))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry()
        let read = ToolCatalog.Descriptor(name: "skill.read", toolDescription: "Read guide", parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: false)
        registry.register(AnyAgentTool(descriptor: read) { _, _ in
            let json = try JSONSerialization.data(withJSONObject: [["id": "guide", "markdown": String(repeating: "instructions ", count: 600), "requiredToolNames": ["document.pdf.inspect", "invented.tool"]]])
            return .init(summary: String(decoding: json, as: UTF8.self), fullOutputSHA256: "", maximumSummaryCharacters: 262_144)
        })
        let inspect = ToolCatalog.Descriptor(name: "document.pdf.inspect", toolDescription: "Inspect PDF", parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: false)
        registry.register(AnyAgentTool(descriptor: inspect) { _, _ in .init(summary: "ok", fullOutputSHA256: "") })
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider, model: TestFixtures.testModel(providerID: provider.id)),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: CatalogToolExecutor(runners: registry))
        try await runtime.start(goal: "Read the guide")
        let first = try #require(adapter.requests.first)
        let second = try #require(adapter.requests.dropFirst().first)
        #expect(!first.toolSchemas.contains { $0.name == "document.pdf.inspect" })
        #expect(second.toolSchemas.contains { $0.name == "document.pdf.inspect" })
        #expect(!second.toolSchemas.contains { $0.name == "invented.tool" })
        let visibleRead = try #require(second.toolResults.first?.output)
        #expect(visibleRead.contains("[middle of tool output compacted]"))
        #expect(visibleRead.contains("[tool output compacted; originalBytes="))
        #expect(visibleRead.contains("requiredToolNames"))
    }

    @Test("provider tool descriptions include explicit prerequisite resolvers")
    func providerToolDescriptionsIncludePrerequisites() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            toolDescription: "Observe the active VNC framebuffer.",
            riskLabels: [],
            isSideEffecting: false,
            prerequisites: [ToolPrerequisite(
                state: "vnc.connected",
                resolverToolName: "vnc.connect",
                mayResolveAutomatically: true
            )]
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "observe only after connecting")

        let request = try #require(adapter.requests.first)
        let description = try #require(
            request.toolSchemas.first(where: { $0.name == "test.observe" })?.description
        )
        #expect(description.contains("Requires state vnc.connected"))
        #expect(description.contains("resolve explicitly with vnc.connect"))
    }

    @Test("subsequent model turns receive a compact activation ledger")
    func activationLedgerInjected() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "ledger_call"))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "inspect once and continue")

        let second = try #require(adapter.requests.dropFirst().first)
        #expect(second.messages.contains {
            $0.role == "system"
                && $0.content.contains("# Activation ledger")
                && $0.content.contains("test.echo [ok]")
                && $0.content.contains("Do not repeat a successful observation")
        })
    }

    @Test("different observations open fresh progress epochs")
    func interleavedDifferentObservationsDoNotStop() async throws {
        let adapter = MockAdapter()
        let calls = try [
            ToolCall(id: "echo-1", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "other-1", toolName: "test.other1", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-2", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "other-2", toolName: "test.other2", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-3", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "other-3", toolName: "test.other3", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-4", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "other-4", toolName: "test.other4", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-5", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local)
        ]
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        for index in 1...4 {
            let name = "test.other\(index)"
            executor.descriptors[name] = ToolCatalog.Descriptor(
                name: name,
                riskLabels: [],
                isSideEffecting: false
            )
        }
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "do not repeat unchanged work")

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after distinct observations")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("three unchanged retries in one progress epoch stop only that route")
    func consecutiveUnchangedRetriesStop() async throws {
        let adapter = MockAdapter()
        let calls = try (1...3).map {
            try ToolCall(
                id: "echo-\($0)",
                toolName: "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "stop only an unchanged retry route")

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("two alternating unchanged read routes stop without a budget limit")
    func alternatingRoutesWithoutProgressStop() async throws {
        let adapter = MockAdapter()
        // A,B,A,B,A,B with constant outcomes. The per-route counter resets on
        // every differing observation, so only the batch-level cycle detector
        // can stop this; maxToolSteps stays high to prove it is not the cause.
        let calls = try (1...6).map { index -> ToolCall in
            try ToolCall(
                id: "cycle-\(index)",
                toolName: index.isMultiple(of: 2) ? "test.observe" : "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "stop a two-route alternation")

        #expect(executor.executedCalls.count == 6)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
        // The non-terminal warning must reach the model on the request that
        // follows the fourth settled batch, before the stop is enforced.
        let warned = adapter.requests.contains { request in
            request.toolResults.contains {
                $0.output.contains("alternating between the same two non-progress tool routes")
            }
        }
        #expect(warned)
    }

    @Test("a successful mutation clears an alternating no-progress cycle")
    func mutationClearsAlternatingCycle() async throws {
        let adapter = MockAdapter()
        // A,B,A,B then a real mutation, then A,B,A,B again. Without the
        // progress reset the trailing six batches would trip the stop; the
        // mutation must restart the cycle so the run completes normally.
        let tools = [
            "test.echo", "test.observe", "test.echo", "test.observe",
            "test.write",
            "test.echo", "test.observe", "test.echo", "test.observe"
        ]
        let calls = try tools.enumerated().map { index, tool in
            try ToolCall(
                id: "reset-\(index)",
                toolName: tool,
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        executor.descriptors["test.write"] = ToolCatalog.Descriptor(
            name: "test.write",
            riskLabels: [],
            isSideEffecting: true
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: executor
        )

        try await runtime.start(goal: "reset the cycle on real progress")

        #expect(executor.executedCalls.count == tools.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after mutation reset")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("a repeated multi-call batch stops after the unchanged-replay limit")
    func repeatedMultiCallBatchesStop() async throws {
        let adapter = MockAdapter()
        // Two calls per provider turn, repeated unchanged. Each route appears
        // once per batch, so the per-route counter never accumulates; the
        // batch-level detector owns this dead-end route set.
        let batches = try (0..<3).map { round -> [AgentEvent] in
            try [
                .toolRequest(ToolCall(
                    id: "pair-\(round)-a",
                    toolName: "test.echo",
                    argumentsJSON: Data("{}".utf8),
                    scope: .local
                )),
                .toolRequest(ToolCall(
                    id: "pair-\(round)-b",
                    toolName: "test.observe",
                    argumentsJSON: Data("{}".utf8),
                    scope: .local
                ))
            ]
        }
        adapter.script = batches + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "stop a repeated multi-call batch")

        #expect(executor.executedCalls.count == 6)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("a result from a capability removed mid-execution is discarded")
    func removedCapabilityResultIsDiscarded() async throws {
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(name: "test.morph", riskLabels: [], isSideEffecting: false)
        ) { _, _ in
            // The capability unloads itself while its call is in flight.
            registry.unregister { $0 == "test.morph" }
            return .init(summary: "morphed ok", fullOutputSHA256: "digest")
        })
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try ToolCall(
                id: "morph-1",
                toolName: "test.morph",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let sink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(runners: registry),
            sink: sink
        )

        try await runtime.start(goal: "unload the capability mid-call")

        let results = sink.events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }
        #expect(results.count == 1)
        #expect(results.first?.status == .cancelled)
        #expect(results.first?.outputSummary.contains("stale result was discarded") == true)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after discarding the stale result")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("a result from a capability replaced mid-execution is not authoritative")
    func replacedCapabilityResultIsDenied() async throws {
        let registry = ToolRunnerRegistry()
        let replacement = ToolCatalog.Descriptor(
            name: "test.morph",
            toolDescription: "Replacement authority for the same name",
            riskLabels: [],
            isSideEffecting: false
        )
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(name: "test.morph", riskLabels: [], isSideEffecting: false)
        ) { _, _ in
            // A same-name replacement with a different descriptor identity
            // lands while the original call is still executing.
            registry.register(AnyAgentTool(descriptor: replacement) { _, _ in
                .init(summary: "replacement ok", fullOutputSHA256: "replacement-digest")
            })
            return .init(summary: "old authority ok", fullOutputSHA256: "old-digest")
        })
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try ToolCall(
                id: "morph-2",
                toolName: "test.morph",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            ))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let sink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(runners: registry),
            sink: sink
        )

        try await runtime.start(goal: "replace the capability authority mid-call")

        let results = sink.events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }
        #expect(results.count == 1)
        #expect(results.first?.status == .denied)
        #expect(results.first?.outputSummary.contains("stale result was discarded") == true)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after discarding the stale authority result")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("an unknown-outcome mutation is never replayed after removal, restore or retry")
    func unknownOutcomeMutationIsNotReplayed() async throws {
        let mutations = AsyncLock(0)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.mutate",
                riskLabels: [],
                isSideEffecting: true
            )
        ) { _, _ in
            mutations.withLock { $0 += 1 }
            // The capability disappears while its own mutation is executing,
            // so the real-world outcome cannot be confirmed from this process.
            registry.unregister { $0 == "test.mutate" }
            return .init(summary: "mutated", fullOutputSHA256: "mutated-digest")
        })
        let adapter = MockAdapter()
        let first = try ToolCall(
            id: "mutate-1", toolName: "test.mutate",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let second = try ToolCall(
            id: "mutate-2", toolName: "test.mutate",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        adapter.script = [
            [.toolRequest(first)],
            [.toolRequest(second)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let checkpoints = MockCheckpointStore()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: registry),
            checkpointStore: checkpoints
        )

        try await runtime.start(goal: "mutate once, never blindly repeat")

        #expect(mutations.withLock { $0 } == 1)
        // The unknown-outcome receipt is durable in the execution ledger.
        let settled = try #require(checkpoints.saved.last)
        #expect(settled.executionLedgerEntries?.contains {
            $0.toolName == "test.mutate"
                && $0.resultFingerprint.hasPrefix("unknown-outcome:")
        } == true)
        // The same-run re-emission was suppressed before the executor.
        #expect(adapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after the suppression")
            return
        }
        #expect(completion.stopReason == .endTurn)

        // Restore the checkpoint in a fresh runtime with the capability
        // available again. A retry of the same route must still not execute,
        // because the earlier real-world outcome remains unknown.
        let restoredRegistry = ToolRunnerRegistry()
        restoredRegistry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.mutate",
                riskLabels: [],
                isSideEffecting: true
            )
        ) { _, _ in
            mutations.withLock { $0 += 1 }
            return .init(summary: "mutated again", fullOutputSHA256: "mutated-again-digest")
        })
        let restoreAdapter = MockAdapter()
        let third = try ToolCall(
            id: "mutate-3", toolName: "test.mutate",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        restoreAdapter.script = [
            [.toolRequest(third)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let restored = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: restoreAdapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: restoredRegistry)
        )

        try await restored.resume(from: settled)

        #expect(mutations.withLock { $0 } == 1)
        #expect(restoreAdapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
    }

    @Test("a legacy dispatched orphan without frozen effect fails conservative at restart")
    func legacyDispatchedOrphanFailsConservative() async throws {
        let executions = AsyncLock(0)
        let registry = ToolRunnerRegistry()
        let registerTool: @Sendable () -> Void = {
            registry.register(AnyAgentTool(
                descriptor: ToolCatalog.Descriptor(
                    name: "test.mutate",
                    riskLabels: [],
                    isSideEffecting: true
                )
            ) { _, _ in
                executions.withLock { $0 += 1 }
                return .init(summary: "retried", fullOutputSHA256: "retried")
            })
        }
        let adapter = RegisteringAdapter(
            toolName: "test.mutate",
            callIDPrefix: "legacy-retry",
            onFirstRequest: registerTool
        )
        let call = try ToolCall(
            id: "legacy-orphan",
            toolName: "test.mutate",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "recover the legacy dispatched call")),
            messages: [ConversationMessage(role: "user", content: "recover after restart")],
            pendingToolCalls: [call],
            pendingToolResults: [],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .dispatched
            )]
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: registry)
        )

        try await runtime.resume(from: checkpoint)

        // The capability was absent at repair time and no frozen effect kind
        // exists, so the dispatched orphan must not be classified as a read.
        #expect(adapter.requests.first?.toolResults.first?.output.contains("outcome is unknown") == true)
        // The capability is re-enabled before the retry; the receipt suppresses
        // it, so the mutation body never runs in this process.
        #expect(executions.withLock { $0 } == 0)
        #expect(adapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
    }

    @Test("a frozen side-effecting orphan stays unknown when the capability is absent at restart")
    func frozenSideEffectingOrphanStaysUnknown() async throws {
        let executions = AsyncLock(0)
        let registry = ToolRunnerRegistry()
        let registerTool: @Sendable () -> Void = {
            registry.register(AnyAgentTool(
                descriptor: ToolCatalog.Descriptor(
                    name: "test.mutate",
                    riskLabels: [],
                    isSideEffecting: true
                )
            ) { _, _ in
                executions.withLock { $0 += 1 }
                return .init(summary: "retried", fullOutputSHA256: "retried")
            })
        }
        let adapter = RegisteringAdapter(
            toolName: "test.mutate",
            callIDPrefix: "frozen-retry",
            onFirstRequest: registerTool
        )
        let call = try ToolCall(
            id: "frozen-orphan",
            toolName: "test.mutate",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "recover the frozen dispatched call")),
            messages: [ConversationMessage(role: "user", content: "recover after restart")],
            pendingToolCalls: [call],
            pendingToolResults: [],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                isSideEffecting: true,
                phase: .dispatched
            )]
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: CatalogToolExecutor(runners: registry)
        )

        try await runtime.resume(from: checkpoint)

        #expect(adapter.requests.first?.toolResults.first?.output.contains("outcome is unknown") == true)
        #expect(executions.withLock { $0 } == 0)
        #expect(adapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
    }

    @Test("a recorded-never-dispatched call is known and its retry executes once")
    func recordedNeverDispatchedRetryExecutes() async throws {
        let executions = AsyncLock(0)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.read",
                riskLabels: [],
                isSideEffecting: false
            )
        ) { _, _ in
            executions.withLock { $0 += 1 }
            return .init(summary: "read ok", fullOutputSHA256: "read-ok")
        })
        let adapter = MockAdapter()
        let retry = try ToolCall(
            id: "recorded-retry",
            toolName: "test.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        adapter.script = [
            [.toolRequest(retry)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let call = try ToolCall(
            id: "recorded-orphan",
            toolName: "test.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "retry a call that never dispatched")),
            messages: [ConversationMessage(role: "user", content: "retry after restart")],
            pendingToolCalls: [call],
            pendingToolResults: [],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .recorded
            )]
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(runners: registry)
        )

        try await runtime.resume(from: checkpoint)

        let repairOutput = try #require(adapter.requests.first?.toolResults.first?.output)
        #expect(repairOutput.contains("never dispatched"))
        #expect(!repairOutput.contains("outcome is unknown"))
        #expect(executions.withLock { $0 } == 1)
    }

    @Test("a frozen read-only interrupted call is retried after recovery")
    func frozenReadOnlyInterruptedRetryRefreshes() async throws {
        let executions = AsyncLock(0)
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.read",
                riskLabels: [],
                isSideEffecting: false
            )
        ) { _, _ in
            executions.withLock { $0 += 1 }
            return .init(summary: "refreshed read", fullOutputSHA256: "refreshed")
        })
        let adapter = MockAdapter()
        let retry = try ToolCall(
            id: "readonly-retry",
            toolName: "test.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        adapter.script = [
            [.toolRequest(retry)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let call = try ToolCall(
            id: "readonly-orphan",
            toolName: "test.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "refresh the interrupted read")),
            messages: [ConversationMessage(role: "user", content: "refresh after restart")],
            pendingToolCalls: [call],
            pendingToolResults: [],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                isSideEffecting: false,
                phase: .dispatched
            )]
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(runners: registry)
        )

        try await runtime.resume(from: checkpoint)

        let repairOutput = try #require(adapter.requests.first?.toolResults.first?.output)
        #expect(repairOutput.contains("read-only"))
        #expect(repairOutput.contains("may be retried"))
        #expect(executions.withLock { $0 } == 1)
        #expect(!adapter.requests.contains { request in
            request.toolResults.contains { $0.output.contains("was not executed again") }
        })
    }

    @Test("saturated unknown-outcome receipts still block side-effecting replay")
    func saturatedUnknownReceiptsBlockMutationReplay() async throws {
        var ledger = HarnessExecutionLedger()
        for index in 0..<13 {
            let call = try ToolCall(
                id: "sat-\(index)",
                toolName: "test.mutate\(index)",
                argumentsJSON: Data("{\"i\":\(index)}".utf8),
                scope: .local
            )
            ledger.record(
                call: call,
                result: ToolResult(
                    callID: call.id,
                    status: .failed,
                    outputSummary: "unknown outcome \(index)",
                    outputDigest: ""
                ),
                isSideEffecting: true,
                outcomeUnknown: true
            )
        }
        // The bounded ledger could not keep every unknown receipt, so the
        // saturation guard must stand in for the dropped ones.
        #expect(ledger.hasUnknownOutcomeOverflow)
        let candidate = try ToolCall(
            id: "sat-candidate",
            toolName: "test.unrelated",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        #expect(ledger.suppressedUnknownOutcomeResult(
            for: candidate,
            isSideEffecting: true
        ) != nil)
        #expect(ledger.suppressedUnknownOutcomeResult(
            for: candidate,
            isSideEffecting: false
        ) == nil)
        // Saturation travels through the existing checkpoint record format.
        let restored = HarnessExecutionLedger(records: ledger.checkpointRecords())
        #expect(restored.hasUnknownOutcomeOverflow)
        #expect(restored.suppressedUnknownOutcomeResult(
            for: candidate,
            isSideEffecting: true
        ) != nil)
    }

    @Test("alternating routes with different arguments or pages remain progress")
    func alternatingRoutesWithChangingArgumentsRemainProgress() async throws {
        let adapter = MockAdapter()
        // Same two tools alternate, but every call advances a cursor. These
        // are materially different routes (pagination/document fan-out), so
        // the cycle detector must not treat the exploration as a stall.
        let calls = try (1...6).map { index -> ToolCall in
            try ToolCall(
                id: "paged-\(index)",
                toolName: index.isMultiple(of: 2) ? "test.observe" : "test.echo",
                argumentsJSON: Data("{\"cursor\":\"page-\(index)\"}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "page through two sources")

        #expect(executor.executedCalls.count == 6)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion for paged exploration")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("alternating routes with changing observations remain progress")
    func alternatingRoutesWithChangingObservationsRemainProgress() async throws {
        let adapter = MockAdapter()
        let calls = try (1...6).map { index -> ToolCall in
            try ToolCall(
                id: "observed-\(index)",
                toolName: index.isMultiple(of: 2) ? "test.observe" : "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        // Every observation carries genuinely new content (a revision), even
        // though the routes alternate. The guard must not stop monitoring or
        // diagnostics that keep seeing new information.
        executor.results = calls.enumerated().map { index, call in
            ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "revision \(index + 1)",
                outputDigest: "revision-\(index + 1)"
            )
        }
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "monitor two changing sources")

        #expect(executor.executedCalls.count == 6)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion for changing observations")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("an explicit wait clears an alternating no-progress cycle")
    func explicitWaitClearsAlternatingCycle() async throws {
        let adapter = MockAdapter()
        let tools = [
            "test.echo", "test.observe", "test.echo", "test.observe",
            "wait",
            "test.echo", "test.observe", "test.echo", "test.observe"
        ]
        let calls = try tools.enumerated().map { index, tool in
            try ToolCall(
                id: "waited-\(index)",
                toolName: tool,
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        executor.descriptors["wait"] = ToolCatalog.Descriptor(
            name: "wait",
            riskLabels: [],
            isSideEffecting: false
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "wait, then re-check the two routes")

        #expect(executor.executedCalls.count == tools.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after an explicit wait")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("new user input clears an alternating no-progress cycle")
    func steerClearsAlternatingCycle() async throws {
        let adapter = MockAdapter()
        let calls = try (1...6).map { index -> ToolCall in
            try ToolCall(
                id: "steered-\(index)",
                toolName: index.isMultiple(of: 2) ? "test.observe" : "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        let gate = ExecutionGate()
        // Park the fourth executed call so the test can steer while the run
        // is mid-tool, then release it. Without the steer reset the six
        // alternating batches would stop; the new guidance must restart it.
        executor.executionGate = { [executor] in
            if executor.executedCalls.count == 3 { await gate.wait() }
        }
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )
        let runTask = Task { try await runtime.start(goal: "alternate until guided") }

        var polls = 0
        while executor.executedCalls.count < 3, polls < 400 {
            try await Task.sleep(nanoseconds: 5_000_000)
            polls += 1
        }
        #expect(executor.executedCalls.count == 3)
        let acceptance = await runtime.steer(
            RuntimeSteerInput(id: UUID(), content: "Change route: the alternation is not working"),
            expectedRunID: runtime.runID
        )
        #expect(acceptance == .accepted)
        await gate.open()
        try await runTask.value

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after user guidance")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("a new route after a cycle warning completes instead of stopping")
    func newRouteAfterCycleWarningCompletes() async throws {
        let adapter = MockAdapter()
        let plan: [(String, String)] = [
            ("0", "test.echo"), ("1", "test.observe"),
            ("2", "test.echo"), ("3", "test.observe"),
            ("4", "test.inspect")
        ]
        let calls = try plan.map { index, tool in
            try ToolCall(
                id: "warned-\(index)",
                toolName: tool,
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        executor.descriptors["test.inspect"] = ToolCatalog.Descriptor(
            name: "test.inspect",
            riskLabels: [],
            isSideEffecting: false
        )
        executor.results = [
            ToolResult(callID: "warned-0", status: .ok, outputSummary: "echo", outputDigest: "echo-digest"),
            ToolResult(callID: "warned-1", status: .ok, outputSummary: "observe", outputDigest: "observe-digest"),
            ToolResult(callID: "warned-2", status: .ok, outputSummary: "echo", outputDigest: "echo-digest"),
            ToolResult(callID: "warned-3", status: .ok, outputSummary: "observe", outputDigest: "observe-digest"),
            ToolResult(callID: "warned-4", status: .ok, outputSummary: "new evidence", outputDigest: "new-evidence")
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "warn on the cycle, then change route")

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after a materially new route")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("multi-call batch order variance is canonicalized into one repeat cycle")
    func multiCallBatchOrderVarianceIsCanonicalized() async throws {
        let adapter = MockAdapter()
        // [A,B], [B,A], [A,B] is the same dead-end route set each round.
        let rounds: [[String]] = [
            ["test.echo", "test.observe"],
            ["test.observe", "test.echo"],
            ["test.echo", "test.observe"]
        ]
        let script = try rounds.enumerated().map { round, tools -> [AgentEvent] in
            try tools.enumerated().map { position, tool -> AgentEvent in
                .toolRequest(try ToolCall(
                    id: "order-\(round)-\(position)",
                    toolName: tool,
                    argumentsJSON: Data("{}".utf8),
                    scope: .local
                ))
            }
        }
        adapter.script = script + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe",
            riskLabels: [],
            isSideEffecting: false
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "repeat the same route set in any order")

        #expect(executor.executedCalls.count == 6)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("a strict surface stops on the first unchanged tool retry")
    func strictSurfaceStopsFirstDuplicate() async throws {
        let adapter = MockAdapter()
        let calls = try (1...2).map {
            try ToolCall(
                id: "strict-echo-\($0)",
                toolName: "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 12,
                unchangedToolOutcomeLimit: 2
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "stop the unchanged canvas route")

        #expect(executor.executedCalls.count == 2)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected strict no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("duplicate calls in one provider batch execute only once")
    func duplicateCallsInOneBatchExecuteOnce() async throws {
        let first = try ToolCall(
            id: "batch-observe-1", toolName: "test.observe",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let duplicate = try ToolCall(
            id: "batch-observe-2", toolName: "test.observe",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(first), .toolRequest(duplicate), .completed(.init(stopReason: .toolUse))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe", riskLabels: [], isSideEffecting: false
        )
        let sink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            sink: sink
        )

        try await runtime.start(goal: "observe once")

        #expect(executor.executedCalls.map(\.id) == [first.id])
        let results = sink.events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }
        #expect(results.count == 2)
        #expect(results.contains { $0.callID == duplicate.id && $0.outputSummary.contains("duplicate") })
    }

    @Test("non-retryable failure suppresses unchanged execution then stops the dead end")
    func nonretryableFailureBlocksUnchangedRetry() async throws {
        let calls = try (1...3).map {
            try ToolCall(
                id: "observe-missing-\($0)", toolName: "test.observe",
                argumentsJSON: Data("{}".utf8), scope: .local
            )
        }
        let adapter = MockAdapter()
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe", riskLabels: [], isSideEffecting: false
        )
        executor.results = [ToolResult(
            callID: calls[0].id,
            status: .failed,
            outputSummary: #"{"category":"configurationMissing","retryable":false}"#,
            outputDigest: ""
        )]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "do not retry an unconfigured endpoint")

        #expect(executor.executedCalls.map(\.id) == [calls[0].id])
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("a suppressed non-retryable retry can change to a recovery route")
    func nonretryableFailureCanChangeRoute() async throws {
        let failed = try ToolCall(
            id: "observe-missing-first", toolName: "test.observe",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let suppressed = try ToolCall(
            id: "observe-missing-suppressed", toolName: "test.observe",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let recovery = try ToolCall(
            id: "ssh-recovery", toolName: "ssh.listHosts",
            argumentsJSON: Data("{}".utf8), scope: .local
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(failed)],
            [.toolRequest(suppressed)],
            [.toolRequest(recovery)],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.observe"] = ToolCatalog.Descriptor(
            name: "test.observe", riskLabels: [], isSideEffecting: false
        )
        executor.descriptors["ssh.listHosts"] = ToolCatalog.Descriptor(
            name: "ssh.listHosts", riskLabels: [], isSideEffecting: false
        )
        executor.results = [
            ToolResult(
                callID: failed.id,
                status: .failed,
                outputSummary: #"{"category":"configurationMissing","retryable":false}"#,
                outputDigest: ""
            ),
            ToolResult(
                callID: recovery.id,
                status: .ok,
                outputSummary: #"{"hosts":[{"id":"saved-host"}]}"#,
                outputDigest: "hosts"
            )
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "recover VNC through the saved SSH host")

        #expect(executor.executedCalls.map(\.id) == [failed.id, recovery.id])
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected the changed recovery route to complete")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("a successful mutation opens a new no-progress epoch")
    func successfulMutationResetsNoProgressEpoch() async throws {
        let adapter = MockAdapter()
        let calls = try [
            ToolCall(id: "echo-1", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-2", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "write-1", toolName: "test.write", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-3", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local),
            ToolCall(id: "echo-4", toolName: "test.echo", argumentsJSON: Data("{}".utf8), scope: .local)
        ]
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.descriptors["test.write"] = ToolCatalog.Descriptor(
            name: "test.write",
            riskLabels: [],
            isSideEffecting: true
        )
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 20
            ),
            adapter: adapter,
            policy: ModelApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: executor
        )

        try await runtime.start(goal: "repeat reads only after real progress")

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion after mutation reset")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("different visual tools are not collapsed into one failed operation")
    func differentVisualFailuresRemainIndependent() async throws {
        let adapter = MockAdapter()
        let tools = ["image.inspect", "image.ocr", "browser.observe"]
        let arguments = Data(#"{"path":"Attachments/a.png"}"#.utf8)
        let calls = try tools.enumerated().map { index, tool in
            try ToolCall(
                id: "visual-\(index)",
                toolName: tool,
                argumentsJSON: arguments,
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]

        let executor = MockExecutor()
        for tool in tools {
            executor.descriptors[tool] = ToolCatalog.Descriptor(
                name: tool,
                riskLabels: [],
                isSideEffecting: false
            )
        }
        executor.results = calls.map {
            ToolResult(
                callID: $0.id,
                status: .failed,
                outputSummary: "could not decode image request 12345",
                outputDigest: "failure"
            )
        }
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 12
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "inspect the attached image")

        #expect(executor.executedCalls.count == 3)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("same tool may continue when arguments or errors materially change")
    func changingArgumentsAndErrorsRemainProgress() async throws {
        let adapter = MockAdapter()
        let calls = try (1...4).map { index in
            try ToolCall(
                id: "changing-\(index)",
                toolName: "test.echo",
                argumentsJSON: Data(#"{"attempt":\#(index)}"#.utf8),
                scope: .local
            )
        }
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.results = calls.enumerated().map { index, call in
            ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "different failure \(index + 1)",
                outputDigest: "failure-\(index + 1)"
            )
        }
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                maxToolSteps: 8
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "adapt using materially different inputs")

        #expect(executor.executedCalls.count == calls.count)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected ordinary completion")
            return
        }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("Pseudo function-call text is rendered but never executed")
    func pseudoFunctionCallTextNeverExecutes() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: #"<|FunctionCallBegin|>[{"name":"test.echo","parameters":{}}]<|FunctionCallEnd|>"#)),
            .completed(.init(stopReason: .endTurn))
        ]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let sink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            sink: sink
        )

        try await runtime.start(goal: "show a pseudo call")

        #expect(executor.executedCalls.isEmpty)
        #expect(sink.events.contains {
            if case .textDelta(let delta) = $0 { return delta.text.contains("FunctionCallBegin") }
            return false
        })
    }

    @Test("Structured provider calls are rejected when native tools are disabled")
    func structuredCallsRequireCapability() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.toolRequest(try TestFixtures.toolCall())]]
        let executor = MockExecutor()
        registerEcho(in: executor)
        let provider = TestFixtures.localhostProvider()
        var model = TestFixtures.testModel(providerID: provider.id)
        model.capabilities.remove(.tools)
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: model),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "do not run tools")

        #expect(executor.executedCalls.isEmpty)
        let state = await runtime.state
        #expect(state.name == "failed")
    }

    private func makeStores() async throws -> (SQLiteConversationStore, SQLiteRunStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (SQLiteConversationStore(database: database), SQLiteRunStore(database: database))
    }

    private func registerEcho(in executor: MockExecutor, sideEffecting: Bool = false) {
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            riskLabels: [],
            isSideEffecting: sideEffecting
        )
    }

    // MARK: 1. Bounded multi-step loop completes

    @Test("N < maxToolSteps: every step executes and the run completes")
    func boundedLoopCompletes() async throws {
        let steps = 3
        var script: [[AgentEvent]] = (1...steps).map { index in
            [.toolRequest(try! TestFixtures.toolCall(id: "call_\(index)"))] // fixture cannot fail
        }
        script.append([.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))])

        let adapter = MockAdapter()
        adapter.script = script
        let executor = MockExecutor()
        registerEcho(in: executor)
        let sink = MockSink()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                maxToolSteps: 5
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            sink: sink
        )

        try await runtime.start(goal: "loop three times")

        let state = await runtime.state
        guard case .completed = state else {
            Issue.record("expected completed, got \(state.name)")
            return
        }
        #expect(executor.executedCalls.count == steps)
        #expect(sink.events.filter {
            if case .toolResult = $0 { return true }
            return false
        }.count == steps)
    }

    // MARK: 2. Infinite loop trips the ceiling

    @Test("Infinite tool requests stop at the activation budget and finalize")
    func infiniteLoopTripsCeiling() async throws {
        let maxSteps = 4
        let adapter = LoopingAdapter()
        let executor = MockExecutor()
        registerEcho(in: executor)
        // Vary the observable output so this fixture reaches the independent
        // activation-budget boundary instead of the stricter no-progress
        // boundary exercised by the tests above.
        executor.results = (1...maxSteps).map { index in
            ToolResult(
                callID: "loop_\(index)",
                status: .ok,
                outputSummary: "progress \(index)",
                outputDigest: "digest-\(index)"
            )
        }
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                maxToolSteps: maxSteps
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "loop forever")

        let state = await runtime.state
        guard case .completed(let completion) = state else {
            Issue.record("expected completed, got \(state.name)")
            return
        }
        #expect(completion.stopReason == .budgetLimited)
        // Exactly maxToolSteps executions happened; the (max+1)-th request
        // was refused before reaching the executor.
        #expect(executor.executedCalls.count == maxSteps)
        // The final request is tool-free. A non-compliant adapter that still
        // emits a tool request is stopped without executing it.
        #expect(adapter.requests.count == maxSteps + 2)
    }

    // MARK: 3. Audit records survive the ceiling trip

    @Test("Audit records every executed step; the refused request is not audited as executed")
    func auditCompleteOnCeiling() async throws {
        let maxSteps = 3
        let adapter = LoopingAdapter()
        let executor = MockExecutor()
        registerEcho(in: executor)
        executor.results = (1...maxSteps).map { index in
            ToolResult(
                callID: "loop_\(index)",
                status: .ok,
                outputSummary: "progress \(index)",
                outputDigest: "audit-digest-\(index)"
            )
        }
        let audit = MockAuditSink()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                maxToolSteps: maxSteps
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            auditSink: audit
        )

        try await runtime.start(goal: "audit me")

        let state = await runtime.state
        #expect(state.name == "completed")
        // Executed steps are followed by one explicit harness-budget denial.
        #expect(audit.entries.count == maxSteps + 1)
        #expect(audit.entries.allSatisfy { $0.toolName == "test.echo" })
        #expect(audit.entries.dropLast().allSatisfy { $0.decision.hasPrefix("allow:") })
        #expect(audit.entries.last?.decision == "deny:harness-budget")
    }

    // MARK: 4. durationMs in mirrored toolResult payloads

    @Test("toolResult events carry durationMs >= 0")
    func toolResultDurationRecorded() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "timed_call"))],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        registerEcho(in: executor)

        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "time this tool")

        let events = try await runStore.events(runID: service.runID)
        let toolResults = events.filter { $0.kind == .toolResult }
        #expect(toolResults.count == 1)
        let payload = toolResults[0].payloadJSON
        #expect(payload.contains("\"durationMs\""))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))
        let duration = try #require(decoded["durationMs"].flatMap(Int.init))
        #expect(duration >= 0)
    }

    // MARK: 5. Run-context system message injection

    @Test("Actual tool-free requests omit discovery and workflow activation in both provider message forms")
    func toolFreeProviderBoundary() async throws {
        for disableConfiguration in [false, true] {
            let (conversationStore, runStore) = try await makeStores()
            let conversationID = UUID(), provider = TestFixtures.localhostProvider()
            try await conversationStore.saveConversation(.init(id: conversationID, title: "Synthetic prompt audit", createdAt: Date(), updatedAt: Date()))
            var model = TestFixtures.testModel(providerID: provider.id)
            if !disableConfiguration { model.capabilities.remove(.tools) }
            let adapter = MockAdapter()
            adapter.script = [[.completed(.init(stopReason: .endTurn))]]
            let service = ConversationRunService(
                configuration: .init(conversationID: conversationID, provider: provider, model: model, toolsEnabled: !disableConfiguration),
                adapter: adapter, policy: HumanApprovalPolicy(), executor: MockExecutor(),
                conversationStore: conversationStore, runStore: runStore,
                runContext: .init(availableToolNames: ["exec.localPython"], skillInstructions: "Synthetic guide: call exec.localPython")
            )
            try await service.start(goal: "Answer this simple synthetic question")
            let request = try #require(adapter.requests.first)
            #expect(request.toolSchemas.isEmpty)
            let legacy = request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
            let structured = request.contentMessages.filter { $0.role == "system" }.flatMap(\.content).compactMap { part -> String? in
                if case .text(let value) = part { return value }; return nil
            }.joined(separator: "\n")
            for prompt in [legacy, structured] {
                #expect(prompt.contains("Native tool calling is unavailable"))
                for absent in ["tools.search", "tools.list", "checklist.updatePlan", "exec.localPython", "Synthetic guide"] {
                    #expect(!prompt.contains(absent))
                }
            }
            try writeSyntheticPromptAudit(request, name: disableConfiguration ? "tools-disabled" : "model-without-tools")
        }
    }

    @Test("Final request checklist guidance follows the current mode and tool policy")
    func planDiscoveryMatchesReadOnlySchemas() async throws {
        for mode: ConversationMode in [.chat, .plan, .goal] {
            let adapter = MockAdapter()
            adapter.script = [[.completed(.init(stopReason: .endTurn))]]
            let executor = MockExecutor()
            for (name, effect): (String, ToolEffect) in [("checklist.readPlan", .readOnly), ("checklist.updatePlan", .internalState)] {
                executor.descriptors[name] = .init(name: name, toolDescription: name, parametersJSON: "{}", riskLabels: [], isSideEffecting: false, effect: effect)
            }
            let provider = TestFixtures.localhostProvider()
            let runtime = FloeAgentRuntime(configuration: .init(provider: provider, model: TestFixtures.testModel(providerID: provider.id), conversationMode: mode),
                adapter: adapter, policy: HumanApprovalPolicy(), executor: executor)
            await runtime.injectSystemContext(AgentPromptComposer.compose(mode: mode, runtimeContext: "Synthetic audit"))
            try await runtime.start(goal: "Plan the work")
            let request = try #require(adapter.requests.first)
            #expect(request.toolSchemas.contains { $0.name == "checklist.updatePlan" } == (mode != .plan))
            #expect(request.messages.contains { $0.role == "system" && $0.content.contains("checklist.updatePlan") } == (mode != .plan))
            try writeSyntheticPromptAudit(request, name: mode.rawValue)
        }
    }

    @Test("Run context includes the live local clock and UTC offset")
    func systemContextIncludesCurrentTimeZone() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 9 * 3_600 + 30 * 60))
        let message = ConversationRunService.buildContextMessage(
            nil,
            toolsAvailable: false,
            currentDate: Date(timeIntervalSince1970: 0),
            timeZone: timeZone
        )

        #expect(message.contains("Current local date and time at run start: 1970-01-01T09:30:00+09:30"))
        #expect(message.contains("Current time zone: GMT+0930 (UTC+09:30)"))
    }

    @Test("The first model message is the injected system context with tool names")
    func systemContextInjected() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        // Supply the actual run capability set; a static catalog declaration
        // alone is intentionally no longer advertised as executable.

        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let executor = MockExecutor()

        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            conversationStore: conversationStore,
            runStore: runStore,
            runContext: ConversationRunService.RunContext(
                workspaceName: "Demo Project",
                selectedRelativePath: "src/main.swift",
                executionTarget: "local",
                availableToolNames: ["test.contextProbe"]
            )
        )

        try await service.start(goal: "context please")

        let request = try #require(adapter.requests.first)
        let first = try #require(request.messages.first)
        #expect(first.role == "system")
        #expect(first.content.contains("Workspace: Demo Project"))
        #expect(first.content.contains("src/main.swift"))
        #expect(first.content.contains("Execution target: local"))
        #expect(first.content.contains("Current local date and time at run start:"))
        #expect(first.content.contains("Current time zone:"))
        #expect(first.content.contains("Installed tool groups:"))
        #expect(first.content.contains("tools.search"))
        // The user goal follows the system message.
        #expect(request.messages.count == 2)
        #expect(request.messages[1].role == "user")
        #expect(request.messages[1].content == "context please")

        // The system context is runtime-only: it must not persist as a
        // conversation message.
        let messages = try await conversationStore.messages(conversationID: conversationID)
        #expect(!messages.contains { $0.role == "system" })
    }

    @Test("Nil run context still injects the tool list")
    func systemContextWithoutWorkspace() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        let adapter = MockAdapter()
        adapter.script = [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]

        let service = ConversationRunService(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            conversationStore: conversationStore,
            runStore: runStore
        )

        try await service.start(goal: "bare run")

        let request = try #require(adapter.requests.first)
        let first = try #require(request.messages.first)
        #expect(first.role == "system")
        #expect(first.content.contains("Available tools:"))
        #expect(!first.content.contains("Workspace:"))
    }

    @Test("Models without native tool calling never receive tool names")
    func systemContextSuppressesToolsForTextOnlyModels() {
        for mode: ConversationMode in [.chat, .plan, .goal] {
            let message = ConversationRunService.buildContextMessage(
                .init(availableToolNames: ["workspace.listDirectory", "exec.localPython"]),
                mode: mode, toolsAvailable: false
            )
            #expect(message.contains("native tool calling is disabled"))
            for absent in ["workspace.listDirectory", "exec.localPython", "tools.search", "skill.list", "plan.submit"] {
                #expect(!message.contains(absent))
            }
        }
    }

    @Test("Uploaded visual files route to semantic inspection instead of OCR")
    func uploadedVisualFilesPreferSemanticInspection() {
        let message = ConversationRunService.buildContextMessage(
            .init(
                availableToolNames: ["image.inspect", "image.ocr"],
                workspaceAttachmentPaths: ["Attachments/example.pdf"]
            )
        )

        #expect(message.contains("call image.inspect"))
        #expect(message.contains("PDF page"))
        #expect(message.contains("image.ocr only for exact text transcription"))
    }

    @Test("Browser context requires structured access before visual fallback")
    func browserContextPrefersStructuredAccess() {
        let message = ConversationRunService.buildContextMessage(
            .init(availableToolNames: [
                "browser.observe", "browser.click", "browser.screenshot",
                "browser.clickPoint", "image.inspect"
            ])
        )

        #expect(message.contains("prefer browser.observe DOM refs"))
        #expect(message.contains("screenshots/OCR are the fallback"))
        #expect(message.contains("fresh evidence"))
        #expect(message.contains("skill.read id=floe-browser"))
    }
}

/// Catalog-registered probe tool used to prove the injected system message
/// lists live catalog names. Never executed.
private struct WorkspaceProbeTool: AgentTool {
    struct Arguments: Decodable, Sendable {}

    static let name = "test.contextProbe"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "unreachable", fullOutputSHA256: "")
    }
}

/// Opt-in fixture evidence only. Never called by the app or a real provider.
/// Audit output contains synthetic messages, schema names and lengths, not
/// credentials, provider profiles, real conversations or inferred token usage.
private func writeSyntheticPromptAudit(_ request: ProviderStreamRequest, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["FLOE_SYNTHETIC_PROMPT_AUDIT_DIR"] else { return }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = request.messages.filter { $0.role == "system" }.map(\.content)
    let structured = request.contentMessages.filter { $0.role == "system" }.map { message in
        message.content.compactMap { part -> String? in
            if case .text(let text) = part { return text }; return nil
        }.joined(separator: "\n")
    }
    let snapshot: [String: Any] = [
        "kind": "synthetic provider-boundary capture",
        "scenario": name,
        "legacySystemMessages": legacy,
        "structuredSystemMessages": structured,
        "toolNames": request.toolSchemas.map(\.name),
        "systemCharacters": legacy.reduce(0) { $0 + $1.count },
        "systemUTF8Bytes": legacy.reduce(0) { $0 + $1.utf8.count },
        "realModelInvoked": false
    ]
    try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
}
