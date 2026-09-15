// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import PencilKit

@main struct PaletteQualificationApp: App {
    var body: some Scene { WindowGroup { PaletteFixture() } }
}

private struct PaletteFixture: View {
    @AppStorage(NotesPencilArcPlacement.preferenceKey) private var placement: NotesPencilArcPlacement = .above
    @State private var inkPreferences = NotesInkPreferences.shared
    @State private var showingBrushes = false
    @State private var presented = false
    @State private var point = CGPoint(x: 0.5, y: 0.08)
    @State private var tool: NotesInkTool = .pen

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(["top", "center", "bottom"], id: \.self) { location in
                    Button(location) {
                        point = CGPoint(x: 0.5, y: location == "top" ? 0.08 : location == "bottom" ? 0.95 : 0.5)
                        presented.toggle()
                    }.accessibilityIdentifier("palette.open.\(location)")
                }
            }.padding(4).buttonStyle(NotesToolbarButtonStyle())
            HStack {
                ForEach(NotesPencilArcPlacement.allCases, id: \.self) { value in
                    Button(value.title) { presented = false; placement = value }
                        .accessibilityIdentifier("palette.placement.\(value.rawValue)")
                        .accessibilityAddTraits(placement == value ? .isSelected : [])
                }
            }.buttonStyle(NotesToolbarButtonStyle())
            // The fixture keeps the production setting and actual drawing viewport.
            HStack {
                Text(tool.rawValue).accessibilityIdentifier("palette.selectedTool")
                Text(inkPreferences.selectedPen.rawValue)
                    .accessibilityIdentifier("palette.selectedPen")
                Button("画笔") { showingBrushes.toggle() }
                    .accessibilityIdentifier("palette.brushes")
                    .popover(isPresented: $showingBrushes) {
                        NotesInkOptionsPanel(selected: tool == .marker ? .marker : inkPreferences.selectedPen,
                            preferences: inkPreferences, select: { kind in
                                if kind == .marker { tool = .marker }
                                else { inkPreferences.select(kind); tool = .pen }
                            }, close: { showingBrushes = false }, doneIdentifier: "palette.brushes.done")
                            .presentationCompactAdaptation(.popover)
                    }
            }.frame(height: 52)
            DrawingViewport(tool: tool == .marker ? inkPreferences.inkingTool(for: .marker) : inkPreferences.inkingTool(for: inkPreferences.selectedPen))
                .notesPencilPalette(isPresented: $presented, point: point) {
                    NotesPencilToolWheel(tool: tool, select: { tool = $0; presented = false },
                                         close: { presented = false })
                }
        }
    }
}

private struct DrawingViewport: UIViewRepresentable {
    let tool: PKInkingTool
    func makeUIView(context: Context) -> PKCanvasView {
        let view = NativeToolCanvas()
        view.backgroundColor = .secondarySystemBackground
        view.drawingPolicy = .pencilOnly
        view.maximumSupportedContentVersion = .latest
        view.accessibilityIdentifier = "palette.canvas"
        view.isAccessibilityElement = true
        return view
    }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = tool
    }
}

// Expose the actual native tool for qualification rather than assuming the
// element category or synthesized value of PencilKit's OS-specific AX tree.
private final class NativeToolCanvas: PKCanvasView {
    override var accessibilityValue: String? {
        get { (tool as? PKInkingTool)?.inkType.rawValue }
        set { }
    }
}
