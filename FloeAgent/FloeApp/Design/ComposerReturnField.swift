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
// Performance: the natural-height TextKit measurement is memoized per
// (text generation, width, content-size category) and reuses the view's
// own layout manager, so a 100k-character draft does not trigger a full
// re-layout on every keystroke or every layout pass.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

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
        return view
    }

    func updateUIView(_ uiView: HardwareReturnTextView, context: Context) {
        // Coordinators outlive individual SwiftUI value snapshots. Refresh
        // the snapshot so send availability and the callback track the
        // current draft/model state instead of the initial empty field.
        context.coordinator.field = self
        // Never clobber in-flight IME composition or echo the user's own edit.
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
            context.coordinator.noteTextChange()
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
            Self.textKitHeight(of: "字", width: contentWidth(width), font: bodyFont)
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
        if uiView.isScrollEnabled != scrolls {
            uiView.isScrollEnabled = scrolls
        }
        return CGSize(width: width, height: min(max(natural, floor), cap))
    }

    // MARK: - Measurement

    private var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    private func contentWidth(_ width: CGFloat) -> CGFloat {
        max(width - textInsets.left - textInsets.right, 1)
    }

    /// Natural content height via the view's own TextKit stack: glyph
    /// layout is incremental across keystrokes, and because line breaking
    /// depends on container width (which we hold fixed per measurement),
    /// the temporary height change never triggers a full re-layout.
    private func measuredNaturalHeight(of uiView: UITextView, width: CGFloat) -> CGFloat {
        let container = uiView.textContainer
        let layoutManager = uiView.layoutManager
        let textWidth = contentWidth(width)
        let oldSize = container.size
        if oldSize.width != textWidth || oldSize.height != .greatestFiniteMagnitude {
            container.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        var used = layoutManager.usedRect(for: container).height
        if uiView.textStorage.string.isEmpty {
            // An empty field still rests on one line.
            used = Self.textKitHeight(of: "字", width: textWidth, font: bodyFont)
        }
        if container.size != oldSize {
            container.size = oldSize
        }
        return used + textInsets.top + textInsets.bottom
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

        init(field: ComposerReturnField) {
            self.field = field
        }

        func noteTextChange() {
            contentGeneration += 1
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
#endif
