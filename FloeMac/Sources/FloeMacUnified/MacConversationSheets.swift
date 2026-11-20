// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Keep the bookmark open for Quick Look's asynchronous reads.
final class MacConversationAttachmentPreview: Identifiable {
    let id: UUID
    let url: URL
    private let scoped: Bool

    init(id: UUID, url: URL) {
        self.id = id
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

struct MacConversationAttachmentSheet: View {
    let preview: MacConversationAttachmentPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: preview.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("mac.attachment.reveal") { NSWorkspace.shared.activateFileViewerSelecting([preview.url]) }
                Button("mac.composer.done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("thread.attachment.preview.done")
            }
            .padding(12)
            Divider()
            MacWorkspaceQuickLook(url: preview.url)
                .accessibilityIdentifier("thread.attachment.preview")
        }
        .frame(width: min(720, (NSScreen.main?.visibleFrame.width ?? 820) - 64),
               height: min(500, (NSScreen.main?.visibleFrame.height ?? 620) - 96))
    }
}

struct MacExpandedComposer: View {
    @Binding var text: String
    @Binding var selection: NSRange
    let canSend: Bool
    let sendLabel: LocalizedStringKey
    let submit: () -> Void
    @StateObject private var input = EditorInput()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("mac.composer.editPrompt").font(.headline)
                Spacer()
                Button {
                    let action = NSMenuItem()
                    action.tag = NSTextFinder.Action.showFindInterface.rawValue
                    input.view?.performTextFinderAction(action)
                } label: { Image(systemName: "magnifyingglass") }
                .help("mac.workspace.find")
                .accessibilityLabel("mac.workspace.find")
                .accessibilityIdentifier("thread.composer.expanded.find")
                .keyboardShortcut("f", modifiers: .command)
                Button("mac.composer.done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("thread.composer.expanded.done")
                Button(sendLabel) {
                    guard canSend, let view = input.view, !view.hasMarkedText() else { return }
                    submit()
                    dismiss()
                }
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("thread.composer.expanded.send")
            }
            .padding(12)
            Divider()
            PromptEditor(text: $text, selection: $selection, input: input)
        }
        .frame(width: min(680, (NSScreen.main?.visibleFrame.width ?? 770) - 64),
               height: min(460, (NSScreen.main?.visibleFrame.height ?? 580) - 96))
    }

    @MainActor private final class EditorInput: ObservableObject {
        weak var view: NSTextView?
    }

    private struct PromptEditor: NSViewRepresentable {
        @Binding var text: String
        @Binding var selection: NSRange
        let input: EditorInput

        final class Coordinator: NSObject, NSTextViewDelegate {
            var editor: PromptEditor
            init(_ editor: PromptEditor) { self.editor = editor }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                editor.text = view.string
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let view = notification.object as? NSTextView else { return }
                editor.selection = view.selectedRange()
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            guard let view = scroll.documentView as? NSTextView else { return scroll }
            input.view = view
            view.isRichText = false
            view.allowsUndo = true
            view.usesFindBar = true
            view.font = .systemFont(ofSize: NSFont.systemFontSize)
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.setAccessibilityIdentifier("thread.composer.expanded.input")
            view.string = text
            let count = (text as NSString).length
            let start = min(selection.location, count)
            view.setSelectedRange(NSRange(location: start, length: min(selection.length, count - start)))
            view.delegate = context.coordinator
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
            }
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            context.coordinator.editor = self
            guard let view = scroll.documentView as? NSTextView, !view.hasMarkedText(), view.string != text else { return }
            view.string = text
        }
    }
}
