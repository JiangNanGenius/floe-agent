// FloeCoreTests — adaptive phone shell geometry.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pins the ONE stable phone-shell plan: the real iPhone Duo sizes (folded
// cover, opened inner landscape/portrait) and their measured SAFE content
// sizes, the compact drawer parity with the historical phone shell, the
// expanded persistent sidebar, hysteresis on resize, the editor minimum
// width and containment. Actual view identity is checked in the native host. Geometry only — capability,
// hinge state and device model never enter this model.

import Foundation
import Testing
@testable import FloeCore

/// Physical sizes of the real iPhone Duo.
private let foldedCover = FoldableSize(width: 466, height: 678)
/// Measured safe content inside the opened inner display (951x669 physical):
/// the system trailing rail is 84 pt and the bottom inset is 34 pt.
private let expandedSafe = FoldableSize(width: 867, height: 635)
/// Additional synthetic narrow portrait viewport (not a device measurement).
private let narrowPortraitViewport = FoldableSize(width: 585, height: 869)
private let innerPortraitPhysical = FoldableSize(width: 669, height: 951)

private func expectClose(_ actual: Double, _ expected: Double,
                         tolerance: Double = 0.01,
                         _ label: String = "") {
    #expect(abs(actual - expected) < tolerance,
            "\(label) expected \(expected), got \(actual)")
}

private func plan(_ size: FoldableSize,
                  preferred: Double = 280,
                  drawerOpen: Bool = false,
                  translation: Double = 0,
                  sidebarVisible: Bool = true,
                  previouslyExpanded: Bool = false) -> PhoneShellPlan {
    PhoneShellLayoutEngine.plan(
        containerWidth: size.width,
        containerHeight: size.height,
        preferredSidebarWidth: preferred,
        drawerOpen: drawerOpen,
        drawerTranslation: translation,
        expandedSidebarVisible: sidebarVisible,
        previouslyExpanded: previouslyExpanded)
}

private func expectContained(_ plan: PhoneShellPlan) {
    #expect(plan.primaryFrame.x >= -0.5)
    #expect(plan.primaryFrame.y >= -0.5)
    #expect(plan.primaryFrame.maxX <= plan.containerSize.width + 0.5)
    #expect(plan.primaryFrame.maxY <= plan.containerSize.height + 0.5)
    #expect(plan.sidebarFrame.width > 0)
    #expect(plan.sidebarFrame.maxX <= plan.containerSize.width + 0.5)
    #expect(plan.sidebarFrame.maxY <= plan.containerSize.height + 0.5)
}

@Suite("Adaptive phone shell — folded cover")
struct PhoneShellCompactTests {
    @Test("measured folded safe content stays usable")
    func measuredFoldedSafeWidth() {
        let p = plan(FoldableSize(width: 382, height: 644), drawerOpen: true)
        #expect(p.mode == .compactDrawer)
        expectClose(p.sidebarFrame.width, 338)
        expectClose(p.primaryFrame.width, 382)
        #expect(p.sidebarIsVisible)
        expectContained(p)
    }

