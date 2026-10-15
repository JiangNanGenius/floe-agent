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

    override var undoManager: UndoManager? {
        sharedUndoManager ?? super.undoManager
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
    /// scrolls internally (true) or fits completely (false). The report is
    /// delivered on the next main-queue turn, never synchronously from the
    /// layout pass; a burst of layout passes coalesces to the newest
    /// measured verdict, so the host always converges to the field's
    /// current truth (including after it resets its own state on a
    /// conversation switch). Nil keeps callers that do not need the signal
    /// unchanged.
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
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = textInsets
        view.textContainer.lineFragmentPadding = 0
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
        // Text first, selection second: a saved non-zero caret cannot be
        // applied to an empty view (it would be clamped away).
        ComposerSelection.prepare(view, text: text, selection: restoredSelection)
        context.coordinator.noteAppliedSelection(restoredSelection)
        return view
    }

    func updateUIView(_ uiView: HardwareReturnTextView, context: Context) {
        // Coordinators outlive individual SwiftUI value snapshots. Refresh
        // the snapshot so send availability and the callback track the
        // current draft/model state instead of the initial empty field.
        context.coordinator.field = self
        uiView.sharedUndoManager = undoManager
        // Never clobber in-flight IME composition or echo the user's own edit.
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
            context.coordinator.noteTextChange()
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
        let width = max(proposal.width ?? 320, 1)
        let sizeClass = UITraitCollection.current.horizontalSizeClass
        let category = UITraitCollection.current.preferredContentSizeCategory
        let deviceCap = ComposerFieldMetrics.lineCap(horizontalSizeClass: sizeClass)
        let upperBound = max(1, min(lineLimit.upperBound, deviceCap))

        let natural = context.coordinator.cachedNaturalHeight(
            width: width,
            contentSizeCategory: category
        ) { [self] in
            measuredNaturalHeight(of: uiView, width: width)
        }
        // Uniform single-line fragments stack exactly: an N-line budget is
        // N × the memoized one-line height.
        let lineHeight = context.coordinator.cachedLineHeight(
            width: width,
            contentSizeCategory: category
        ) { [self] in
            Self.textKitHeight(of: FloeL10n.l("design.composer_return_field.chars"), width: contentWidth(width), font: bodyFont)
        }
        let insets = textInsets.top + textInsets.bottom
        let cap = ComposerFieldMetrics.heightCap(
            lineCapHeight: lineHeight * CGFloat(upperBound) + insets,
            availableHeight: maxHeightBudget
        )
        let floor = max(
            restingMinHeight,
            lineHeight * CGFloat(max(1, lineLimit.lowerBound)) + insets
        )
        let scrolls = natural > cap
        // The scroll verdict is applied on the next main-queue turn together
        // with the host report: `sizeThatFits` runs inside SwiftUI's layout
        // pass, and mutating the live view there (isScrollEnabled flips
        // intrinsic invalidation) is one half of the synchronous layout
        // feedback loop behind the build-272 composer stack overflow. The
        // measured height above is unaffected by the deferred flag.
        // `scrolls` is the real layout verdict the user sees: the natural
        // TextKit height has passed the cap, so the tail of the text is no
        // longer visible inline. The host is told after this pass —
        // mutating SwiftUI state inside layout would be a synchronous
        // update during view update — and the coordinator coalesces a
        // layout burst down to the latest verdict. Zero, unit and
        // non-finite widths are SwiftUI probes, not the inline layout, so
        // they must not toggle the host's control. The callback is read
        // from the coordinator so it tracks the latest snapshot.
        if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 1 {
            context.coordinator.scheduleOverflowReport(
                scrolls,
                textView: uiView,
                report: context.coordinator.field.onOverflowChange ?? onOverflowChange
            )
        }
        return CGSize(width: width, height: min(max(natural, floor), cap))
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
            width: textWidth
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

        /// Coalescing overflow reporter. Called from `sizeThatFits` on the
        /// main thread; delivers on the next main-queue turn (never
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
            }
            guard let overflow else { return }
            report?(overflow)
        }

        func noteTextChange() {
            contentGeneration += 1
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
            contentGeneration += 1
            field.text = textView.text
            placeholderLabel(of: textView)?.isHidden = !textView.text.isEmpty
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
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
    static func detachedHeight(of storage: NSTextStorage, width: CGFloat) -> CGFloat {
        let boundedWidth = max(width, 1)
        let detachedStorage = NSTextStorage(attributedString: storage)
        let container = NSTextContainer(size: CGSize(
            width: boundedWidth,
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
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
