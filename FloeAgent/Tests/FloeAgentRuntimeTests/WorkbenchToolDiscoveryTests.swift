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

    @Test func ordinaryEditorQueriesFindTheirAuthorizedToolsInBothLanguages() {
        let cases = [
            ("导入地理图层", "gis.import"), ("export GeoJSON", "gis.export"),
            ("编译论文", "latex.typeset"), ("typeset this paper", "latex.typeset"),
            ("修改建筑的墙面", "studio.edit"), ("edit a wall finish", "studio.edit"),
            ("换一个音色", "studio.edit"), ("export audio waveform", "audio.exportWaveform"),
            ("编辑照片", "studio.edit"), ("export a diagram", "studio.run"),
            ("制作演示文稿", "document.presentation.createDeck")
        ]
        let offered = Set(cases.map { $0.1 } + ["linux.port"]).sorted().map(descriptor)
        for (query, name) in cases {
            let found = ToolDiscovery.matches(query: query, descriptors: offered).map(\.name)
            #expect(found.contains(name), "Missing \(name) for \(query)")
            #expect(!found.contains("linux.port"))
            let restricted = offered.filter { $0.name != name }
            #expect(!ToolDiscovery.matches(query: query, descriptors: restricted).contains { $0.name == name })
        }
        #expect(ToolDiscovery.matches(query: "forward port 8080", descriptors: offered).map(\.name) == ["linux.port"])
    }

    @Test func anExactToolInAnotherChecklistStepDoesNotHideEditorCapabilities() {
        let offered = ["studio.read", "gis.export", "latex.edit"].map(descriptor)
        let names = NativeAuthoringRouting.taskBoundNames(userTask: "继续",
            taskContext: "studio.read\n导出地图图层\n排版论文", liveDescriptors: offered)
        #expect(Set(names) == Set(offered.map(\.name)))
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
