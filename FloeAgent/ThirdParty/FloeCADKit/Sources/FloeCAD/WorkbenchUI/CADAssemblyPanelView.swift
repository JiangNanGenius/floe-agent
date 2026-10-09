//
//  CADAssemblyPanelView.swift
//  FloeCADKit
//
//  Assembly panel for the Floe workbench: explicit instance placement (source
//  body picker — NEVER an implicit first body), per-instance transform/hide/
//  delete, and full create/suppress/remove of fixed/coaxial/planarAlign/
//  distance/angle constraints over `CADAssemblyService`. Constraint geometry
//  is entered as named axis presets + numeric fields; solvable failures are
//  reported with preview diagnostics and never mutate the stored model.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

// MARK: - Report model

struct CADAssemblyReport {
    struct Instance: Identifiable {
        var id: String
        var name: String
        var bodyID: String
        var dof: Int
        var stale: Bool
        var hidden: Bool
        var independentCopy: Bool
        var position: SIMD3<Double>
        var rotation: SIMD4<Double>
        var scale: SIMD3<Double>
    }
    struct Constraint: Identifiable {
        var id: String
        var kind: String
        var instanceA: String
        var instanceB: String?
        var value: Double?
        var suppressed: Bool
        var valid: Bool
        var conflicting: Bool
        var redundant: Bool
    }
    var instances: [Instance] = []
    var constraints: [Constraint] = []
    var assemblyDOF = 0
    var relativeDOF = 0
    var globalRigidDOF = 0
    var fullyConstrained = false
    var unconstrainedCount = 0
    var conflictCount = 0
    var invalidCount = 0
    var redundantCount = 0
    var staleCount = 0

    init() {}

    init(reply: [String: Any]) {
        assemblyDOF = reply["assemblyDOF"] as? Int ?? 0
        relativeDOF = reply["relativeDOF"] as? Int ?? 0
        globalRigidDOF = reply["globalRigidDOF"] as? Int ?? 0
        fullyConstrained = reply["fullyConstrained"] as? Bool ?? false
        unconstrainedCount = (reply["unconstrainedInstances"] as? [String])?.count ?? 0
        let conflicts = Set(reply["conflicts"] as? [String] ?? reply["conflicting"] as? [String] ?? [])
        conflictCount = conflicts.count
        invalidCount = Set(reply["invalidRefs"] as? [String] ?? []).count
        redundantCount = Set(reply["redundantConstraints"] as? [String] ?? []).count
        instances = (reply["instances"] as? [[String: Any]] ?? []).map { row in
            let transform = row["transform"] as? [String: Any] ?? [:]
            let position = (transform["position"] as? [Double]) ?? [0, 0, 0]
            let rotation = (transform["rotation"] as? [Double]) ?? [0, 0, 0, 1]
            let scale = (transform["scale"] as? [Double]) ?? [1, 1, 1]
            return Instance(
                id: row["id"] as? String ?? "",
                name: row["name"] as? String ?? "—",
                bodyID: row["bodyID"] as? String ?? "",
                dof: row["dof"] as? Int ?? 0,
                stale: row["stale"] as? Bool ?? false,
                hidden: row["hidden"] as? Bool ?? false,
                independentCopy: row["independentCopy"] as? Bool ?? false,
                position: SIMD3(position.count == 3 ? position[0] : 0,
                                position.count == 3 ? position[1] : 0,
                                position.count == 3 ? position[2] : 0),
                rotation: SIMD4(rotation.count == 4 ? rotation[0] : 0,
                                rotation.count == 4 ? rotation[1] : 0,
                                rotation.count == 4 ? rotation[2] : 0,
                                rotation.count == 4 ? rotation[3] : 1),
                scale: SIMD3(scale.count == 3 ? scale[0] : 1,
                             scale.count == 3 ? scale[1] : 1,
                             scale.count == 3 ? scale[2] : 1))
        }
        constraints = (reply["constraints"] as? [[String: Any]] ?? []).map { row in
            Constraint(id: row["id"] as? String ?? "",
                       kind: row["kind"] as? String ?? "",
                       instanceA: row["instanceA"] as? String ?? "",
                       instanceB: row["instanceB"] as? String,
                       value: row["value"] as? Double,
                       suppressed: row["suppressed"] as? Bool ?? false,
                       valid: row["valid"] as? Bool ?? true,
                       conflicting: conflicts.contains(row["id"] as? String ?? ""),
                       redundant: row["redundant"] as? Bool ?? false)
        }
        staleCount = instances.filter(\.stale).count
    }

