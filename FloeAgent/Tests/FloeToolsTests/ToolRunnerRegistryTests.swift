// FloeToolsTests — ToolRunnerRegistry registration/lookup and the
// CatalogToolExecutor execution closed loop.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6: descriptor missing → reject;
// runner missing → structured "No runner registered" failure; otherwise
// decode → validate → execute → wrap into ToolResult.

import Foundation
import Testing
import Crypto
@testable import FloeTools
@testable import FloeCore
import FloeModels
import FloeAgentRuntime

/// Concrete runner tool: echoes its `text` argument with a real digest.
private struct EchoRunnerTool: AgentTool {
    struct Arguments: Decodable, Sendable { var text: String }

    static let name = "test.registryEcho"
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {
        if args.text.isEmpty { throw FloeError.validationFailed("text required") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let digest = SHA256.hash(data: Data(args.text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: "echo:\(args.text)", fullOutputSHA256: digest)
    }
}

/// Runner tool that always honors cooperative cancellation.
private struct CancellationAwareTool: AgentTool {
    struct Arguments: Decodable, Sendable {}

    static let name = "test.registryCancelling"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return ToolExecutionOutput(summary: "should-not-reach", fullOutputSHA256: "")
    }
}

/// Descriptor-only tool (registered in the catalog, never in a registry).
private struct UnrunTool: AgentTool {
    struct Arguments: Decodable, Sendable {}

    static let name = "test.registryUnrun"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "unreachable", fullOutputSHA256: "")
    }
}

@Suite("FloeTools.ToolRunnerRegistry")
struct ToolRunnerRegistryTests {

    private func makeCall(_ toolName: String, argumentsJSON: String = "{}") throws -> ToolCall {
        try ToolCall(
            id: "call-\(UUID().uuidString)",
            toolName: toolName,
            argumentsJSON: Data(argumentsJSON.utf8),
            scope: .local
        )
    }

