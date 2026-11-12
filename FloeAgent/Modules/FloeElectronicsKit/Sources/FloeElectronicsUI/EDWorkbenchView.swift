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
    var image: String {
        switch self {
        case .schematic: return "square.on.circle"
        case .board: return "square.grid.3x3"
        case .symbols: return "function"
        case .footprints: return "square.grid.2x2"
        case .checks: return "checklist"
        case .outputs: return "square.and.arrow.up"
        case .threeD: return "cube"
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
    let onLibraryUpdates: (() -> Void)?
    let onRemoteLibrary: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab = EDWorkspaceTab.schematic
    @State private var panel: EDWorkbenchPanel?
    @State private var inspectorVisible = true
    @State private var navigatorVisible = true
    @State private var inspectorDrafts = EDInspectorDraftStore()
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
    @State private var libraryPlacement: EDALibraryPlacementSelection?
    @State private var replacementPlan: EDALibraryReplacementPlan?
    @State private var pendingReplacement: EDALibraryReplacementPlan?
    @State private var pendingLibraryUpdates = false
    @State private var pendingLibraryChooser = false
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
                onExportPreview: ((EDAExchangeFile, UInt64) -> Void)? = nil, onLibraryUpdates: (() -> Void)? = nil,
                onRemoteLibrary: (() -> Void)? = nil) {
        self.session = session; self.onAssistant = onAssistant; self.onExportPreview = onExportPreview
        self.onLibraryUpdates = onLibraryUpdates; self.onRemoteLibrary = onRemoteLibrary
    }
    private var layout: EDWorkbenchLayout {
        EDWorkbenchLayout(width: viewportWidth, horizontalSizeClass: sizeClass)
    }
    private var showsNavigator: Bool { layout.canShowSideNavigator && navigatorVisible }
    private var showsInspector: Bool { layout.sideInspectorKeepsCanvas(showingNavigator: showsNavigator) && inspectorVisible }
    private var copperLayers: [EDALayer] { currentBoard?.layers.filter { $0.kind == .copper } ?? [] }
    private var currentBoard: EDABoard? { session.project.boards.first { $0.id == boardID } ?? session.project.boards.first }
    private var currentSheet: EDASheet? { session.project.sheets.first { $0.id == sheetID } ?? session.project.sheets.first }
    private var currentSymbol: EDASymbolDefinition? { session.project.symbols.first { $0.id == symbolID } ?? session.project.symbols.first }
    private var currentFootprint: EDAFootprintDefinition? { session.project.footprints.first { $0.id == footprintID } ?? session.project.footprints.first }
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
        case .schematic: currentSheet?.name ?? tab.title
        case .board: currentBoard?.name ?? "PCB"
        case .symbols: currentSymbol?.name ?? tab.title
        case .footprints: currentFootprint?.name ?? tab.title
        default: tab.title
        }
    }
    private var selectedComponentID: UUID? {
        guard session.selection.objectIDs.count == 1, let object = session.selection.objectIDs.first else { return nil }
        switch session.selection.context {
        case .schematic(let id): return session.project.sheets.first { $0.id == id }?.symbols.first { $0.id == object }?.componentID
        case .board(let id): return session.project.boards.first { $0.id == id }?.footprints.first { $0.id == object }?.componentID
        default: return nil
        }
    }
    private var partName: String {
        if let libraryPlacement { return libraryPlacement.snapshot.part.name }
        if tab == .board { return currentFootprint?.name ?? edText("选择封装", "Choose footprint") }
        return currentSymbol?.name ?? edText("选择元件", "Choose part")
    }

    private var editorSubtitle: String {
        switch tab {
        case .board:
            let copper = copperLayers.count
            return edText("PCB", "PCB") + " · " + String(copper) + edText(" 个铜层", copper == 1 ? " copper layer" : " copper layers")
        case .schematic:
            let count = currentSheet?.symbols.count ?? 0
            return edText("原理图", "Schematic") + " · " + String(count) + edText(" 个元件", count == 1 ? " part" : " parts")
        case .symbols:
            let pins = currentSymbol?.pins.count ?? 0
            return edText("符号库", "Symbols") + " · " + String(pins) + edText(" 个引脚", pins == 1 ? " pin" : " pins")
        case .footprints:
            let pads = currentFootprint?.pads.count ?? 0
            return edText("封装库", "Footprints") + " · " + String(pads) + edText(" 个焊盘", pads == 1 ? " pad" : " pads")
        default: return tab.title
        }
    }
    private var selectionSummary: String? {
        guard let context, session.selection.context == context, !session.selection.objectIDs.isEmpty else { return nil }
        if session.selection.objectIDs.count > 1 {
            return String(session.selection.objectIDs.count) + edText(" 个对象", " selected")
        }
        guard let object = session.selection.objectIDs.first else { return nil }
        switch context {
        case .board(let id):
            guard let board = session.project.boards.first(where: { $0.id == id }) else { return edText("布线", "Board") }
            if let value = board.footprints.first(where: { $0.id == object }) {
                return value.reference.isEmpty ? edText("封装", "Footprint") : value.reference
            }
            if board.tracks.contains(where: { $0.id == object }) { return edText("走线", "Track") }
            if board.vias.contains(where: { $0.id == object }) { return edText("过孔", "Via") }
            if board.holes.contains(where: { $0.id == object }) { return edText("孔", "Hole") }
            if board.zones.contains(where: { $0.id == object }) { return edText("铜区", "Copper zone") }
            return edText("PCB 对象", "Board object")
        case .schematic(let id):
            guard let sheet = session.project.sheets.first(where: { $0.id == id }) else { return edText("图页", "Sheet") }
            if let placement = sheet.symbols.first(where: { $0.id == object }),
               let component = session.project.components.first(where: { $0.id == placement.componentID }) {
                return component.reference.isEmpty ? edText("元件", "Component") : component.reference
            }
            if sheet.buses.contains(where: { $0.id == object }) { return edText("总线", "Bus") }
            if sheet.buses.contains(where: { ($0.entries ?? []).contains { $0.id == object } }) { return edText("总线引出", "Bus entry") }
            if sheet.wires.contains(where: { $0.id == object }) { return edText("导线", "Wire") }
            if sheet.labels.contains(where: { $0.id == object }) { return edText("网络标签", "Net label") }
            return edText("原理图对象", "Schematic object")
        case .symbol(let id):
            return session.project.symbols.first(where: { $0.id == id })?.name ?? edText("符号", "Symbol")
        case .footprint(let id):
            return session.project.footprints.first(where: { $0.id == id })?.name ?? edText("封装", "Footprint")
        }
    }
    private var canLocateCrossProbe: Bool {
        !locatingComponent && !session.busy && !session.isClosed
            && session.selection.context == context
            && EDACrossProbe.isComponentSelection(session.project, selection: session.selection)
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
            EDWorkbenchStatusBar(session: session, tab: tab, activeLayer: activeLayer,
                                 selectionSummary: selectionSummary, compact: layout.isCompact)
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
        .sheet(item: $panel, onDismiss: {
            if let pending = pendingReplacement, !session.isClosed, pending.projectID == session.project.id, pending.sourceRevision == session.revision { replacementPlan = pending }
            pendingReplacement = nil
            if pendingLibraryUpdates { pendingLibraryUpdates = false; onLibraryUpdates?() }
            if pendingLibraryChooser { pendingLibraryChooser = false; panel = .parts }
        }) { item in
            NavigationStack {
                panelContent(item)
                    .navigationTitle(item == .parts ? edText("放置元件", "Place part")
                                     : item == .navigator ? edText("项目", "Project")
                                     : item == .boardSettings ? edText("PCB 设置", "Board setup")
                                     : edText("属性", "Properties"))
                    .edInlineNavigationTitle()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(item == .properties || item == .boardSettings ? edText("关闭", "Close") : edText("完成", "Done")) { panel = nil } } }
            }
            // The compact properties sheet and the inline side panel resolve
            // unapplied drafts from this same workbench-scoped store.
            .environment(\.edInspectorDraftStore, inspectorDrafts)
            .presentationDetents(item == .parts ? [.large] : [.medium, .large])
            .presentationBackground(.background)
        }
        .sheet(isPresented: Binding(get: { replacementPlan != nil }, set: { if !$0 { replacementPlan = nil } })) {
            if let plan = replacementPlan {
                EDLibraryReplacementReview(plan: plan) { accepted in
                    Task { do { try await session.replaceLibrary(plan, acceptedDifferences: accepted) } catch { session.report(error) } }
                }
            }
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
            tool = .select; libraryTool = .select; libraryPlacement = nil; placementAngle = 0; placementFlipped = false
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
        .onChange(of: currentBoard?.id, initial: true) { _, _ in normalizeActiveLayer() }
        .onChange(of: session.project.id) { _, _ in inspectorDrafts.removeAll() }
        .onChange(of: session.isClosed) { _, closed in if closed { inspectorDrafts.removeAll() } }
    }

    private var workspaceTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(EDWorkspaceTab.allCases) { item in
                    let selected = tab == item
                    Button { tab = item } label: {
                        Label(item.title, systemImage: item.image)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("electronics.tab." + item.rawValue)
                }
            }.padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
    @ViewBuilder private var workspace: some View {
        switch tab {
        case .checks:
            EDAChecksView(session: session, onFocus: { session.requestFocus($0) })
        case .outputs:
            EDAOutputsView(session: session, onExportPreview: onExportPreview)
        case .threeD:
            EDABoard3DView(project: session.project, boardID: currentBoard?.id,
                          renderer: session.board3DRenderer, modelLoader: session.board3DModelLoader)
        default:
            VStack(spacing: 0) {
                editorHeader
                Divider()
                if layout.isCompact {
                    EDToolStrip(tab: tab, tool: tool, libraryTool: libraryTool,
                                fingerDrawingEnabled: session.fingerDrawingEnabled,
                                onTool: { tool = $0 }, onPlace: { panel = .parts },
                                onLibraryTool: { libraryTool = $0 },
                                onToggleFingerDrawing: { session.fingerDrawingEnabled.toggle() })
                    Divider()
                }
                contextBar
                Divider()
                HStack(spacing: 0) {
                    if showsNavigator {
                        navigator.frame(width: EDWorkbenchLayout.navigatorWidth)
                        Divider()
                    }
                    if !layout.isCompact {
                        EDToolRail(tab: tab, tool: tool, libraryTool: libraryTool,
                                   fingerDrawingEnabled: session.fingerDrawingEnabled,
                                   onTool: { tool = $0 }, onPlace: { panel = .parts },
                                   onLibraryTool: { libraryTool = $0 },
                                   onToggleFingerDrawing: { session.fingerDrawingEnabled.toggle() })
                        Divider()
                    }
                    canvasArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsInspector {
                        Divider()
                        EDAInspector(session: session, context: context,
                                     onReplaceLibrary: libraryReplacementAction,
                                     activeLayer: $activeLayer,
                                     onBoardSetup: { panel = .boardSettings },
                                     onUpdateBoard: updateBoard,
                                     onRefillCopper: refillBoard)
                            // Same scoped store as the compact properties sheet.
                            .environment(\.edInspectorDraftStore, inspectorDrafts)
                            .frame(width: EDWorkbenchLayout.inspectorWidth)
                    }
                }
            }
        }
    }
    @ViewBuilder private var canvasArea: some View {
        if let context {
            EDCanvasEditor(session: session, context: context, mode: mode,
                           symbolID: symbolID, footprintID: footprintID, labelName: labelName,
                           layer: activeLayer, width: wireWidth, netID: netID, holeDiameter: holeDiameter,
                           showGrid: showGrid, placementAngle: $placementAngle, placementFlipped: $placementFlipped,
                           onCancel: { tool = .select; libraryTool = .select }, onProperties: showProperties,
                           onWireToolRequested: { tool = .wire }, graphicStroke: graphicStroke,
                           graphicLayer: tab == .footprints ? EDAGraphicLayers.standardAssignments.first { $0.layerID == graphicLayerID } : nil,
                           arcClockwise: arcClockwise, libraryPlacement: libraryPlacement,
                           compactLayout: layout.isCompact)
        } else {
            ContentUnavailableView(edText("选择图页或库项目", "Select a sheet or library item"), systemImage: "square.dashed")
        }
    }
    private var editorHeader: some View {
        HStack(spacing: 2) {
            Button {
                if layout.canShowSideNavigator { navigatorVisible.toggle() } else { panel = .navigator }
            } label: {
                Image(systemName: "sidebar.left").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(showsNavigator ? Color.accentColor : Color.primary)
            .accessibilityLabel(edText("项目导航", "Project navigator"))
            .accessibilityValue(showsNavigator ? edText("已显示", "Shown") : "")
            .accessibilityIdentifier("electronics.navigator")
            VStack(alignment: .leading, spacing: 0) {
                Text(canvasTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(editorSubtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !layout.isCompact {
                if session.canReturnFromCrossProbe {
                    Button { returnFromCrossProbe() } label: { Image(systemName: "arrow.uturn.backward.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel(edText("返回定位前的位置", "Return to previous location"))
                        .accessibilityIdentifier("electronics.crossProbe.return")
                        .disabled(locatingComponent)
                }
                if tab == .schematic || tab == .board {
                    Button { beginCrossProbe() } label: { Image(systemName: "arrow.left.arrow.right.square").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel(tab == .schematic ? edText("在 PCB 中定位", "Select on PCB") : edText("在原理图中定位", "Select on schematic"))
                        .help(tab == .schematic ? edText("在 PCB 中定位", "Select on PCB") : edText("在原理图中定位", "Select on schematic"))
                        .accessibilityIdentifier("electronics.crossProbe.locate")
                        .disabled(!canLocateCrossProbe)
                }
            }
            libraryMenu
            propertiesButton
            optionsMenu
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .background(.bar)
        .accessibilityIdentifier("electronics.editorHeader")
    }
    private var libraryMenu: some View {
        Menu {
            Button(edText("放置元件…", "Place part…"), systemImage: "plus.square") { panel = .parts }
            if let onRemoteLibrary {
                Button(edText("在线元件库", "Online library"), systemImage: "globe") { onRemoteLibrary() }
                    .accessibilityIdentifier("electronics.library.online")
            }
            if let onLibraryUpdates {
                Divider()
                Button(edText("内容更新…", "Library updates…"), systemImage: "arrow.triangle.2.circlepath") { onLibraryUpdates() }
                    .accessibilityIdentifier("electronics.library.updates")
            }
        } label: {
            Image(systemName: "books.vertical").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(edText("元件库", "Library"))
        .accessibilityIdentifier("electronics.library.menu")
    }
    private var propertiesButton: some View {
        Button(action: showProperties) {
            Image(systemName: showsInspector ? "sidebar.right" : "slider.horizontal.3")
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .foregroundStyle(showsInspector ? Color.accentColor : Color.primary)
        .accessibilityLabel(edText("属性检查器", "Properties inspector"))
        .accessibilityValue(showsInspector ? edText("已显示", "Shown") : "")
        .accessibilityAddTraits(showsInspector ? .isSelected : [])
        .accessibilityIdentifier("electronics.selectionProperties")
    }
    private var optionsMenu: some View {
        Menu {
            Toggle(edText("显示网格", "Show grid"), isOn: $showGrid)
            Toggle(edText("吸附网格", "Snap to grid"), isOn: $session.snapToGrid)
            Toggle(edText("手指绘图", "Finger drawing"), isOn: $session.fingerDrawingEnabled)
            Menu(edText("网格间距", "Grid spacing")) {
                ForEach([0.1, 0.25, 0.5, 1.0, 1.27, 2.54], id: \.self) { step in
                    Button { session.gridSizeMillimetres = step } label: {
                        if session.gridSizeMillimetres == step { Label(String(format: "%g mm", step), systemImage: "checkmark") }
                        else { Text(String(format: "%g mm", step)) }
                    }
                }
            }
            if layout.isCompact {
                Divider()
                if session.canReturnFromCrossProbe {
                    Button(edText("返回定位前的位置", "Return to previous location"), systemImage: "arrow.uturn.backward.circle") { returnFromCrossProbe() }
                        .disabled(locatingComponent)
                }
                if tab == .schematic || tab == .board {
                    Button(tab == .schematic ? edText("在 PCB 中定位", "Select on PCB") : edText("在原理图中定位", "Select on schematic"),
                           systemImage: "arrow.left.arrow.right.square") { beginCrossProbe() }
                        .disabled(!canLocateCrossProbe)
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
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(edText("画布选项", "Canvas options"))
        .accessibilityIdentifier("electronics.options")
    }
    @ViewBuilder private var contextBar: some View {
        if tab == .schematic || tab == .board || tab == .symbols || tab == .footprints {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { contextControls; Spacer(minLength: 0) }
                ScrollView(.horizontal) { HStack(spacing: 8) { contextControls } }.scrollIndicators(.hidden)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("electronics.contextBar")
        }
    }
    @ViewBuilder private var contextControls: some View {
        if tab == .schematic || tab == .board {
            if tab == .board, !copperLayers.isEmpty {
                EDCopperLayerStrip(layers: copperLayers, selection: $activeLayer)
                Rectangle().fill(.quaternary).frame(width: 1, height: 24).padding(.horizontal, 2)
            }
            optionControls
        } else {
            libraryControls
        }
    }
    @ViewBuilder private var optionControls: some View {
        if tool == .place {
            Button { panel = .parts } label: { Label(partName, systemImage: "plus.square").lineLimit(1) }
                .frame(minHeight: 44)
            Button { placementAngle = (placementAngle + 90).truncatingRemainder(dividingBy: 360) } label: { Image(systemName: "rotate.right") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel(edText("旋转 90°", "Rotate 90°"))
            Button { placementFlipped.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel(tab == .board ? edText("翻到另一面", "Flip board side") : edText("镜像", "Mirror"))
            if tab == .board { Text(placementFlipped ? "B.Cu" : "F.Cu").font(.caption).foregroundStyle(.secondary) }
        } else if tool == .label {
            TextField(edText("网络名称", "Net name"), text: $labelName)
                .textFieldStyle(.roundedBorder).frame(width: 150).frame(minHeight: 36)
                .accessibilityIdentifier("electronics.label.name")
        } else if tool == .hole {
            Text(edText("孔径", "Diameter")).font(.caption)
            TextField("mm", value: $holeDiameter, format: .number).textFieldStyle(.roundedBorder)
                .frame(width: 64).frame(minHeight: 36)
                .accessibilityLabel(edText("孔径（毫米）", "Hole diameter in millimetres"))
            Text("mm").font(.caption).foregroundStyle(.secondary)
        } else if tab == .board, tool == .wire {
            EDTrackWidthControl(width: $wireWidth)
        } else if tab == .board, tool == .via || tool == .zone {
            netPicker
        } else if tool == .select {
            Text(edText("选择对象以编辑属性", "Select an object to edit properties"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text(tool.title(on: tab)).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var netPicker: some View {
        Picker(edText("网络", "Net"), selection: $netID) {
            Text(edText("未连接", "Unconnected")).tag("")
            ForEach((try? session.netlist().nets) ?? []) { Text($0.name).tag($0.id) }
        }
        .fixedSize()
        .frame(maxWidth: 230)
        .accessibilityIdentifier("electronics.net")
    }
    @ViewBuilder private var libraryControls: some View {
        if libraryTool == .arc {
            Button { arcClockwise.toggle() } label: {
                Label(arcClockwise ? edText("顺时针", "Clockwise") : edText("逆时针", "Counterclockwise"),
                      systemImage: arcClockwise ? "arrow.clockwise" : "arrow.counterclockwise")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("electronics.arc.direction")
        }
        if [EDLibraryTool.line, .rectangle, .circle, .arc].contains(libraryTool) {
            TextField(edText("线宽（毫米）", "Stroke width in millimetres"), value: $graphicStroke, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 64).frame(minHeight: 36)
                .accessibilityIdentifier(libraryTool == .arc ? "electronics.arc.width" : "electronics.graphic.width")
            Text("mm").font(.caption).foregroundStyle(.secondary)
            if tab == .footprints {
                Picker(edText("图层", "Layer"), selection: $graphicLayerID) {
                    ForEach(EDAGraphicLayers.standardAssignments, id: \.layerID) { Text($0.layerID).tag($0.layerID) }
                }
                .fixedSize()
                .accessibilityIdentifier(libraryTool == .arc ? "electronics.arc.layer" : "electronics.graphic.layer")
            }
        } else {
            Text(libraryTool.title).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private func normalizeActiveLayer() {
        guard let first = copperLayers.first else { return }
        if !copperLayers.contains(where: { $0.id == activeLayer }) { activeLayer = first.id }
    }
    private func showLibraryReplacement() {
        guard selectedComponentID != nil else { return }
        if panel != nil { pendingLibraryChooser = true; panel = nil } else { panel = .parts }
    }
    private var libraryReplacementAction: (() -> Void)? {
        guard session.library != nil else { return nil }
        return { showLibraryReplacement() }
    }
    private func showProperties() {
        if layout.isCompact { panel = .properties } else { inspectorVisible.toggle() }
    }
    @ViewBuilder private func panelContent(_ item: EDWorkbenchPanel) -> some View {
        switch item {
        case .navigator: navigator
        case .parts:
            EDPartChooser(project: session.project, footprints: tab == .board, library: session.library, choose: { id in
                libraryPlacement = nil
                if tab == .board { footprintID = id } else { symbolID = id }
                tool = .place; placementAngle = 0; placementFlipped = false; panel = nil
            }, chooseLibrary: { choice in
                libraryPlacement = choice
                tool = .place; placementAngle = 0; placementFlipped = false; panel = nil
            }, replaceLibrary: selectedComponentID.map { component in { snapshot in
                do { pendingReplacement = try EDALibraryProject.planReplacement(snapshot, componentID: component, project: session.project); panel = nil }
                catch { session.report(error) }
            } }, onUpdates: onLibraryUpdates.map { _ in { pendingLibraryUpdates = true; panel = nil } })
        case .properties:
            EDAInspector(session: session, context: context, onReplaceLibrary: libraryReplacementAction,
                         activeLayer: $activeLayer,
                         onBoardSetup: { panel = .boardSettings },
                         onUpdateBoard: updateBoard,
                         onRefillCopper: refillBoard)
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
