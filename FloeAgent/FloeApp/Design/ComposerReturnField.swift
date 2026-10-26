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

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

import FloeCore
/// UITextView that intercepts hardware Cmd+Return for sending. The press is
/// consumed only when the handler reports the send actually fired; every
/// other Return (plain, Shift+, during IME composition) keeps its default
/// newline behavior.
final class HardwareReturnTextView: UITextView {
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

    private var lastNotifiedLayoutWidth: CGFloat = -1

    override var undoManager: UndoManager? {
        sharedUndoManager ?? super.undoManager
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
    var lineLimit: ClosedRange<Int> = 1...5
    /// Height available to the hosting page; the field never grows beyond
    /// one third of it. Nil disables the height rule.
    var maxHeightBudget: CGFloat? = nil
    /// Caret/selection captured in the full editor (or on the previous
    /// launch). Applied only once the initial text exists and only while the
    /// user is not editing, so it never fights the live caret.
    var restoredSelection: NSRange? = nil
    /// Undo manager shared with the expanded editor; nil keeps UIKit's own.
    var undoManager: UndoManager? = nil
    /// Reports the live caret/selection so the caller can persist it and the
    /// full editor can reopen exactly where editing stopped.
    var onSelectionChange: ((NSRange?) -> Void)? = nil
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
    var onReturn: () -> Void

    private let textInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    /// Classic 44pt composer row; the `lineLimit.lowerBound` may push the
    /// resting height beyond this (e.g. a two-line canvas prompt field).
    private let restingMinHeight: CGFloat = 44

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeUIView(context: Context) -> HardwareReturnTextView {
        let view = HardwareReturnTextView()
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
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textContainer.lineBreakMode = .byWordWrapping
        view.textContainer.widthTracksTextView = true
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
        if uiView.markedTextRange == nil, uiView.font != font {
            uiView.font = font
            uiView.placeholderLabel.font = font
            context.coordinator.noteTextChange()
            needsRemeasure = true
        }
        // Never clobber in-flight IME composition or echo the user's own edit.
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
            context.coordinator.noteTextChange()
            needsRemeasure = true
        }
        if previous.maxHeightBudget != maxHeightBudget || previous.lineLimit != lineLimit {
            needsRemeasure = true
        }
        // A programmatic draft swap (dictation landing, slash command, the
        // send clear, a restored or conversation-switched draft) or a
        // budget/line-limit change at the SAME laid-out width produces no
        // `layoutSubviews` width notification: the intrinsic invalidation
        // hop is what asks SwiftUI for one fresh sizing pass, whose real
        // proposal then re-derives and re-reports the overflow verdict.
        // This runs during the state update — never inside layout — so the
        // deferred coalescing stays loop-free.
        if needsRemeasure {
            uiView.invalidateIntrinsicContentSize()
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
        let width = max(proposed.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
            ?? (uiView.bounds.width > 1 ? uiView.bounds.width : 320), 1)
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
        if let truthWidth {
            let hostVerdict = truthWidth == width
                ? verdict
                : self.verdict(at: truthWidth, textView: uiView,
                               coordinator: context.coordinator)
            context.coordinator.scheduleOverflowReport(
                hostVerdict.scrolls,
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
        let natural = coordinator.cachedNaturalHeight(
            width: width,
            contentSizeCategory: category
        ) { [self] in
            measuredNaturalHeight(of: textView, width: width)
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
            naturalTextHeight: natural,
            lineHeight: lineHeight,
            verticalInsets: textInsets.top + textInsets.bottom,
            lineLimit: lineLimit,
            deviceLineCap: ComposerFieldMetrics.lineCap(horizontalSizeClass: sizeClass),
            availableHeight: maxHeightBudget,
            restingMinimumHeight: restingMinHeight
        )
    }

    // MARK: - Measurement

    private var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    private func contentWidth(_ width: CGFloat) -> CGFloat {
        max(width - textInsets.left - textInsets.right, 1)
    }

    /// Measure only a detached TextKit stack. Even requesting live layout
    /// here can re-enter UIKit while SwiftUI is measuring this view. The
    /// coordinator memo avoids repeating work for the same content and width.
    private func measuredNaturalHeight(of uiView: UITextView, width: CGFloat) -> CGFloat {
        let textWidth = contentWidth(width)
        if uiView.textStorage.string.isEmpty {
            return Self.textKitHeight(of: FloeL10n.l("design.composer_return_field.chars"), width: textWidth, font: bodyFont)
                + textInsets.top + textInsets.bottom
        }
        return ComposerFieldMeasurement.detachedHeight(
            of: uiView.textStorage,
            width: textWidth,
            fallbackFont: uiView.font ?? bodyFont
        ) + textInsets.top + textInsets.bottom
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
        private var naturalHeightMemo = ComposerFieldMetrics.HeightCache()
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
        private var latestOverflow: Bool?
        private var latestOverflowCallback: ((Bool) -> Void)?
        /// Live view the pending verdict belongs to, so the deferred
        /// `isScrollEnabled` change is applied to the same field that was
        /// measured (never a reused coordinator's older view).
        private weak var latestOverflowView: HardwareReturnTextView?

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
            textView: HardwareReturnTextView?,
            report: ((Bool) -> Void)?
        ) {
            latestOverflowView = textView
            latestOverflow = overflow
            latestOverflowCallback = report
            let needsScrollChange = textView.map { $0.isScrollEnabled != overflow } ?? false
            guard needsScrollChange || report != nil else { return }
            guard !pendingOverflowReport else { return }
            pendingOverflowReport = true
            DispatchQueue.main.async { [weak self] in
                self?.deliverPendingOverflowReport()
            }
        }

        private func deliverPendingOverflowReport() {
            pendingOverflowReport = false
            let overflow = latestOverflow
            let report = latestOverflowCallback
            let textView = latestOverflowView
            latestOverflow = nil
            latestOverflowCallback = nil
            latestOverflowView = nil
            if let overflow, let textView, textView.isScrollEnabled != overflow {
                textView.isScrollEnabled = overflow
                // UITextView reconfigures its NSTextContainer when the
                // scrolling state flips: re-assert the composer layout so
                // the LIVE text keeps wrapping at the actual laid-out
                // width in both states (a container that stopped tracking
                // width is how long text runs off instead of soft-wrapping)
                // and reveal the caret the moment the field starts to
                // scroll internally.
                textView.textContainer.widthTracksTextView = true
                textView.textContainer.lineFragmentPadding = 0
                if overflow {
                    textView.scrollRangeToVisible(textView.selectedRange)
                }
            }
            guard let overflow else { return }
            report?(overflow)
        }

        func noteTextChange() {
            contentGeneration += 1
            // An undelivered verdict was measured against older text (or a
            // draft that belonged to the previous conversation — the same
            // field view is reused across task switches). Drop it: a later
            // pass at the laid-out width re-measures and re-reports the new
            // truth, so a stale verdict can never toggle the host's
            // full-editor control for a draft it never measured.
            latestOverflow = nil
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

        func cachedNaturalHeight(
            width: CGFloat,
            contentSizeCategory: UIContentSizeCategory,
            compute: () -> CGFloat
        ) -> CGFloat {
            naturalHeightMemo.value(
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
            // Cancels any undelivered verdict measured against the
            // pre-keystroke text before re-deriving below.
            noteTextChange()
            field.text = textView.text
            // Scroll-enabled UITextView has no useful intrinsic height. Ask
            // SwiftUI to remeasure after each user edit, without mutating
            // layout from inside sizeThatFits.
            textView.invalidateIntrinsicContentSize()
            placeholderLabel(of: textView)?.isHidden = !textView.text.isEmpty
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
            // The keystroke itself is the freshest possible overflow truth:
            // re-derive at the laid-out width so deleting back under the cap
            // hides the full-editor control immediately, even if SwiftUI
            // answers the new height from a sizing path that never reaches
            // the host report.
            if let hardware = textView as? HardwareReturnTextView, hardware.bounds.width > 1 {
                noteLaidOutWidth(hardware.bounds.width, in: hardware)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Hardware-arrow navigation past the cap must keep the caret
            // visible even when the text itself did not change.
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
            reportSelectionIfChanged(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
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

/// Text measurement isolated from the live view's layout callbacks.
/// The coordinator caches results by content revision, width and text size.
@MainActor
enum ComposerFieldMeasurement {
    /// Height of `storage` wrapped at `width`, without any view mutation.
    static func detachedHeight(of storage: NSTextStorage, width: CGFloat, fallbackFont: UIFont? = nil) -> CGFloat {
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
        _ = manager.glyphRange(for: container)
        return manager.usedRect(for: container).height
    }
}
#endif
