import Foundation
import Testing
@testable import FloeTools

@Suite("Tool name compatibility")
struct ToolAliasTableTests {
    @Test func aliasesAreUnambiguousAndTerminal() {
        #expect(!ToolAliasTable.renamed.isEmpty)
        for (old, canonical) in ToolAliasTable.renamed {
            #expect(old != canonical)
            #expect(ToolAliasTable.renamed[canonical] == nil)
            #expect(ToolAliasTable.canonical(old) == canonical)
            #expect(ToolAliasTable.canonical(old.replacingOccurrences(of: ".", with: "_")) == canonical)
            #expect(ToolAliasTable.canonical(canonical) == canonical)
            #expect(ToolAliasTable.aliases(of: canonical).contains(old))
        }
        #expect(ToolAliasTable.canonical("unknown.tool") == "unknown.tool")
    }

    @Test func compatibilityRunnersRemainCallableWithoutDiscovery() {
        let registry = ToolRunnerRegistry()
        registry.register(AliasTestTool(), compatibilityOnly: true)
        #expect(registry.allDescriptors.isEmpty)
        #expect(registry.runner(named: "task.readPlan") != nil)
        registry.register(AliasTestTool())
        #expect(registry.allDescriptors.count == 1)
    }

    @Test func oldNamesResolveToCanonicalRunnerAndDescriptor() {
        let registry = ToolRunnerRegistry()
        registry.register(AliasTestTool())
        #expect(registry.runner(named: "task.readPlan")?.descriptor.name == "checklist.readPlan")
        #expect(registry.descriptor(named: "task.readPlan")?.name == "checklist.readPlan")
        #expect(registry.allDescriptors.map(\.name) == ["checklist.readPlan"])
    }
}

private struct AliasTestTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "checklist.readPlan"
    static let toolDescription = "Alias test"
    static let parametersJSON = #"{"type":"object","properties":{}}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        .init(digesting: "ok", exitStatus: 0)
    }
}
