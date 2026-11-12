// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

/// One 44 pt icon button shared by the vertical rail and the compact strip.
struct EDToolButton: View {
    let title: String
    let image: String
    let selected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("electronics.tool." + identifier)
    }
}

/// iPad/keyboard layout: a narrow vertical rail keeps the drawing wide.
struct EDToolRail: View {
    let tab: EDWorkspaceTab
    let tool: EDCanvasTool
    let libraryTool: EDLibraryTool
    let fingerDrawingEnabled: Bool
    let onTool: (EDCanvasTool) -> Void
    let onPlace: () -> Void
    let onLibraryTool: (EDLibraryTool) -> Void
    let onToggleFingerDrawing: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    canvasGroups
                    libraryTools
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Divider().padding(.horizontal, 8)
            EDToolButton(title: edText("手指绘图", "Finger drawing"), image: "hand.draw",
                         selected: fingerDrawingEnabled, identifier: "fingerDrawing",
                         action: onToggleFingerDrawing)
        }
        .padding(.vertical, 2)
        .frame(width: EDWorkbenchLayout.toolRailWidth)
        .background(.bar)
        .accessibilityIdentifier("electronics.toolRail")
    }

    @ViewBuilder private var canvasGroups: some View {
        let groups = EDToolCatalog.canvasGroups(for: tab)
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { railDivider }
            ForEach(groups[index]) { item in
                toolButton(item)
            }
        }
    }

    @ViewBuilder private var libraryTools: some View {
        let tools = EDToolCatalog.libraryTools(for: tab)
        ForEach(tools.indices, id: \.self) { index in
            if index == 0 { railDivider }
            let item = tools[index]
            EDToolButton(title: item.title, image: item.image, selected: libraryTool == item,
                         identifier: item.rawValue) { onLibraryTool(item) }
        }
    }

    private var railDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 28, height: 1).padding(.vertical, 4)
    }

    private func toolButton(_ item: EDCanvasTool) -> some View {
        EDToolButton(title: item.title(on: tab), image: item.image, selected: tool == item,
                     identifier: item.rawValue) {
            item == .place ? onPlace() : onTool(item)
        }
    }
}

/// iPhone/split-view layout: the same tool model as one compact horizontal row.
struct EDToolStrip: View {
    let tab: EDWorkspaceTab
    let tool: EDCanvasTool
    let libraryTool: EDLibraryTool
    let fingerDrawingEnabled: Bool
    let onTool: (EDCanvasTool) -> Void
    let onPlace: () -> Void
    let onLibraryTool: (EDLibraryTool) -> Void
    let onToggleFingerDrawing: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                canvasGroups
                libraryTools
                stripDivider
                EDToolButton(title: edText("手指绘图", "Finger drawing"), image: "hand.draw",
                             selected: fingerDrawingEnabled, identifier: "fingerDrawing",
                             action: onToggleFingerDrawing)
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: 48)
        .background(.bar)
        .accessibilityIdentifier("electronics.toolStrip")
    }

    @ViewBuilder private var canvasGroups: some View {
        let groups = EDToolCatalog.canvasGroups(for: tab)
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { stripDivider }
            ForEach(groups[index]) { item in
                EDToolButton(title: item.title(on: tab), image: item.image, selected: tool == item,
                             identifier: item.rawValue) {
                    item == .place ? onPlace() : onTool(item)
                }
            }
        }
    }

    @ViewBuilder private var libraryTools: some View {
        let tools = EDToolCatalog.libraryTools(for: tab)
        ForEach(tools.indices, id: \.self) { index in
            if index == 0 { stripDivider }
            let item = tools[index]
            EDToolButton(title: item.title, image: item.image, selected: libraryTool == item,
                         identifier: item.rawValue) { onLibraryTool(item) }
        }
    }

    private var stripDivider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 26).padding(.horizontal, 4)
    }
}

/// Active copper layer is a first-class routing control. Four chips stay
/// visible and any additional layers remain reachable from the overflow menu.
struct EDCopperLayerStrip: View {
    let layers: [EDALayer]
    @Binding var selection: String
    private static let maximumVisible = 4

    private var copperLayers: [EDALayer] { layers.filter { $0.kind == .copper } }

