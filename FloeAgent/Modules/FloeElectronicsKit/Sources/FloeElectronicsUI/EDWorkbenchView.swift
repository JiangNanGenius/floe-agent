// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

func edText(_ zh: String, _ en: String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en }

enum EDWorkspaceTab: String, CaseIterable, Identifiable {
    case schematic, board, symbols, footprints, checks, outputs, threeD
    var id: Self { self }
    var title: String {
        switch self {
        case .schematic: edText("原理图", "Schematic")
        case .board: "PCB"
        case .symbols: edText("符号库", "Symbols")
        case .footprints: edText("封装库", "Footprints")
        case .checks: edText("检查", "Checks")
        case .outputs: edText("输出", "Outputs")
        case .threeD: edText("三维", "3D")
        }
    }
}

enum EDCanvasTool: String, CaseIterable, Identifiable {
    case select, place, wire, bus, junction, label, via, zone, outline, hole, erase
    var id: Self { self }
    static let schematicTools: [Self] = [.select, .place, .wire, .bus, .junction, .label, .erase]
    static let boardTools: [Self] = [.select, .place, .wire, .via, .zone, .outline, .hole, .erase]
    var title: String {
        switch self {
        case .select: edText("选择", "Select")
        case .place: edText("放置元件", "Place part")
        case .wire: edText("连线", "Wire")
        case .bus: edText("总线", "Bus")
        case .junction: edText("连接点", "Junction")
        case .label: edText("网络标签", "Net label")
        case .via: edText("过孔", "Via")
        case .zone: edText("铜区", "Copper zone")
        case .outline: edText("绘制板框", "Draw board outline")
        case .hole: edText("安装孔", "Mounting hole")
        case .erase: edText("擦除", "Erase")
        }
    }
    var image: String {
        switch self {
        case .select: "cursorarrow"
        case .place: "plus.square"
        case .wire: "point.topleft.down.to.point.bottomright.curvepath"
        case .bus: "line.3.horizontal"
        case .junction: "circle.fill"
        case .label: "tag"
        case .via: "circle.inset.filled"
        case .zone: "square.dashed.inset.filled"
        case .outline: "pentagon"
        case .hole: "circle"
        case .erase: "eraser"
        }
    }
    func title(on tab: EDWorkspaceTab) -> String {
        self == .wire && tab == .board ? edText("交互布线", "Route tracks") : title
    }
}

enum EDLibraryTool: String, CaseIterable, Identifiable {
    case select, line, rectangle, circle, arc, pin, pad, erase
    var id: Self { self }
    var title: String {
        switch self {
        case .select: edText("选择", "Select")
        case .line: edText("线段", "Line")
        case .rectangle: edText("矩形", "Rectangle")
        case .circle: edText("圆", "Circle")
        case .arc: edText("圆弧", "Arc")
        case .pin: edText("引脚", "Pin")
        case .pad: edText("焊盘", "Pad")
        case .erase: edText("擦除", "Erase")
        }
    }
    var image: String {
        switch self {
        case .select: "cursorarrow"
        case .line: "slash"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .arc: "arrow.up.right.circle"
        case .pin: "pin.fill"
        case .pad: "square.fill"
        case .erase: "eraser"
        }
    }
    static let symbolTools: [Self] = [.select, .line, .rectangle, .circle, .arc, .pin, .erase]
    static let footprintTools: [Self] = [.select, .pad, .line, .rectangle, .circle, .arc, .erase]
}

enum EDCanvasMode: Equatable {
    case schematic(EDCanvasTool), board(EDCanvasTool), symbol(EDLibraryTool), footprint(EDLibraryTool)
}

private enum EDWorkbenchPanel: String, Identifiable {
    case navigator, parts, properties, boardSettings
    var id: Self { self }
}

