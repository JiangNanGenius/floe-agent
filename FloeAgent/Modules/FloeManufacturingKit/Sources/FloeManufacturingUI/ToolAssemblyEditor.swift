// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct ToolAssemblyEditor: View {
    let study: ManufacturingStudy
    let cuttingPartName:String
    let apply: (ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var assembly: MillingToolAssembly
    @State private var profile: String
    @State private var queryLimit: Int
    @State private var problem = ""
    init(study:ManufacturingStudy,cuttingPartName:String = L("平底铣刀","Flat end mill"),apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.apply = apply; self.cuttingPartName = cuttingPartName
        let value = study.millingAssembly ?? .demonstration(cuttingLengthMM:study.milling.toolLengthMM)
        _assembly = State(initialValue:value)
        _profile = State(initialValue:Self.profileText(value))
        _queryLimit = State(initialValue:study.budget.collisionQueryLimit)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(L("切削部分 · ","Cutting part · ")+cuttingPartName) {
                    LabeledContent(L("直径","Diameter"),value:String(format:"%.3f mm",2*study.milling.toolRadiusMM))
                    LabeledContent(L("切削刃长","Cutting-edge length"),value:String(format:"%.3f mm",study.milling.toolLengthMM))
                    if let motion = study.acMotion { LabeledContent(L("刀尖至量规点","Tip to gauge point"),value:String(format:"%.3f mm",motion.toolLengthMM)) }
                }
                Section(L("当前总成","Active assembly")) {
                    TextField(L("名称","Name"),text:$assembly.name).accessibilityIdentifier("assembly.name")
                    number(L("刀杆直径 · mm","Shank diameter · mm"),value:$assembly.shankDiameterMM,id:"assembly.shankDiameter")
                    number(L("所需间隙 · mm","Required clearance · mm"),value:$assembly.clearanceMM,id:"assembly.clearance")
                    Text(L("以下初始尺寸是研究示例，请按所用刀具填写。","Initial dimensions are a research example. Enter the dimensions of the tool in use.")).font(.caption).foregroundStyle(.secondary)
                    Button(L("填入演示尺寸","Use demonstration dimensions")) {
                        assembly = .demonstration(cuttingLengthMM:study.milling.toolLengthMM)
                        assembly.name = L("演示刀具总成","Demonstration assembly")
                        profile = Self.profileText(assembly); problem = ""
                    }.accessibilityIdentifier("assembly.example")
                }
                Section(L("刀柄外形 · mm","Holder profile · mm")) {
                    Text(L("每点为 [距刀尖的轴向距离, 半径]。正方向朝主轴；同一轴向位置可表示台阶。刀杆由切削刃末端延伸到首点。","Each point is [axial distance from tool tip, radius], positive toward the spindle. Equal axial positions describe shoulders. The shank runs from the cutting-edge end to the first point.")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text:$profile).font(.body.monospaced()).frame(minHeight:150).accessibilityIdentifier("assembly.profile")
                }
                Section(L("检查范围","Query scope")) {
                    Text(L("动力刀具的切削部分检查夹具；刀杆和刀柄检查夹具及当时的剩余材料。车刀和完整机床部件另行记录。","The live-tool cutting part is checked against fixtures; shank and holder against fixtures and stock at the current step. Turning-tool bodies and full machine components remain separate.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(L("查询预算","Query budget")); Spacer()
                        TextField("1…500000",value:$queryLimit,format:.number).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("assembly.budget")
                    }
                    Button(L("读取已保存的总成字段","Read saved assembly fields")) { loadStoredFields() }
                    if study.millingAssembly != nil {
                        Button(L("移除总成，保留切削部分检查","Remove assembly; retain cutting-part queries"),role:.destructive) {
                            var edited = study; edited.millingAssembly = nil; apply(edited); dismiss()
                        }.accessibilityIdentifier("assembly.remove")
                    }
                }
                if !problem.isEmpty { Section { Text(problem).foregroundStyle(.orange).textSelection(.enabled).accessibilityIdentifier("assembly.error") } }
            }
            .navigationTitle(L("动力刀具总成","Live-tool assembly"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(L("应用","Apply")) {
                        do {
                            var edited = study
                            guard profile.utf8.count <= 64_000 else { throw ManufacturingError.invalid("holder profile text budget") }
                            assembly.holderProfile = try JSONDecoder().decode([HolderProfilePoint].self,from:Data(profile.utf8))
                            edited.millingAssembly = assembly; edited.budget.maxCollisionQueries = queryLimit
                            for key in ["millingAssembly.shankDiameterMM","millingAssembly.holderProfile","millingAssembly.clearanceMM","budget.maxCollisionQueries"] {
                                edited.parameters?.remove(key)
                            }
                            try edited.validate(); apply(edited); dismiss()
                        } catch { problem = error.localizedDescription }
                    }.accessibilityIdentifier("assembly.apply")
                }
            }
        }.presentationDetents([.large])
    }
    private func number(_ label:String,value:Binding<Double>,id:String) -> some View {
        HStack { Text(label); Spacer(); TextField(label,value:value,format:.number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth:120).accessibilityIdentifier(id) }.frame(minHeight:44)
    }
    private static func profileText(_ value:MillingToolAssembly) -> String {
        String(decoding:(try? ManufacturingStudy.encoder.encode(value.holderProfile)) ?? Data(),as:UTF8.self)
    }
    private func loadStoredFields() {
        do {
            var edited = study; edited.millingAssembly = assembly
            let restored = try edited.applyingParameters(study.parameterSnapshot())
            guard let value = restored.millingAssembly else { return }
            assembly = value; profile = Self.profileText(value); queryLimit = restored.budget.collisionQueryLimit; problem = ""
        } catch { problem = error.localizedDescription }
    }
}
#endif
