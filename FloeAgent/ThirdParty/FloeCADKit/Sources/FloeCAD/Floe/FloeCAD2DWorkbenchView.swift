// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A drafting entrance into the existing document, transaction, geometry and
/// undo services. It never creates a parallel sketch editor or file format.
public struct FloeCAD2DWorkbenchView: View {
    let document: FloeCADDocument
    @State private var activated = false
    @Environment(\.cadCanvasKeyboardAvoidanceEnabled) private var keyboardAvoidanceEnabled
    public init(document: FloeCADDocument) { self.document = document }
    public var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                CAD2DDraftingBar(document: document)
                FloeCADEditorView(document: document, draftingOnly: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
            .ignoresSafeArea(.keyboard, edges: keyboardAvoidanceEnabled ? [] : .bottom)
            .cadCanvasLayoutObservation("drafting")
            .task {
                guard !activated else { return }
                activated = true
                document.activate2DWorkspace()
            }
    }
}

extension View {
    @ViewBuilder func cadCanvasLayoutObservation(_ stage: String) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--floe-editor-input-ownership-observation") {
            onGeometryChange(for: String.self) { geometry in
                "size=\(geometry.size) frame=\(geometry.frame(in: .global)) insets=\(geometry.safeAreaInsets)"
            } action: { value in
                print("CADCanvasGeometry \(stage) \(value)")
            }
        } else { self }
        #else
        self
        #endif
    }
}
public extension FloeCADDocument {
    @MainActor func activate2DWorkspace() {
        guard !isClosed else { return }
        let model = viewModel()
        model.planarNavigationOnly = true
        if session.document.sketches.isEmpty, !isReadOnly {
            let sketch = Sketch(name: FloeCADStrings.text("cad.sketch", "Sketch"), plane: .worldXY)
            session.perform(AddSketchCommand(sketch: sketch, title: FloeCADStrings.text("cad.sketch", "Sketch")))
        }
        if let sketch = model.activeSketch ?? session.document.sketches.first {
            model.openItemSketch(sketch.id)
            model.requestDraftingCamera(for: sketch.plane)
        }
    }
}
