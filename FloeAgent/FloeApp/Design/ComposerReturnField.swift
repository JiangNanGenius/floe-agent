// FloeApp — Shared composer text field with hardware-key send handling.
//
// SPDX-License-Identifier: MPL-2.0
//
// Multiline input used by the chat thread composer and the canvas assistant.
// Text wraps by width (Chinese, English and unbroken long strings alike).
// The field grows from one line up to a device-aware budget — 6 visible
// lines on compact widths, 8 on regular widths, and never more than one
// third of the height available to the hosting page — then switches to
// internal scrolling with the caret kept visible.
//
// Keyboard contract (both keyboards): plain Return inserts a newline.
// Hardware Cmd+Return sends, and only while sending is allowed and no
// input method composition is in flight — a half-confirmed IME candidate
// can never trigger a send. Callers that previously used
// `.submitLabel(.send)` keep software-send via `softwareReturnSends`.
//
// Natural-height measurement uses a detached TextKit stack and is memoized
// per (text generation, width, content-size category), so repeated layout
// probes do not remeasure unchanged content or enter the live view's layout.
// The overflow verdict (the full-editor control's only source) is derived
// from the width the view is ACTUALLY laid out at — reported by the live
// view's layout pass, the keystroke pass and any real sizing pass alike —
// never from a character count and never only from a SwiftUI proposal.
// Hosts additionally feed the row's real width through `hostAvailableWidth`
// (measured with `onGeometryChange`), because a bottom-pinned
// `safeAreaInset` band (the New Task launchpad) can answer content changes
// from cached measurement without ever re-running `sizeThatFits`: with only
// the proposal/bounds chain the field would sit clipped at its resting
// height with no verdict and no expand control. Every accepted mutation
// (programmatic draft swap, budget change, host-width change) therefore
// re-derives the verdict IMMEDIATELY at the best known real width — the
// laid-out bounds width, else the host row width — instead of hoping a
// SwiftUI sizing pass arrives. And a container transition (the
// `isScrollEnabled` flip, which reconfigures TextKit) is deferred — never
// dropped — while an input method holds marked text, so a Chinese-IME
// candidate run is never disturbed; it lands the moment composition
// commits.
//
// Hosts compose the field with its natural controls through
// `ComposerResponsiveRow` (bottom of this file): one stable subtree whose
// custom `Layout` keeps the compact single row while the text has a usable
// column and otherwise gives the field the whole row with the controls
// directly below — without ever re-creating the field, so caret, undo,
// first responder and marked text survive the reflow.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

import FloeCore
/// UITextView that intercepts hardware Cmd+Return for sending. The press is
/// consumed only when the handler reports the send actually fired; every
/// other Return (plain, Shift+, during IME composition) keeps its default
/// newline behavior.
final class HardwareReturnTextView: UITextView {
    /// Match the live editor to the TextKit layout used for its measured
    /// height. Default UITextView uses TextKit 2; reading layoutManager in a
    /// test silently switches that view to TextKit 1 and can hide a live
    /// height-change/caret rendering regression. Select the backing engine
    /// once, before text or a selection exists, rather than falling back
    /// during an edit.
    static func makeComposerTextView() -> HardwareReturnTextView {
        HardwareReturnTextView(usingTextLayoutManager: false)
    }

    /// Placeholder shown while the field is empty; a subview so it tracks
    /// the text container's origin and insets.
    let placeholderLabel = UILabel()

    /// Asks whether a Cmd+Return press may send right now. Returns false
    /// when sending is disabled or an input method still has marked text.
    var commandReturnHandler: (() -> Bool)?

    /// A composer-owned undo manager shared with the full editor, so
    /// undo/redo continues across the inline ↔ expanded surfaces instead of
    /// each UITextView keeping a private history. Nil keeps UIKit's default.
    var sharedUndoManager: UndoManager?

    /// Reports each NEW width this view is actually laid out at. SwiftUI
    /// may place the final slot without ever consulting `sizeThatFits`
    /// with a finite proposal (nil / 0 / .infinity are sizing probes), so
    /// the laid-out bounds width is the only width that is guaranteed to
    /// be the width the user sees. The overflow verdict is re-derived here
    /// as well, which is what makes the full-editor control appear after
    /// rotation, split-view drags, keyboard changes or a restored large
    /// draft even when no sizing pass ran.
    var onLaidOutWidthChange: ((CGFloat) -> Void)?

    /// Composition probe. Production reads the live `markedTextRange`
    /// (nil override); behavior tests inject the value so the IME
    /// deferral can be pinned without synthesizing a hardware input
    /// method session — UIKit exposes marked text only on the view.
    var markedTextProbe: (() -> Bool)?

    /// Whether an input method currently holds an unconfirmed marked run,
    /// as the composer's transition guard sees it.
    var hasActiveComposition: Bool {
        markedTextProbe?() ?? (markedTextRange != nil)
    }

    private var caretRevealPending = false

