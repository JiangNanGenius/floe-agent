// FloeToolsTests — Catalog registration, lookup, and whitelist semantics.

import Foundation
import Testing
@testable import FloeTools
@testable import FloeCore

/// Concrete test tools registered into the catalog.
private struct EchoTool: AgentTool {
    struct Arguments: Decodable, Sendable { var text: String }

    static let name = "test.echo"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false

    func validate(_ args: Arguments) throws {
        if args.text.isEmpty { throw FloeError.validationFailed("text required") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: args.text, fullOutputSHA256: "")
    }
}

private struct DangerTool: AgentTool {
    struct Arguments: Decodable, Sendable { var command: String }

    static let name = "test.danger"
    static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .modifiesRemoteSystem]
    static let isSideEffecting = true

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "ran", fullOutputSHA256: "")
    }
}

@Suite("FloeTools.ToolCatalog")
struct ToolCatalogTests {

    @Test("Register and look up a tool descriptor")
    func registerAndLookup() {
        ToolCatalog.register(EchoTool.self)
        let descriptor = ToolCatalog.descriptor(named: "test.echo")
        #expect(descriptor != nil)
        #expect(descriptor?.name == "test.echo")
        #expect(descriptor?.isSideEffecting == false)
    }

    @Test("Unknown tool names return nil (whitelist rejection)")
    func unknownToolRejected() {
        #expect(ToolCatalog.descriptor(named: "evil.runArbitraryCode") == nil)
    }

    @Test("Risk labels survive registration")
    func riskLabelsPreserved() {
        ToolCatalog.register(DangerTool.self)
        let descriptor = ToolCatalog.descriptor(named: "test.danger")
        #expect(descriptor?.riskLabels.contains(.executesRemoteCommand) == true)
        #expect(descriptor?.riskLabels.contains(.modifiesRemoteSystem) == true)
        #expect(descriptor?.isSideEffecting == true)
        #expect(descriptor?.requiresHostScope == true)
    }

    @Test("GUI control does not imply remote host scope")
    func localGUIIsNotRemote() {
        let descriptor = ToolCatalog.Descriptor(
            name: "browser.click",
            riskLabels: [.controlsGUI],
            isSideEffecting: true
        )
        #expect(descriptor.requiresHostScope == false)
    }

    @Test("allDescriptors is sorted by name")
    func allDescriptorsSorted() {
        ToolCatalog.register(EchoTool.self)
        ToolCatalog.register(DangerTool.self)
        let names = ToolCatalog.allDescriptors.map(\.name)
        #expect(names == names.sorted())
    }

    @Test("CancellationToken: cancel flips state and throws")
    func cancellationToken() throws {
        let token = CancellationToken()
        #expect(!token.isCancelled)
        try token.throwIfCancelled()
        token.cancel()
        #expect(token.isCancelled)
        #expect(throws: FloeError.self) {
            try token.throwIfCancelled()
        }
    }

    @Test("Tool validate() rejects empty echo text")
    func toolValidation() throws {
        let tool = EchoTool()
        #expect(throws: FloeError.self) {
            try tool.validate(EchoTool.Arguments(text: ""))
        }
        try tool.validate(EchoTool.Arguments(text: "ok"))
    }
}
