// FloeCoreTests — foldable layout engine (system-detected hinge hardware).
//
// Pins the pure decision layer: unknown/nonFoldable/positive capability and
// transient nil behave per spec; the preference defaults enabled; an explicit
// opt-out still uses the ONE stable foldable parent but drops region-driven
// placement; ordinary devices keep the historical HStack/sheet rule exactly;
// synthetic compact/expanded/book/tabletop regions (with keyboard/safe-area
// bottoms) yield contained, reachable rects inside the same mount positions;
// the mount gate is bounded and one-way. Hinge status/angle never drives
// layout — geometry and system regions do.

import Foundation
import Testing
@testable import FloeCore

private let resolvedFoldable = FoldableDisplaySnapshot(capability: .foldable,
                                                       hingeStatus: .partiallyOpen,
                                                       isMountResolved: true,
                                                       latchedFoldableMount: true)
private let unfolded = FoldableDisplaySnapshot(capability: .foldable,
                                               hingeStatus: .fullyOpen,
                                               isMountResolved: true,
                                               latchedFoldableMount: true)
private let closedFoldable = FoldableDisplaySnapshot(capability: .foldable,
                                                     hingeStatus: .closed,
                                                     isMountResolved: true,
                                                     latchedFoldableMount: true)
private let unresolvedFoldable = FoldableDisplaySnapshot(capability: .foldable,
                                                         hingeStatus: .partiallyOpen,
                                                         isMountResolved: false,
                                                         latchedFoldableMount: false)
/// Late positive raise: capability arrived AFTER an ordinary mount decision
/// (deadline or attach-time nil). Settings may show it; parents may not swap.
private let latePositive = FoldableDisplaySnapshot(capability: .foldable,
                                                   hingeStatus: .partiallyOpen,
                                                   isMountResolved: true,
                                                   latchedFoldableMount: false)
private let unknown = FoldableDisplaySnapshot.neutral
private let nonFoldable = FoldableDisplaySnapshot(capability: .nonFoldable,
                                                  hingeStatus: .unknown,
                                                  isMountResolved: true,
                                                  latchedFoldableMount: false)
/// Ordinary-latched scene before any late raise (deadline or attach-nil).
private let ordinaryLatched = FoldableDisplaySnapshot(capability: .unknown,
                                                      hingeStatus: .unknown,
                                                      isMountResolved: true,
                                                      latchedFoldableMount: false)

/// A horizontal tabletop band at 45%...55% height across the full width.
private let tabletopBand = FoldableRegion(kind: .occlusion, x: 0, y: 0.45,
                                          width: 1, height: 0.10)
/// A vertical book band at 48%...52% width down the full height.
private let bookBand = FoldableRegion(kind: .division, x: 0.48, y: 0,
                                      width: 0.04, height: 1)
private let unfoldedSize = FoldableSize(width: 1200, height: 900)
private let foldedSize = FoldableSize(width: 402, height: 874)

private func foldableMode(_ placement: FoldableWorkbenchPlacement) -> FoldableWorkbenchMode? {
    if case .foldable(let mode) = placement { return mode }
    return nil
}

private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.01) {
    #expect(abs(actual - expected) < tolerance, "expected \(expected), got \(actual)")
}

private func expectSideBySide(_ mode: FoldableWorkbenchMode?,
                              secondaryWidth: Double, gapWidth: Double) {
    if case .sideBySide(let w, let g)? = mode {
        expectClose(w, secondaryWidth)
        expectClose(g, gapWidth)
    } else {
        Issue.record("expected .sideBySide, got \(String(describing: mode))")
    }
}

private func expectContentAbove(_ mode: FoldableWorkbenchMode?,
                                secondaryHeight: Double, gapHeight: Double) {
    if case .contentAbove(let h, let g)? = mode {
        expectClose(h, secondaryHeight)
        expectClose(g, gapHeight)
    } else {
        Issue.record("expected .contentAbove, got \(String(describing: mode))")
    }
}

private func expectOverlay(_ mode: FoldableWorkbenchMode?,
                           secondaryHeight: Double, bottomInset: Double) {
    if case .compactOverlay(let h, let b)? = mode {
        expectClose(h, secondaryHeight)
        expectClose(b, bottomInset)
    } else {
        Issue.record("expected .compactOverlay, got \(String(describing: mode))")
    }
}