    /// Re-read the current selection after UIKit lays out this edit, rather
    /// than scrolling using the previous text layout or a stale captured range.
    func revealCurrentCaretAfterLayout() {
        guard !caretRevealPending else { return }
        caretRevealPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.caretRevealPending = false
            guard self.isFirstResponder, self.isScrollEnabled else { return }
            self.layoutIfNeeded()
            self.scrollRangeToVisible(self.selectedRange)
        }
    }

    private var lastNotifiedLayoutWidth: CGFloat = -1

    override var undoManager: UndoManager? {
        sharedUndoManager ?? super.undoManager
    }

    /// Applies the composer's scroll-state flip through ONE seam. UITextView
    /// reconfigures its NSTextContainer whenever the scrolling state flips
    /// (width tracking drops and the container stops wrapping at the
    /// laid-out width — exactly how a long unbroken run used to run off to
    /// the right instead of soft-wrapping), so the composer layout contract
    /// is re-asserted here on every flip, whether the flip comes from the
    /// initial configuration, the deferred overflow delivery or a behavior
    /// test driving this seam directly.
    /// - Parameters:
    ///   - scrolls: true switches the field to internal scrolling; false
    ///     returns it to inline growth at the laid-out width.
    ///   - revealCaret: true reveals the caret when scrolling starts.
    func applyComposerScrollState(_ scrolls: Bool, revealCaret: Bool = false) {
        if isScrollEnabled != scrolls {
            isScrollEnabled = scrolls
        }
        // The flip reconfigured the container; re-pin the composer layout
        // (guarded so a no-op flip stays free of container KVO churn).
        if !textContainer.widthTracksTextView {
            textContainer.widthTracksTextView = true
        }
        if textContainer.lineFragmentPadding != 0 {
            textContainer.lineFragmentPadding = 0
        }
        // The non-scrolling composer sizes its container to the view, so a
        // draft that grows the slot must never be laid out against the
        // previous one-row container. UIKit updates this on the
        // `isScrollEnabled` flip, but the composer owns this seam and a
        // desynced flag clips the new line: the shipped two-line launchpad
        // failure painted only its first row while the text storage and the
        // model held both.
        if textContainer.heightTracksTextView != !scrolls {
            textContainer.heightTracksTextView = !scrolls
        }
        if scrolls, revealCaret {
            scrollRangeToVisible(selectedRange)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UITextView can also reconfigure the container outside our seam
        // (internal scroll-state bookkeeping, future SDK changes). Pinning
        // the composer contract on every layout pass keeps the LIVE text
        // wrapped at the actual slot width in both states; the guard keeps
        // steady state free of container KVO churn.
        if !textContainer.widthTracksTextView {
            textContainer.widthTracksTextView = true
        }
        if textContainer.lineFragmentPadding != 0 {
            textContainer.lineFragmentPadding = 0
        }
        // Same container contract as `applyComposerScrollState`: a live
        // layout pass keeps the non-scrolling container tracking this view's
        // height, so a slot that grew by a row lays out (and paints) it.
        let tracksHeight = !isScrollEnabled
        if textContainer.heightTracksTextView != tracksHeight {
            textContainer.heightTracksTextView = tracksHeight
        }
        let width = bounds.width
        guard width > 1, abs(width - lastNotifiedLayoutWidth) >= 0.5 else { return }
        lastNotifiedLayoutWidth = width
        onLaidOutWidthChange?(width)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var consumed = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.keyCode == .keyboardReturnOrEnter else { continue }
            // Caps Lock (.alphaShift) must not block plain Return; only the
            // four editing modifiers decide whether this is Cmd+Return.
            let modifiers = key.modifierFlags
                .intersection([.shift, .control, .alternate, .command])
            guard modifiers == .command, commandReturnHandler?() == true else { continue }
            consumed.insert(press)
        }
        let remaining = presses.subtracting(consumed)
        guard !remaining.isEmpty else { return }
        super.pressesBegan(remaining, with: event)
    }
}

