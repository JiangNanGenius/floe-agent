// FloeAppTests — foldable scene capability state machine, mount latch and
// the stable workbench layout's actual host behavior.
//
// Pins the scene-owned detection state and the one-way mount latch: positive
// evidence during the unresolved boot window latches the foldable parents;
// the late-positive-after-deadline and late-positive-after-initial-nil
// sequences update capability ONLY — the same already-mounted ordinary
// parents cannot be replaced mid-scene. The custom Layout always places the
// primary, with or without a secondary (primary-only host size regression).
//
// NOTE: definitions only — full-App object compilation and UI runs belong to
// Main's combined verification (no Duo hardware is required or claimed).

#if canImport(UIKit)
import Foundation
import Testing
import SwiftUI
import FloeCore
@testable import FloeApp

@Suite("Foldable display scene state")
@MainActor
struct FoldableDisplayStateTests {
    @Test("a fresh scene starts unknown, unresolved and ordinary-latched")
    func freshUnknown() {
        let state = FoldableDisplayState()
        #expect(state.snapshot == .neutral)
        #expect(state.snapshot.capability == .unknown)
        #expect(!state.snapshot.isMountResolved)
        #expect(!state.snapshot.latchedFoldableMount)
    }

    @Test("positive hinge evidence during boot proves capability AND latches")
    func positiveEvidence() {
        let state = FoldableDisplayState()
        state.recordHinge(status: .partiallyOpen)
        #expect(state.snapshot.capability == .foldable)
        #expect(state.snapshot.hingeStatus == .partiallyOpen)
        #expect(state.snapshot.isMountResolved)
        #expect(state.snapshot.latchedFoldableMount)
    }

    @Test("division-region evidence during boot also latches")
    func regionEvidence() {
        let state = FoldableDisplayState()
        let region = FoldableRegion(kind: .division, x: 0.48, y: 0, width: 0.04, height: 1)
        state.record(divisionRegions: [region])
        #expect(state.snapshot.capability == .foldable)
        #expect(state.snapshot.latchedFoldableMount)
        // Empty region lists are absence-of-update, not negative evidence.
        let fresh = FoldableDisplayState()
        fresh.record(divisionRegions: [])
        #expect(fresh.snapshot.capability == .unknown)
        #expect(!fresh.snapshot.isMountResolved)
    }

    @Test("transient nil never loses proven capability or the latch")
    func transientNilSticky() {
        let state = FoldableDisplayState()
        state.recordHinge(status: .fullyOpen)
        state.recordHingeUnavailable()
        #expect(state.snapshot.capability == .foldable)
        #expect(state.snapshot.hingeStatus == .unknown)
        #expect(state.snapshot.latchedFoldableMount)
        state.recordHinge(status: .closed)
        #expect(state.snapshot.hingeStatus == .closed)
        state.recordNonFoldable()
        // Explicit negative evidence can never overwrite proven hardware.
        #expect(state.snapshot.capability == .foldable)
    }

