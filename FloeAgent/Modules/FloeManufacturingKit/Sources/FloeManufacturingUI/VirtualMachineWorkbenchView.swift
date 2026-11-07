// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Charts
import UniformTypeIdentifiers
import FloeManufacturingCore

public struct VirtualMachineWorkbenchView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var model:VirtualMachineModel
    @State private var tab = 0
    @State private var importing = false
    @State private var editing = false
    @State private var smooth = true
    @State private var revision = UUID()
    @State private var exported:URL?
    @State private var hasSavedResult = false
    private let directory:URL
    private let initialFile:URL?
    private let embedded:Bool
    @State private var didLoadInitialFile = false
    @State private var lastInitialFile:URL?
    private let autoCalculate:Bool
    private let autoPlay:Bool
    public init(project:VirtualMachineProject,directory:URL,cellArtifact:CellSimulationArtifact? = nil,initialFile:URL? = nil,autoCalculate:Bool = false,autoPlay:Bool = false,embedded:Bool = false,sessions:ManufacturingResearchSessions? = nil) {
        _model = State(initialValue:sessions?.virtual(project:project,cellArtifact:cellArtifact) ?? VirtualMachineModel(project:project,directory:directory,cellArtifact:cellArtifact))
        self.directory = directory;self.initialFile = initialFile;self.autoCalculate = autoCalculate;self.autoPlay = autoPlay;self.embedded = embedded
    }
    public var body:some View {
        Group {
            if embedded { workbenchContent }
            else { NavigationStack { workbenchContent } }
        }
    }
    private var workbenchContent:some View {
        @Bindable var model = model
        return Group {
            VStack(spacing:0) {
                if hasSavedResult && model.artifact == nil {
                    HStack {
                        Label(L("已有保存结果","Saved results available"),systemImage:"archivebox")
                        Spacer()
                        Button(L("打开已保存结果","Open saved results")) { model.reopen();tab = 0;refreshSavedResultPresence() }
                            .buttonStyle(.bordered).accessibilityIdentifier("virtual.savedResult.open")
                    }.font(.callout).padding(.horizontal,16).padding(.vertical,8).disabled(model.busy)
                }
                GeometryReader { geometry in
                    if geometry.size.width >= 1_000 { wideContent(width:geometry.size.width) }
                    else { compactContent }
                }.accessibilityIdentifier("virtual.workspace")
                if model.busy { ProgressView(value:model.progress).padding(.horizontal) }
                if !model.notice.isEmpty { Text(displayNotice).font(.callout).padding(8) }
            }
            .navigationTitle(L("虚拟机床配置","Virtual machine setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done")) { dismiss() }.accessibilityIdentifier("virtual.done") }
                ToolbarItemGroup(placement:.primaryAction) {
                    if model.busy { Button(L("取消","Cancel")) { model.cancel() } }
                    else { Button(L("计算","Calculate")) { model.calculate() }.accessibilityIdentifier("virtual.calculate") }
                    Menu {
                        Button(L("完整配置","Complete setup")) { editing = true }
                        Button(L("加载","Load"),systemImage:"folder") { importing = true }
                        Button(L("保存结果","Save result")) { model.save();refreshSavedResultPresence() }.disabled(model.artifact == nil)
                        Button(L("重新打开","Reopen")) { model.reopen();refreshSavedResultPresence() }
                        Button(L("导出设置","Export setup")) { export(input:true) }
                        Button(L("导出结果","Export result")) { export(input:false) }.disabled(model.artifact == nil)
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.disabled(model.busy)
                }
            }
            .sheet(isPresented:$editing) { ResearchSetupEditor(value:model.project,validate:{ try $0.validate() }) { value in model.invalidate();model.project = value } }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json,.data]) { result in
                switch result { case .success(let url):model.load(url);case .failure(let error):model.report(error) }
            }
            .task(id:initialFile) {
                if !didLoadInitialFile || lastInitialFile != initialFile {
                    didLoadInitialFile = true;lastInitialFile = initialFile
                    if let initialFile { model.load(initialFile) } else if autoCalculate && model.artifact == nil { model.calculate() }
                }
                refreshSavedResultPresence()
            }
            .onChange(of:model.project) { _,_ in
                if model.busy || (model.artifact != nil && model.artifact?.inputSHA256 != (try? ResearchArchive.digest(model.project))) { model.invalidate() }
            }
            .onChange(of:model.artifact?.inputSHA256) { _,value in revision = UUID();if value != nil && autoPlay { model.play() } }
            .onChange(of:model.speed) { _,_ in model.stop() }
        }
        .onDisappear { model.stop() } // Visual playback stops; the accepted service calculation remains owned.
    }
    private func refreshSavedResultPresence() {
        let values = try? directory.appendingPathComponent("latest.floetwin").resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        hasSavedResult = values?.isRegularFile == true && values?.isSymbolicLink != true && (values?.fileSize ?? 0) > 0
    }
    private var compactContent:some View {
        VStack(spacing:0) {
            Picker(L("虚拟机床页面","Virtual machine page"),selection:$tab) {
                Text(L("三维回放","3D replay")).tag(0);Text(L("驱动估算","Drive estimate")).tag(1);Text(L("设置","Setup")).tag(2)
            }.pickerStyle(.segmented).padding().accessibilityIdentifier("virtual.pages")
            if tab == 0 { replay } else if tab == 1 { drives } else { setup }
        }
    }
    private func wideContent(width:CGFloat)->some View {
        HStack(spacing:0) {
            VStack(spacing:0) {
                Text(L("设置","Setup")).font(.headline).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,12)
                setup
            }.frame(width:min(420,width*0.38))
            Divider()
            VStack(spacing:0) {
                Picker(L("虚拟机床页面","Virtual machine page"),selection:Binding(get:{ tab == 1 ? 1 : 0 },set:{ tab = $0 })) {
                    Text(L("三维回放","3D replay")).tag(0);Text(L("驱动估算","Drive estimate")).tag(1)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("virtual.pages")
                if tab == 1 { drives } else { replay }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private var replay:some View {
        ScrollView {
            VStack(spacing:14) {
                if let scene = model.scene {
                    VirtualMachineViewport(scene:scene,revision:revision,smooth:smooth,
                        cellSize:model.project.cell.cell.steps.compactMap { if case .operate(let op) = $0.action { op.study.stock.resolutionMM } else { nil } }.min() ?? 1,
                        warningBodies:Set(model.currentCollision?.result.pairs.filter { $0.state != "clear" }.flatMap { [$0.a,$0.b] } ?? []))
                        .frame(minHeight:360,idealHeight:440).clipShape(.rect(cornerRadius:16))
                    HStack {
                        Button { model.playing ? model.stop() : model.play() } label: { Image(systemName:model.playing ? "pause.fill" : "play.fill").frame(width:44,height:44) }
                            .accessibilityLabel(model.playing ? L("暂停","Pause") : L("播放","Play"))
                        Slider(value:Binding(get:{ model.seconds },set:{ model.stop();model.seek($0) }),in:0...max(0.001,model.duration))
                            .accessibilityIdentifier("virtual.replay-position").accessibilityLabel(L("回放时间","Replay time"))
                        Text(String(format:"%.1f / %.1f s",model.seconds,model.duration)).monospacedDigit().font(.caption)
                    }
                    HStack {
                        Picker(L("回放速度","Replay speed"),selection:Binding(get:{ model.speed },set:{ model.speed = $0 })) {
                            Text("0.05×").tag(0.05);Text("0.25×").tag(0.25);Text("1×").tag(1.0);Text("5×").tag(5.0)
                        }.pickerStyle(.segmented)
                        Button(L("重置视角","Reset view")) { revision = UUID() }
                    }
                    Toggle(L("材料显示光顺","Smooth material display"),isOn:$smooth)
                    if let snapshot = model.snapshot {
                        ForEach(snapshot.spindles) { spindle in
                            HStack {
                                Text(spindleName(spindle.id))
                                Spacer();Text(modeName(spindle.mode));Text(String(format:"%.0f rpm",spindle.rpm ?? 0)).monospacedDigit()
                                Text(String(format:"%.1f°",spindle.wrappedPhaseDegrees)).monospacedDigit()
                            }.font(.callout)
                        }
                        ForEach(snapshot.workpieces) { part in
                            LabeledContent(model.project.cell.cell.workpieces.first(where:{ $0.id == part.id })?.name ?? L("工件","Workpiece"),value:part.ownerSpindleID.map(spindleName) ?? L("已释放","Released"))
                        }
                    }
                    Divider()
                    HStack {
                        Text(L("当前姿态碰撞","Current-pose collision"));Spacer()
                        if model.checking { ProgressView() }
                        Button(L("检查当前姿态","Check current pose")) { model.checkPose() }.disabled(model.checking || model.busy)
                    }
                    if let feedback = model.currentCollision {
                        Text(verdictName(feedback.verdict)).foregroundStyle(feedback.verdict == .interference ? .red : .primary)
                        DisclosureGroup(L("碰撞覆盖详情","Collision coverage details")) {
                            Text(String(format:L("%.3f秒的静态姿态；不覆盖采样间运动。","Static pose at %.3f seconds; motion between samples is not covered."),feedback.seconds))
                            ForEach(feedback.result.pairs.indices,id:\.self) { i in
                                let pair = feedback.result.pairs[i];Text(pair.a+" ↔ "+pair.b+" · "+pair.state)
                            }
                        }.font(.caption)
                    } else { Text(L("此时刻尚未检查。","This time has not been checked.")).foregroundStyle(.secondary) }
                    DisclosureGroup(L("回放与形体范围","Replay and geometry scope")) { ForEach(scene.warnings,id:\.self) { Text($0).font(.caption) } }
                } else {
                    ContentUnavailableView(L("准备虚拟机床","Prepare virtual machine"),systemImage:"rotate.3d",description:Text(L("计算后可查看主轴、卡盘、工件和刀具的命令回放。","Calculate to replay commanded spindle, chuck, workpiece and tool poses."))).frame(minHeight:360)
                }
                diagnostics
            }.padding()
        }.accessibilityIdentifier("virtual.replay")
    }
    private var drives:some View {
        List {
            Section { Text(L("驱动估算使用显式惯量、转矩、功率和负载，与三维命令回放分别计算。","Drive estimates use explicit inertia, torque, power and load, separately from 3D commanded replay.")) }
            if let results = model.artifact?.drives,!results.isEmpty {
                ForEach(results) { item in
                    Section(spindleName(item.spindleID)) {
                        quantity(L("加速或制动时间","Acceleration or braking time"),item.result.elapsedSeconds,"s")
                        quantity(L("最终转速","Final speed"),item.result.finalRPM,"rpm")
                        LabeledContent(L("目标状态","Target state"),value:item.result.termination == .targetReached ? L("已达到","Reached") : L("预算内未达到","Not reached within budget"))
                        let samples = item.result.samples.enumerated().filter { $0.offset%max(1,item.result.samples.count/500) == 0 }
                        Chart(samples,id:\.offset) { sample in LineMark(x:.value("s",sample.element.seconds),y:.value("rpm",sample.element.rpm)) }
                            .frame(height:180).accessibilityLabel(L("转速随时间变化","Spindle speed over time"))
                        quantity(L("电输入","Electrical input"),item.result.electricalInputJ,"J")
                        quantity(L("回收电能","Recovered electrical energy"),item.result.regeneratedElectricalJ,"J")
                        DisclosureGroup(L("转矩、相位与能量详情","Torque, phase and energy details")) {
                            quantity(L("累计角度","Unwrapped angle"),item.result.finalPhaseDegrees,"°")
                            quantity(L("动能变化","Kinetic energy change"),item.result.kineticEnergyChangeJ,"J")
                            quantity(L("机械阻力功","Resistance work"),item.result.resistanceWorkJ,"J")
                            quantity(L("能量残差","Energy residual"),item.result.energyBalanceResidualJ,"J")
                            ForEach(item.result.warnings,id:\.self) { Text($0).font(.caption) }
                        }
                    }
                }
            } else { Text(L("尚无驱动估算。可在设置中加入显式参数。","No drive estimate yet. Add explicit parameters in Setup.")) }
            diagnostics
        }.accessibilityIdentifier("virtual.drives")
    }
    private var setup:some View {
        @Bindable var model = model
        return Form {
            ForEach(model.project.scene.spindles.indices,id:\.self) { i in
                Section(spindleName(model.project.scene.spindles[i].id)) {
                    number(L("主轴箱半径 · mm","Housing radius · mm"),value:$model.project.scene.spindles[i].housingRadiusMM)
                    number(L("主轴箱长度 · mm","Housing length · mm"),value:$model.project.scene.spindles[i].housingLengthMM)
                    number(L("卡盘半径 · mm","Chuck radius · mm"),value:$model.project.scene.spindles[i].chuckRadiusMM)
                    number(L("卡盘长度 · mm","Chuck length · mm"),value:$model.project.scene.spindles[i].chuckLengthMM)
                    Stepper(L("卡爪数量","Jaw count")+": \(model.project.scene.spindles[i].jawCount)",value:$model.project.scene.spindles[i].jawCount,in:2...12)
                }
            }
            ForEach(model.project.drives.indices,id:\.self) { i in
                Section(L("驱动估算 · ","Drive estimate · ")+spindleName(model.project.drives[i].spindleID)) {
                    number(L("等效惯量 · kg·m²","Equivalent inertia · kg·m²"),value:$model.project.drives[i].request.configuration.inertiaKgM2)
                    number(L("驱动转矩 · N·m","Motoring torque · N·m"),value:$model.project.drives[i].request.configuration.motoringTorqueNM)
                    number(L("制动转矩 · N·m","Braking torque · N·m"),value:$model.project.drives[i].request.configuration.brakingTorqueNM)
                    number(L("驱动功率 · kW","Motoring power · kW"),value:$model.project.drives[i].request.configuration.motoringPowerKW)
                    number(L("制动功率 · kW","Braking power · kW"),value:$model.project.drives[i].request.configuration.brakingPowerKW)
                    number(L("初始转速 · rpm","Initial speed · rpm"),value:$model.project.drives[i].request.initialRPM)
                    number(L("目标转速 · rpm","Target speed · rpm"),value:$model.project.drives[i].request.targetRPM)
                }
            }
            if model.project.drives.isEmpty { Button(L("加入研究用驱动示例","Add research drive example")) {
                guard let spindle = model.project.cell.cell.spindles.first else { return }
                var request = SpindleDriveRequest.demonstration();request.configuration.maxRPM = spindle.maxRPM;request.targetRPM = min(1500,spindle.maxRPM)
                model.project.drives.append(.init(id:"drive-"+spindle.id,spindleID:spindle.id,request:request))
            } }
            Section { Button(L("完整配置与低频参数","Complete setup and uncommon parameters")) { editing = true }
                Text(L("这里的形体和驱动参数是研究输入，请按实际设备填写。","Geometry and drive parameters here are research inputs. Enter your actual equipment data.")).font(.caption).foregroundStyle(.secondary) }
        }.disabled(model.busy).accessibilityIdentifier("virtual.settings")
    }
    @ViewBuilder private var diagnostics:some View {
        if let exported { ShareLink(item:exported) { Label(L("分享导出文件","Share exported file"),systemImage:"square.and.arrow.up") } }
        if !model.diagnostic.isEmpty { DisclosureGroup(L("问题详情","Problem details")) { Text(model.diagnostic).font(.caption).textSelection(.enabled) } }
    }
    private func number(_ title:String,value:Binding<Double>)->some View {
        LabeledContent {
            TextField(title,value:value,format:.number)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                .frame(maxWidth:120).accessibilityLabel(title)
        } label: { Text(title) }
        .frame(minHeight:44)
    }
    private func quantity(_ title:String,_ value:Double,_ unit:String)->some View { LabeledContent(title,value:String(format:"%.5g %@",value,unit)) }
    private func export(input:Bool) { do { exported = try model.export(input:input) } catch { model.report(error) } }
    private func spindleName(_ id:String)->String {
        guard let spindle = model.project.cell.cell.spindles.first(where:{ $0.id == id }) else { return L("主轴","Spindle") }
        return ManufacturingDisplayNames.spindle(name:spindle.name,id:spindle.id)
    }
    private var displayNotice:String {
        switch model.notice {
        case "虚拟主轴已准备好", "Virtual spindles are ready": L("虚拟机床已准备好","Virtual machine is ready")
        case "已保存虚拟主轴研究", "Virtual spindle study saved": L("已保存虚拟机床配置","Virtual machine setup saved")
        case "虚拟主轴研究已打开", "Virtual spindle study opened": L("虚拟机床配置已打开","Virtual machine setup opened")
        default: model.notice
        }
    }
    private func modeName(_ mode:CellMachineState.SpindleState.Mode)->String { switch mode { case .stopped:L("停转","Stopped");case .rpm:L("旋转","Rotating");case .cIndex:L("C轴定位","C index") } }
    private func verdictName(_ verdict:VirtualPoseCollision.Verdict)->String { switch verdict { case .clear:L("所查形体在此姿态无干涉","Queried bodies are clear at this pose");case .interference:L("此姿态存在形体干涉","Bodies interfere at this pose");case .unresolved:L("此姿态有未决查询或包络命中","This pose has unresolved queries or envelope hits");case .uncovered:L("此姿态没有有效查询覆盖","This pose has no effective query coverage") } }
}
#endif
