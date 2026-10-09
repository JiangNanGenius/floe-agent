import SwiftUI

struct SnappingSettingsSection: View {
    @Bindable var settings: CADPreferences

    var body: some View {
        Section {
            Toggle(FloeCADStrings.label("cad.ui.snapping.grid", "Grid"), isOn: $settings.snapToGrid)
                .accessibilityIdentifier("SnapToGridToggle")
            Toggle(FloeCADStrings.label("cad.ui.snapping.sketchGuideLines", "Sketch Guide Lines"),
                   isOn: $settings.snapToSketchGuidelines)
                .accessibilityIdentifier("SnapToSketchGuidelinesToggle")
            Toggle(FloeCADStrings.label("cad.ui.snapping.sketchGuidepoints", "Sketch Guidepoints"),
                   isOn: $settings.snapToSketchGuidepoints)
                .accessibilityIdentifier("SnapToSketchGuidepointsToggle")
            Toggle(FloeCADStrings.label("cad.ui.snapping.faceGuidepoints", "Face Guidepoints"),
                   isOn: $settings.snapToFaceGuidepoints)
                .accessibilityIdentifier("SnapToFaceGuidepointsToggle")
            HStack {
                Text(FloeCADStrings.label("cad.ui.snapping.hints", "Snapping Hints"))
                Spacer()
                Toggle("", isOn: $settings.showSnapHints)
                    .labelsHidden()
                    .accessibilityLabel(FloeCADStrings.label("cad.ui.snapping.hints", "Snapping Hints"))
                    .accessibilityIdentifier("ShowSnapHintsToggle")
            }
        } header: {
            Text(FloeCADStrings.label("cad.settings.snap.title", "Snapping"))
        } footer: {
            Text("Snap to grid steps, sketch points, or the corners and edges of the face you are sketching on. Hints label the snap without changing it. Auto-Constrain separately controls inferred geometric relationships.")
        }
    }
}