    func instanceName(_ id: String) -> String {
        instances.first { $0.id == id }?.name ?? String(id.prefix(8))
    }
}

func localizedConstraintKind(_ raw: String) -> String {
    let key = "cad.constraint.\(raw)"
    let fallback: String
    switch raw {
    case "fixed": fallback = "Fixed"
    case "coaxial": fallback = "Coaxial"
    case "planarAlign": fallback = "Planar align"
    case "distance": fallback = "Distance"
    case "angle": fallback = "Angle"
    default: fallback = raw
    }
    return FloeCADStrings.text(key, fallback)
}

// MARK: - Panel

struct CADAssemblyPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var report = CADAssemblyReport()
    @State private var outcome: [String: Any] = [:]
    @State private var busy = false
    @State private var showPlaceSheet = false
    @State private var editingInstance: CADAssemblyReport.Instance?
    @State private var showConstraintSheet = false

    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.assembly", "Assembly"),
                             identifier: "CADAssemblyPanel") {
            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.place", "Place instance"),
                                  systemImage: "cube.transparent", disabled: busy) {
                    showPlaceSheet = true
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.addConstraint", "Add constraint"),
                                  systemImage: "link.badge.plus",
                                  disabled: busy || report.instances.isEmpty) {
                    showConstraintSheet = true
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.solve", "Solve"),
                                  systemImage: "arrow.triangle.branch", disabled: busy) {
                    run { await $0.handleAsync(action: "solve", args: [:]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.dof", "DOF"),
                                  systemImage: "number", disabled: busy) {
                    refresh()
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.interference", "Interference"),
                                  systemImage: "square.on.square.dashed", disabled: busy) {
                    run { await $0.handleAsync(action: "interference", args: ["toleranceMM": 1e-6]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.source", "Update sources"),
                                  systemImage: "arrow.triangle.2.circlepath", disabled: busy) {
                    run { await $0.handleAsync(action: "sourceUpdate", args: [:]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.sourceApply", "Apply sources"),
                                  systemImage: "checkmark.arrow.trianglehead.counterclockwise", disabled: busy) {
                    run { await $0.handleAsync(action: "sourceUpdate", args: ["apply": true]) }
                }
            }

            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)
            assemblyReportContent
        }
        .task { refresh() }
        .sheet(isPresented: $showPlaceSheet) {
            CADAssemblyPlaceSheet(
                document: document,
                preferredSourceBodyID: selectedBodyID,
                busy: $busy,
                onPlaced: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true {
                        // Select the new instance so the viewport highlights
                        // exactly the placement that was just created.
                        if let id = reply["id"] as? String, let uuid = UUID(uuidString: id) {
                            viewModel.selectedAssemblyInstances = [uuid]
                        }
                        refresh()
                    }
                })
        }
        .sheet(item: $editingInstance) { instance in
            CADInstanceTransformSheet(
                document: document,
                instance: instance,
                busy: $busy,
                onApplied: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true { refresh() }
                })
        }
        .sheet(isPresented: $showConstraintSheet) {
            CADConstraintEditorSheet(
                document: document,
                report: report,
                busy: $busy,
                onAdded: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true { refresh() }
                })
        }
    }

    @ViewBuilder
    private var assemblyReportContent: some View {
        if report.instances.isEmpty {
            PanelEmptyState(
                text: FloeCADStrings.text("cad.workbench.assembly.empty", "No assembly instances yet."),
                hint: FloeCADStrings.text("cad.workbench.assembly.emptyHint",
                                          "Tap “Place instance” and pick the source body explicitly; constraints are solved against the placed instances."))
        } else {
            PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.instances", "Instances")) {
                ForEach(report.instances) { instance in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            select(instance)
                        } label: {
                            HStack(spacing: 8) {
                                Text(instance.name)
                                    .font(.callout)
                                Spacer(minLength: 4)
                                if isSelected(instance) {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.assembly.selectedInViewport",
                                                                         "selected"),
                                               tint: .blue)
                                }
                                if instance.hidden {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.hidden", "hidden"))
                                }
                                if instance.independentCopy {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.copy", "copy"))
                                }
                                if instance.stale {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                               tint: .orange)
                                }
                                PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofEach", "%@ DOF", instance.dof),
                                           tint: instance.dof == 0 ? .green : .blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("CADAssemblyInstanceSelect-\(instance.id)")
                        panelHitTarget(Button(FloeCADStrings.label("cad.workbench.assembly.editInstance", "Edit transform")) {
                            editingInstance = instance
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small))
                        .accessibilityIdentifier("CADAssemblyInstanceEdit-\(instance.id)")
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("CADAssemblyInstance-\(instance.id)")
                    .contextMenu {
                        Button(FloeCADStrings.label("cad.workbench.assembly.selectInstance", "Select in viewport")) {
                            select(instance)
                        }
                        Button(FloeCADStrings.label("cad.workbench.assembly.editInstance", "Edit transform")) {
                            editingInstance = instance
                        }
                        Button(instance.hidden
                               ? FloeCADStrings.text("cad.workbench.assembly.show", "Show")
                               : FloeCADStrings.text("cad.workbench.assembly.hide", "Hide")) {
                            setVisible(instance, hidden: !instance.hidden)
                        }
                        Button(role: .destructive) {
                            removeInstance(instance)
                        } label: {
                            Text(FloeCADStrings.text("cad.workbench.assembly.delete", "Delete instance"))
                        }
                    }
                }
            }

            PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.constraints", "Constraints")) {
                if report.constraints.isEmpty {
                    Text(FloeCADStrings.text("cad.workbench.assembly.noConstraints",
                                             "No constraints yet — add fixed, coaxial, planar, distance or angle."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(report.constraints) { constraint in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(localizedConstraintKind(constraint.kind))
                                    .font(.callout)
                                Text(constraintDescription(constraint))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let value = constraint.value {
                                    Text("· \(Self.valueFormatter.string(from: NSNumber(value: value)) ?? "\(value)")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if constraint.suppressed {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.suppressed", "suppressed"))
                                }
                                if !constraint.valid {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.invalid", "invalid ref"),
                                               tint: .red)
                                }
                                if constraint.conflicting {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.conflict", "conflict"),
                                               tint: .red)
                                }
                                if constraint.redundant {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.redundant", "redundant"),
                                               tint: .orange)
                                }
                            }
                            HStack(spacing: 8) {
                                panelHitTarget(Button(constraint.suppressed
                                                      ? FloeCADStrings.text("cad.workbench.assembly.enable", "Enable")
                                                      : FloeCADStrings.text("cad.workbench.assembly.suppress", "Suppress")) {
                                    suppress(constraint, suppressed: !constraint.suppressed)
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(role: .destructive) {
                                    removeConstraint(constraint)
                                } label: {
                                    Text(FloeCADStrings.text("cad.workbench.assembly.removeConstraint", "Remove"))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("CADAssemblyConstraint-\(constraint.id)")
                    }
                }
            }

            PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.results", "Results")) {
                HStack(spacing: 10) {
                    PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofTotal", "%@ DOF total", report.assemblyDOF),
                               tint: report.assemblyDOF == 0 ? .green : .blue)
                    PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.relative", "%@ relative", report.relativeDOF),
                               tint: .secondary)
                    if report.globalRigidDOF > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.globalRigid",
                                                               "%@ global (unfixed)", report.globalRigidDOF),
                                   tint: .orange)
                    }
                    if report.fullyConstrained {
                        PanelBadge(text: FloeCADStrings.text("cad.workbench.assembly.fullyConstrained",
                                                             "fully constrained"),
                                   tint: .green)
                    }
                    if report.unconstrainedCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.unconstrained", "%@ unconstrained", report.unconstrainedCount),
                                   tint: .orange)
                    }
                    if report.conflictCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.conflicts", "%@ conflicts", report.conflictCount),
                                   tint: .red)
                    }
                    if report.invalidCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.invalid", "%@ invalid refs", report.invalidCount),
                                   tint: .red)
                    }
                    if report.redundantCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.redundant", "%@ redundant", report.redundantCount),
                                   tint: .orange)
                    }
                }
            }
        }
    }

    private func constraintDescription(_ constraint: CADAssemblyReport.Constraint) -> String {
        let a = report.instanceName(constraint.instanceA)
        guard let b = constraint.instanceB else { return a }
        return "\(a) ↔ \(report.instanceName(b))"
    }

    private static let valueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private func refresh() {
        run { await $0.handleAsync(action: "report", args: [:]) }
    }

    private func setVisible(_ instance: CADAssemblyReport.Instance, hidden: Bool) {
        run { await $0.handleAsync(action: "setVisible",
                                   args: ["id": instance.id, "hidden": hidden]) }
    }

    /// Selects an instance in the viewport highlight (runtime selection only).
    private func select(_ instance: CADAssemblyReport.Instance) {
        guard let uuid = UUID(uuidString: instance.id) else { return }
        viewModel.selectedAssemblyInstances = [uuid]
    }

    private func isSelected(_ instance: CADAssemblyReport.Instance) -> Bool {
        guard let uuid = UUID(uuidString: instance.id) else { return false }
        return viewModel.selectedAssemblyInstances.contains(uuid)
    }

    private func removeInstance(_ instance: CADAssemblyReport.Instance) {
        run { await $0.handleAsync(action: "removeInstance", args: ["id": instance.id]) }
    }

    private func suppress(_ constraint: CADAssemblyReport.Constraint, suppressed: Bool) {
        run { await $0.handleAsync(action: "suppressConstraint",
                                   args: ["id": constraint.id, "suppressed": suppressed]) }
    }

    private func removeConstraint(_ constraint: CADAssemblyReport.Constraint) {
        run { await $0.handleAsync(action: "removeConstraint", args: ["id": constraint.id]) }
    }

    private func run(_ operation: @escaping @MainActor (CADAssemblyService) async -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = await operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            outcome = reply
            let fresh = await service.handleAsync(action: "report", args: [:])
            report = CADAssemblyReport(reply: fresh)
            busy = false
        }
    }
}

