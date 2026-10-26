// FloeAppTests — composer soft-wrap and the overflow → expand-control chain.
//
// Behavior regressions for the repair, driven through the REAL production
// seams: the same `configure` setup `makeUIView` performs, the live view's
// own `layoutSubviews` laid-out-width notification, the delegate keystroke
// path, the coalesced deferred host report and the actual NSTextContainer /
// NSLayoutManager the field wraps inside. The pinned contract:
// - the verdict gates `composer.expand` on real TextKit overflow at the
//   width the field is ACTUALLY laid out at — never a character count;
// - deleting text back under the cap, or widening the slot, re-reports
//   false even when no SwiftUI sizing pass runs at all;
// - a verdict measured against older text never reaches the host, and the
//   next real pass re-derives the new draft's truth at the SAME laid-out
//   width (conversation switch inside the shared field view);
// - flipping the scroll state through `applyComposerScrollState` keeps the
//   live container width-tracked, so long CJK / English / unbroken-URL runs
//   wrap inside the bounded width instead of running off to the right (a
//   raw `isScrollEnabled` write is UIKit's untracked reconfiguration — the
//   run-off defect — and never a state the composer leaves the container
//   in);
// - the one shared layout rule keeps the existing line budget
//   (6 compact / 8 regular), the one-third page-height cap and the 44pt
//   resting minimum.
// The view's delegate and its laid-out-width closure hold the coordinator
// weakly (production semantics), so every fixture owns field + view +
// coordinator together and nothing early-releases mid-drain.
// Device feel (keyboard, rotation, dynamic type on the real hosting rows,
// and the updateUIView intrinsic hop) remains Simulator acceptance owned
// by Main after source freeze.

#if canImport(UIKit)
import Testing
import UIKit
import SwiftUI
import FloeCore
@testable import FloeApp

@Suite("FloeApp.ComposerOverflow")
@MainActor
struct ComposerOverflowRegressionTests {

    private static let cjkDraft =
        String(repeating: "这是一段用于验证软换行与溢出判定的中文草稿。", count: 8)
    private static let urlDraft =
        String(repeating: "https://example.com/very/long/path/without-any-breakable-space-characters-0123456789",
               count: 4)

    /// Strong ownership for the whole chain: the representable snapshot,
    /// the live view and the coordinator that the view references only
    /// weakly. One `let` keeps all three alive through every async drain.
    private struct Fixture {
        let field: ComposerReturnField
        let view: HardwareReturnTextView
        let coordinator: ComposerReturnField.Coordinator
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// The production setup (`configure`, exactly what `makeUIView` runs)
    /// followed by a real layout at `width`, so the laid-out-width
    /// notification, the detached memoized measurement and the coalesced
    /// report hop are all exercised, not re-stated.
    private func laidOutField(
        text: String,
        width: CGFloat,
        reports: @escaping (Bool) -> Void
    ) -> Fixture {
        let field = ComposerReturnField(
            text: .constant(text),
            placeholder: "composer.test.placeholder",
            canSend: true,
            lineLimit: 1...8,
            maxHeightBudget: nil,
            onOverflowChange: reports,
            onReturn: {}
        )
        let coordinator = field.makeCoordinator()
        let view = HardwareReturnTextView()
        field.configure(view: view, coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 44)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return Fixture(field: field, view: view, coordinator: coordinator)
    }

    @Test("A long CJK draft laid out at the row width overflows and reports true")
    func longDraftAtLaidOutWidthReportsOverflow() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.cjkDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        // Layout alone (no SwiftUI sizing pass in this test) delivered the
        // verdict — the old proposal-only source could deliver nothing and
        // `composer.expand` never appeared.
        #expect(reports == [true])
        #expect(fixture.view.isScrollEnabled)
        // The LIVE container still wraps at the bounded width: the real
        // TextKit output can never run off to the right of the slot.
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        let used = fixture.view.layoutManager.usedRect(for: fixture.view.textContainer)
        #expect(used.width <= 320 + 0.5)
        #expect(used.height > 0)
        // The scroll flip re-asserted width tracking on the live container.
        #expect(fixture.view.textContainer.widthTracksTextView)
        withExtendedLifetime(fixture) {}
    }

