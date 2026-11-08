import Foundation
import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Native authoring discovery contracts")
struct NativeAuthoringDiscoveryContractTests {
    private func descriptor(_ name: String, schema: String = #"{"type":"object","properties":{},"additionalProperties":false}"#) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: "A registered authoring operation.", parametersJSON: schema, riskLabels: [], isSideEffecting: false)
    }
    @Test func shortPCBQueriesFindOnlyOfferedToolsAndInspectBeforeMutating() {
        let offered = ["studio.chemistry", "studio.edit", "studio.run", "studio.read", "studio.list", "exec.shell"].map { descriptor($0) }
        for query in ["PCB", "EDA", "electronics", "电路", "原理图", "铜区", "走线", "焊盘", "封装"] {
            let found = ToolDiscovery.matches(query: query, descriptors: offered).map(\.name)
            #expect(Array(found.prefix(2)) == ["studio.list", "studio.read"])
            #expect(Set(found) == Set(offered.filter { $0.name.hasPrefix("studio.") }.map(\.name)))
        }
        #expect(ToolDiscovery.matches(query: "电路", descriptors: [descriptor("web.search"), descriptor("exec.shell")]).isEmpty)
        let explicit = ToolDiscovery.matches(query: "exec.shell", descriptors: offered).map(\.name)
        #expect(explicit == ["exec.shell"])
        #expect(ToolDiscovery.matches(query: "PCB Python", descriptors: offered).contains { $0.name == "exec.shell" })
    }
    @Test func shortNotesQueriesPreserveTheActualReadOnlyCeiling() {
        let offered = [descriptor("notes.edit"), descriptor("notes.read"), descriptor("web.search")]
        for query in ["手记", "笔记", "笔记本", "notebook"] {
            #expect(ToolDiscovery.matches(query: query, descriptors: offered).map(\.name) == ["notes.read", "notes.edit"])
            #expect(ToolDiscovery.matches(query: query, descriptors: [descriptor("notes.read")]).map(\.name) == ["notes.read"])
        }
    }
    @Test func nativeMeaningSurvivesDeferralWithoutSlicingSchemasOrInventingAvailability() {
        let search = ToolDiscovery.descriptor
        let large = descriptor("studio.read", schema: #"{"type":"object","properties":{"projectID":{"type":"string","description":""# + String(repeating: "source", count: 1_000) + #""}},"required":["projectID"],"additionalProperties":false}"#)
        let list = descriptor("studio.list")
        let offered = [large, list, search]
        let plan = ToolSchemaOfferPlanner.plan(descriptors: offered, tokenBudget: ToolSchemaOfferPlanner.tokenCost(search), alwaysKeep: ["tools.search"])
        #expect(plan.offered.map(\.name) == ["tools.search"])
        #expect(plan.offered[0].parametersJSON == search.parametersJSON)
        #expect(plan.deferred.contains("studio.list") && plan.oversized.contains("studio.read"))
        let index = ToolDiscovery.index(offered)
        #expect(index.contains("Native first") && index.contains("activeProjectID") && index.contains("deferred is not missing"))
        #expect(!ToolDiscovery.index([descriptor("web.search"), search]).contains("Native first"))
        let args = try? JSONDecoder().decode(DiscoveryQueries.self, from: Data(NativeAuthoringGuidance.examples(for: offered.map(\.name))[0].argumentsJSON.utf8))
        #expect((try? args?.validated()) == ["studio.list", "studio.read"])
    }
    @Test func compactAndCloudPoliciesRetainUserRouteAndNoDeniedFallback() {
        let full = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx", toolsAvailable: true)
        let local = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx", compactForLocal: true)
        for prompt in [full, local] {
            #expect(prompt.contains("用户指定路径优先"))
            #expect(prompt.contains("configured native operation"))
            #expect(prompt.contains("denied") || prompt.contains("denial"))
        }
        #expect(local.utf8.count < 8_000)
    }
}
