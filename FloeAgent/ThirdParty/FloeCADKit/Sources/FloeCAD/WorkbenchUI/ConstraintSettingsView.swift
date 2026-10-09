//
//  ConstraintSettingsView.swift
//  openshape3d
//
//  Constraint settings panel (plan §B2): a compact toggle sheet. "Auto-Constrain"
//  is bound to EditorViewModel.autoConstrainSettings — a master switch gating the
//  per-inference sub-toggles and an angle-tolerance stepper. "Visibility" is bound
//  to CADPreferences and decides whether dimensions and constraint glyphs persist
//  outside the sketch being edited (Shapr3D's "Constraint & Locked Dimension
//  Visibility"). Presented while viewModel.showConstraintSettings is true; Done
//  clears that flag.
//

import SwiftUI

struct ConstraintSettingsView: View {
    @Bindable var viewModel: EditorViewModel
    @Bindable var settings: CADPreferences = .shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Always Show Dimensions", isOn: $settings.alwaysShowDimensions)
                        .accessibilityIdentifier("AlwaysShowDimensionsToggle")
                    Toggle("Always Show Constraints", isOn: $settings.alwaysShowConstraints)
                        .accessibilityIdentifier("AlwaysShowConstraintsToggle")
                } header: {
                    Text("Visibility")
                } footer: {
                    Text("When off, annotations follow selected geometry. Turn on to show all annotations in visible sketches, including after leaving sketch mode.")
                }

                SnappingSettingsSection(settings: settings)

                Section {
                    Picker("Keep in place", selection: $settings.anchoredSketchEntity) {
                        ForEach(AnchoredSketchEntity.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("AnchoredSketchEntityPicker")
                } header: {
                    Text("Anchored Sketch Entity")
                } footer: {
                    Text("Choose whether the first or last selected entity stays in place when applying a constraint. Existing constraints take priority.")
                }

                Section {
                    Toggle("Auto-Constrain", isOn: $viewModel.autoConstrainSettings.enabled)
                        .accessibilityIdentifier("AutoConstrainToggle")
                } footer: {
                    Text("Infer sketch constraints automatically while you draw.")
                }

                if viewModel.autoConstrainSettings.enabled {
                    Section("Inferences") {
                        Toggle(
                            "Horizontal / Vertical",
                            isOn: $viewModel.autoConstrainSettings.horizontalVertical
                        )
                        .accessibilityIdentifier("AutoConstrainHVToggle")

                        Toggle(
                            "Snap to Points",
                            isOn: $viewModel.autoConstrainSettings.pointSnap
                        )
                        .accessibilityIdentifier("AutoConstrainPointSnapToggle")

                        Toggle(
                            "Parallel / Perpendicular",
                            isOn: $viewModel.autoConstrainSettings.parallelPerpendicular
                        )
                        .accessibilityIdentifier("AutoConstrainParallelPerpToggle")

                        Toggle(
                            "Tangent",
                            isOn: $viewModel.autoConstrainSettings.tangent
                        )
                        .accessibilityIdentifier("AutoConstrainTangentToggle")

                        Toggle(
                            "Equal Length",
                            isOn: $viewModel.autoConstrainSettings.equal
                        )
                        .accessibilityIdentifier("AutoConstrainEqualToggle")
                        }

                    Section("Tolerance") {
                        Stepper(
                            value: $viewModel.autoConstrainSettings.angleToleranceDeg,
                            in: 1...15,
                            step: 1
                        ) {
                            HStack {
                                Text("Angle Snap")
                                Spacer(minLength: 8)
                                Text("\(Int(viewModel.autoConstrainSettings.angleToleranceDeg.rounded()))°")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("AutoConstrainAngleValue")
                            }
                        }
                        .accessibilityIdentifier("AutoConstrainAngleStepper")
                    }
                }
            }
            .navigationTitle("Constraints")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.showConstraintSettings = false
                    }
                    .accessibilityIdentifier("ConstraintSettingsDone")
                }
            }
        }
        .accessibilityIdentifier("ConstraintSettingsPanel")
        // No half-height detent. At the medium stop, while the sheet could
        // still resize, it swallowed taps on its switches, wherever they sat:
        // the Grid switch (near the bottom edge) ignored 6 of 30 taps in a
        // UI-test diagnostic (2026-09-15), still 1 of 30 with
        // `.presentationContentInteraction(.scrolls)`, and 0 of 15 once the
        // sheet opened full height. `SheetDetentTapUITests` later measured
        // 17 of 60 on the Grid switch and 3 of 30 on the top switch.
    }
}
