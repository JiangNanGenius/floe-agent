// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct CellStockPreview:View {
    let study:ManufacturingStudy
    let job:CellSimulationArtifact.Job
    @State private var replay = 1.0
    @State private var paths = true
    @State private var smooth = true
    @State private var revision = UUID()
    var body:some View {
        VStack {
            StockViewport(study:study,inputRevision:revision,artifact:job.artifact,replay:replay,showPaths:paths,
                          showFixtures:true,smoothStock:smooth,showAssembly:true,showReference:true)
                .frame(minHeight:300).clipShape(.rect(cornerRadius:16)).padding()
            Slider(value:$replay,in:0...1).padding(.horizontal).accessibilityLabel(L("工序回放位置","Operation replay position"))
            HStack {
                Toggle(L("刀路","Toolpaths"),isOn:$paths)
                Toggle(L("显示光顺","Display smoothing"),isOn:$smooth)
            }.padding()
            LabeledContent(L("剩余材料","Remaining material"),value:String(format:"%.3f mm³",job.artifact.result.remainingMM3)).padding(.horizontal)
            DisclosureGroup(L("装夹与坐标详情","Gripping and coordinate details")) {
                Text(job.spindleID)
                Text(job.worldFromWorkpiece.translationMM.map { String(format:"%.3f",$0) }.joined(separator:", ")+" mm")
                Text(L("此视图使用工件坐标。完整导出保留世界刀路、接料事件和装夹变换。","This view uses part coordinates. The complete export retains world paths, transfer events and gripping transforms."))
            }.font(.caption).padding()
            Spacer(minLength:0)
        }
        .navigationTitle(job.stepID)
    }
}
#endif
