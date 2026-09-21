// FloeAgentRuntimeTests — false success claims and the receipt contract.
//
// Evidence: a local model run made no tool call and still reported a file as
// created. These tests pin the pure claim detector and the runtime's bounded
// corrective retry, then the honest failure after a repeated claim.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

@Suite("FloeAgentRuntime.ActionClaimGate")
struct ActionClaimGateTests {
    private let gate = ActionClaimGate()

    @Test("A past-tense creation claim without a receipt requests correction")
    func claimRequestsCorrection() {
        let directive = gate.evaluate(
            claim: "已创建 test.txt 文件并保存。",
            receipts: [],
            correctiveRetries: 0
        )
        #expect(directive == .requestCorrection)
    }

    @Test("A second unsubstantiated claim fails the run honestly")
    func secondClaimFails() {
        let directive = gate.evaluate(
            claim: "已创建 test.txt 文件并保存。",
            receipts: [],
            correctiveRetries: 1
        )
        #expect(directive == .failRun)
    }

    @Test("A successful side-effecting receipt legitimizes the claim")
    func receiptAllowsClaim() {
        let directive = gate.evaluate(
            claim: "已创建 test.txt 文件并保存。",
            receipts: [.init(toolName: "workspace.createFile", status: .ok)],
            correctiveRetries: 0
        )
        #expect(directive == .allow)
    }

    @Test("Any successful receipt disarms the gate so real tool runs are never second-guessed")
    func anySuccessfulReceiptAllows() {
        let directive = gate.evaluate(
            claim: "文件已写入。",
            receipts: [.init(toolName: "test.echo", status: .ok)],
            correctiveRetries: 0
        )
        #expect(directive == .allow)
    }

    @Test("Failed receipts do not legitimize a success claim")
    func failedReceiptDoesNotAllowClaim() {
        let directive = gate.evaluate(
            claim: "The file was created successfully.",
            receipts: [.init(toolName: "workspace.createFile", status: .failed)],
            correctiveRetries: 0
        )
        #expect(directive == .requestCorrection)
    }

    @Test("Negated and ordinary messages are never treated as success claims")
    func negatedAndOrdinaryTextAllowed() {
        let cases = [
            "未能创建文件，原因是存储空间不足。",
            "我没有保存这个文件。",
            "I could not save the file.",
            "你好，需要我做什么？",
            "The document is open in the editor."
        ]
        for text in cases {
            #expect(
                gate.evaluate(claim: text, receipts: [], correctiveRetries: 0) == .allow,
                Comment(rawValue: text)
            )
        }
    }
}

@Suite("FloeAgentRuntime.ActionClaimFlow")
struct ActionClaimFlowTests {
    private func makeLocalProvider() -> ProviderProfile {
        var provider = TestFixtures.localhostProvider()
        provider.kind = .local
        return provider
    }

    private func makeRuntime(adapter: MockAdapter, executor: MockExecutor, sink: MockSink) -> FloeAgentRuntime {
        FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: makeLocalProvider(),
                model: TestFixtures.testModel(providerID: makeLocalProvider().id),
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: adapter,
            policy: AutomaticApprovalPolicy(backend: RecordingApprovalBackend()),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
    }

    private func makeExecutor() -> MockExecutor {
        let executor = MockExecutor()
        executor.descriptors["workspace.createFile"] = ToolCatalog.Descriptor(
            name: "workspace.createFile",
            riskLabels: [],
            isSideEffecting: true
        )
        executor.descriptors["workspace.readFile"] = ToolCatalog.Descriptor(
            name: "workspace.readFile",
            riskLabels: [.readsFiles],
            isSideEffecting: false
        )
        return executor
    }

    /// The three-turn chain from the device evidence: a claim with no call,
    /// one bounded correction, the real tool call, then a truthful answer.
    @Test("A false creation claim is corrected into a real call, then completes")
    func falseClaimIsCorrectedThenCompletes() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.textDelta(.init(text: "已创建 test.txt 文件并保存。")), .completed(.init(stopReason: .endTurn))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "create-1",
                toolName: "workspace.createFile",
                arguments: #"{"path":"test.txt","content":"Hello, this is a test file created by Floe!"}"#
            )), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "已创建 test.txt 文件并保存。")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = makeExecutor()
        let sink = MockSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: sink)

        try await runtime.start(goal: "试一下创建一个文本文件并保存")

        #expect(adapter.requests.count == 3)
        #expect(executor.executedCalls.map(\.toolName) == ["workspace.createFile"])
        // The correction names the missing receipt instead of silently
        // accepting the claim.
        let correction = try #require(adapter.requests.dropFirst().first)
        #expect(correction.messages.contains {
            $0.role == "system" && $0.content.contains("no successful tool result")
        })
        guard case .completed = await runtime.state else {
            Issue.record("Expected the corrected run to complete, got \(await runtime.state.name)")
            return
        }
    }

    /// A repeated claim after the one correction must end honestly instead of
    /// reporting success.
    @Test("A repeated false claim fails the run recoverably without a receipt")
    func repeatedFalseClaimFailsHonestly() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.textDelta(.init(text: "已创建 test.txt 文件并保存。")), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "已创建 test.txt 文件并保存。")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = makeExecutor()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: MockSink())

        try await runtime.start(goal: "帮我创建一个文件")

        #expect(adapter.requests.count == 2)
        #expect(executor.executedCalls.isEmpty)
        guard case .failed(let failure) = await runtime.state else {
            Issue.record("Expected a recoverable failure, got \(await runtime.state.name)")
            return
        }
        #expect(failure.isRecoverable)
        #expect(failure.message.contains("without a successful tool result"))
    }

    /// Sequential multi-tool work: create, then read the same file, then a
    /// truthful summary — with the chain's schemas still offered on the later
    /// turns (no tools.list round-trip in between).
    @Test("A local run chains create then read with schemas still offered")
    func sequentialLocalToolChain() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(
                id: "create-chain",
                toolName: "workspace.createFile",
                arguments: #"{"path":"test.txt","content":"hello"}"#
            )), .completed(.init(stopReason: .toolUse))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "read-chain",
                toolName: "workspace.readFile",
                arguments: #"{"path":"test.txt"}"#
            )), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "test.txt 的内容是 hello。")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = makeExecutor()
        let runtime = makeRuntime(adapter: adapter, executor: executor, sink: MockSink())

        try await runtime.start(goal: "创建一个文件再读回来")

        #expect(executor.executedCalls.map(\.toolName) == ["workspace.createFile", "workspace.readFile"])
        #expect(adapter.requests.count == 3)
        // The second and third requests still carry the file schemas.
        for request in adapter.requests.dropFirst() {
            let names = Set(request.toolSchemas.map(\.name))
            #expect(names.contains("workspace.readFile"))
            #expect(names.contains("workspace.createFile"))
        }
        guard case .completed = await runtime.state else {
            Issue.record("Expected the chain to complete, got \(await runtime.state.name)")
            return
        }
    }

    /// Ordinary conversation must never be disturbed by the gate.
    @Test("Ordinary local chat completes in one turn")
    func ordinaryChatIsUntouched() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "你好！有什么可以帮你？")), .completed(.init(stopReason: .endTurn))]]
        let runtime = makeRuntime(adapter: adapter, executor: makeExecutor(), sink: MockSink())

        try await runtime.start(goal: "你好")

        #expect(adapter.requests.count == 1)
        guard case .completed = await runtime.state else {
            Issue.record("Expected ordinary chat to complete, got \(await runtime.state.name)")
            return
        }
    }
}
