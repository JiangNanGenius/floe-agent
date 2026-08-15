// FloeExecutionTests — exec.javascript tool: descriptor contract, argument
// validation, outcome mapping, and the full execution loop through
// CatalogToolExecutor (decode → validate → run → ToolResult).
// See docs/ARCHITECTURE_EXECUTION.md §3.4/§6 and the workspace-tool
// dual-registration convention (ARCHITECTURE_AGENT_WORKSPACE.md §10).

import Foundation
import Testing
@testable import FloeExecution
@testable import FloeTools
@testable import FloeCore
import FloeModels
import FloeAgentRuntime

@Suite("FloeExecution.JavaScriptExecutionTool")
struct JavaScriptExecutionToolTests {

    private func makeContext() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    private func makeCall(_ argumentsJSON: String) throws -> ToolCall {
        try ToolCall(
            id: "call-\(UUID().uuidString)",
            toolName: JavaScriptExecutionTool.name,
            argumentsJSON: Data(argumentsJSON.utf8),
            scope: .local
        )
    }

    // MARK: Descriptor contract

    @Test("Descriptor: non-side-effecting, no risk labels, correct name")
    func descriptorContract() {
        let tool = JavaScriptExecutionTool()
        #expect(JavaScriptExecutionTool.name == "exec.javascript")
        #expect(JavaScriptExecutionTool.isSideEffecting == false)
        #expect(JavaScriptExecutionTool.riskLabels.isEmpty)

        let erased = AnyAgentTool(tool)
        #expect(erased.descriptor.name == "exec.javascript")
        #expect(erased.descriptor.isSideEffecting == false)
        #expect(erased.descriptor.riskLabels.isEmpty)
        #expect(erased.descriptor.parametersJSON.contains("\"script\""))
    }

    // MARK: Validation

    @Test("Empty script fails validation")
    func validateEmptyScript() async throws {
        let tool = JavaScriptExecutionTool()
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: "   "))
        }
    }

    @Test("Script over 64 KiB fails validation")
    func validateOversizeScript() async throws {
        let tool = JavaScriptExecutionTool()
        let big = String(repeating: "x", count: JavaScriptExecutionTool.maxScriptBytes + 1)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: big))
        }
    }

    @Test("Invalid arguments JSON fails decoding through the executor")
    func invalidArgumentsJSON() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()
        let call = try makeCall(#"{"other":1}"#)
        let result = try await executor.execute(call, context: makeContext())
        #expect(result.status == .failed)
        #expect(result.outputSummary.contains("Invalid arguments"))
    }

    // MARK: Execution through the full loop

    @Test("console.log(1+1) executes end to end; the model-readable result contains 2")
    func consoleLogThroughExecutor() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()

        // Descriptor must be visible (compile-time registration)…
        #expect(executor.descriptor(named: "exec.javascript") != nil)

        let call = try makeCall(#"{"script":"console.log(1 + 1); printJSON({answer: 2});"}"#)
        let result = try await executor.execute(call, context: makeContext())

        #expect(result.status == .ok)
        #expect(result.outputSummary.contains("status=ok"))
        #expect(result.outputSummary.contains("2"))
        #expect(result.outputSummary.contains(#"result={"answer":2}"#) || result.outputSummary.contains(#""answer":2"#))
        #expect(!result.outputDigest.isEmpty)
    }

    @Test("console.error lands in the stderr section, separate from stdout")
    func stderrSectionThroughExecutor() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()
        let call = try makeCall(
            #"{"script":"console.log('hello-out'); console.error('boom-err');"}"#
        )
        let result = try await executor.execute(call, context: makeContext())
        #expect(result.status == .ok)
        #expect(result.outputSummary.contains("--- stdout ---"))
        #expect(result.outputSummary.contains("hello-out"))
        #expect(result.outputSummary.contains("--- stderr ---"))
        #expect(result.outputSummary.contains("boom-err"))
        // stdout section must not contain the stderr line.
        let stdoutSection = result.outputSummary
            .components(separatedBy: "--- stderr ---").first ?? ""
        #expect(!stdoutSection.contains("boom-err"))
    }

    @Test("A JS exception returns an ok result carrying the error status")
    func jsExceptionMapping() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()
        let call = try makeCall(#"{"script":"throw new Error('kaboom');"}"#)
        let result = try await executor.execute(call, context: makeContext())
        #expect(result.status == .ok)
        #expect(result.outputSummary.contains("status=exception"))
        #expect(result.outputSummary.contains("kaboom"))
        #expect(result.exitStatus == 1)
    }

    @Test("A runaway script maps to a timedOut result within the deadline")
    func timeoutMapping() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()
        let started = Date()
        let call = try makeCall(#"{"script":"while (true) {}","timeout":0.5}"#)
        let result = try await executor.execute(call, context: makeContext())
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.status == .ok)
        #expect(result.outputSummary.contains("status=timedOut"))
        #expect(result.outputSummary.contains("afterMs=500"))
        #expect(result.exitStatus == 124)
        #expect(elapsed < 5.0)
    }

    @Test("Cancellation before execution propagates as a cancelled ToolResult")
    func cancellationMapping() async throws {
        registerExecutionTools(includeOnDeviceJavaScript: true)
        let executor = CatalogToolExecutor()
        let token = CancellationToken()
        token.cancel()
        let call = try makeCall(#"{"script":"console.log('never');"}"#)
        let result = try await executor.execute(
            call,
            context: ToolContext(runID: UUID(), cancellation: token)
        )
        #expect(result.status == .cancelled)
    }

    // MARK: Registration

    @Test("Production registration omits the on-device JavaScript runner")
    func productionRegistrationOmitsJavaScript() {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry)

        #expect(registry.runner(named: "exec.javascript") == nil)
    }

    @Test("registerExecutionTools wires catalog + runner on the shared registry")
    func dualRegistration() async throws {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry, includeOnDeviceJavaScript: true)

        #expect(ToolCatalog.descriptor(named: "exec.javascript") != nil)
        let runner = registry.runner(named: "exec.javascript")
        #expect(runner != nil)

        let output = try await runner?.execute(
            argumentsJSON: Data(#"{"script":"console.log('wired');"}"#.utf8),
            context: makeContext()
        )
        #expect(output?.summary.contains("wired") == true)
    }
}
