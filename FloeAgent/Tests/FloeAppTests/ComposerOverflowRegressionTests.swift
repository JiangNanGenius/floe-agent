// FloeAppTests — composer soft-wrap and the overflow → expand-control chain.
//
// Behavior regressions for the repair, driven through the REAL production
// seams: the same `configure` setup `makeUIView` performs, the live view's
// own `layoutSubviews` laid-out-width notification, the delegate keystroke
// path, the `requestRemeasureHop` statement `updateUIView` takes for every
// accepted content/budget/host-width change, the coalesced deferred host
// report and the actual NSTextContainer / NSLayoutManager the field wraps
// inside. The pinned contract:
// - the verdict gates `composer.expand` on real TextKit overflow at the
//   width the field is ACTUALLY laid out at — never a character count;
// - a programmatic draft swap at the SAME laid-out width (New Task
//   launchpad restore, dictation landing, the send clear) re-derives and
//   delivers the fresh verdict WITHOUT depending on a hypothetical SwiftUI
//   sizing pass — the bottom `safeAreaInset` band is exactly the host that
//   answers from cached measurement, which is how the shipped New Task
//   composer kept a long mixed draft clipped at one line with no Expand;
// - before any laid-out frame exists, the host row's measured width
//   (`hostAvailableWidth`) is the first truth, not the 320pt fallback;
// - a container transition measured while an input method holds marked
//   text is DEFERRED (never applied mid-composition, never silently
//   dropped): the host report still lands (Expand appears), the marked
//   run is untouched, and the flip lands on composition commit;
// - deleting text back under the cap, or widening the slot, re-reports
//   false even when no SwiftUI sizing pass runs at all;
// - a verdict measured against older text never reaches the host, and the
//   next real pass re-derives the new draft's truth at the SAME laid-out
//   width (conversation switch inside the shared field view);
// - flipping the scroll state through `applyComposerScrollState` keeps the
//   live container width-tracked, so long CJK / English / unbroken-URL runs
//   wrap inside the bounded width instead of running off to the right;
//   the wrapped block is measured in the scrolling state production
//   displays for an overflowing draft — a NON-scrolling UITextView pins
//   `heightTracksTextView` and clamps its container to the frame, so at
//   the 44pt fixture row that state can never hold more than one line
//   fragment no matter how the text wraps (UIKit semantics, not a defect);
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
    /// The screenshot scenario: ONE logical line mixing Chinese, spaced
    /// Latin and an unbroken Latin run — measured and wrapped by the real
    /// production TextKit stack, never by an equivalent.
    private static let mixedDraft = String(
        repeating: "这是一段中文mixed with English words plus an unbroken https://example.invalid/segmentwithoutanybreakablecharacter 的草稿。",
        count: 8)
    /// Two explicit lines (paste with a hard line break): under the cap,
    /// the field must GROW to the measured natural height, not stay at the
    /// 44pt resting row.
    private static let growthDraft = "第一行中文mixed with English words\n第二行second line of the pasted draft"

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
        hostWidth: CGFloat? = nil,
        reports: @escaping (Bool) -> Void
    ) -> Fixture {
        let field = ComposerReturnField(
            text: .constant(text),
            placeholder: "composer.test.placeholder",
            canSend: true,
            lineLimit: 1...8,
            maxHeightBudget: nil,
            hostAvailableWidth: hostWidth,
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

    /// The same production `configure`, but WITHOUT any laid-out frame:
    /// the state a restored large draft sits in on the New Task launchpad
    /// while the bottom `safeAreaInset` band answers measurement from its
    /// cache. Only the host row's measured width can produce the first
    /// verdict in this state.
    private func hostOnlyField(
        text: String,
        hostWidth: CGFloat,
        reports: @escaping (Bool) -> Void
    ) -> Fixture {
        let field = ComposerReturnField(
            text: .constant(text),
            placeholder: "composer.test.placeholder",
            canSend: true,
            lineLimit: 1...8,
            maxHeightBudget: nil,
            hostAvailableWidth: hostWidth,
            onOverflowChange: reports,
            onReturn: {}
        )
        let coordinator = field.makeCoordinator()
        let view = HardwareReturnTextView()
        field.configure(view: view, coordinator: coordinator)
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
        // Measure the state production actually displays for this draft:
        // the deferred verdict has just flipped the field to internal
        // scrolling through `applyComposerScrollState`, leaving the live
        // container width-tracked at the real slot width with an unbounded
        // height. The earlier flip to `isScrollEnabled == false` measured a
        // state that can never show this block: a NON-scrolling UITextView
        // pins `heightTracksTextView` and clamps its container to the frame
        // (44pt row − 16pt insets = 28pt), and TextKit lays out only the
        // line fragments that FIT that container — exactly one 22.0083pt
        // line here, since a second fragment would end at 44.0166 — so the
        // used height stayed frame-clamped below the assertion no matter
        // how the text wrapped, identically before and after the seam
        // repair (the width cap passed in BOTH runs: the run was always
        // broken at the bounded width, never an unbounded run-off).
        #expect(fixture.view.isScrollEnabled)
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        // The live UITextView's TextKit stack lays out lazily; force the
        // FULL document layout for the container before reading the used
        // block — the same forcing the detached production measurement
        // applies through `glyphRange` — so the measurement reflects every
        // wrapped line, not just the first viewport fragment.
        let layoutManager = fixture.view.layoutManager
        let textContainer = fixture.view.textContainer
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
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

    @Test("The one-line mixed CJK/Latin/unbroken draft grows the REAL field under the cap")
    func mixedDraftGrowsToNaturalHeightUnderCap() {
        // Production UITextView + its own coordinator measurement at the
        // real slot width: an explicit-newline paste under the cap must
        // report the MEASURED multi-line height (dynamic growth), not the
        // 44pt resting row and not scrolling.
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: Self.growthDraft,
            width: 320,
            reports: { reports.append($0) }
        )
        let verdict = fixture.field.verdict(at: 320, textView: fixture.view,
                                            coordinator: fixture.coordinator)
        #expect(!verdict.scrolls)
        #expect(verdict.height > 44,
                "a two-line draft grows the field past the resting row at the real width")
        // The screenshot scenario: the same measurement path at the real
        // row width finds the overflow (one logical line cannot stay one
        // fragment when the measured container is width-bounded).
        fixture.view.text = Self.mixedDraft
        fixture.coordinator.noteTextChange()
        let overflow = fixture.field.verdict(at: 320, textView: fixture.view,
                                             coordinator: fixture.coordinator)
        #expect(overflow.scrolls)
        #expect(overflow.height <= 8 * 22.05 + 16 + 0.5)
        withExtendedLifetime(fixture) {}
    }

    @Test("The New Task band: a same-width programmatic swap re-derives via the exact updateUIView hop")
    func programmaticSwapReDerivesWithoutSizingPass() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: "短草稿",
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [false])
        // Exactly what production `updateUIView` does for a programmatic
        // draft swap (New Task restore, dictation landing, the send clear)
        // at an UNCHANGED laid-out width, where no `layoutSubviews` width
        // notification fires and the launchpad's `safeAreaInset` band may
        // never re-run `sizeThatFits`: assign the text, cancel the stale
        // generation, then take the SAME `requestRemeasureHop` statement.
        fixture.view.text = Self.mixedDraft
        fixture.coordinator.noteTextChange()
        fixture.field.requestRemeasureHop(
            uiView: fixture.view,
            coordinator: fixture.coordinator
        )
        await drainMainQueue()
        #expect(reports == [false, true],
                "the swap alone must deliver the fresh verdict — no hypothetical sizing pass")
        #expect(fixture.view.isScrollEnabled)
        #expect(fixture.view.textContainer.widthTracksTextView)
        // And it converges back: shrinking the draft at the same width
        // through the same hop re-reports false.
        fixture.view.text = "短草稿"
        fixture.coordinator.noteTextChange()
        fixture.field.requestRemeasureHop(
            uiView: fixture.view,
            coordinator: fixture.coordinator
        )
        await drainMainQueue()
        #expect(reports == [false, true, false])
        #expect(!fixture.view.isScrollEnabled)
        withExtendedLifetime(fixture) {}
    }

    @Test("Before any laid-out frame, the host row width (not the 320 fallback) drives the first verdict")
    func hostRowWidthDrivesFirstVerdictPreLayout() async {
        var reports: [Bool] = []
        // A large restored draft on a field the band has not laid out yet:
        // bounds are empty, so only the host's measured row width can
        // produce a verdict. 200pt is deliberately narrow: the draft
        // overflows there while the same draft at the historical blind 320
        // fallback would under-report.
        let fixture = hostOnlyField(
            text: Self.cjkDraft,
            hostWidth: 200,
            reports: { reports.append($0) }
        )
        #expect(fixture.view.bounds.width <= 1)
        fixture.field.requestRemeasureHop(
            uiView: fixture.view,
            coordinator: fixture.coordinator
        )
        await drainMainQueue()
        #expect(reports == [true])
        #expect(fixture.view.isScrollEnabled)
        // The laid-out truth wins as soon as a real frame exists: the same
        // hop re-derives at the (wider) bounds width, not the host value.
        reports.removeAll()
        fixture.view.frame = CGRect(x: 0, y: 0, width: 640, height: 44)
        fixture.view.setNeedsLayout()
        fixture.view.layoutIfNeeded()
        fixture.coordinator.noteTextChange()
        fixture.field.requestRemeasureHop(
            uiView: fixture.view,
            coordinator: fixture.coordinator
        )
        await drainMainQueue()
        #expect(reports.contains(false),
                "the actual laid-out width — not the host row number — is the verdict truth")
        withExtendedLifetime(fixture) {}
    }

    @Test("A Chinese-IME composition defers the container transition, still reveals Expand, keeps the marked run")
    func compositionDefersTransitionAndLandsOnCommit() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: "短草稿",
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [false])
        reports.removeAll()
        // A live composition owns the editing surface (in production this
        // is UIKit's real markedTextRange; tests inject the same value at
        // the view's probe seam).
        fixture.view.markedTextProbe = { true }
        // The marked run must ACTUALLY overflow at the laid-out width — the
        // transition this test defers can only exist if the freshest
        // measurement says so (the first revision's ~3-line run measured
        // under the 6/8-line cap at 320pt, so no verdict ever reached the
        // host mid-composition and there was nothing to land on commit).
        // The proven screenshot-scenario mixed draft, with the unconfirmed
        // pinyin syllable still at the caret.
        let markedRun = Self.mixedDraft + "ni3zai4shu1ru4de4pin1yin1"
        fixture.view.text = markedRun
        // Production keystroke path: the freshest measurement now says
        // "overflow" — the host must learn it, but the container flip may
        // NOT reconfigure TextKit under the active composition.
        fixture.coordinator.textViewDidChange(fixture.view)
        await drainMainQueue()
        #expect(reports == [true], "Expand appears even while composing")
        #expect(!fixture.view.isScrollEnabled,
                "the container transition is deferred during composition, not applied")
        #expect(fixture.view.text == markedRun, "marked run untouched")
        // Composition commits: the same delegate path lands the transition
        // against fresh truth at the laid-out width.
        fixture.view.markedTextProbe = { false }
        fixture.coordinator.textViewDidChange(fixture.view)
        await drainMainQueue()
        #expect(fixture.view.isScrollEnabled)
        #expect(fixture.view.textContainer.widthTracksTextView)
        #expect(fixture.view.text == markedRun)
        withExtendedLifetime(fixture) {}
    }

    @Test("Paste-explicit newlines overflow at the real slot width through the keystroke seam")
    func explicitNewlinesOverflowAtSlotWidth() async {
        var reports: [Bool] = []
        let fixture = laidOutField(
            text: "短草稿",
            width: 320,
            reports: { reports.append($0) }
        )
        await drainMainQueue()
        #expect(reports == [false])
        reports.removeAll()
        // A pasted multi-line draft: plain Return/paste inserts newlines
        // (the preserved send policy), and the explicit breaks alone must
        // overflow the cap at the row's actual width.
        let pasted = Self.cjkDraft + "\n" + Self.urlDraft
        fixture.view.text = pasted
        fixture.coordinator.textViewDidChange(fixture.view)
        await drainMainQueue()
        #expect(reports == [true])
        #expect(fixture.view.isScrollEnabled)
        withExtendedLifetime(fixture) {}
    }

    @Test("The IME policy gates container mutations, never the host report")
    func imePolicyPins() {
        #expect(ComposerIMEPolicy.allowsTextReplacement(hasMarkedText: false))
        #expect(!ComposerIMEPolicy.allowsTextReplacement(hasMarkedText: true))
        #expect(ComposerIMEPolicy.allowsScrollTransition(hasMarkedText: false))
        #expect(!ComposerIMEPolicy.allowsScrollTransition(hasMarkedText: true))
    }
}
#endif
