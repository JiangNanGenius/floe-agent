// FloeApp — Full composer editor sheet.
//
// SPDX-License-Identifier: MPL-2.0
//
// The "expand" destination of the shared composer: the complete prompt in a
// large, internally scrolling editor. It binds the *same* draft as the
// inline field, so both surfaces always agree; Done only dismisses — it
// never sends. Editing support: undo/redo, the system find navigator,
// select-all, a live character count and a rough token estimate. The caret
// position is captured on dismiss and restored on reopen by the caller
// (via the draft store), so long-prompt editing resumes where it stopped.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

struct ComposerFullEditorSheet: View {
    @Binding var text: String
    /// Restores the caret/selection captured when the editor last closed.
    var restoredSelection: NSRange?
    /// Delivers the final selection for persistence (draft store).
    var onFinalSelection: ((NSRange?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FullEditorTextView(
                    text: $text,
                    restoredSelection: restoredSelection,
                    canUndo: $canUndo,
                    canRedo: $canRedo,
                    onFinalSelection: { range in
                        onFinalSelection?(range)
                    }
                )
                Divider()
                HStack(spacing: 12) {
                    Text("\(text.count) \(String(localized: "composer.editor.characters"))")
                        .font(FloeTheme.Typography.metadata.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("composer.editor.characters")
                    Spacer()
                    let estimate = ComposerTokenEstimator.estimatedTokens(in: text)
                    Text(
                        String(
                            format: String(localized: "composer.editor.token_estimate"),
                            estimate
                        )
                    )
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("composer.editor.tokens")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("composer.editor.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        FullEditorTextViewHost.sharedUndoAction?(.undo)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!canUndo)
                    .accessibilityLabel("composer.editor.undo")
                    Button {
                        FullEditorTextViewHost.sharedUndoAction?(.redo)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!canRedo)
                    .accessibilityLabel("composer.editor.redo")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        FullEditorTextViewHost.sharedFindAction?()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("composer.editor.find")
                    Button {
                        FullEditorTextViewHost.sharedSelectAllAction?()
                    } label: {
                        Image(systemName: "selection.pin.in.out")
                    }
                    .accessibilityLabel("composer.editor.select_all")
                    // Done closes the editor only; sending stays the
                    // composer's explicit send action.
                    Button("action.done") { dismiss() }
                        .accessibilityIdentifier("composer.editor.done")
                }
            }
        }
        .presentationDetents([.large])
        // Resigning first responder normally reports the selection, but a
        // swipe-down dismissal can tear the sheet down without it — capture
        // explicitly so the caret really is restored on reopen.
        .onDisappear { FullEditorTextViewHost.sharedCaptureSelection?() }
    }
}

/// Routes toolbar actions into the hosted UITextView. The sheet owns exactly
/// one editor, so a single hosting slot is enough and stays testable.
enum FullEditorTextViewHost {
    enum EditAction { case undo, redo }
    static var sharedUndoAction: ((EditAction) -> Void)?
    static var sharedFindAction: (() -> Void)?
    static var sharedSelectAllAction: (() -> Void)?
    static var sharedCaptureSelection: (() -> Void)?
}

/// Scrollable UITextView backing the full editor.
private struct FullEditorTextView: UIViewRepresentable {
    @Binding var text: String
    var restoredSelection: NSRange?
    @Binding var canUndo: Bool
    @Binding var canRedo: Bool
    var onFinalSelection: (NSRange?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.isFindInteractionEnabled = true
        view.accessibilityIdentifier = "composer.editor.input"
        context.coordinator.attachActions(to: view)
        if let restoredSelection,
           restoredSelection.location <= (view.text as NSString).length {
            view.selectedRange = restoredSelection
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        // Never clobber in-flight IME composition or echo the user's edit.
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        context.coordinator.refreshUndoState(in: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FullEditorTextView

        init(_ parent: FullEditorTextView) {
            self.parent = parent
        }

        func attachActions(to view: UITextView) {
            FullEditorTextViewHost.sharedUndoAction = { [weak view, weak self] action in
                guard let view, let manager = view.undoManager else { return }
                switch action {
                case .undo: manager.undo()
                case .redo: manager.redo()
                }
                self?.refreshUndoState(in: view)
            }
            FullEditorTextViewHost.sharedFindAction = { [weak view] in
                guard let view, let interaction = view.findInteraction else { return }
                interaction.presentFindNavigator(showingReplace: true)
            }
            FullEditorTextViewHost.sharedSelectAllAction = { [weak view] in
                view?.selectAll(nil)
            }
            FullEditorTextViewHost.sharedCaptureSelection = { [weak view, weak self] in
                guard let view, let self else { return }
                self.parent.onFinalSelection(view.selectedRange)
            }
        }

        func refreshUndoState(in view: UITextView) {
            let canUndo = view.undoManager?.canUndo ?? false
            let canRedo = view.undoManager?.canRedo ?? false
            if canUndo != parent.canUndo { parent.canUndo = canUndo }
            if canRedo != parent.canRedo { parent.canRedo = canRedo }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            refreshUndoState(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Keep the caret visible while navigating a long prompt.
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFinalSelection(textView.selectedRange)
        }
    }
}
#endif
