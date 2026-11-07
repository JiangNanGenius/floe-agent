import Testing
import FloeTools
@testable import FloeAgentRuntime

@Suite("Native data analysis discovery")
struct NativeDataAnalysisDiscoveryTests {
    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: "Native numerical observations.",
              parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: false)
    }

    @Test("Short Chinese and English requests find only the offered data tool")
    func analysisQueries() {
        let offered = [descriptor("data.analyze"), descriptor("web.search")]
        for query in ["统计", "回归", "直方图", "相关系数", "数据分析", "statistics", "regression", "histogram", "data.analyze"] {
            #expect(ToolDiscovery.matches(query: query, descriptors: offered).map(\.name) == ["data.analyze"])
        }
    }

    @Test("Discovery cannot recreate an unavailable data tool or a retired evaluator")
    func permissionCeiling() {
        let offered = [descriptor("web.search"), descriptor("exec.compatEvaluator")]
        #expect(ToolDiscovery.matches(query: "统计", descriptors: offered).isEmpty)
        #expect(ToolDiscovery.matches(query: "data.analyze", descriptors: offered).isEmpty)
        #expect(ToolDiscovery.matches(query: "exec.compatEvaluator", descriptors: offered).isEmpty)
    }
}
