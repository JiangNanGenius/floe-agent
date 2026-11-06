// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct TurningCuttingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var study: ManufacturingStudy
    @State private var enabled: Bool
    @State private var settings: TurningCuttingParameters
    @State private var error = ""
    let onApply: (ManufacturingStudy) -> Void

    init(study: ManufacturingStudy, onApply: @escaping (ManufacturingStudy) -> Void) {
        _study = State(initialValue:study)
        _enabled = State(initialValue:study.turningCutting != nil)
        _settings = State(initialValue:study.configuredTurningCutting)
        self.onApply = onApply
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L("启用切削速度","Enable cutting speeds"),isOn:$enabled).accessibilityIdentifier("cutting.enabled")
                    Text(L("按当前刀路估算切削时间。主轴转速与 C 轴定位分别设置。","Estimate cutting time from the current paths. Spindle RPM and C-axis positioning are separate settings.")).font(.caption).foregroundStyle(.secondary)
                }
                if enabled {
                    Section(L("主轴","Spindle")) {
                        Picker(L("模式","Mode"),selection:$settings.spindleMode) {
                            Text(L("恒线速","Constant surface speed")).tag(TurningCuttingParameters.SpindleMode.constantSurfaceSpeed)
                            Text(L("恒转速","Fixed RPM")).tag(TurningCuttingParameters.SpindleMode.fixedRPM)
                        }.accessibilityIdentifier("cutting.spindleMode")
                        if settings.spindleMode == .constantSurfaceSpeed {
                            number(L("线速 · m/min","Surface speed · m/min"),value:$settings.surfaceSpeedMPerMinute,id:"cutting.surfaceSpeed")
                        } else {
                            number(L("转速 · rpm","Speed · rpm"),value:$settings.spindleRPM,id:"cutting.rpm")
                        }
                        number(L("转速上限 · rpm","RPM limit"),value:$settings.maxSpindleRPM,id:"cutting.limit")
                    }
                    Section(L("进给","Feed")) {
                        Picker(L("单位","Units"),selection:$settings.feedMode) {
                            Text(L("每转 · mm/rev","Per revolution · mm/rev")).tag(TurningCuttingParameters.FeedMode.mmPerRevolution)
                            Text(L("每分钟 · mm/min","Per minute · mm/min")).tag(TurningCuttingParameters.FeedMode.mmPerMinute)
                        }.accessibilityIdentifier("cutting.feedMode")
                        if settings.feedMode == .mmPerRevolution {
                            number(L("每转进给","Feed per revolution"),value:$settings.feedMMPerRevolution,id:"cutting.feedPerRev")
                        } else {
                            number(L("进给 · mm/min","Feed · mm/min"),value:$study.turning.feedMMPerMinute,id:"cutting.feedPerMinute")
                        }
                    }
                    Section {
                        Text(L("首次启用显示的是演示数值，请按实际刀具、材料和机床填写。时间未包含空移、加减速、主轴升降速和换刀。","First-time values are for demonstration. Enter values for the actual tool, material and machine. Time excludes rapid links, acceleration, spindle transients and tool changes.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("cutting.error") } }
            }
            .navigationTitle(L("车削切削速度","Turning cutting speeds"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(L("应用","Apply")) { apply() }.accessibilityIdentifier("cutting.apply")
                }
            }
        }
    }
    private func number(_ title:String,value:Binding<Double>,id:String) -> some View {
        LabeledContent(title) {
            TextField(title,value:value,format:.number).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(maxWidth:130).accessibilityIdentifier(id)
        }.frame(minHeight:44)
    }
    private func apply() {
        do {
            var draft = study
            if var stored = draft.parameters {
                stored.remove("turning.feedMMPerMinute")
                draft.parameters = stored
            }
            draft = try draft.applyingTurningCutting(settings,enabled:enabled)
            onApply(draft); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