/// Multiline composer field shared by the chat and canvas assistants.
///
/// Hardware keyboard: Cmd+Return invokes `onReturn` (only when `canSend`
/// and no marked text is pending); every other Return inserts a newline.
/// Software keyboard: the return key keeps inserting newlines unless
/// `softwareReturnSends` is true (the surfaces that previously used
/// `.submitLabel(.send)`).
struct ComposerReturnField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Mirrors the send button's enabled state; when false, hardware
    /// Cmd+Return falls back to doing nothing instead of sending.
    var canSend: Bool = true
    /// True where the replaced surface used `.submitLabel(.send)`: the
    /// software keyboard's return key then sends as well.
    var softwareReturnSends: Bool = false
    /// Visible line budget; beyond the upper bound the field scrolls, like
    /// `lineLimit(_:)` on a multiline `TextField`. The upper bound is
    /// additionally clamped by the device line cap (6 compact / 8 regular)
    /// and by `maxHeightBudget`.
    var lineLimit: ClosedRange<Int> = 1...3
    /// Height available to the hosting page; the field never grows beyond
    /// one third of it. Nil disables the height rule.
    var maxHeightBudget: CGFloat? = nil
    /// The width the host row ACTUALLY gives this field, measured by the
    /// host (`onGeometryChange` on the row slot). Secondary truth after the
    /// live laid-out bounds: it lets the first verdict land while the view
    /// has no laid-out frame yet (pre-placement measurement of a restored
    /// or pasted large draft), so a bottom-pinned `safeAreaInset` host that
    /// answers layout from cache cannot leave the field clipped at its
    /// resting height with no expand control. Nil keeps callers that do not
    /// measure the row (canvas assistant, previews) exactly as before.
    var hostAvailableWidth: CGFloat? = nil
    /// Caret/selection captured in the full editor (or on the previous
    /// launch). Applied only once the initial text exists and only while the
    /// user is not editing, so it never fights the live caret.
    var restoredSelection: NSRange? = nil
    /// Undo manager shared with the expanded editor; nil keeps UIKit's own.
    var undoManager: UndoManager? = nil
    /// Reports the live caret/selection so the caller can persist it and the
    /// full editor can reopen exactly where editing stopped.
    var onSelectionChange: ((NSRange?) -> Void)? = nil
    /// Independent of scrolling: the third visual line offers the full editor.
    var onExpansionAvailableChange: ((Bool) -> Void)? = nil
    /// Reports whether the field currently overflows its height cap and
    /// scrolls internally (true) or fits completely (false). The verdict is
    /// derived at the width the field is ACTUALLY laid out at (sizing pass,
    /// UIKit layout pass and keystroke pass share one rule), never from a
    /// character count. The report is delivered on the next main-queue
    /// turn, never synchronously from a layout pass; a burst of layout
    /// passes coalesces to the newest measured verdict, a verdict that no
    /// longer matches the current text is dropped when the text changes,
    /// and the field re-reports after a conversation switch, so the host
    /// always converges to the field's current truth (including after it
    /// resets its own state on that switch). Nil keeps callers that do not
    /// need the signal unchanged.
    var onOverflowChange: ((Bool) -> Void)? = nil
    /// Reports the measured height the host must give this field for the
    /// current draft and width. A host that pins its field slot to this
    /// value keeps the live UITextView's laid-out area equal to the area the
    /// detached measurement reserved; without it a growing draft can reserve
    /// a second row while the text view keeps its resting one-row frame, so
    /// its container clips the new line and the caret at the end is out of
    /// view. Delivered on the same coalesced main-queue hop as
    /// `onOverflowChange`, change-only, never synchronously from layout.
    var onHeightChange: ((CGFloat) -> Void)? = nil
    /// Live focus callback for hosts that switch between voice and text panels.
    var onEditingChange: ((Bool) -> Void)? = nil
    var onReturn: () -> Void

    private let textInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    /// Classic 44pt composer row; the `lineLimit.lowerBound` may push the
    /// resting height beyond this (e.g. a two-line canvas prompt field).
    private let restingMinHeight: CGFloat = 44

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeUIView(context: Context) -> HardwareReturnTextView {
        let view = HardwareReturnTextView.makeComposerTextView()
        configure(view: view, coordinator: context.coordinator)
        return view
    }

    /// Single place the field's initial UIKit configuration is applied
    /// (insets, width-tracked soft wrapping, placeholder, the laid-out
    /// width overflow reporter, and the text-then-selection restore
    /// order). `makeUIView` and the behavior tests drive exactly this
    /// production setup, so tests never re-state the configuration.
    func configure(view: HardwareReturnTextView, coordinator: Coordinator) {
        view.delegate = coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = textInsets
        view.applyComposerScrollState(false)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textContainer.lineBreakMode = .byWordWrapping
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.keyboardDismissMode = .none
        view.placeholderLabel.font = view.font
        view.placeholderLabel.textColor = .tertiaryLabel
        view.placeholderLabel.numberOfLines = 1
        view.placeholderLabel.isHidden = !text.isEmpty
        view.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(view.placeholderLabel)
        NSLayoutConstraint.activate([
            view.placeholderLabel.topAnchor.constraint(
                equalTo: view.topAnchor, constant: textInsets.top),
            view.placeholderLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: textInsets.left + view.textContainer.lineFragmentPadding),
            view.placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -textInsets.right),
        ])
        view.placeholderLabel.text = placeholder
        view.accessibilityLabel = placeholder
        view.sharedUndoManager = undoManager
        // The laid-out width is the truth the host control must follow: re-derive
        // the overflow verdict whenever this view is first placed or moved to a
        // different width (rotation, split view, the expand control appearing,
        // keyboard-driven resize) — including when SwiftUI answers the new width
        // from a cached sizing result and never re-runs `sizeThatFits`.
        view.onLaidOutWidthChange = { [weak view, weak coordinator] width in
            guard let view, let coordinator else { return }
            coordinator.noteLaidOutWidth(width, in: view)
        }
        // Text first, selection second: a saved non-zero caret cannot be
        // applied to an empty view (it would be clamped away).
        ComposerSelection.prepare(view, text: text, selection: restoredSelection)
        coordinator.noteAppliedSelection(restoredSelection)
    }

    func updateUIView(_ uiView: HardwareReturnTextView, context: Context) {
        // Coordinators outlive individual SwiftUI value snapshots. Refresh
        // the snapshot so send availability and the callback track the
        // current draft/model state instead of the initial empty field.
        let previous = context.coordinator.field
        context.coordinator.field = self
        uiView.sharedUndoManager = undoManager
        var needsRemeasure = false
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: uiView.traitCollection)
        if ComposerIMEPolicy.allowsTextReplacement(hasMarkedText: uiView.hasActiveComposition),
           uiView.font != font {
            uiView.font = font
            uiView.placeholderLabel.font = font
            context.coordinator.noteTextChange()
            needsRemeasure = true
        }
        // Never clobber in-flight IME composition or echo the user's own edit.
        if ComposerIMEPolicy.allowsTextReplacement(hasMarkedText: uiView.hasActiveComposition),
           uiView.text != text {
            uiView.text = text
            context.coordinator.noteTextChange()
            needsRemeasure = true
        }
        if previous.maxHeightBudget != maxHeightBudget || previous.lineLimit != lineLimit {
            needsRemeasure = true
        }
        // The row's real width changed (rotation, split-view drag, the
        // expand control appearing/disappearing shrinks or frees the slot).
        let hostWidthChanged = previous.hostAvailableWidth != hostAvailableWidth
        if hostWidthChanged {
            needsRemeasure = true
        }
        // A programmatic draft swap (dictation landing, slash command, the
        // send clear, a restored or conversation-switched draft), a
        // budget/line-limit change or a host-width change at the SAME
        // laid-out width produces no `layoutSubviews` width notification,
        // and a bottom-pinned `safeAreaInset` band (the New Task launchpad)
        // may answer the new content from a cached measurement without ever
        // re-running `sizeThatFits` — relying on that hop alone was the New
        // Task defect: the field stayed clipped at its resting height and
        // `composer.expand` never appeared. The intrinsic invalidation hop
        // stays (it lets SwiftUI grow the frame where it does measure), but
        // the verdict is now ALSO re-derived immediately at the best known
        // real width: the laid-out bounds first, else the host row width.
        // This runs during the state update — never inside layout — and the
        // coalescing reporter keeps it loop-free.
        if needsRemeasure {
            requestRemeasureHop(uiView: uiView, coordinator: context.coordinator)
        }
        // A restored caret (full editor dismissed, task reopened) only lands
        // while the field itself is not the editing surface.
        if !uiView.isFirstResponder {
            context.coordinator.applyRestoredSelectionIfNeeded(in: uiView)
        }
        uiView.commandReturnHandler = { [weak uiView, canSend, onReturn] in
            guard ComposerSendKeyPolicy.commandReturnSends(
                canSend: canSend, hasMarkedText: uiView?.markedTextRange != nil
            ) else { return false }
            onReturn()
            return true
        }
        let returnKey: UIReturnKeyType = softwareReturnSends ? .send : .default
        if uiView.returnKeyType != returnKey {
            uiView.returnKeyType = returnKey
        }
        if uiView.placeholderLabel.text != placeholder {
            uiView.placeholderLabel.text = placeholder
        }
        uiView.accessibilityLabel = placeholder
        uiView.placeholderLabel.isHidden = !text.isEmpty
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: HardwareReturnTextView,
        context: Context
    ) -> CGSize? {
        let proposed = proposal.width
        // Measurement width priority: the width SwiftUI actually proposes,
        // else the width the view is laid out at, else the width the host
        // row actually gives the field (measured), else the historical
        // 320pt fallback. A restored/pasted large draft on a surface that
        // places the slot without a finite proposal must still be measured
        // at the row's real width, not at a guessed 320.
        let width = max(proposed.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
            ?? (uiView.bounds.width > 1 ? uiView.bounds.width : nil)
            ?? hostAvailableWidth.flatMap { $0 > 1 ? $0 : nil }
            ?? 320, 1)
        // The height this pass reports must correspond to the width this
        // pass was asked about; `ComposerFieldLayout.verdict` applies the
        // existing line budget (6 compact / 8 regular), the one-third
        // available-height rule and the resting minimum. `scrolls` is the
        // real layout verdict — the measured natural TextKit height has
        // passed the cap, so the tail of the text is no longer visible
        // inline. The verdict is applied on the next main-queue turn
        // together with the host report: `sizeThatFits` runs inside
        // SwiftUI's layout pass, and mutating the live view there
        // (isScrollEnabled flips intrinsic invalidation) is one half of
        // the synchronous layout feedback loop behind the build-272
        // composer stack overflow.
        let verdict = self.verdict(
            at: width,
            textView: uiView,
            coordinator: context.coordinator
        )
        // Host delivery uses the width the field is actually laid out at
        // when that is known; the proposal is only the pre-layout fallback.
        // SwiftUI's sizing probes (nil / 0 / .infinity) never toggled the
        // host control before either — but relying on a real proposal at
        // all was the bug: the final exact placement inside the composer
        // HStack may not re-run `sizeThatFits`, so a large draft could sit
        // clipped in a slot-width layout with no verdict ever delivered
        // and `composer.expand` never appearing. A burst of passes
        // coalesces to the newest verdict inside the coordinator.
        let laidOutWidth = uiView.bounds.width > 1 ? uiView.bounds.width : nil
        let truthWidth = laidOutWidth
            ?? proposed.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
            ?? hostAvailableWidth.flatMap { $0 > 1 ? $0 : nil }
        if let truthWidth {
            let hostVerdict = truthWidth == width
                ? verdict
                : self.verdict(at: truthWidth, textView: uiView,
                               coordinator: context.coordinator)
            context.coordinator.scheduleOverflowReport(
                hostVerdict.scrolls,
                canExpand: hostVerdict.canExpand,
                height: hostVerdict.height,
                textView: uiView,
                report: context.coordinator.field.onOverflowChange ?? onOverflowChange
            )
        }
        return CGSize(width: width, height: verdict.height)
    }

    /// The one rule, at one width, for every producer: measure the natural
    /// detached TextKit height and the one-line height at `width` (both
    /// memoized per text generation / width / content-size category), then
    /// apply the shared `ComposerFieldLayout` budget. Used by the sizing
    /// pass, the live view's layout pass and the keystroke pass alike, so
    /// the height the field reports and the overflow the host shows can
    /// never disagree about which width was measured.
    func verdict(
        at width: CGFloat,
        textView: HardwareReturnTextView,
        coordinator: Coordinator
    ) -> ComposerFieldLayout.Verdict {
        let sizeClass = textView.traitCollection.horizontalSizeClass
        let category = textView.traitCollection.preferredContentSizeCategory
        let natural = coordinator.cachedNaturalMetrics(
            width: width,
            contentSizeCategory: category
        ) { [self] in
            measuredNaturalText(of: textView, width: width)
        }
        // Uniform single-line fragments stack exactly: an N-line budget is
        // N × the memoized one-line height.
        let lineHeight = coordinator.cachedLineHeight(
            width: width,
            contentSizeCategory: category
        ) { [self] in
            Self.textKitHeight(
                of: FloeL10n.l("design.composer_return_field.chars"),
                width: contentWidth(width),
                font: textView.font ?? bodyFont
            )
        }
        return ComposerFieldLayout.verdict(
            naturalTextHeight: natural.height,
            lineHeight: lineHeight,
            verticalInsets: textInsets.top + textInsets.bottom,
            lineLimit: lineLimit,
            deviceLineCap: ComposerFieldMetrics.lineCap(horizontalSizeClass: sizeClass),
            availableHeight: maxHeightBudget,
            restingMinimumHeight: restingMinHeight,
            visualLineCount: natural.lineCount
        )
    }

    /// The re-derive hop `updateUIView` takes for every accepted content,
    /// font, budget or host-width change: invalidate SwiftUI's cached
    /// measurement AND re-derive the overflow verdict immediately at the
    /// best known REAL width — the laid-out bounds first, else the host
    /// row's measured width. A host that answers the new content from a
    /// cached sizing pass without ever proposing a finite width again (the
    /// New Task launchpad's bottom `safeAreaInset` band) still converges,
    /// because the verdict no longer depends on a hypothetical sizing run.
    /// Extracted as the single production statement so behavior tests drive
    /// exactly it rather than an equivalent.
    func requestRemeasureHop(
        uiView: HardwareReturnTextView,
        coordinator: Coordinator
    ) {
        uiView.invalidateIntrinsicContentSize()
        if uiView.bounds.width > 1 {
            coordinator.noteLaidOutWidth(uiView.bounds.width, in: uiView)
        } else if let hostAvailableWidth, hostAvailableWidth > 1 {
            coordinator.noteHostAvailableWidth(hostAvailableWidth, in: uiView)
        }
    }

    // MARK: - Measurement

    private var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    private func contentWidth(_ width: CGFloat) -> CGFloat {
        max(width - textInsets.left - textInsets.right, 1)
    }

    /// Measure only a detached TextKit stack. Even requesting live layout
    /// here can re-enter UIKit while SwiftUI is measuring this view. The
    /// coordinator memo avoids repeating work for the same content and width.
    private func measuredNaturalText(of uiView: UITextView, width: CGFloat) -> MeasuredComposerText {
        let textWidth = contentWidth(width)
        if uiView.textStorage.string.isEmpty {
            return MeasuredComposerText(
                height: Self.textKitHeight(
                    of: FloeL10n.l("design.composer_return_field.chars"),
                    width: textWidth,
                    font: bodyFont
                ) + textInsets.top + textInsets.bottom,
                lineCount: 1
            )
        }
        let metrics = ComposerFieldMeasurement.detachedMetrics(
            of: uiView.textStorage,
            width: textWidth,
            fallbackFont: uiView.font ?? bodyFont
        )
        return MeasuredComposerText(
            height: metrics.height + textInsets.top + textInsets.bottom,
            lineCount: metrics.lineCount
        )
    }

    private static func textKitHeight(of string: String, width: CGFloat, font: UIFont) -> CGFloat {
        let storage = NSTextStorage(string: string, attributes: [.font: font])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(for: container)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.height
    }

    // MARK: - Delegate

    final class Coordinator: NSObject, UITextViewDelegate {
        var field: ComposerReturnField
        /// Bumped on every real text mutation; keys the height memo so
        /// unchanged text never re-measures.
        private var contentGeneration = 0
        /// Natural metrics memo: height and painted rows from one layout,
        /// keyed exactly like the old height-only memo.
        private var naturalMetricsMemo = ComposerFieldMetrics.MetricsCache()
        /// One-line height, keyed by width + content-size category only.
        private var lineHeightMemo = ComposerFieldMetrics.HeightCache()
        /// Last selection this coordinator restored or reported, so the
        /// update cycle never re-applies (and never echoes) the same range.
        private var lastAppliedSelection: NSRange?
        private var lastReportedSelection: NSRange?
        /// One overflow delivery hop at a time: a layout burst overwrites
        /// the pending verdict instead of queueing another block, so only
        /// the newest measured revision reaches the host and older queued
        /// width/layout reports cannot bounce the host's control.
        private var pendingOverflowReport = false
        private var latestCanExpand: Bool?
        private var latestOverflow: Bool?
        private var latestOverflowCallback: ((Bool) -> Void)?
        /// Newest measured height and its host callback. Delivered on the
        /// same coalesced hop as the overflow verdict so the host's slot and
        /// the field's own laid-out height change in one update; change-only
        /// so a steady layout never churns the host.
        private var latestHeight: (value: CGFloat, callback: ((CGFloat) -> Void)?)?
        private var lastDeliveredHeight: CGFloat?
        /// Live view the pending verdict belongs to, so the deferred
        /// `isScrollEnabled` change is applied to the same field that was
        /// measured (never a reused coordinator's older view).
        private weak var latestOverflowView: HardwareReturnTextView?
        /// A container transition measured while an input method held
        /// marked text: kept (never dropped) and applied the moment the
        /// composition commits. The flip reconfigures the NSTextContainer,
        /// which must not happen mid-candidate.
        private var deferredScrollTarget: Bool?
        private weak var deferredScrollView: HardwareReturnTextView?

        init(field: ComposerReturnField) {
            self.field = field
        }

        /// Coalescing overflow reporter. Called from `sizeThatFits`, the
        /// live view's layout pass and the keystroke pass, all on the main
        /// thread; delivers on the next main-queue turn (never
        /// synchronously from layout). Repeated calls while a delivery is
        /// pending keep only the latest verdict, view and callback. The
        /// measured view's `isScrollEnabled` is applied in the same deferred
        /// hop: changing it inside SwiftUI's layout pass is what re-entered
        /// UIKit layout on build 272.
        func scheduleOverflowReport(
            _ overflow: Bool,
            canExpand: Bool? = nil,
            height: CGFloat? = nil,
            textView: HardwareReturnTextView?,
            report: ((Bool) -> Void)?
        ) {
            latestOverflowView = textView
            latestOverflow = overflow
            latestCanExpand = canExpand
            latestOverflowCallback = report
            if let height { latestHeight = (height, field.onHeightChange) }
            let needsScrollChange = textView.map { $0.isScrollEnabled != overflow } ?? false
            let heightChanged = height.map { value in
                lastDeliveredHeight.map { abs($0 - value) >= 0.5 } ?? true
            } ?? false
            guard needsScrollChange || report != nil
                || field.onExpansionAvailableChange != nil
                || heightChanged else { return }
            guard !pendingOverflowReport else { return }
            pendingOverflowReport = true
            DispatchQueue.main.async { [weak self] in
                self?.deliverPendingOverflowReport()
            }
        }

        private func deliverPendingOverflowReport() {
            pendingOverflowReport = false
            let overflow = latestOverflow
            let canExpand = latestCanExpand
            latestCanExpand = nil
            let report = latestOverflowCallback
            let height = latestHeight
            latestHeight = nil
            let textView = latestOverflowView
            latestOverflow = nil
            latestOverflowCallback = nil
            latestOverflowView = nil
            if let overflow, let textView, textView.isScrollEnabled != overflow {
                if ComposerIMEPolicy.allowsScrollTransition(
                    hasMarkedText: textView.hasActiveComposition
                ) {
                    // The one seam for scroll flips: it re-pins the composer
                    // container contract (width tracking + zero padding) so the
                    // LIVE text keeps wrapping at the actual laid-out width in
                    // both states, and reveals the caret the moment the field
                    // starts to scroll internally.
                    textView.applyComposerScrollState(overflow, revealCaret: overflow)
                    deferredScrollTarget = nil
                    deferredScrollView = nil
                } else {
                    // A Chinese-IME (or any marked-text) composition owns the
                    // editing run right now: the flip reconfigures the
                    // NSTextContainer and must not disturb it. Remember the
                    // verdict and re-derive on composition end — never mutate
                    // marked text, never silently drop the transition.
                    deferredScrollTarget = overflow
                    deferredScrollView = textView
                }
            }
            guard let overflow else { return }
            // The host signal is pure SwiftUI state (the expand control's
            // visibility); delivering it cannot touch the text container, so
            // IME composition never defers the report itself.
            report?(overflow)
            if let canExpand { field.onExpansionAvailableChange?(canExpand) }
            if let height, let callback = height.callback,
               lastDeliveredHeight.map({ abs($0 - height.value) >= 0.5 }) ?? true {
                lastDeliveredHeight = height.value
                callback(height.value)
            }
            textView?.revealCurrentCaretAfterLayout()
        }

        /// Applies whatever the layout actually requires NOW that an input
        /// method's composition has ended: NOT the boolean remembered during
        /// composition (marked text inflates the measurement), but a fresh
        /// verdict re-derived from the committed text at the real width.
        /// Called from the delegate seams that observe composition end
        /// (text change, selection change, editing end); refuses while a
        /// composition is still active.
        func flushDeferredTransition(in textView: HardwareReturnTextView) {
            guard deferredScrollTarget != nil, deferredScrollView === textView else { return }
            guard ComposerIMEPolicy.allowsScrollTransition(
                hasMarkedText: textView.hasActiveComposition
            ) else { return }
            deferredScrollTarget = nil
            deferredScrollView = nil
            if textView.bounds.width > 1 {
                noteLaidOutWidth(textView.bounds.width, in: textView)
            } else if let width = field.hostAvailableWidth, width > 1 {
                noteHostAvailableWidth(width, in: textView)
            }
        }

        /// Re-derives the overflow verdict at the width the host row
        /// ACTUALLY gives this field, before/without any laid-out frame or
        /// SwiftUI sizing proposal (the New Task launchpad measures its
        /// bottom band through a `safeAreaInset`, where a real finite
        /// proposal is not guaranteed on every content change).
        func noteHostAvailableWidth(_ width: CGFloat, in textView: HardwareReturnTextView) {
            let verdict = field.verdict(at: width, textView: textView, coordinator: self)
            scheduleOverflowReport(
                verdict.scrolls,
                canExpand: verdict.canExpand,
                height: verdict.height,
                textView: textView,
                report: field.onOverflowChange
            )
        }

        func noteTextChange() {
            contentGeneration += 1
            // An undelivered verdict was measured against older text (or a
            // draft that belonged to the previous conversation — the same
            // field view is reused across task switches). Drop it: a later
            // pass at the laid-out width re-measures and re-reports the new
            // truth, so a stale verdict can never toggle the host's
            // full-editor control for a draft it never measured. The same
            // rule retires a transition deferred during composition — the
            // freshest measurement (keystroke end of this handler, or the
            // updateUIView re-derive after a programmatic swap) re-establishes
            // it against the CURRENT text.
            latestOverflow = nil
            latestCanExpand = nil
            latestHeight = nil
            deferredScrollTarget = nil
            deferredScrollView = nil
        }

        /// Re-derives the overflow verdict at the width this view was just
        /// laid out at. Called from UIKit's own layout pass (never inside
        /// SwiftUI's), so the detached measurement and the coalesced report
        /// hop are both safe here. This is the guarantee that the host's
        /// `composer.expand` control reflects the ACTUAL bounded width —
        /// rotation, split-view drags, keyboard height changes and the
        /// control's own width feedback all funnel through it.
        func noteLaidOutWidth(_ width: CGFloat, in textView: HardwareReturnTextView) {
            let verdict = field.verdict(at: width, textView: textView, coordinator: self)
            scheduleOverflowReport(
                verdict.scrolls,
                canExpand: verdict.canExpand,
                height: verdict.height,
                textView: textView,
                report: field.onOverflowChange
            )
        }

        func noteAppliedSelection(_ selection: NSRange?) {
            lastAppliedSelection = selection
            lastReportedSelection = selection
        }

        /// Restores a caret captured elsewhere once the text exists. Skipped
        /// while the user is editing this field, and idempotent per range.
        func applyRestoredSelectionIfNeeded(in textView: UITextView) {
            guard let target = ComposerSelection.clamped(
                field.restoredSelection,
                utf16Length: (textView.text as NSString).length
            ) else { return }
            guard textView.selectedRange != target, lastAppliedSelection != target else { return }
            lastAppliedSelection = target
            textView.selectedRange = target
        }

        func cachedNaturalMetrics(
            width: CGFloat,
            contentSizeCategory: UIContentSizeCategory,
            compute: () -> MeasuredComposerText
        ) -> MeasuredComposerText {
            naturalMetricsMemo.value(
                generation: contentGeneration,
                width: width,
                contentSizeCategory: contentSizeCategory,
                compute: compute
            )
        }

        func cachedLineHeight(
            width: CGFloat,
            contentSizeCategory: UIContentSizeCategory,
            compute: () -> CGFloat
        ) -> CGFloat {
            // Constant generation: the one-line height depends only on the
            // proposed width and the content-size category.
            lineHeightMemo.value(
                generation: 0,
                width: width,
                contentSizeCategory: contentSizeCategory,
                compute: compute
            )
        }

        func textViewDidChange(_ textView: UITextView) {
            let hardware = textView as? HardwareReturnTextView
            // Cancels any undelivered verdict measured against the
            // pre-keystroke text before re-deriving below.
            noteTextChange()
            // Then: a composition that just ended (or never existed) lets
            // any transition deferred during it land against fresh truth.
            if let hardware {
                flushDeferredTransition(in: hardware)
            }
            field.text = textView.text
            // Scroll-enabled UITextView has no useful intrinsic height. Ask
            // SwiftUI to remeasure after each user edit, without mutating
            // layout from inside sizeThatFits.
            textView.invalidateIntrinsicContentSize()
            placeholderLabel(of: textView)?.isHidden = !textView.text.isEmpty
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
                (textView as? HardwareReturnTextView)?.revealCurrentCaretAfterLayout()
            }
            // The keystroke itself is the freshest possible overflow truth:
            // re-derive at the laid-out width so deleting back under the cap
            // hides the full-editor control immediately, even if SwiftUI
            // answers the new height from a sizing path that never reaches
            // the host report.
            if let hardware, hardware.bounds.width > 1 {
                noteLaidOutWidth(hardware.bounds.width, in: hardware)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Candidate-window navigation ends a composition with or
            // without a delegate text change; land any deferred transition
            // against fresh truth the moment marked text is gone.
            if let hardware = textView as? HardwareReturnTextView {
                flushDeferredTransition(in: hardware)
            }
            // Hardware-arrow navigation past the cap must keep the caret
            // visible even when the text itself did not change.
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
                (textView as? HardwareReturnTextView)?.revealCurrentCaretAfterLayout()
            }
            reportSelectionIfChanged(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            field.onEditingChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            field.onEditingChange?(false)
            if let hardware = textView as? HardwareReturnTextView {
                flushDeferredTransition(in: hardware)
            }
            reportSelectionIfChanged(textView)
        }

        /// Persists the live caret so the full editor can reopen at exactly
        /// that position (and the store can restore it after a relaunch).
        private func reportSelectionIfChanged(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range != lastReportedSelection else { return }
            lastReportedSelection = range
            lastAppliedSelection = range
            field.onSelectionChange?(range)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            // Sending moved to Cmd+Return; the software return key sends
            // only on the surfaces that opted in. Everything else — plain
            // Return, Shift+Return, IME commit — inserts a newline.
            guard field.softwareReturnSends, field.canSend else { return true }
            field.onReturn()
            return false
        }

        private func placeholderLabel(of textView: UITextView) -> UILabel? {
            (textView as? HardwareReturnTextView)?.placeholderLabel
        }
    }
}

