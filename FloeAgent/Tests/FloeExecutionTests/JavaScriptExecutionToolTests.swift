// Internal business JavaScript remains supported; model execution is Linux-only.
import Foundation
import Testing
@testable import FloeExecution
import FloeTools
import FloeCore

@Suite("Internal JavaScript and Linux-only registration")
struct JavaScriptExecutionToolTests {
    @Test("Production catalog and runner reject all retired execution names")
    func retiredRuntimesAbsent() {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry)
        for name in RetiredExecutionTools.names {
            #expect(registry.runner(named: name) == nil)
            #expect(ToolCatalog.descriptor(named: name) == nil)
        }
    }

    @Test("Internal JS processor still computes and separates stderr")
    func internalBusinessProcessor() async throws {
        let tool = JavaScriptExecutionTool()
        let result = try await tool.execute(.init(script: "console.log('out'); console.error('err'); printJSON({answer: 1+1});"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(result.summary.contains("status=ok"))
        #expect(result.summary.contains("\"answer\":2"))
        #expect(result.summary.contains("--- stdout ---\nout"))
        #expect(result.summary.contains("--- stderr ---\nerr"))
    }

    @Test("Internal JS errors and validation retain real failure information")
    func internalFailure() async throws {
        let tool = JavaScriptExecutionTool()
        #expect(throws: FloeError.self) { try tool.validate(.init(script: " ")) }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(script: String(repeating: "x", count: JavaScriptExecutionTool.maxScriptBytes + 1)))
        }
        let result = try await tool.execute(.init(script: "throw new Error('kaboom')"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(result.exitStatus == 1)
        #expect(result.summary.contains("kaboom"))
    }

    @Test("Internal cancellation precedes evaluation")
    func cancelledInternalProcessor() async throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        await #expect(throws: (any Error).self) {
            try await JavaScriptExecutionTool().execute(.init(script: "console.log('never')"),
                context: ToolContext(runID: UUID(), cancellation: cancellation))
        }
    }
}
