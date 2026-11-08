import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

private final class ContractAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func record(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct ContractProbeTool: AgentTool {
    struct Arguments: Decodable, Sendable { let value: Int; let label: String }
    static let name = "test.contractCorrection"
    static let toolDescription = "Read a nonnegative value with its label."
    static let parametersJSON = #"{"type":"object","properties":{"value":{"type":"integer","minimum":0},"label":{"type":"string"}},"required":["value","label"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let attempts: ContractAttempts
    let minimum: Int
    init(attempts: ContractAttempts, minimum: Int = 0) { self.attempts = attempts; self.minimum = minimum }
    func validate(_ arguments: Arguments) throws {
        attempts.record(arguments.value)
        guard arguments.value >= minimum else { throw FloeError.validationFailed("value must be nonnegative") }
    }
    func execute(_ arguments: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let summary = "value=\(arguments.value)"
        return .init(summary: summary, fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)))
    }
}

/// The user/configuration replaces a tool between provider turns. Only the
/// provider transport is scripted; the real registry/executor/authority checks
/// must observe the changed descriptor rather than retaining a stale fence.
private final class ReplacingContractAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let lock = NSLock()
    private var turn = 0
    let runners: ToolRunnerRegistry
    let attempts: ContractAttempts
    init(runners: ToolRunnerRegistry, attempts: ContractAttempts) { self.runners = runners; self.attempts = attempts }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock(); let index = turn; turn += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            do {
                if index < 2 {
                    if index == 1 {
                        var replacement = AnyAgentTool(ContractProbeTool(attempts: attempts, minimum: -2))
                        replacement.descriptor = ToolCatalog.Descriptor(name: ContractProbeTool.name,
                            toolDescription: "Updated value contract", parametersJSON: ContractProbeTool.parametersJSON.replacingOccurrences(of: "\"minimum\":0", with: "\"minimum\":-2"),
                            riskLabels: [], isSideEffecting: false)
                        runners.register(replacement)
                    }
                    let call = try ToolCall(id: "changed-descriptor-\(index)", toolName: ContractProbeTool.name,
                        argumentsJSON: Data(#"{"value":-1,"label":"HTML"}"#.utf8), scope: .local)
                    continuation.yield(.toolRequest(call))
                    continuation.yield(.completed(.init(stopReason: .toolUse)))
                } else { continuation.yield(.completed(.init(stopReason: .endTurn))) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("Tool contract correction and retry fencing")
struct ToolContractCorrectionTests {
    private func call(_ id: String, _ arguments: String) throws -> ToolCall {
        try call(id, ContractProbeTool.name, arguments)
    }
    private func call(_ id: String, _ tool: String, _ arguments: String) throws -> ToolCall {
        try ToolCall(id: id, toolName: tool, argumentsJSON: Data(arguments.utf8), scope: .local)
    }

    @Test("an actual replacement descriptor permits the now-valid identical payload")
    func actualCapabilityReplacementAllowsRetry() async throws {
        let attempts = ContractAttempts(), runners = ToolRunnerRegistry()
        runners.register(ContractProbeTool(attempts: attempts))
        let adapter = ReplacingContractAdapter(runners: runners, attempts: attempts)
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: [ContractProbeTool.name]),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: CatalogToolExecutor(runners: runners))
        try await runtime.start(goal: "Use the newly configured tool after its contract has actually changed.")
        #expect(attempts.all == [-1, -1])
        guard case .completed(let completion) = await runtime.state else { Issue.record("Updated tool did not complete"); return }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("the third identical failure still reaches the unchanged-outcome guard")
    func failureAdviceDoesNotBypassOutcomeCounting() throws {
        var guardrail = ToolLoopGuard()
        for index in 1...3 {
            let request = try call("failure-\(index)", #"{"value":-1,"label":"HTML"}"#)
            let result = ToolResult(callID: request.id, status: .failed, outputSummary: "same failure", outputDigest: "")
            let decision = guardrail.record(call: request, result: result, isSideEffecting: false)
            if index == 1 { #expect(decision == nil) }
            else { #expect(decision?.shouldStop == (index == 3)) }
        }
    }

    @Test("schema reads do not dissolve a failed payload fence but actual progress does")
    func schemaReadPreservesFence() throws {
        var guardrail = ToolLoopGuard()
        let bad = try call("first", #"{"value":-1,"label":"HTML"}"#)
        _ = guardrail.record(call: bad, result: .init(callID: bad.id, status: .failed,
            outputSummary: "validation failed; retryable=false", outputDigest: ""), isSideEffecting: false)
        let search = try call("schema", "tools.search", #"{"queries":["test.contractCorrection"]}"#)
        _ = guardrail.record(call: search, result: .init(callID: search.id, status: .ok,
            outputSummary: ContractProbeTool.parametersJSON, outputDigest: ""), isSideEffecting: false)
        let reordered = try call("new-call-id", #"{"label":"HTML","value":-1}"#)
        #expect(guardrail.blockDecision(for: reordered)?.shouldStop == false)
        let corrected = try call("corrected", #"{"value":2,"label":"HTML"}"#)
        #expect(guardrail.blockDecision(for: corrected) == nil)
        let progress = try call("resolved-input", "test.resolve", "{}")
        _ = guardrail.record(call: progress, result: .init(callID: progress.id, status: .ok,
            outputSummary: "input changed", outputDigest: ""), isSideEffecting: true)
        #expect(guardrail.blockDecision(for: reordered) == nil)
    }

    @Test("real registry validation is suppressed after schema reload and corrected arguments execute")
    func registeredRuntimeAllowsCorrection() async throws {
        let attempts = ContractAttempts(), runners = ToolRunnerRegistry()
        runners.register(ContractProbeTool(attempts: attempts))
        let adapter = MockAdapter()
        let bad = try call("invalid", #"{"value":-1,"label":"HTML"}"#)
        let search = try call("schema", "tools.search", #"{"queries":["test.contractCorrection"]}"#)
        let repeated = try call("reordered", #"{"label":"HTML","value":-1}"#)
        let corrected = try call("corrected", #"{"value":7,"label":"HTML"}"#)
        adapter.script = [bad, search, repeated, corrected].map { [.toolRequest($0)] }
            + [[.completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: [ContractProbeTool.name]),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: CatalogToolExecutor(runners: runners))
        try await runtime.start(goal: "Correct the invalid value after reading its schema.")
        #expect(attempts.all == [-1, 7])
        let feedback = adapter.requests.flatMap(\.messages).map(\.content).joined(separator: "\n")
        #expect(feedback.contains("value must be nonnegative"))
        #expect(feedback.contains("retryable=false"))
        #expect(feedback.contains("Harness suppression:"))
        #expect(feedback.contains("value=7"))
        guard case .completed(let completion) = await runtime.state else { Issue.record("Run did not complete"); return }
        #expect(completion.stopReason == .endTurn)
    }

    @Test("repeated deterministic failures stop actual execution even with schema reads between them")
    func registeredRuntimeStopsIdenticalFailures() async throws {
        let attempts = ContractAttempts(), runners = ToolRunnerRegistry()
        runners.register(ContractProbeTool(attempts: attempts))
        let adapter = MockAdapter()
        let requests = try [
            call("bad-1", #"{"value":-1,"label":"HTML"}"#),
            call("schema-1", "tools.search", #"{"queries":["test.contractCorrection"]}"#),
            call("bad-2", #"{"label":"HTML","value":-1}"#),
            call("schema-2", "tools.search", #"{"queries":["test.contractCorrection"]}"#),
            call("bad-3", #"{"value":-1,"label":"HTML"}"#)
        ]
        adapter.script = requests.map { [.toolRequest($0)] } + [[.completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: [ContractProbeTool.name]),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: CatalogToolExecutor(runners: runners))
        try await runtime.start(goal: "Do not keep repeating a known invalid payload.")
        #expect(attempts.all == [-1])
        guard case .completed(let completion) = await runtime.state else { Issue.record("Run did not stop"); return }
        #expect(completion.stopReason == .noProgress)
    }
}