// MARK: - Responsive composer row (field + natural controls)

/// Marks the one editable field slot inside `ComposerResponsiveRowLayout`.
/// The layout finds the field by this value rather than by declaration
/// index, so optional controls (attachment menu, Expand, Stop) never shift
/// which subview is measured as the text column.
struct ComposerResponsiveFieldSlotKey: LayoutValueKey {
    static let defaultValue = false
}

/// Marks a control that keeps the leading edge when the row reflows. The
/// attachment menu does; every action control (Expand, dictation, continuous
/// voice, Stop, Send) trails on the right, exactly as it does in one row.
struct ComposerResponsiveLeadingControlKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Declares this subview as the row's editable text field.
    func composerResponsiveFieldSlot() -> some View {
        layoutValue(key: ComposerResponsiveFieldSlotKey.self, value: true)
    }

    /// Declares this subview as one of the row's leading-edge controls.
    func composerResponsiveLeadingControl() -> some View {
        layoutValue(key: ComposerResponsiveLeadingControlKey.self, value: true)
    }
}

/// One composer input row: the live field and its natural controls, placed
/// side by side while the text keeps a usable column, or field above a
/// controls row when it does not (see `ComposerResponsiveLayoutPolicy`).
///
/// The reflow is pure placement inside ONE `Layout`: the `ComposerReturnField`
/// subview — and therefore its `HardwareReturnTextView`, coordinator, first
/// responder, caret, marked text and undo association — is never re-created,
/// so a Chinese-IME composition or an active keyboard session survives the
/// flip untouched. That is why this row uses neither `ViewThatFits` nor two
/// conditional branches: both would remount the editing surface mid-IME, and
/// choosing per keystroke from a remounting branch would drop focus.
struct ComposerResponsiveRowLayout: Layout {
    /// Gap between adjacent items on one row.
    var spacing: CGFloat = 8
    /// Gap between the field row and the control row when stacked.
    var stackedSpacing: CGFloat = 6
    /// The host's live overflow verdict for the field (it scrolls at its
    /// current width). Stacks the row: the draft is multiline at its widest
    /// available slot too, so the text deserves the whole width.
    var isFieldOverflowing = false