@Suite("Foldable capability decisions")
struct FoldableCapabilityDecisionTests {
    @Test("neutral snapshot defaults unknown/non-foldable/unresolved")
    func defaults() {
        #expect(FoldableDisplaySnapshot.neutral.capability == .unknown)
        #expect(FoldableDisplaySnapshot.neutral.hingeStatus == .unknown)
        #expect(!FoldableDisplaySnapshot.neutral.isMountResolved)
        #expect(!FoldableDisplaySnapshot.neutral.isPositivelyFoldable)
        #expect(!FoldableLayoutEngine.foldAdaptationActive(snapshot: unknown,
                                                           adaptationEnabled: true))
        #expect(!FoldableLayoutEngine.foldAdaptationActive(snapshot: nonFoldable,
                                                           adaptationEnabled: true))
        #expect(FoldableLayoutEngine.foldAdaptationActive(snapshot: resolvedFoldable,
                                                          adaptationEnabled: true))
        #expect(!FoldableLayoutEngine.foldAdaptationActive(snapshot: resolvedFoldable,
                                                           adaptationEnabled: false))
    }

    @Test("layout preference defaults enabled; settings model round-trips both states")
    func defaultEnabled() {
        #expect(LayoutSettings().foldableAdaptationEnabled)
        var off = LayoutSettings()
        off.foldableAdaptationEnabled = false
        #expect(!off.foldableAdaptationEnabled)
    }

    @Test("unknown devices keep ordinary workbench/canvas/shell behavior at any width")
    func unknownIsOrdinary() {
        for snapshot in [unknown, nonFoldable] {
            let wide = FoldableLayoutEngine.workbenchPlacement(
                assistantVisible: true, width: 1200, containerSize: unfoldedSize,
                snapshot: snapshot, adaptationEnabled: true,
                previouslySideBySide: false, regions: [tabletopBand],
                bottomSafeInset: 34)
            #expect(wide == .ordinary, "\(snapshot)")
            #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
                snapshot: snapshot, adaptationEnabled: true,
                width: 1200, previouslyExpanded: false, isPhoneIdiom: true))
            #expect(!FoldableLayoutEngine.retainsSplitShell(
                snapshot: snapshot, forceCompactForUITest: false, mountResolved: true))
            #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: snapshot))
        }
    }

    @Test("the stable parent requires the FROZEN latch, never live capability")
    func parentNeedsLatch() {
        #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: unresolvedFoldable))
        #expect(FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: resolvedFoldable))
        // Posture is NOT a parent input (rects only).
        #expect(FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: closedFoldable))
        // A late positive raise after an ordinary mount can NEVER re-parent.
        #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: latePositive))
        #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: ordinaryLatched))
    }

    @Test("a late positive raise never swaps the mounted root shell mid-scene")
    func latePositiveKeepsMountedShell() {
        #expect(!FoldableLayoutEngine.retainsSplitShell(snapshot: latePositive,
                                                        forceCompactForUITest: false,
                                                        mountResolved: true))
        #expect(!FoldableLayoutEngine.retainsSplitShell(snapshot: ordinaryLatched,
                                                        forceCompactForUITest: false,
                                                        mountResolved: true))
        // Capability itself still raises for settings display.
        #expect(latePositive.isPositivelyFoldable)
        // The next SCENE resolving with this evidence latches foldable;
        #expect(FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: resolvedFoldable))
    }

    @Test("transient unknown hinge status on proven hardware still adapts")
    func transientNilStillFoldable() {
        let afterNil = FoldableDisplaySnapshot(capability: .foldable,
                                               hingeStatus: .unknown,
                                               isMountResolved: true,
                                               latchedFoldableMount: true)
        #expect(FoldableLayoutEngine.foldAdaptationActive(snapshot: afterNil,
                                                          adaptationEnabled: true))
        #expect(FoldableLayoutEngine.retainsSplitShell(snapshot: afterNil,
                                                       forceCompactForUITest: false,
                                                       mountResolved: true))
    }

    @Test("closed status never fabricates capability")
    func noFakeCapability() {
        #expect(!FoldableDisplaySnapshot(capability: .unknown,
                                         hingeStatus: .closed).isPositivelyFoldable)
        #expect(!FoldableDisplaySnapshot(capability: .nonFoldable,
                                         hingeStatus: .fullyOpen).isPositivelyFoldable)
    }
}

