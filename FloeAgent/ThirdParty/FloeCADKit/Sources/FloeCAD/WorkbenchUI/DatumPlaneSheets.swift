//
//  DatumPlaneSheets.swift
//  FloeCAD
//
//  Items-panel editing and first creation UI for the three associative datum
//  kinds. The views own drafts only; every commit goes through the same
//  `EditorViewModel` → `CADDatumService` transaction path as the native face
//  picker and the public parameter actions.
//

import SwiftUI
import simd

// MARK: - Edit existing datum

struct DatumPlaneEditSheet: View {
    @Bindable var viewModel: EditorViewModel
    let planeID: ConstructionPlaneID
    let kind: ConstructionPlaneDefinition.Kind
    let expectedExpression: String
    let initialPoints: [SketchAnchorRef]

    @State private var expression: String
    @State private var hinge: SIMD2<Double>
    @State private var hingeChanged = false
    @State private var selectedAnchorIDs: [String?]
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel, plane: ConstructionPlane) {
        self.viewModel = viewModel
        planeID = plane.id
        switch plane.definition {
        case let .offset(definition)?:
            kind = .offset
            expectedExpression = definition.distance.formula ?? ""
            _expression = State(initialValue: definition.distance.formula
                ?? String(definition.distance.value))
            _hinge = State(initialValue: SIMD2(1, 0))
            initialPoints = []
            _selectedAnchorIDs = State(initialValue: [])
        case let .angle(definition)?:
            kind = .angle
            expectedExpression = definition.angle.formula ?? ""
            _expression = State(initialValue: definition.angle.formula
                ?? String(definition.angle.value))
            _hinge = State(initialValue: definition.hinge)
            initialPoints = []
            _selectedAnchorIDs = State(initialValue: [])
        case let .threePoints(definition)?:
            kind = .threePoints
            expectedExpression = ""
            _expression = State(initialValue: "")
            _hinge = State(initialValue: SIMD2(1, 0))
            initialPoints = definition.points
            _selectedAnchorIDs = State(
                initialValue: definition.points.map(\.key).map { Optional($0) })
        case nil:
            kind = .offset
            expectedExpression = ""
            _expression = State(initialValue: "0")
            _hinge = State(initialValue: SIMD2(1, 0))
            initialPoints = []
            _selectedAnchorIDs = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .offset:
                    expressionSection(
                        title: FloeCADStrings.text("cad.datum.offsetMillimetres", "Offset (mm)"),
                        footer: FloeCADStrings.text("cad.datum.formulaHint",
                            "Enter a distance or a formula using document variables."),
                        identifier: "DatumOffsetExpression")
                    sourceSection(action: "datum.offsetPlane.update")
                case .angle:
                    expressionSection(
                        title: FloeCADStrings.text("cad.datum.angleDegrees", "Angle (°)"),
                        footer: FloeCADStrings.text("cad.datum.angleHint",
                            "Enter an angle in degrees or a formula using document variables."),
                        identifier: "DatumAngleExpression")
                    Section {
                        Picker(FloeCADStrings.text("cad.datum.hinge", "Hinge"),
                               selection: Binding(
                                get: { hinge.x >= hinge.y ? 0 : 1 },
                                set: {
                                    hinge = $0 == 0 ? SIMD2(1, 0) : SIMD2(0, 1)
                                    hingeChanged = true
                                })) {
                            Text(FloeCADStrings.text("cad.datum.hingeX", "Source X axis")).tag(0)
                            Text(FloeCADStrings.text("cad.datum.hingeY", "Source Y axis")).tag(1)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("DatumEditHinge")
                    } footer: {
                        Text(FloeCADStrings.text("cad.datum.hingeHint",
                            "The plane rotates about this in-plane axis through the source face anchor."))
                    }
                    sourceSection(action: "datum.anglePlane.update")
                case .threePoints:
                    Section {
                        ForEach(0..<3, id: \.self) { index in
                            Picker(FloeCADStrings.text("cad.datum.point", "Point") + " \(index + 1)",
                                   selection: Binding(
                                    get: { selectedAnchorIDs[index] },
                                    set: { selectedAnchorIDs[index] = $0 })) {
                                Text(FloeCADStrings.text("cad.datum.selectPoint",
                                    "Select a point")).tag(String?.none)
                                ForEach(viewModel.threePointAnchorCandidates) { candidate in
                                    Text(candidate.label).tag(Optional(candidate.id))
                                }
                            }
                            .accessibilityIdentifier("DatumEditPoint\(index)")
                        }
                    } header: {
                        Text(FloeCADStrings.text("cad.datum.points", "Source Points"))
                    } footer: {
                        Text(FloeCADStrings.text("cad.datum.threePointHint",
                            "Pick three existing sketch points. The first is the plane origin; the plane follows those entities."))
                    }
                }
                if let feedback {
                    Text(feedback)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(kind == .offset ? "DatumOffsetError" : "DatumEditError")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done", "Done"), action: apply)
                        .disabled(!canApply)
                        .accessibilityIdentifier(kind == .offset ? "DatumOffsetApply" : "DatumEditApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("DatumPlaneEditSheet")
    }

    private var title: String {
        switch kind {
        case .offset: return FloeCADStrings.text("cad.datum.editOffset", "Edit Offset")
        case .angle: return FloeCADStrings.text("cad.datum.editAngle", "Edit Angle")
        case .threePoints:
            return FloeCADStrings.text("cad.datum.editThreePoint", "Edit 3-Point Plane")
        }
    }

    private var canApply: Bool {
        switch kind {
        case .offset, .angle:
            return !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .threePoints:
            let ids = selectedAnchorIDs.compactMap { $0 }
            return ids.count == 3 && Set(ids).count == 3
        }
    }

    @ViewBuilder
    private func expressionSection(title: String, footer: String, identifier: String) -> some View {
        Section {
            TextField(title, text: $expression)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(apply)
                .accessibilityIdentifier(identifier)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private func sourceSection(action: String) -> some View {
        if let selection = viewModel.currentDatumFaceSelection {
            Section {
                Button {
                    if viewModel.reselectDatumSource(planeID, action: action, selection: selection) {
                        dismiss()
                    } else {
                        feedback = viewModel.errorMessage
                        viewModel.errorMessage = nil
                    }
                } label: {
                    Label(FloeCADStrings.text("cad.datum.useSelectedFace",
                        "Use Selected Face"), systemImage: "scope")
                }
                .accessibilityIdentifier("DatumReselectSource")
            } footer: {
                Text(FloeCADStrings.text("cad.datum.selectedFaceHint",
                    "Reselects this datum's source from the face currently held by the native picker."))
            }
        }
    }

    private func apply() {
        let ok: Bool
        switch kind {
        case .offset:
            ok = viewModel.updateDatumPlane(planeID, action: "datum.offsetPlane.update",
                args: ["expression": expression, "expected_expression": expectedExpression])
        case .angle:
            var args: [String: Any] = ["expression": expression,
                                       "expected_expression": expectedExpression]
            if hingeChanged {
                args["hinge_x"] = hinge.x
                args["hinge_y"] = hinge.y
            }
            ok = viewModel.updateDatumPlane(planeID, action: "datum.anglePlane.update",
                                            args: args)
        case .threePoints:
            let candidates = Dictionary(uniqueKeysWithValues:
                viewModel.threePointAnchorCandidates.map { ($0.id, $0) })
            let refs = selectedAnchorIDs.compactMap { $0 }.compactMap { candidates[$0]?.ref }
            guard refs.count == 3 else {
                feedback = FloeCADStrings.text("cad.datum.missingPoint",
                    "A source point is missing. Reselect all three points.")
                return
            }
            ok = viewModel.updateDatumPlane(planeID, action: "datum.threePointPlane.update",
                args: ["points": refs.map(Self.json), "expected_points": initialPoints.map(Self.json)])
        }
        if ok { dismiss() }
        feedback = viewModel.errorMessage
        viewModel.errorMessage = nil
    }

    static func json(_ ref: SketchAnchorRef) -> [String: Any] {
        ["sketch_id": ref.sketchID.raw.uuidString,
         "entity_id": ref.entityID.uuidString,
         "role": ref.role.rawValue]
    }
}

// MARK: - Create three-point datum

struct ThreePointPlaneSheet: View {
    @Bindable var viewModel: EditorViewModel
    @State private var selectedAnchorIDs: [String?] = [nil, nil, nil]
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(0..<3, id: \.self) { index in
                        Picker(FloeCADStrings.text("cad.datum.point", "Point") + " \(index + 1)",
                               selection: Binding(
                                get: { selectedAnchorIDs[index] },
                                set: { selectedAnchorIDs[index] = $0 })) {
                            Text(FloeCADStrings.text("cad.datum.selectPoint",
                                "Select a point")).tag(String?.none)
                            ForEach(viewModel.threePointAnchorCandidates) { candidate in
                                Text(candidate.label).tag(Optional(candidate.id))
                            }
                        }
                        .accessibilityIdentifier("ThreePointPlanePoint\(index)")
                    }
                } header: {
                    Text(FloeCADStrings.text("cad.datum.points", "Source Points"))
                } footer: {
                    Text(FloeCADStrings.text("cad.datum.threePointHint",
                        "Pick three existing sketch points. The first is the plane origin; the plane follows those entities."))
                }
                if let feedback {
                    Text(feedback)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ThreePointPlaneError")
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.datum.addThreePoint", "3-Point Plane"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.datum.create", "Create"), action: create)
                        .disabled(!canCreate)
                        .accessibilityIdentifier("ThreePointPlaneCreate")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ThreePointPlaneSheet")
    }

    private var canCreate: Bool {
        let ids = selectedAnchorIDs.compactMap { $0 }
        return ids.count == 3 && Set(ids).count == 3
    }

    private func create() {
        let candidates = Dictionary(uniqueKeysWithValues:
            viewModel.threePointAnchorCandidates.map { ($0.id, $0) })
        let refs = selectedAnchorIDs.compactMap { $0 }.compactMap { candidates[$0]?.ref }
        guard refs.count == 3 else {
            feedback = FloeCADStrings.text("cad.datum.missingPoint",
                "A source point is missing. Reselect all three points.")
            return
        }
        if viewModel.createThreePointPlane(refs) {
            dismiss()
        } else {
            feedback = viewModel.errorMessage
            viewModel.errorMessage = nil
        }
    }
}