    private struct Plan {
        var isStacked = false
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fieldIndex = 0
        var fieldSize: CGSize = .zero
        var controlIndices: [Int] = []
        var controlSizes: [CGSize] = []
        var maxControlHeight: CGFloat = 0
    }

    private func plan(subviews: Subviews, proposal: ProposedViewSize) -> Plan {
        var plan = Plan()
        guard !subviews.isEmpty else { return plan }
        plan.fieldIndex = subviews.indices.first {
            subviews[$0][ComposerResponsiveFieldSlotKey.self]
        } ?? 0
        plan.controlIndices = subviews.indices.filter { $0 != plan.fieldIndex }
        plan.controlSizes = plan.controlIndices.map { subviews[$0].sizeThatFits(.unspecified) }
        let controlsWidth = plan.controlSizes.reduce(0) { $0 + $1.width }
        plan.maxControlHeight = plan.controlSizes.map(\.height).max() ?? 0
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            // A zero/one-point proposal is a collapsed host: report an empty
            // row instead of measuring a meaningless 1pt text column.
            guard proposedWidth > 1 else { return plan }
            plan.width = proposedWidth
        } else {
            // Unbounded sizing probe: ask for the natural row (the field's
            // own ideal width plus the controls) rather than a guess. Only
            // this branch pays for the extra ideal-width measurement, so a
            // bounded pass never remeasures the draft a third time.
            let idealField = subviews[plan.fieldIndex].sizeThatFits(.unspecified)
            plan.width = idealField.width + controlsWidth
                + spacing * CGFloat(plan.controlIndices.count)
        }
        let inlineWidth = ComposerResponsiveLayoutPolicy.inlineTextWidth(
            rowWidth: plan.width,
            controlsWidth: controlsWidth,
            controlsCount: plan.controlIndices.count,
            spacing: spacing
        )
        let inlineField = subviews[plan.fieldIndex].sizeThatFits(
            ProposedViewSize(width: inlineWidth, height: nil)
        )
        let fullField = subviews[plan.fieldIndex].sizeThatFits(
            ProposedViewSize(width: plan.width, height: nil)
        )
        plan.isStacked = ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: plan.width,
            controlsWidth: controlsWidth,
            controlsCount: plan.controlIndices.count,
            spacing: spacing,
            fieldHeightAtInlineWidth: inlineField.height,
            fieldHeightAtFullWidth: fullField.height,
            isFieldOverflowing: isFieldOverflowing
        )
        plan.fieldSize = plan.isStacked
            ? CGSize(width: plan.width, height: fullField.height)
            : CGSize(width: inlineWidth, height: inlineField.height)
        plan.height = plan.isStacked
            ? plan.fieldSize.height + stackedSpacing + plan.maxControlHeight
            : max(plan.fieldSize.height, plan.maxControlHeight)
        return plan
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let plan = plan(subviews: subviews, proposal: proposal)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard !subviews.isEmpty else { return }
        // Re-plan from the space actually granted (a parent may clamp the
        // proposal) so placement can never use a different mode than sizing.
        let plan = plan(
            subviews: subviews,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
        guard plan.width > 1 else {
            for index in subviews.indices {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: .zero
                )
            }
            return
        }
        if plan.isStacked {
            placeStacked(plan, in: bounds, subviews: subviews)
        } else {
            placeInline(plan, in: bounds, subviews: subviews)
        }
    }

    /// One compact row, bottom-aligned like the historical composer HStack:
    /// attachment, the field taking the remaining width, then the actions.
    private func placeInline(_ plan: Plan, in bounds: CGRect, subviews: Subviews) {
        var x = bounds.minX
        var controlPosition = 0
        for index in subviews.indices {
            let size: CGSize
            if index == plan.fieldIndex {
                size = plan.fieldSize
            } else {
                size = plan.controlSizes[controlPosition]
                controlPosition += 1
            }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.maxY - size.height),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
        }
    }

    /// Field across the full row, then its controls directly below: leading
    /// group (the attachment menu) on the left edge, every action control
    /// right-aligned in declaration order.
    private func placeStacked(_ plan: Plan, in bounds: CGRect, subviews: Subviews) {
        subviews[plan.fieldIndex].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(plan.fieldSize)
        )
        let rowTop = bounds.minY + plan.fieldSize.height + stackedSpacing
        // Bottom-align every control inside the control row, so a control
        // that reports a taller accessible frame (Dynamic Type, larger hit
        // target) still shares one visual baseline.
        func place(_ index: Int, size: CGSize, atX x: CGFloat) {
            subviews[index].place(
                at: CGPoint(x: x, y: rowTop + plan.maxControlHeight - size.height),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
        var leading: [(index: Int, size: CGSize)] = []
        var trailing: [(index: Int, size: CGSize)] = []
        for (position, index) in plan.controlIndices.enumerated() {
            let size = plan.controlSizes[position]
            if subviews[index][ComposerResponsiveLeadingControlKey.self] {
                leading.append((index, size))
            } else {
                trailing.append((index, size))
            }
        }
        var x = bounds.minX
        for control in leading {
            place(control.index, size: control.size, atX: x)
            x += control.size.width + spacing
        }
        var trailingWidth = trailing.reduce(0) { $0 + $1.size.width }
        if trailing.count > 1 { trailingWidth += spacing * CGFloat(trailing.count - 1) }
        x = bounds.maxX - trailingWidth
        for control in trailing {
            place(control.index, size: control.size, atX: x)
            x += control.size.width + spacing
        }
    }
}

