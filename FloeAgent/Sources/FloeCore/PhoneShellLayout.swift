// FloeCore — pure adaptive phone-shell geometry.
//
// SPDX-License-Identifier: MPL-2.0
//
// The ordinary phone navigation shell has always been ONE full-width content
// column plus an off-canvas drawer. Hinge hardware whose first mount resolved
// as ordinary (a verified real-iPhone-Duo case: capability foldable /
// fullyOpen / latchedFoldableMount false) — and any sufficiently wide phone
// window — still needs a readable persistent sidebar inside that SAME shell.
// The outer iPhoneRoot/iPadRoot choice stays frozen; the phone shell keeps
// exactly two identity-bearing children (primary content, sidebar) and only
// their placed rects change. Everything the runtime component and its tests
// share lives here, with no UIKit and no device-name heuristics.

import Foundation

/// The two presentations of the stable phone shell.
public enum PhoneShellPresentationMode: String, Sendable, Equatable, CaseIterable {
    /// Full-width content plus the existing off-canvas drawer (today's phone).
    case compactDrawer
    /// Persistent, readable sidebar beside the content column (iPad-like wide).
    case expandedSidebar
}

/// Fixed structural slots of the one stable workbench parent. The raw values
/// are compile-time constants: a fold, resize or sidebar toggle can only move
/// the two children inside the parent — never swap or recreate them.
public enum PhoneShellSlot: Int, Sendable, Equatable, CaseIterable {
    case primary = 0
    case sidebar = 1
}

/// The complete placement plan for one container size. Pure value type so the
/// SwiftUI `Layout` and the tests place the very same rects.
public struct PhoneShellPlan: Sendable, Equatable {
    public var mode: PhoneShellPresentationMode
    public var containerSize: FoldableSize
    /// Primary content subtree, in container coordinates.
    public var primaryFrame: FoldableRect
    /// Sidebar subtree. In compact mode it stays MOUNTED off-canvas, and in
    /// expanded mode with the sidebar collapsed it stays mounted just outside
    /// the leading edge: a width transition never recreates either subtree.
    public var sidebarFrame: FoldableRect
    /// Compact draw-in progress 0...1 (always 0 in the expanded layout).
    public var drawerProgress: Double
    public var primaryScale: Double
    public var primaryOffsetX: Double
    public var primaryCornerRadius: Double
    public var sidebarCornerRadius: Double
    public var scrimOpacity: Double
    /// The sidebar is actually on screen.
    public var sidebarIsVisible: Bool

    public init(mode: PhoneShellPresentationMode,
                containerSize: FoldableSize,
                primaryFrame: FoldableRect,
                sidebarFrame: FoldableRect,
                drawerProgress: Double,
                primaryScale: Double,
                primaryOffsetX: Double,
                primaryCornerRadius: Double,
                sidebarCornerRadius: Double,
                scrimOpacity: Double,
                sidebarIsVisible: Bool) {
        self.mode = mode
        self.containerSize = containerSize
        self.primaryFrame = primaryFrame
        self.sidebarFrame = sidebarFrame
        self.drawerProgress = drawerProgress
        self.primaryScale = primaryScale
        self.primaryOffsetX = primaryOffsetX
        self.primaryCornerRadius = primaryCornerRadius
        self.sidebarCornerRadius = sidebarCornerRadius
        self.scrimOpacity = scrimOpacity
        self.sidebarIsVisible = sidebarIsVisible
    }

    public var showsScrim: Bool { scrimOpacity > 0.001 }

    /// Slot constants pinned for identity tests.
    public var primarySlot: PhoneShellSlot { .primary }
    public var sidebarSlot: PhoneShellSlot { .sidebar }

    /// The primary always owns the whole container height.
    public var primaryWidth: Double { primaryFrame.width }
    public var sidebarWidth: Double { sidebarFrame.width }
}

public enum PhoneShellLayoutEngine {
    /// Enter the persistent-sidebar layout only when the content column can
    /// still keep `editorMinimumContentWidth` beside the minimum sidebar.
    public static let expandedEnterWidth: Double = 580
    /// Leave late so a live resize or fold animation crossing the threshold
    /// cannot flap the chrome (hysteresis).
    public static let expandedExitWidth: Double = 560
    public static let editorMinimumContentWidth: Double = 320
    public static let sidebarMinimumWidth: Double = 240
    public static let sidebarMaximumWidth: Double = 360
    /// Target sidebar width as a fraction of the container, clamped.
    public static let sidebarWidthFraction: Double = 0.32
    public static let drawerMinimumWidth: Double = 300
    public static let drawerMaximumWidth: Double = 390
    public static let drawerEdgeReveal: Double = 44
    public static let compactSidebarCornerRadius: Double = 28
    public static let primaryDrawScaleReduction: Double = 0.025
    public static let primaryDrawOffset: Double = 18
    public static let primaryDrawCornerRadius: Double = 22
    public static let scrimMaximumOpacity: Double = 0.22
    /// The drawer opens/closes only past this fraction of its width.
    public static let drawerCommitFraction: Double = 0.22

    private static func sanitized(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }

    /// Width-only decision. Idle/unknown capability never enters this input:
    /// an ordinary phone window and an ordinary-latched Duo both use the same
    /// rule, so the opened inner screen reaches the persistent sidebar even
    /// when the scene latch stayed ordinary.
    public static func mode(containerWidth: Double,
                            previouslyExpanded: Bool) -> PhoneShellPresentationMode {
        let width = max(0, sanitized(containerWidth))
        let threshold = previouslyExpanded ? expandedExitWidth : expandedEnterWidth
        return width >= threshold ? .expandedSidebar : .compactDrawer
    }

