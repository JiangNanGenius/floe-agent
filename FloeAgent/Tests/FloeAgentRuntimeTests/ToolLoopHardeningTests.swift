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
        storage.withLock { $0.append(request) }
        // Unique id per turn → unique idempotency key per turn.
        let call = try! ToolCall( // literals only; cannot fail
            id: "loop_\(UUID().uuidString)",
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

@Suite("FloeAgentRuntime.ToolLoopHardening")
struct ToolLoopHardeningTests {

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

    @Test("non-consecutive identical outcomes still trip no-progress guard")
    func nonConsecutiveNoProgressStops() async throws {
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

        // The third unchanged observation is now the hard stop; alternating
        // unrelated calls no longer lets a repeated route evade the guard.
        #expect(executor.executedCalls.count == 5)
        guard case .completed(let completion) = await runtime.state else {
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
    }

    @Test("equivalent visual inspection failures stop after three attempts")
    func equivalentVisualFailuresStop() async throws {
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
            Issue.record("expected completed no-progress finalization")
            return
        }
        #expect(completion.stopReason == .noProgress)
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
                callID: "loop-\(index)",
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
                callID: "audit-\(index)",
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

    @Test("The first model message is the injected system context with tool names")
    func systemContextInjected() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date()
        ))

        // Register a catalog tool so the injected list is non-empty.
        ToolCatalog.register(WorkspaceProbeTool.self)

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
                executionTarget: "local"
            )
        )

        try await service.start(goal: "context please")

        let request = try #require(adapter.requests.first)
        let first = try #require(request.messages.first)
        #expect(first.role == "system")
        #expect(first.content.contains("Workspace: Demo Project"))
        #expect(first.content.contains("src/main.swift"))
        #expect(first.content.contains("Execution target: local"))
        #expect(first.content.contains("Available tools:"))
        #expect(first.content.contains("test.contextProbe"))
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
        let message = ConversationRunService.buildContextMessage(
            .init(availableToolNames: ["workspace.listDirectory", "exec.localPython"]),
            toolsAvailable: false
        )

        #expect(message.contains("native tool calling is disabled"))
        #expect(!message.contains("workspace.listDirectory"))
        #expect(!message.contains("exec.localPython"))
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

        #expect(message.contains("browser.observe and stable DOM refs first"))
        #expect(message.contains("When DOM structure is insufficient"))
        #expect(message.contains("browser.clickVisualText"))
        #expect(message.contains("fresh evidence from the current page"))
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
