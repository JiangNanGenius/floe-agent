import SwiftUI

struct SnappingSettingsSection: View {
    @Bindable var settings: CADPreferences

    var body: some View {
        Section {
            Toggle("Grid", isOn: $settings.snapToGrid)
                .accessibilityIdentifier("SnapToGridToggle")
            Toggle("Sketch Guide Lines", isOn: $settings.snapToSketchGuidelines)
                .accessibilityIdentifier("SnapToSketchGuidelinesToggle")
            Toggle("Sketch Guidepoints", isOn: $settings.snapToSketchGuidepoints)
                .accessibilityIdentifier("SnapToSketchGuidepointsToggle")
            Toggle("Face Guidepoints", isOn: $settings.snapToFaceGuidepoints)
                .accessibilityIdentifier("SnapToFaceGuidepointsToggle")
            HStack {
                Text("Snapping Hints")
                Spacer()
                Toggle("", isOn: $settings.showSnapHints)
                    .labelsHidden()
                    .accessibilityLabel("Snapping Hints")
                    .accessibilityIdentifier("ShowSnapHintsToggle")
            }
        } header: {
            Text("Snapping")
        } footer: {
            Text("Snap to grid steps, sketch points, or the corners and edges of the face you are sketching on. Hints label the snap without changing it. Auto-Constrain separately controls inferred geometric relationships.")
        }
    }
}