// MARK: - Place sheet

private struct CADAssemblyPlaceSheet: View {
    let document: FloeCADDocument
    let preferredSourceBodyID: UUID?
    @Binding var busy: Bool
    let onPlaced: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceBodyID: UUID?
    @State private var name = ""
    @State private var positionX = "0"
    @State private var positionY = "0"
    @State private var positionZ = "0"
    @State private var eulerX = "0"
    @State private var eulerY = "0"
    @State private var eulerZ = "0"
    @State private var scale = "1"
    @State private var independentCopy = false
    @State private var errorText: String?

    private var bodies: [CADPanelBodyOption] { document.panelBodyOptions }

    private var positionValues: SIMD3<Double>? {
        guard let x = Double(positionX), let y = Double(positionY), let z = Double(positionZ),
              x.isFinite, y.isFinite, z.isFinite else { return nil }
        return SIMD3(x, y, z)
    }

    private var eulerValues: SIMD3<Double>? {
        guard let x = Double(eulerX), let y = Double(eulerY), let z = Double(eulerZ),
              x.isFinite, y.isFinite, z.isFinite else { return nil }
        return SIMD3(x, y, z)
    }

    private var scaleValue: Double? {
        guard let value = Double(scale), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var canPlace: Bool {
        sourceBodyID != nil && positionValues != nil && eulerValues != nil && scaleValue != nil && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.assembly.sourceBody", "Source body")) {
                    Picker(FloeCADStrings.text("cad.workbench.assembly.sourceBody", "Source body"),
                           selection: $sourceBodyID) {
                        Text(FloeCADStrings.text("cad.workbench.assembly.pickBody",
                                                 "Select a body…"))
                            .tag(UUID?.none)
                        ForEach(bodies) { body in
                            Text(body.name).tag(UUID?.some(body.id))
                        }
                    }
                    .accessibilityIdentifier("CADPlaceSourceBody")
                    Text(FloeCADStrings.text("cad.workbench.assembly.sourceHint",
                                             "The instance places the chosen body; “Independent copy” duplicates it instead of sharing it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(FloeCADStrings.text("cad.workbench.assembly.instance", "Instance")) {
                    TextField(FloeCADStrings.text("cad.workbench.assembly.name", "Name"), text: $name)
                        .accessibilityIdentifier("CADPlaceName")
                    Toggle(FloeCADStrings.text("cad.workbench.assembly.independentCopy",
                                               "Independent copy"), isOn: $independentCopy)
                        .accessibilityIdentifier("CADPlaceIndependentCopy")
                }

                Section(FloeCADStrings.text("cad.workbench.assembly.position", "Position (mm)")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $positionX, identifier: "CADPlacePosX")
                        CADPanelNumberField(title: "Y", text: $positionY, identifier: "CADPlacePosY")
                        CADPanelNumberField(title: "Z", text: $positionZ, identifier: "CADPlacePosZ")
                    }
                }

                Section(FloeCADStrings.text("cad.workbench.assembly.rotation", "Rotation (degrees, X→Y→Z)")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $eulerX, identifier: "CADPlaceRotX")
                        CADPanelNumberField(title: "Y", text: $eulerY, identifier: "CADPlaceRotY")
                        CADPanelNumberField(title: "Z", text: $eulerZ, identifier: "CADPlaceRotZ")
                    }
                }

                Section(FloeCADStrings.text("cad.workbench.assembly.scale", "Scale")) {
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.assembly.uniformScale", "Uniform"),
                                        text: $scale, identifier: "CADPlaceScale")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.assembly.place", "Place instance"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.place", "Place")) { place() }
                        .disabled(!canPlace)
                        .accessibilityIdentifier("CADPlaceConfirm")
                }
            }
            .onAppear {
                if let preferredSourceBodyID,
                   bodies.contains(where: { $0.id == preferredSourceBodyID }) {
                    sourceBodyID = preferredSourceBodyID
                } else if let first = bodies.first, sourceBodyID == nil {
                    name = first.name
                }
            }
            .onChange(of: sourceBodyID) { _, newValue in
                if name.trimmingCharacters(in: .whitespaces).isEmpty,
                   let body = bodies.first(where: { $0.id == newValue }) {
                    name = body.name
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func place() {
        guard let sourceBodyID, let position = positionValues,
              let euler = eulerValues, let scaleValue else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let q = CADPanelTransform.quaternion(eulerDegrees: euler)
            let transform: [String: Any] = [
                "position": [position.x, position.y, position.z],
                "rotation": [q.x, q.y, q.z, q.w],
                "scale": [scaleValue, scaleValue, scaleValue],
            ]
            let nameValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = await service.handleAsync(action: "addInstance", args: [
                "bodyID": sourceBodyID.uuidString,
                "name": nameValue.isEmpty ? "Instance" : nameValue,
                "transform": transform,
                "independentCopy": independentCopy,
            ])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onPlaced(reply)
            if reply["ok"] as? Bool == true {
                dismiss()
            } else {
                errorText = reply["message"] as? String
                    ?? FloeCADStrings.text("cad.workbench.assembly.placeFailed",
                                           "The instance could not be placed.")
            }
        }
    }
}

