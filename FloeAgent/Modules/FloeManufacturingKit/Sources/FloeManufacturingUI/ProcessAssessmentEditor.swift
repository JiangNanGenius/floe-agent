// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct ProcessAssessmentEditor: View {
    let study:ManufacturingStudy
    let apply:(ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var enabled:Bool
    @State private var settings:TurningProcessRequirements
    @State private var error = ""
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.apply = apply
        _enabled = State(initialValue:study.isProcessAssessmentEnabled)
        _settings = State(initialValue:study.processRequirements ?? .init(radiusMM:min(10,study.stock.radiusMM),depthMM:min(1,study.stock.radiusMM)))
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L("启用工艺评估","Enable process assessment"),isOn:$enabled)
                    Text(L("先启用车削速度与进给。输入当前材料和实际切削条件。","Enable turning speeds and feeds first. Supply the current material and actual cutting conditions.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("切削条件","Cutting conditions")) {
                    number(L("评估半径 · mm","Evaluation radius · mm"),value:$settings.radiusMM)
                    number(L("径向切深 · mm","Radial depth · mm"),value:$settings.depthMM)
                    number(L("比切削力 · N/mm²","Specific cutting force · N/mm²"),value:$settings.specificCuttingForceNPerMM2)
                    number(L("机床效率 · 0…1","Machine efficiency · 0…1"),value:$settings.efficiency)
                }.disabled(!enabled)
                Section(L("对照上限 · 可选","Comparison limits · optional")) {
                    optional(L("输入功率 · kW","Input power · kW"),value:$settings.availableInputPowerKW,initial:5)
                    optional(L("扭矩 · N·m","Torque · N·m"),value:$settings.availableTorqueNM,initial:20)
                    optional(L("理论残留高度 · μm","Ideal cusp height · μm"),value:$settings.maximumIdealCuspUM,initial:5)
                }.disabled(!enabled)
                if enabled, let result = try? TurningProcessAssessment.evaluate(study:study,requirements:settings) {
                    Section(L("当前估算","Current estimate")) {
                        quantity(L("理论残留高度","Ideal cusp height"),result.idealCuspHeightUM,"μm")
                        quantity(L("切向力","Tangential force"),result.tangentialForceN,"N")
                        quantity(L("所需输入功率","Required input power"),result.requiredInputPowerKW,"kW")
                        quantity(L("扭矩","Torque"),result.torqueNM,"N·m")
                        quantity(L("材料去除率","Material removal rate"),result.materialRemovalCM3PerMinute,"cm³/min")
                        if !result.exceededLimits.isEmpty { Text(L("有估算值超过所填上限。","An estimate exceeds a supplied limit.")).foregroundStyle(.orange) }
                    }
                }
                Section {
                    Text(L("理论残留高度只考虑圆弧刀尖与进给，不代表实测粗糙度。预览网格、磨损和振动需另行判断。","Ideal cusp height considers only a circular nose and feed; it is not measured roughness. Mesh faceting, wear and vibration require separate assessment.")).font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle(L("工艺评估","Process assessment"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do {
                        var draft = study; draft.processRequirements = settings; draft.processAssessmentEnabled = enabled
                        try draft.validate(requireOperations:false); apply(draft); dismiss()
                    } catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
    private func number(_ title:String,value:Binding<Double>)->some View {
        HStack { Text(title); Spacer(); TextField(title,value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth:120) }.frame(minHeight:44)
    }
    private func optional(_ title:String,value:Binding<Double?>,initial:Double)->some View {
        VStack {
            Toggle(title,isOn:Binding(get:{ value.wrappedValue != nil },set:{ value.wrappedValue = $0 ? initial : nil }))
            if value.wrappedValue != nil { number(title,value:Binding(get:{ value.wrappedValue ?? initial },set:{ value.wrappedValue = $0 })) }
        }
    }
    private func quantity(_ title:String,_ value:Double,_ unit:String)->some View {
        LabeledContent(title,value:String(format:"%.3f %@",value,unit))
    }
}
#endif
