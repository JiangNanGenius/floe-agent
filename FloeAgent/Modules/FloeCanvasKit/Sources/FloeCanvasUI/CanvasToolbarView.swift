#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore
import FloeCanvasLayout

/// One native top toolbar. At 390pt secondary controls collapse into menus;
/// primary hit targets never shrink below 44pt (UI_BRIEF).
public struct CanvasToolbarView: View {
    @ObservedObject var store: CanvasEditorStore
    @Binding var showsNewSceneSheet: Bool
    var isNarrow: Bool

    private var strings: CanvasStrings { store.strings }

    public var body: some View {
        Group {
            if isNarrow {
                compactToolbar
            } else {
                ViewThatFits(in: .horizontal) {
                    expandedToolbar.fixedSize(horizontal: true, vertical: false)
                    compactToolbar
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.topToolbar.identifier)
    }

    private var newButton: some View {
        Button { showsNewSceneSheet = true } label: {
            Label(strings[.toolbarNew], systemImage: "doc.badge.plus")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonNew.identifier)
        .disabled(store.isMutating)
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    private var expandedToolbar: some View {
        HStack(spacing: 10) {
            newButton
            insertMenu.disabled(store.isMutating)
            toolPicker
            undoRedoGroup.labelStyle(.iconOnly).disabled(store.isMutating)
            arrangementMenu.labelStyle(.iconOnly).disabled(store.isMutating)
            searchAndFit.labelStyle(.iconOnly)
            flowControls
            labMenu
            panelButtons.labelStyle(.iconOnly)
        }
    }

    /// Six primary controls fit the 390pt host. Secondary actions remain
    /// native menu items, with their existing identities and shortcuts.
    private var compactToolbar: some View {
        HStack(spacing: 8) {
            newButton
            insertMenu.disabled(store.isMutating)
            Menu {
                Picker(strings[.toolSelect], selection: $store.tool) {
                    ForEach(CanvasEditingTool.allCases, id: \.self) { tool in
                        Label(toolLabel(tool), systemImage: toolIcon(tool)).tag(tool)
                    }
                }
            } label: {
                Label(toolLabel(store.tool), systemImage: toolIcon(store.tool))
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarToolPicker.identifier)
            Button { Task { await store.undo() } } label: {
                Label(strings[.toolbarUndo], systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!store.canUndo || store.isMutating)
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonUndo.identifier)
            Spacer(minLength: 0)
            if store.activeFlowGraph != nil {
                Button { Task { await store.startFlowRun() } } label: {
                    Label(strings[.toolbarRun], systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowRun.identifier)
            }
            Menu {
                panelButtons
                Divider()
                Menu(strings[.toolbarEdit]) { undoRedoGroup }
                    .disabled(store.isMutating)
                    .accessibilityIdentifier("floe.canvas.toolbar.edit")
                arrangementMenu
                    .disabled(store.isMutating)
                Menu(strings[.toolbarNavigate]) { searchAndFit }
                Divider()
                flowControls
                labMenu
            } label: {
                Label(strings[.toolbarMore], systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("floe.canvas.toolbar.more")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var panelButtons: some View {
        Button { withAnimation { store.showsInspector.toggle() } } label: {
            Label(strings[.toolbarInspector], systemImage: "sidebar.right")
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonInspector.identifier)
        Button { withAnimation { store.showsSidebar.toggle() } } label: {
            Label(strings[.toolbarPages], systemImage: "sidebar.left")
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonPages.identifier)
    }

    // MARK: Insert

    private var insertMenu: some View {
        Menu {
            Button(strings[.insertText]) { insert(.text("")) }
            Button(strings[.insertRichText]) { insert(.richText(document: CanvasRichTextDocument())) }
            Button(strings[.insertMarkdown]) { insert(.markdown(document: "", previewText: nil)) }
            Button(strings[.insertTable]) { insert(.table(header: ["", ""], rows: [["", ""]])) }
            Button(strings[.insertFormula]) { insert(.formula(source: "", renderedAssetID: nil)) }
            Button(strings[.insertCode]) { insert(.code(language: nil, source: "")) }
            Menu(strings[.insertShapeRectangle]) {
                Button(strings[.insertShapeRectangle]) { insertShape(.rectangle) }
                Button(strings[.insertShapeRounded]) { insertShape(.roundedRectangle) }
                Button(strings[.insertShapeEllipse]) { insertShape(.ellipse) }
                Button(strings[.insertShapeDiamond]) { insertShape(.diamond) }
                Button(strings[.insertShapeLine]) { insertShape(.line) }
                Button(strings[.insertShapeArrow]) { insertShape(.arrow) }
            }
            Divider()
            Button(strings[.insertFlowStep]) { insertFlowStep() }
        } label: {
            Label(strings[.toolbarInsert], systemImage: "plus.square")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonInsert.identifier)
        .keyboardShortcut("i", modifiers: [.command, .shift])
    }

    // MARK: Tools

    private var toolPicker: some View {
        Picker(strings[.toolSelect], selection: $store.tool) {
            ForEach(CanvasEditingTool.allCases, id: \.self) { tool in
                Label(toolLabel(tool), systemImage: toolIcon(tool))
                    .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: isNarrow ? 200 : 320)
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarToolPicker.identifier)
    }

    // MARK: Edit group

    private var undoRedoGroup: some View {
        Group {
            Button {
                Task { await store.undo() }
            } label: {
                Label(strings[.toolbarUndo], systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonUndo.identifier)
            .keyboardShortcut("z", modifiers: .command)

            Button {
                Task { await store.redo() }
            } label: {
                Label(strings[.toolbarRedo], systemImage: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo)
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonRedo.identifier)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button {
                Task { await store.apply(.duplicateSelection) }
            } label: {
                Label(strings[.toolbarDuplicate], systemImage: "plus.square.on.square")
            }
            .disabled(store.selection.isEmpty)
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonDuplicate.identifier)
            .keyboardShortcut("d", modifiers: .command)

            Button {
                Task { await store.apply(.deleteSelection) }
            } label: {
                Label(strings[.toolbarDelete], systemImage: "trash")
            }
            .disabled(store.selection.isEmpty)
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonDelete.identifier)
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private var arrangementMenu: some View {
        Menu {
            Button(strings[.toolbarGroup]) {
                Task { await store.apply(.groupSelection) }
            }
            .disabled(store.selection.isEmpty)
            Button(strings[.toolbarUngroup]) {
                Task { await store.apply(.ungroupSelection) }
            }
            .disabled(store.selection.isEmpty)
            Divider()
            Button(strings[.toolbarRegion]) {
                Task { await store.apply(.createRegionForSelection(name: nil)) }
            }
            .disabled(store.selection.isEmpty)
            if let region = store.page.regions.first(where: { region in
                store.page.nodes.contains { node in
                    store.selection.contains(node.id) && node.regionID == region.id
                }
            }) {
                Button(strings[region.isCollapsed ? .toolbarExpandRegion : .toolbarCollapseRegion]) {
                    Task { await store.apply(.setRegionCollapsed(region.id, !region.isCollapsed)) }
                }
            }
            Button(strings[.toolbarScene]) {
                Task { await store.apply(.createScene(name: strings[.toolbarScene])) }
            }
            Divider()
            Button(strings[.toolbarArrangeHorizontal]) {
                arrange(.horizontal)
            }
            .disabled(store.selection.count < 2)
            Button(strings[.toolbarArrangeVertical]) {
                arrange(.vertical)
            }
            .disabled(store.selection.count < 2)
        } label: {
            Label(strings[.toolbarArrange], systemImage: "rectangle.3.group")
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonArrange.identifier)
    }

    private var searchAndFit: some View {
        Group {
            Button {
                store.fitToContent()
            } label: {
                Label(strings[.toolbarFit], systemImage: "aspectratio")
            }
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonFit.identifier)
            .keyboardShortcut("0", modifiers: .command)

            Button {
                store.zoomIn()
            } label: {
                Label(strings[.toolbarZoomIn], systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            Button {
                store.zoomOut()
            } label: {
                Label(strings[.toolbarZoomOut], systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }

    // MARK: Flow controls

    /// Page-level flow graph chooser (visible only when the page holds more
    /// than one graph). The active graph is what routing/run/debug act on;
    /// other graphs stay ordinary visible content.
    private var flowGraphChooser: some View {
        Menu {
            ForEach(Array(store.page.flowGraphs.enumerated()), id: \.element.id) { index, graph in
                Button {
                    store.selectFlowGraph(graph.id)
                } label: {
                    Label(
                        store.strings.formatted(.flowGraphEntry, index + 1),
                        systemImage: graph.id == store.activeFlowGraphID
                            ? "checkmark.circle.fill" : "circle")
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowGraphChooser.identifier)
        .help(store.strings[.flowGraphChooser])
    }

    @ViewBuilder
    private var flowControls: some View {
        if store.activeFlowGraph != nil {
            if store.page.flowGraphs.count > 1 {
                flowGraphChooser
            }
            Button {
                Task { await store.startFlowRun() }
            } label: {
                Image(systemName: "play.fill")
            }
            .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowRun.identifier)
            .help(strings[.toolbarRun])

            if let run = store.flowRun, !run.isTerminal {
                Button { store.pauseFlowRun() } label: {
                    Label(strings[.toolbarPause], systemImage: "pause.fill")
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowPause.identifier)
                Button { store.stepFlowRun() } label: {
                    Label(strings[.toolbarStep], systemImage: "forward.frame")
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowStep.identifier)
                Button { store.cancelFlowRun() } label: {
                    Label(strings[.toolbarStop], systemImage: "stop.fill")
                }
                .accessibilityIdentifier(CanvasAccessibilityID.toolbarFlowStop.identifier)
            }
            Button {
                withAnimation { store.showsDebugger.toggle() }
            } label: {
                Label(strings[.inspectorFlowBinding], systemImage: "ant.circle")
            }
            .accessibilityIdentifier(CanvasAccessibilityID.debuggerPanel.identifier)
        }
    }

    // MARK: Lab menu

    private var labMenu: some View {
        Menu(strings[.toolbarLab]) {
            ForEach(labGroups) { group in
                Menu(group.title) {
                    ForEach(store.services.labActions.filter { $0.group?.id == group.id }) { action in
                        Button(action.title) { Task { await store.runLabAction(action) } }
                    }
                }
            }
            ForEach(store.services.labActions.filter { $0.group == nil }) { action in
                Button(action.title) { Task { await store.runLabAction(action) } }
            }
            if store.services.labActions.isEmpty {
                Text(strings[.debuggerEmpty])
            }
        }
        .accessibilityIdentifier(CanvasAccessibilityID.toolbarButtonLab.identifier)
        .help(strings[.toolbarLab])
    }

    private var labGroups: [CanvasLabActionGroup] {
        var seen = Set<String>()
        return store.services.labActions.compactMap { action in
            guard let group = action.group, seen.insert(group.id).inserted else { return nil }
            return group
        }
    }

    // MARK: Actions

    private func insert(_ content: CanvasContent) {
        let center = store.viewport.viewToWorld(.init(
            x: store.viewport.viewSize.width / 2,
            y: store.viewport.viewSize.height / 2))
        Task {
            await store.apply(.insertContent(
                content, title: nil,
                at: .init(x: center.x, y: center.y)))
        }
    }

    private func insertShape(_ kind: CanvasShapeKind) {
        let center = store.viewport.viewToWorld(.init(
            x: store.viewport.viewSize.width / 2,
            y: store.viewport.viewSize.height / 2))
        Task {
            await store.apply(.insertShape(
                kind, text: "",
                at: .init(x: center.x, y: center.y)))
        }
    }

    private func insertFlowStep() {
        let center = store.viewport.viewToWorld(.init(
            x: store.viewport.viewSize.width / 2,
            y: store.viewport.viewSize.height / 2))
        Task {
            await store.apply(.insertFlowStep(
                kind: .transform,
                name: strings[.flowKindTransform],
                at: .init(x: center.x, y: center.y)))
        }
    }

    private func arrange(_ direction: CanvasArrangeDirection) {
        Task {
            do {
                let proposal = try CanvasPartialArrange.proposeArrangement(
                    page: store.page,
                    selection: store.selection,
                    direction: direction)
                let moves = proposal.placements.map { ($0.key, $0.value) }
                guard !moves.isEmpty else { return }
                await store.apply(.moveNodes(moves))
            } catch {
                store.presentAlertFromError(error)
            }
        }
    }

    // MARK: Labels

    private func toolLabel(_ tool: CanvasEditingTool) -> String {
        switch tool {
        case .select: return strings[.toolSelect]
        case .hand: return strings[.toolHand]
        case .pencil: return strings[.toolPencil]
        case .lasso: return strings[.toolLasso]
        case .eraser: return strings[.toolEraser]
        case .connector: return strings[.toolConnector]
        }
    }

    private func toolIcon(_ tool: CanvasEditingTool) -> String {
        switch tool {
        case .select: return "cursorarrow.rays"
        case .hand: return "hand.raised"
        case .pencil: return "pencil"
        case .lasso: return "lasso"
        case .eraser: return "eraser"
        case .connector: return "arrow.triangle.branch"
        }
    }
}
#endif