// MARK: - Instance transform sheet

private struct CADInstanceTransformSheet: View {
    let document: FloeCADDocument
    let instance: CADAssemblyReport.Instance
    @Binding var busy: Bool
    let onApplied: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var positionX: String
    @State private var positionY: String
    @State private var positionZ: String
    @State private var eulerX: String
    @State private var eulerY: String
    @State private var eulerZ: String
    @State private var scale: String
    @State private var errorText: String?

    init(document: FloeCADDocument, instance: CADAssemblyReport.Instance,
         busy: Binding<Bool>, onApplied: @escaping ([String: Any]) -> Void) {
        self.document = document
        self.instance = instance
        self._busy = busy
        self.onApplied = onApplied
        let euler = CADPanelTransform.eulerDegrees(quaternion: instance.rotation)
        _positionX = State(initialValue: CADPanelTransform.format(instance.position.x))
        _positionY = State(initialValue: CADPanelTransform.format(instance.position.y))
        _positionZ = State(initialValue: CADPanelTransform.format(instance.position.z))
        _eulerX = State(initialValue: CADPanelTransform.format(euler.x))
        _eulerY = State(initialValue: CADPanelTransform.format(euler.y))
        _eulerZ = State(initialValue: CADPanelTransform.format(euler.z))
        _scale = State(initialValue: CADPanelTransform.format(instance.scale.x))
    }