    @Test("late positive AFTER the deadline: capability raises, latch stays ordinary")
    func latePositiveAfterDeadline() async {
        let state = FoldableDisplayState()
        state.startMountResolutionDeadline()
        try? await Task.sleep(nanoseconds: FoldableDisplayState.mountResolutionDeadlineNanoseconds
                              + 200_000_000)
        // Bounded resolution: mounted ordinary, honestly unknown capability.
        #expect(state.snapshot.isMountResolved)
        #expect(state.snapshot.capability == .unknown)
        #expect(!state.snapshot.latchedFoldableMount)
        // A late raise (evidence arrives after the ordinary tree mounted).
        state.recordHinge(status: .partiallyOpen)
        #expect(state.snapshot.capability == .foldable)
        #expect(!state.snapshot.latchedFoldableMount)
        // Parents read the latch: the mounted tree cannot be re-parented.
        #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: state.snapshot))
        #expect(!FoldableLayoutEngine.retainsSplitShell(snapshot: state.snapshot,
                                                        forceCompactForUITest: false,
                                                        mountResolved: true))
        // Settings display still sees the positive capability.
        #expect(state.snapshot.capability == .foldable)
    }

    @Test("late positive AFTER an attach-time nil: same freeze, no fabricated hardware")
    func latePositiveAfterInitialNil() {
        let state = FoldableDisplayState()
        state.recordHingeUnavailable()
        #expect(state.snapshot.isMountResolved)
        // The nil answer is honest unknown — never a permanent negative.
        #expect(state.snapshot.capability == .unknown)
        #expect(!state.snapshot.latchedFoldableMount)
        state.record(divisionRegions: [FoldableRegion(kind: .division, x: 0.48, y: 0,
                                                      width: 0.04, height: 1)])
        #expect(state.snapshot.capability == .foldable)
        #expect(!state.snapshot.latchedFoldableMount)
        #expect(!FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: state.snapshot))
    }

    @Test("the deadline cancels once the boot window proves evidence")
    func deadlineCancelledOnEarlyProof() async {
        let state = FoldableDisplayState()
        state.startMountResolutionDeadline()
        state.recordHinge(status: .closed)
        try? await Task.sleep(nanoseconds: FoldableDisplayState.mountResolutionDeadlineNanoseconds
                              + 200_000_000)
        // The expired deadline must not demote the latched foldable mount.
        #expect(state.snapshot.latchedFoldableMount)
        #expect(state.snapshot.capability == .foldable)
    }

    @Test("non-foldable marking only applies while unproven")
    func nonFoldableBeforeProof() {
        let state = FoldableDisplayState()
        state.recordNonFoldable()
        #expect(state.snapshot.capability == .nonFoldable)
        #expect(!state.snapshot.isMountResolved)
        state.recordHinge(status: .closed)
        #expect(state.snapshot.capability == .foldable)
        #expect(state.snapshot.latchedFoldableMount)
    }

    @Test("capability is scene-owned: a new instance starts neutral again")
    func noCrossHardwarePersistence() {
        let first = FoldableDisplayState()
        first.recordHinge(status: .partiallyOpen)
        let second = FoldableDisplayState()
        #expect(second.snapshot == .neutral)
    }

    @Test("environment default is neutral without any provider")
    func environmentDefault() {
        #expect(EnvironmentValues().foldableDisplay == .neutral)
    }

    @Test("foldable row visibility follows positive capability, not the latch")
    func rowVisibilityPredicate() {
        // GeneralSettingsView gates on `capability == .foldable` exactly.
        #expect(FoldableDisplaySnapshot.neutral.capability != .foldable)
        #expect(FoldableDisplaySnapshot(capability: .nonFoldable).capability != .foldable)
        // A late raise still shows the row even though parents stay mounted
        // ordinary for the current scene (next scene adopts the layout).
        #expect(FoldableDisplaySnapshot(capability: .foldable,
                                       isMountResolved: true,
                                       latchedFoldableMount: false)
                .capability == .foldable)
    }

    @Test("regression identifiers are pinned")
    func identifiers() {
        #expect(FoldableLayoutIdentifiers.settingsToggle
                == "settings.general.foldable_adaptation")
        #expect(FoldableLayoutIdentifiers.notesAssistantInlineColumn
                == "notes.assistant.inline.column")
        #expect(FoldableLayoutIdentifiers.notesAssistantInlineBelow
                == "notes.assistant.inline.below")
        #expect(FoldableLayoutIdentifiers.notesAssistantSheet
                == "notes.assistant.sheet")
    }
}

@Suite("Foldable workbench layout placement")
@MainActor
struct FoldableWorkbenchLayoutTests {
    private let container = FoldableSize(width: 800, height: 600)

    @Test("a primary-only plan still places the document at the full rect")
    func primaryOnlyPlan() {
        for mode in [FoldableWorkbenchMode.hidden,
                     .sideBySide(secondaryWidth: 300, gapWidth: 0),
                     .contentAbove(secondaryHeight: 200, gapHeight: 90),
                     .compactOverlay(secondaryHeight: 300, bottomInset: 34)] {
            let plan = FoldableWorkbenchLayout.placementPlan(mode: mode,
                                                             containerSize: container,
                                                             subviewCount: 1)
            #expect(plan.count == 1)
            #expect(plan[0].width > 0)
            #expect(plan[0].height > 0)
            #expect(mode == .hidden
                    ? plan[0] == FoldableRect(x: 0, y: 0, width: 800, height: 600)
                    : plan[0].maxX <= 800 && plan[0].maxY <= 600)
        }
    }

    @Test("two subviews place both, in stable order")
    func twoSubviewPlan() {
        let plan = FoldableWorkbenchLayout.placementPlan(
            mode: .sideBySide(secondaryWidth: 300, gapWidth: 12),
            containerSize: container,
            subviewCount: 2)
        #expect(plan.count == 2)
        #expect(plan[0].x == 0)
        #expect(plan[1].x == 500)
    }

    @Test("real host lays out the assistant-less document with non-zero bounds")
    func primaryOnlyHostLayout() async throws {
        @MainActor final class SizeProbe {
            var size: CGSize = .zero
        }
        let probe = SizeProbe()
        let host = UIHostingController(rootView:
            FoldableWorkbenchLayout(mode: .hidden,
                                    containerSize: container) {
                Color.red
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in Task { @MainActor in probe.size = size } }
            })
        host.beginAppearanceTransition(true, animated: false)
        host.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.view.layoutIfNeeded()
        host.endAppearanceTransition()
        // Allow the SwiftUI geometry action to deliver (bounded, not a race
        // on layout: two runloop hops).
        for _ in 0..<20 where probe.size == .zero {
            try await Task.sleep(nanoseconds: 10_000_000)
            host.view.layoutIfNeeded()
        }
        #expect(probe.size == CGSize(width: 800, height: 600))
    }
}
#endif
