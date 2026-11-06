// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import FloeManufacturingParameters

struct TurningSetupEditor:View {
    let study:ManufacturingStudy
    let apply:(ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var setup:TurningSetup
    @State private var enabled:Bool
    @State private var approach:TurningApproach
    @State private var problem = ""
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.apply = apply
        _setup = State(initialValue:study.configuredTurningSetup); _enabled = State(initialValue:study.turningSetup != nil)
        _approach = State(initialValue:study.turningApproach ?? .positiveZ)
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("加工端方向","Machining end"),selection:$approach) {
                        Text(L("从工件 +Z 端","From part +Z end")).tag(TurningApproach.positiveZ)
                        Text(L("从工件 −Z 端","From part −Z end")).tag(TurningApproach.negativeZ)
                    }
                    Toggle(L("分别设置车削工序","Configure turning operations separately"),isOn:$enabled).accessibilityIdentifier("turning.setup.enabled")
                    Text(L("关闭时沿用三个工序及原进给。当前输入仍随工艺单保存。","When disabled, the original three operations and feed are used. These entries remain in the process sheet.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("执行工序","Operations")) {
                    Toggle(L("端面","Face"),isOn:$setup.faceEnabled).accessibilityIdentifier("turning.setup.face")
                    Toggle(L("外圆粗车","External roughing"),isOn:$setup.roughEnabled)
                    Toggle(L("轮廓精车","Profile finishing"),isOn:$setup.profileEnabled)
                }
                Section(L("刀片几何","Insert geometry")) {
                    Picker(L("二维形状","2D shape"),selection:$setup.insertShape) { ForEach(["D","C","V","S","T","R"],id:\.self) { Text($0).tag($0) } }.accessibilityIdentifier("turning.setup.shape")
                    ManufacturingNumber(L("边长 · mm","Edge length · mm"),value:$setup.insertEdgeLengthMM)
                    ManufacturingNumber(L("旋转 · °","Rotation · °"),value:$setup.insertRotationDegrees)
                    Toggle(L("允许外圆型线凹槽","Allow external profile grooving"),isOn:$setup.allowGrooving)
                    Text(L("边长不是内切圆直径。二维刀形用于型线计算；名义刀尖半径固定 0.4 mm，尚无刀尖半径补偿。","Edge length differs from inscribed-circle diameter. The 2D insert shapes profile planning; the nominal nose remains 0.4 mm without nose-radius compensation.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("进退刀与分向进给","Entry, exit and axis feeds")) {
                    ManufacturingNumber(L("安全间隙 · mm","Clearance · mm"),value:$setup.clearanceMM)
                    ManufacturingNumber(L("引入角 · °","Lead-in angle · °"),value:$setup.leadinAngleDegrees)
                    ManufacturingNumber(L("引出角 · °","Lead-out angle · °"),value:$setup.leadoutAngleDegrees)
                    ManufacturingNumber(L("X 上限 · mm/min","X limit · mm/min"),value:$setup.horizontalFeedMMPerMinute)
                    ManufacturingNumber(L("Z 上限 · mm/min","Z limit · mm/min"),value:$setup.verticalFeedMMPerMinute)
                    if study.turningCutting?.feedMode == .mmPerRevolution {
                        Text(L("当前按每转进给计时；这里的方向速度仅是原生路径的每分钟指令，未建模的轴速限制不会改写每转进给。","Timing currently uses feed per revolution. Axis feeds here describe native per-minute paths; unmodeled axis speed limits do not override the per-revolution law.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !problem.isEmpty { Section { Text(problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("turning.setup.error") } }
            }.navigationTitle(L("车削工序与刀片","Turning operations and insert"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do { var value = try study.applyingTurningSetup(setup,enabled:enabled); value.turningApproach = approach;try value.validate(requireOperations:false);apply(value); dismiss() } catch { problem = error.localizedDescription }
                }.accessibilityIdentifier("turning.setup.apply") }
            }
        }.presentationDetents([.large])
    }
}

struct ManufacturingStockEditor:View {
    let apply:(ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft:ManufacturingStudy
    @State private var shape:String
    @State private var low:[Double]
    @State private var high:[Double]
    @State private var problem = ""
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.apply = apply; _draft = State(initialValue:study)
        _shape = State(initialValue:study.stock.shape ?? "cylinder")
        _low = State(initialValue:study.stock.bounds.min); _high = State(initialValue:study.stock.bounds.max)
    }
    var body:some View {
        NavigationStack {
            Form {
                Section(L("毛坯 · mm","Stock · mm")) {
                    Picker(L("形状","Shape"),selection:$shape) { Text(L("圆柱","Cylinder")).tag("cylinder"); Text(L("长方体","Box")).tag("box") }.accessibilityIdentifier("stock.shape")
                    if shape == "box" {
                        CoordinateFields(label:L("XYZ 下界","XYZ minimum"),values:$low,labels:["X","Y","Z"])
                        CoordinateFields(label:L("XYZ 上界","XYZ maximum"),values:$high,labels:["X","Y","Z"])
                        Text(L("方料使用刀具库中的特征 CAM；车削与原单趟铣槽会关闭。","Box stock uses feature CAM from the tool library; turning and the original single-pass slot will be disabled.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ManufacturingNumber(L("半径","Radius"),value:$draft.stock.radiusMM)
                        ManufacturingNumber(L("Z 下端","Z minimum"),value:$draft.stock.zMinMM)
                        ManufacturingNumber(L("Z 上端","Z maximum"),value:$draft.stock.zMaxMM)
                    }
                    ManufacturingNumber(L("采样单元边长","Sampling cell size"),value:$draft.stock.resolutionMM)
                }
                Section(L("资源预算","Resource budgets")) {
                    intField(L("体素上限","Maximum cells"),value:$draft.budget.maxCells)
                    intField(L("姿态上限","Maximum poses"),value:$draft.budget.maxPoses)
                    intField(L("网格面上限","Maximum triangles"),value:$draft.budget.maxTriangles)
                    intField(L("保留工序帧","Retained operation frames"),value:Binding(get:{ draft.budget.frameLimit },set:{ draft.budget.maxFrames = $0 }))
                    intField(L("帧网格字节预算","Frame mesh byte budget"),value:Binding(get:{ draft.budget.retainedMeshByteLimit },set:{ draft.budget.maxRetainedMeshBytes = $0 }))
                }
                if !problem.isEmpty { Section { Text(problem).font(.caption).foregroundStyle(.orange) } }
            }.navigationTitle(L("毛坯与预算","Stock and budgets"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply"),action:save).accessibilityIdentifier("stock.apply") }
            }
        }.presentationDetents([.large])
    }
    private func intField(_ label:String,value:Binding<Int>) -> some View {
        HStack { Text(label); Spacer(); TextField(label,value:value,format:.number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth:150) }.frame(minHeight:44)
    }
    private func save() {
        do {
            if shape == "box" {
                draft.stock.shape = "box"; draft.stock.minMM = low; draft.stock.maxMM = high
                draft.stock.zMinMM = low[2]; draft.stock.zMaxMM = high[2]
                draft.turning.enabled = false; draft.milling.enabled = false
            } else { draft.stock.shape = nil; draft.stock.minMM = nil; draft.stock.maxMM = nil }
            try draft.validate(requireOperations:false); apply(draft); dismiss()
        } catch { problem = error.localizedDescription }
    }
}
#endif