    @Test("Deleting back under the cap re-reports false through the keystroke path")
    func deletingTextHidesOverflowAgain() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.cjkDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [true])
        // The real delegate callback re-derives the verdict at the laid-out
        // width: the freshest possible truth for the host control.
        fixture.view.text = "短草稿"
        fixture.coordinator.textViewDidChange(fixture.view)
        await drainMainQueue()
        #expect(reports == [true, false])
        #expect(!fixture.view.isScrollEnabled)
        #expect(fixture.view.textContainer.widthTracksTextView)
        withExtendedLifetime(fixture) {}
    }

    @Test("The verdict follows the laid-out width, never a character count")
    func verdictFollowsRealWidthNotLength() {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.cjkDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        // The same characters measured by the real container at two widths:
        // overflow at the narrow slot, no overflow at the wide one. A
        // length heuristic could never produce this pair.
        let narrow = fixture.field.verdict(at: 320, textView: fixture.view,
                                           coordinator: fixture.coordinator)
        let wide = fixture.field.verdict(at: 640, textView: fixture.view,
                                         coordinator: fixture.coordinator)
        #expect(narrow.scrolls)
        #expect(!wide.scrolls)
        // The overflowing narrow slot reports its cap; the fitting wide
        // slot reports the actual natural height — always the smaller block.
        #expect(narrow.height > wide.height)
        withExtendedLifetime(fixture) {}
    }

    @Test("An unbroken URL-style run soft-wraps inside the live bounded container")
    func unbrokenRunWrapsAtBoundedWidth() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.urlDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports.last == true)
        // Measure the pure inline (non-scrolling) wrapping state through
        // the same seam the deferred overflow delivery flips. A raw
        // `isScrollEnabled` write lets UIKit reconfigure the container
        // untracked, so the measured block collapses to a single unbounded
        // line — that raw UIKit state is the run-off defect itself, not a
        // state the composer ever leaves the container in.
        fixture.view.applyComposerScrollState(false)
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        let used = fixture.view.layoutManager.usedRect(for: fixture.view.textContainer)
        // Word-wrapping breaks the 86-character unbroken run mid-word: the
        // used block is wide-line-count tall and never wider than the slot.
        #expect(used.width <= 320 + 0.5)
        #expect(used.height > 4 * 32)
        withExtendedLifetime(fixture) {}
    }

    @Test("A same-width draft swap cancels the stale verdict and re-derives fresh")
    func staleVerdictIsCancelledBeforeDelivery() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.cjkDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [true])
        reports.removeAll()
        // The shared field view is reused when the composer switches
        // conversation: a queued verdict measured against the PREVIOUS
        // draft (here a stale "fits" report that would wrongly hide the
        // control and end scrolling) must never reach the host. The text
        // mutation at the SAME laid-out width — exactly what updateUIView
        // performs for a draft swap — cancels it before the deferred
        // delivery runs.
        fixture.coordinator.scheduleOverflowReport(false, textView: fixture.view,
                                                   report: { reports.append($0) })
        fixture.view.text = "短草稿"
        fixture.coordinator.noteTextChange()
        await drainMainQueue()
        #expect(reports.isEmpty)
        #expect(fixture.view.isScrollEnabled)
        // The remeasure hop (production: the intrinsic-invalidation pass
        // that updateUIView now requests for a same-width swap) re-derives
        // the new draft's truth and delivers it instead.
        fixture.coordinator.noteLaidOutWidth(320, in: fixture.view)
        await drainMainQueue()
        #expect(reports == [false])
        #expect(!fixture.view.isScrollEnabled)
        withExtendedLifetime(fixture) {}
    }

    @Test("A width change alone re-reports the control from the layout pass")
    func widthChangeReReportsWithoutSizingPass() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.cjkDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [true])
        reports.removeAll()
        // The row gives the field a wider slot (split-view drag, or the
        // expand control leaving the row): no SwiftUI sizing pass runs in
        // this test at all, and the layout notification alone must flip
        // the verdict — same characters, more width, text now fits.
        fixture.view.frame = CGRect(x: 0, y: 0, width: 640, height: 44)
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        await drainMainQueue()
        #expect(reports == [false])
        #expect(!fixture.view.isScrollEnabled)
        withExtendedLifetime(fixture) {}
    }

    @Test("The shared layout rule keeps the line budget, one-third cap and row minimum")
    func layoutRuleMatchesBudgets() {
        func verdict(natural: CGFloat, deviceLineCap: Int, available: CGFloat?)
            -> ComposerFieldLayout.Verdict {
            ComposerFieldLayout.verdict(
                naturalTextHeight: natural,
                lineHeight: 22,
                verticalInsets: 16,
                lineLimit: 1...8,
                deviceLineCap: deviceLineCap,
                availableHeight: available,
                restingMinimumHeight: 44
            )
        }
        // Regular width: 8 visible lines (8×22+16 = 192).
        #expect(!verdict(natural: 150, deviceLineCap: 8, available: nil).scrolls)
        #expect(verdict(natural: 150, deviceLineCap: 8, available: nil).height == 150)
        #expect(verdict(natural: 230, deviceLineCap: 8, available: nil).scrolls)
        #expect(verdict(natural: 230, deviceLineCap: 8, available: nil).height == 192)
        // Compact width tightens the same draft to the 6-line budget.
        #expect(verdict(natural: 150, deviceLineCap: 6, available: nil).scrolls)
        // One third of the hosting page overrides the line budget.
        let third = verdict(natural: 150, deviceLineCap: 8, available: 400)
        #expect(third.scrolls)
        #expect(third.height == 133)
        // A short draft still rests at the 44pt row minimum.
        #expect(verdict(natural: 30, deviceLineCap: 8, available: nil).height == 44)
        #expect(!verdict(natural: 30, deviceLineCap: 8, available: nil).scrolls)
    }
}
#endif
