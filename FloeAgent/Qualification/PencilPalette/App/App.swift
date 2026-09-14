// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import PencilKit

@main struct PaletteQualificationApp: App {
    var body: some Scene { WindowGroup { PaletteFixture() } }
}

private struct PaletteFixture: View {
    @State private var presented = false
    @State private var point = CGPoint(x: 0.5, y: 0.08)
    @State private var tool: NotesInkTool = .pen
    @State private var color = "#18181B"
    @State private var width = 3.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["top", "center", "bottom"], id: \.self) { location in
                    Button(location) {
                        point = CGPoint(x: 0.5, y: location == "top" ? 0.08 : location == "bottom" ? 0.95 : 0.5)
                        tool = .pen
                        presented = true
                    }.accessibilityIdentifier("palette.open.\(location)")
                }
            }.padding(4).buttonStyle(NotesToolbarButtonStyle())
            // Reserve the same two toolbar rows as the real editor.
            Text("Palette layout qualification").frame(height: 52)
            DrawingViewport()
                .notesPencilPalette(isPresented: $presented, point: point) {
                    NotesPencilQuickPalette(tool: tool, color: $color, width: $width,
                                           canUndo: true, canRedo: true, select: { tool = $0 },
                                           undo: {}, redo: {}, close: { presented = false })
                }
        }
    }
}

private struct DrawingViewport: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.backgroundColor = .secondarySystemBackground
        view.drawingPolicy = .pencilOnly
        return view
    }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
