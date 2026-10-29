//
//  CADEnvironmentInspectorView.swift
//  FloeCADKit
//
//  Studio / Daylight / Dark presentation environments. Three settings are
//  stored together in the document's `sceneSettings` column; Apply is one
//  undoable `applyViewAppearance` command and Cancel restores the previous
//  look. While the sheet is open the presentation previews the draft locally
//  (no document writes, no undo records).
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import simd

struct CADEnvironmentInspectorView: View {
    let document: FloeCADDocument
    let onPreview: (CADViewAppearance) -> Void
    let onCancelPreview: () -> Void

    @State private var draft: CADViewAppearance
    @Environment(\.dismiss) private var dismiss

    init(document: FloeCADDocument,
         onPreview: @escaping (CADViewAppearance) -> Void,
         onCancelPreview: @escaping () -> Void) {
        self.document = document
        self.onPreview = onPreview
        self.onCancelPreview = onCancelPreview
        _draft = State(initialValue: document.viewAppearance)
    }

    private var settings: CADViewEnvironmentSettings {
        switch draft.activeEnvironment {
        case .studio: draft.studio
        case .daylight: draft.daylight
        case .dark: draft.dark
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(FloeCADStrings.text("cad.environment.kind", "Environment"),
                           selection: Binding(
                            get: { draft.activeEnvironment },
                            set: { kind in
                                draft.activeEnvironment = kind
                                preview()
                            })) {
                        Text(FloeCADStrings.text("cad.environment.studio", "Studio"))
                            .tag(CADViewEnvironmentKind.studio)
                        Text(FloeCADStrings.text("cad.environment.daylight", "Daylight"))
                            .tag(CADViewEnvironmentKind.daylight)
                        Text(FloeCADStrings.text("cad.environment.dark", "Dark"))
                            .tag(CADViewEnvironmentKind.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("CADEnvironmentKind")
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.environment.kindNote",
                        "Each environment keeps its own light, background and floor settings."))
                }

                Section {
                    HStack {
                        Text(FloeCADStrings.text("cad.environment.lightStrength",
                                                 "Light strength"))
                        Slider(value: Binding(
                            get: { settings.lightIntensity },
                            set: { value in
                                updateSettings { $0.lightIntensity = value }
                            }), in: 0...8)
                            .accessibilityIdentifier("CADEnvironmentLightStrength")
                        Text(String(format: "%.1f", settings.lightIntensity))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    environmentAngleRow(
                        title: FloeCADStrings.text("cad.environment.lightDirection",
                                                   "Light direction"))
                    ColorPicker(FloeCADStrings.text("cad.environment.background",
                                                    "Background"),
                                selection: colorBinding(\.backgroundColor),
                                supportsOpacity: false)
                        .accessibilityIdentifier("CADEnvironmentBackground")
                } header: {
                    Text(FloeCADStrings.text("cad.environment.section.light", "Light"))
                }

                Section {
                    Toggle(FloeCADStrings.text("cad.environment.floor", "Floor"),
                           isOn: Binding(
                            get: { draft.floorVisible },
                            set: { value in
                                draft.floorVisible = value
                                preview()
                            }))
                        .accessibilityIdentifier("CADEnvironmentFloor")
                    if draft.floorVisible {
                        ColorPicker(FloeCADStrings.text("cad.environment.floorColor",
                                                        "Floor colour"),
                                    selection: floorColorBinding,
                                    supportsOpacity: false)
                        HStack {
                            Text(FloeCADStrings.text("cad.environment.floorSize",
                                                     "Floor size"))
                            TextField(FloeCADStrings.text("cad.unit.mm", "mm"),
                                      value: Binding(
                                        get: { draft.floorSizeMM },
                                        set: { value in
                                            draft.floorSizeMM = min(max(value, 10), 200_000)
                                            preview()
                                        }),
                                      format: .number.precision(.fractionLength(0...0)))
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 110)
                                .accessibilityIdentifier("CADEnvironmentFloorSize")
                            Text(FloeCADStrings.text("cad.unit.mm", "mm"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(FloeCADStrings.text("cad.environment.shadows", "Shadows"),
                           isOn: Binding(
                            get: { draft.shadowsEnabled },
                            set: { value in
                                draft.shadowsEnabled = value
                                preview()
                            }))
                        .accessibilityIdentifier("CADEnvironmentShadows")
                } header: {
                    Text(FloeCADStrings.text("cad.environment.section.ground", "Floor"))
                }

                Section {
                    Button {
                        draft = .default
                        preview()
                    } label: {
                        Label(FloeCADStrings.text("cad.environment.reset",
                                                  "Reset all environments"),
                              systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("CADEnvironmentReset")
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.environment.title", "Environment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                        onCancelPreview()
                        dismiss()
                    }
                    .accessibilityIdentifier("CADEnvironmentCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply", "Apply")) {
                        document.applyViewAppearance(draft)
                        onPreview(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("CADEnvironmentApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { onCancelPreview() }
    }

    // MARK: Helpers

    private func updateSettings(_ mutate: (inout CADViewEnvironmentSettings) -> Void) {
        var value = settings
        mutate(&value)
        switch draft.activeEnvironment {
        case .studio: draft.studio = value.sanitized
        case .daylight: draft.daylight = value.sanitized
        case .dark: draft.dark = value.sanitized
        }
        preview()
    }

    private func preview() {
        onPreview(draft.sanitized)
    }

    private var floorColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: draft.floorColor.first ?? 0.5,
                      green: draft.floorColor.count > 1 ? draft.floorColor[1] : 0.5,
                      blue: draft.floorColor.count > 2 ? draft.floorColor[2] : 0.52)
            },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
                UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                draft.floorColor = [Double(red), Double(green), Double(blue)]
                preview()
            })
    }

    private func colorBinding(
        _ keyPath: WritableKeyPath<CADViewEnvironmentSettings, [Double]>
    ) -> Binding<Color> {
        Binding(
            get: {
                let values = settings[keyPath: keyPath]
                return Color(red: values.first ?? 0.1,
                             green: values.count > 1 ? values[1] : 0.1,
                             blue: values.count > 2 ? values[2] : 0.1)
            },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
                UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                updateSettings {
                    $0[keyPath: keyPath] = [Double(red), Double(green), Double(blue)]
                }
            })
    }

    private func environmentAngleRow(title: String) -> some View {
        let direction = settings.lightDirection
        let vector = SIMD3(direction.first ?? 0.35,
                           direction.count > 1 ? direction[1] : 0.55,
                           direction.count > 2 ? direction[2] : 0.75)
        let normalized = simd_length(vector) > 1e-6 ? simd_normalize(vector) : SIMD3(0.35, 0.55, 0.75)
        // The model and RealityKit are +Y up: azimuth turns in the XZ plane.
        let elevation = asin(min(max(Double(normalized.y), -1), 1)) * 180 / .pi
        let azimuth = atan2(Double(normalized.z), Double(normalized.x)) * 180 / .pi
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(azimuth.rounded()))° / \(Int(elevation.rounded()))°")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(FloeCADStrings.text("cad.environment.azimuth", "Around"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { azimuth },
                    set: { value in
                        setDirection(azimuth: value, elevation: elevation)
                    }), in: -180...180)
                    .accessibilityIdentifier("CADEnvironmentAzimuth")
            }
            HStack {
                Text(FloeCADStrings.text("cad.environment.elevation", "Height"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { elevation },
                    set: { value in
                        setDirection(azimuth: azimuth, elevation: value)
                    }), in: -89...89)
                    .accessibilityIdentifier("CADEnvironmentElevation")
            }
        }
    }

    private func setDirection(azimuth: Double, elevation: Double) {
        let azimuthRadians = azimuth * .pi / 180
        let elevationRadians = elevation * .pi / 180
        let cosElevation = cos(elevationRadians)
        updateSettings {
            $0.lightDirection = [cosElevation * cos(azimuthRadians),
                                 sin(elevationRadians),
                                 cosElevation * sin(azimuthRadians)]
        }
    }
}

#endif
