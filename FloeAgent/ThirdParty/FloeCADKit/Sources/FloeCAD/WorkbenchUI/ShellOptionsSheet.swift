import SwiftUI

/// The same transient shell edit owns selections and values. Applying goes
/// through its existing feature/command path; this sheet never saves geometry.
struct ShellOptionsSheet: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(FloeCADStrings.text("cad.shell.selectWallRegions", "Select wall regions"),
                        isOn: $viewModel.shellPickingRegions)
                    if viewModel.shellPickingRegions {
                        HStack {
                            Text(FloeCADStrings.text("cad.shell.newRegionThickness", "Thickness for selected walls"))
                            ExpressionValueField(placeholder: "mm", value: $viewModel.shellRegionThickness,
                                clamp: nil, identifier: "ShellRegionThickness")
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(FloeCADStrings.text("cad.shell.pickHelp", "Close this panel, then tap wall faces. Other faces keep the common thickness."))
                }
                Section(FloeCADStrings.text("cad.shell.wallRegions", "Wall regions")) {
                    ForEach(Array(viewModel.shellWallRegions.enumerated()), id: \.element.id) { index, region in
                        HStack {
                            Text(FloeCADStrings.format("cad.shell.wallNumber", "Wall %@", String(index + 1)))
                            ExpressionValueField(placeholder: "mm", value: Binding(
                                get: { viewModel.shellWallRegions.first { $0.id == region.id }?.thickness ?? region.thickness },
                                set: { viewModel.setShellWallThickness(region.id, value: $0) }),
                                clamp: nil, identifier: "ShellWall-\(region.id.uuidString)")
                            Text("mm").foregroundStyle(.secondary)
                            Button(role: .destructive) { viewModel.removeShellWallRegion(region.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel(FloeCADStrings.text("cad.shell.removeWall", "Remove wall thickness"))
                        }
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.shell.wallOptions", "Wall thicknesses"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.common.done", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