    private var visibleLayers: [EDALayer] {
        let copper = copperLayers
        guard copper.count > Self.maximumVisible else { return copper }
        var visible = Array(copper.prefix(Self.maximumVisible))
        if !visible.contains(where: { $0.id == selection }),
           let active = copper.first(where: { $0.id == selection }) {
            visible[Self.maximumVisible - 1] = active
        }
        return visible
    }

    private var remainingLayers: [EDALayer] {
        let visible = Set(visibleLayers.map(\.id))
        return copperLayers.filter { !visible.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.3.layers.3d")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(visibleLayers) { layer in
                layerButton(layer)
            }
            if !remainingLayers.isEmpty {
                Menu {
                    ForEach(copperLayers) { layer in
                        Button { selection = layer.id } label: {
                            if layer.id == selection {
                                Label(layer.id, systemImage: "checkmark")
                            } else {
                                Text(layer.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(edText("其他铜层", "More copper layers"))
                .accessibilityIdentifier("electronics.layers.menu")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("electronics.layers")
    }

    private func layerButton(_ layer: EDALayer) -> some View {
        let active = layer.id == selection
        return Button { selection = layer.id } label: {
            HStack(spacing: 5) {
                Circle().fill(edCopperTint(layer.id)).frame(width: 6, height: 6)
                Text(layer.id).font(.caption.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(edText("铜层 ", "Copper layer ") + layer.id)
        .accessibilityValue(active ? edText("当前", "Active") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("electronics.layer." + layer.id)
    }
}

/// Manual track width remains available; presets make repeated routing choices
/// one tap on touch and pointer input.
struct EDTrackWidthControl: View {
    @Binding var width: Double
    private static let presets: [Double] = [0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 3) {
            TextField(edText("线宽（毫米）", "Track width in millimetres"), value: $width, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
                .frame(minHeight: 36)
                .accessibilityLabel(edText("线宽（毫米）", "Track width in millimetres"))
                .accessibilityIdentifier("electronics.trackWidth")
            Text("mm").font(.caption2).foregroundStyle(.secondary)
            Menu {
                ForEach(Self.presets, id: \.self) { value in
                    Button { width = value } label: {
                        if abs(width - value) < 0.0005 {
                            Label(String(format: "%g mm", value), systemImage: "checkmark")
                        } else {
                            Text(String(format: "%g mm", value))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(edText("常用线宽", "Common track widths"))
            .accessibilityIdentifier("electronics.trackWidth.presets")
        }
    }
}

/// Thin, stable status strip. It never changes height as a selection or draft
/// appears, so the canvas budget stays predictable while editing.
struct EDWorkbenchStatusBar: View {
    let session: EDWorkbenchSession
    let tab: EDWorkspaceTab
    let activeLayer: String
    let selectionSummary: String?
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(stateText).lineLimit(1)
            if session.isFilling {
                Button(edText("停止", "Stop")) { session.cancelFilling() }
                    .disabled(!session.canCancelFilling)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("electronics.status.stopFilling")
            } else if session.isRouting {
                Button(edText("停止", "Stop")) { session.cancelRouting() }
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("electronics.status.stopRouting")
            }
            Spacer(minLength: 4)
            if let selectionSummary, !compact {
                Label(selectionSummary, systemImage: "cursorarrow")
                    .lineLimit(1)
                    .accessibilityIdentifier("electronics.status.selection")
            }
            if tab == .board, !activeLayer.isEmpty {
                Label(activeLayer, systemImage: "square.3.layers.3d")
                    .font(.caption.monospacedDigit())
            }
            Label(String(format: "%g mm", session.gridSizeMillimetres), systemImage: "grid")
                .font(.caption.monospacedDigit())
            if !compact {
                Text(session.snapToGrid ? edText("吸附", "Snap") : edText("自由", "Free"))
            }
            if session.busy || session.isRouting || session.isFilling {
                ProgressView().controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("electronics.status")
    }

    private var stateText: String {
        if session.busy || session.isCommittingCopperFill { return edText("正在保存…", "Saving…") }
        if session.isFilling { return edText("正在重填铜区…", "Refilling copper zones…") }
        if session.isRouting { return edText("正在布线…", "Routing…") }
        if session.isDirty { return edText("有未保存的修改", "Unsaved changes") }
        return edText("已保存", "Saved")
    }
}
