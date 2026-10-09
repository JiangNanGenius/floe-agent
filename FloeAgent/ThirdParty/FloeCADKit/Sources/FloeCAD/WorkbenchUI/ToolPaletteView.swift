//
//  ToolPaletteView.swift
//  openshape3d
//
//  Floating left tool palette, Shapr3D style. Context-sensitive: sketch tools
//  show only while sketching, body/3D tools only otherwise. Tools are described
//  as `ToolItem`s; related ones collapse into `ToolGroup`s that expand into a
//  floating flyout row of icon buttons beside the palette.
//

import SwiftUI

// MARK: - Palette model (view-layer only; values captured at build time)

private enum ToolMenu { case constrain, dimension, insert, mirror }

private struct ToolItem: Identifiable {
    let id: String
    let label: String
    let icon: String
    var enabled: Bool = true
    var active: Bool = false
    var activeTint: Color = .blue
    /// Explicit accessibility identifier; nil = rely on the visible label text.
    var accessibilityID: String? = nil
    var run: () -> Void = {}
    var menu: ToolMenu? = nil
}

private struct ToolGroup: Identifiable {
    let id: String
    let label: String
    let icon: String
    let items: [ToolItem]
}

/// One palette row: a standalone tool, or a group that opens a flyout.
private enum PaletteEntry: Identifiable {
    case item(ToolItem)
    case group(ToolGroup)
    var id: String {
        switch self {
        case .item(let i): return "i_" + i.id
        case .group(let g): return "g_" + g.id
        }
    }
}

/// Records each group button's frame (in the palette coordinate space) so the
/// flyout can be positioned beside the tapped group.
private struct GroupFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ToolPaletteView: View {
    @Bindable var viewModel: EditorViewModel

    private var paletteOnRight: Bool { CADPreferences.shared.paletteOnRight }

    @State private var expandedGroupID: String?
    @State private var groupFrames: [String: CGRect] = [:]