@Suite("Foldable mount gate (initial decision, bounded, one-way)")
struct FoldableMountGateTests {
    @Test("boot chrome shows while persistence or the mount decision is pending")
    func bootGate() {
        #expect(FoldableMountGate.showsBootChrome(persistenceReady: false, mountResolved: false))
        #expect(FoldableMountGate.showsBootChrome(persistenceReady: true, mountResolved: false))
        #expect(!FoldableMountGate.showsBootChrome(persistenceReady: true, mountResolved: true))
    }

    @Test("entry routes deliver only after the shell choice is frozen")
    func routeGate() {
        #expect(!FoldableMountGate.entryRoutesReady(persistenceReady: true, mountResolved: false))
        #expect(!FoldableMountGate.entryRoutesReady(persistenceReady: false, mountResolved: true))
        #expect(FoldableMountGate.entryRoutesReady(persistenceReady: true, mountResolved: true))
    }

    @Test("resolution is one-way: both gates stabilize once resolved")
    func oneWay() {
        // A later capability raise must not re-open the gates: the booted
        // shell/container stays as mounted for the scene (no late remount).
        #expect(!FoldableMountGate.showsBootChrome(persistenceReady: true, mountResolved: true))
        #expect(FoldableMountGate.entryRoutesReady(persistenceReady: true, mountResolved: true))
    }
}

@Suite("Foldable stable root shell")
struct FoldableShellTests {
    @Test("proven foldable keeps the split shell regardless of width or opt-out")
    func shellRetained() {
        #expect(FoldableLayoutEngine.retainsSplitShell(snapshot: closedFoldable,
                                                       forceCompactForUITest: false,
                                                       mountResolved: true))
        #expect(FoldableLayoutEngine.retainsSplitShell(snapshot: unfolded,
                                                       forceCompactForUITest: false,
                                                       mountResolved: true))
    }

    @Test("UI test compact forcing keeps the historical drawer shell")
    func forceCompactWins() {
        #expect(!FoldableLayoutEngine.retainsSplitShell(snapshot: resolvedFoldable,
                                                        forceCompactForUITest: true,
                                                        mountResolved: true))
    }

    @Test("the shell choice waits for the frozen mount resolution")
    func unresolvedKeepsOrdinaryBoot() {
        #expect(!FoldableLayoutEngine.retainsSplitShell(snapshot: unresolvedFoldable,
                                                        forceCompactForUITest: false,
                                                        mountResolved: false))
    }

    @Test("root shell selection is frozen: no live width/size-class can swap it")
    func shellIndependentOfLiveGeometry() {
        // The selection inputs are the frozen latch, idiom and the UITest
        // forcing flags ONLY. Geometry never enters, so crossing compact/
        // regular (rotation, Stage Manager resize, unfold on an ordinary-
        // latched scene) cannot replace the outermost mounted tree.
        let pad = FoldableLayoutEngine.selectRootShell(
            snapshot: ordinaryLatched, isPadIdiom: true, mountResolved: true,
            forceRegularForUITest: false, forceCompactForUITest: false)
        #expect(pad == .splitView)
        let phone = FoldableLayoutEngine.selectRootShell(
            snapshot: ordinaryLatched, isPadIdiom: false, mountResolved: true,
            forceRegularForUITest: false, forceCompactForUITest: false)
        #expect(phone == .phoneDrawer)
        // A late positive raise (latch false) keeps the phone drawer mounted.
        #expect(FoldableLayoutEngine.selectRootShell(
            snapshot: latePositive, isPadIdiom: false, mountResolved: true,
            forceRegularForUITest: false, forceCompactForUITest: false) == .phoneDrawer)
        // The first positive latch uses the split shell from the initial mount.
        #expect(FoldableLayoutEngine.selectRootShell(
            snapshot: resolvedFoldable, isPadIdiom: false, mountResolved: true,
            forceRegularForUITest: false, forceCompactForUITest: false) == .splitView)
        // Determinism across "geometry changes": same inputs, same shell.
        for _ in 0..<4 {
            #expect(FoldableLayoutEngine.selectRootShell(
                snapshot: resolvedFoldable, isPadIdiom: false, mountResolved: true,
                forceRegularForUITest: false, forceCompactForUITest: false) == .splitView)
            #expect(FoldableLayoutEngine.selectRootShell(
                snapshot: ordinaryLatched, isPadIdiom: false, mountResolved: true,
                forceRegularForUITest: false, forceCompactForUITest: false) == .phoneDrawer)
        }
        // UITest forcing coverage preserved exactly.
        #expect(FoldableLayoutEngine.selectRootShell(
            snapshot: ordinaryLatched, isPadIdiom: false, mountResolved: true,
            forceRegularForUITest: true, forceCompactForUITest: true) == .splitView)
        #expect(FoldableLayoutEngine.selectRootShell(
            snapshot: resolvedFoldable, isPadIdiom: true, mountResolved: true,
            forceRegularForUITest: false, forceCompactForUITest: true) == .phoneDrawer)
    }
}

