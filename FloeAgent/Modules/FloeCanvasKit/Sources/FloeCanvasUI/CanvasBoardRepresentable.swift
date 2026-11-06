#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore

/// SwiftUI bridge for the UIKit board. Updates flow one way (store → view);
/// gestures call back into the store as commands.
public struct CanvasBoardRepresentable: UIViewRepresentable {
    @ObservedObject public var store: CanvasEditorStore

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    public func makeUIView(context: Context) -> CanvasBoardView {
        let view = CanvasBoardView()
        view.bind(to: store)
        return view
    }

    public func updateUIView(_ uiView: CanvasBoardView, context: Context) {
        if uiView.store !== store {
            uiView.bind(to: store)
        }
    }
}
#endif