public struct EDWorkbenchView: View {
    @Bindable var session: EDWorkbenchSession
    let onAssistant: (() -> Void)?
    let onExportPreview: ((EDAExchangeFile, UInt64) -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = EDWorkspaceTab.schematic
    @State private var panel: EDWorkbenchPanel?
    @State private var inspectorVisible = false
    @State private var navigatorVisible = true
    @State private var sheetID: UUID?
    @State private var boardID: UUID?
    @State private var symbolID: UUID?
    @State private var footprintID: UUID?
    @State private var tool = EDCanvasTool.select
    @State private var libraryTool = EDLibraryTool.select
    @State private var labelName = "NET"
    @State private var activeLayer = "F.Cu"
    @State private var graphicStroke = 0.2
    @State private var graphicLayerID = "F.Fab"
    @State private var arcClockwise = false
    @State private var wireWidth = 0.25
    @State private var holeDiameter = 3.2
    @State private var netID = ""
    @State private var placementAngle = 0.0
    @State private var placementFlipped = false
    @State private var showGrid = true
    @State private var reload = false
    @State private var viewportWidth: CGFloat = 0
    @State private var focusNavigationToken: UUID?
    @State private var crossProbeRequest: EDACrossProbeRequest?
    @State private var crossProbeMessage = ""
    @State private var showCrossProbeMessage = false
    @State private var crossProbeTask: Task<Void, Never>?
    @State private var locatingComponent = false
    @State private var showingBackAnnotation = false

    public init(session: EDWorkbenchSession, onAssistant: (() -> Void)? = nil,
                onExportPreview: ((EDAExchangeFile, UInt64) -> Void)? = nil) {
        self.session = session; self.onAssistant = onAssistant; self.onExportPreview = onExportPreview
    }
    private var compactPanels: Bool { sizeClass == .compact || viewportWidth < 1_000 }
    private var currentBoard: EDABoard? { session.project.boards.first { $0.id == boardID } ?? session.project.boards.first }
    private var context: EDADocumentContext? {
        switch tab {
        case .schematic: (sheetID ?? session.project.sheets.first?.id).map { .schematic(sheetID: $0) }
        case .board, .threeD: currentBoard.map { .board(boardID: $0.id) }
        case .symbols: (symbolID ?? session.project.symbols.first?.id).map { .symbol(definitionID: $0) }
        case .footprints: (footprintID ?? session.project.footprints.first?.id).map { .footprint(definitionID: $0) }
        default: nil
        }
    }
    private var mode: EDCanvasMode {
        switch tab {
        case .board: .board(tool)
        case .symbols: .symbol(libraryTool)
        case .footprints: .footprint(libraryTool)
        default: .schematic(tool)
        }
    }
    private var canvasTitle: String {
        switch tab {
        case .schematic: session.project.sheets.first { $0.id == sheetID }?.name ?? session.project.sheets.first?.name ?? tab.title
        case .board: currentBoard?.name ?? "PCB"
        case .symbols: session.project.symbols.first { $0.id == symbolID }?.name ?? tab.title
        case .footprints: session.project.footprints.first { $0.id == footprintID }?.name ?? tab.title
        default: tab.title
        }
    }
    private var partName: String {
        if tab == .board { return session.project.footprints.first { $0.id == footprintID }?.name ?? edText("选择封装", "Choose footprint") }
        return session.project.symbols.first { $0.id == symbolID }?.name ?? edText("选择元件", "Choose part")
    }

    public var body: some View {
        VStack(spacing: 0) {
            workspaceTabs
            Divider()
            if let failure = session.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(failure.message).font(.caption)
                    Spacer()
                    if session.conflictWithOriginal { Button(edText("重新载入", "Reload")) { reload = true } }
                }.padding(8).background(.orange.opacity(0.12))
            }
            workspace
            status
        }
        .accessibilityIdentifier("electronics.workbench")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { Task { do { try await session.undo() } catch { session.report(error) } } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!session.canUndo).accessibilityLabel(edText("撤销", "Undo"))
                Button { Task { do { try await session.redo() } catch { session.report(error) } } } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!session.canRedo).accessibilityLabel(edText("重做", "Redo"))
                if let onAssistant { Button(action: onAssistant) { Label(edText("助手", "Assistant"), systemImage: "sparkles") } }
            }
        }
        .sheet(item: $panel) { item in
            NavigationStack {
                panelContent(item)
                    .navigationTitle(item == .parts ? edText("放置元件", "Place part") : item == .navigator ? edText("项目", "Project") : edText("属性", "Properties"))
                    .edInlineNavigationTitle()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(item == .properties || item == .boardSettings ? edText("关闭", "Close") : edText("完成", "Done")) { panel = nil } } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.background)
        }
        .sheet(item: $crossProbeRequest) { request in
            EDCrossProbePicker(request: request, busy: locatingComponent,
                select: { target in locate(request, targetID: target.id) }, cancel: { crossProbeRequest = nil })
        }
        .sheet(isPresented: $showingBackAnnotation) {
            if let board = currentBoard { EDBackAnnotationSheet(session: session, boardID: board.id) }
        }
        .alert(edText("无法定位", "Cannot locate component"), isPresented: $showCrossProbeMessage) {
            Button(edText("好", "OK"), role: .cancel) { }
        } message: { Text(crossProbeMessage) }
        .onDisappear { crossProbeTask?.cancel(); crossProbeTask = nil }
        .confirmationDialog(edText("放弃未保存的修改并重新载入？", "Discard unsaved changes and reload?"), isPresented: $reload, titleVisibility: .visible) {
            Button(edText("重新载入", "Reload"), role: .destructive) { Task { do { try await session.refresh(discardChanges: true) } catch { session.report(error) } } }
        }
        .onChange(of: tab) { _, _ in
            tool = .select; libraryTool = .select; placementAngle = 0; placementFlipped = false
            if let token=focusNavigationToken,let request=session.focusRequest,request.token==token,request.context==context{
                session.selection = .init(context:request.context,objectIDs:request.objectIDs)
            }else{session.selection = .none}
            focusNavigationToken=nil
        }
        .onChange(of: session.focusRequest) { _, request in
            guard let request else { return }
            switch request.context {
            case .schematic(let id): sheetID = id;if tab != .schematic {focusNavigationToken=request.token;tab = .schematic}
            case .board(let id): boardID = id;if tab != .board {focusNavigationToken=request.token;tab = .board}
            default: break
            }
        }
    }

    private var workspaceTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(EDWorkspaceTab.allCases) { item in
                    Button(item.title) { tab = item }
                        .buttonStyle(.bordered).tint(tab == item ? .accentColor : .secondary)
                        .frame(minHeight: 44).accessibilityIdentifier("electronics.tab." + item.rawValue)
                }
            }.padding(.horizontal, 8)
        }.scrollIndicators(.hidden)
    }
    @ViewBuilder private var workspace: some View {
        switch tab {
        case .checks:
            EDAChecksView(session: session, onFocus: { session.requestFocus($0) })
        case .outputs:
            EDAOutputsView(session: session, onExportPreview: onExportPreview)
        case .threeD:
            EDABoard3DView(project: session.project, boardID: currentBoard?.id)
        default:
            VStack(spacing: 0) {
                editorHeader
                Divider()
                HStack(spacing: 0) {
                    if !compactPanels && navigatorVisible { navigator.frame(width: 200); Divider() }
                    toolRail
                    Divider()
                    VStack(spacing: 0) {
                        toolOptions
                        if let context {
                            EDCanvasEditor(session: session, context: context, mode: mode,
                                           symbolID: symbolID, footprintID: footprintID, labelName: labelName,
                                           layer: activeLayer, width: wireWidth, netID: netID, holeDiameter: holeDiameter,
                                           showGrid: showGrid, placementAngle: $placementAngle, placementFlipped: $placementFlipped,
                                           onCancel: { tool = .select; libraryTool = .select }, onProperties: showProperties,
                                           onWireToolRequested: { tool = .wire }, graphicStroke: graphicStroke,
                                           graphicLayer: tab == .footprints ? EDAGraphicLayers.standardAssignments.first { $0.layerID == graphicLayerID } : nil,
                                           arcClockwise: arcClockwise)
                        } else { ContentUnavailableView(edText("选择图页或库项目", "Select a sheet or library item"), systemImage: "square.dashed") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !compactPanels && inspectorVisible {
                        Divider(); EDAInspector(session: session, context: context).frame(width: 270)
                    }
                }
            }
        }
    }
    private var editorHeader: some View {
        HStack(spacing: 8) {
            Button { if compactPanels { panel = .navigator } else { navigatorVisible.toggle() } } label: { Image(systemName: "sidebar.left").frame(width:44,height:44).contentShape(Rectangle()) }
                .accessibilityLabel(edText("项目导航", "Project navigator"))
            Text(canvasTitle).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            if session.canReturnFromCrossProbe {
                Button { returnFromCrossProbe() } label: { Image(systemName: "arrow.uturn.backward.circle").frame(width:44,height:44).contentShape(Rectangle()) }
                    .accessibilityLabel(edText("返回定位前的位置", "Return to previous location"))
                    .accessibilityIdentifier("electronics.crossProbe.return").disabled(locatingComponent)
            }
            if tab == .schematic || tab == .board {
                Button { beginCrossProbe() } label: { Image(systemName: "arrow.left.arrow.right.square").frame(width:44,height:44).contentShape(Rectangle()) }
                    .accessibilityLabel(tab == .schematic ? edText("在 PCB 中定位", "Select on PCB") : edText("在原理图中定位", "Select on schematic"))
                    .help(tab == .schematic ? edText("在 PCB 中定位", "Select on PCB") : edText("在原理图中定位", "Select on schematic"))
                    .accessibilityIdentifier("electronics.crossProbe.locate")
                    .disabled(locatingComponent || session.busy || session.isClosed || session.selection.context != context || !EDACrossProbe.isComponentSelection(session.project, selection: session.selection))
            }
            Button(action: showProperties) { Image(systemName: "slider.horizontal.3").frame(width:44,height:44).contentShape(Rectangle()) }
                .accessibilityLabel(edText("所选对象属性", "Selection properties"))
                .disabled(session.selection.objectIDs.isEmpty)
                .accessibilityIdentifier("electronics.selectionProperties")
            Menu {
                Toggle(edText("显示网格", "Show grid"), isOn: $showGrid)
                Toggle(edText("吸附网格", "Snap to grid"), isOn: $session.snapToGrid)
                Menu(edText("网格间距", "Grid spacing")) {
                    ForEach([0.1, 0.25, 0.5, 1.0, 1.27, 2.54], id: \.self) { step in
                        Button { session.gridSizeMillimetres = step } label: {
                            if session.gridSizeMillimetres == step { Label(String(format: "%g mm", step), systemImage: "checkmark") }
                            else { Text(String(format: "%g mm", step)) }
                        }
                    }
                }
                if tab == .board {
                    Divider()
                    Button(edText("PCB 设置", "Board setup"), systemImage: "gearshape") { panel = .boardSettings }
                    Button(edText("从原理图更新 PCB", "Update PCB from schematic"), systemImage: "arrow.triangle.2.circlepath") { updateBoard() }
                    Button(edText("重填铜区", "Refill copper zones"), systemImage: "square.dashed.inset.filled") { refillBoard() }
                        .disabled(session.busy || session.isFilling)
                }
                if tab == .schematic || tab == .board {
                    Button(edText("从 PCB 更新原理图", "Update schematic from PCB"), systemImage: "arrow.triangle.2.circlepath") {
                        showingBackAnnotation = true
                    }
                    .disabled(currentBoard == nil || session.busy || session.isClosed || session.isRouting || session.isFilling)
                    .accessibilityIdentifier("electronics.backAnnotation.open")
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(edText("画布选项", "Canvas options"))
        }.padding(.horizontal, 4)
    }
    private var toolRail: some View {
        VStack(spacing: 2) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    if tab == .schematic || tab == .board {
                        ForEach(tab == .board ? EDCanvasTool.boardTools : EDCanvasTool.schematicTools) { item in
                            railButton(title: item.title(on: tab), image: item.image, selected: tool == item, id: item.rawValue) {
                                if item == .place { panel = .parts } else { tool = item }
                            }
                        }
                    } else {
                        ForEach(tab == .symbols ? EDLibraryTool.symbolTools : EDLibraryTool.footprintTools) { item in
                            railButton(title: item.title, image: item.image, selected: libraryTool == item, id: item.rawValue) { libraryTool = item }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
            Divider().padding(.horizontal, 6)
            railButton(title: edText("手指绘图", "Finger drawing"), image: "hand.draw", selected: session.fingerDrawingEnabled, id: "fingerDrawing") { session.fingerDrawingEnabled.toggle() }
        }.padding(.vertical, 4).frame(width: 52).background(.bar)
    }
    private func railButton(title: String, image: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).font(.system(size: 18)).frame(width: 44, height: 44)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("electronics.tool." + id)
    }
    @ViewBuilder private var toolOptions: some View {
        if tab == .schematic || tab == .board {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { optionControls; Spacer(minLength: 0) }
                ScrollView(.horizontal) { HStack(spacing: 8) { optionControls } }.scrollIndicators(.hidden)
            }.padding(.horizontal, 10).frame(minHeight: 44).background(.bar)
        } else if libraryTool == .arc {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { arcControls; Spacer(minLength: 0) }
                ScrollView(.horizontal) { HStack(spacing: 8) { arcControls } }.scrollIndicators(.hidden)
            }.padding(.horizontal, 10).frame(minHeight: 44).background(.bar)
        }
    }
    @ViewBuilder private var arcControls: some View {
        Button { arcClockwise.toggle() } label: {
            Label(arcClockwise ? edText("顺时针", "Clockwise") : edText("逆时针", "Counterclockwise"), systemImage: arcClockwise ? "arrow.clockwise" : "arrow.counterclockwise")
        }.frame(minHeight: 44).accessibilityIdentifier("electronics.arc.direction")
        TextField(edText("线宽（毫米）", "Stroke width in millimetres"), value: $graphicStroke, format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 64).accessibilityIdentifier("electronics.arc.width")
        Text("mm").font(.caption).foregroundStyle(.secondary)
        if tab == .footprints {
            Picker(edText("图层", "Layer"), selection: $graphicLayerID) {
                ForEach(EDAGraphicLayers.standardAssignments, id: \.layerID) { Text($0.layerID).tag($0.layerID) }
            }.fixedSize().accessibilityIdentifier("electronics.arc.layer")
        }
    }
    @ViewBuilder private var optionControls: some View {
        if tool == .place {
            Button { panel = .parts } label: { Label(partName, systemImage: "plus.square").lineLimit(1) }
            Button { placementAngle = (placementAngle + 90).truncatingRemainder(dividingBy: 360) } label: { Image(systemName: "rotate.right") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel(edText("旋转 90°", "Rotate 90°"))
            Button { placementFlipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel(tab == .board ? edText("翻到另一面", "Flip board side") : edText("镜像", "Mirror"))
            if tab == .board { Text(placementFlipped ? "B.Cu" : "F.Cu").font(.caption).foregroundStyle(.secondary) }
        } else if tool == .label {
            TextField(edText("网络名称", "Net name"), text: $labelName).textFieldStyle(.roundedBorder).frame(width: 150)
        } else if tool == .hole {
            Text(edText("孔径", "Diameter")).font(.caption)
            TextField("mm", value: $holeDiameter, format: .number).textFieldStyle(.roundedBorder).frame(width: 64).accessibilityLabel(edText("孔径（毫米）", "Hole diameter in millimetres"))
            Text("mm").font(.caption).foregroundStyle(.secondary)
        } else { Text(tool.title(on: tab)).font(.subheadline) }
        if tab == .board && [.wire, .via, .zone].contains(tool) {
            Picker(edText("铜层", "Copper layer"), selection: $activeLayer) {
                ForEach(currentBoard?.layers.filter { $0.kind == .copper } ?? [], id: \.id) { Text($0.id).tag($0.id) }
            }.fixedSize()
            if tool == .wire {
                TextField(edText("线宽（毫米）", "Track width in millimetres"), value: $wireWidth, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Text("mm").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(edText("网络", "Net"), selection: $netID) {
                    Text(edText("未连接", "Unconnected")).tag("")
                    ForEach((try? session.netlist().nets) ?? []) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 210)
            }
        }
    }
    private var status: some View {
        HStack(spacing: 6) {
            Text(session.busy || session.isCommittingCopperFill ? edText("正在保存…", "Saving…") : session.isFilling ? edText("正在重填铜区…", "Refilling copper zones…") : session.isRouting ? edText("正在布线…", "Routing…") : session.isDirty ? edText("有未保存的修改", "Unsaved changes") : edText("已保存", "Saved"))
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.isFilling { Button(edText("停止", "Stop")) { session.cancelFilling() }.disabled(!session.canCancelFilling) }
            else if session.isRouting { Button(edText("停止", "Stop")) { session.cancelRouting() } }
            Text(String(format: "%g mm", session.gridSizeMillimetres))
            if session.busy || session.isRouting || session.isFilling { ProgressView().controlSize(.small) }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
    }
    private func showProperties() {
        if compactPanels { panel = .properties } else { inspectorVisible.toggle() }
    }
    @ViewBuilder private func panelContent(_ item: EDWorkbenchPanel) -> some View {
        switch item {
        case .navigator: navigator
        case .parts:
            EDPartChooser(project: session.project, footprints: tab == .board) { id in
                if tab == .board { footprintID = id } else { symbolID = id }
                tool = .place; placementAngle = 0; placementFlipped = false; panel = nil
            }
        case .properties: EDAInspector(session: session, context: context)
        case .boardSettings:
            if let board = currentBoard { EDBoardProperties(session: session, value: board).id(board.id) }
        }
    }
    private var navigator: some View {
        EDProjectNavigator(session: session, tab: tab, sheetID: $sheetID, boardID: $boardID, symbolID: $symbolID, footprintID: $footprintID) { panel = nil }
    }
    private func beginCrossProbe() {
        do {
            let request = try session.makeCrossProbeRequest()
            if request.resolution.targets.count == 1 { locate(request) }
            else { crossProbeRequest = request }
        } catch { crossProbeFailed(error) }
    }
    private func locate(_ request: EDACrossProbeRequest, targetID: String? = nil) {
        locatingComponent = true
        crossProbeTask = Task { @MainActor in
            defer { locatingComponent = false; crossProbeTask = nil }
            do { try await session.crossProbe(request, targetID: targetID); crossProbeRequest = nil }
            catch { crossProbeRequest = nil; crossProbeFailed(error) }
        }
    }
    private func returnFromCrossProbe() {
        locatingComponent = true
        crossProbeTask = Task { @MainActor in
            defer { locatingComponent = false; crossProbeTask = nil }
            do { try await session.returnFromCrossProbe() }
            catch { crossProbeFailed(error) }
        }
    }
    private func crossProbeFailed(_ error: any Error) {
        if error is CancellationError || (error as? EDAError) == .cancelled { return }
        crossProbeMessage = (error as? EDACrossProbeError)?.message ?? edText("无法定位，请检查工程是否仍打开且原件未改变。", "Could not locate the component. Check that the project is still open and the original has not changed.")
        showCrossProbeMessage = true
    }
    private func updateBoard() {
        guard let id = currentBoard?.id else { return }
        Task { do { try await session.forwardAnnotation(boardID: id) } catch { session.report(error) } }
    }
    private func refillBoard() {
        guard let id = currentBoard?.id else { return }; let revision = session.revision
        Task { do { try await session.refillCopper(boardID: id, expectedRevision: revision) } catch { session.report(error, operation: "refillCopper") } }
    }
}

private extension View {
    @ViewBuilder func edInlineNavigationTitle()->some View{
#if canImport(UIKit)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}
