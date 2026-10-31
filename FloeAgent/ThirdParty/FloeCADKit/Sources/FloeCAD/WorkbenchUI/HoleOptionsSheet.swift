//
//  HoleOptionsSheet.swift
//  FloeCAD — M12 native mechanical hole options
//
//  Bounded options only: the locating circle keeps sole ownership of position
//  and pilot diameter, so this sheet never duplicates them. Commit goes through
//  the same `FeatureKind.hole` transaction as `feature.hole` from the AI/command
//  path; there is intentionally no separate live-cut preview in H1.
//

import Foundation
import SwiftUI

struct HoleOptionsSheet: View {
    let viewModel: EditorViewModel
    let draft: EditorViewModel.HoleDraft

    @Environment(\.dismiss) private var dismiss

    @State private var targetID: UUID?
    @State private var type: HoleSpec.Kind
    @State private var depth: Double
    @State private var counterboreDiameter: Double
    @State private var counterboreDepth: Double
    @State private var countersinkDiameter: Double
    @State private var countersinkAngle: Double
    @State private var reversed: Bool
    @State private var errorText: String?

    init(viewModel: EditorViewModel, draft: EditorViewModel.HoleDraft) {
        self.viewModel = viewModel
        self.draft = draft
        _targetID = State(initialValue: draft.targetBodyID?.raw)
        _type = State(initialValue: draft.type)
        _depth = State(initialValue: draft.depth)
        _counterboreDiameter = State(initialValue: draft.counterboreDiameter)
        _counterboreDepth = State(initialValue: draft.counterboreDepth)
        _countersinkDiameter = State(initialValue: draft.countersinkDiameter)
        _countersinkAngle = State(initialValue: draft.countersinkAngle)
        _reversed = State(initialValue: draft.reversed)
    }

    private var bodies: [Body] {
        viewModel.session.document.bodies.filter { $0.brep != nil }
    }

    private var commitLabel: String {
        viewModel.editingHoleFeatureID == nil
            ? FloeCADStrings.text("cad.hole.create", "Create")
            : FloeCADStrings.text("cad.hole.save", "Save")
    }

    private func typeLabel(_ kind: HoleSpec.Kind) -> String {
        switch kind {
        case .throughAll: return FloeCADStrings.text("cad.hole.throughAll", "Through all")
        case .blind: return FloeCADStrings.text("cad.hole.blind", "Blind")
        case .counterbore: return FloeCADStrings.text("cad.hole.counterbore", "Counterbore")
        case .countersink: return FloeCADStrings.text("cad.hole.countersink", "Countersink")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(FloeCADStrings.text("cad.hole.type", "Type"), selection: $type) {
                        ForEach(HoleSpec.Kind.allCases, id: \.self) { kind in
                            Text(typeLabel(kind))
                                .tag(kind)
                                // Stable qualification selectors; the visible
                                // form, layout and copy are unchanged.
                                .accessibilityIdentifier("HoleTypeOption-\(kind.rawValue)")
                        }
                    }
                    .accessibilityIdentifier("HoleTypePicker")
                    if bodies.isEmpty {
                        Text(FloeCADStrings.text(
                            "cad.hole.noTarget", "Add a body to drill into first."))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(FloeCADStrings.text("cad.hole.target", "Target body"),
                               selection: $targetID) {
                            ForEach(bodies) { body in
                                Text(body.name).tag(Optional(body.id.raw))
                            }
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    switch type {
                    case .throughAll:
                        EmptyView()
                    case .blind:
                        LabeledContent(FloeCADStrings.text("cad.hole.depth", "Depth")) {
                            ExpressionValueField(
                                placeholder: FloeCADStrings.text("cad.hole.depth", "Depth"),
                                value: $depth, kind: .length,
                                clamp: 0.001...1e6, width: 90,
                                identifier: "HoleDepth")
                        }
                    case .counterbore:
                        LabeledContent(FloeCADStrings.text(
                            "cad.hole.counterboreDiameter", "Counterbore diameter")) {
                            ExpressionValueField(
                                placeholder: FloeCADStrings.text(
                                    "cad.hole.counterboreDiameter", "Counterbore diameter"),
                                value: $counterboreDiameter, kind: .length,
                                clamp: 0.001...1e6, width: 90,
                                identifier: "HoleCounterboreDiameter")
                        }
                        LabeledContent(FloeCADStrings.text(
                            "cad.hole.counterboreDepth", "Counterbore depth")) {
                            ExpressionValueField(
                                placeholder: FloeCADStrings.text(
                                    "cad.hole.counterboreDepth", "Counterbore depth"),
                                value: $counterboreDepth, kind: .length,
                                clamp: 0.001...1e6, width: 90,
                                identifier: "HoleCounterboreDepth")
                        }
                    case .countersink:
                        LabeledContent(FloeCADStrings.text(
                            "cad.hole.countersinkDiameter", "Countersink diameter")) {
                            ExpressionValueField(
                                placeholder: FloeCADStrings.text(
                                    "cad.hole.countersinkDiameter", "Countersink diameter"),
                                value: $countersinkDiameter, kind: .length,
                                clamp: 0.001...1e6, width: 90,
                                identifier: "HoleCountersinkDiameter")
                        }
                        LabeledContent(FloeCADStrings.text(
                            "cad.hole.countersinkAngle", "Included angle")) {
                            ExpressionValueField(
                                placeholder: FloeCADStrings.text(
                                    "cad.hole.countersinkAngle", "Included angle"),
                                value: $countersinkAngle, kind: .plain,
                                clamp: 30.0...170.0, width: 70,
                                identifier: "HoleCountersinkAngle")
                        }
                    }
                } header: {
                    Text(FloeCADStrings.text("cad.hole.parameters", "Hole parameters"))
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.hole.circleHint",
                        "Position and diameter come from the placement circle. Edit that circle to move or resize the hole."))
                }

                Section {
                    Picker(FloeCADStrings.text("cad.hole.direction", "Drill direction"),
                           selection: $reversed) {
                        Text(FloeCADStrings.text(
                            "cad.hole.directionNormal", "Along plane normal"))
                            .tag(false)
                            .accessibilityIdentifier("HoleDirectionNormal")
                        Text(FloeCADStrings.text(
                            "cad.hole.directionReversed", "Opposite normal"))
                            .tag(true)
                            .accessibilityIdentifier("HoleDirectionReversed")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(FloeCADStrings.text("cad.hole.direction", "Drill direction"))
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.hole.directionHint",
                        "If the plane normal points out of the part, choose Opposite normal."))
                }
            }
            .navigationTitle(viewModel.editingHoleFeatureID == nil
                ? FloeCADStrings.text("cad.hole.title", "Hole")
                : FloeCADStrings.text("cad.hole.edit", "Edit Hole"))
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { MacWindowTitle.restore() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                        viewModel.cancelHole()
                        dismiss()
                    }
                    .accessibilityIdentifier("HoleCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(commitLabel) {
                        guard let targetID else { return }
                        if viewModel.commitHole(
                            targetBodyID: BodyID(raw: targetID),
                            type: type,
                            depth: depth,
                            counterboreDiameter: counterboreDiameter,
                            counterboreDepth: counterboreDepth,
                            countersinkDiameter: countersinkDiameter,
                            countersinkAngle: countersinkAngle,
                            reversed: reversed) {
                            dismiss()
                        } else {
                            errorText = viewModel.errorMessage
                        }
                    }
                    .disabled(targetID == nil)
                    .accessibilityIdentifier("HoleCreate")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