@Suite("Foldable workbench placement")
struct FoldableWorkbenchPlacementTests {
    @Test("ordinary wide iPad keeps the exact historical column rule")
    func ordinaryPadRule() {
        #expect(FoldableLayoutEngine.ordinaryAssistantUsesColumn(isPadIdiom: true, width: 850))
        #expect(!FoldableLayoutEngine.ordinaryAssistantUsesColumn(isPadIdiom: true, width: 849.9))
        #expect(!FoldableLayoutEngine.ordinaryAssistantUsesColumn(isPadIdiom: false, width: 1200))
    }

    @Test("closed assistant collapses the secondary and creates nothing")
    func hiddenWhenClosed() {
        let placement = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: false, width: 1200, containerSize: unfoldedSize,
            snapshot: resolvedFoldable, adaptationEnabled: true,
            previouslySideBySide: true)
        #expect(placement == .foldable(mode: .hidden))
        let rects = FoldableLayoutEngine.rects(for: .hidden, containerSize: unfoldedSize)
        #expect(rects.secondary.width == 0)
        #expect(rects.primary.width == unfoldedSize.width)
    }

    @Test("folded with the assistant open overlays the SAME secondary (never a sheet)")
    func compactOverlay() {
        let placement = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 402, containerSize: foldedSize,
            snapshot: closedFoldable, adaptationEnabled: true,
            previouslySideBySide: false, bottomSafeInset: 34)
        #expect(placement == .foldable(mode: .compactOverlay(secondaryHeight: 524.4,
                                                             bottomInset: 34)))
        if case .foldable(let mode) = placement {
            let rects = FoldableLayoutEngine.rects(for: mode, containerSize: foldedSize)
            #expect(rects.primary == FoldableRect(x: 0, y: 0, width: 402, height: 874))
            #expect(rects.secondary.maxY <= 874 - 34 + 0.5)
            #expect(rects.secondary.x >= 0)
        }
    }

    @Test("preference off keeps the stable parent with proportional placement only")
    func optOutProportional() {
        let placement = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: resolvedFoldable, adaptationEnabled: false,
            previouslySideBySide: false,
            regions: [tabletopBand], bottomSafeInset: 0)
        // Regions are ignored while off — ordinary adaptive geometry.
        #expect(placement == .foldable(mode: .sideBySide(secondaryWidth: 432, gapWidth: 0)))
    }

    @Test("expanded uses side-by-side; tabletop regions place content above, assistant below")
    func postures() {
        let expanded = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: unfolded, adaptationEnabled: true, previouslySideBySide: false)
        #expect(expanded == .foldable(mode: .sideBySide(secondaryWidth: 432, gapWidth: 0)))
        let tabletop = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: resolvedFoldable, adaptationEnabled: true,
            previouslySideBySide: true, regions: [tabletopBand])
        #expect(tabletop == .foldable(mode: .contentAbove(secondaryHeight: 405, gapHeight: 90)))
        let book = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: unfolded, adaptationEnabled: true,
            previouslySideBySide: true, regions: [bookBand])
        // The hinge occupies x=576...624, so the right region is 576 wide.
        #expect(book == .foldable(mode: .sideBySide(secondaryWidth: 576, gapWidth: 48)))
        let rects = FoldableLayoutEngine.rects(
            for: .sideBySide(secondaryWidth: 576, gapWidth: 48),
            containerSize: unfoldedSize)
        #expect(rects.primary.maxX == 576)
        #expect(rects.secondary.x == 624)
        #expect(rects.secondary.maxX == 1200)
    }

    @Test("side-by-side hysteresis prevents churn across the width threshold")
    func hysteresis() {
        let rising = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 820, containerSize: FoldableSize(width: 820, height: 900),
            snapshot: unfolded, adaptationEnabled: true, previouslySideBySide: false)
        #expect(rising == .foldable(mode: .compactOverlay(secondaryHeight: 540, bottomInset: 0)))
        let holding = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 820, containerSize: FoldableSize(width: 820, height: 900),
            snapshot: unfolded, adaptationEnabled: true, previouslySideBySide: true)
        #expect(holding == .foldable(mode: .sideBySide(secondaryWidth: 360, gapWidth: 0)))
        let dropped = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 800, containerSize: FoldableSize(width: 800, height: 900),
            snapshot: unfolded, adaptationEnabled: true, previouslySideBySide: true)
        #expect(dropped == .foldable(mode: .compactOverlay(secondaryHeight: 540, bottomInset: 0)))
    }

    @Test("hinge status alone never changes placement (geometry/regions decide)")
    func statusDoesNotDriveLayout() {
        let a = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: closedFoldable, adaptationEnabled: true, previouslySideBySide: true)
        let b = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: true, width: 1200, containerSize: unfoldedSize,
            snapshot: unfolded, adaptationEnabled: true, previouslySideBySide: true)
        #expect(a == b)
    }
}

