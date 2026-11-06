import SwiftUI
import FloeChemistryCore

@MainActor struct ChemistryDrawing: View {
    let state: ChemistryEditorState
    let object: ChemicalObject
    @State private var session: NativeDrawingSession
    init(state: ChemistryEditorState, object: ChemicalObject) {
        self.state = state; self.object = object
        _session = State(initialValue: state.drawingSession(for: object))
    }
    var body: some View {
        NativeDrawingWorkbench(session: session)
            .task { await session.load(object) }
            .onChange(of: object.revision) { _, _ in session.externalUpdate(object) }
            .onDisappear { Task { await session.flush() } }
    }
}
