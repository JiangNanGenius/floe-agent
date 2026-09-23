// FloeApp — Full composer editor sheet.
//
// SPDX-License-Identifier: MPL-2.0
//
// The "expand" destination of the shared composer: the complete prompt in a
// large, internally scrolling editor. It binds the *same* draft as the
// inline field, so both surfaces always agree; Done only dismisses — it
// never sends. Editing support: undo/redo, the system find navigator,
// select-all, a debounced character count and a rough token estimate. The
// caret position is captured on dismiss (Done or swipe) and restored on
// reopen by the caller (via the draft store), so long-prompt editing resumes
// where it stopped.
//
// Each presented sheet owns its editor through an instance-owned
// `FullEditorController`; there is no process-global action slot, so two
// windows/sheets can never route a toolbar tap into each other's editor.
//
// Keyboard contract: plain Return inserts a newline (including while an
// input method has marked text, which is never intercepted). Hardware
// Cmd+Return performs the Done action only when no marked text is pending;
// sending stays the composer's explicit action, exactly like the inline
// field. Undo/redo is shared with the inline field through the composer's
// undo manager when one is supplied.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Editor-instance owned action surface. One sheet = one controller, so a
/// second window/sheet cannot steal another editor's undo/find/capture.
@MainActor
final class FullEditorController: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Called with the final selection when the editor closes (Done or a
    /// swipe dismissal), so the caret survives the sheet.
    var onFinalSelection: ((NSRange?) -> Void)?

    private weak var textView: UITextView?

    func attach(_ textView: UITextView) {
        self.textView = textView
        refreshUndoState()
    }

    func detach(_ textView: UITextView) {
        guard self.textView === textView else { return }
        self.textView = nil
    }

    func undo() {
        textView?.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        textView?.undoManager?.redo()
        refreshUndoState()
    }

    func presentFindNavigator() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: true)
    }

    func selectAll() {
        textView?.selectAll(nil)
    }

    /// Reports the current selection to the owner exactly once per close.
    func captureSelection() {
        guard let textView else { return }
        onFinalSelection?(textView.selectedRange)
    }

    func refreshUndoState() {
        let canUndo = textView?.undoManager?.canUndo ?? false
        let canRedo = textView?.undoManager?.canRedo ?? false
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
    }
}

struct ComposerFullEditorSheet: View {
    @Binding var text: String
    /// Restores the caret/selection captured when the editor last closed.
    var restoredSelection: NSRange?
    /// Undo manager shared with the inline field (nil keeps UIKit's own).
    var undoManager: UndoManager? = nil
    /// Delivers the final selection for persistence (draft store).
    var onFinalSelection: ((NSRange?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = FullEditorController()
    @StateObject private var counts = ComposerFooterCounts()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FullEditorTextView(
                    text: $text,
                    restoredSelection: restoredSelection,
                    undoManager: undoManager,
                    controller: controller,
                    onFinalSelection: { range in
                        onFinalSelection?(range)
                    },
                    onDone: { dismiss() }
                )
                Divider()
                footer
            }
            .navigationTitle("composer.editor.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        controller.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!controller.canUndo)
                    .accessibilityLabel("composer.editor.undo")
                    Button {
                        controller.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!controller.canRedo)
                    .accessibilityLabel("composer.editor.redo")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.presentFindNavigator()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("composer.editor.find")
                    Button {
                        controller.selectAll()
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
        // The footer counts are already revision-debounced; the first value
        // is computed when the editor opens, not inside the view body.
        .onAppear { counts.setImmediately(text: text) }
        .onChange(of: text) { _, newValue in
            counts.schedule(text: newValue)
        }
        // Resigning first responder normally reports the selection, but a
        // swipe-down dismissal can tear the sheet down without it — capture
        // explicitly so the caret really is restored on reopen.
        .onDisappear { controller.captureSelection() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(counts.characters) \(String(localized: "composer.editor.characters"))")
                .font(FloeTheme.Typography.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("composer.editor.characters")
            Spacer()
            Text(
                String(
                    format: String(localized: "composer.editor.token_estimate"),
                    counts.estimatedTokens
                )
            )
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("composer.editor.tokens")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// UITextView for the full editor: same Cmd+Return discipline as the inline
/// field (never during marked text) plus the shared undo manager.
final class FullEditorUITextView: UITextView {
    /// Handles Cmd+Return; returns true when the press was consumed.
    var commandReturnHandler: (() -> Bool)?
    /// Composer-owned undo manager shared with the inline field.
    var sharedUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        sharedUndoManager ?? super.undoManager
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var consumed = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.keyCode == .keyboardReturnOrEnter else { continue }
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

/// Scrollable UITextView backing the full editor.
private struct FullEditorTextView: UIViewRepresentable {
    @Binding var text: String
    var restoredSelection: NSRange?
    var undoManager: UndoManager?
    var controller: FullEditorController
    var onFinalSelection: (NSRange?) -> Void
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> FullEditorUITextView {
        let view = FullEditorUITextView()
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
        view.sharedUndoManager = undoManager
        // Text first, selection second: a non-zero caret restored onto an
        // empty view would be clamped to 0 and then silently lost.
        ComposerSelection.prepare(view, text: text, selection: restoredSelection)
        context.coordinator.noteAppliedSelection(restoredSelection)
        context.coordinator.attachActions(to: view, controller: controller)
        return view
    }

    func updateUIView(_ uiView: FullEditorUITextView, context: Context) {
        context.coordinator.parent = self
        uiView.sharedUndoManager = undoManager
        // Never clobber in-flight IME composition or echo the user's edit.
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        if !uiView.isFirstResponder {
            context.coordinator.applyRestoredSelectionIfNeeded(in: uiView)
        }
        controller.refreshUndoState()
    }

    static func dismantleUIView(_ uiView: FullEditorUITextView, coordinator: Coordinator) {
        // Covers a swipe dismissal that never runs the sheet's onDisappear.
        coordinator.captureSelection(from: uiView)
        coordinator.detach(from: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FullEditorTextView
        private weak var controller: FullEditorController?
        private var lastAppliedSelection: NSRange?
        private var lastReportedSelection: NSRange?

        init(_ parent: FullEditorTextView) {
            self.parent = parent
        }

        func attachActions(to view: FullEditorUITextView, controller: FullEditorController) {
            self.controller = controller
            controller.onFinalSelection = { [weak self] range in
                self?.parent.onFinalSelection(range)
            }
            controller.attach(view)
            view.commandReturnHandler = { [weak view, weak self] in
                // IME protection: a half-confirmed candidate can never close
                // the editor; plain Return keeps its newline behavior.
                guard view?.markedTextRange == nil else { return false }
                self?.parent.onDone()
                return true
            }
        }

        func detach(from view: UITextView) {
            controller?.onFinalSelection = nil
            controller?.detach(view)
            controller = nil
        }

        func noteAppliedSelection(_ selection: NSRange?) {
            lastAppliedSelection = selection
            lastReportedSelection = selection
        }

        func applyRestoredSelectionIfNeeded(in textView: UITextView) {
            guard let target = ComposerSelection.clamped(
                parent.restoredSelection,
                utf16Length: (textView.text as NSString).length
            ) else { return }
            guard textView.selectedRange != target, lastAppliedSelection != target else { return }
            lastAppliedSelection = target
            textView.selectedRange = target
        }

        func captureSelection(from textView: UITextView) {
            let range = textView.selectedRange
            lastReportedSelection = range
            parent.onFinalSelection(range)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            controller?.refreshUndoState()
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