@Suite("Foldable workbench rects")
struct FoldableWorkbenchRectTests {
    @Test("side-by-side keeps the hinge gap empty and both panels contained")
    func sideBySideRects() {
        let rects = FoldableLayoutEngine.rects(
            for: .sideBySide(secondaryWidth: 552, gapWidth: 48),
            containerSize: unfoldedSize)
        #expect(rects.primary.x == 0)
        #expect(rects.primary.maxX == 1200 - 552 - 48)
        #expect(rects.secondary.x == 1200 - 552)
        #expect(unfoldedSize.width >= rects.secondary.maxX)
        let container = FoldableRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(container.contains(rects.primary))
        #expect(container.contains(rects.secondary))
    }

    @Test("tabletop contentAbove separates primary and secondary around the band")
    func contentAboveRects() {
        let rects = FoldableLayoutEngine.rects(
            for: .contentAbove(secondaryHeight: 405, gapHeight: 90),
            containerSize: unfoldedSize)
        let container = FoldableRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(container.contains(rects.primary))
        #expect(container.contains(rects.secondary))
        // The band stays empty between the two regions.
        #expect(rects.primary.maxY <= rects.secondary.y - 90 + 1)
        #expect(rects.secondary.y == 900 - 405)
    }

    @Test("compact overlay sits inside the container above the keyboard inset")
    func overlayRects() {
        let rects = FoldableLayoutEngine.rects(
            for: .compactOverlay(secondaryHeight: 524.4, bottomInset: 34),
            containerSize: foldedSize)
        #expect(rects.primary == FoldableRect(x: 0, y: 0, width: 402, height: 874))
        #expect(abs(rects.secondary.maxY - (874 - 34)) < 1)
        #expect(rects.secondary.y > 0)
    }

    @Test("oversized requests clamp so both rects remain contained")
    func clamping() {
        let rects = FoldableLayoutEngine.rects(
            for: .sideBySide(secondaryWidth: 5000, gapWidth: 5000),
            containerSize: unfoldedSize)
        let container = FoldableRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(container.contains(rects.primary))
        #expect(container.contains(rects.secondary))
        let overlay = FoldableLayoutEngine.rects(
            for: .compactOverlay(secondaryHeight: 5000, bottomInset: 5000),
            containerSize: unfoldedSize)
        #expect(container.contains(overlay.secondary))
    }
}

@Suite("Foldable canvas chrome")
struct FoldableCanvasChromeTests {
    @Test("ordinary iPhone/idiom rule is byte-for-byte the historical decision")
    func ordinaryRulePreserved() {
        for snapshot in [unknown, nonFoldable] {
            #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
                snapshot: snapshot, adaptationEnabled: true,
                width: 1100, previouslyExpanded: false, isPhoneIdiom: true))
            #expect(!FoldableLayoutEngine.canvasUsesCompactChrome(
                snapshot: snapshot, adaptationEnabled: true,
                width: 700, previouslyExpanded: false, isPhoneIdiom: false))
            #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
                snapshot: snapshot, adaptationEnabled: true,
                width: 619.9, previouslyExpanded: false, isPhoneIdiom: false))
        }
        // Opt-out: proven foldable with the switch off → ordinary layout.
        #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
            snapshot: unfolded, adaptationEnabled: false,
            width: 1100, previouslyExpanded: false, isPhoneIdiom: true))
    }

    @Test("unfolded foldable phone reaches the expanded workbench chrome")
    func expandedPhone() {
        #expect(!FoldableLayoutEngine.canvasUsesCompactChrome(
            snapshot: unfolded, adaptationEnabled: true,
            width: 1100, previouslyExpanded: false, isPhoneIdiom: true))
        #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
            snapshot: unfolded, adaptationEnabled: true,
            width: 600, previouslyExpanded: false, isPhoneIdiom: true))
    }

    @Test("chrome hysteresis band avoids oscillation during a fold animation")
    func chromeHysteresis() {
        #expect(!FoldableLayoutEngine.canvasUsesCompactChrome(
            snapshot: resolvedFoldable, adaptationEnabled: true,
            width: 600, previouslyExpanded: true, isPhoneIdiom: true))
        #expect(FoldableLayoutEngine.canvasUsesCompactChrome(
            snapshot: resolvedFoldable, adaptationEnabled: true,
            width: 560, previouslyExpanded: true, isPhoneIdiom: true))
    }
}

