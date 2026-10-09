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

    init(probe: MeshImportProbe, onImport: @escaping (MeshImportUnit) -> Void) {
        self.probe = probe
        self.onImport = onImport
        _unit = State(initialValue: probe.detectedUnit)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("File", value: probe.fileName)
                    LabeledContent("Contents",
                                   value: "\(probe.parts.count) part\(probe.parts.count == 1 ? "" : "s"), "
                                        + "\(probe.triangleCount.formatted()) triangles")
                    // Up here with the file facts so the consequence of the
                    // choice stays in view: a form sheet shows the five unit
                    // rows and nothing below them without scrolling.
                    LabeledContent("Imported size") {
                        Text(probe.sizeDescription(for: unit))
                            .monospacedDigit()
                            .accessibilityIdentifier("MeshUnitResult")
                    }
                } footer: {
                    Text(probe.unitNote)
                }

                Section("Units in the file") {
                    ForEach(MeshImportUnit.allCases) { candidate in
                        Button {
                            unit = candidate
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
                                if candidate == probe.detectedUnit {
                                    Text("Detected")
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
                            + (candidate == probe.detectedUnit ? ", detected" : ""))
                        .accessibilityIdentifier("MeshUnitRow-\(candidate.rawValue)")
                    }
                }
            }
            .navigationTitle("Import Units")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("MeshUnitCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(unit)
                        dismiss()
                    }
                    .accessibilityIdentifier("MeshUnitImport")
                }
            }
        }
        .presentationDetents([.large])
    }
}
