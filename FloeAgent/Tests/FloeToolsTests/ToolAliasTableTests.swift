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

    @Test func historySynonymsExpandToTheConversationGroup() {
        // Chinese and English history terms must group-search the conversation
        // tools so a vague "查一下历史" request discovers the whole pair.
        let terms = ToolAliasTable.synonyms["conversation"] ?? []
        for expected in ["历史", "任务历史", "聊天记录", "会话记录", "history", "chat history", "以前", "之前", "上次", "查找历史"] {
            #expect(terms.contains(expected), "missing conversation synonym: \(expected)")
        }
        // Every synonym group token stays lowercased for query containment.
        for token in terms {
            #expect(token == token.lowercased())
        }
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
