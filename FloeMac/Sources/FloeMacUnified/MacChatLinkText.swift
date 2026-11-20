// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

/// A selectable Markdown run routes clicks through the owning SwiftUI window.
/// AppKit's default link action would open the user's external browser.
struct MacChatLinkText: NSViewRepresentable {
    let content: AttributedString
    let baseFont: NSFont
    @Environment(\.openURL) private var openURL

    init(_ content: AttributedString, font: NSFont = .preferredFont(forTextStyle: .callout)) {
        self.content = content
        self.baseFont = font
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: OpenURLAction
        var displayed: AttributedString?
        var font: NSFont?
        init(open: OpenURLAction) { self.open = open }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url) }
            else if let address = link as? String, let url = URL(string: address) { open(url) }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: openURL) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = openURL
        guard context.coordinator.displayed != content || context.coordinator.font != baseFont else { return }
        context.coordinator.displayed = content
        context.coordinator.font = baseFont
        let output = NSMutableAttributedString()
        for run in content.runs {
            let intent = run.inlinePresentationIntent
            var font = intent?.contains(.code) == true ? NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) : baseFont
            if intent?.contains(.stronglyEmphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent?.contains(.emphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let url = run.link { attributes[.link] = url }
            if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: String(content[run.range].characters), attributes: attributes))
        }
        view.textStorage?.setAttributedString(output)
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = max(1, proposal.width ?? view.attributedString().size().width.rounded(.up))
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}
