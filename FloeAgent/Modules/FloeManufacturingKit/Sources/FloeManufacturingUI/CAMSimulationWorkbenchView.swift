// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

public struct CAMSimulationWorkbenchView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var model:CAMPreviewModel
    @State private var columns:NavigationSplitViewVisibility = .all
    @State private var inspector = false
    @State private var displayOptions = false
    @State private var operationInspector = false
    private let autoplay:Bool
    private let initialOperationID:String?
    private let viewState:Data?
    public init(source:CAMPreviewSource,directory:URL,autoplay:Bool = false,initialOperationID:String? = nil,viewState:Data? = nil) {
        _model = State(initialValue:CAMPreviewModel(source:source,directory:directory));self.autoplay = autoplay;self.initialOperationID = initialOperationID;self.viewState = viewState
    }
    public var body:some View {
        NavigationSplitView(columnVisibility:$columns) {
            operations.navigationTitle(L("工序","Operations")).navigationSplitViewColumnWidth(min:220,ideal:270,max:320)
        } detail: {
            simulation
                .navigationTitle(model.program?.name ?? L("加工仿真","Machining simulation"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button(L("完成","Done")) { model.close();dismiss() }.accessibilityIdentifier("cam.preview.done") }
                    ToolbarItemGroup(placement:.primaryAction) {
                        Button { model.stop();operationInspector.toggle() } label: { Image(systemName:"slider.horizontal.3").frame(width:44,height:44) }
                            .accessibilityLabel(L("工序与刀具","Operation and tool")).accessibilityIdentifier("cam.preview.operation-details")
                            .disabled(model.operationInspection == nil)
                        displayMenu
                        Menu {
                            Button(L("保存仿真","Save simulation"),systemImage:"square.and.arrow.down") { model.save() }.disabled(model.program == nil || model.fileBusy).accessibilityIdentifier("cam.preview.save")
                            Button(L("重新打开保存的仿真","Reopen saved simulation"),systemImage:"arrow.clockwise") { model.reopen() }.disabled(model.program == nil || model.fileBusy).accessibilityIdentifier("cam.preview.reopen")
                            if let saved = model.savedURL { ShareLink(item:saved) { Label(L("分享结果","Share result"),systemImage:"square.and.arrow.up") } }
                            Button(L("预览详情","Preview details"),systemImage:"checklist") { model.stop();inspector = true }
                        } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.accessibilityLabel(L("文件与报告","Files and reports")).accessibilityIdentifier("cam.preview.menu")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .task { model.prepare(autoplay:autoplay,initialOperationID:initialOperationID,viewState:viewState) }
        .onDisappear { model.close() }
        .sheet(isPresented:$inspector) { inspection }
        .inspector(isPresented:$operationInspector) {
            if let value = model.operationInspection { CAMOperationInspector(value:value) { operationInspector = false }.inspectorColumnWidth(min:280,ideal:350,max:420) }
        }
    }
    private var operations:some View {
        List {
            Section {
                Button { model.select(nil) } label: {
                    HStack { Label(L("全部工序","All operations"),systemImage:"list.bullet");Spacer();if model.settings.selectedChapterID == nil { Image(systemName:"checkmark") } }.frame(minHeight:44)
                }.accessibilityIdentifier("cam.preview.all")
                if let program = model.program {
                    ForEach(program.chapters) { chapter in
                        Button { model.select(chapter.id) } label: {
                            HStack(spacing:10) {
                                Image(systemName:chapter.kind == "machine" ? "gearshape" : "point.topleft.down.to.point.bottomright.curvepath")
                                VStack(alignment:.leading,spacing:4) {
                                    Text(camChapterName(chapter)).foregroundStyle(.primary)
                                    if let tool = chapter.toolName { Text(tool).font(.caption).foregroundStyle(.secondary) }
                                    if let start = chapter.start,let end = chapter.end {
                                        Text(program.metric == .seconds ? String(format:"%.1f–%.1f s",start,end) : String(format:"%.1f mm",end-start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    } else { Text(L("仅有轨迹，暂无时间数据","Geometry only; no timing")).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength:0)
                                if model.settings.selectedChapterID == chapter.id { Image(systemName:"checkmark") }
                                else if model.frame?.activeChapterIDs.contains(chapter.id) == true { Image(systemName:"play.fill").font(.caption).accessibilityLabel(L("当前工序","Current operation")) }
                            }.frame(minHeight:44).contentShape(.rect)
                        }.buttonStyle(.plain).listRowBackground(model.settings.selectedChapterID == chapter.id ? Color.accentColor.opacity(0.1):Color.clear).accessibilityIdentifier("cam.preview.operation.\(chapter.id)")
                    }
                }
            } header: { Text(L("加工顺序","Machining sequence")) }
            if model.settings.selectedChapterID != nil {
                Section {
                    Picker(L("播放范围","Playback range"),selection:Binding(get:{ model.settings.selectedOnly },set:{ model.settings.selectedOnly = $0;model.changeScope() })) {
                        Text(L("所有工序","All operations")).tag(false)
                        Text(L("当前工序","Current operation")).tag(true)
                    }.pickerStyle(.segmented).disabled(model.selectedChapter?.start == nil).accessibilityIdentifier("cam.preview.scope")
                }
            }
            Section {
                Text(L("选择工序可跳到起点。播放、单步和进度拖动都使用当前工件的刀路。","Select an operation to jump to its start. Playback, stepping and scrubbing use this workpiece’s toolpaths.")).font(.caption).foregroundStyle(.secondary)
            }
        }.listStyle(.sidebar)
    }
    private var simulation:some View {
        VStack(spacing:0) {
            if let program = model.program,let frame = model.frame {
                ZStack(alignment:.topLeading) {
                    VirtualMachineViewport(scene:frame.scene,revision:model.cameraRevision,smooth:model.settings.smooth,cellSize:program.resolutionMM,warningBodies:[],preview:frame,settings:model.settings,onSelectChapter:{ model.select($0) },chapterNames:Dictionary(uniqueKeysWithValues:program.chapters.map { ($0.id,camChapterName($0)) }),onSelectionBudget:{ model.reportSelectionBudget() })
                    VStack(alignment:.leading,spacing:4) {
                        Text(currentOperation).font(.subheadline.weight(.semibold)).accessibilityIdentifier("cam.preview.active-operation")
                        if !model.timed { Text(L("几何回放 · 未提供加工时间","Geometric playback · no machining time")).font(.caption).foregroundStyle(.secondary) }
                        Text(model.settings.displayScope == .machining ? L("加工区域","Machining area") : L("整机检查","Machine inspection")).font(.caption).foregroundStyle(.secondary)
                    }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(12).allowsHitTesting(false)
                    VStack { Spacer();legend }.padding(12).frame(maxWidth:.infinity,alignment:.leading).allowsHitTesting(false)
                }.frame(minHeight:240).layoutPriority(1)
                Divider()
                transport
                Divider()
                readout(frame).padding(.horizontal,14).padding(.vertical,8)
            } else if model.preparing {
                VStack(spacing:12) { ProgressView();Text(L("正在准备当前刀路…","Preparing current toolpaths…")) }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ContentUnavailableView { Label(L("尚不能播放","Preview unavailable"),systemImage:"point.topleft.down.to.point.bottomright.curvepath") } description: { Text(model.notice) } actions: { Button(L("重试","Retry")) { model.prepare() } }
            }
            if !model.notice.isEmpty { Text(model.notice).font(.caption).padding(8).frame(maxWidth:.infinity).background(.bar).accessibilityIdentifier("cam.preview.notice") }
        }
    }
    private var currentOperation:String {
        guard let program = model.program,let active = model.frame?.activeChapterIDs.first,let chapter = program.chapters.first(where:{ $0.id == active }) else { return L("加工仿真","Machining simulation") }
        return camChapterName(chapter)
    }
    private var legend:some View {
        HStack(spacing:14) {
            Label(L("切削","Cutting"),systemImage:"line.diagonal").foregroundStyle(.teal)
            Label(L("快移 / 退刀","Rapid / retract"),systemImage:"line.diagonal").foregroundStyle(.orange)
            Label(L("已走轨迹","Traversed"),systemImage:"line.diagonal").foregroundStyle(.green)
            if model.settings.selectedChapterID != nil { Label(L("选中工序","Selected operation"),systemImage:"line.diagonal").foregroundStyle(.blue) }
        }.font(.caption).padding(6).background(.regularMaterial,in:RoundedRectangle(cornerRadius:6))
    }
    private var transport:some View {
        VStack(spacing:2) {
            HStack(spacing:8) {
                Slider(value:Binding(get:{ model.settings.position },set:{ model.scrub($0) }),in:model.range.lowerBound...max(model.range.upperBound,model.range.lowerBound+0.000001))
                    .accessibilityLabel(L("加工进度","Machining progress")).accessibilityIdentifier("cam.preview.position")
                Text(positionLabel).font(.caption.monospacedDigit()).fixedSize()
            }.padding(.horizontal,16)
            HStack(spacing:4) {
                transportButton("backward.end.fill",L("回到起点","Go to start"),"start") { model.scrub(model.range.lowerBound) }
                transportButton("backward.frame.fill",L("上一步","Previous move"),"previous") { model.step(forward:false) }
                transportButton(model.playing ? "pause.fill" : "play.fill",model.playing ? L("暂停","Pause") : L("播放","Play"),"play") { model.playing ? model.stop() : model.play() }
                    .keyboardShortcut(.space,modifiers:[])
                transportButton("forward.frame.fill",L("下一步","Next move"),"next") { model.step(forward:true) }
                transportButton("forward.end.fill",L("到达终点","Go to end"),"end") { model.scrub(model.range.upperBound) }
                Spacer(minLength:4)
                Menu {
                    ForEach([0.05,0.25,1,5,20],id:\.self) { speed in
                        Button { model.settings.speed = speed } label: { if model.settings.speed == speed { Label(String(format:"%g×",speed),systemImage:"checkmark") } else { Text(String(format:"%g×",speed)) } }
                    }
                } label: { Text(String(format:"%g×",model.settings.speed)).monospacedDigit().frame(minWidth:44,minHeight:44) }.accessibilityLabel(L("播放速度","Playback speed"))
                Menu {
                    ForEach(CAMCameraPreset.allCases,id:\.self) { preset in Button(cameraName(preset)) { model.settings.camera = preset;model.cameraRevision = UUID() } }
                } label: { Image(systemName:"viewfinder").frame(width:44,height:44) }.accessibilityLabel(L("标准视图","Standard views"))
            }.padding(.horizontal,12)
        }.padding(.top,6).disabled(model.program?.extent == 0)
    }
    private var positionLabel:String {
        let range = model.range,position = model.settings.position-range.lowerBound,extent = range.upperBound-range.lowerBound
        if model.timed { return String(format:"%.1f / %.1f s",position,extent) }
        return String(format:"%.1f%%",100*position/max(0.000001,extent))
    }
    private func transportButton(_ icon:String,_ title:String,_ id:String,action:@escaping()->Void)->some View {
        Button(action:action) { Image(systemName:icon).frame(width:44,height:44) }.accessibilityLabel(title).accessibilityIdentifier("cam.preview."+id)
    }
    private func readout(_ frame:CAMPreviewFrame)->some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:20) {
                if frame.tools.isEmpty { Text(L("当前为辅助动作，未提供刀具移动轨迹","Auxiliary action; no tool trajectory supplied")).foregroundStyle(.secondary) }
                ForEach(frame.tools) { tool in
                    HStack(spacing:12) {
                        Text(camOperationName(tool.name)).fontWeight(.medium)
                        let path = frame.paths.first { $0.id == tool.pathID }
                        Text(camMoveName(path?.moveType))
                        Text(String(format:"X %.3f  Y %.3f  Z %.3f",tool.tipMM[0],tool.tipMM[1],tool.tipMM[2])).monospacedDigit().accessibilityIdentifier("cam.preview.tcp")
                        if let feed = tool.feedMMPerMinute { Text(String(format:"F %.1f mm/min",feed)).monospacedDigit() }
                        if let rpm = tool.rpm { Text(String(format:"S %.0f rpm",rpm)).monospacedDigit() }
                        else { Text(L("未提供主轴转速","Spindle speed not supplied")).foregroundStyle(.secondary) }
                        if let joints = tool.joints,joints.count == 5 { Text(String(format:"A %.2f°  C %.2f°",joints[3],joints[4])).monospacedDigit() }
                    }
                }
            }.font(.caption).frame(minHeight:24)
        }
    }
    private var displayMenu:some View {
        Button { displayOptions = true } label: { Image(systemName:"eye").frame(width:44,height:44) }
            .accessibilityLabel(L("显示选项","Display options")).accessibilityIdentifier("cam.preview.display")
            .popover(isPresented:$displayOptions) { displayPanel.frame(width:360,height:610).presentationCompactAdaptation(.sheet) }
    }
    private var displayPanel:some View {
        NavigationStack {
          Form {
            Section {
                Picker(L("范围","Scope"),selection:Binding(get:{ model.settings.displayScope },set:{ model.setDisplayScope($0) })) {
                    Text(L("加工区域","Machining area")).tag(CAMDisplayScope.machining)
                    Text(L("整机检查","Machine inspection")).tag(CAMDisplayScope.machine)
                }.pickerStyle(.segmented).accessibilityIdentifier("cam.display.scope")
            }
            Section(L("对象显示","Object display")) {
                objectDisplay(L("主轴鼻端","Spindle nose"),key:\.spindleDisplay,id:"spindle")
                objectDisplay(L("刀杆与刀柄","Shank and holder"),key:\.holderDisplay,id:"holder")
                objectDisplay(L("卡盘、工作台与夹具","Workholding and fixtures"),key:\.workholdingDisplay,id:"workholding")
                objectDisplay(L("床身、立柱与外壳","Bed, column and housing"),key:\.structureDisplay,id:"structure")
                VStack(alignment:.leading) {
                    HStack { Text(L("透明度","Transparency"));Spacer();Text(model.settings.transparency,format:.percent.precision(.fractionLength(0))).monospacedDigit() }
                    Slider(value:Binding(get:{ model.settings.transparency },set:{ model.settings.transparency = $0 }),in:0.1...0.9).accessibilityIdentifier("cam.display.transparency")
                }
            }
            Section(L("刀路与材料","Toolpaths and material")) {
            Picker(L("刀路","Toolpaths"),selection:Binding(get:{ model.settings.paths },set:{ model.settings.paths = $0 })) {
                Text(L("全部刀路","All toolpaths")).tag(CAMPathVisibility.all)
                Text(L("所选工序","Selected operation")).tag(CAMPathVisibility.selected)
                Text(L("隐藏刀路","Hide toolpaths")).tag(CAMPathVisibility.hidden)
            }
            Toggle(L("毛坯与剩余材料","Stock and remaining material"),isOn:setting(\.showStock))
            Toggle(L("半透明材料","Translucent material"),isOn:setting(\.translucentStock))
            Toggle(L("刀具与刀柄","Tool and holder"),isOn:setting(\.showTools)).accessibilityIdentifier("cam.preview.tools")
            Toggle(L("夹具","Fixtures"),isOn:setting(\.showFixtures))
            Toggle(L("平滑着色","Smooth shading"),isOn:setting(\.smooth)).accessibilityIdentifier("cam.preview.smooth")
            }
          }.accessibilityIdentifier("cam.display.form").navigationTitle(L("显示选项","Display options")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done")) { displayOptions = false }.accessibilityIdentifier("cam.display.done") } }
        }
    }
    private func objectDisplay(_ title:String,key:WritableKeyPath<CAMPreviewSettings,CAMObjectVisibility>,id:String)->some View {
        Picker(title,selection:Binding(get:{ model.settings[keyPath:key] },set:{ model.settings[keyPath:key] = $0 })) {
            Text(L("实体","Solid")).tag(CAMObjectVisibility.solid)
            Text(L("半透明","Translucent")).tag(CAMObjectVisibility.translucent)
            Text(L("隐藏","Hidden")).tag(CAMObjectVisibility.hidden)
        }.accessibilityIdentifier("cam.display."+id)
    }
    private func setting(_ key:WritableKeyPath<CAMPreviewSettings,Bool>)->Binding<Bool> { .init(get:{ model.settings[keyPath:key] },set:{ model.settings[keyPath:key] = $0 }) }
    private func cameraName(_ preset:CAMCameraPreset)->String { switch preset { case .isometric:L("等轴测 / 适合窗口","Isometric / Fit");case .top:L("俯视","Top");case .front:L("正视","Front");case .right:L("右视","Right") } }
    private var inspection:some View {
        NavigationStack {
            List {
                Section(L("预览范围","Preview coverage")) {
                    Text(L("刀片、刀具按当前参数显示；未提供的主轴箱、刀柄采用通用外形。去料在已保存的工序阶段更新。","Insert and cutter dimensions follow the current setup; missing housings and holders use generic bodies. Material updates at retained operation stages."))
                    ForEach(model.frame?.coverage ?? model.program?.warnings ?? [],id:\.self) { Text($0).font(.caption) }
                }
                if !model.diagnostic.isEmpty { Section(L("问题详情","Problem details")) { Text(model.diagnostic).textSelection(.enabled) } }
                Section(L("源结果","Source result")) { Text(model.program?.sourceKey ?? "").font(.caption.monospaced()).textSelection(.enabled) }
            }.navigationTitle(L("预览详情","Preview details")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done")) { inspector = false } } }
        }
    }
}
#endif
