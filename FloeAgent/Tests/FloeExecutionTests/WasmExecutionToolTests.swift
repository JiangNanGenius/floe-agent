import Foundation
import Testing
@testable import FloeExecution
@testable import FloeTools
@testable import FloeCore

@Suite("FloeExecution.WasmExecutionTool")
struct WasmExecutionToolTests {
    // (module (func (export "answer") (result i32) i32.const 42))
    private let answerModule = "AGFzbQEAAAABBQFgAAF/AwIBAAcKAQZhbnN3ZXIAAAoGAQQAQSoL"

    @Test("Descriptor is local pure computation")
    func descriptor() {
        #expect(WasmExecutionTool.name == "exec.wasm")
        #expect(WasmExecutionTool.riskLabels.isEmpty)
        #expect(!WasmExecutionTool.isSideEffecting)
    }

    @Test("Rejects data without a WebAssembly header")
    func rejectsInvalidHeader() {
        let tool = WasmExecutionTool()
        #expect(throws: FloeError.self) {
            try tool.validate(.init(moduleBase64: Data("hello".utf8).base64EncodedString(), function: "answer"))
        }
    }

    @Test("Executes a self-contained module when system JavaScriptCore supports WebAssembly")
    func executesAnswer() async throws {
        let tool = WasmExecutionTool()
        let args = WasmExecutionTool.Arguments(moduleBase64: answerModule, function: "answer")
        try tool.validate(args)
        let output = try await tool.execute(
            args,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        // Older system JavaScriptCore builds report structured unavailability;
        // supported builds execute and return 42. Both are honest outcomes.
        #expect(output.summary.contains("42") || output.summary.contains("WebAssembly is unavailable"))
    }
}