    private func makeContext(cancellation: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: UUID(), approvalGrantID: nil, cancellation: cancellation)
    }

    // MARK: Registration & lookup

    @Test("Register and look up a runner by name")
    func registerAndLookup() {
        let registry = ToolRunnerRegistry()
        #expect(registry.runner(named: "test.registryEcho") == nil)

        registry.register(EchoRunnerTool())
        let runner = registry.runner(named: "test.registryEcho")
        #expect(runner != nil)
        #expect(runner?.descriptor.name == "test.registryEcho")
        #expect(runner?.descriptor.riskLabels == [.readsFiles])
        #expect(runner?.descriptor.isSideEffecting == false)
    }

    @Test("Unknown names return nil")
    func unknownNameReturnsNil() {
        let registry = ToolRunnerRegistry()
        registry.register(EchoRunnerTool())
        #expect(registry.runner(named: "test.noSuchTool") == nil)
    }

    @Test("Re-registering replaces the previous runner")
    func reRegisterReplaces() async throws {
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.replaceable", riskLabels: [], isSideEffecting: false
            ),
            run: { _, _ in ToolExecutionOutput(summary: "first", fullOutputSHA256: "") }
        ))
        registry.register(AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "test.replaceable", riskLabels: [], isSideEffecting: false
            ),
            run: { _, _ in ToolExecutionOutput(summary: "second", fullOutputSHA256: "") }
        ))
        let output = try await registry.runner(named: "test.replaceable")?
            .execute(argumentsJSON: Data("{}".utf8), context: makeContext())
        #expect(output?.summary == "second")
    }

    @Test("Runtime descriptors are visible and namespaced removal is bounded")
    func runtimeDescriptorsAndRemoval() {
        let registry = ToolRunnerRegistry()
        let first = ToolCatalog.Descriptor(
            name: "mcp.alpha.search", riskLabels: [], isSideEffecting: false
        )
        let second = ToolCatalog.Descriptor(
            name: "mcp.beta.search", riskLabels: [], isSideEffecting: false
        )
        registry.register(AnyAgentTool(
            descriptor: first,
            run: { _, _ in ToolExecutionOutput(summary: "alpha", fullOutputSHA256: "") }
        ))
        registry.register(AnyAgentTool(
            descriptor: second,
            run: { _, _ in ToolExecutionOutput(summary: "beta", fullOutputSHA256: "") }
        ))

        #expect(registry.descriptor(named: first.name)?.name == first.name)
        #expect(registry.allDescriptors.map(\.name) == [first.name, second.name])

        registry.unregister { $0.hasPrefix("mcp.alpha.") }
        #expect(registry.runner(named: first.name) == nil)
        #expect(registry.runner(named: second.name) != nil)
    }

    // MARK: Execution closed loop through CatalogToolExecutor

    @Test("CatalogToolExecutor runs a registered runner end to end")
    func executorClosedLoop() async throws {
        let registry = ToolRunnerRegistry()
        registry.register(EchoRunnerTool())
        let executor = CatalogToolExecutor(runners: registry)

        let call = try makeCall("test.registryEcho", argumentsJSON: #"{"text":"hi"}"#)
        let result = try await executor.execute(call, context: makeContext())

        #expect(result.callID == call.id)
        #expect(result.status == .ok)
        #expect(result.outputSummary == "echo:hi")
        let expectedDigest = SHA256.hash(data: Data("hi".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(result.outputDigest == expectedDigest)
    }

    @Test("CatalogToolExecutor exposes a runtime-only descriptor")
    func executorExposesRuntimeDescriptor() {
        let registry = ToolRunnerRegistry()
        let descriptor = ToolCatalog.Descriptor(
            name: "mcp.example.lookup", riskLabels: [], isSideEffecting: false
        )
        registry.register(AnyAgentTool(
            descriptor: descriptor,
            run: { _, _ in ToolExecutionOutput(summary: "ok", fullOutputSHA256: "") }
        ))
        let executor = CatalogToolExecutor(runners: registry)

        #expect(executor.descriptor(named: descriptor.name)?.name == descriptor.name)
        #expect(executor.allDescriptors.contains { $0.name == descriptor.name })
    }

    @Test("CatalogToolExecutor rejects a runner replaced after approval")
    func executorRejectsChangedAuthority() async throws {
        let registry = ToolRunnerRegistry()
        let original = ToolCatalog.Descriptor(
            name: "mcp.example.mutate",
            toolDescription: "Original operation",
            parametersJSON: #"{"type":"object","additionalProperties":false}"#,
            riskLabels: [.networkAccess, .modifiesRemoteSystem],
            isSideEffecting: true
        )
        registry.register(AnyAgentTool(
            descriptor: original,
            run: { _, _ in ToolExecutionOutput(summary: "original", fullOutputSHA256: "") }
        ))
        let approvedIdentity = original.authorizationIdentity

        let replacement = ToolCatalog.Descriptor(
            name: original.name,
            toolDescription: "Replacement operation",
            parametersJSON: #"{"type":"object","additionalProperties":true}"#,
            riskLabels: [.networkAccess, .modifiesRemoteSystem],
            isSideEffecting: true
        )
        registry.register(AnyAgentTool(
            descriptor: replacement,
            run: { _, _ in ToolExecutionOutput(summary: "replacement", fullOutputSHA256: "") }
        ))

        let executor = CatalogToolExecutor(runners: registry)
        let call = try makeCall(original.name)
        let result = try await executor.execute(
            call,
            expectedAuthorizationIdentity: approvedIdentity,
            context: makeContext()
        )
        #expect(result.status == .denied)
        #expect(result.outputSummary.contains("authority changed"))
    }

    @Test("Descriptor present but no runner → structured failure")
    func missingRunnerStructuredFailure() async throws {
        ToolCatalog.register(UnrunTool.self)
        let registry = ToolRunnerRegistry()
        let executor = CatalogToolExecutor(runners: registry)

        // Static-only declarations never advertise unavailable capabilities.
        #expect(executor.descriptor(named: "test.registryUnrun") == nil)
        #expect(!executor.allDescriptors.contains { $0.name == "test.registryUnrun" })

        // A stale model call still fails in a structured way.
        let call = try makeCall("test.registryUnrun")
        let result = try await executor.execute(call, context: makeContext())
        #expect(result.status == .failed)
        #expect(result.outputSummary.contains("No runner registered"))
        #expect(result.outputSummary.contains("test.registryUnrun"))
    }

    @Test("Runner errors become failed results; validation failures surface")
    func executionFailureWrapped() async throws {
        let registry = ToolRunnerRegistry()
        registry.register(EchoRunnerTool())
        let executor = CatalogToolExecutor(runners: registry)

        // Fails validation (empty text).
        let invalid = try makeCall("test.registryEcho", argumentsJSON: #"{"text":""}"#)
        let invalidResult = try await executor.execute(invalid, context: makeContext())
        #expect(invalidResult.status == .failed)
        #expect(invalidResult.outputSummary.contains("text required"))

        // Fails decoding (missing key).
        let malformed = try makeCall("test.registryEcho", argumentsJSON: #"{"other":1}"#)
        let malformedResult = try await executor.execute(malformed, context: makeContext())
        #expect(malformedResult.status == .failed)
        #expect(malformedResult.outputSummary.contains("Invalid arguments"))
    }

    // MARK: Cancellation propagation

    @Test("Cancelled token propagates as a cancelled ToolResult")
    func cancellationPropagation() async throws {
        let registry = ToolRunnerRegistry()
        registry.register(CancellationAwareTool())
        let executor = CatalogToolExecutor(runners: registry)

        let token = CancellationToken()
        token.cancel()
        let call = try makeCall("test.registryCancelling")
        let result = try await executor.execute(
            call,
            context: makeContext(cancellation: token)
        )
        #expect(result.status == .cancelled)
        #expect(result.callID == call.id)
    }
}
