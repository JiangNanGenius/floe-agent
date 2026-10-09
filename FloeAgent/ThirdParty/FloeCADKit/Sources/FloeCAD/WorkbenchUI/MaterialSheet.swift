//
//  MaterialSheet.swift
//  openshape3d
//
//  Body material dialog (plan §B15): preset grid + custom color picker +
//  metallic/roughness sliders. Apply commits one SetMaterialCommand over the
//  whole selection (EditorViewModel.applyMaterial).
//

import SwiftUI

struct MaterialSheet: View {
    @State private var color: Color
    @State private var metallic: Double
    @State private var roughness: Double

    @Environment(\.dismiss) private var dismiss
    let onApply: (BodyMaterialSpec) -> Void

    init(initial: BodyMaterialSpec, onApply: @escaping (BodyMaterialSpec) -> Void) {
        let spec = initial.clamped
        _color = State(initialValue: Color(
            red: spec.baseColor.x, green: spec.baseColor.y, blue: spec.baseColor.z
        ))
        _metallic = State(initialValue: spec.metallic)
        _roughness = State(initialValue: spec.roughness)
        self.onApply = onApply
    }

    private static let gridColumns = [GridItem(.adaptive(minimum: 74), spacing: 10)]

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.label("cad.ui.material.presets", "Presets")) {
                    LazyVGrid(columns: Self.gridColumns, spacing: 10) {
                        ForEach(MaterialPreset.library) { preset in
                            presetSwatch(preset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section(FloeCADStrings.label("cad.ui.material.custom", "Custom")) {
                    ColorPicker(FloeCADStrings.label("cad.ui.material.color", "Color"),
                                selection: $color, supportsOpacity: false)
                        .accessibilityIdentifier("MaterialColorPicker")
                    sliderRow(
                        FloeCADStrings.text("cad.ui.material.metallic", "Metallic"), value: $metallic,
                        sliderID: "MaterialMetallicSlider",
                        valueID: "MaterialMetallicValue"
                    )
                    sliderRow(
                        FloeCADStrings.text("cad.ui.material.roughness", "Roughness"), value: $roughness,
                        sliderID: "MaterialRoughnessSlider",
                        valueID: "MaterialRoughnessValue"
                    )
                }
            }
            .navigationTitle(FloeCADStrings.label("cad.ui.tool.material", "Material"))
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("MaterialCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.apply", "Apply")) {
                        onApply(currentSpec)
                        dismiss()
                    }
                    .accessibilityIdentifier("MaterialApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func presetSwatch(_ preset: MaterialPreset) -> some View {
        Button {
            let spec = preset.spec
            color = Color(
                red: spec.baseColor.x, green: spec.baseColor.y, blue: spec.baseColor.z
            )
            metallic = spec.metallic
            roughness = spec.roughness
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(
                        red: preset.spec.baseColor.x,
                        green: preset.spec.baseColor.y,
                        blue: preset.spec.baseColor.z
                    ))
                    .frame(height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "MaterialPreset\(preset.name.replacingOccurrences(of: " ", with: ""))"
        )
    }

    private func sliderRow(
        _ title: String, value: Binding<Double>, sliderID: String, valueID: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityIdentifier(sliderID)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityIdentifier(valueID)
        }
    }

    /// The sheet state as a model spec (sRGB components from the picker).
    private var currentSpec: BodyMaterialSpec {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return BodyMaterialSpec(
            baseColor: SIMD4(Double(r), Double(g), Double(b), 1),
            metallic: metallic,
            roughness: roughness
        ).clamped
    }
}