    @Test("folded Duo stays the existing compact drawer")
    func foldedCoverIsCompact() {
        #expect(PhoneShellLayoutEngine.mode(containerWidth: foldedCover.width,
                                            previouslyExpanded: false) == .compactDrawer)
        let p = plan(foldedCover)
        #expect(p.mode == .compactDrawer)
        #expect(p.primaryFrame == FoldableRect(x: 0, y: 0,
                                               width: foldedCover.width,
                                               height: foldedCover.height))
        // The sidebar stays mounted, entirely left of the screen.
        expectClose(p.sidebarFrame.x, -p.sidebarFrame.width, "closed drawer x")
        #expect(p.drawerProgress == 0)
        #expect(p.primaryScale == 1)
        #expect(p.primaryOffsetX == 0)
        #expect(p.primaryCornerRadius == 0)
        #expect(!p.showsScrim)
        #expect(!p.sidebarIsVisible)
        expectContained(p)
    }

    @Test("opening the drawer reproduces the historical phone geometry")
    func drawerOpenParity() {
        let width = foldedCover.width
        let drawer = PhoneShellLayoutEngine.drawerWidth(containerWidth: width)
        #expect(drawer == min(390, max(300, width - 44)))
        let p = plan(foldedCover, drawerOpen: true)
        #expect(p.drawerProgress == 1)
        expectClose(p.sidebarFrame.x, 0, "open drawer x")
        expectClose(p.sidebarFrame.width, drawer, "open drawer width")
        expectClose(p.primaryScale, 1 - 0.025, "primary scale")
        expectClose(p.primaryOffsetX, 18, "primary offset")
        expectClose(p.primaryCornerRadius, 22, "primary corner radius")
        expectClose(p.scrimOpacity, 0.22, "scrim")
        #expect(p.sidebarIsVisible)
        expectContained(p)
    }

    @Test("live drag is clamped and monotonic")
    func dragClamping() {
        let width = 445.0
        let drawer = PhoneShellLayoutEngine.drawerWidth(containerWidth: width)
        let half = PhoneShellLayoutEngine.drawerProgress(drawerWidth: drawer,
                                                        drawerOpen: false,
                                                        translation: drawer / 2)
        expectClose(half, 0.5, "half-open")
        #expect(PhoneShellLayoutEngine.drawerProgress(drawerWidth: drawer,
                                                      drawerOpen: false,
                                                      translation: 10_000) == 1)
        #expect(PhoneShellLayoutEngine.drawerProgress(drawerWidth: drawer,
                                                      drawerOpen: true,
                                                      translation: -10_000) == 0)
        // Negative translation never opens a closed drawer.
        #expect(PhoneShellLayoutEngine.drawerProgress(drawerWidth: drawer,
                                                      drawerOpen: false,
                                                      translation: -120) == 0)
    }

    @Test("the scrim and accessibility-hidden state track progress only")
    func scrimTracksProgress() {
        let p0 = plan(foldedCover, drawerOpen: false)
        #expect(!p0.showsScrim)
        let p1 = plan(foldedCover, drawerOpen: true)
        #expect(p1.showsScrim)
        #expect(p1.scrimOpacity > 0 && p1.scrimOpacity <= 0.22)
    }
}

@Suite("Adaptive phone shell — unfolded inner display")
struct PhoneShellExpandedTests {
    @Test("expanded landscape gets a persistent readable sidebar")
    func expandedLandscape() {
        #expect(PhoneShellLayoutEngine.mode(containerWidth: expandedSafe.width,
                                            previouslyExpanded: false) == .expandedSidebar)
        let p = plan(expandedSafe)
        #expect(p.mode == .expandedSidebar)
        #expect(p.primaryFrame.x > 0)
        expectClose(p.primaryFrame.x, p.sidebarFrame.width, "primary starts after sidebar")
        expectClose(p.primaryFrame.x + p.primaryFrame.width, expandedSafe.width, "no gap")
        #expect(p.primaryFrame.width >= PhoneShellLayoutEngine.editorMinimumContentWidth)
        #expect(p.sidebarIsVisible)
        #expect(!p.showsScrim)
        #expect(p.primaryScale == 1)
        #expect(p.primaryOffsetX == 0)
        #expect(p.primaryCornerRadius == 0)
        expectContained(p)
    }

    @Test("opened inner portrait also uses the persistent sidebar")
    func innerPortrait() {
        // 585 pt safe width is past the 580 pt entry threshold and keeps a
        // 345 pt content column beside the 240 pt minimum sidebar.
        #expect(PhoneShellLayoutEngine.mode(containerWidth: narrowPortraitViewport.width,
                                            previouslyExpanded: false) == .expandedSidebar)
        let p = plan(narrowPortraitViewport)
        #expect(p.mode == .expandedSidebar)
        #expect(p.primaryFrame.width >= PhoneShellLayoutEngine.editorMinimumContentWidth)
        expectClose(p.sidebarFrame.width, 240, "portrait sidebar")
        expectContained(p)
        // The physical portrait size (before the system trailing rail) is
        // still expanded: no double-insetting is added by this model.
        #expect(PhoneShellLayoutEngine.mode(containerWidth: innerPortraitPhysical.width,
                                            previouslyExpanded: false) == .expandedSidebar)
        let physical = plan(innerPortraitPhysical)
        expectClose(physical.containerSize.width, innerPortraitPhysical.width, "container width")
        expectClose(physical.primaryFrame.maxX, innerPortraitPhysical.width, "primary maxX")
    }

    @Test("sidebar width stays clamped and leaves the editor room")
    func sidebarClamp() {
        for width in stride(from: 320.0, through: 1400.0, by: 20.0) {
            let sidebar = PhoneShellLayoutEngine.sidebarWidth(containerWidth: width,
                                                              preferredWidth: 280)
            if width >= PhoneShellLayoutEngine.expandedEnterWidth {
                #expect(sidebar >= PhoneShellLayoutEngine.sidebarMinimumWidth)
                #expect(sidebar <= PhoneShellLayoutEngine.sidebarMaximumWidth)
                #expect(width - sidebar >= PhoneShellLayoutEngine.editorMinimumContentWidth - 0.5,
                        "content too narrow at width \(width)")
            }
        }
        expectClose(PhoneShellLayoutEngine.sidebarWidth(containerWidth: 867,
                                                        preferredWidth: 280),
                    867 * 0.32, "fraction bound")
        expectClose(PhoneShellLayoutEngine.sidebarWidth(containerWidth: 867,
                                                        preferredWidth: 240),
                    240, "minimum")
        expectClose(PhoneShellLayoutEngine.sidebarWidth(containerWidth: 1200,
                                                        preferredWidth: 1_000),
                    360, "maximum")
    }

    @Test("collapsing the persistent sidebar keeps it mounted")
    func collapsedSidebarStaysMounted() {
        let p = plan(expandedSafe, sidebarVisible: false)
        #expect(p.mode == .expandedSidebar)
        #expect(p.primaryFrame == FoldableRect(x: 0, y: 0,
                                               width: expandedSafe.width,
                                               height: expandedSafe.height))
        #expect(p.sidebarFrame.width > 0)
        expectClose(p.sidebarFrame.x, -p.sidebarFrame.width, "mounted offscreen")
        #expect(!p.sidebarIsVisible)
        #expect(!p.showsScrim)
        expectContained(p)
    }
}

