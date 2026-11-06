// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A drafting entrance into the existing document, transaction, geometry and
/// undo services. It never creates a parallel sketch editor or file format.
public struct FloeCAD2DWorkbenchView: View {
    let document: FloeCADDocument
    @State private var activated = false
    public init(document: FloeCADDocument) { self.document = document }
    public var body: some View {
        FloeCADEditorView(document: document, draftingOnly: true)
            .safeAreaInset(edge: .top, spacing: 0) { CAD2DDraftingBar(document: document) }
            .task {
                guard !activated else { return }
                activated = true
                document.activate2DWorkspace()
            }
    }
}
public extension FloeCADDocument {
    @MainActor func activate2DWorkspace() {
        guard !isClosed else { return }
        let model = viewModel()
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