    private var canApply: Bool {
        Double(positionX) != nil && Double(positionY) != nil && Double(positionZ) != nil
            && Double(eulerX) != nil && Double(eulerY) != nil && Double(eulerZ) != nil
            && (Double(scale) ?? 0) > 0 && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.assembly.position", "Position (mm)")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $positionX, identifier: "CADEditPosX")
                        CADPanelNumberField(title: "Y", text: $positionY, identifier: "CADEditPosY")
                        CADPanelNumberField(title: "Z", text: $positionZ, identifier: "CADEditPosZ")
                    }
                }
                Section(FloeCADStrings.text("cad.workbench.assembly.rotation", "Rotation (degrees, X→Y→Z)")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $eulerX, identifier: "CADEditRotX")
                        CADPanelNumberField(title: "Y", text: $eulerY, identifier: "CADEditRotY")
                        CADPanelNumberField(title: "Z", text: $eulerZ, identifier: "CADEditRotZ")
                    }
                }
                Section(FloeCADStrings.text("cad.workbench.assembly.scale", "Scale")) {
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.assembly.uniformScale", "Uniform"),
                                        text: $scale, identifier: "CADEditScale")
                }
                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(instance.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply", "Apply")) { apply() }
                        .disabled(!canApply)
                        .accessibilityIdentifier("CADEditConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply() {
        guard canApply,
              let x = Double(positionX), let y = Double(positionY), let z = Double(positionZ),
              let rx = Double(eulerX), let ry = Double(eulerY), let rz = Double(eulerZ),
              let scaleValue = Double(scale) else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            let q = CADPanelTransform.quaternion(eulerDegrees: SIMD3(rx, ry, rz))
            let service = CADAssemblyService(document: document)
            let reply = await service.handleAsync(action: "setTransform", args: [
                "id": instance.id,
                "transform": [
                    "position": [x, y, z],
                    "rotation": [q.x, q.y, q.z, q.w],
                    "scale": [scaleValue, scaleValue, scaleValue],
                ],
            ])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onApplied(reply)
            if reply["ok"] as? Bool == true {
                dismiss()
            } else {
                errorText = reply["message"] as? String
            }
        }
    }
}

