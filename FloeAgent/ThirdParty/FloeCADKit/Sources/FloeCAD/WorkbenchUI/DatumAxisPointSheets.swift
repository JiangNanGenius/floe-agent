//
//  DatumAxisPointSheets.swift
//  FloeCAD
//
//  M08 native UI for associative construction axes and datum points.
//
//  The sheets own DRAFTS only. Every commit goes through the same
//  `EditorViewModel` → `CADDatumService` transaction the assistant uses, so
//  source selection, offsets, undo, save/reopen and broken-source reporting are
//  one implementation. The shared reference picker (Add Axis tool) is armed
//  from here for source creation/reselection rather than duplicating picking.
//

import SwiftUI
import simd

// MARK: - Axis edit sheet

struct DatumAxisEditSheet: View {
    @Bindable var viewModel: EditorViewModel
    let axisID: ConstructionAxisID

    @State private var offset: String
    @State private var length: Double
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel, axisID: ConstructionAxisID) {
        self.viewModel = viewModel
        self.axisID = axisID
        let axis = viewModel.session.document.axes.first { $0.id == axisID }
        _offset = State(initialValue: viewModel.datumAxisOffsetText(axisID))
        _length = State(initialValue: axis?.length ?? 100)
    }

    private var axis: ConstructionAxis? {
        viewModel.session.document.axes.first { $0.id == axisID }
    }

    private var definition: ConstructionAxisDefinition? { axis?.definition }

    private var supportsOffset: Bool {
        definition?.expressionSlots.contains { $0.name == "offset" } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(FloeCADStrings.text("cad.datum.kind", "Source"),
                                   value: viewModel.datumAxisKindLabel(axisID))
                    if let status = viewModel.datumAxisStatus(axisID) {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("DatumAxisStatus")
                    }
                }

                if supportsOffset {
                    Section {
                        TextField(FloeCADStrings.text("cad.datum.offsetMillimetres", "Offset (mm)"),
                                  text: $offset)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(applyOffset)
                            .accessibilityIdentifier("DatumAxisOffsetExpression")
                            .disabled(viewModel.session.isReadOnly)
                    } footer: {
                        Text(FloeCADStrings.text("cad.datum.formulaHint",
                                                 "Enter a distance or a formula using document variables."))
                    }
                }

                Section {
                    TextField(FloeCADStrings.text("cad.datum.axisLength", "Length (mm)"),
                              value: $length,
                              format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("DatumAxisLengthField")
                        .disabled(viewModel.session.isReadOnly)
                } footer: {
                    Text(FloeCADStrings.text("cad.datum.axisLengthHint",
                                             "How long the reference axis is drawn. It never changes the geometry."))
                }

                if definition != nil {
                    Section {
                        Button {
                            if viewModel.beginDatumAxisReselect(axisID) { dismiss() }
                        } label: {
                            Label(FloeCADStrings.text("cad.datum.reselectSource", "Reselect Source"),
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(viewModel.session.isReadOnly)
                        .accessibilityIdentifier("DatumAxisReselect")
                    } footer: {
                        Text(FloeCADStrings.text("cad.datum.reselectSourceHint",
                                                 "Then tap the new straight edge, flat face or round face and press Apply. The kind must match the axis."))
                    }
                }

                if let feedback {
                    Section {
                        Text(feedback)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("DatumAxisError")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if viewModel.deleteDatumAxis(axisID) { dismiss() }
                        else { feedback = viewModel.errorMessage }
                    } label: {
                        Label(FloeCADStrings.text("cad.ui.common.delete", "Delete"),
                              systemImage: "trash")
                    }
                    .accessibilityIdentifier("DatumAxisDelete")
                }
            }
            .navigationTitle(axis?.name ?? FloeCADStrings.text("cad.datum.axis", "Axis"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done", "Done"), action: applyOffset)
                        .accessibilityIdentifier("DatumAxisApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("DatumAxisEditSheet")
    }

    private func applyOffset() {
        let current = viewModel.datumAxisOffsetText(axisID)
        if supportsOffset, offset.trimmingCharacters(in: .whitespacesAndNewlines) != current {
            guard viewModel.updateDatumAxisOffset(axisID, offset: offset,
                                                  expectedOffset: current) else {
                feedback = viewModel.errorMessage
                viewModel.errorMessage = nil
                return
            }
        }
        if let current = axis?.length, abs(current - length) > 1e-9 {
            guard viewModel.updateDatumAxisLength(axisID, length: length) else {
                feedback = viewModel.errorMessage
                viewModel.errorMessage = nil
                return
            }
        }
        dismiss()
    }
}

// MARK: - Point sheet (create + edit)

struct DatumPointSheet: View {
    @Bindable var viewModel: EditorViewModel
    /// Nil = creation mode.
    let pointID: DatumPointID?

    @State private var offset: String = "0"
    @State private var length: Double = 0
    @State private var axisID: ConstructionAxisID?
    @State private var planeID: ConstructionPlaneID?
    @State private var firstChoice: String?
    @State private var secondChoice: String?
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel, pointID: DatumPointID? = nil) {
        self.viewModel = viewModel
        self.pointID = pointID
        if let pointID {
            _offset = State(initialValue: viewModel.datumPointOffsetText(pointID))
        }
        let axes = viewModel.session.document.axes
        _axisID = State(initialValue: axes.first?.id)
        _planeID = State(initialValue: viewModel.session.document.planes.first?.id)
    }

    private var point: DatumPoint? {
        guard let pointID else { return nil }
        return viewModel.session.document.datumPoints.first { $0.id == pointID }
    }

    private var definition: DatumPointDefinition? { point?.definition }

    private var supportsOffset: Bool {
        definition?.expressionSlots.contains { $0.name == "offset" } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let pointID, point != nil {
                    editSections(pointID: pointID)
                } else {
                    creationSections
                }
                if let feedback {
                    Section {
                        Text(feedback)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("DatumPointError")
                    }
                }
            }
            .navigationTitle(point?.name
                             ?? FloeCADStrings.text("cad.datum.addPoint", "Add Point"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("DatumPointSheet")
    }

    // MARK: Existing point

    @ViewBuilder
    private func editSections(pointID: DatumPointID) -> some View {
        Section {
            LabeledContent(FloeCADStrings.text("cad.datum.kind", "Source"),
                           value: viewModel.datumPointKindLabel(pointID))
            if let status = viewModel.datumPointStatus(pointID) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("DatumPointStatus")
            }
        }
        if supportsOffset {
            Section {
                TextField(FloeCADStrings.text("cad.datum.offsetMillimetres", "Offset (mm)"),
                          text: $offset)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("DatumPointOffsetExpression")
                    .disabled(viewModel.session.isReadOnly)
            } footer: {
                Text(FloeCADStrings.text("cad.datum.formulaHint",
                                         "Enter a distance or a formula using document variables."))
            }
            Section {
                Button(FloeCADStrings.text("cad.datum.applyOffset", "Apply Offset"), action: {
                    applyOffset(pointID: pointID)
                })
                .accessibilityIdentifier("DatumPointApplyOffset")
            }
        }
        if definition != nil {
            Section {
                Button {
                    if viewModel.beginDatumPointReselect(pointID) { dismiss() }
                } label: {
                    Label(FloeCADStrings.text("cad.datum.reselectSource", "Reselect Source"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.session.isReadOnly)
                .accessibilityIdentifier("DatumPointReselect")
            } footer: {
                Text(FloeCADStrings.text("cad.datum.reselectPointHint",
                                         "Then tap the new straight edge or flat face and press Apply."))
            }
        }
        Section {
            Button(role: .destructive) {
                if viewModel.deleteDatumPoint(pointID) { dismiss() }
                else { feedback = viewModel.errorMessage }
            } label: {
                Label(FloeCADStrings.text("cad.ui.common.delete", "Delete"),
                      systemImage: "trash")
            }
            .accessibilityIdentifier("DatumPointDelete")
        }
    }

    // MARK: Creation

    @ViewBuilder
    private var creationSections: some View {
        Section {
            Button {
                if viewModel.beginDatumPointFromPick(face: true) { dismiss() }
            } label: {
                Label(FloeCADStrings.text("cad.datum.pointFromFace", "Face Center"),
                      systemImage: "square.dashed")
            }
            .disabled(viewModel.session.isReadOnly)
            .accessibilityIdentifier("DatumPointFromFace")

            Button {
                if viewModel.beginDatumPointFromPick(face: false) { dismiss() }
            } label: {
                Label(FloeCADStrings.text("cad.datum.pointFromEdge", "On Edge"),
                      systemImage: "line.diagonal")
            }
            .disabled(viewModel.session.isReadOnly)
            .accessibilityIdentifier("DatumPointFromEdge")
        } footer: {
            Text(FloeCADStrings.text("cad.datum.pointPickHint",
                                     "Then tap a flat face or a straight edge and press Apply."))
        }

        Section {
            Picker(FloeCADStrings.text("cad.datum.axis", "Axis"),
                   selection: $axisID) {
                ForEach(viewModel.session.document.axes) { axis in
                    Text(axis.name).tag(Optional(axis.id))
                }
            }
            .accessibilityIdentifier("DatumPointAxisPicker")

            TextField(FloeCADStrings.text("cad.datum.offsetMillimetres", "Offset (mm)"),
                      text: $offset)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("DatumPointAxisOffset")

            Button(FloeCADStrings.text("cad.datum.pointOnAxis", "Point on Axis")) {
                guard let axisID else { feedback = noAxisText; return }
                if viewModel.createDatumPointFromAxis(axisID, offset: offset) { dismiss() }
                else { feedback = viewModel.errorMessage }
            }
            .disabled(viewModel.session.isReadOnly || axisID == nil)
            .accessibilityIdentifier("DatumPointCreateOnAxis")
        } footer: {
            Text(FloeCADStrings.text("cad.datum.pointOnAxisHint",
                                     "A point on the axis, offset along it. It follows the axis."))
        }

        Section {
            Picker(FloeCADStrings.text("cad.datum.plane", "Plane"),
                   selection: $planeID) {
                ForEach(viewModel.constructionPlaneChoices) { choice in
                    Text(choice.label).tag(Optional(choice.id))
                }
            }
            .accessibilityIdentifier("DatumPointPlanePicker")

            Button(FloeCADStrings.text("cad.datum.pointAtAxisPlane", "Axis and Plane")) {
                guard let axisID else { feedback = noAxisText; return }
                guard let planeID else { feedback = noPlaneText; return }
                if viewModel.createDatumPointFromAxisPlane(axis: axisID, plane: planeID) { dismiss() }
                else { feedback = viewModel.errorMessage }
            }
            .disabled(viewModel.session.isReadOnly || axisID == nil || planeID == nil)
            .accessibilityIdentifier("DatumPointCreateAxisPlane")
        }

        Section {
            Picker(FloeCADStrings.text("cad.datum.firstPoint", "First Point"),
                   selection: $firstChoice) {
                Text(FloeCADStrings.text("cad.datum.choose", "Choose"))
                    .tag(Optional<String>.none)
                ForEach(viewModel.datumPointChoices) { choice in
                    Text(choice.label).tag(Optional(choice.id))
                }
            }
            .accessibilityIdentifier("DatumPointFirstPicker")

            Picker(FloeCADStrings.text("cad.datum.secondPoint", "Second Point"),
                   selection: $secondChoice) {
                Text(FloeCADStrings.text("cad.datum.choose", "Choose"))
                    .tag(Optional<String>.none)
                ForEach(viewModel.datumPointChoices) { choice in
                    Text(choice.label).tag(Optional(choice.id))
                }
            }
            .accessibilityIdentifier("DatumPointSecondPicker")

            Button(FloeCADStrings.text("cad.datum.midpoint", "Midpoint")) {
                let choices = viewModel.datumPointChoices
                guard let first = choices.first(where: { $0.id == firstChoice }),
                      let second = choices.first(where: { $0.id == secondChoice }),
                      first.id != second.id else {
                    feedback = FloeCADStrings.text("cad.datum.needTwoPoints",
                                                   "Choose two different points.")
                    return
                }
                if viewModel.createDatumPointMidpoint([first.source, second.source]) { dismiss() }
                else { feedback = viewModel.errorMessage }
            }
            .disabled(viewModel.session.isReadOnly)
            .accessibilityIdentifier("DatumPointCreateMidpoint")
        }
    }

    private var noAxisText: String {
        FloeCADStrings.text("cad.datum.chooseAxis", "Choose an axis first.")
    }

    private var noPlaneText: String {
        FloeCADStrings.text("cad.datum.choosePlane", "Choose a plane first.")
    }

    private func applyOffset(pointID: DatumPointID) {
        let current = viewModel.datumPointOffsetText(pointID)
        guard offset.trimmingCharacters(in: .whitespacesAndNewlines) != current else {
            dismiss()
            return
        }
        if viewModel.updateDatumPointOffset(pointID, offset: offset, expectedOffset: current) {
            dismiss()
        } else {
            feedback = viewModel.errorMessage
            viewModel.errorMessage = nil
        }
    }
}

// MARK: - Axis creation sheet (two points / two planes)

struct DatumAxisCreateSheet: View {
    @Bindable var viewModel: EditorViewModel

    @State private var firstPlane: ConstructionPlaneID?
    @State private var secondPlane: ConstructionPlaneID?
    @State private var firstPoint: String?
    @State private var secondPoint: String?
    @State private var length: Double = 0
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        let planes = viewModel.session.document.planes
        _firstPlane = State(initialValue: planes.first?.id)
        _secondPlane = State(initialValue: planes.dropFirst().first?.id)
        _length = State(initialValue: 100)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if viewModel.beginDatumPick(.axisCreate) { dismiss() }
                    } label: {
                        Label(FloeCADStrings.text("cad.datum.axisFromPick",
                                                  "From Edge, Face or Cylinder"),
                              systemImage: "line.diagonal.arrow")
                    }
                    .disabled(viewModel.session.isReadOnly)
                    .accessibilityIdentifier("DatumAxisFromPick")
                } footer: {
                    Text(FloeCADStrings.text("cad.datum.axisFromPickHint",
                                             "Then tap a straight edge, a flat face or a round face and press Apply. The axis keeps following that source."))
                }

                Section {
                    Picker(FloeCADStrings.text("cad.datum.firstPlane", "First Plane"),
                           selection: $firstPlane) {
                        ForEach(viewModel.constructionPlaneChoices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    Picker(FloeCADStrings.text("cad.datum.secondPlane", "Second Plane"),
                           selection: $secondPlane) {
                        ForEach(viewModel.constructionPlaneChoices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    Button(FloeCADStrings.text("cad.datum.axisFromPlanes", "Axis from Two Planes")) {
                        guard let firstPlane, let secondPlane, firstPlane != secondPlane else {
                            feedback = FloeCADStrings.text("cad.datum.needTwoPlanes",
                                                           "Choose two different planes.")
                            return
                        }
                        if viewModel.createDatumAxisFromPlanes([firstPlane, secondPlane],
                                                               length: length) { dismiss() }
                        else { feedback = viewModel.errorMessage }
                    }
                    .disabled(viewModel.session.isReadOnly)
                    .accessibilityIdentifier("DatumAxisCreateTwoPlanes")
                } footer: {
                    Text(FloeCADStrings.text("cad.datum.axisFromPlanesHint",
                                             "The axis is the intersection line and follows both planes, including their own edits."))
                }

                Section {
                    Picker(FloeCADStrings.text("cad.datum.firstPoint", "First Point"),
                           selection: $firstPoint) {
                        Text(FloeCADStrings.text("cad.datum.choose", "Choose"))
                            .tag(Optional<String>.none)
                        ForEach(viewModel.datumPointChoices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    .accessibilityIdentifier("DatumAxisFirstPointPicker")
                    Picker(FloeCADStrings.text("cad.datum.secondPoint", "Second Point"),
                           selection: $secondPoint) {
                        Text(FloeCADStrings.text("cad.datum.choose", "Choose"))
                            .tag(Optional<String>.none)
                        ForEach(viewModel.datumPointChoices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    .accessibilityIdentifier("DatumAxisSecondPointPicker")
                    Button(FloeCADStrings.text("cad.datum.axisFromPoints", "Axis from Two Points")) {
                        let choices = viewModel.datumPointChoices
                        guard let first = choices.first(where: { $0.id == firstPoint }),
                              let second = choices.first(where: { $0.id == secondPoint }),
                              first.id != second.id else {
                            feedback = FloeCADStrings.text("cad.datum.needTwoPoints",
                                                           "Choose two different points.")
                            return
                        }
                        if viewModel.createDatumAxisFromPoints([first.source, second.source],
                                                               length: length) { dismiss() }
                        else { feedback = viewModel.errorMessage }
                    }
                    .disabled(viewModel.session.isReadOnly)
                    .accessibilityIdentifier("DatumAxisCreateTwoPoints")
                } footer: {
                    Text(FloeCADStrings.text("cad.datum.axisFromPointsHint",
                                             "The axis runs through both points and follows either one when it moves."))
                }

                if let feedback {
                    Section {
                        Text(feedback)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("DatumAxisCreateError")
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.datum.addAxis", "Add Axis"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("DatumAxisCreateSheet")
    }
}
