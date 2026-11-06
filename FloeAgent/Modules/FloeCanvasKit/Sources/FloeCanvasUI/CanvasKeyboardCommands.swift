#if canImport(UIKit)
import SwiftUI

/// Keyboard routing for the board. Attached to the board container and
/// active only while no text editor is focused — standard text-editor
/// commands and IME composition are never stolen (UI_BRIEF, ICH02).
public struct CanvasKeyCommands: ViewModifier {
    @ObservedObject var store: CanvasEditorStore
    @FocusState private var boardFocused: Bool

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    public func body(content: Content) -> some View {
        content
            .focused($boardFocused)
            .onKeyPress(.return, phases: .down) { _ in
                if let node = store.singleSelectedNode {
                    store.focusNode(node.id)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.delete, phases: .down) { _ in
                guard boardFocused else { return .ignored }
                guard store.focusedNodeID == nil else { return .ignored }
                Task { await store.apply(.deleteSelection) }
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                guard store.focusedNodeID == nil else { return .ignored }
                if store.showsInspector {
                    store.showsInspector = false
                    return .handled
                }
                store.clearSelection()
                return .handled
            }
            .onKeyPress("a", phases: .down) { press in
                guard boardFocused, store.focusedNodeID == nil,
                      press.modifiers.contains(.command) else { return .ignored }
                store.selectAll()
                return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { _ in
                guard boardFocused else { return .ignored }
                store.zoomIn()
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { _ in
                guard boardFocused else { return .ignored }
                store.zoomOut()
                return .handled
            }
            .onKeyPress("f", phases: .down) { press in
                guard boardFocused, press.modifiers.isEmpty else { return .ignored }
                store.fitToContent()
                return .handled
            }
    }
}

public extension View {
    func canvasKeyCommands(store: CanvasEditorStore) -> some View {
        modifier(CanvasKeyCommands(store: store))
    }
}
#endif
