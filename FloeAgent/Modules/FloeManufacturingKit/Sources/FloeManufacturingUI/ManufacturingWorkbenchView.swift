// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import UniformTypeIdentifiers

public struct ManufacturingWorkbenchView: View {
    @State private var model: ManufacturingModel
    @State private var importFile = false
    @State private var editor: EditorSheet?
    @State private var stockDraft:ManufacturingStockDraft?
    @State private var stockPresentationID:UUID?
    @State private var preferredCompactColumn:NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility:NavigationSplitViewVisibility = .automatic
    @State private var visibilityBeforeResearch:NavigationSplitViewVisibility?
    @State private var exportItem: ExportItem?
    @State private var playing = false
    @State private var viewportRevision = UUID()
    @State private var playbackRate = 5.0
    @State private var researchFile:URL?
    @State private var camPreview:CAMPreviewRequest?
    @State private var ncRequest:NCWorkbenchRequest?
    @State private var pendingNC:URL?
    @State private var checkingSource = false
    @State private var sourceCheck: Task<Void,Never>?
    private var onClose: (() -> Void)?
    private var onAssistant: (() -> Void)?
    private var hostedInCAD = false
    private var beforeCalculate: (@MainActor () async throws -> Void)?
    public init(directory: URL) { _model = State(initialValue:ManufacturingModel(directory:directory)) }
    public init(model: ManufacturingModel, hostedInCAD: Bool = false, beforeCalculate: (@MainActor () async throws -> Void)? = nil, onClose: (() -> Void)? = nil, onAssistant: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.hostedInCAD = hostedInCAD
        self.beforeCalculate = beforeCalculate
        self.onClose = onClose
        self.onAssistant = onAssistant
    }
    public var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility:$columnVisibility,preferredCompactColumn:$preferredCompactColumn) {
            Form {
                Section(L("加工设置","Machining setup")) {
                    Text(model.study.name).font(.headline)
                    Button {
                        editor = .machine
                    } label: {
                        LabeledContent(L("机床与坐标系","Machine and coordinates"),value:model.study.machineSetup.map { machineName($0.kind) } ?? L("选择机床","Select machine"))
                    }.accessibilityIdentifier("study.machine")
                    Button(L("毛坯与装夹","Stock and fixtures"),systemImage:"cube") { openStockEditor() }.accessibilityIdentifier("study.stock")
                    if model.study.turning.enabled || model.study.machineSetup?.kind == .lathe || model.study.machineSetup?.kind == .turnMill {
                        Button(L("车削型线","Turning profile"),systemImage:"point.topleft.down.to.point.bottomright.curvepath") { editor = .profile }.accessibilityIdentifier("study.profile")
                        Button(L("车削工序与刀片","Turning operations and insert"),systemImage:"wrench.and.screwdriver") { editor = .turningSetup }.accessibilityIdentifier("study.turningSetup")
                    }
                    if model.study.machineSetup?.kind != .lathe {
                        Button(L("铣削刀具与工序","Milling tools and operations"),systemImage:"wrench.and.screwdriver") { editor = .cam }.accessibilityIdentifier("study.cam.sidebar")
                    }
                    if model.study.turning.enabled { Button(L("车削转速与进给","Turning speeds and feeds"),systemImage:"speedometer") { editor = .cutting }.accessibilityIdentifier("study.cutting.common") }
                }
                Section(L("工序","Operations")) {
                    if model.study.turning.enabled {
                        if model.study.configuredTurningSetup.faceEnabled { operationRow("turning-face",name:L("端面车削","Facing"),editor:.turningSetup) }
                        if model.study.configuredTurningSetup.roughEnabled { operationRow("turning-rough",name:L("外圆粗车","Rough turning"),editor:.turningSetup) }
                        if model.study.configuredTurningSetup.profileEnabled { operationRow("turning-profile",name:L("轮廓精车","Finish turning"),editor:.turningSetup) }
                    }
                    if model.study.milling.enabled { operationRow("milling-slot",name:L("动力刀具铣槽","Live-tool slot milling"),editor:.parameters) }
                    if let cam = model.study.cam {
                        ForEach(cam.operations) { operation in
                            if operation.enabled { operationRow(operation.id,name:operation.name,editor:.cam) }
                        }
                    }
                    if model.study.acMotion != nil { operationRow("ac",name:L("A/C 五轴轨迹","A/C five-axis path"),editor:.motion) }
                    Button(L("编辑加工顺序","Edit machining sequence"),systemImage:"list.bullet.rectangle") { editor = .cam }
                }
                Section {
                    Button(L("加工仿真","Simulate machining"),systemImage:"play.rectangle") { openSimulation() }
                        .disabled(model.artifact == nil).accessibilityIdentifier("study.simulate.sidebar")
                    if model.artifact == nil { Text(L("设置工序后生成刀路，再进入仿真。","Set up operations, generate toolpaths, then simulate.")).font(.caption).foregroundStyle(.secondary) }
                    Button(L("后处理与 G-code","Post process and G-code"),systemImage:"curlybraces") { editor = .ncPost }
                        .disabled(model.artifact == nil).accessibilityIdentifier("study.postProcess")
                }
                DisclosureGroup(L("详细工艺参数","Detailed process parameters")) { parameterSections }
                if !hostedInCAD { DisclosureGroup(L("示例与专业研究","Examples and professional research")) {
                    Button(L("阶梯轴","Stepped shaft")) { model.select(0) }.accessibilityIdentifier("sample.shaft")
                    Button(L("车铣件","Turn-mill part")) { model.select(1) }.accessibilityIdentifier("sample.turnmill")
                    Button(L("A/C 五轴轨迹","A/C five-axis motion")) { model.select(2) }.accessibilityIdentifier("sample.fiveaxis")
                    Button(L("刀柄干涉例","Holder interference example")) { model.select(3) }.accessibilityIdentifier("sample.assembly")
                    Button(L("恒线速车削","CSS turning")) { model.select(4) }.accessibilityIdentifier("sample.cutting")
                    Button(L("单主轴车铣工序","Single-spindle turn-mill operations")) { model.select(8) }.accessibilityIdentifier("sample.turnmillcam")
                    Button(L("多工序方料","Multi-operation block")) { model.select(5) }.accessibilityIdentifier("sample.featurecam")
                    Button(L("曲面栅格","Surface raster")) { model.select(6) }.accessibilityIdentifier("sample.surfacecam")
                    Button(L("可选车削工序","Selected turning operations")) { model.select(7) }.accessibilityIdentifier("sample.turningSetup")
                    Button(L("多主轴与多刀塔工程","Multi-spindle and multi-turret project"),systemImage:"gearshape.2") { researchFile = nil;editor = .cell }.accessibilityIdentifier("research.cell")
                    Button(L("材料与工程分析","Materials and engineering analysis"),systemImage:"function") { researchFile = nil;editor = .engineering }.accessibilityIdentifier("research.engineering")
                    Button(L("打开工艺单或结果","Open study or result"),systemImage:"folder") { importFile = true }.accessibilityIdentifier("study.import")
                } }
                if hostedInCAD { DisclosureGroup(L("机床与工程工具","Machine and engineering tools")) {
                    Button(L("多主轴与多刀塔配置","Multi-spindle and multi-turret setup"),systemImage:"gearshape.2") { researchFile = nil; editor = .cell }.accessibilityIdentifier("research.cell")
                    Button(L("虚拟机床配置","Virtual machine setup"),systemImage:"cube.transparent") { researchFile = nil; editor = .virtual }.accessibilityIdentifier("research.virtual")
                    Button(L("材料与工程分析","Materials and engineering analysis"),systemImage:"function") { researchFile = nil; editor = .engineering }.accessibilityIdentifier("research.engineering")
                    Text(L("这些工具各自保存机床或分析设置，不会替换当前 CAD 模型。","These tools save their own machine or analysis setup and do not replace the current CAD model.")).font(.footnote).foregroundStyle(.secondary)
                } }
            }
            .navigationTitle(L("切削加工","Machining"))
            .accessibilityIdentifier("manufacturing.sidebar")
            .disabled(model.isBusy)
        } detail: {
            NavigationStack {
            VStack(spacing:0) {
                ZStack(alignment:.topLeading) {
                    StockViewport(study:model.study,inputRevision:viewportRevision,artifact:model.artifact,replay:model.replay,showPaths:model.showPaths,showFixtures:model.showFixtures,smoothStock:model.smoothStock,showAssembly:model.showAssembly,showReference:model.showReference)
                    VStack(alignment:.leading,spacing:5) {
                        Text(model.study.name).font(.headline)
                        Text(model.smoothStock ? L("平滑着色 · 保留原始边界","Smooth shading · original edges retained") : L("原始网格 · 近似去料","Raw mesh · approximate stock")).font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding(16)
                }.frame(minHeight:240)
                HStack {
                    Toggle(L("刀路","Toolpaths"),isOn:$model.showPaths).toggleStyle(.button)
                    Toggle(L("夹具","Fixtures"),isOn:$model.showFixtures).toggleStyle(.button)
                    Spacer()
                    Button(L("加工仿真","Simulate machining"),systemImage:"play.rectangle") { openSimulation() }.disabled(model.artifact == nil || model.isBusy).accessibilityIdentifier("study.simulate")
                }.frame(minHeight:44).padding(.horizontal,16).background(.bar)
                Divider()
                results.frame(maxHeight:260)
            }
            .navigationTitle(L("加工预览","Machining preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editor?.isResearch != true {
                if let onAssistant {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("作品助手", "Work assistant"), systemImage: "sparkles") {
                            if let stockDraft,let stockPresentationID { hideStockEditor(stockDraft.id,presentationID:stockPresentationID) }
                            onAssistant()
                        }
                            .accessibilityIdentifier("space.editor.assistant")
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("完成", "Done"), action: onClose).accessibilityIdentifier("space.editor.done")
                    }
                }
                ToolbarItem(placement:.topBarLeading) {
                    if !hostedInCAD { Menu {
                        Button(L("阶梯轴","Stepped shaft")) { model.select(0) }.accessibilityIdentifier("sample.shaft.menu")
                        Button(L("车铣件","Turn-mill part")) { model.select(1) }.accessibilityIdentifier("sample.turnmill.menu")
                        Button(L("A/C 五轴轨迹","A/C five-axis motion")) { model.select(2) }.accessibilityIdentifier("sample.fiveaxis.menu")
                        Button(L("刀柄干涉例","Holder interference example")) { model.select(3) }.accessibilityIdentifier("sample.assembly.menu")
                        Button(L("恒线速车削","CSS turning")) { model.select(4) }.accessibilityIdentifier("sample.cutting.menu")
                        Button(L("单主轴车铣工序","Single-spindle turn-mill operations")) { model.select(8) }.accessibilityIdentifier("sample.turnmillcam.menu")
                        Button(L("多工序方料","Multi-operation block")) { model.select(5) }.accessibilityIdentifier("sample.featurecam.menu")
                        Button(L("曲面栅格","Surface raster")) { model.select(6) }.accessibilityIdentifier("sample.surfacecam.menu")
                        Button(L("可选车削工序","Selected turning operations")) { model.select(7) }.accessibilityIdentifier("sample.turningSetup.menu")
                    } label: { Label(L("工件","Workpiece"),systemImage:"cube").frame(minHeight:44) }.disabled(model.isBusy).accessibilityIdentifier("study.samples") }
                }
                ToolbarItemGroup(placement:.primaryAction) {
                    Button(L("参数","Parameters"),systemImage:"slider.horizontal.3") { editor = .parameters }.disabled(model.isBusy).accessibilityIdentifier("study.parameters")
                    if model.isBusy {
                        Button(L("取消","Cancel"),systemImage:"stop.circle") { model.cancel() }.accessibilityIdentifier("study.cancel")
                    } else {
                        Button(checkingSource ? L("正在检查模型","Checking model") : L("生成刀路","Generate toolpaths"),systemImage:"point.topleft.down.to.point.bottomright.curvepath",action:calculate)
                            .disabled(checkingSource).buttonStyle(.borderedProminent).accessibilityIdentifier("study.calculate")
                    }
                    Menu {
                        Button(L("刀具与工序","Tools and operations"),systemImage:"list.bullet.rectangle") { editor = .cam }.disabled(model.isBusy).accessibilityIdentifier("study.cam")
                        Button(L("生成 G-code","Generate G-code"),systemImage:"curlybraces") { editor = .ncPost }.disabled(model.artifact == nil || model.isBusy).accessibilityIdentifier("study.gcode")
                        Button(L("打开 G-code 轨迹","Open G-code trajectory"),systemImage:"point.topleft.down.to.point.bottomright.curvepath") { ncRequest = .init(file:nil) }.accessibilityIdentifier("study.nc")
                        Button(L("机床与坐标系","Machine and coordinates")) { editor = .machine }.disabled(model.isBusy)
                        Button(L("毛坯与装夹","Stock and fixtures")) { openStockEditor() }.disabled(model.isBusy)
                        Button(L("刀具总成","Tool assembly"),systemImage:"wrench.and.screwdriver") { editor = .assembly }.disabled(model.isBusy).accessibilityIdentifier("study.assembly")
                        Button(L("保存结果","Save result"),systemImage:"square.and.arrow.down") { model.save() }.disabled(model.artifact == nil || model.isBusy).accessibilityIdentifier("study.save")
                        Button(L("重新打开","Reopen"),systemImage:"arrow.clockwise") { model.reopen() }.disabled(model.isBusy).accessibilityIdentifier("study.reopen")
                        Button(L("导出工艺单","Export process sheet")) {
                            do { exportItem = .init(url:try model.exportStudy()) } catch { model.report(error) }
                        }.disabled(model.isBusy).accessibilityIdentifier("study.exportInput")
                        Button(L("导出 STL","Export STL")) { export(stl:true) }.disabled(model.artifact == nil || model.isBusy).accessibilityIdentifier("study.exportSTL")
                        Button(L("导出刀路","Export toolpath")) { export(stl:false) }.disabled(model.artifact == nil || model.isBusy).accessibilityIdentifier("study.exportPath")
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.accessibilityIdentifier("study.menu")
                }
                }
            }
            .navigationDestination(item:researchEditor) { item in
                switch item {
                case .cell: ManufacturingCellWorkbenchView(project:.demonstration(),directory:model.directory.appendingPathComponent("cell"),initialFile:researchFile,embedded:true)
                case .virtual: VirtualMachineWorkbenchView(project:.demonstration(),directory:model.directory.appendingPathComponent("virtual"),initialFile:researchFile,embedded:true)
                case .engineering: EngineeringWorkbenchView(directory:model.directory.appendingPathComponent("engineering"),initialFile:researchFile,embedded:true)
                default: EmptyView()
                }
            }
            }
        }
        .inspector(isPresented:stockEditorPresented) {
            if let stockDraft,let presentationID = stockPresentationID {
                ManufacturingStockEditor(session:stockDraft,isBusy:model.isBusy || checkingSource,isCurrentPresentation:{ isCurrentStockPresentation(stockDraft.id,presentationID:presentationID) },onHide:{ hideStockEditor(stockDraft.id,presentationID:presentationID) },onClose:{ finishStockEditor(stockDraft.id,presentationID:presentationID) }) { edited,expectedFingerprint in
                    guard isCurrentStockPresentation(stockDraft.id,presentationID:presentationID) else { throw ManufacturingError.stale }
                    guard !model.isBusy,!checkingSource else { throw StockEditorCommitError.busy }
                    try model.replaceStudy(edited,expectedFingerprint:expectedFingerprint)
                }
                .id(presentationID)
                .inspectorColumnWidth(min:340,ideal:400,max:480)
                .accessibilityIdentifier("stock.inspector")
            }
        }
        .onChange(of:editor) { previous,route in
            if editor != .stock { stockPresentationID = nil }
            if route?.isResearch == true {
                if previous?.isResearch != true { visibilityBeforeResearch = columnVisibility }
                // A research page uses the feature's available width. Keeping
                // the machining form beside it defeats its wide workbench.
                columnVisibility = .detailOnly
                preferredCompactColumn = .detail
            } else if previous?.isResearch == true {
                columnVisibility = visibilityBeforeResearch ?? .automatic
                visibilityBeforeResearch = nil
            }
        }
        .onChange(of:model.study) { _,_ in
            viewportRevision = UUID(); playing = false
            if model.isBusy || (model.artifact != nil && model.artifact?.inputSHA256 != (try? model.study.fingerprint())) { model.invalidate() }
            do { try model.saveDraft() } catch { model.report(error) }
        }
        .onOpenURL { loadDocument($0) }
        .onDisappear { sourceCheck?.cancel(); sourceCheck = nil; checkingSource = false }
        .fileImporter(isPresented:$importFile,allowedContentTypes:[.json,.data]) { outcome in
            switch outcome { case .success(let url): loadDocument(url); case .failure(let error): model.report(error) }
        }
        .sheet(item:parameterEditor,onDismiss:{ if let pendingNC { ncRequest = .init(file:pendingNC);self.pendingNC=nil } }) { item in
            switch item {
            case .machine: MachineSetupEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .ncPost:
                if let artifact=model.artifact {
                    CAMNCPostView(study:model.study,artifact:artifact,directory:model.directory.appendingPathComponent("nc")) { url in pendingNC=url;editor=nil }
                }
            case .cam: CAMEditor(study:model.study,directory:model.directory) { edited in model.invalidate(); model.study = edited }
            case .stock: EmptyView() // Owned by the stock inspector.
            case .turningSetup: TurningSetupEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .profile: ProfileEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .motion: MotionEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .parameters: ParameterEditor(study:model.study,directory:model.directory) { edited in model.invalidate(); model.study = edited }
            case .assembly: ToolAssemblyEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .cutting: TurningCuttingEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .assessment: ProcessAssessmentEditor(study:model.study) { edited in model.invalidate(); model.study = edited }
            case .cell,.virtual,.engineering: EmptyView() // Owned by the detail navigation destination.
            }
        }
        .fullScreenCover(item:$camPreview) { request in
            CAMSimulationWorkbenchView(source:request.source,directory:model.directory.appendingPathComponent("preview"),initialOperationID:request.operationID,viewState:request.viewState)
        }
        .fullScreenCover(item:$ncRequest) { request in NCProgramWorkbenchView(directory:model.directory.appendingPathComponent("nc"),initialFile:request.file) }
        .sheet(item:$exportItem) { item in ShareFile(url:item.url) }
        .task(id:playing) {
            guard playing else { return }
            if model.replay >= 1 { model.replay = 0 }
            let clock = ContinuousClock()
            var lastTick = clock.now
            while !Task.isCancelled && playing && model.replay < 1 {
                try? await Task.sleep(for:.milliseconds(40)); if Task.isCancelled { break }
                let now = clock.now
                let elapsed = lastTick.duration(to:now).components
                let seconds = max(0,Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18)
                lastTick = now
                if let timeline = timedReplay {
                    model.replay = min(1,model.replay+seconds*playbackRate/max(timeline.totalSeconds,0.001))
                } else { model.replay = min(1,model.replay+0.008) }
            }
            if !Task.isCancelled { playing = false }
        }
    }
    private func calculate() {
        guard !model.isBusy, !checkingSource else { return }
        guard let beforeCalculate else { model.calculate(); return }
        checkingSource = true
        sourceCheck = Task { @MainActor in
            defer { checkingSource = false; sourceCheck = nil }
            do {
                let fingerprint = try model.study.fingerprint()
                try await beforeCalculate(); try Task.checkCancellation()
                guard try model.study.fingerprint() == fingerprint else { throw ManufacturingError.stale }
                model.calculate()
            } catch { if !Task.isCancelled { model.report(error) } }
        }
    }
    private func openSimulation(operationID:String? = nil) {
        guard let artifact = model.artifact,!model.isBusy else { return }
        playing = false;camPreview = .init(source:.study(model.study,artifact),operationID:operationID)
    }
    // One editor route remains authoritative. Professional pages push in the
    // detail stack; small parameter forms retain their existing sheet. A late
    // dismissal/pop cannot clear a different route.
    private var parameterEditor:Binding<EditorSheet?> {
        let presented = editor?.isResearch == true || editor == .stock ? nil : editor
        return Binding(get:{ editor?.isResearch == true || editor == .stock ? nil : editor },set:{ value in
            if let value { editor = value } else if editor == presented { editor = nil }
        })
    }
    private var researchEditor:Binding<EditorSheet?> {
        let presented = editor?.isResearch == true ? editor : nil
        return Binding(get:{ editor?.isResearch == true ? editor : nil },set:{ value in
            if let value { editor = value } else if editor == presented { editor = nil }
        })
    }
    private var stockEditorPresented:Binding<Bool> {
        let sessionID = stockDraft?.id,presentationID = stockPresentationID
        return Binding(get:{
            guard let sessionID,let presentationID else { return false }
            return isCurrentStockPresentation(sessionID,presentationID:presentationID)
        },set:{ presented in
            if !presented,let sessionID,let presentationID { hideStockEditor(sessionID,presentationID:presentationID) }
        })
    }
    private func isCurrentStockPresentation(_ sessionID:UUID,presentationID:UUID)->Bool {
        editor == .stock && stockDraft?.id == sessionID && stockPresentationID == presentationID
    }
    private func openStockEditor() {
        guard editor != .stock,!model.isBusy,!checkingSource else { return }
        if stockDraft == nil { stockDraft = ManufacturingStockDraft(study:model.study) }
        stockPresentationID = UUID();editor = .stock
    }
    private func hideStockEditor(_ sessionID:UUID,presentationID:UUID) {
        guard isCurrentStockPresentation(sessionID,presentationID:presentationID) else { return }
        stockPresentationID = nil;editor = nil
    }
    private func finishStockEditor(_ sessionID:UUID,presentationID:UUID) {
        guard isCurrentStockPresentation(sessionID,presentationID:presentationID) else { return }
        stockPresentationID = nil;editor = nil;stockDraft = nil
    }
    private func operationRow(_ id:String,name:String,editor sheet:EditorSheet)->some View {
        Button {
            if model.artifact != nil { openSimulation(operationID:id) } else { editor = sheet }
        } label: {
            Label(name,systemImage:"point.topleft.down.to.point.bottomright.curvepath").frame(minHeight:44)
        }
    }
    private var parameterSections:some View {
        @Bindable var model = model
        return Group {
                Section(L("毛坯 · 毫米","Stock · mm")) {
                    if model.study.stock.isBox {
                        let bounds = model.study.stock.bounds
                        LabeledContent(L("长方体","Box"),value:zip(bounds.min,bounds.max).map { String(format:"%.1f",$1-$0) }.joined(separator:" × "))
                    } else {
                        number(L("半径","Radius"),value:$model.study.stock.radiusMM)
                        number(L("长度","Length"),value:Binding(get:{ model.study.stock.zMaxMM-model.study.stock.zMinMM },set:{ model.study.stock.zMaxMM = model.study.stock.zMinMM+$0 }))
                    }
                    Button(L("形状、边界与预算","Shape, bounds and budgets")) { openStockEditor() }.accessibilityIdentifier("study.stock")
                    Picker(L("分辨率","Resolution"),selection:$model.study.stock.resolutionMM) {
                        ForEach([0.5,1.0,2.0],id:\.self) { Text($0,format:.number).tag($0) }
                    }
                    if !model.study.stock.isBox { Button(L("编辑型线","Edit profile"),systemImage:"point.topleft.down.to.point.bottomright.curvepath") { editor = .profile }.accessibilityIdentifier("study.profile") }
                }
                Section(L("刀具与有序工序","Tools and ordered operations")) {
                    LabeledContent(L("刀具","Tools"),value:"\(model.study.cam?.tools.count ?? 0)")
                    LabeledContent(L("启用工序","Enabled operations"),value:"\(model.study.cam?.enabledOperations.count ?? 0)")
                    Button(L("设置刀具与工序","Set up tools and operations"),systemImage:"list.bullet.rectangle") { editor = .cam }.accessibilityIdentifier("study.cam.sidebar")
                }
                Section(L("原单槽刀具总成","Original slot tool assembly")) {
                    if let assembly = model.study.millingAssembly {
                        Text(assembly.name).font(.callout)
                        LabeledContent(L("刀杆直径","Shank diameter"),value:String(format:"%.2f mm",assembly.shankDiameterMM))
                    } else {
                        Text(L("当前仅检查切削部分。","Only the cutting part is currently checked.")).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L("设置刀杆与刀柄","Set up shank and holder"),systemImage:"wrench.and.screwdriver") { editor = .assembly }.accessibilityIdentifier("study.assembly.sidebar")
                }
                Section(L("车削","Turning")) {
                    Toggle(L("端面、粗车与精车","Face, rough and finish"),isOn:$model.study.turning.enabled)
                    number(L("切深","Step-over"),value:$model.study.turning.stepOverMM)
                    number(L("精车前留量","Finishing allowance"),value:$model.study.turning.allowanceMM)
                    Button(L("工序、刀片与进退刀","Operations, insert and entry/exit")) { editor = .turningSetup }.accessibilityIdentifier("study.turningSetup")
                    Button(L("切削速度与进给","Cutting speeds and feeds"),systemImage:"speedometer") { editor = .cutting }.accessibilityIdentifier("study.cutting")
                    Button(L("表面、切削力与功率","Surface, cutting force and power"),systemImage:"function") { editor = .assessment }.accessibilityIdentifier("study.assessment")
                }
                Section(L("动力刀具铣削","Live-tool milling")) {
                    Toggle(L("铣槽","Mill slot"),isOn:$model.study.milling.enabled).accessibilityIdentifier("study.milling")
                    number(L("定位角度","Index angle"),value:$model.study.milling.angleDegrees)
                    number(L("槽深","Slot depth"),value:$model.study.milling.depthMM)
                    number(L("槽宽","Slot width"),value:Binding(get:{ model.study.milling.widthMM },set:{ model.study.milling.widthMM = $0; model.study.milling.toolRadiusMM = $0/2 }))
                    number(L("刀具半径","Tool radius"),value:Binding(get:{ model.study.milling.toolRadiusMM },set:{ model.study.milling.toolRadiusMM = $0; model.study.milling.widthMM = 2*$0 }))
                    number(L("切削刃长","Cutting length"),value:$model.study.milling.toolLengthMM)
                }
                if let motion = model.study.acMotion {
                    Section(L("五轴运动","Five-axis motion")) {
                        Text(L("相交 A/C 转台 · 保留输入的实际旋转行程","Intersecting A/C trunnion · preserves physical rotary travel")).font(.caption).foregroundStyle(.secondary)
                        Text(String(format:"C: %.1f° → %.1f°",motion.start[4],motion.end[4])).font(.caption.monospacedDigit())
                        Button(L("编辑运动","Edit motion"),systemImage:"slider.horizontal.3") { editor = .motion }.accessibilityIdentifier("study.motion")
                    }
                }
        }
    }
    private func number(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label,value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth:95).textFieldStyle(.roundedBorder) }.frame(minHeight:44)
    }
    private func loadDocument(_ url:URL) {
        switch url.pathExtension.lowercased() {
        case "floenc","nc","ngc","gcode","tap":ncRequest = .init(file:url)
        case "floepreview":
            let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { let value = try CAMPreviewArchive.open(url);camPreview = .init(source:value.source,viewState:value.viewState) } catch { model.report(error) }
        case "floetwin":
            let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { let (project,artifact) = try VirtualMachineArchive.open(url);camPreview = .init(source:.cell(project,artifact.cellArtifact)) } catch { model.report(error) }
        case "floecell":researchFile = url;editor = .cell
        case "floeanalysis":researchFile = url;editor = .engineering
        default:model.load(url)
        }
    }
    private var timedReplay: CuttingTimeline? {
        guard model.study.acMotion == nil, let timeline = model.artifact?.result.cuttingTimeline,
              timeline.excludedPathIndices.isEmpty else { return nil }
        return timeline
    }
    private var replayBar: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Button { playing.toggle() } label: { Image(systemName:playing ? "pause.fill":"play.fill").frame(width:44,height:44) }.disabled(model.artifact == nil).accessibilityLabel(L("回放刀路","Replay toolpath")).accessibilityIdentifier("study.replay")
                Slider(value:$model.replay,in:0...1).frame(minWidth:100).layoutPriority(1).disabled(model.artifact == nil).accessibilityLabel(L("刀路位置","Toolpath position")).accessibilityIdentifier("study.replayPosition")
                if let timeline = timedReplay {
                    Text(String(format:"%.1f / %.1f s",model.replay*timeline.totalSeconds,timeline.totalSeconds)).font(.caption.monospacedDigit()).fixedSize().accessibilityIdentifier("cutting.replayTime")
                } else if let frames = model.artifact?.result.frames, !frames.isEmpty {
                    Text(L("快照 ","Snapshot ")+"\(min(frames.count,Int(Double(frames.count)*model.replay)+1))/\(frames.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel(L("工序快照","Phase snapshot"))
                }
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:12) {
                    if timedReplay != nil {
                        Picker(L("回放速度","Playback speed"),selection:$playbackRate) {
                            ForEach([1.0,5,20],id:\.self) { Text("\(Int($0))×").tag($0) }
                        }.labelsHidden().pickerStyle(.menu).frame(width:70).accessibilityLabel(L("回放速度","Playback speed")).accessibilityIdentifier("cutting.playbackRate")
                    }
                    Toggle(isOn:$model.showPaths) { Image(systemName:"point.topleft.down.to.point.bottomright.curvepath") }.toggleStyle(.button).accessibilityLabel(L("显示刀路","Show toolpath"))
                    Toggle(isOn:$model.showFixtures) { Image(systemName:"cube.transparent") }.toggleStyle(.button).accessibilityLabel(L("显示夹具","Show fixtures"))
                    Toggle(isOn:$model.smoothStock) { Image(systemName:"circle.lefthalf.filled") }.toggleStyle(.button).accessibilityLabel(L("平滑着色","Smooth shading")).accessibilityIdentifier("study.smooth")
                    if model.study.cam?.partMesh != nil {
                        Toggle(isOn:$model.showReference) { Image(systemName:"square.3.layers.3d") }.toggleStyle(.button).accessibilityLabel(L("显示参考模型","Show reference model")).accessibilityIdentifier("study.showReference")
                    }
                    if model.study.millingAssembly != nil || model.study.cam?.tools.contains(where:{ $0.assembly != nil }) == true {
                        Toggle(isOn:$model.showAssembly) { Image(systemName:"wrench.and.screwdriver") }.toggleStyle(.button).accessibilityLabel(L("显示刀杆与刀柄","Show shank and holder")).accessibilityIdentifier("study.showAssembly")
                    }
                }.frame(minHeight:44)
            }.frame(height:44)
        }.padding(.horizontal,16).background(.bar)
    }
    private var results: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Label(model.status,systemImage:model.state == .completed ? "checkmark.circle.fill" : "circle.dotted").font(.subheadline.weight(.semibold)).accessibilityIdentifier("study.status")
                    Spacer()
                    if model.isBusy { ProgressView(value:model.progress).frame(width:140) }
                    if let artifact = model.artifact { Text(String(format:L("计算 %.2f s · 峰值 %.1f MB","Compute %.2f s · peak %.1f MB"),artifact.elapsedSeconds,Double(artifact.processPeakBytes)/1_000_000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if !model.notice.isEmpty { Text(model.notice).font(.callout).accessibilityIdentifier("study.notice") }
                if let result = model.artifact?.result {
                    if let timeline = result.cuttingTimeline {
                        VStack(alignment:.leading,spacing:4) {
                            Text(String(format:timeline.formatVersion == 2 ? L("名义动作时间 %.2f s","Nominal motion time %.2f s") : L("名义切削时间 %.2f s","Nominal cutting time %.2f s"),timeline.totalSeconds)).font(.headline).accessibilityIdentifier("cutting.totalTime")
                            if !timeline.excludedPathIndices.isEmpty {
                                Text(String(format:L("另有 %d 条路径未计时","%d additional paths have no timing"),timeline.excludedPathIndices.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            if timedReplay != nil, let sample = try? timeline.sample(atSeconds:model.replay*timeline.totalSeconds) {
                                Text(String(format:L("当前进给 %.1f mm/min","Current feed %.1f mm/min"),sample.feedMMPerMinute)).font(.caption.monospacedDigit()).accessibilityIdentifier("cutting.currentFeed")
                                if let rpm = sample.rpm { Text(String(format:L("当前主轴 %.0f rpm","Current spindle %.0f rpm"),rpm)).font(.caption.monospacedDigit()).accessibilityIdentifier("cutting.currentRPM") }
                                else if result.paths.indices.contains(sample.pathIndex), let operationID = result.paths[sample.pathIndex].operationID,
                                        let op = model.study.cam?.operations.first(where:{ $0.id == operationID }) {
                                    Text(op.name+" · "+(model.study.cam?.tools.first { $0.id == op.toolID }?.name ?? op.toolID)).font(.caption).accessibilityIdentifier("cam.currentOperation")
                                    if let rpm = op.cutting?.toolSpindleRPM { Text(String(format:L("动力刀具主轴 %.0f rpm","Live-tool spindle %.0f rpm"),rpm)).font(.caption.monospacedDigit()).accessibilityIdentifier("cam.currentRPM") }
                                }
                                if timeline.segments.indices.contains(sample.segmentIndex), timeline.segments[sample.segmentIndex].spindleLimited {
                                    Text(L("已达主轴转速上限","Spindle speed limit reached")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cutting.limited")
                                }
                            }
                            Text(timeline.formatVersion == 2 ? L("包含明确直线移动与停留；未计未输出的连接、加减速、换刀或旋转轴时间。材料显示为工序快照。","Includes explicit linear moves and dwell; excludes missing links, acceleration, tool changes and rotary-axis time. Stock uses operation snapshots.") : L("仅含已有直线切削段；未包含空移、加减速、主轴升降速、换刀或 A/C 运动时间。材料显示仍为工序快照。","Existing linear cutting segments only; excludes rapid links, acceleration, spindle transients, tool changes and A/C motion time. Stock remains phase snapshots.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let receipt = result.turningSetupReceipt {
                        DisclosureGroup(L("刀片计算用二维形状","Insert profile used in planning")) { InsertOutlinePreview(receipt:receipt) }
                    }
                    if let reports = result.camReport {
                        DisclosureGroup(L("各工序材料与范围","Per-operation material and scope")) {
                            ForEach(Array(reports.enumerated()),id:\.offset) { _,report in
                                VStack(alignment:.leading,spacing:3) {
                                    Text((model.study.cam?.operations.first { $0.id == report.operationID }?.name ?? report.operationID)+" · "+strategyName(report.strategy)).fontWeight(.semibold)
                                    Text(String(format:L("去除 %.2f mm³ · 剩余 %.2f mm³","Removed %.2f mm³ · remaining %.2f mm³"),report.removedMM3,report.remainingMM3))
                                    ForEach(report.limits,id:\.self) { Text($0).foregroundStyle(.secondary) }
                                    Text(report.sources.joined(separator:" · ")).foregroundStyle(.secondary)
                                }.font(.caption).padding(.vertical,3)
                            }
                        }.accessibilityIdentifier("cam.report")
                    }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:120),alignment:.leading)],alignment:.leading,spacing:12) {
                        metric(L("已去除","Removed"),value:result.removedMM3)
                        metric(L("剩余","Remaining"),value:result.remainingMM3)
                        VStack(alignment:.leading) { Text(L("网格面","Mesh faces")).font(.caption).foregroundStyle(.secondary); Text(result.triangles.count,format:.number).monospacedDigit().accessibilityIdentifier("study.faces") }
                    }
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(collisionSummary(result.collisions)) { summary in
                            let c = summary.collision
                            Label(collisionTarget(c)+" · "+toolPartName(c.toolPart)+collisionLabel(c.state),systemImage:c.state == "clear" ? "checkmark.circle":"exclamationmark.triangle")
                                .font(.caption).foregroundStyle(c.state == "clear" ? Color.secondary : c.state == "intersecting" ? Color.red : Color.orange)
                                .accessibilityIdentifier("collision.summary."+summary.id)
                        }
                    }
                    Text(collisionScope(result)).font(.caption).foregroundStyle(.secondary)
                    if !result.collisions.isEmpty {
                        DisclosureGroup {
                            VStack(alignment:.leading,spacing:8) {
                                ForEach(Array(result.collisions.enumerated()),id:\.offset) { _,c in
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(collisionTarget(c)+" · "+toolPartName(c.toolPart)+collisionLabel(c.state)).fontWeight(.semibold)
                                        Text(c.message).foregroundStyle(.secondary)
                                        if let index = c.firstPoseIndex { Text(L("首次记录姿态","First recorded pose")+" \(index)").foregroundStyle(.secondary) }
                                        if let gap = c.minimumGapLowerBoundMM { Text(String(format:L("间距下界 %.4f mm","Gap lower bound %.4f mm"),gap)).foregroundStyle(.secondary) }
                                        if let error = c.geometryErrorMM { Text(String(format:L("几何近似量 %.4f mm","Geometry approximation %.4f mm"),error)).foregroundStyle(.secondary) }
                                    }
                                }
                                if let count = result.assemblyQueryCount { Text(L("总成查询调用","Assembly query calls")+" \(count) / \(model.study.budget.collisionQueryLimit)").foregroundStyle(.secondary).accessibilityIdentifier("collision.queryCount") }
                            }.font(.caption).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                        } label: {
                            Text(L("碰撞详情","Collision details")).accessibilityIdentifier("collision.details")
                        }
                    }
                    DisclosureGroup(L("能力与来源","Capabilities and sources")) {
                        VStack(alignment:.leading,spacing:6) {
                            Text(result.backend)
                            ForEach(result.capabilities,id:\.self) { Text($0) }
                            ForEach(result.warnings,id:\.self) { Text($0).foregroundStyle(.secondary) }
                            Text(L("独立预研宿主；尚未接入主 App。工业精度、双主轴和多刀塔分别记录。","Independent research host; main App integration, industrial accuracy, dual spindles and multiple turrets are separate milestones."))
                        }.font(.caption).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                    }
                }
                if !model.diagnostic.isEmpty { DisclosureGroup(L("问题详情","Problem details")) { Text(model.diagnostic).font(.caption).textSelection(.enabled) }.tint(.orange).accessibilityIdentifier("study.error") }
            }.padding(18)
        }.background(Color(uiColor:.systemBackground)).accessibilityIdentifier("study.results")
    }
    private func metric(_ label: String, value: Double) -> some View { VStack(alignment:.leading) { Text(label).font(.caption).foregroundStyle(.secondary); Text(String(format:"%.1f mm³",value)).font(.title3.monospacedDigit()) } }
    private func collisionLabel(_ state: String) -> String {
        switch state {
        case "clear": L("未见相交","No overlap found")
        case "intersecting": L("相交","Intersection")
        case "clearance": L("间隙不足","Insufficient clearance")
        default: L("查询未决","Unresolved query")
        }
    }
    private func componentName(_ id: String) -> String { id == "chuck" ? L("卡盘","Chuck") : id }
    private func collisionTarget(_ c:ManufacturingResult.Collision) -> String {
        c.targetKind == "stock" ? L("工件剩余材料","Remaining stock") : componentName(c.component)
    }
    private func toolPartName(_ value:String?) -> String {
        switch value {
        case "shank": L("刀杆 · ","Shank · ")
        case "holder": L("刀柄 · ","Holder · ")
        case "cutter": L("切削部分 · ","Cutting part · ")
        case "turningNose": L("车刀刀尖 · ","Turning nose · ")
        default: ""
        }
    }
    private func collisionScope(_ result:ManufacturingResult) -> String {
        if result.camReport != nil { return L("按采样刀位检查已设置的夹具及快移穿料；刀杆、刀柄的覆盖见各工序详情。","Configured fixtures and rapid-through-stock checked at sampled poses; see each operation for shank and holder coverage.") }
        if result.collisions.isEmpty { return L("未执行碰撞查询，请设置夹具或刀具总成。","No collision queries were performed. Configure fixtures or a tool assembly.") }
        if result.collisions.contains(where:{ $0.toolPart == "shank" || $0.toolPart == "holder" }) {
            return L("按采样姿态检查已设置的总成、夹具及近似剩余材料。","Configured assembly, fixtures and approximate stock checked at sampled poses.")
        }
        return L("当前仅检查切削部分与盒形夹具。","Only the cutting part and box fixtures are checked.")
    }
    private struct CollisionSummary: Identifiable {
        var id: String
        var collision: ManufacturingResult.Collision
    }
    private func collisionSummary(_ items:[ManufacturingResult.Collision]) -> [CollisionSummary] {
        let groups = Dictionary(grouping:items) { ($0.targetKind ?? "fixture")+":"+$0.component }
        func rank(_ state:String)->Int { state == "intersecting" ? 3 : state == "uncertain" ? 2 : state == "clearance" ? 1 : 0 }
        return groups.keys.sorted().compactMap { key in
            guard let collision = groups[key]?.max(by:{ rank($0.state)<rank($1.state) }) else { return nil }
            return .init(id:key,collision:collision)
        }
    }
    private func export(stl: Bool) { do { exportItem = .init(url:try model.export(stl:stl)) } catch { model.report(error) } }
}