// MARK: - Constraint editor

private struct CADConstraintEditorSheet: View {
    let document: FloeCADDocument
    let report: CADAssemblyReport
    @Binding var busy: Bool
    let onAdded: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "fixed"
    @State private var instanceA: String?
    @State private var instanceB: String?
    @State private var axisA: CADPanelAxisPreset = .zPlus
    @State private var axisB: CADPanelAxisPreset = .zPlus
    @State private var pointAX = "0"
    @State private var pointAY = "0"
    @State private var pointAZ = "0"
    @State private var pointBX = "0"
    @State private var pointBY = "0"
    @State private var pointBZ = "0"
    @State private var value = "0"
    @State private var errorText: String?

    private var kindLabel: String { localizedConstraintKind(kind) }
    private var needsB: Bool { kind != "fixed" }
    private var usesAxis: Bool { kind == "coaxial" || kind == "planarAlign" || kind == "angle" }
    private var usesValue: Bool { kind == "distance" || kind == "angle" }
    private var usesPoints: Bool { kind == "distance" || kind == "coaxial" || kind == "planarAlign" }

    private var canAdd: Bool {
        guard !busy, instanceA != nil else { return false }
        if needsB, instanceB == nil || instanceB == instanceA { return false }
        if usesValue {
            guard let number = Double(value), number.isFinite else { return false }
            if kind == "distance", number < 0 { return false }
            if kind == "angle", number < 0 || number > 180 { return false }
        }
        if usesPoints {
            for text in [pointAX, pointAY, pointAZ, pointBX, pointBY, pointBZ]
            where Double(text) == nil { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.assembly.constraintKind", "Constraint")) {
                    Picker(FloeCADStrings.text("cad.workbench.assembly.constraintKind", "Constraint"),
                           selection: $kind) {
                        Text(localizedConstraintKind("fixed")).tag("fixed")
                        Text(localizedConstraintKind("coaxial")).tag("coaxial")
                        Text(localizedConstraintKind("planarAlign")).tag("planarAlign")
                        Text(localizedConstraintKind("distance")).tag("distance")
                        Text(localizedConstraintKind("angle")).tag("angle")
                    }
                    .accessibilityIdentifier("CADConstraintKind")
                    Picker(FloeCADStrings.text("cad.workbench.assembly.instanceA", "Instance A"),
                           selection: $instanceA) {
                        Text(FloeCADStrings.text("cad.workbench.assembly.pickInstance", "Select…"))
                            .tag(String?.none)
                        ForEach(report.instances) { instance in
                            Text(instance.name).tag(String?.some(instance.id))
                        }
                    }
                    .accessibilityIdentifier("CADConstraintInstanceA")
                    if needsB {
                        Picker(FloeCADStrings.text("cad.workbench.assembly.instanceB", "Instance B"),
                               selection: $instanceB) {
                            Text(FloeCADStrings.text("cad.workbench.assembly.pickInstance", "Select…"))
                                .tag(String?.none)
                            ForEach(report.instances.filter { $0.id != instanceA }) { instance in
                                Text(instance.name).tag(String?.some(instance.id))
                            }
                        }
                        .accessibilityIdentifier("CADConstraintInstanceB")
                    }
                }

                if usesAxis {
                    Section(FloeCADStrings.text("cad.workbench.assembly.axisA",
                                                "Axis/face on A (local)")) {
                        Picker(FloeCADStrings.text("cad.workbench.assembly.axisA", "Axis/face on A (local)"),
                               selection: $axisA) {
                            ForEach(CADPanelAxisPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("CADConstraintAxisA")
                    }
                    Section(FloeCADStrings.text("cad.workbench.assembly.axisB",
                                                "Axis/face on B (local)")) {
                        Picker(FloeCADStrings.text("cad.workbench.assembly.axisB", "Axis/face on B (local)"),
                               selection: $axisB) {
                            ForEach(CADPanelAxisPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("CADConstraintAxisB")
                    }
                }

                if usesPoints {
                    Section(FloeCADStrings.text("cad.workbench.assembly.pointA",
                                                "Reference point on A (mm)")) {
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "X", text: $pointAX)
                            CADPanelNumberField(title: "Y", text: $pointAY)
                            CADPanelNumberField(title: "Z", text: $pointAZ)
                        }
                    }
                    Section(FloeCADStrings.text("cad.workbench.assembly.pointB",
                                                "Reference point on B (mm)")) {
                        HStack(spacing: 10) {
                            CADPanelNumberField(title: "X", text: $pointBX)
                            CADPanelNumberField(title: "Y", text: $pointBY)
                            CADPanelNumberField(title: "Z", text: $pointBZ)
                        }
                    }
                }

                if usesValue {
                    Section(kind == "angle"
                            ? FloeCADStrings.text("cad.workbench.assembly.angleDegrees", "Angle (degrees, 0–180)")
                            : FloeCADStrings.text("cad.workbench.assembly.distanceMM", "Distance (mm)")) {
                        CADPanelNumberField(title: kind == "angle" ? "°" : "mm",
                                            text: $value,
                                            identifier: "CADConstraintValue")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(kindLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.add", "Add")) { add() }
                        .disabled(!canAdd)
                        .accessibilityIdentifier("CADConstraintConfirm")
                }
            }
            .onAppear {
                if instanceA == nil { instanceA = report.instances.first?.id }
            }
            .onChange(of: kind) { _, _ in
                if kind == "fixed" { instanceB = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard let instanceA else { return }
        var args: [String: Any] = ["kind": kind, "instanceA": instanceA]
        if needsB { args["instanceB"] = instanceB }
        if usesAxis {
            args["directionA"] = [axisA.vector.x, axisA.vector.y, axisA.vector.z]
            args["directionB"] = [axisB.vector.x, axisB.vector.y, axisB.vector.z]
        }
        if usesPoints {
            args["pointA"] = [Double(pointAX) ?? 0, Double(pointAY) ?? 0, Double(pointAZ) ?? 0]
            args["pointB"] = [Double(pointBX) ?? 0, Double(pointBY) ?? 0, Double(pointBZ) ?? 0]
        }
        if usesValue, let number = Double(value) { args["value"] = number }
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = await service.handleAsync(action: "addConstraint", args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onAdded(reply)
            if reply["ok"] as? Bool == true {
                dismiss()
            } else {
                errorText = reply["message"] as? String
                    ?? FloeCADStrings.text("cad.workbench.assembly.constraintFailed",
                                           "The constraint could not be added.")
            }
        }
    }
}
#endif
