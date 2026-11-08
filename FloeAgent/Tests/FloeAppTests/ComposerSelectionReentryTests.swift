// FloeAppTests — SwiftUI-owned restoration must not echo into host state.
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import FloeApp

@Suite("FloeApp.ComposerSelectionReentry", .serialized)
@MainActor
struct ComposerSelectionReentryTests {
    @Test("Real hosted field restores silently, then native selection and typing still hand off to the full editor")
    func hostRestoresDoNotEchoAndLiveSelectionStillReachesFullEditor() async throws {
        let model = SelectionHostModel()
        let host = UIHostingController(rootView: SelectionHost(model: model))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 460))
        }
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 460)
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        try await waitFor(host.view) {
            Self.descendant(HardwareReturnTextView.self, in: host.view)?.text == model.text
        }
        let field = try #require(Self.descendant(HardwareReturnTextView.self, in: host.view))
        #expect(field.selectedRange == NSRange(location: 3, length: 2))
        #expect(model.selections.isEmpty, "makeUIView text/selection preparation must not write back into SwiftUI")

        // Drive real updateUIView through an observed host, not the
        // coordinator's private suppression state or a manual delegate call.
        let restored = NSRange(location: 9, length: 4)
        model.restoredSelection = restored
        try await waitFor(host.view) { field.selectedRange == restored }
        #expect(model.selections.isEmpty, "a host-requested caret restoration is not a user selection")

        let replacement = "replacement draft from the full editor"
        let replacedSelection = NSRange(location: 5, length: 3)
        model.text = replacement
        model.restoredSelection = replacedSelection
        try await waitFor(host.view) { field.text == replacement && field.selectedRange == replacedSelection }
        #expect(Self.descendant(HardwareReturnTextView.self, in: host.view) === field)
        #expect(model.selections.isEmpty, "programmatic text replacement must not echo its intermediate selection")

        #expect(field.becomeFirstResponder())
        // UITextInput is the native selection path used by touch, pointer
        // and hardware-key navigation. No delegate method is called here.
        let start = try #require(field.position(from: field.beginningOfDocument, offset: 8))
        let end = try #require(field.position(from: start, offset: 2))
        let selected = try #require(field.textRange(from: start, to: end))
        field.selectedTextRange = selected
        let userSelection = NSRange(location: 8, length: 2)
        try await waitFor(host.view) { model.latestSelection == userSelection }
        #expect(model.restoredSelection == userSelection, "the live range must remain available to the draft/full-editor host")

        field.insertText("Z")
        let typedText = (replacement as NSString).replacingCharacters(in: userSelection, with: "Z")
        let typedCaret = NSRange(location: 9, length: 0)
        try await waitFor(host.view) { model.text == typedText && model.latestSelection == typedCaret }
        #expect(Self.descendant(HardwareReturnTextView.self, in: host.view) === field)
        #expect(model.restoredSelection == typedCaret)

        field.resignFirstResponder()
        // Mount the actual expanded editor with the range delivered by the
        // live inline delegate. This exercises the production handoff, not
        // a separate range-clamping implementation in this test.
        let expanded = UIHostingController(rootView: ComposerFullEditorSheet(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            restoredSelection: model.restoredSelection,
            undoManager: model.undoManager,
            onFinalSelection: nil
        ))
        window.rootViewController = expanded
        try await waitFor(expanded.view) {
            let editor = Self.descendant(FullEditorUITextView.self, in: expanded.view)
            return editor?.text == typedText && editor?.selectedRange == typedCaret
        }
        let editor = try #require(Self.descendant(FullEditorUITextView.self, in: expanded.view))
        #expect(editor.selectedRange == typedCaret)
        #expect(editor.undoManager === model.undoManager)
    }

    private func waitFor(_ view: UIView, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if predicate() {
                // Allow the queued UIKit/SwiftUI turn to finish before the
                // caller checks that no programmatic callback escaped.
                try await Task.sleep(for: .milliseconds(20))
                if predicate() { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "the real hosted UIKit field did not reach the requested state")
    }

    private static func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }
}

@MainActor
private final class SelectionHostModel: ObservableObject {
    @Published var text = "original draft for caret restoration"
    @Published var restoredSelection: NSRange? = NSRange(location: 3, length: 2)
    var selections: [NSRange?] = []
    var latestSelection: NSRange? { selections.last ?? nil }
    let undoManager = UndoManager()
}

private struct SelectionHost: View {
    @ObservedObject var model: SelectionHostModel

    var body: some View {
        ComposerReturnField(
            text: $model.text,
            placeholder: "composer.test.placeholder",
            restoredSelection: model.restoredSelection,
            undoManager: model.undoManager,
            onSelectionChange: { range in
                model.selections.append(range)
                model.restoredSelection = range
            },
            onReturn: {}
        )
        .frame(width: 560)
        .padding()
    }
}
#endif