@Suite("Adaptive phone shell — width policy")
struct PhoneShellWidthPolicyTests {
    @Test("narrow and ordinary phone windows stay compact")
    func narrowStaysCompact() {
        for width in [0.0, 320, 393, 430, 440, 466, 500, 559] {
            #expect(PhoneShellLayoutEngine.mode(containerWidth: width,
                                                previouslyExpanded: false) == .compactDrawer,
                    "width \(width)")
        }
    }

    @Test("enter and exit thresholds use hysteresis")
    func hysteresis() {
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 580,
                                            previouslyExpanded: false) == .expandedSidebar)
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 579,
                                            previouslyExpanded: false) == .compactDrawer)
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 570,
                                            previouslyExpanded: true) == .expandedSidebar)
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 570,
                                            previouslyExpanded: false) == .compactDrawer)
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 560,
                                            previouslyExpanded: true) == .expandedSidebar)
        #expect(PhoneShellLayoutEngine.mode(containerWidth: 559,
                                            previouslyExpanded: true) == .compactDrawer)
    }

    @Test("a resized window transitions without changing the plan contract")
    func resizeTransitions() {
        let widths = [466.0, 560, 580, 669, 867, 951, 1200, 600, 466]
        for width in widths {
            let size = FoldableSize(width: width, height: 700)
            let p = plan(size)
            expectClose(p.containerSize.width, width, "container width")
            expectClose(p.primaryFrame.maxX, width,
                        "primary reaches the trailing edge")
            expectContained(p)
            #expect(p.primarySlot == .primary)
            #expect(p.sidebarSlot == .sidebar)
        }
    }

    @Test("non-finite geometry degrades to an empty compact plan")
    func degenerateInput() {
        let p = PhoneShellLayoutEngine.plan(
            containerWidth: .nan,
            containerHeight: .infinity,
            preferredSidebarWidth: .nan,
            drawerOpen: true,
            drawerTranslation: .nan,
            expandedSidebarVisible: true,
            previouslyExpanded: false)
        #expect(p.mode == .compactDrawer)
        #expect(p.primaryFrame.width == 0)
        #expect(p.sidebarFrame.width >= 0)
        #expect(p.drawerProgress.isFinite)
        #expect(p.primaryScale.isFinite)
    }
}

@Suite("Adaptive phone shell — placement purity")
struct PhoneShellPurityTests {
    @Test("the plan is a pure function of geometry — identity never enters it")
    func planIsPure() {
        let inputs: [(FoldableSize, Bool, Bool)] = [
            (foldedCover, false, false),
            (expandedSafe, false, true),
            (narrowPortraitViewport, false, true),
            (expandedSafe, true, false)
        ]
        for (size, open, visible) in inputs {
            let first = plan(size, drawerOpen: open, sidebarVisible: visible)
            let second = plan(size, drawerOpen: open, sidebarVisible: visible)
            #expect(first == second)
            #expect(first.primarySlot == .primary)
            #expect(first.sidebarSlot == .sidebar)
        }
        // Same width, different container height changes only the height.
        let tall = plan(FoldableSize(width: expandedSafe.width, height: expandedSafe.height + 100))
        let short = plan(expandedSafe)
        #expect(tall.mode == short.mode)
        expectClose(tall.primaryFrame.width, short.primaryFrame.width, "width unchanged")
        expectClose(tall.primaryFrame.height, short.primaryFrame.height + 100, "height follows")
    }
}