    var body: some View {
        ViewThatFits(in: .vertical) {
            paletteColumn(spacing: 12, verticalPadding: 16)
            // Compact height (an iPhone in portrait under the extrude bar):
            // a tighter column keeps every entry on screen — with the wide
            // spacing the last one, Delete, scrolled off and was untappable.
            paletteColumn(spacing: 6, verticalPadding: 10)
            // The identifier lives on the scroll view only: on the plain
            // column it would make the VStack one accessibility element and
            // hide every tool button from the UI tests.
            ScrollView(.vertical, showsIndicators: false) {
                paletteColumn(spacing: 12, verticalPadding: 16)
            }
            .accessibilityIdentifier("ToolPalette")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .coordinateSpace(name: "palette")
        .onPreferenceChange(GroupFrameKey.self) { groupFrames = $0 }
        .overlay(alignment: paletteOnRight ? .topTrailing : .topLeading) { flyoutOverlay }
        // A context flip (enter/leave sketch) closes any open flyout.
        .onChange(of: viewModel.mode.isSketching) { _, _ in expandedGroupID = nil }
    }

    private func paletteColumn(spacing: CGFloat, verticalPadding: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(entries) { entry in
                switch entry {
                case .item(let item): toolView(item)
                case .group(let group): groupButton(group)
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 10)
    }

    // MARK: - Entries by context

    private var entries: [PaletteEntry] {
        viewModel.mode.isSketching ? sketchEntries : bodyEntries
    }

    private var bodyEntries: [PaletteEntry] {
        [.group(sketchGroup), .group(modifyGroup), .group(transformGroup), .group(combineGroup),
         .item(axisItem), .item(measureItem), .item(materialItem),
         .item(selectItem), .item(deleteItem)]
    }

    private var sketchEntries: [PaletteEntry] {
        drawItems.map(PaletteEntry.item)
        // Offset Edge sits with the sketch tools, matching the manual's order
        // (…Polygon, Offset Edge, …). Sketch-only: there is nothing to offset
        // from outside a sketch, so it is absent from the body-mode group.
        + [.item(sketchTool("cad.ui.tool.offset", "Offset", "square.on.square.dashed", .offset)),
           .item(sketchTool("cad.ui.tool.trim", "Trim", "scissors", .trim)),
           .item(sketchTool("cad.ui.tool.project", "Project", "square.on.square.dashed", .project)),
           .group(constrainGroup),
           .group(symbolGroup),
           .item(constructItem),
           .item(deleteItem)]
    }

    private var currentGroups: [ToolGroup] {
        entries.compactMap { if case .group(let g) = $0 { return g }; return nil }
    }

    // MARK: - Groups

    private var sketchGroup: ToolGroup {
        ToolGroup(id: "Sketch", label: FloeCADStrings.text("cad.ui.tool.sketch", "Sketch"),
                  icon: "pencil.line", items: drawItems + [
            sketchTool("cad.ui.tool.project", "Project", "square.on.square.dashed", .project),
        ])
    }

    private var modifyGroup: ToolGroup {
        ToolGroup(id: "Modify", label: FloeCADStrings.text("cad.ui.tool.modify", "Modify"),
                  icon: "cube", items: [
            modifyItem("cad.ui.tool.extrude", "Extrude", "arrow.up.to.line", .extrude, "ExtrudeButton"),
            modifyItem("cad.ui.tool.revolve", "Revolve", "arrow.trianglehead.2.clockwise.rotate.90", .revolve, "RevolveButton"),
            modifyItem("cad.ui.tool.sweep", "Sweep", "scribble.variable", .sweep, "SweepButton"),
            modifyItem("cad.ui.tool.loft", "Loft", "square.stack.3d.up", .loft, "LoftButton"),
            modifyItem("cad.ui.tool.helix", "Helix", "tornado", .helix, "HelixButton"),
            toggleItem("cad.ui.tool.chamfer", "Chamfer", "square.on.circle", "ChamferButton",
                       active: isMode { if case .pickingBlendEdges(.chamfer) = $0 { return true }; return false },
                       enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                       begin: { viewModel.beginBlend(.chamfer) }, cancel: { viewModel.cancelBlend() }),
            toggleItem("cad.ui.tool.fillet", "Fillet", "circle.circle", "FilletButton",
                       active: isMode { if case .pickingBlendEdges(.fillet) = $0 { return true }; return false },
                       enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                       begin: { viewModel.beginBlend(.fillet) }, cancel: { viewModel.cancelBlend() }),
            toggleItem("cad.ui.tool.shell", "Shell", "cube.transparent", "ShellButton",
                       active: isMode { if case .pickingShellFaces = $0 { return true }; return false },
                       enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                       begin: { viewModel.beginShell() }, cancel: { viewModel.cancelShell() }),
            toggleItem("cad.ui.tool.replaceFace", "Replace Face", "arrow.up.and.down.square", "ReplaceFaceButton",
                       active: isMode { if case .pickingReplaceFace = $0 { return true }; return false },
                       enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                       begin: { viewModel.beginReplaceFace() },
                       cancel: { viewModel.cancelReplaceFace() }),
            toggleItem("cad.ui.tool.deleteFace", "Delete Face", "square.slash", "DeleteFaceButton",
                       active: isMode { if case .pickingDeleteFaces = $0 { return true }; return false },
                       enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                       begin: { viewModel.beginDeleteFace() },
                       cancel: { viewModel.cancelDeleteFace() }),
        ])
    }

    private var transformGroup: ToolGroup {
        ToolGroup(id: "Transform", label: FloeCADStrings.text("cad.ui.tool.transform", "Transform"),
                  icon: "move.3d", items: [
            toggleItem("cad.ui.tool.scale", "Scale", "arrow.down.left.and.arrow.up.right", "ScaleButton",
                       active: viewModel.isScaleToolActive,
                       enabled: !viewModel.selection.isEmpty, tint: .purple,
                       begin: { viewModel.beginScaleTool() }, cancel: { viewModel.cancelScaleTool() }),
            ToolItem(id: "Mirror", label: FloeCADStrings.text("cad.ui.tool.mirror", "Mirror"),
                     icon: "rectangle.on.rectangle",
                     enabled: viewModel.selection.count == 1, menu: .mirror),
            toggleItem("cad.ui.tool.move", "Move", "arrow.up.and.down.and.arrow.left.and.right", "TranslateButton",
                       active: viewModel.isMoveToolActive,
                       enabled: !viewModel.selection.isEmpty, tint: .purple,
                       begin: { viewModel.beginMoveTool() }, cancel: { viewModel.cancelMoveTool() }),
            toggleItem("cad.ui.tool.rotate", "Rotate", "arrow.clockwise", "RotateAxisButton",
                       active: viewModel.isRotateToolActive,
                       enabled: !viewModel.selection.isEmpty, tint: .purple,
                       begin: { viewModel.beginRotateTool() }, cancel: { viewModel.cancelRotateTool() }),
            toggleItem("cad.ui.tool.align", "Align", "point.3.connected.trianglepath.dotted", "AlignButton",
                       active: isMode { if case .aligning = $0 { return true }; return false },
                       enabled: viewModel.session.document.bodies.count >= 2, tint: .purple,
                       begin: { viewModel.beginAlignPick() }, cancel: { viewModel.cancelAlign() }),
            toggleItem("cad.ui.tool.split", "Split", "square.split.1x2", "SplitButton",
                       active: isMode { if case .pickingSplitCutter = $0 { return true }; return false },
                       enabled: viewModel.selection.count == 1, tint: .purple,
                       begin: { viewModel.beginSplitCutterPick() }, cancel: { viewModel.cancelSplitCutterPick() }),
            toggleItem("cad.ui.tool.pattern", "Pattern", "square.grid.3x3", "PatternButton",
                       active: isMode { if case .patterning = $0 { return true }; return false },
                       enabled: viewModel.canBeginPattern, tint: .blue,
                       begin: { viewModel.beginPattern() }, cancel: { viewModel.cancelPattern() }),
        ])
    }

    private var combineGroup: ToolGroup {
        ToolGroup(id: "Combine", label: FloeCADStrings.text("cad.ui.tool.combine", "Combine"),
                  icon: "square.on.square.dashed", items: [
            booleanItem("cad.ui.tool.union", "Union", "plus.square.on.square", .union),
            booleanItem("cad.ui.tool.subtract", "Subtract", "minus.square", .subtract),
            booleanItem("cad.ui.tool.intersect", "Intersect", "square.on.square.intersection.dashed", .intersect),
        ])
    }

    private var constrainGroup: ToolGroup {
        ToolGroup(id: "Constrain", label: FloeCADStrings.text("cad.ui.tool.constrain", "Constrain"),
                  icon: "link", items: [
            ToolItem(id: "Constrain", label: FloeCADStrings.text("cad.ui.tool.constrain", "Constrain"),
                     icon: "link",
                     enabled: viewModel.mode.isSketching,
                     accessibilityID: "ConstraintsMenu", menu: .constrain),
            ToolItem(id: "Dimension", label: FloeCADStrings.text("cad.ui.tool.dimension", "Dimension"),
                     icon: "ruler",
                     enabled: viewModel.canDimensionSelection,
                     accessibilityID: "DimensionButton",
                     run: { viewModel.beginDimensionForSelection() },
                     menu: viewModel.dimensionKindChoices.count > 1 ? .dimension : nil),
        ])
    }

    private var symbolGroup: ToolGroup {
        ToolGroup(id: "Symbol", label: FloeCADStrings.text("cad.ui.tool.symbol", "Symbol"),
                  icon: "rectangle.stack", items: [
            ToolItem(id: "Symbol", label: FloeCADStrings.text("cad.ui.tool.symbol", "Symbol"),
                     icon: "rectangle.stack.badge.plus",
                     enabled: viewModel.canMakeSymbol, accessibilityID: "MakeSymbolButton",
                     run: { viewModel.showMakeSymbolPrompt = true }),
            ToolItem(id: "Insert", label: FloeCADStrings.text("cad.ui.tool.insert", "Insert"),
                     icon: "rectangle.stack",
                     enabled: viewModel.mode.isSketching && !viewModel.session.document.symbols.isEmpty,
                     active: viewModel.pendingSymbolID != nil,
                     accessibilityID: "InsertSymbolMenu", menu: .insert),
        ])
    }

    // MARK: - Standalone items

    private var drawItems: [ToolItem] {
        [sketchTool("cad.ui.tool.line", "Line", "line.diagonal", .line),
         sketchTool("cad.ui.tool.rectangle", "Rectangle", "rectangle", .rect),
         sketchTool("cad.ui.tool.circle", "Circle", "circle", .circle),
         sketchTool("cad.ui.tool.arc", "Arc", "point.topleft.down.to.point.bottomright.curvepath", .arc),
         sketchTool("cad.ui.tool.ellipse", "Ellipse", "oval", .ellipse),
         sketchTool("cad.ui.tool.polygon", "Polygon", "hexagon", .polygon),
         sketchTool("cad.ui.tool.text", "Text", "textformat", .text)]
    }

    /// Add Axis (spec §6.2). Construction geometry, so it sits with the
    /// reference tools rather than inside Modify — nothing it makes is a body.
    private var axisItem: ToolItem {
        toggleItem("cad.ui.tool.axis", "Axis", "line.diagonal.arrow", "AxisButton",
                   active: isMode { if case .pickingAxisReferences = $0 { return true }; return false },
                   enabled: !viewModel.session.document.bodies.isEmpty, tint: .blue,
                   begin: { viewModel.beginAxisTool() }, cancel: { viewModel.cancelAxisTool() })
    }

    private var measureItem: ToolItem {
        ToolItem(id: "Measure", label: FloeCADStrings.text("cad.ui.tool.measure", "Measure"),
                 icon: "ruler",
                 active: isMode { if case .measuring = $0 { return true }; return false },
                 accessibilityID: "MeasureButton", run: { viewModel.toggleMeasure() })
    }

    private var materialItem: ToolItem {
        ToolItem(id: "Material", label: FloeCADStrings.text("cad.ui.tool.material", "Material"),
                 icon: "paintpalette",
                 enabled: !viewModel.selection.isEmpty, accessibilityID: "MaterialButton",
                 run: { viewModel.showMaterialSheet = true })
    }

    private var selectItem: ToolItem {
        ToolItem(id: "Select", label: FloeCADStrings.text("cad.ui.tool.select", "Select"),
                 icon: "cursorarrow.and.square.on.square.dashed",
                 active: viewModel.selectModeActive, accessibilityID: "SelectModeButton",
                 run: { viewModel.toggleSelectMode() })
    }

    private var constructItem: ToolItem {
        ToolItem(id: "Construct", label: FloeCADStrings.text("cad.ui.tool.construct", "Construct"),
                 icon: "square.dashed",
                 enabled: viewModel.mode.isSketching && !viewModel.selectedSketchEntityIDs.isEmpty,
                 active: viewModel.selectionIsConstruction, accessibilityID: "ConstructionButton",
                 run: { viewModel.toggleConstructionOnSelection() })
    }

    private var deleteItem: ToolItem {
        ToolItem(id: "Delete", label: FloeCADStrings.text("cad.ui.common.delete", "Delete"),
                 icon: "trash",
                 enabled: viewModel.mode.isSketching
                    ? (!viewModel.selectedSketchEntityIDs.isEmpty || viewModel.hasSketchGlyphSelection)
                    : (!viewModel.selection.isEmpty || viewModel.selectedImage != nil
                       || !viewModel.selectedSketchEntityIDs.isEmpty),
                 accessibilityID: "DeleteButton", run: { viewModel.deleteSelection() })
    }

    // MARK: - Item builders

    private func sketchTool(_ key: String, _ label: String, _ icon: String, _ tool: SketchTool) -> ToolItem {
        let active: Bool = {
            if case .sketching(_, let current) = viewModel.mode { return current == tool }
            return false
        }()
        // Tapping the active tool deselects it (same toggle as CreateTool):
        // with no tool armed, empty-space drags orbit the sketch view.
        return ToolItem(id: label, label: FloeCADStrings.text(key, label), icon: icon, active: active,
                        accessibilityID: tool == .rect ? "Rect" : nil,
                        run: {
                            if active {
                                viewModel.deselectSketchTool()
                            } else {
                                viewModel.startSketch(tool: tool)
                            }
                        })
    }

    private func modifyItem(_ key: String, _ label: String, _ icon: String,
                            _ tool: CreateTool, _ axid: String) -> ToolItem {
        ToolItem(id: label, label: FloeCADStrings.text(key, label), icon: icon,
                 enabled: viewModel.hasExtrudableProfile,
                 active: viewModel.pendingCreateTool == tool, activeTint: .blue,
                 accessibilityID: axid,
                 run: { viewModel.pendingCreateTool == tool ? viewModel.cancelCreate() : viewModel.beginCreate(tool) })
    }

    private func booleanItem(_ key: String, _ label: String, _ icon: String, _ kind: BooleanKind) -> ToolItem {
        let isArming: Bool = {
            if case .pickingBooleanTool(let current, _) = viewModel.mode { return current == kind }
            return false
        }()
        return ToolItem(id: label, label: FloeCADStrings.text(key, label), icon: icon,
                        enabled: viewModel.selection.count == 1 || isArming,
                        active: isArming, activeTint: .purple,
                        run: { isArming ? viewModel.cancelBooleanPicking() : viewModel.armBoolean(kind) })
    }

    private func toggleItem(_ key: String, _ label: String, _ icon: String, _ axid: String,
                            active: Bool, enabled: Bool, tint: Color,
                            begin: @escaping () -> Void, cancel: @escaping () -> Void) -> ToolItem {
        ToolItem(id: label, label: FloeCADStrings.text(key, label), icon: icon,
                 enabled: enabled || active, active: active, activeTint: tint,
                 accessibilityID: axid, run: { active ? cancel() : begin() })
    }

    private func isMode(_ predicate: (EditorMode) -> Bool) -> Bool { predicate(viewModel.mode) }

    // MARK: - Group button + flyout

    private func groupButton(_ group: ToolGroup) -> some View {
        let anyActive = group.items.contains { $0.active }
        let expanded = expandedGroupID == group.id
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                expandedGroupID = expanded ? nil : group.id
            }
        } label: {
            paletteIcon(group.icon, label: group.label)
                .foregroundStyle(anyActive ? Color.blue : Color.primary)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((expanded || anyActive) ? Color.blue.opacity(0.15) : Color.clear)
        )
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: GroupFrameKey.self,
                value: [group.id: geo.frame(in: .named("palette"))]
            )
        })
        .accessibilityIdentifier(group.id + "Group")
    }

    @ViewBuilder
    private var flyoutOverlay: some View {
        if let id = expandedGroupID,
           let group = currentGroups.first(where: { $0.id == id }),
           let frame = groupFrames[id] {
            HStack(spacing: 4) {
                ForEach(group.items) { item in
                    toolView(item, inFlyout: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .fixedSize()
            .offset(x: paletteOnRight ? -(frame.width + 10) : frame.maxX + 10, y: frame.minY)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func toolView(_ item: ToolItem, inFlyout: Bool = false) -> some View {
        switch item.menu {
        case .constrain: constraintsMenu
        case .dimension: dimensionMenu
        case .insert: insertSymbolMenu
        case .mirror: mirrorMenu
        case nil: actionButton(item, inFlyout: inFlyout)
        }
    }

    @ViewBuilder
    private func actionButton(_ item: ToolItem, inFlyout: Bool) -> some View {
        let button = Button {
            item.run()
            if inFlyout { expandedGroupID = nil }
        } label: {
            paletteIcon(item.icon, label: item.label)
                .foregroundStyle(item.active ? item.activeTint : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(item.active ? item.activeTint.opacity(0.15) : Color.clear)
        )
        if let axid = item.accessibilityID {
            button.accessibilityIdentifier(axid)
        } else {
            button
        }
    }

    // MARK: - Menu-backed tools (kept bespoke)

    private var dimensionMenu: some View {
        Menu {
            ForEach(viewModel.dimensionKindChoices, id: \.rawValue) { kind in
                Button(dimensionKindTitle(kind)) {
                    viewModel.beginDimensionForSelection(kind: kind)
                    expandedGroupID = nil
                }
                .accessibilityIdentifier("DimensionKind-" + kind.rawValue)
            }
        } label: {
            paletteIcon("ruler", label: FloeCADStrings.text("cad.ui.tool.dimension", "Dimension"))
                .foregroundStyle(Color.primary)
        }
        .disabled(!viewModel.canDimensionSelection)
        .accessibilityIdentifier("DimensionButton")
    }

    private func dimensionKindTitle(_ kind: DimensionKind) -> String {
        switch kind {
        case .distance: FloeCADStrings.text("cad.ui.dimension.absolute", "Absolute")
        case .horizontal: FloeCADStrings.text("cad.ui.constraint.horizontal", "Horizontal")
        case .vertical: FloeCADStrings.text("cad.ui.constraint.vertical", "Vertical")
        default: EditorViewModel.dimensionTitle(.init(kind: kind, refs: [], value: 0))
        }
    }

    private var mirrorMenu: some View {
        Menu {
            ForEach(Array(viewModel.mirrorPlaneOptions.enumerated()), id: \.offset) { _, option in
                Button(option.label) {
                    viewModel.mirrorSelection(across: option.plane)
                    expandedGroupID = nil
                }
            }
        } label: {
            paletteIcon("rectangle.on.rectangle", label: FloeCADStrings.text("cad.ui.tool.mirror", "Mirror"))
                .foregroundStyle(Color.primary)
        }
        .disabled(viewModel.selection.count != 1)
    }

    private var insertSymbolMenu: some View {
        let armed = viewModel.pendingSymbolID != nil
        return Menu {
            ForEach(viewModel.session.document.symbols) { symbol in
                Button(symbol.name) {
                    viewModel.beginInsertSymbol(symbol.id)
                    expandedGroupID = nil
                }
            }
        } label: {
            paletteIcon("rectangle.stack", label: FloeCADStrings.text("cad.ui.tool.insert", "Insert"))
                .foregroundStyle(armed ? Color.blue : Color.primary)
        }
        .disabled(!viewModel.mode.isSketching || viewModel.session.document.symbols.isEmpty)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(armed ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("InsertSymbolMenu")
    }

    private var constraintsMenu: some View {
        Menu {
            constraintItem("cad.ui.constraint.coincident", "Coincident", .coincident, key: "c")
            constraintItem("cad.ui.constraint.horizontal", "Horizontal", .horizontal, key: "h")
            constraintItem("cad.ui.constraint.vertical", "Vertical", .vertical, key: "v")
            constraintItem("cad.ui.constraint.parallel", "Parallel", .parallel, key: "p")
            constraintItem("cad.ui.constraint.perpendicular", "Perpendicular", .perpendicular, key: "e")
            constraintItem("cad.ui.constraint.equalLength", "Equal Length", .equalLength, key: "q")
            constraintItem("cad.ui.constraint.equalRadius", "Equal Radius", .equalRadius, key: "r")
            constraintItem("cad.ui.constraint.concentric", "Concentric", .concentric, key: "o")
            constraintItem("cad.ui.constraint.midpoint", "Midpoint", .midpoint, key: "m")
            constraintItem("cad.ui.constraint.symmetric", "Symmetric", .symmetric, key: "y")
            constraintItem("cad.ui.constraint.tangent", "Tangent", .tangent, key: "t")
            constraintItem("cad.ui.constraint.colinear", "Colinear", .colinear, key: "l")
            constraintItem("cad.ui.constraint.lock", "Lock", .fixed, key: "k")

            Divider()
            Button(FloeCADStrings.label("cad.ui.constraint.delete", "Delete Constraint")) {
                viewModel.deleteSelectedConstraint()
            }
                .disabled(viewModel.selectedConstraintID == nil)
                .accessibilityIdentifier("DeleteConstraintItem")

            Divider()
            Button(FloeCADStrings.label("cad.ui.constraint.autoSettings", "Auto-Constrain Settings…")) {
                viewModel.showConstraintSettings = true
            }
                .accessibilityIdentifier("ConstraintSettingsItem")
        } label: {
            paletteIcon("link", label: FloeCADStrings.text("cad.ui.tool.constrain", "Constrain"))
                .foregroundStyle(Color.primary)
        }
        .disabled(!viewModel.mode.isSketching)
        .accessibilityIdentifier("ConstraintsMenu")
    }

    private func constraintItem(_ translationKey: String, _ label: String, _ kind: SketchConstraintKind, key: KeyEquivalent) -> some View {
        Button {
            viewModel.applyConstraint(kind)
            expandedGroupID = nil
        } label: {
            Text("\(EditorViewModel.constraintCode(kind))   \(FloeCADStrings.text(translationKey, label))")
        }
        .keyboardShortcut(key, modifiers: [.shift])
        .disabled(!viewModel.canApplyConstraint(kind))
        .accessibilityIdentifier("Constraint_\(label.replacingOccurrences(of: " ", with: ""))")
    }

    // MARK: - Shared icon renderer

    private func paletteIcon(_ systemImage: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 44, height: 30)
            Text(label)
                .font(.system(size: 9))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