@Suite("Foldable region placement")
struct FoldableRegionPlacementTests {
    @Test("tabletop band splits above/below and keeps content out of the hinge")
    func tabletopSplit() {
        let parts = FoldableLayoutEngine.tabletopRegions(regions: [tabletopBand],
                                                         containerSize: unfoldedSize)
        #expect(parts != nil)
        if let parts {
            #expect(abs(parts.band.y - 405) < 1)
            #expect(abs(parts.above.height - 405) < 1)
            #expect(abs(parts.below.height - 405) < 1)
            let insets = FoldableLayoutEngine.contentAvoidanceInsets(
                regions: [tabletopBand], containerSize: unfoldedSize)
            #expect(abs(insets.bottom - (900 - 405)) < 1)
            let content = FoldableRect(x: 0, y: 0,
                                       width: unfoldedSize.width,
                                       height: unfoldedSize.height - insets.bottom)
            #expect(parts.above.contains(content))
        }
    }

    @Test("synthetic tabletop controls stay reachable inside the lower region")
    func controlsContained() {
        let keyboardInset = 80.0
        let frame = FoldableLayoutEngine.tabletopControlFrame(
            controlWidth: 420, controlHeight: 56,
            regions: [tabletopBand],
            containerSize: unfoldedSize,
            bottomSafeInset: keyboardInset)
        #expect(frame != nil)
        if let parts = FoldableLayoutEngine.tabletopRegions(regions: [tabletopBand],
                                                            containerSize: unfoldedSize),
           let frame {
            #expect(parts.below.contains(frame))
            #expect(frame.maxY <= unfoldedSize.height - keyboardInset + 0.5)
        }
    }

    @Test("book pose splits left/right and never classifies as tabletop")
    func bookPose() {
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [bookBand],
                                                     containerSize: unfoldedSize) == nil)
        let book = FoldableLayoutEngine.bookSplit(regions: [bookBand],
                                                  containerSize: unfoldedSize)
        #expect(book != nil)
        if let book {
            #expect(abs(book.band.width - 48) < 1)
            #expect(abs(book.left.width - 576) < 1)
            #expect(abs(book.right.width - 576) < 1)
        }
        #expect(FoldableLayoutEngine.contentAvoidanceInsets(regions: [bookBand],
                                                            containerSize: unfoldedSize).isZero)
    }

    @Test("edge bands and thin unusable splits never trigger tabletop")
    func invalidBands() {
        let edgeBand = FoldableRegion(kind: .division, x: 0, y: 0.05, width: 1, height: 0.1)
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [edgeBand],
                                                     containerSize: unfoldedSize) == nil)
        let fatBand = FoldableRegion(kind: .division, x: 0, y: 0.3, width: 1, height: 0.4)
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [fatBand],
                                                     containerSize: unfoldedSize) == nil)
        let narrowBand = FoldableRegion(kind: .division, x: 0.1, y: 0.45, width: 0.3, height: 0.1)
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [narrowBand],
                                                     containerSize: unfoldedSize) == nil)
        let inactive = FoldableRegion(kind: .division, x: 0, y: 0.45, width: 1, height: 0.1,
                                      isActive: false)
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [inactive],
                                                     containerSize: unfoldedSize) == nil)
    }

    @Test("zero or inverted containers are safe")
    func degenerate() {
        #expect(FoldableLayoutEngine.tabletopRegions(regions: [tabletopBand],
                                                     containerSize: .zero) == nil)
        #expect(FoldableLayoutEngine.bookSplit(regions: [bookBand],
                                               containerSize: .zero) == nil)
        #expect(FoldableLayoutEngine.contentAvoidanceInsets(regions: [],
                                                            containerSize: unfoldedSize).isZero)
    }
}
