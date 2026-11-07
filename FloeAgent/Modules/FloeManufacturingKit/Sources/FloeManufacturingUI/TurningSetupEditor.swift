// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Observation
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
        _setup = State(initialValue:study.configuredTurningSetup); _enabled = State(initialValue:study.turning.enabled)
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
                    Toggle(L("启用车削工序","Enable turning operations"),isOn:$enabled).accessibilityIdentifier("turning.setup.enabled")
                    Text(L("刀片形状、旋转和工序选择会保存并用于生成刀路。","Insert shape, rotation and operation selection are saved and used when generating toolpaths.")).font(.caption).foregroundStyle(.secondary)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do {
                        var value = study; value.turning.enabled = enabled
                        value = try value.applyingTurningSetup(setup,enabled:true)
                        value.turningApproach = approach; try value.validate(requireOperations:false); apply(value); dismiss()
                    } catch { problem = error.localizedDescription }
                }.accessibilityIdentifier("turning.setup.apply") }
            }
        }.presentationDetents([.large])
    }
}

@MainActor @Observable final class ManufacturingStockDraft:Identifiable {
    let id = UUID()
    let original:ManufacturingStudy
    var draft:ManufacturingStudy
    var shape:String
    var low:[Double]
    var high:[Double]
    var problem = ""
    init(study:ManufacturingStudy) {
        original = study;draft = study;shape = study.stock.shape ?? "cylinder"
        low = study.stock.bounds.min;high = study.stock.bounds.max
    }
}

struct ManufacturingStockEditor:View {
    let apply:(ManufacturingStudy,String)throws->Void
    private let onClose:(()->Void)?
    private let onHide:(()->Void)?
    private let isCurrentPresentation:()->Bool
    private let isBusy:Bool
    @Environment(\.dismiss) private var dismiss
    @State private var session:ManufacturingStockDraft
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.init(session:ManufacturingStockDraft(study:study)) { edited,_ in apply(edited) }
    }
    init(session:ManufacturingStockDraft,isBusy:Bool = false,isCurrentPresentation:@escaping()->Bool = { true },onHide:(()->Void)? = nil,onClose:(()->Void)? = nil,apply:@escaping(ManufacturingStudy,String)throws->Void) {
        self.apply = apply;self.isBusy = isBusy;self.onClose = onClose;self.onHide = onHide;self.isCurrentPresentation = isCurrentPresentation
        _session = State(initialValue:session)
    }
    var body:some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section(L("毛坯 · mm","Stock · mm")) {
                    Picker(L("形状","Shape"),selection:$session.shape) { Text(L("圆柱","Cylinder")).tag("cylinder"); Text(L("长方体","Box")).tag("box") }.accessibilityIdentifier("stock.shape")
                    if session.shape == "box" {
                        CoordinateFields(label:L("XYZ 下界","XYZ minimum"),values:$session.low,labels:["X","Y","Z"])
                        CoordinateFields(label:L("XYZ 上界","XYZ maximum"),values:$session.high,labels:["X","Y","Z"])
                        Text(L("方料使用刀具库中的特征 CAM；车削与原单趟铣槽会关闭。","Box stock uses feature CAM from the tool library; turning and the original single-pass slot will be disabled.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ManufacturingNumber(L("半径","Radius"),value:$session.draft.stock.radiusMM)
                        ManufacturingNumber(L("Z 下端","Z minimum"),value:$session.draft.stock.zMinMM)
                        ManufacturingNumber(L("Z 上端","Z maximum"),value:$session.draft.stock.zMaxMM)
                    }
                    ManufacturingNumber(L("采样单元边长","Sampling cell size"),value:$session.draft.stock.resolutionMM)
                }
                Section(L("夹具边界 · mm","Fixture bounds · mm")) {
                    ForEach(session.draft.fixtures.indices, id: \.self) { index in
                        DisclosureGroup(session.draft.fixtures[index].id) {
                            CoordinateFields(label:L("XYZ 下界","XYZ minimum"),values:$session.draft.fixtures[index].minMM,labels:["X","Y","Z"])
                            CoordinateFields(label:L("XYZ 上界","XYZ maximum"),values:$session.draft.fixtures[index].maxMM,labels:["X","Y","Z"])
                            Button(L("移除夹具","Remove fixture"),role:.destructive) { session.draft.fixtures.remove(at:index) }
                        }
                    }
                    Button(L("添加夹具","Add fixture"),systemImage:"plus") {
                        let b = session.draft.stock.bounds
                        session.draft.fixtures.append(.init(id:"fixture-\(UUID().uuidString.prefix(6))",minMM:[b.min[0],b.min[1],b.min[2]-10],maxMM:[b.max[0],b.max[1],b.min[2]-1]))
                    }.disabled(session.draft.fixtures.count >= 16).accessibilityIdentifier("stock.addFixture")
                }
                DisclosureGroup(L("计算精度与资源","Calculation quality and resources")) {
                    intField(L("体素上限","Maximum cells"),value:$session.draft.budget.maxCells)
                    intField(L("姿态上限","Maximum poses"),value:$session.draft.budget.maxPoses)
                    intField(L("网格面上限","Maximum triangles"),value:$session.draft.budget.maxTriangles)
                    intField(L("保留工序帧","Retained operation frames"),value:Binding(get:{ session.draft.budget.frameLimit },set:{ session.draft.budget.maxFrames = $0 }))
                    intField(L("帧网格字节预算","Frame mesh byte budget"),value:Binding(get:{ session.draft.budget.retainedMeshByteLimit },set:{ session.draft.budget.maxRetainedMeshBytes = $0 }))
                }
                if !session.problem.isEmpty { Section { Text(session.problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("stock.error") } }
            }.navigationTitle(L("毛坯与装夹","Stock and fixtures"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel"),action:close).accessibilityIdentifier("stock.cancel") }
                ToolbarItemGroup(placement:.confirmationAction) {
                    if let onHide {
                        Button(L("收起","Hide")) {
                            guard isCurrentPresentation() else { return }
                            onHide()
                        }.accessibilityIdentifier("stock.hide")
                    }
                    Button(L("应用","Apply"),action:save).disabled(isBusy).accessibilityIdentifier("stock.apply")
                }
            }
        }.presentationDetents([.large])
    }
    private func intField(_ label:String,value:Binding<Int>) -> some View {
        HStack { Text(label); Spacer(); TextField(label,value:value,format:.number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth:150) }.frame(minHeight:44)
    }
    private func close() {
        guard isCurrentPresentation() else { return }
        if let onClose { onClose() } else { dismiss() }
    }
    private func save() {
        guard isCurrentPresentation() else { return }
        do {
            if session.shape == "box" {
                session.draft.stock.shape = "box"; session.draft.stock.minMM = session.low; session.draft.stock.maxMM = session.high
                session.draft.stock.zMinMM = session.low[2]; session.draft.stock.zMaxMM = session.high[2]
                session.draft.turning.enabled = false; session.draft.milling.enabled = false
            } else { session.draft.stock.shape = nil; session.draft.stock.minMM = nil; session.draft.stock.maxMM = nil }
            try session.draft.validate(requireOperations:false)
            try apply(session.draft,session.original.fingerprint());close()
        } catch ManufacturingError.stale {
            session.problem = L("加工设置已改变，请取消后重新打开毛坯。","Machining settings changed. Cancel and reopen stock setup.")
        } catch { session.problem = error.localizedDescription }
    }
}
enum StockEditorCommitError:LocalizedError {
    case busy
    var errorDescription:String? {
        L("请等待当前计算或模型检查完成，再应用修改。","Wait for the current calculation or model check before applying changes.")
    }
}
#endif