    public static func resolvesExpanded(containerWidth: Double,
                                        previouslyExpanded: Bool) -> Bool {
        mode(containerWidth: containerWidth, previouslyExpanded: previouslyExpanded) == .expandedSidebar
    }

    /// Clamped persistent-sidebar width. Never takes room the content column
    /// needs for a readable editor.
    public static func sidebarWidth(containerWidth: Double,
                                    preferredWidth: Double) -> Double {
        let width = max(0, sanitized(containerWidth))
        guard width > 0 else { return 0 }
        let preferred = sanitized(preferredWidth, fallback: sidebarMinimumWidth)
        let target = max(sidebarMinimumWidth, min(preferred, width * sidebarWidthFraction))
        let contentRoom = max(0, width - editorMinimumContentWidth)
        let upper = min(sidebarMaximumWidth, max(sidebarMinimumWidth, contentRoom))
        return min(width, min(upper, max(sidebarMinimumWidth, target)))
    }

    /// Today's drawer width, unchanged: min(390, max(300, container - 44)).
    public static func drawerWidth(containerWidth: Double) -> Double {
        let width = max(0, sanitized(containerWidth))
        return min(drawerMaximumWidth, max(drawerMinimumWidth, width - drawerEdgeReveal))
    }

    /// The drawer's x offset for an open/closed state plus a live drag.
    /// Closing drags are negative while open; opening drags are positive
    /// while closed — exactly the historical phone behaviour.
    public static func drawerOffset(drawerWidth: Double,
                                    drawerOpen: Bool,
                                    translation: Double) -> Double {
        let width = max(0, sanitized(drawerWidth))
        guard width > 0 else { return 0 }
        let base = drawerOpen ? 0 : -width
        let raw = min(width, max(-width, sanitized(translation)))
        let applied = drawerOpen ? min(0, raw) : max(0, raw)
        return min(0, max(-width, base + applied))
    }

    public static func drawerProgress(drawerWidth: Double,
                                      drawerOpen: Bool,
                                      translation: Double) -> Double {
        let width = max(0, sanitized(drawerWidth))
        guard width > 0 else { return drawerOpen ? 1 : 0 }
        let offset = drawerOffset(drawerWidth: width,
                                  drawerOpen: drawerOpen,
                                  translation: translation)
        return min(1, max(0, 1 - abs(offset / width)))
    }

    /// The one plan the runtime component places. `previouslyExpanded` is the
    /// component's own hysteresis state; it never changes identity.
    public static func plan(containerWidth: Double,
                            containerHeight: Double,
                            preferredSidebarWidth: Double,
                            drawerOpen: Bool,
                            drawerTranslation: Double,
                            expandedSidebarVisible: Bool,
                            previouslyExpanded: Bool) -> PhoneShellPlan {
        let width = max(0, sanitized(containerWidth))
        let height = max(0, sanitized(containerHeight))
        let container = FoldableSize(width: width, height: height)
        let mode = mode(containerWidth: width, previouslyExpanded: previouslyExpanded)
        switch mode {
        case .expandedSidebar:
            let sidebar = sidebarWidth(containerWidth: width,
                                       preferredWidth: preferredSidebarWidth)
            if expandedSidebarVisible {
                return PhoneShellPlan(
                    mode: mode,
                    containerSize: container,
                    primaryFrame: FoldableRect(x: sidebar, y: 0,
                                               width: max(0, width - sidebar),
                                               height: height),
                    sidebarFrame: FoldableRect(x: 0, y: 0,
                                               width: sidebar, height: height),
                    drawerProgress: 0,
                    primaryScale: 1,
                    primaryOffsetX: 0,
                    primaryCornerRadius: 0,
                    sidebarCornerRadius: 0,
                    scrimOpacity: 0,
                    sidebarIsVisible: sidebar > 0)
            }
            return PhoneShellPlan(
                mode: mode,
                containerSize: container,
                primaryFrame: FoldableRect(x: 0, y: 0, width: width, height: height),
                sidebarFrame: FoldableRect(x: -sidebar, y: 0,
                                           width: sidebar, height: height),
                drawerProgress: 0,
                primaryScale: 1,
                primaryOffsetX: 0,
                primaryCornerRadius: 0,
                sidebarCornerRadius: 0,
                scrimOpacity: 0,
                sidebarIsVisible: false)
        case .compactDrawer:
            let drawer = drawerWidth(containerWidth: width)
            let offset = drawerOffset(drawerWidth: drawer,
                                      drawerOpen: drawerOpen,
                                      translation: drawerTranslation)
            let progress = drawerProgress(drawerWidth: drawer,
                                          drawerOpen: drawerOpen,
                                          translation: drawerTranslation)
            return PhoneShellPlan(
                mode: mode,
                containerSize: container,
                primaryFrame: FoldableRect(x: 0, y: 0, width: width, height: height),
                sidebarFrame: FoldableRect(x: offset, y: 0, width: drawer, height: height),
                drawerProgress: progress,
                primaryScale: 1 - primaryDrawScaleReduction * progress,
                primaryOffsetX: primaryDrawOffset * progress,
                primaryCornerRadius: primaryDrawCornerRadius * progress,
                sidebarCornerRadius: compactSidebarCornerRadius,
                scrimOpacity: scrimMaximumOpacity * progress,
                sidebarIsVisible: progress > 0.001)
        }
    }
}
