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

    // MARK: - Responsive row: the editable field's real width

    /// The shipped New Task defect was geometric, not textual. On the
    /// canonical iPad in portrait with the sidebar open (the rejected
    /// `qa/ui-second-attachments` screenshot) the detail pane is ~421pt; the
    /// launchpad's 24pt band padding, ThreadComposerView's 12pt card inset and
    /// the input row's 12pt padding leave the row ~325pt, and five 44pt
    /// controls plus their five 8pt gaps left ~65pt for the field — the
    /// ragged staircase of tiny lines in the screenshot. These pins are the
    /// exact arithmetic the row layout applies, so a regression to that
    /// column fails here before it reaches a screenshot.
    @Test("Responsive row: the shipped launchpad width gives the field the whole row")
    func responsivePolicyStacksAtTheShippedLaunchpadWidth() {
        let control = FloeTheme.minimumTarget
        let row = 421 - 48 - 24 - 24
        let inline = ComposerResponsiveLayoutPolicy.inlineTextWidth(
            rowWidth: row,
            controlsWidth: 5 * control,
            controlsCount: 5,
            spacing: 8
        )
        #expect(row == 325)
        #expect(inline == 325 - 220 - 40,
                "the flanked column is the row minus every control and gap")
        #expect(inline == 65,
                "the shipped column was a ~65pt sliver, matching the screenshot")
        #expect(inline < ComposerResponsiveLayoutPolicy.minimumInlineTextWidth)
        #expect(ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: row,
            controlsWidth: 5 * control,
            controlsCount: 5,
            spacing: 8,
            fieldHeightAtInlineWidth: 44,
            fieldHeightAtFullWidth: 44,
            isFieldOverflowing: false
        ), "a ~65pt text column must never be accepted beside the controls")
    }

    @Test("Responsive row: a wide row with a short draft keeps the compact single row")
    func responsivePolicyKeepsWideShortDraftCompact() {
        #expect(!ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: 900,
            controlsWidth: 5 * FloeTheme.minimumTarget,
            controlsCount: 5,
            spacing: 8,
            fieldHeightAtInlineWidth: 44,
            fieldHeightAtFullWidth: 44,
            isFieldOverflowing: false
        ), "a 636pt column with one short line stays the calm compact row")
    }

    @Test("Responsive row: a draft that only wraps beside the controls reflows them below")
    func responsivePolicyStacksWhenOnlyTheControlsForceWrapping() {
        #expect(ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: 900,
            controlsWidth: 5 * FloeTheme.minimumTarget,
            controlsCount: 5,
            spacing: 8,
            fieldHeightAtInlineWidth: 88,
            fieldHeightAtFullWidth: 44,
            isFieldOverflowing: false
        ), "two lines beside the controls but one line across the row belongs below")
    }

    @Test("Responsive row: the host overflow verdict stacks the row at its widest slot")
    func responsivePolicyStacksForTheHostOverflowVerdict() {
        #expect(ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: 900,
            controlsWidth: 5 * FloeTheme.minimumTarget,
            controlsCount: 5,
            spacing: 8,
            fieldHeightAtInlineWidth: 192,
            fieldHeightAtFullWidth: 192,
            isFieldOverflowing: true
        ), "a draft scrolling at the widest slot is multiline and gets the whole row")
    }

    @Test("Responsive row: a collapsed host reports an empty row instead of a 1pt column")
    func responsivePolicyNeverMeasuresACollapsedRow() {
        // SwiftUI proposes zero width to collapsed views; the layout must not
        // turn that into a "1pt text column" that looks like a real verdict.
        #expect(ComposerResponsiveLayoutPolicy.inlineTextWidth(
            rowWidth: 0,
            controlsWidth: 220,
            controlsCount: 5,
            spacing: 8
        ) == 0)
        #expect(ComposerResponsiveLayoutPolicy.inlineTextWidth(
            rowWidth: 120,
            controlsWidth: 0,
            controlsCount: 0,
            spacing: 8
        ) == 120)
    }

    /// Real host geometry: the production row + the production field are
    /// mounted in a real UIWindow at the viewport width the New Task
    /// launchpad actually gives them, and the editable width is read from
    /// the placed frames — never re-stated from the policy arithmetic.
    @Test("Real host: a constrained row gives the live field the full width, controls below")
    func hostedRowGivesTheFieldTheFullRowAtConstrainedWidth() async throws {
        let fixture = try await hostedResponsiveRow(width: 325, draft: Self.mixedDraft)
        defer { fixture.dismantle() }
        // The shipped launchpad row is ~325pt. With four 44pt controls
        // (attach, Expand, mic, send) and their gaps the flanked column is
        // 117pt — far below the practical minimum — so the field must own the
        // row and the controls must reflow below it.
        #expect(fixture.probe.row.width > 324)
        #expect(fixture.probe.field.width > 324,
                "the editable field owns the row, not a ~117pt column beside the controls")
        #expect(fixture.probe.field.width >= fixture.probe.row.width - 1,
                "the field width is the row's actual available width, measured on the host")
        #expect(fixture.probe.field.width >= ComposerResponsiveLayoutPolicy.minimumInlineTextWidth,
                "the practical editable width must never fall below the shared minimum")
        #expect(fixture.textView.frame.width > 324,
                "the live UITextView is laid out at the row width")
        #expect(fixture.probe.leading.minY >= fixture.probe.field.maxY - 0.5,
                "the attachment control reflows below the text")
        #expect(fixture.probe.trailing.minY >= fixture.probe.field.maxY - 0.5,
                "action controls reflow below the text")
        #expect(fixture.probe.trailing.maxX <= fixture.probe.row.maxX + 0.5,
                "actions stay inside the row's trailing edge")
        #expect(fixture.probe.leading.minX <= fixture.probe.row.minX + 0.5,
                "the attachment control keeps the leading edge")
        withExtendedLifetime(fixture) {}
    }

    /// The identity invariant the whole reflow rests on: inline → stacked is
    /// re-placement inside one `Layout`, so the SAME UITextView/Coordinator
    /// keeps first responder eligibility, caret, undo association and marked
    /// text. A `ViewThatFits`/duplicate-branch would fail this.
    @Test("Real host: reflowing the row never remounts the field or moves its caret")
    func hostedRowReflowPreservesTheEditingSurface() async throws {
        let undo = UndoManager()
        let fixture = try await hostedResponsiveRow(
            width: 900,
            draft: "短草稿",
            undoManager: undo
        )
        defer { fixture.dismantle() }
        // Wide + one short line: the compact row, field beside the controls.
        #expect(fixture.probe.field.width > 550)
        #expect(fixture.probe.field.width < fixture.probe.row.width - 150,
                "the compact row keeps the field beside its controls")
        #expect(fixture.probe.trailing.minY < fixture.probe.field.maxY + 1,
                "actions share the field's row while compact")
        let identity = ObjectIdentifier(fixture.textView)
        // The user's caret is where the reflow must leave it — untouched.
        fixture.textView.selectedRange = NSRange(location: 3, length: 0)
        // Host verdict flip (the production `onOverflowChange` state): the row
        // reflows with the SAME draft and the SAME editing surface.
        fixture.model.manualOverflow = true
        let flipped = try await waitForFieldWidth(
            fixture,
            atLeast: fixture.probe.row.width - 2
        )
        #expect(flipped, "the multiline verdict must give the field the whole row")
        #expect(fixture.probe.trailing.minY >= fixture.probe.field.maxY - 0.5,
                "controls move below the reflowed field")
        let liveViews = Self.hardwareTextViews(in: fixture.host.view)
        #expect(liveViews.count == 1, "one editing surface for the whole composer")
        #expect(liveViews.first.map(ObjectIdentifier.init) == identity,
                "the reflow must not remount the field")
        #expect(fixture.textView.selectedRange.location == 3,
                "the caret survives the reflow")
        #expect(fixture.textView.undoManager === undo,
                "the shared undo history stays attached across the reflow")
        #expect(fixture.textView.text == "短草稿",
                "the reflow never rewrites the draft")
        withExtendedLifetime(fixture) {}
    }

    @Test("Real host: a long draft on a wide row reflows to the full width and keeps one field")
    func hostedRowReflowsForALongDraftAndKeepsOneField() async throws {
        let fixture = try await hostedResponsiveRow(width: 900, draft: "短草稿")
        defer { fixture.dismantle() }
        let identity = ObjectIdentifier(fixture.textView)
        let compactWidth = fixture.probe.field.width
        // Production programmatic swap at the same host width: the field's
        // text binding changes, `updateUIView` re-derives, the row re-measures.
        fixture.model.text = Self.mixedDraft
        let reflowed = try await waitForFieldWidth(
            fixture,
            atLeast: fixture.probe.row.width - 2
        )
        #expect(reflowed, "a wrapping draft must own the full row even on a wide host")
        #expect(fixture.probe.field.width > compactWidth + 100,
                "the reflow must widen the editable column, not merely stack it")
        #expect(fixture.probe.trailing.minY >= fixture.probe.field.maxY - 0.5,
                "controls reflow below the multiline field")
        #expect(fixture.textView.text == Self.mixedDraft,
                "the reflow never alters the draft")
        #expect(Self.hardwareTextViews(in: fixture.host.view).count == 1)
        #expect(Self.hardwareTextViews(in: fixture.host.view).first.map(ObjectIdentifier.init)
            == identity, "the same editing surface is retained")
        withExtendedLifetime(fixture) {}
    }

    // MARK: - Real hosted-row fixture

    private func hostedResponsiveRow(
        width: CGFloat,
        draft: String,
        undoManager: UndoManager? = nil
    ) async throws -> HostedResponsiveRowFixture {
        let model = ComposerRowFixtureModel(text: draft)
        let probe = ResponsiveRowProbe()
        let host = UIHostingController(rootView: ComposerRowFixtureHost(
            model: model,
            probe: probe,
            undoManager: undoManager,
            width: width
        ))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        }
        window.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        func framesArrived() -> Bool {
            probe.row.width > 0 && probe.field.width > 0
                && probe.leading.width > 0 && probe.trailing.width > 0
        }
        let deadline = Date().addingTimeInterval(5)
        while !framesArrived() && Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let textView = try #require(Self.hardwareTextViews(in: host.view).first,
                                    "the hosted row must mount the real composer field")
        // A settled geometry pass before the assertions read the frames.
        for _ in 0..<3 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return HostedResponsiveRowFixture(
            host: host,
            window: window,
            previousKeyWindow: previousKeyWindow,
            probe: probe,
            model: model,
            textView: textView
        )
    }

    /// Polls until the row places the field at (at least) the requested
    /// width, driving the same layout pass the app's update cycle runs.
    private func waitForFieldWidth(
        _ fixture: HostedResponsiveRowFixture,
        atLeast width: CGFloat
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if fixture.probe.field.width >= width { return true }
            fixture.host.view.setNeedsLayout()
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return fixture.probe.field.width >= width
    }

    private static func hardwareTextViews(in view: UIView) -> [HardwareReturnTextView] {
        var found: [HardwareReturnTextView] = []
        if let textView = view as? HardwareReturnTextView { found.append(textView) }
        for subview in view.subviews {
            found.append(contentsOf: hardwareTextViews(in: subview))
        }
        return found
    }
}

