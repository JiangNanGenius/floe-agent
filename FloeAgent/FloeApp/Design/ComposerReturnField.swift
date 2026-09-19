// FloeApp — Shared composer text field with hardware Return handling.
//
// SPDX-License-Identifier: MPL-2.0
//
// Multiline input used by the chat thread composer and the canvas assistant.
// On a hardware keyboard (Magic Keyboard and other external keyboards):
// plain Return sends, Shift+Return inserts a newline, and Return never sends
// while an input method is still composing marked text. The software keyboard
// keeps its classic multiline behavior (return key inserts a newline); only
// callers that previously used `.submitLabel(.send)` opt into software-send
// via `softwareReturnSends`.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// UITextView that marks hardware Return/Enter presses so the delegate can
/// distinguish them from the software keyboard's return key, which never
/// produces a `UIPress`. Modifier-bearing presses (Shift+Return, …) are not
/// marked, so they keep their default newline insertion.
final class HardwareReturnTextView: UITextView {
    /// Placeholder shown while the field is empty; a subview so it tracks
    /// the text container's origin and insets.
    let placeholderLabel = UILabel()

    /// True exactly while a hardware Return/Enter press is being translated
    /// into text input. Reading it via `consumeHardwareReturn()` clears it.
    private(set) var hardwareReturnIsDelivering = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        noteHardwareReturnPress(presses, set: true)
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // The legitimate flow already consumed the flag inside the
        // synchronous text-input delivery in pressesBegan. Anything left
        // here means the press did not produce text input; drop it so a
        // later software return key is never mistaken for hardware Return.
        noteHardwareReturnPress(presses, set: false)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        noteHardwareReturnPress(presses, set: false)
        super.pressesCancelled(presses, with: event)
    }

    /// Reads and clears the hardware-Return flag.
    func consumeHardwareReturn() -> Bool {
        let delivering = hardwareReturnIsDelivering
        hardwareReturnIsDelivering = false
        return delivering
    }

    private func noteHardwareReturnPress(_ presses: Set<UIPress>, set: Bool) {
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardReturnOrEnter:
                // Only an unmodified Return may send; Shift+Return and other
                // modified combinations must keep inserting a newline.
                let modified = !key.modifierFlags
                    .intersection([.shift, .control, .alternate, .command])
                    .isEmpty
                hardwareReturnIsDelivering = set && !modified
            default:
                break
            }
        }
    }
}

/// Multiline composer field shared by the chat and canvas assistants.
///
/// Hardware keyboard: unmodified Return invokes `onReturn` (only when
/// `canSend`); Shift+Return inserts a newline; Return while an input method
/// composes marked text commits the composition instead of sending. Software
/// keyboard: the return key keeps inserting newlines unless
/// `softwareReturnSends` is true (the surfaces that previously used
/// `.submitLabel(.send)`).
struct ComposerReturnField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Mirrors the send button's enabled state; when false, hardware Return
    /// falls back to inserting a newline instead of sending.
    var canSend: Bool = true
    /// True where the replaced surface used `.submitLabel(.send)`: the
    /// software keyboard's return key then sends as well.
    var softwareReturnSends: Bool = false
    /// Visible line budget; beyond the upper bound the field scrolls, like
    /// `lineLimit(_:)` on a multiline `TextField`.
    var lineLimit: ClosedRange<Int> = 1...5
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
        let natural = measuredHeight(of: text, width: width)
        let cap = maxHeight(width: width)
        let scrolls = natural > cap
        if uiView.isScrollEnabled != scrolls {
            uiView.isScrollEnabled = scrolls
        }
        let floor = minHeight(width: width)
        return CGSize(width: width, height: min(max(natural, floor), cap))
    }

    // MARK: - Measurement

    private var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    /// TextKit-based height so it stays correct before the view has a laid
    /// out width; `sizeThatFits` on a UITextView is unreliable pre-layout.
    private func measuredHeight(of string: String, width: CGFloat) -> CGFloat {
        let content = string.isEmpty ? " " : string
        let storage = NSTextStorage(string: content, attributes: [.font: bodyFont])
        let container = NSTextContainer(size: CGSize(
            width: max(width - textInsets.left - textInsets.right, 1),
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(for: container)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.height + textInsets.top + textInsets.bottom
    }

    /// Height of exactly `lineLimit.upperBound` lines; beyond this the field
    /// stops growing and scrolls instead.
    private func maxHeight(width: CGFloat) -> CGFloat {
        measuredHeight(
            of: Self.lineFiller(count: max(1, lineLimit.upperBound)),
            width: width
        )
    }

    /// Resting height of `lineLimit.lowerBound` lines, never below 44pt.
    private func minHeight(width: CGFloat) -> CGFloat {
        max(
            restingMinHeight,
            measuredHeight(
                of: Self.lineFiller(count: max(1, lineLimit.lowerBound)),
                width: width
            )
        )
    }

    private static func lineFiller(count: Int) -> String {
        Array(repeating: "字", count: count).joined(separator: "\n")
    }

    // MARK: - Delegate

    final class Coordinator: NSObject, UITextViewDelegate {
        var field: ComposerReturnField

        init(field: ComposerReturnField) {
            self.field = field
        }

        func textViewDidChange(_ textView: UITextView) {
            field.text = textView.text
            placeholderLabel(of: textView)?.isHidden = !textView.text.isEmpty
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // Always consume the hardware-Return flag: a Return that an input
            // method swallowed (composition commit) or a disabled send must
            // not turn the next software return key into a send.
            let hardwareReturn = (textView as? HardwareReturnTextView)?
                .consumeHardwareReturn() ?? false
            guard text == "\n", textView.markedTextRange == nil else { return true }
            // Sending is available: hardware Return sends, and the software
            // return key sends only on the surfaces that opted in. Everything
            // else (Shift+Return, IME commit, disabled send, software return
            // on default surfaces) keeps inserting a newline.
            guard field.canSend, hardwareReturn || field.softwareReturnSends else {
                return true
            }
            field.onReturn()
            return false
        }

        private func placeholderLabel(of textView: UITextView) -> UILabel? {
            (textView as? HardwareReturnTextView)?.placeholderLabel
        }
    }
}
#endif
