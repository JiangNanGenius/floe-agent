//
//  MeshUnitPromptSheet.swift
//  openshape3d
//
//  "Import Units" (Shapr3D parity): mesh formats either don't record a unit
//  (OBJ, STL) or are sometimes exported with the wrong one, so before a
//  mesh becomes bodies the user sees the model's size under each unit and
//  picks. The detected unit is preselected; Import applies the choice.
//

import SwiftUI

struct MeshUnitPromptSheet: View {
    let probe: MeshImportProbe
    let onImport: (MeshImportUnit) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var unit: MeshImportUnit
    @State private var confirmedUnit = false

    init(probe: MeshImportProbe, onImport: @escaping (MeshImportUnit) -> Void) {
        self.probe = probe
        self.onImport = onImport
        _unit = State(initialValue: probe.detectedUnit)
        _confirmedUnit = State(initialValue: probe.unitIsDeclared)
    }

    private func importMeaning(_ code: String) -> String {
        switch code {
        case "static_mesh": return FloeCADStrings.text("cad.import.mesh", "Static geometry")
        case "object_placement": return FloeCADStrings.text("cad.import.placement", "Object placement")
        case "part_names": return FloeCADStrings.text("cad.import.names", "Part names")
        case "uv0": return FloeCADStrings.text("cad.import.textureCoordinates", "Texture coordinates")
        case "base_color": return FloeCADStrings.text("cad.import.baseColor", "Base colors")
        case "base_color_texture": return FloeCADStrings.text("cad.import.colorTextures", "Color textures")
        case "supported_pbr_materials", "supported_static_materials": return FloeCADStrings.text("cad.import.materials", "Supported materials")
        case "parametric_history": return FloeCADStrings.text("cad.import.history", "Parametric history")
        case "editable_scene_hierarchy": return FloeCADStrings.text("cad.import.hierarchy", "Editable scene hierarchy")
        case "animations", "animation_rig_modifiers": return FloeCADStrings.text("cad.import.animation", "Animation, rigs and modifiers")
        case "skins", "morph_targets": return FloeCADStrings.text("cad.import.deformation", "Skinning and morph targets")
        case "material_channels_other_than_base_color": return FloeCADStrings.text("cad.import.materialChannels", "Material channels other than base color")
        default: return FloeCADStrings.text("cad.import.otherSceneData", "Other scene data not supported by this importer")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(FloeCADStrings.label("cad.ui.meshImport.file", "File"), value: probe.fileName)
                    LabeledContent(FloeCADStrings.label("cad.ui.meshImport.contents", "Contents"),
                                   value: "\(probe.parts.count) part\(probe.parts.count == 1 ? "" : "s"), "
                                        + "\(probe.triangleCount.formatted()) triangles")
                    // Up here with the file facts so the consequence of the
                    // choice stays in view: a form sheet shows the five unit
                    // rows and nothing below them without scrolling.
                    LabeledContent(FloeCADStrings.label("cad.ui.meshImport.importedSize", "Imported size")) {
                        Text(probe.sizeDescription(for: unit))
                            .monospacedDigit()
                            .accessibilityIdentifier("MeshUnitResult")
                    }
                } footer: {
                    Text(probe.unitNote)
                }

                Section(FloeCADStrings.label("cad.ui.meshImport.unitsInFile", "Units in the file")) {
                    ForEach(MeshImportUnit.allCases) { candidate in
                        Button {
                            unit = candidate
                            confirmedUnit = true
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.label)
                                        .foregroundStyle(Color.primary)
                                    Text(probe.sizeDescription(for: candidate))
                                        .font(.footnote)
                                        .foregroundStyle(Color.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                if probe.unitIsDeclared && candidate == probe.detectedUnit {
                                    Text(FloeCADStrings.label("cad.ui.meshImport.detected", "Detected"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(candidate == unit ? 1 : 0)
                            }
                        }
                        .accessibilityLabel(candidate.label)
                        // The row folds its texts into one element; carry the
                        // size (and state) in the value so it stays inspectable.
                        .accessibilityValue(
                            probe.sizeDescription(for: candidate)
                            + (candidate == unit ? ", selected" : "")
                            + (probe.unitIsDeclared && candidate == probe.detectedUnit ? ", detected" : ""))
                        .accessibilityIdentifier("MeshUnitRow-\(candidate.rawValue)")
                    }
                }
                if let coverage = probe.coverage {
                    Section(FloeCADStrings.text("cad.import.coverage", "Import Details")) {
                        Text(FloeCADStrings.text("cad.import.staticOnly", "Imports static geometry, placement and supported materials."))
                        Text(FloeCADStrings.text("cad.import.originalKept", "Original source files are kept unchanged."))
                        if !coverage.retained.isEmpty {
                            DisclosureGroup(FloeCADStrings.text("cad.import.retained", "Retained")) {
                                ForEach(coverage.retained, id: \.self) { item in Text(importMeaning(item)) }
                            }
                        }
                        if !coverage.discarded.isEmpty {
                            DisclosureGroup(FloeCADStrings.text("cad.import.notKept", "Not retained")) {
                                ForEach(coverage.discarded, id: \.self) { item in Text(importMeaning(item)) }
                            }
                        }
                    }
                }
                if !probe.unitIsDeclared && !confirmedUnit {
                    Text(FloeCADStrings.text("cad.import.chooseUnit", "Choose the file’s unit before importing."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(FloeCADStrings.label("cad.ui.meshImport.title", "Import Units"))
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("MeshUnitCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.import", "Import")) {
                        onImport(unit)
                        dismiss()
                    }
                    .disabled(!confirmedUnit)
                    .accessibilityIdentifier("MeshUnitImport")
                }
            }
        }
        .presentationDetents([.large])
    }
}
