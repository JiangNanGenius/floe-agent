// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct CellStepEditor:View {
    @Environment(\.dismiss) private var dismiss
    @State private var step:CellStep
    @State private var error = ""
    @State private var studyEditor:StudyEditor?
    let cell:ManufacturingCell
    let directory:URL
    let apply:(CellStep)->Void
    private enum StudyEditor:String,Identifiable { case cam,turning,cutting;var id:String { rawValue } }
    init(step:CellStep,cell:ManufacturingCell,directory:URL,apply:@escaping(CellStep)->Void) {
        _step = State(initialValue:step); self.cell = cell; self.directory = directory; self.apply = apply
    }
    var body:some View {
        NavigationStack {
            Form {
                Section { LabeledContent(L("通道","Channel"),value:step.channelID); Text(step.id) }
                fields
                if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .navigationTitle(L("工序设置","Step settings"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do {
                        var draft = cell
                        guard let i = draft.steps.firstIndex(where:{ $0.id == step.id }) else { throw ManufacturingError.stale }
                        draft.steps[i] = step; try draft.validate(); apply(step); dismiss()
                    } catch { self.error = error.localizedDescription }
                } }
            }
            .sheet(item:$studyEditor) { editor in
                if case .operate(let op) = step.action {
                    switch editor {
                    case .cam:CAMEditor(study:op.study,directory:directory) { updateStudy($0) }
                    case .turning:TurningSetupEditor(study:op.study) { updateStudy($0) }
                    case .cutting:TurningCuttingEditor(study:op.study) { updateStudy($0) }
                    }
                }
            }
        }
    }
    @ViewBuilder private var fields:some View {
        switch step.action {
        case .operate(let op):
            Section(L("加工","Machining")) {
                LabeledContent(L("工件","Workpiece"),value:op.workpieceID)
                LabeledContent(L("主轴","Spindle"),value:op.spindleID)
                LabeledContent(L("刀塔 / 工位","Turret / station"),value:[op.turretID,op.stationID].compactMap { $0 }.joined(separator:" / "))
                scalar(L("名义时间 · s","Nominal time · s"),value:op.durationSeconds) { if case .operate(var v) = step.action { v.durationSeconds = $0;v.durationProvenance = .supplied;step.action = .operate(v) } }
                Button(L("刀具与铣削工序","Tools and milling operations")) { studyEditor = .cam }
                Button(L("车削工序与刀片","Turning operations and insert")) { studyEditor = .turning }
                Button(L("车削速度与进给","Turning speeds and feeds")) { studyEditor = .cutting }
                Text(L("工位必须与实际刀具一致。多刀加工需拆成带换位步骤的工序。","The station must match the actual tool. Split multiple tools into jobs with explicit indexing steps.")).font(.caption).foregroundStyle(.secondary)
            }
        case .transfer(let transfer):
            Section(L("接料","Transfer")) {
                LabeledContent(L("交出主轴","Donor spindle"),value:transfer.donorSpindleID)
                LabeledContent(L("接收主轴","Receiver spindle"),value:transfer.receiverSpindleID)
                scalar(L("接收夹持长度 · mm","Receiver grip · mm"),value:transfer.receiverGripLengthMM) { if case .transfer(var v) = step.action { v.receiverGripLengthMM = $0;step.action = .transfer(v) } }
                scalar(L("间隙 · mm","Clearance · mm"),value:transfer.clearanceMM) { if case .transfer(var v) = step.action { v.clearanceMM = $0;step.action = .transfer(v) } }
                scalar(L("角度偏置 · °","Twist offset · °"),value:transfer.twistDegrees) { if case .transfer(var v) = step.action { v.twistDegrees = $0;step.action = .transfer(v) } }
                scalar(L("时间 · s","Duration · s"),value:transfer.durationSeconds) { if case .transfer(var v) = step.action { v.durationSeconds = $0;step.action = .transfer(v) } }
                ForEach(0..<3,id:\.self) { c in
                    scalar(L("接收卡盘位置 ","Receiver acquisition ")+["X","Y","Z"][c]+" · mm",value:transfer.acquisitionOriginMM[c]) { value in
                        if case .transfer(var v) = step.action { v.acquisitionOriginMM[c] = value;step.action = .transfer(v) }
                    }
                }
                if let retract = transfer.retractOriginMM {
                    ForEach(0..<3,id:\.self) { c in
                        scalar(L("接料后退回 ","Receiver retract ")+["X","Y","Z"][c]+" · mm",value:retract[c]) { value in
                            if case .transfer(var v) = step.action { v.retractOriginMM?[c] = value;step.action = .transfer(v) }
                        }
                    }
                }
            }
        case .spindle(let command):
            Section(L("主轴状态","Spindle state")) {
                LabeledContent(L("主轴","Spindle"),value:command.spindleID)
                LabeledContent(L("模式","Mode"),value:command.mode.rawValue)
                if let rpm = command.rpm { scalar(L("转速 · rpm","Speed · rpm"),value:rpm) { if case .spindle(var v) = step.action { v.rpm = $0;step.action = .spindle(v) } } }
                if let angle = command.cIndexDegrees { scalar(L("C轴定位 · °","C index · °"),value:angle) { if case .spindle(var v) = step.action { v.cIndexDegrees = $0;step.action = .spindle(v) } } }
                scalar(L("过渡时间 · s","Transition · s"),value:command.durationSeconds) { if case .spindle(var v) = step.action { v.durationSeconds = $0;step.action = .spindle(v) } }
            }
        case .dwell(let dwell):
            scalar(L("停留 · s","Dwell · s"),value:dwell.seconds) { if case .dwell(var v) = step.action { v.seconds = $0;step.action = .dwell(v) } }
        case .synchronize(let sync):
            Section(L("主轴同步","Spindle synchronization")) {
                Text(sync.spindleIDs.joined(separator:" ↔ "))
                LabeledContent(L("同步方式","Mode"),value:sync.mode.rawValue)
                if let ratio = sync.speedRatio { scalar(L("速比","Speed ratio"),value:ratio) { if case .synchronize(var v) = step.action { v.speedRatio = $0;step.action = .synchronize(v) } } }
                if let tolerance = sync.phaseToleranceDegrees { scalar(L("相位容差 · °","Phase tolerance · °"),value:tolerance) { if case .synchronize(var v) = step.action { v.phaseToleranceDegrees = $0;step.action = .synchronize(v) } } }
                scalar(L("同步时间 · s","Acquisition · s"),value:sync.durationSeconds) { if case .synchronize(var v) = step.action { v.durationSeconds = $0;step.action = .synchronize(v) } }
            }
        case .indexTurret(let index):
            Section {
                LabeledContent(L("刀塔","Turret"),value:index.turretID)
                if let turret = cell.turret(index.turretID) {
                    Picker(L("工位","Station"),selection:Binding(get:{ index.stationID },set:{ if case .indexTurret(var v) = step.action { v.stationID = $0;step.action = .indexTurret(v) } })) {
                        ForEach(turret.stations) { Text($0.name).tag($0.id) }
                    }
                }
            }
        default:
            Text(L("该步骤的资源、联锁和低频设置保存在完整配置中。","Resources, interlocks and uncommon settings for this step are retained in the complete setup."))
        }
    }
    private func updateStudy(_ study:ManufacturingStudy) { if case .operate(var value) = step.action { value.study = study;step.action = .operate(value) } }
    private func scalar(_ title:String,value:Double,set:@escaping @MainActor @Sendable (Double)->Void)->some View {
        HStack { Text(title);Spacer();TextField(title,value:Binding(get:{ value },set:set),format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth:120) }.frame(minHeight:44)
    }
}
#endif