/// Frames the hosted row actually placed, in window coordinates.
@MainActor
private final class ResponsiveRowProbe {
    var row = CGRect.zero
    var field = CGRect.zero
    var leading = CGRect.zero
    var trailing = CGRect.zero
}

/// Mutable state of one hosted row: the draft the field binds to and the
/// host overflow verdict that reflows it, driven exactly like production.
/// `reportedOverflow` is the live field's own verdict (the production
/// `onOverflowChange` feed); `manualOverflow` lets a test flip the host
/// verdict with the draft untouched, to prove the caret survives a reflow.
@MainActor
private final class ComposerRowFixtureModel: ObservableObject {
    @Published var text: String
    @Published var reportedOverflow = false
    @Published var manualOverflow = false

    var overflowing: Bool { manualOverflow || reportedOverflow }

    init(text: String) {
        self.text = text
    }
}

/// The production responsive row with production-width controls (attachment,
/// Expand, mic, send) around the production `ComposerReturnField`.
private struct ComposerRowFixtureHost: View {
    @ObservedObject var model: ComposerRowFixtureModel
    let probe: ResponsiveRowProbe
    let undoManager: UndoManager?
    let width: CGFloat

    private var control: CGFloat { FloeTheme.minimumTarget }

    var body: some View {
        ComposerResponsiveRow(isFieldOverflowing: model.overflowing) {
            Color.clear
                .frame(width: control, height: control)
                .composerResponsiveLeadingControl()
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    Task { @MainActor in probe.leading = frame }
                }
            ComposerReturnField(
                text: $model.text,
                placeholder: "composer.test.placeholder",
                canSend: true,
                lineLimit: 1...8,
                maxHeightBudget: nil,
                hostAvailableWidth: nil,
                undoManager: undoManager,
                onOverflowChange: { overflowing in
                    Task { @MainActor in model.reportedOverflow = overflowing }
                },
                onReturn: {}
            )
            .frame(maxWidth: .infinity, minHeight: control, alignment: .leading)
            .composerResponsiveFieldSlot()
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                Task { @MainActor in probe.field = frame }
            }
            Color.clear.frame(width: control, height: control)
            Color.clear.frame(width: control, height: control)
            Color.clear
                .frame(width: control, height: control)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    Task { @MainActor in probe.trailing = frame }
                }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            Task { @MainActor in probe.row = frame }
        }
        .frame(width: width)
    }
}

private struct HostedResponsiveRowFixture {
    let host: UIHostingController<ComposerRowFixtureHost>
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    let probe: ResponsiveRowProbe
    let model: ComposerRowFixtureModel
    let textView: HardwareReturnTextView

    @MainActor
    func dismantle() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
#endif
