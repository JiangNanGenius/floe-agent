// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import UniformTypeIdentifiers

public struct ManufacturingCellWorkbenchView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var model:CellWorkbenchModel
    @State private var tab = 0
    @State private var importing = false
    @State private var selectedStep:Sheet?
    @State private var exported:URL?
    @State private var camPreview:CAMPreviewRequest?
    @State private var confirmingSavedOpen = false
    @State private var pendingSavedOpen:CellWorkbenchModel.SavedOpenRequest?
    private let directory:URL
    private let initialFile:URL?
    private let embedded:Bool
    @State private var didLoadInitialFile = false
    @State private var lastInitialFile:URL?
    private enum Sheet:Identifiable {
        case step(String),complete
        var id:String { switch self { case .step(let id):"step:"+id;case .complete:"complete" } }
    }
    public init(project:ManufacturingCellProject,directory:URL,initialFile:URL? = nil,embedded:Bool = false,sessions:ManufacturingResearchSessions? = nil) { self.directory = directory;self.initialFile = initialFile;self.embedded = embedded;_model = State(initialValue:sessions?.cell(project:project) ?? CellWorkbenchModel(project:project,directory:directory)) }
    public var body:some View {
        Group {
            if embedded { workbenchContent }
            else { NavigationStack { workbenchContent } }
        }
    }
    private var workbenchContent:some View {
        @Bindable var model = model
        return Group {
            GeometryReader { geometry in
                VStack(spacing:0) {
                    if geometry.size.width >= 1_000 {
                        HStack(spacing:0) {
                            setup.frame(width:min(420,geometry.size.width * 0.34))
                            Divider()
                            VStack(spacing:0) {
                                Picker(L("制造单元页面","Manufacturing cell page"),selection:Binding(get:{ tab == 2 ? 2:1 },set:{ tab = $0 })) {
                                    Text(L("通道与排程","Channels and schedule")).tag(1);Text(L("结果","Results")).tag(2)
                                }.pickerStyle(.segmented).padding()
                                if tab == 2 { results } else { savedResultPrompt;schedule }
                            }
                        }
                    } else {
                        Picker(L("制造单元页面","Manufacturing cell page"),selection:$tab) {
                            Text(L("设置","Setup")).tag(0);Text(L("通道与排程","Channels and schedule")).tag(1);Text(L("结果","Results")).tag(2)
                        }.pickerStyle(.segmented).padding()
                        if tab == 0 { savedResultPrompt;setup }
                        else if tab == 1 { savedResultPrompt;schedule }
                        else { results }
                    }
                    if model.busy {
                        if model.openingSavedResult { ProgressView().padding(8) }
                        else { ProgressView(value:model.progress).padding(.horizontal) }
                    }
                    if !model.notice.isEmpty { Text(model.notice).font(.callout).padding(8) }
                }
            }
            .navigationTitle(L("多主轴与多刀塔","Spindles and turrets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done")) { dismiss() }.accessibilityIdentifier("cell.done") }
                ToolbarItemGroup(placement:.primaryAction) {
                    if let artifact = model.artifact {
                        Button(L("加工仿真","Simulate machining"),systemImage:"play.rectangle") { camPreview = .init(source:.cell(.init(cell:model.project),artifact)) }.accessibilityIdentifier("cell.simulate")
                    }
                    if model.busy { Button(L("取消","Cancel")) { model.cancel() } }
                    else {
                        Button { model.calculate();tab = 2 } label: {
                            HStack(spacing:6) {
                                Image(systemName:"play.fill")
                                Text(model.artifact == nil ? L("计算","Calculate"):L("重新计算","Recalculate"))
                            }
                        }.accessibilityIdentifier("cell.calculate")
                    }
                    Menu {
                        Button(L("加载","Load"),systemImage:"folder") { importing = true }
                        Button(L("完整配置","Complete setup")) { selectedStep = .complete }
                        Button(L("保存结果","Save result")) { model.save() }.disabled(model.artifact == nil)
                        Button(L("打开已保存结果","Open saved result"),systemImage:"folder") { requestSavedOpen() }
                        Button(L("导出配置","Export setup")) { export(input:true) }
                        Button(L("导出排程与刀路","Export schedule and paths")) { export(input:false) }.disabled(model.artifact == nil)
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.disabled(model.busy)
                }
            }
            .confirmationDialog(L("打开已保存结果？","Open saved result?"),isPresented:$confirmingSavedOpen,titleVisibility:.visible) {
                Button(L("打开已保存结果","Open saved result"),role:.destructive) {
                    if let request = pendingSavedOpen { model.reopen(request);tab = 2 }
                    pendingSavedOpen = nil
                }
                Button(L("取消","Cancel"),role:.cancel) { pendingSavedOpen = nil }
            } message: { Text(L("当前未保存的配置和结果将被替换。","This replaces the current unsaved setup and result.")) }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json,.data]) { outcome in
                switch outcome { case .success(let url):model.load(url);case .failure(let error):model.report(error) }
            }
            .sheet(item:$selectedStep) { item in
                switch item {
                case .complete:
                    ResearchSetupEditor(value:model.project,validate:{ try $0.validate() }) { value in model.project = value }
                case .step(let id):
                    if let index = model.project.cell.steps.firstIndex(where:{ $0.id == id }) {
                        CellStepEditor(step:model.project.cell.steps[index],cell:model.project.cell,directory:directory) { step in
                            model.project.cell.steps[index] = step
                        }
                    }
                }
            }
            .task(id:initialFile) {
                model.refreshSavedResultAvailability()
                if !didLoadInitialFile || lastInitialFile != initialFile {
                    didLoadInitialFile = true;lastInitialFile = initialFile
                    if let initialFile { model.load(initialFile) }
                }
            }
            .fullScreenCover(item:$camPreview) { request in CAMSimulationWorkbenchView(source:request.source,directory:directory.appendingPathComponent("preview")) }
        }
        // The parent service owns accepted calculations; disappearing is not Cancel.
    }
    @ViewBuilder private var savedResultPrompt:some View {
        if model.artifact == nil, model.savedResultAvailability == .available || model.savedResultAvailability == .unavailable {
            VStack(alignment:.leading,spacing:8) {
                Text(model.savedResultAvailability == .unavailable
                    ? L("保存的结果暂不可用，可重试打开。","The saved result is unavailable. Try opening it again.")
                    : L("可打开已保存的制造单元，无需重新计算。","Open the saved manufacturing cell without recalculating.")).font(.callout)
                Button(L("打开已保存结果","Open saved result"),systemImage:"folder") { requestSavedOpen() }
                    .accessibilityIdentifier("cell.openSavedResult").disabled(model.busy)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal).padding(.bottom,8)
        }
    }
    private func requestSavedOpen() {
        guard !model.busy else { return }
        let request = model.savedOpenRequest()
        if model.hasUnsavedChanges { pendingSavedOpen = request;confirmingSavedOpen = true }
        else { model.reopen(request);tab = 2 }
    }
    private var setup:some View {
        @Bindable var model = model
        return Form {
            Section { TextField(L("名称","Name"),text:$model.project.cell.name) }
            ForEach(model.project.cell.spindles.indices,id:\.self) { i in
                Section(ManufacturingDisplayNames.spindle(name:model.project.cell.spindles[i].name,id:model.project.cell.spindles[i].id)) {
                    number(L("最高转速 · rpm","Maximum speed · rpm"),value:$model.project.cell.spindles[i].maxRPM)
                    number(L("卡盘开口 · mm","Chuck opening · mm"),value:$model.project.cell.spindles[i].chuck.openingDiameterMM)
                    number(L("卡盘最大开口 · mm","Maximum chuck opening · mm"),value:$model.project.cell.spindles[i].chuck.maxOpeningDiameterMM)
                    Text(L("转速、C轴定位、夹紧与接料在通道工序中分别设置。","Set rotation, C indexing, clamping and transfer separately in channel operations.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.project.cell.turrets.indices,id:\.self) { i in
                Section(model.project.cell.turrets[i].name) {
                    Picker(L("初始工位","Initial station"),selection:$model.project.cell.turrets[i].initialStationID) {
                        ForEach(model.project.cell.turrets[i].stations) { Text($0.name).tag($0.id) }
                    }
                    number(L("相邻工位换位 · s","Neighbouring index · s"),value:$model.project.cell.turrets[i].indexDurationSeconds)
                    number(L("停靠时间 · s","Parking time · s"),value:$model.project.cell.turrets[i].parkDurationSeconds)
                    Toggle(L("初始已停靠","Initially parked"),isOn:$model.project.cell.turrets[i].parkedInitially)
                }
            }
            Section(L("工件与装夹","Workpieces and gripping")) {
                ForEach(model.project.cell.workpieces) { part in
                    LabeledContent(part.name,value:part.ownerSpindleID ?? L("未装夹","Unclamped"))
                    Text(String(format:L("夹持 %.2f mm","Grip %.2f mm"),part.gripLengthMM)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("整机运动查询","Machine motion checks")) {
                LabeledContent(L("显式查询","Explicit checks"),value:"\(model.project.machineChecks.count)")
                Text(L("几何、轴链与低频配置随完整配置文件保存；没有提供运动查询的工序会明确标为未覆盖。","Geometry, axis chains and uncommon settings are saved in the complete setup file. Operations without motion queries remain explicitly uncovered.")).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy)
    }
    private var schedule:some View {
        List {
            ForEach(model.project.cell.channels) { channel in
                Section(channel.name) {
                    ForEach(model.project.cell.steps.filter { $0.channelID == channel.id }.sorted { $0.order < $1.order }) { step in
                        Button { selectedStep = .step(step.id) } label: {
                            HStack {
                                VStack(alignment:.leading) { Text(step.id); Text(actionName(step.action)).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if let entry = model.artifact?.schedule.steps.first(where:{ $0.stepID == step.id }) {
                                    Text(String(format:"%.2f – %.2f s",entry.startSeconds,entry.endSeconds)).font(.caption.monospacedDigit())
                                }
                                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight:44)
                        }.disabled(model.busy)
                    }
                }
            }
        }
    }
    private var results:some View {
        List {
            if let artifact = model.artifact {
                Section {
                    LabeledContent(L("名义排程","Nominal schedule"),value:String(format:"%.2f s",artifact.schedule.totalSeconds))
                    LabeledContent(L("已计算工序","Calculated jobs"),value:"\(artifact.jobs.count)")
                    LabeledContent(L("接料记录","Transfer records"),value:"\(artifact.schedule.transfers.count)")
                }
                Section {
                    Button(L("加工仿真","Simulate machining"),systemImage:"play.rectangle") { camPreview = .init(source:.cell(.init(cell:model.project),artifact)) }
                    NavigationLink(L("机床模型与驱动设置","Machine geometry and drive setup")) { VirtualMachineWorkbenchView(project:.init(cell:model.project),directory:directory.appendingPathComponent("virtual"),cellArtifact:artifact,autoCalculate:true,embedded:true) }
                }
                Section(L("剩余材料","Remaining material")) {
                    ForEach(artifact.finalStock.keys.sorted(),id:\.self) { key in
                        LabeledContent(key,value:String(format:"%.3f mm³",artifact.finalStock[key]!.remainingMM3))
                    }
                }
                Section(L("工序去料与回放","Operation removal and replay")) {
                    ForEach(artifact.jobs.indices,id:\.self) { i in
                        let job = artifact.jobs[i]
                        if let step = artifact.executedCell.steps.first(where:{ $0.id == job.stepID }),case .operate(let operation) = step.action {
                            NavigationLink(job.stepID) { CellStockPreview(study:operation.study,job:job) }
                        }
                    }
                }
                Section(L("碰撞反馈","Collision feedback")) {
                    ForEach(artifact.jobs.indices,id:\.self) { i in
                        let job = artifact.jobs[i]
                        DisclosureGroup(job.stepID+" · "+localCollisionState(job.artifact.result.collisions)) {
                            ForEach(job.artifact.result.collisions.indices,id:\.self) { k in
                                let collision = job.artifact.result.collisions[k]
                                VStack(alignment:.leading) {
                                    Text(collision.component+" · "+collision.state)
                                    Text(collision.message).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }
                    }
                    if artifact.machineFeedback.isEmpty { Text(L("尚未提供整机运动查询。","No machine motion checks supplied.")) }
                    ForEach(artifact.machineFeedback.indices,id:\.self) { i in
                        let result = artifact.machineFeedback[i]
                        LabeledContent(result.stepID,value:machineState(result.result))
                    }
                }
                DisclosureGroup(L("计算范围与详情","Calculation scope and details")) {
                    ForEach(artifact.warnings,id:\.self) { Text($0).font(.caption) }
                    ForEach(artifact.machineFeedback.indices,id:\.self) { i in
                        Text(artifact.machineFeedback[i].result.scope).font(.caption)
                        ForEach(artifact.machineFeedback[i].result.warnings,id:\.self) { Text($0).font(.caption) }
                    }
                }
            } else if model.savedResultAvailability == .available || model.savedResultAvailability == .unavailable {
                ContentUnavailableView {
                    Label(model.savedResultAvailability == .unavailable
                        ? L("保存的结果暂不可用","Saved result unavailable")
                        : L("已保存结果尚未打开","Saved result is not open"),systemImage:"doc.badge.clock")
                } description: {
                    Text(model.savedResultAvailability == .unavailable
                        ? L("可重试打开，或在问题详情中查看原因。","Try opening it again, or see Problem details.")
                        : L("打开后可查看已保存的排程和剩余材料，无需重新计算。","Open the saved schedule and remaining material without recalculating."))
                } actions: {
                    Button(L("打开已保存结果","Open saved result"),systemImage:"folder") { requestSavedOpen() }
                        .accessibilityIdentifier("cell.openSavedResult").disabled(model.busy)
                }
            } else { ContentUnavailableView(L("尚无结果","No results yet"),systemImage:"gearshape.2",description:Text(L("完成设置后计算。","Calculate after completing the setup."))) }
            if let exported { ShareLink(item:exported) { Label(L("分享导出文件","Share exported file"),systemImage:"square.and.arrow.up") } }
            if !model.diagnostic.isEmpty { DisclosureGroup(L("问题详情","Problem details")) { Text(model.diagnostic).textSelection(.enabled).font(.caption) } }
        }
    }
    private func export(input:Bool) { do { exported = try model.export(input:input); tab = 2 } catch { model.report(error) } }
    private func machineState(_ result:MachineQueryResult)->String {
        if !result.hasCollisionCoverage { return L("没有待查询部件对","No body pairs selected") }
        if result.hasInterference { return L("发现干涉","Interference found") }
        if result.hasUnresolvedQueries { return L("存在未决查询","Unresolved queries") }
        return L("采样位置未发现干涉","No interference at sampled poses")
    }
    private func localCollisionState(_ collisions:[ManufacturingResult.Collision])->String {
        if collisions.contains(where:{ ["intersecting","clearance"].contains($0.state) }) { return L("局部检查发现干涉","Local interference found") }
        if collisions.contains(where:{ $0.state == "uncertain" }) { return L("局部检查有未决项","Local checks unresolved") }
        return L("已检查位置未发现干涉","No interference at checked positions")
    }
    private func number(_ title:String,value:Binding<Double>)->some View { HStack { Text(title); Spacer(); TextField(title,value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth:120) }.frame(minHeight:44) }
    private func actionName(_ action:CellAction)->String {
        switch action {
        case .operate:return L("加工","Machining");case .transfer:return L("接料","Transfer");case .synchronize:return L("主轴同步","Spindle synchronization")
        case .spindle:return L("主轴状态","Spindle state");case .chuck:return L("卡盘","Chuck");case .indexTurret:return L("刀塔换位","Turret index")
        case .parkTurret:return L("停靠刀塔","Park turret");case .approach:return L("接近","Approach");case .retract:return L("退刀","Retract")
        case .dwell:return L("停留","Dwell");case .barrier:return L("通道会合","Channel barrier");case .wait:return L("等待","Wait")
        }
    }
}
#endif
