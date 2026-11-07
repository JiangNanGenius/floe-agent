import Foundation
import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Workbench tools in the effective discovery catalog")
struct WorkbenchToolDiscoveryTests {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: "Read or operate the current native work.",
              parametersJSON: #"{"type":"object","properties":{}}"#, riskLabels: [], isSideEffecting: false)
    }

    @Test func shortChineseWorkQueriesFindTheOfferedNativeRoute() {
        let offered = ["studio.read", "studio.edit", "studio.run", "studio.chemistry", "studio.simulation"].map(descriptor)
        for query in ["化学", "音乐", "图示", "切片", "打印", "画布", "物理", "有限元", "工程分析"] {
            let found = ToolDiscovery.matches(query: query, descriptors: offered)
            #expect(!found.isEmpty, "No offered native route for \(query)")
            #expect(found.allSatisfy { item in offered.contains { $0.name == item.name } })
        }
    }

    @Test func audioAndBiologyQueriesRespectTheActualOfferedCeiling() {
        let offered = ["audio.inspect", "biology.readProject"].map(descriptor)
        #expect(ToolDiscovery.matches(query: "音频波形", descriptors: offered).map(\.name) == ["audio.inspect"])
        #expect(ToolDiscovery.matches(query: "蛋白", descriptors: offered).map(\.name) == ["biology.readProject"])
        let restricted = [descriptor("web.search")]
        #expect(ToolDiscovery.matches(query: "音频波形", descriptors: restricted).isEmpty)
        #expect(ToolDiscovery.matches(query: "蛋白", descriptors: restricted).isEmpty)
    }
}