private struct NCWorkbenchRequest:Identifiable { let id=UUID();let file:URL? }
private enum EditorSheet: String, Identifiable, Hashable {
    case profile,motion,parameters,assembly,cutting,cam,stock,machine,turningSetup,assessment,cell,engineering,virtual,ncPost
    var id:String { rawValue }
    var isResearch:Bool { switch self { case .cell,.engineering,.virtual:true;default:false } }
}
struct ExportItem: Identifiable { var id = UUID(); var url: URL }
struct ShareFile: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context) {}
}
private struct ProfileEditor: View {
    let study: ManufacturingStudy
    let apply: (ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var points: [ProfilePoint]
    @State private var error = ""
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.apply = apply
        _points = State(initialValue: study.profile)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Canvas { context, size in
                        guard let first = points.first, let last = points.last else { return }
                        let extent = max(0.001, last.zMM-first.zMM)
                        let radius = max(0.001, points.map(\.radiusMM).max() ?? 1)
                        func screen(_ p: ProfilePoint, side: Double) -> CGPoint {
                            CGPoint(x: 12 + (p.zMM-first.zMM)/extent * (size.width-24), y: size.height/2 - side*p.radiusMM/radius*(size.height/2-12))
                        }
                        var axis = Path(); axis.move(to: CGPoint(x: 0,y: size.height/2)); axis.addLine(to: CGPoint(x: size.width,y: size.height/2))
                        context.stroke(axis, with: .color(.secondary.opacity(0.4)), style: .init(lineWidth: 1,dash: [4,4]))
                        for side in [-1.0,1.0] {
                            var path = Path(); path.move(to: screen(first,side:side))
                            for point in points.dropFirst() { path.addLine(to: screen(point,side:side)) }
                            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                        }
                    }.frame(height: 160).accessibilityLabel(L("车削型线，沿模型 Z 轴","Turning profile along the model Z axis"))
                    Text(study.source.documentID.hasPrefix("cad:")
                         ? L("初始型线为模型绕 Z 轴的径向外包络，请确认它适用于当前车削工件。", "The initial profile is the model's radial envelope about Z. Check that it describes the intended turned part.")
                         : L("按 Z 顺序设置半径；同一 Z 的点可表达台阶。", "Set radii in Z order. Equal Z values can define a shoulder."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L("型线点 · mm","Profile points · mm")) {
                    HStack { Text("#").frame(width: 24); Spacer(); Text(L("半径","Radius")).frame(maxWidth: 120); Text("Z").frame(maxWidth: 120) }.font(.caption).foregroundStyle(.secondary)
                    ForEach(points.indices,id:\.self) { index in
                        HStack {
                            Text("\(index+1)").font(.caption).foregroundStyle(.secondary).frame(width: 24)
                            Spacer()
                            TextField(L("半径","Radius"),value:coordinate(index,\.radiusMM),format:.number)
                                .accessibilityIdentifier("profile.radius.\(index)")
                            TextField("Z",value:coordinate(index,\.zMM),format:.number)
                                .accessibilityIdentifier("profile.z.\(index)")
                        }.keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(minHeight:44)
                    }.onDelete { offsets in points.remove(atOffsets: offsets) }
                    Button(L("添加型线点","Add profile point"),systemImage:"plus") {
                        let last = points.last ?? .init(1,0)
                        points.append(.init(last.radiusMM,last.zMM+1))
                    }.disabled(points.count >= 256).accessibilityIdentifier("profile.add")
                }
                if !error.isEmpty { Section {
                    Text(L("无法应用型线，请检查点顺序、半径和毛坯范围。","Check the point order, radii and stock bounds before applying the profile.")).foregroundStyle(.orange)
                    DisclosureGroup(L("详情","Details")) { Text(error).font(.caption).textSelection(.enabled) }
                } }
            }.navigationTitle(L("车削型线","Turning profile")).navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.primaryAction) { EditButton() }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do {
                        var draft = study; draft.profile = points
                        if !draft.source.documentID.hasPrefix("cad:") { draft.source.revision += 1; draft.source.contentSHA256 = ManufacturingStudy.digest(try ManufacturingStudy.encoder.encode(points)) }
                        try draft.validate(requireOperations:false); apply(draft); dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("profile.apply") }
            }
        }
    }
    private func coordinate(_ index: Int,_ key: WritableKeyPath<ProfilePoint,Double>) -> Binding<Double> {
        Binding(get: { points.indices.contains(index) ? points[index][keyPath:key] : 0 }, set: { if points.indices.contains(index) { points[index][keyPath:key] = $0 } })
    }
}