/// Host-facing wrapper for `ComposerResponsiveRowLayout`: pass the row's
/// natural controls and exactly one `.composerResponsiveFieldSlot()` field.
struct ComposerResponsiveRow<Content: View>: View {
    var spacing: CGFloat = 8
    var stackedSpacing: CGFloat = 6
    var isFieldOverflowing = false
    var content: Content

    init(
        spacing: CGFloat = 8,
        stackedSpacing: CGFloat = 6,
        isFieldOverflowing: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.stackedSpacing = stackedSpacing
        self.isFieldOverflowing = isFieldOverflowing
        self.content = content()
    }

    var body: some View {
        // A custom `Layout` is used as the container itself (its
        // `callAsFunction` builder), which is what gives the subviews stable
        // identities across reflow: the same field subview is re-placed, not
        // re-created, so an active editing session survives.
        ComposerResponsiveRowLayout(
            spacing: spacing,
            stackedSpacing: stackedSpacing,
            isFieldOverflowing: isFieldOverflowing
        ) {
            content
        }
    }
}

/// Text measurement isolated from the live view's layout callbacks.
/// The coordinator caches results by content revision, width and text size.
@MainActor
enum ComposerFieldMeasurement {
    /// Height of `storage` wrapped at `width`, without any view mutation.
    /// The natural height AND the number of visible rows, from ONE detached
    /// layout. The expand control is gated on the row count, never on a
    /// fractional height comparison, so a two-line draft can never reveal
    /// the third-line editor because its measured height rounded just past
    /// a separately measured one-line yardstick.
    static func detachedMetrics(
        of storage: NSTextStorage,
        width: CGFloat,
        fallbackFont: UIFont? = nil
    ) -> MeasuredComposerText {
        let boundedWidth = max(width, 1)
        let detachedStorage: NSTextStorage
        if let fallbackFont {
            // Composer content is plain text. Reading a live NSTextStorage's
            // attributes can lazily synthesize 12pt fonts before they can be
            // filled. Copy only characters and use the ACTUAL visible font;
            // no attribute/layout access can normalize the live storage.
            detachedStorage = NSTextStorage(string: storage.string, attributes: [.font: fallbackFont])
        } else {
            detachedStorage = NSTextStorage(attributedString: storage)
        }
        let container = NSTextContainer(size: CGSize(
            width: boundedWidth,
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.lineBreakMode = .byWordWrapping
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        detachedStorage.addLayoutManager(manager)
        // `glyphRange` forces layout for the container; `usedRect` is then the
        // same quantity `sizeThatFits` reports for the live field.
        let glyphs = manager.glyphRange(for: container)
        var lineCount = 0
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
            if usedRect.height > 0.5 { lineCount += 1 }
        }
        // `enumerateLineFragments` skips the empty fragment a trailing
        // newline adds, but the user sees that caret row; count it so a
        // draft ending in a newline offers the editor on its third row, not
        // its fourth.
        if detachedStorage.string.hasSuffix("\n") { lineCount += 1 }
        let usedHeight = manager.usedRect(for: container).maxY
        // TextKit can keep the final empty caret row outside usedRect. The
        // host must reserve that row too, otherwise pressing Return hides
        // the insertion point even though the visual line count is correct.
        let caretRowHeight = manager.extraLineFragmentTextContainer === container
            ? manager.extraLineFragmentUsedRect.maxY : 0
        return MeasuredComposerText(
            height: max(usedHeight, caretRowHeight),
            lineCount: max(1, lineCount)
        )
    }

    /// Height-only compatibility wrapper (existing callers/tests).
    static func detachedHeight(of storage: NSTextStorage, width: CGFloat, fallbackFont: UIFont? = nil) -> CGFloat {
        detachedMetrics(of: storage, width: width, fallbackFont: fallbackFont).height
    }
}
#endif
