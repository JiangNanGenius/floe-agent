// FloeProvidersTests — Local-model curated tool admission.
//
// The on-device ceiling is intentionally small. These tests pin the one
// approved CAD addition and prove that generic file/web turns keep their
// existing priority and never receive an unrelated CAD schema.

import Foundation
import Testing
@testable import FloeProviders

@Suite("FloeProviders.LocalModelToolPolicy")
struct LocalModelToolPolicyTests {

    @Test("CAD is the only added document capability in the local ceiling")
    func ceilingContainsCadOnly() {
        let ceiling = LocalModelToolPolicy.curatedCeilingNames
        #expect(ceiling.contains("cad.document"))
        #expect(ceiling.contains("web.search"))
        #expect(ceiling.contains("workspace.readFile"))
        #expect(!ceiling.contains("workspace.writeFile"))
        #expect(!ceiling.contains("exec.shell"))
        #expect(!ceiling.contains("exec.localPython"))
        #expect(!ceiling.contains("document.updateText"))
        #expect(!ceiling.contains("image.svgDocument"))
    }

    @Test("CAD stays out of the always-pinned base set")
    func cadIsNotAlwaysPinned() {
        #expect(!LocalModelToolPolicy.pinnedToolNames.contains("cad.document"))
        #expect(!LocalModelToolPolicy.pinnedToolNames(for: "今天天气怎么样").contains("cad.document"))
        #expect(!LocalModelToolPolicy.pinnedToolNames(for: "读取工作区文件").contains("cad.document"))
        #expect(!LocalModelToolPolicy.pinnedToolNames(for: "切换模型并重新连接").contains("cad.document"))
        #expect(!LocalModelToolPolicy.requestsCadWork("adjust the cadence"))
        #expect(!LocalModelToolPolicy.requestsCadWork("whistle a tune"))
        #expect(!LocalModelToolPolicy.requestsCadWork("switch to the faster model"))
        #expect(!LocalModelToolPolicy.requestsCadWork("重新选择模型"))
    }

    @Test("Explicit CAD, 3D and modeling turns pin cad.document")
    func cadIntentPinsTool() {
        for text in [
            "用 cad 画一张工程图",
            "cad画图",
            "用 CAD 画一张工程图",
            "打开这个 dwg 图纸",
            "创建一个 3d 模型",
            "帮我建模一个机械零件",
            "make a 3d model of a bracket",
            "create an assembly and export step file",
            "检查这个 floecad 文档",
            "把孔径改为8毫米",
            "给这个边加一个2毫米圆角",
            "倒角0.5毫米",
            "这个支架再加一个安装孔",
            "increase the fillet radius on this edge",
            "add a 2mm chamfer",
            "make the bracket 20mm wider",
            "open bracket.obj",
            "把这个零件的材质改为磨砂金属",
            "换一张木纹贴图"
        ] {
            #expect(LocalModelToolPolicy.requestsCadWork(text.lowercased()), "\(text)")
            #expect(
                LocalModelToolPolicy.pinnedToolNames(for: text.lowercased()).contains("cad.document"),
                "\(text)"
            )
            #expect(
                LocalModelToolPolicy.pinnedAdmissionOrder(for: text.lowercased()).first == "cad.document",
                "\(text)"
            )
        }
    }

    @Test("Generic file and web priorities are unchanged")
    func genericPrioritiesPreserved() {
        let file = LocalModelToolPolicy.pinnedAdmissionOrder(for: "读取工作区的文件")
        #expect(file.first == "workspace.readFile")
        #expect(file.contains("web.search"))
        let web = LocalModelToolPolicy.pinnedAdmissionOrder(for: "搜索今天的新闻")
        #expect(web.first == "web.search")
        #expect(web.contains("workspace.readFile"))

        // A CAD turn leads with CAD but keeps the rest of the existing order.
        let cadFile = LocalModelToolPolicy.pinnedAdmissionOrder(for: "读取 cad 图纸文件")
        #expect(cadFile.first == "cad.document")
        #expect(cadFile.dropFirst().first == "workspace.readFile")
        let cadWeb = LocalModelToolPolicy.pinnedAdmissionOrder(for: "online 查找 3d 模型")
        #expect(cadWeb.first == "cad.document")
        #expect(cadWeb.dropFirst().first == "web.search")
    }
}
