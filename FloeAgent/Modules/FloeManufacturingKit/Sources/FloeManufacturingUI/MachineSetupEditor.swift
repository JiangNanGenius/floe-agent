// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

func machineName(_ kind: ManufacturingMachineSetup.Kind) -> String {
    switch kind {
    case .lathe: L("数控车床", "CNC lathe")
    case .milling3Axis: L("三轴铣床", "3-axis mill")
    case .milling5AxisAC: L("A/C 五轴铣床", "A/C 5-axis mill")
    case .turnMill: L("车铣复合（单主轴）", "Single-spindle turn-mill")
    }
}

struct MachineSetupEditor: View {
    let study: ManufacturingStudy
    let apply: (ManufacturingStudy) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ManufacturingMachineSetup.Kind
    @State private var frame: ManufacturingCAM.Frame
    @State private var problem = ""
    init(study: ManufacturingStudy, apply: @escaping (ManufacturingStudy) -> Void) {
        self.study = study; self.apply = apply
        _kind = State(initialValue: study.machineSetup?.kind ?? (study.turning.enabled ? .lathe : .milling3Axis))
        let bounds = study.stock.bounds
        _frame = State(initialValue: study.machineSetup?.coordinateFrame ?? .init(originMM: [(bounds.min[0]+bounds.max[0])/2, (bounds.min[1]+bounds.max[1])/2, bounds.max[2]]))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(L("机床类型", "Machine type")) {
                    Picker(L("类型", "Type"), selection: $kind) {
                        ForEach(ManufacturingMachineSetup.Kind.allCases, id: \.self) { Text(machineName($0)).tag($0) }
                    }.accessibilityIdentifier("machining.machine.kind")
                    if kind == .milling5AxisAC {
                        Text(L("使用相交 A/C 转台运动链。刀具需要量规长度；超出可达范围会报告错误。", "Uses the intersecting A/C table chain. Tools require a gauge length; unreachable poses report an error.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(L("切换类型会关闭不兼容工序。刀具和工序设置仍保留，可继续调整。", "Changing type disables incompatible operations. Tool and operation settings remain available to edit.")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(L("工件坐标系", "Work coordinate system")) {
                    if kind == .lathe || kind == .turnMill {
                        Text(L("车削轴为模型 Z 轴，半径从 X/Y 原点量起。请在生成刀路前检查车削轮廓与装夹方向。", "Turning uses the model Z axis, with radii measured from the X/Y origin. Check the turning profile and clamping direction before generating toolpaths.")).font(.footnote)
                    } else {
                        Button(L("使用毛坯顶面中心", "Use stock top center")) {
                            let b = study.stock.bounds
                            frame = .init(originMM: [(b.min[0]+b.max[0])/2, (b.min[1]+b.max[1])/2, b.max[2]])
                        }
                        CoordinateFields(label: L("原点 · mm", "Origin · mm"), values: $frame.originMM, labels: ["X","Y","Z"])
                        CoordinateFields(label: L("刀轴方向", "Tool axis"), values: $frame.axis, labels: ["X","Y","Z"])
                        CoordinateFields(label: L("X 方向", "X direction"), values: $frame.xDirection, labels: ["X","Y","Z"])
                        Text(L("应用后，此坐标系用于当前铣削工序和后续新工序。", "On apply, this coordinate system is used by current and newly created milling operations.")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !problem.isEmpty { Section { Text(problem).foregroundStyle(.orange) } }
            }
            .navigationTitle(L("机床与坐标系", "Machine and coordinates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("应用", "Apply")) {
                    do { apply(try study.applyingMachineSetup(.init(kind: kind, coordinateFrame: frame))); dismiss() }
                    catch { problem = error.localizedDescription }
                }.accessibilityIdentifier("machining.machine.apply") }
            }
        }
    }
}
#endif