private struct MotionEditor: View {
    let study: ManufacturingStudy
    let apply: (ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var motion: ManufacturingStudy.ACMotion
    @State private var problem = ""
    init(study:ManufacturingStudy,apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.apply = apply
        _motion = State(initialValue:study.acMotion ?? .init(start:[7,0,10,20,-170],end:[7,0,10,40,170],toolLengthMM:6,steps:160))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(L("起点 · 毫米 / 度","Start · mm / degrees")) { axisFields(values:$motion.start) }
                Section(L("终点 · 毫米 / 度","End · mm / degrees")) { axisFields(values:$motion.end) }
                Section {
                    HStack { Text(L("刀长 · 毫米","Tool length · mm")); TextField("mm",value:$motion.toolLengthMM,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Stepper(L("采样数","Samples")+" · \(motion.steps)",value:$motion.steps,in:8...512,step:8)
                    Text(L("转角按输入的实际行程计算。","Rotary motion follows the physical travel entered here.")).font(.caption).foregroundStyle(.secondary)
                }
                if !problem.isEmpty { Text(problem).foregroundStyle(.orange).font(.caption) }
            }.navigationTitle(L("五轴运动","Five-axis motion")).toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do { var draft = study; draft.acMotion = motion; try draft.validate(); apply(draft); dismiss() }
                    catch { problem = error.localizedDescription }
                } }
            }
        }
    }
    private func axisFields(values:Binding<[Double]>) -> some View {
        ForEach(0..<5,id:\.self) { i in
            HStack { Text(["X","Y","Z","A","C"][i]); TextField("",value:values[i],format:.number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }.frame(minHeight:44)
        }
    }
}
#endif
