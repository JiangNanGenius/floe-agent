// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Width classes used by the workbench shell. The thresholds are shared by the
/// view and its focused geometry checks so the canvas budget is observable
/// instead of depending on an accidental stack of minimum widths.
enum EDWorkbenchWidthClass: Equatable, Sendable {
    case compact, regular, wide
}

struct EDWorkbenchLayout: Equatable, Sendable {
    /// A regular horizontal size class below this width uses one side panel
    /// (inspector) and moves the navigator into a sheet. Below 900 the canvas
    /// leads and both side panels become sheets.
    static let regularMinimumWidth: CGFloat = 900
    /// A large iPad in landscape keeps the navigator and inspector visible.
    static let wideMinimumWidth: CGFloat = 1_180
    static let minimumCanvasWidth: CGFloat = 480
    static let navigatorWidth: CGFloat = 204
    static let toolRailWidth: CGFloat = 52
    static let inspectorWidth: CGFloat = 280
    static let dividerWidth: CGFloat = 1

    let width: CGFloat
    let compactSizeClass: Bool

    init(width: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) {
        self.width = width.isFinite ? max(0, width) : 0
        compactSizeClass = horizontalSizeClass == .compact
    }

    var widthClass: EDWorkbenchWidthClass {
        if compactSizeClass || width < Self.regularMinimumWidth { return .compact }
        if width >= Self.wideMinimumWidth { return .wide }
        return .regular
    }

    var isCompact: Bool { widthClass == .compact }
    var canShowSideNavigator: Bool { widthClass == .wide }
    var canShowInspector: Bool { !isCompact }
    var usesHorizontalToolStrip: Bool { isCompact }

    /// Width left for the drawing after the actual side surfaces. Compact
    /// widths never subtract side panels; only the tool rail is removed when
    /// the horizontal tool strip owns the tool row.
    func canvasBudget(showingNavigator: Bool, showingInspector: Bool) -> CGFloat {
        var budget = width
        if !isCompact { budget -= Self.toolRailWidth + Self.dividerWidth }
        if showingNavigator, canShowSideNavigator { budget -= Self.navigatorWidth + Self.dividerWidth }
        if showingInspector, canShowInspector { budget -= Self.inspectorWidth + Self.dividerWidth }
        return max(0, budget)
    }

    func sideInspectorKeepsCanvas(showingNavigator: Bool) -> Bool {
        canShowInspector
            && canvasBudget(showingNavigator: showingNavigator, showingInspector: true) >= Self.minimumCanvasWidth
    }
}

/// Tool grouping is data so the vertical rail and compact strip cannot drift
/// apart, and focused checks can prove the previously available tools remain.
enum EDToolCatalog {
    static func canvasGroups(for tab: EDWorkspaceTab) -> [[EDCanvasTool]] {
        switch tab {
        case .board:
            return [[.select], [.place, .wire, .via, .zone, .outline, .hole], [.erase]]
        case .symbols, .footprints, .checks, .outputs, .threeD:
            return []
        case .schematic:
            return [[.select], [.place, .wire, .bus, .junction, .label], [.erase]]
        }
    }

    static func libraryTools(for tab: EDWorkspaceTab) -> [EDLibraryTool] {
        switch tab {
        case .symbols: return EDLibraryTool.symbolTools
        case .footprints: return EDLibraryTool.footprintTools
        default: return []
        }
    }
}

enum EDCanvasZoom {
    static let minimum = 0.05
    static let maximum = 50.0
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(maximum, max(minimum, value))
    }
}

func edCopperTint(_ layerID: String) -> Color {
    switch layerID {
    case "F.Cu": return .red
    case "B.Cu": return .blue
    default: return .green
    }
}
