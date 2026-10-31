//
//  CADAssemblyPanelView.swift
//  FloeCADKit
//
//  Assembly panel for the Floe workbench: explicit instance placement (source
//  body picker — NEVER an implicit first body), per-instance transform/hide/
//  delete, and full create/edit/suppress/remove of fixed/coaxial/planarAlign/
//  distance/angle constraints over `CADAssemblyService`. Constraints can use
//  live face/axis/edge references from the real kernel geometry (native
//  picker + current viewport selection) or the legacy numeric presets/points;
//  named exploded views persist per-instance offsets without moving the base
//  geometry. Solvable failures are reported with preview diagnostics and never
//  mutate the stored model.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
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
        var isSubassembly: Bool
        var childCount: Int
        var parentID: String?
        var path: [String]
        var depth: Int
        var referenceID: String?
        var referenceStatus: String?
        var referenceMissing: Bool
        var position: SIMD3<Double>
        var rotation: SIMD4<Double>
        var scale: SIMD3<Double>
    }
    struct Reference: Identifiable {
        var id: String
        var name: String
        var status: String
        var missing: Bool
        var updateAvailable: Bool
        var sourceRevision: Int
        var sourceSchemaVersion: Int
        var sourceHash: String
        var stagedGeometryHash: String
        var stagedBodyID: String
        var sharedCount: Int
        var independentCount: Int
        var subassemblyNames: [String]
        var cachedGeometry: Bool
    }
    struct Constraint: Identifiable {
        var id: String
        var kind: String
        var instanceA: String
        var instanceB: String?
        var value: Double?
        var valueUnit: String?
        var suppressed: Bool
        var valid: Bool
        var conflicting: Bool
        var redundant: Bool
        var staleReference: Bool
        var pointA: SIMD3<Double>
        var directionA: SIMD3<Double>
        var pointB: SIMD3<Double>?
        var directionB: SIMD3<Double>?
        var sourceRevisionA: UInt64?
        var sourceRevisionB: UInt64?
        var parentID: String?
        var scope: String?
    }
    struct ExplodedView: Identifiable {
        var id: String
        var name: String
        var direction: SIMD3<Double>
        var distanceMM: Double
        var entryCount: Int
        var invalidCount: Int
    }
    var instances: [Instance] = []
    var constraints: [Constraint] = []
    var explodedViews: [ExplodedView] = []
    var references: [Reference] = []
    var assemblyDOF = 0
    var relativeDOF = 0
    var globalRigidDOF = 0
    var assemblyDOFScope = "root"
    var fullyConstrained = false
    var rootFullyConstrained = false
    var nestedFullyConstrained = true
    var dofCredible = true
    var solved = true
    var unconstrainedCount = 0
    var conflictCount = 0
    var invalidCount = 0
    var redundantCount = 0
    var staleCount = 0

    /// True when the assembly contains at least one subassembly container, so
    /// the root-scope DOF count is NOT a whole-assembly total.
    var hasSubassemblies: Bool { instances.contains { $0.isSubassembly } }

    init() {}

    init(reply: [String: Any]) {
        assemblyDOF = reply["assemblyDOF"] as? Int ?? 0
        relativeDOF = reply["relativeDOF"] as? Int ?? 0
        globalRigidDOF = reply["globalRigidDOF"] as? Int ?? 0
        assemblyDOFScope = reply["assemblyDOFScope"] as? String ?? "root"
        fullyConstrained = reply["fullyConstrained"] as? Bool ?? false
        // Older services only sent the root-scope verdict as
        // `fullyConstrained`; keep that display behavior when the explicit
        // scope fields are absent.
        rootFullyConstrained = reply["rootFullyConstrained"] as? Bool ?? fullyConstrained
        nestedFullyConstrained = reply["nestedFullyConstrained"] as? Bool ?? true
        dofCredible = reply["dofCredible"] as? Bool ?? true
        solved = reply["solved"] as? Bool ?? true
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
                isSubassembly: row["isSubassembly"] as? Bool ?? false,
                childCount: row["childCount"] as? Int ?? 0,
                parentID: row["parentID"] as? String,
                path: row["path"] as? [String] ?? [],
                depth: row["depth"] as? Int ?? 0,
                referenceID: row["referenceID"] as? String,
                referenceStatus: row["referenceStatus"] as? String,
                referenceMissing: row["referenceMissing"] as? Bool ?? false,
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
            func vector(_ key: String) -> SIMD3<Double>? {
                guard let values = row[key] as? [Double], values.count == 3 else { return nil }
                return SIMD3(values[0], values[1], values[2])
            }
            func revision(_ key: String) -> UInt64? {
                if let value = row[key] as? UInt64 { return value }
                if let value = row[key] as? NSNumber { return value.uint64Value }
                if let value = row[key] as? Int, value >= 0 { return UInt64(value) }
                return nil
            }
            let pointA = vector("pointA") ?? .zero
            let directionA = vector("directionA") ?? SIMD3(0, 0, 1)
            return Constraint(
                id: row["id"] as? String ?? "",
                kind: row["kind"] as? String ?? "",
                instanceA: row["instanceA"] as? String ?? "",
                instanceB: row["instanceB"] as? String,
                value: row["value"] as? Double,
                valueUnit: row["valueUnit"] as? String,
                suppressed: row["suppressed"] as? Bool ?? false,
                valid: row["valid"] as? Bool ?? true,
                conflicting: conflicts.contains(row["id"] as? String ?? ""),
                redundant: row["redundant"] as? Bool ?? false,
                staleReference: row["staleReference"] as? Bool ?? false,
                pointA: pointA,
                directionA: directionA,
                pointB: vector("pointB"),
                directionB: vector("directionB"),
                sourceRevisionA: revision("sourceRevisionA"),
                sourceRevisionB: revision("sourceRevisionB"),
                parentID: row["parentID"] as? String,
                scope: row["scope"] as? String)
        }
        explodedViews = (reply["explodedViews"] as? [[String: Any]] ?? []).map { row in
            let direction = (row["direction"] as? [Double]) ?? [1, 1, 1]
            return ExplodedView(
                id: row["id"] as? String ?? "",
                name: row["name"] as? String ?? "—",
                direction: SIMD3(direction.count == 3 ? direction[0] : 1,
                                 direction.count == 3 ? direction[1] : 1,
                                 direction.count == 3 ? direction[2] : 1),
                distanceMM: row["distanceMM"] as? Double ?? 0,
                entryCount: row["entryCount"] as? Int ?? 0,
                invalidCount: (row["missingInstanceIDs"] as? [String])?.count ?? 0)
        }
        references = (reply["references"] as? [[String: Any]] ?? []).map { row in
            Reference(
                id: row["id"] as? String ?? "",
                name: row["name"] as? String ?? "—",
                status: row["status"] as? String ?? "",
                missing: row["missing"] as? Bool ?? false,
                updateAvailable: row["updateAvailable"] as? Bool ?? false,
                sourceRevision: row["sourceRevision"] as? Int ?? 0,
                sourceSchemaVersion: row["sourceSchemaVersion"] as? Int ?? 0,
                sourceHash: row["sourceContentHash"] as? String ?? "",
                stagedGeometryHash: row["stagedGeometryHash"] as? String ?? "",
                stagedBodyID: row["stagedBodyID"] as? String ?? "",
                sharedCount: row["sharedInstanceCount"] as? Int ?? 0,
                independentCount: row["independentCopyCount"] as? Int ?? 0,
                subassemblyNames: (row["subassemblies"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String },
                cachedGeometry: row["cachedGeometryAvailable"] as? Bool ?? false)
        }
        staleCount = instances.filter(\.stale).count
    }

    var subassemblyCount: Int { instances.filter(\.isSubassembly).count }
    var missingReferenceCount: Int { references.filter(\.missing).count }

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
    @State private var editingPartInfo: CADAssemblyReport.Instance?
    @State private var showConstraintSheet = false
    @State private var editingConstraint: CADAssemblyReport.Constraint?
    @State private var showExplodedSheet = false
    @State private var showInterferenceSheet = false
    @State private var showReferenceAttach = false
    @State private var showReferenceCheck = false
    @State private var showReferenceUpdate = false
    @State private var activeReference: CADAssemblyReport.Reference?
    @State private var showSubassemblyPrompt = false
    @State private var newSubassemblyName = ""

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
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.referencePart",
                                                              "Reference part"),
                                  systemImage: "doc.badge.plus", disabled: busy) {
                    showReferenceAttach = true
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.addSubassembly",
                                                              "New subassembly"),
                                  systemImage: "square.stack.3d.down.right", disabled: busy) {
                    newSubassemblyName = FloeCADStrings.text("cad.workbench.assembly.subassemblyDefault",
                                                             "Subassembly")
                    showSubassemblyPrompt = true
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.addConstraint", "Add constraint"),
                                  systemImage: "link.badge.plus",
                                  disabled: busy || report.instances.isEmpty) {
                    showConstraintSheet = true
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.exploded",
                                                              "Exploded views"),
                                  systemImage: "square.stack.3d.up",
                                  disabled: busy || report.instances.isEmpty) {
                    showExplodedSheet = true
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
                    showInterferenceSheet = true
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
            // The transient exploded preview lives in the document session, so
            // it can also be started by an assistant read and outlives the
            // sheet. This row is the always-reachable way back to the baseline.
            if viewModel.explodedPreview.isActive {
                PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.previewActive",
                                                        "Exploded preview")) {
                    HStack(spacing: 8) {
                        Text(viewModel.explodedPreview.viewName ?? "—")
                            .font(.callout)
                        Spacer(minLength: 4)
                        Button(FloeCADStrings.text("cad.workbench.assembly.resetExploded",
                                                   "Reset preview")) {
                            run { await $0.handleAsync(action: "resetExplodedView", args: [:]) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("CADAssemblyResetExplodedPreview")
                    }
                    Text(FloeCADStrings.text("cad.workbench.assembly.previewTransientHint",
                                             "The viewport is showing this view's offsets. Nothing is saved."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
        .sheet(item: $editingPartInfo) { instance in
            CADPartInfoSheet(
                document: document,
                instance: instance,
                busy: $busy,
                onApplied: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true { refresh() }
                })
        }
        .sheet(isPresented: $showExplodedSheet) {
            CADExplodedViewsSheet(document: document, report: report,
                                  preview: viewModel.explodedPreview,
                                  busy: $busy,
                                  onChanged: { reply in
                                      outcome = reply
                                      if reply["mutated"] as? Bool == true { refresh() }
                                  })
        }
        .sheet(isPresented: $showInterferenceSheet) {
            CADAssemblyInterferenceSheet(
                document: document,
                report: report,
                initialSelection: viewModel.selectedAssemblyInstances,
                busy: $busy,
                onFinished: { reply in
                    outcome = reply
                })
        }
        .sheet(isPresented: $showConstraintSheet) {
            CADConstraintEditorSheet(
                document: document,
                report: report,
                busy: $busy,
                onSaved: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true { refresh() }
                })
        }
        .sheet(item: $editingConstraint) { constraint in
            CADConstraintEditorSheet(
                document: document,
                report: report,
                busy: $busy,
                editing: constraint,
                onSaved: { reply in
                    outcome = reply
                    if reply["ok"] as? Bool == true { refresh() }
                })
        }
        .fileImporter(isPresented: $showReferenceAttach,
                      allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: false) { result in
            handleReferenceFile(result, action: .attach)
        }
        .fileImporter(isPresented: $showReferenceCheck,
                      allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: false) { result in
            guard let reference = activeReference else { return }
            handleReferenceFile(result, action: .check(reference))
        }
        .fileImporter(isPresented: $showReferenceUpdate,
                      allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: false) { result in
            guard let reference = activeReference else { return }
            handleReferenceFile(result, action: .update(reference))
        }
        .alert(FloeCADStrings.text("cad.workbench.assembly.newSubassemblyTitle", "New subassembly"),
               isPresented: $showSubassemblyPrompt) {
            TextField(FloeCADStrings.text("cad.workbench.assembly.subassemblyName",
                                          "Subassembly name"), text: $newSubassemblyName)
            Button(FloeCADStrings.text("cad.workbench.assembly.cancel", "Cancel"), role: .cancel) {}
            Button(FloeCADStrings.text("cad.workbench.assembly.create", "Create")) {
                createSubassembly()
            }
        } message: {
            Text(FloeCADStrings.text("cad.workbench.assembly.newSubassemblyHint",
                                     "Place parts inside it afterwards; the subassembly keeps its own local mates."))
        }
    }

    private enum ReferenceFileAction {
        case attach
        case check(CADAssemblyReport.Reference)
        case update(CADAssemblyReport.Reference)
    }

    private func handleReferenceFile(_ result: Result<[URL], Error>,
                                     action: ReferenceFileAction) {
        switch result {
        case .failure(let error):
            outcome = ["ok": false, "error": "file_unavailable",
                       "message": error.localizedDescription]
        case .success(let urls):
            guard let url = urls.first else { return }
            switch action {
            case .attach:
                run { _ in
                    await CADAssemblyReferenceBridge().attach(sourceURL: url, to: document)
                }
            case .check(let reference):
                guard let id = UUID(uuidString: reference.id) else { return }
                run { _ in
                    await CADAssemblyReferenceBridge().check(referenceID: id,
                                                             sourceURL: url,
                                                             in: document)
                }
            case .update(let reference):
                guard let id = UUID(uuidString: reference.id) else { return }
                run { _ in
                    await CADAssemblyReferenceBridge().update(
                        referenceID: id,
                        sourceURL: url,
                        in: document,
                        expectedSourceContentHash: reference.sourceHash,
                        expectedStagedGeometryHash: reference.stagedGeometryHash)
                }
            }
        }
    }

    private func createSubassembly() {
        let name = newSubassemblyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { service in
            await service.handleAsync(action: "addSubassembly", args: ["name": name])
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
                                if instance.isSubassembly {
                                    PanelBadge(text: FloeCADStrings.format(
                                        "cad.workbench.assembly.childCount", "%@ parts", instance.childCount))
                                }
                                if instance.independentCopy {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.copy", "copy"))
                                }
                                if instance.referenceMissing {
                                    PanelBadge(text: FloeCADStrings.text(
                                        "cad.workbench.assembly.referenceMissing", "source missing"),
                                               tint: .orange)
                                } else if instance.referenceStatus == "updateAvailable" {
                                    PanelBadge(text: FloeCADStrings.text(
                                        "cad.workbench.assembly.referenceUpdate", "update available"),
                                               tint: .blue)
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
                        HStack(spacing: 8) {
                            panelHitTarget(Button(FloeCADStrings.label(
                                "cad.workbench.assembly.editInstance", "Edit transform")) {
                                editingInstance = instance
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small))
                            .accessibilityIdentifier("CADAssemblyInstanceEdit-\(instance.id)")
                            if !instance.isSubassembly {
                                panelHitTarget(Button(FloeCADStrings.label(
                                    "cad.workbench.assembly.partInfo", "Part info")) {
                                    editingPartInfo = instance
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                .accessibilityIdentifier("CADAssemblyInstancePart-\(instance.id)")
                            }
                        }
                    }
                    .padding(.leading, CGFloat(instance.depth) * 12)
                    .padding(.vertical, 2)
                    // A container identifier is inherited by every nested
                    // button on iPadOS. Keep the distinct select/edit/part
                    // identifiers on the actual controls instead.
                    .contextMenu {
                        Button(FloeCADStrings.label("cad.workbench.assembly.selectInstance", "Select in viewport")) {
                            select(instance)
                        }
                        Button(FloeCADStrings.label("cad.workbench.assembly.editInstance", "Edit transform")) {
                            editingInstance = instance
                        }
                        if !instance.isSubassembly {
                            Button(FloeCADStrings.label("cad.workbench.assembly.partInfo", "Part info")) {
                                editingPartInfo = instance
                            }
                        }
                        Button(instance.hidden
                               ? FloeCADStrings.text("cad.workbench.assembly.show", "Show")
                               : FloeCADStrings.text("cad.workbench.assembly.hide", "Hide")) {
                            setVisible(instance, hidden: !instance.hidden)
                        }
                        if !instance.isSubassembly && !instance.independentCopy {
                            Button(FloeCADStrings.text("cad.workbench.assembly.makeIndependent",
                                                       "Make independent")) {
                                makeIndependent(instance)
                            }
                        }
                        if !availableParents(for: instance).isEmpty {
                            Menu(FloeCADStrings.text("cad.workbench.assembly.moveInto",
                                                     "Move into subassembly")) {
                                ForEach(availableParents(for: instance), id: \.id) { parent in
                                    Button(parent.name) {
                                        moveInstance(instance, parentID: parent.id)
                                    }
                                }
                            }
                        }
                        if instance.parentID != nil {
                            Button(FloeCADStrings.text("cad.workbench.assembly.moveToTop",
                                                       "Move to top level")) {
                                moveToTopLevel(instance)
                            }
                        }
                        Button(role: .destructive) {
                            removeInstance(instance)
                        } label: {
                            Text(FloeCADStrings.text("cad.workbench.assembly.delete", "Delete instance"))
                        }
                    }
                }
            }

            if !report.references.isEmpty {
                PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.references",
                                                        "External parts")) {
                    ForEach(report.references) { reference in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(reference.name)
                                    .font(.callout)
                                Spacer(minLength: 4)
                                if reference.missing {
                                    PanelBadge(text: FloeCADStrings.text(
                                        "cad.workbench.assembly.referenceMissing", "source missing"),
                                               tint: .orange)
                                } else if reference.updateAvailable {
                                    PanelBadge(text: FloeCADStrings.text(
                                        "cad.workbench.assembly.referenceUpdate", "update available"),
                                               tint: .blue)
                                }
                                PanelBadge(text: FloeCADStrings.format(
                                    "cad.workbench.assembly.referenceShares", "%@ shared",
                                    reference.sharedCount))
                                if reference.independentCount > 0 {
                                    PanelBadge(text: FloeCADStrings.format(
                                        "cad.workbench.assembly.referenceCopies", "%@ copies",
                                        reference.independentCount))
                                }
                            }
                            Text(FloeCADStrings.format(
                                "cad.workbench.assembly.referenceVersion",
                                "rev %@ · schema %@ · %@",
                                reference.sourceRevision,
                                reference.sourceSchemaVersion,
                                String(reference.sourceHash.prefix(8))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !reference.subassemblyNames.isEmpty {
                                Text(FloeCADStrings.text(
                                    "cad.workbench.assembly.referenceInSubassemblies",
                                    "Used in: ") + reference.subassemblyNames.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if reference.missing {
                                Text(FloeCADStrings.text(
                                    "cad.workbench.assembly.referenceCachedHint",
                                    "The cached geometry, mates and BOM row are preserved. "
                                    + "Check or update with the source document to recover."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button(FloeCADStrings.label(
                                    "cad.workbench.assembly.referenceCheck", "Check source")) {
                                    activeReference = reference
                                    showReferenceCheck = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(FloeCADStrings.label(
                                    "cad.workbench.assembly.referenceUpdateApply", "Update source")) {
                                    activeReference = reference
                                    showReferenceUpdate = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(FloeCADStrings.label(
                                    "cad.workbench.assembly.placePartReference", "Place reference")) {
                                    placeSharedReference(reference)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("CADAssemblyReference-\(reference.id)")
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
                                    let unit = constraint.kind == "angle" ? "°" : " mm"
                                    Text("· \(Self.valueFormatter.string(from: NSNumber(value: value)) ?? "\(value)")\(unit)")
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
                                if constraint.staleReference {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.staleReference",
                                                                         "re-pick reference"),
                                               tint: .orange)
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
                                if canEditConstraint(constraint) {
                                    panelHitTarget(Button {
                                        editingConstraint = constraint
                                    } label: {
                                        Text(FloeCADStrings.text("cad.workbench.assembly.editConstraint", "Edit"))
                                    }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("CADAssemblyConstraintEdit-\(constraint.id)"))
                                }
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
                    // The count is a ROOT-scope diagnostic (each subassembly
                    // container counts as one rigid body); label it as such
                    // whenever nested scopes exist so it is never read as a
                    // whole-assembly total.
                    if report.hasSubassemblies {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofRootScope",
                                                               "%@ top-level DOF", report.assemblyDOF),
                                   tint: report.rootFullyConstrained ? .green : .blue)
                    } else {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofTotal", "%@ DOF total", report.assemblyDOF),
                                   tint: report.fullyConstrained ? .green : .blue)
                    }
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
                    } else if report.rootFullyConstrained, report.hasSubassemblies,
                              report.solved, report.dofCredible {
                        // The root scope cannot move but children inside a
                        // subassembly still can; say that instead of implying
                        // the whole assembly is locked.
                        PanelBadge(text: FloeCADStrings.text("cad.workbench.assembly.internalMotionRemains",
                                                             "Parts can still move"),
                                   tint: .orange)
                    }
                    if !report.solved || !report.dofCredible {
                        PanelBadge(text: FloeCADStrings.text("cad.workbench.assembly.dofUnavailable",
                                                             "Freedom unverified"),
                                   tint: .red)
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

    private func canEditConstraint(_ constraint: CADAssemblyReport.Constraint) -> Bool {
        if constraint.kind == "distance" || constraint.kind == "angle" { return true }
        guard constraint.kind == "coaxial" || constraint.kind == "planarAlign" else { return false }
        return report.instances.contains { instance in
            !instance.isSubassembly
                && (instance.id == constraint.instanceA || instance.id == constraint.instanceB)
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

    private func makeIndependent(_ instance: CADAssemblyReport.Instance) {
        run { await $0.handleAsync(action: "makeIndependent", args: ["id": instance.id]) }
    }

    private func moveToTopLevel(_ instance: CADAssemblyReport.Instance) {
        run { await $0.handleAsync(action: "moveInstance",
                                   args: ["id": instance.id, "parentID": NSNull()]) }
    }

    private func placeSharedReference(_ reference: CADAssemblyReport.Reference) {
        run { await $0.handleAsync(action: "placePartReference",
                                   args: ["referenceID": reference.id]) }
    }

    private func moveInstance(_ instance: CADAssemblyReport.Instance, parentID: String) {
        run { await $0.handleAsync(action: "moveInstance",
                                   args: ["id": instance.id, "parentID": parentID]) }
    }

    private func availableParents(for instance: CADAssemblyReport.Instance)
        -> [CADAssemblyReport.Instance] {
        report.instances.filter { candidate in
            guard candidate.isSubassembly, candidate.id != instance.id else { return false }
            return !candidate.path.contains(instance.id)
        }
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

// MARK: - Interference sheet

/// One compact selected-instance inspector: choose the subset (a selected
/// subassembly expands to its drawable parts), run the same
/// `CADAssemblyService` operation the typed tool uses, watch the service-owned
/// pair progress, cancel it, and read the actual exact/mesh result.
private struct CADAssemblyInterferenceSheet: View {
    let document: FloeCADDocument
    let report: CADAssemblyReport
    let initialSelection: Set<UUID>
    @Binding var busy: Bool
    let onFinished: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var initialized = false
    @State private var toleranceText = "0.000001"
    @State private var volumeToleranceText = "0"
    @State private var visibleRowLimits: [String: Int] = [:]
    @State private var service: CADAssemblyService?
    @State private var isRunning = false
    @State private var progress: [String: Any] = [:]
    @State private var result: [String: Any] = [:]
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    private var leaves: [CADAssemblyReport.Instance] {
        report.instances.filter { !$0.isSubassembly }
    }

    private var selectedLeaves: [CADAssemblyReport.Instance] {
        leaves.filter { selectedIDs.contains($0.id) }
    }

    private var pairCount: Int {
        let count = selectedLeaves.count
        return count * (count - 1) / 2
    }

    private var parsedTolerance: Double? {
        Double(toleranceText.replacingOccurrences(of: ",", with: "."))
    }

    private var parsedVolumeTolerance: Double? {
        Double(volumeToleranceText.replacingOccurrences(of: ",", with: "."))
    }

    /// Local page size for one result section. The sheet renders only this
    /// many rows at a time from the already-retained service result; it never
    /// re-runs the kernel to read a later page.
    private var rowPageSize: Int { 40 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if report.instances.isEmpty {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.noInstances",
                            "No assembly instances are available to inspect."))
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.instances) { instance in
                            Toggle(isOn: selectionBinding(for: instance)) {
                                HStack(spacing: 6) {
                                    Text(instance.name)
                                    if instance.isSubassembly {
                                        PanelBadge(text: FloeCADStrings.format(
                                            "cad.workbench.assembly.childCount", "%@ parts",
                                            instance.childCount))
                                    }
                                }
                            }
                            .padding(.leading, CGFloat(instance.depth) * 10)
                            .disabled(isRunning)
                            .accessibilityIdentifier("CADAssemblyInterferenceSelection-\(instance.id)")
                        }
                    }
                } header: {
                    Text(FloeCADStrings.text(
                        "cad.workbench.assembly.interference.select",
                        "Instances to inspect"))
                } footer: {
                    Text(FloeCADStrings.format(
                        pairCount == 1
                            ? "cad.workbench.assembly.interference.selectionSummary.one"
                            : "cad.workbench.assembly.interference.selectionSummary",
                        pairCount == 1 ? "%@ selected · %@ pair" : "%@ selected · %@ pairs",
                        selectedLeaves.count, pairCount))
                    .accessibilityIdentifier("CADAssemblyInterferencePairCount")
                }

                Section {
                    HStack {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.tolerance", "Contact tolerance"))
                        Spacer(minLength: 8)
                        TextField("0.000001", text: $toleranceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                            .disabled(isRunning)
                            .accessibilityIdentifier("CADAssemblyInterferenceTolerance")
                        Text("mm").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.volumeTolerance",
                            "Volume threshold"))
                        Spacer(minLength: 8)
                        TextField("0", text: $volumeToleranceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                            .disabled(isRunning)
                            .accessibilityIdentifier("CADAssemblyInterferenceVolumeTolerance")
                        Text("mm³").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.workbench.assembly.interference.toleranceHint",
                        "Surfaces within this distance count as touching. The volume threshold "
                            + "flags small overlaps without hiding them."))
                }

                if isRunning || !progress.isEmpty {
                    Section {
                        ProgressView(value: progressFraction)
                            .accessibilityIdentifier("CADAssemblyInterferenceProgress")
                        HStack {
                            Text(progressPairText)
                                .font(.callout)
                            Spacer(minLength: 8)
                            if isRunning {
                                Button(role: .destructive) {
                                    _ = service?.cancelInterference()
                                } label: {
                                    Text(FloeCADStrings.text(
                                        "cad.workbench.assembly.interference.cancelRun",
                                        "Cancel check"))
                                }
                                .accessibilityIdentifier("CADAssemblyInterferenceCancel")
                            }
                        }
                        HStack(spacing: 6) {
                            PanelBadge(text: FloeCADStrings.format(
                                "cad.workbench.assembly.interference.countInterfering",
                                "%@ interfering", int(progress["interferingPairCount"])),
                                tint: .red)
                            PanelBadge(text: FloeCADStrings.format(
                                "cad.workbench.assembly.interference.countContacts",
                                "%@ contacts", int(progress["contactPairCount"])),
                                tint: .orange)
                            PanelBadge(text: FloeCADStrings.format(
                                "cad.workbench.assembly.interference.countClearances",
                                "%@ clearances", int(progress["separatedPairCount"])),
                                tint: .blue)
                            PanelBadge(text: FloeCADStrings.format(
                                "cad.workbench.assembly.interference.countUnresolved",
                                "%@ unresolved", int(progress["unresolvedPairCount"])))
                        }
                        if let phase = progress["phase"] as? String {
                            Text(phaseLabel(phase))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.progress", "Progress"))
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("CADAssemblyInterferenceError")
                    }
                }

                resultSections

                Section {
                    Button {
                        start()
                    } label: {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.start", "Run check"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || selectedLeaves.count < 2
                              || parsedTolerance == nil || parsedVolumeTolerance == nil)
                    .accessibilityIdentifier("CADAssemblyInterferenceStart")
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.workbench.assembly.interference.basis",
                        "Mesh measurements are approximate."))
                }
            }
            .navigationTitle(FloeCADStrings.text(
                "cad.workbench.assembly.interference.title", "Interference check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if service == nil { service = CADAssemblyService(document: document) }
            initializeSelection()
        }
        .onDisappear {
            pollTask?.cancel()
            if isRunning { _ = service?.cancelInterference() }
        }
    }

    // MARK: Selection

    private func initializeSelection() {
        guard !initialized else { return }
        initialized = true
        let valid = Set(leaves.map(\.id))
        var seed = Set<String>()
        for id in initialSelection.map(\.uuidString) {
            guard let instance = report.instances.first(where: { $0.id == id }) else { continue }
            if instance.isSubassembly {
                seed.formUnion(leafDescendants(of: instance.id))
            } else if valid.contains(id) {
                seed.insert(id)
            }
        }
        selectedIDs = seed.intersection(valid)
        if selectedIDs.isEmpty && initialSelection.isEmpty {
            selectedIDs = valid
        }
    }

    private func leafDescendants(of instanceID: String) -> Set<String> {
        Set(leaves.filter { $0.path.contains(instanceID) }.map(\.id))
    }

    private func selectionBinding(for instance: CADAssemblyReport.Instance) -> Binding<Bool> {
        Binding(
            get: {
                if instance.isSubassembly {
                    let descendants = leafDescendants(of: instance.id)
                    return !descendants.isEmpty && descendants.isSubset(of: selectedIDs)
                }
                return selectedIDs.contains(instance.id)
            },
            set: { isOn in
                if instance.isSubassembly {
                    let descendants = leafDescendants(of: instance.id)
                    if isOn {
                        selectedIDs.formUnion(descendants)
                    } else {
                        selectedIDs.subtract(descendants)
                    }
                } else if isOn {
                    selectedIDs.insert(instance.id)
                } else {
                    selectedIDs.remove(instance.id)
                }
            })
    }

    // MARK: Run

    private func start() {
        guard let service else { return }
        guard let tolerance = parsedTolerance, tolerance.isFinite, tolerance >= 0 else {
            errorText = FloeCADStrings.text(
                "cad.workbench.assembly.interference.badTolerance",
                "Enter a finite, non-negative contact tolerance in millimetres.")
            return
        }
        guard let volumeTolerance = parsedVolumeTolerance,
              volumeTolerance.isFinite, volumeTolerance >= 0 else {
            errorText = FloeCADStrings.text(
                "cad.workbench.assembly.interference.badVolumeTolerance",
                "Enter a finite, non-negative exact-common volume threshold in cubic millimetres.")
            return
        }
        let ids = selectedLeaves.map(\.id)
        guard ids.count >= 2 else {
            errorText = FloeCADStrings.text(
                "cad.workbench.assembly.interference.needTwo",
                "Select at least two drawable instances.")
            return
        }
        visibleRowLimits = [:]
        result = [:]
        progress = [:]
        errorText = nil
        isRunning = true
        busy = true
        let args: [String: Any] = [
            "instanceIDs": ids,
            "toleranceMM": tolerance,
            "volumeToleranceMM3": volumeTolerance,
        ]
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let current = service.interferenceProgress() {
                    progress = current
                }
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        Task { @MainActor in
            let reply = await service.handleAsync(action: "interference", args: args)
            if let current = service.interferenceProgress() {
                progress = current
            } else if let current = reply["progress"] as? [String: Any] {
                progress = current
            }
            result = reply
            if reply["ok"] as? Bool != true {
                errorText = failureMessage(reply)
            }
            isRunning = false
            busy = false
            pollTask?.cancel()
            onFinished(reply)
        }
    }

    // MARK: Progress and results

    private func failureMessage(_ reply: [String: Any]) -> String {
        switch reply["error"] as? String {
        case "cancelled":
            return FloeCADStrings.text("cad.workbench.assembly.interference.cancelled", "Check cancelled.")
        case "closed":
            return FloeCADStrings.text("cad.workbench.assembly.interference.closed", "The document is closed.")
        case "stale":
            return FloeCADStrings.text("cad.workbench.assembly.interference.stale", "The assembly changed. Run the check again.")
        case "result_too_large":
            return FloeCADStrings.text("cad.workbench.assembly.interference.tooLarge", "There are too many results. Select fewer instances and try again.")
        default:
            return reply["message"] as? String
                ?? FloeCADStrings.text("cad.workbench.assembly.interference.failed", "The interference check did not complete.")
        }
    }

    private var progressFraction: Double {
        if let fraction = double(progress["fraction"]) { return min(1, max(0, fraction)) }
        let total = int(progress["requestedPairCount"])
        let processed = int(progress["processedPairCount"])
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    private var progressPairText: String {
        let processed = int(progress["processedPairCount"])
        let total = int(progress["requestedPairCount"])
        return FloeCADStrings.format(
            "cad.workbench.assembly.interference.pairProgress",
            "%@ / %@ pairs", processed, total)
    }

    /// One actual result count with stable native label/value semantics for
    /// VoiceOver and UI acceptance. The visual row stays the system
    /// LabeledContent used by the rest of this inspector.
    private func resultValueRow(
        key: String, fallback: String, value: String, identifier: String
    ) -> some View {
        let label = FloeCADStrings.text(key, fallback)
        return LabeledContent(label) {
            Text(value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var resultSections: some View {
        if result["ok"] as? Bool == true {
            Section {
                resultValueRow(
                    key: "cad.workbench.assembly.interference.resultPairs",
                    fallback: "Pairs checked",
                    value: "\(int(result["processedPairCount"])) / \(int(result["requestedPairCount"]))",
                    identifier: "CADAssemblyInterferenceResultPairs")
                resultValueRow(
                    key: "cad.workbench.assembly.interference.resultInterfering",
                    fallback: "Interfering",
                    value: "\(int(result["interferingPairCount"]))",
                    identifier: "CADAssemblyInterferenceResultInterfering")
                resultValueRow(
                    key: "cad.workbench.assembly.interference.resultContacts",
                    fallback: "Contacts",
                    value: "\(int(result["contactPairCount"]))",
                    identifier: "CADAssemblyInterferenceResultContacts")
                resultValueRow(
                    key: "cad.workbench.assembly.interference.resultClearances",
                    fallback: "Clearances",
                    value: "\(int(result["separatedPairCount"]))",
                    identifier: "CADAssemblyInterferenceResultClearances")
                resultValueRow(
                    key: "cad.workbench.assembly.interference.resultUnresolved",
                    fallback: "Unresolved",
                    value: "\(int(result["unresolvedPairCount"]))",
                    identifier: "CADAssemblyInterferenceResultUnresolved")
                DisclosureGroup(FloeCADStrings.text(
                    "cad.workbench.assembly.interference.details", "Check details")) {
                    LabeledContent(FloeCADStrings.text(
                        "cad.workbench.assembly.interference.detailRows", "Detail rows"),
                                   value: "\(int(result["detailRowCount"]))")
                    LabeledContent(FloeCADStrings.text(
                        "cad.workbench.assembly.interference.resultEnvelope", "Result size"),
                                   value: "\(int(result["resultBytes"] ?? result["detailBytes"])) / \(int(result["resultBudgetBytes"])) B")
                    if let basis = (result["precision"] as? [String: Any])?["basis"] as? String {
                        Text(basis)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(FloeCADStrings.text(
                    "cad.workbench.assembly.interference.results", "Result"))
                    .accessibilityIdentifier("CADAssemblyInterferenceResult")
            }

            entrySection(
                key: "interferences",
                title: FloeCADStrings.text(
                    "cad.workbench.assembly.interference.interferences", "Interferences"),
                tint: .red)
            entrySection(
                key: "contacts",
                title: FloeCADStrings.text(
                    "cad.workbench.assembly.interference.contacts", "Contacts"),
                tint: .orange)
            entrySection(
                key: "clearances",
                title: FloeCADStrings.text(
                    "cad.workbench.assembly.interference.clearances", "Clearances"),
                tint: .blue)
            entrySection(
                key: "unresolvedPairs",
                title: FloeCADStrings.text(
                    "cad.workbench.assembly.interference.unresolved", "Unresolved"),
                tint: .gray)
        }
    }

    @ViewBuilder
    private func entrySection(key: String, title: String, tint: Color) -> some View {
        let rows = result[key] as? [[String: Any]] ?? []
        let shown = min(rows.count, visibleRowLimits[key] ?? rowPageSize)
        if !rows.isEmpty {
            Section {
                ForEach(Array(rows.prefix(shown).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(name(row["a"] as? String)) ↔ \(name(row["b"] as? String))")
                                .font(.callout)
                            Spacer(minLength: 4)
                            PanelBadge(text: classificationLabel(row["classification"] as? String ?? ""),
                                       tint: tint)
                        }
                        let detail = entryDetail(row)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if rows.count > shown {
                    Button {
                        visibleRowLimits[key] = min(rows.count, shown + rowPageSize)
                    } label: {
                        Text(FloeCADStrings.text(
                            "cad.workbench.assembly.interference.showMoreRows", "Show more rows"))
                    }
                    .accessibilityIdentifier("CADAssemblyInterferenceMore-\(key)")
                }
                Text(FloeCADStrings.format(
                    "cad.workbench.assembly.interference.rowsShown",
                    "%@ of %@ rows shown", shown, rows.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(title)
            }
        }
    }

    private func entryDetail(_ row: [String: Any]) -> String {
        var parts: [String] = []
        let volume = double(row["volumeMM3"])
        if let volume, volume > 0 {
            parts.append(String(format: "%.6g mm³", volume))
            if row["volumeBelowThreshold"] as? Bool == true {
                parts.append(FloeCADStrings.text(
                    "cad.workbench.assembly.interference.belowVolumeThreshold",
                    "below volume threshold"))
            }
        } else if let distance = double(row["minimumDistanceMM"]) {
            parts.append(String(format: "%.6g mm", distance))
        } else if let gap = double(row["aabbGapMM"]) {
            parts.append(String(format: "AABB gap %.6g mm", gap))
        }
        if let precision = double(row["precisionMM"]) {
            parts.append(String(format: "± %.3g mm", precision))
        }
        if let containment = row["containment"] as? String,
           containment != "none", containment != "none_disjointBounds" {
            parts.append(containmentLabel(containment))
        }
        if let reason = row["unresolvedReason"] as? String {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    private func name(_ id: String?) -> String {
        guard let id else { return "—" }
        return report.instances.first { $0.id == id }?.name
            ?? FloeCADStrings.text(
                "cad.workbench.assembly.interference.unknownInstance", "Unknown instance")
    }

    private func classificationLabel(_ classification: String) -> String {
        switch classification {
        case "penetrating":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.penetrating", "Penetrating")
        case "contact":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.contact", "Contact")
        case "separated":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.separated", "Separated")
        default:
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.unresolvedBadge", "Unresolved")
        }
    }

    private func containmentLabel(_ containment: String) -> String {
        switch containment {
        case "bInsideA":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.bInsideA", "B inside A material")
        case "aInsideB":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.aInsideB", "A inside B material")
        case "surfaceCrossing":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.surfaceCrossing", "Surfaces cross")
        case "notEvaluatedOpenMesh":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.openMesh",
                "Open mesh; containment not claimed")
        case "indeterminate":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.indeterminate",
                "Containment indeterminate")
        default:
            return ""
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "preparing":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phasePreparing", "Preparing")
        case "checking":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseChecking", "Checking")
        case "cancelling":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseCancelling", "Cancelling")
        case "cancelled":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseCancelled", "Cancelled")
        case "stale":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseStale", "Document changed")
        case "result_too_large":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseTooLarge", "Result too large")
        case "completed":
            return FloeCADStrings.text(
                "cad.workbench.assembly.interference.phaseCompleted", "Completed")
        default:
            return phase
        }
    }

    private func int(_ raw: Any?) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return 0
    }

    private func double(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
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

    private var bodies: [CADPanelBodyOption] {
        // Staged external-reference bodies are internal definitions; they are
        // placed only through `placePartReference`, never as an ordinary body.
        let staged = Set((try? CADAssembly.decode(from: document.session.document.assemblyData))?
            .partReferences.map(\.stagedBodyID) ?? [])
        return document.panelBodyOptions.filter { !staged.contains($0.id) }
    }

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

/// Engineering part record for one definition. Shared instances all read the
/// same record; an explicit independent copy reads and writes its own. The
/// fields are plain text with natural iPad control sizes; the version is an
/// explicit label, never inferred from geometry or the App version.
private struct CADPartInfoSheet: View {
    let document: FloeCADDocument
    let instance: CADAssemblyReport.Instance
    @Binding var busy: Bool
    let onApplied: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var partNumber = ""
    @State private var material = ""
    @State private var version = ""
    @State private var canApply = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text("cad.workbench.assembly.partInfo", "Part info")) {
                    TextField(FloeCADStrings.text("cad.workbench.assembly.partNumber",
                                                  "Part number"), text: $partNumber)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("CADPartNumber")
                    TextField(FloeCADStrings.text("cad.workbench.assembly.partMaterial",
                                                  "Material"), text: $material)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("CADPartMaterial")
                    TextField(FloeCADStrings.text("cad.workbench.assembly.partVersion",
                                                  "Version"), text: $version)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("CADPartVersion")
                }
                Section {
                    Text(instance.independentCopy
                         ? FloeCADStrings.text(
                            "cad.workbench.assembly.partInfoIndependentHint",
                            "This independent copy has its own part record; changes do not affect the shared source.")
                         : FloeCADStrings.text(
                            "cad.workbench.assembly.partInfoSharedHint",
                            "Every shared instance of this part uses this part number, engineering material and version; an independent copy keeps its own record."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Section { Text(errorText).font(.callout).foregroundStyle(.red) }
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
                        .disabled(!canApply || busy)
                        .accessibilityIdentifier("CADPartInfoApply")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { load() }
    }

    private func load() {
        let reply = CADAssemblyService(document: document)
            .handle(action: "partMetadata", args: ["instanceID": instance.id])
        guard reply["ok"] as? Bool == true,
              let row = (reply["parts"] as? [[String: Any]])?.first else {
            errorText = reply["message"] as? String
                ?? FloeCADStrings.text("cad.workbench.assembly.partInfoLoadFailed",
                                        "The part record could not be read.")
            return
        }
        partNumber = row["partNumber"] as? String ?? ""
        material = row["material"] as? String ?? ""
        version = row["version"] as? String ?? ""
        canApply = true
    }

    private func apply() {
        guard canApply, !busy else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = service.handle(action: "setPartMetadata", args: [
                "instanceID": instance.id,
                "partNumber": partNumber,
                "material": material,
                "version": version,
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

struct CADAssemblyReferenceDraft {
    var point: SIMD3<Double>
    var direction: SIMD3<Double>
    var source: String
    var label: String
    var sourceRevision: UInt64?
    var fence: [String: Any]?

    init?(reply: [String: Any], label: String) {
        guard reply["ok"] as? Bool == true,
              let point = reply["point"] as? [Double], point.count == 3,
              let direction = reply["direction"] as? [Double], direction.count == 3 else {
            return nil
        }
        self.point = SIMD3(point[0], point[1], point[2])
        self.direction = SIMD3(direction[0], direction[1], direction[2])
        self.source = reply["source"] as? String ?? "reference"
        self.label = label
        if let revision = reply["source_revision"] as? NSNumber {
            self.sourceRevision = revision.uint64Value
        } else if let revision = reply["source_revision"] as? UInt64 {
            self.sourceRevision = revision
        } else {
            self.sourceRevision = nil
        }
        self.fence = reply["fence"] as? [String: Any]
    }

    var payload: [String: Any] {
        var object: [String: Any] = [
            "point": [point.x, point.y, point.z],
            "direction": [direction.x, direction.y, direction.z],
            "source": source,
        ]
        if let sourceRevision { object["source_revision"] = sourceRevision }
        if let fence { object["fence"] = fence }
        return object
    }

    var summary: String {
        let pointText = String(format: "(%.2f, %.2f, %.2f)", point.x, point.y, point.z)
        return "\(label) · \(source) · \(pointText)"
    }
}

struct CADReferencePickerRequest: Identifiable {
    let id = UUID()
    let instanceID: String
    let instanceName: String
    let side: String
}

private struct CADConstraintEditorSheet: View {
    let document: FloeCADDocument
    let report: CADAssemblyReport
    @Binding var busy: Bool
    let editing: CADAssemblyReport.Constraint?
    let onSaved: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var instanceA: String?
    @State private var instanceB: String?
    @State private var axisA: CADPanelAxisPreset = .zPlus
    @State private var axisB: CADPanelAxisPreset = .zPlus
    @State private var pointAX: String
    @State private var pointAY: String
    @State private var pointAZ: String
    @State private var pointBX: String
    @State private var pointBY: String
    @State private var pointBZ: String
    @State private var value: String
    @State private var referenceA: CADAssemblyReferenceDraft?
    @State private var referenceB: CADAssemblyReferenceDraft?
    @State private var pickerRequest: CADReferencePickerRequest?
    @State private var captureMessage: String?
    @State private var errorText: String?

    init(document: FloeCADDocument,
         report: CADAssemblyReport,
         busy: Binding<Bool>,
         editing: CADAssemblyReport.Constraint? = nil,
         onSaved: @escaping ([String: Any]) -> Void) {
        self.document = document
        self.report = report
        self._busy = busy
        self.editing = editing
        self.onSaved = onSaved
        _kind = State(initialValue: editing?.kind ?? "fixed")
        _instanceA = State(initialValue: editing?.instanceA ?? report.instances.first?.id)
        _instanceB = State(initialValue: editing?.instanceB)
        _value = State(initialValue: Self.numberString(editing?.value ?? 0))
        _pointAX = State(initialValue: Self.numberString(editing?.pointA.x ?? 0))
        _pointAY = State(initialValue: Self.numberString(editing?.pointA.y ?? 0))
        _pointAZ = State(initialValue: Self.numberString(editing?.pointA.z ?? 0))
        _pointBX = State(initialValue: Self.numberString(editing?.pointB?.x ?? 0))
        _pointBY = State(initialValue: Self.numberString(editing?.pointB?.y ?? 0))
        _pointBZ = State(initialValue: Self.numberString(editing?.pointB?.z ?? 0))
    }

    private static func numberString(_ value: Double) -> String {
        String(format: "%.15g", value)
    }

    private static func vectorString(_ vector: SIMD3<Double>) -> String {
        String(format: "(%.3f, %.3f, %.3f)", vector.x, vector.y, vector.z)
    }

    private var isEditing: Bool { editing != nil }
    private var kindLabel: String { localizedConstraintKind(kind) }
    private var needsB: Bool { kind != "fixed" }
    private var usesAxis: Bool { kind == "coaxial" || kind == "planarAlign" || kind == "angle" }
    private var usesValue: Bool { kind == "distance" || kind == "angle" }
    private var usesPoints: Bool { kind == "distance" || kind == "coaxial" || kind == "planarAlign" }
    private var effectiveInstanceA: String? { instanceA }
    private var effectiveInstanceB: String? { needsB ? instanceB : nil }

    private var canAdd: Bool {
        guard !busy, instanceA != nil else { return false }
        if needsB, instanceB == nil || instanceB == instanceA { return false }
        if usesValue {
            guard let number = Double(value), number.isFinite else { return false }
            if kind == "distance", number < 0 { return false }
            if kind == "angle", number < 0 || number > 180 { return false }
        }
        if !isEditing, usesPoints {
            if referenceA == nil, useNumericPointsA {
                for text in [pointAX, pointAY, pointAZ] where Double(text) == nil { return false }
            }
            if needsB, referenceB == nil, useNumericPointsB {
                for text in [pointBX, pointBY, pointBZ] where Double(text) == nil { return false }
            }
        }
        return true
    }

    private var useNumericPointsA: Bool { referenceA == nil }
    private var useNumericPointsB: Bool { referenceB == nil }

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
                    .disabled(isEditing)
                    .accessibilityIdentifier("CADConstraintKind")
                    Picker(FloeCADStrings.text("cad.workbench.assembly.instanceA", "Instance A"),
                           selection: $instanceA) {
                        Text(FloeCADStrings.text("cad.workbench.assembly.pickInstance", "Select…"))
                            .tag(String?.none)
                        ForEach(report.instances) { instance in
                            Text(instance.name).tag(String?.some(instance.id))
                        }
                    }
                    .disabled(isEditing)
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
                        .disabled(isEditing)
                        .accessibilityIdentifier("CADConstraintInstanceB")
                    }
                }

                if kind != "fixed", let instanceA {
                    referenceSection(side: "A", instanceID: instanceA)
                }
                if kind != "fixed", needsB, let instanceB {
                    referenceSection(side: "B", instanceID: instanceB)
                }

                if !isEditing, usesAxis, referenceA == nil {
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
                }
                if !isEditing, usesAxis, needsB, referenceB == nil {
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

                if !isEditing, usesPoints {
                    if referenceA == nil {
                        Section(FloeCADStrings.text("cad.workbench.assembly.pointA",
                                                    "Reference point on A (mm)")) {
                            HStack(spacing: 10) {
                                CADPanelNumberField(title: "X", text: $pointAX)
                                CADPanelNumberField(title: "Y", text: $pointAY)
                                CADPanelNumberField(title: "Z", text: $pointAZ)
                            }
                        }
                        .accessibilityIdentifier("CADConstraintPointA")
                    }
                    if needsB, referenceB == nil {
                        Section(FloeCADStrings.text("cad.workbench.assembly.pointB",
                                                    "Reference point on B (mm)")) {
                            HStack(spacing: 10) {
                                CADPanelNumberField(title: "X", text: $pointBX)
                                CADPanelNumberField(title: "Y", text: $pointBY)
                                CADPanelNumberField(title: "Z", text: $pointBZ)
                            }
                        }
                        .accessibilityIdentifier("CADConstraintPointB")
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

                if let captureMessage {
                    Section {
                        Text(captureMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing
                             ? FloeCADStrings.text("cad.workbench.constraint.editTitle", "Edit constraint")
                             : kindLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing
                           ? FloeCADStrings.text("cad.ui.common.apply", "Apply")
                           : FloeCADStrings.text("cad.ui.common.add", "Add")) { add() }
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
            .sheet(item: $pickerRequest) { request in
                CADReferencePickerView(document: document,
                                       instanceID: request.instanceID,
                                       instanceName: request.instanceName,
                                       side: request.side) { draft in
                    if request.side == "A" {
                        referenceA = draft
                    } else {
                        referenceB = draft
                    }
                    captureMessage = draft.summary
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func referenceSection(side: String, instanceID: String) -> some View {
        let draft = side == "A" ? referenceA : referenceB
        let name = report.instanceName(instanceID)
        let leaf = report.instances.first(where: { $0.id == instanceID })?.isSubassembly == false
        Section {
            if let draft {
                Text(draft.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    if side == "A" { referenceA = nil } else { referenceB = nil }
                    captureMessage = nil
                } label: {
                    Text(FloeCADStrings.text("cad.workbench.assembly.clearReference", "Clear picked reference"))
                }
                .accessibilityIdentifier("CADConstraintClearReference\(side)")
            } else if isEditing {
                Text(existingReferenceText(side: side))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FloeCADStrings.text(
                    "cad.workbench.constraint.referenceKept",
                    "Choose another face to change this reference."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(FloeCADStrings.text("cad.workbench.assembly.noReference",
                                         "No face/axis picked yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if leaf {
                HStack(spacing: 10) {
                    Button {
                        captureSelection(side: side, instanceID: instanceID)
                    } label: {
                        Text(FloeCADStrings.text("cad.workbench.assembly.useViewportSelection",
                                                 "Use viewport selection"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityIdentifier("CADConstraintCapture\(side)")

                    Button {
                        pickerRequest = CADReferencePickerRequest(instanceID: instanceID,
                                                                  instanceName: name,
                                                                  side: side)
                    } label: {
                        Text(FloeCADStrings.text("cad.workbench.assembly.pickFace",
                                                 "Pick face/axis/edge…"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityIdentifier("CADConstraintPick\(side)")
                }
            } else if isEditing {
                Text(FloeCADStrings.text(
                    "cad.workbench.constraint.subassemblyReference",
                    "Editing the value keeps the current subassembly reference."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(FloeCADStrings.format("cad.workbench.assembly.referenceFor",
                                       "Picked geometry on %@", name))
        }
    }

    /// User-meaningful geometry of the stored reference (point and direction,
    /// in mm / unit axes). Internal revision pins stay in the service
    /// payload/diagnostics and are deliberately not surfaced in the ordinary
    /// sheet.
    private func existingReferenceText(side: String) -> String {
        guard let editing else { return "" }
        let isA = side == "A"
        let point: SIMD3<Double>
        let direction: SIMD3<Double>
        if isA {
            point = editing.pointA
            direction = editing.directionA
        } else {
            point = editing.pointB ?? .zero
            direction = editing.directionB ?? SIMD3(0, 0, 1)
        }
        return Self.vectorString(point) + " → " + Self.vectorString(direction)
    }

    private func captureSelection(side: String, instanceID: String) {
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = service.handle(action: "reference",
                                       args: ["instanceID": instanceID,
                                              "useSelection": true])
            busy = false
            if let draft = CADAssemblyReferenceDraft(reply: reply,
                                                     label: "Live selection") {
                if side == "A" { referenceA = draft } else { referenceB = draft }
                captureMessage = draft.summary
            } else {
                errorText = reply["message"] as? String
                    ?? FloeCADStrings.text("cad.workbench.assembly.noSelection",
                                           "Nothing usable is selected in the viewport for this instance.")
            }
        }
    }

    private func add() {
        guard let instanceA else { return }
        if let editing {
            var args: [String: Any] = ["id": editing.id]
            if usesValue, let number = Double(value) {
                args["value"] = number
                if let current = editing.value { args["expectedValue"] = current }
            }
            if let referenceA { args["referenceA"] = referenceA.payload }
            if needsB, let referenceB { args["referenceB"] = referenceB.payload }
            busy = true
            errorText = nil
            Task { @MainActor in
                let service = CADAssemblyService(document: document)
                let reply = await service.handleAsync(action: "updateConstraint", args: args)
                if reply["mutated"] as? Bool == true { _ = await document.save() }
                busy = false
                onSaved(reply)
                if reply["ok"] as? Bool == true {
                    dismiss()
                } else {
                    errorText = reply["message"] as? String
                        ?? FloeCADStrings.text("cad.workbench.constraint.updateFailed",
                                               "The constraint could not be updated.")
                }
            }
            return
        }
        var args: [String: Any] = ["kind": kind, "instanceA": instanceA]
        if let rowA = report.instances.first(where: { $0.id == instanceA }) {
            let rowB = needsB ? report.instances.first(where: { $0.id == instanceB }) : nil
            if needsB {
                if let parentA = rowA.parentID, let parentB = rowB?.parentID, parentA == parentB {
                    args["parentID"] = parentA
                }
            } else if let parentA = rowA.parentID {
                args["parentID"] = parentA
            }
        }
        if needsB { args["instanceB"] = instanceB }
        if let referenceA { args["referenceA"] = referenceA.payload }
        if needsB, let referenceB { args["referenceB"] = referenceB.payload }
        if usesAxis {
            if referenceA == nil {
                args["directionA"] = [axisA.vector.x, axisA.vector.y, axisA.vector.z]
            }
            if referenceB == nil {
                args["directionB"] = [axisB.vector.x, axisB.vector.y, axisB.vector.z]
            }
        }
        if usesPoints {
            if referenceA == nil {
                args["pointA"] = [Double(pointAX) ?? 0, Double(pointAY) ?? 0,
                                  Double(pointAZ) ?? 0]
            }
            if needsB, referenceB == nil {
                args["pointB"] = [Double(pointBX) ?? 0, Double(pointBY) ?? 0,
                                  Double(pointBZ) ?? 0]
            }
        }
        if usesValue, let number = Double(value) { args["value"] = number }
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = await service.handleAsync(action: "addConstraint", args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onSaved(reply)
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

/// Native reference picker: lists the instance's REAL kernel faces (plane
/// normal / cylinder axis) and crease edges, with the exact query generation
/// echoed back. It never guesses a stale index, and it works inside the
/// constraint sheet, so choosing A then B never loses the pending form.
private struct CADReferencePickerView: View {
    let document: FloeCADDocument
    let instanceID: String
    let instanceName: String
    let side: String
    let onPick: (CADAssemblyReferenceDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [[String: Any]] = []
    @State private var edges: [[String: Any]] = []
    @State private var notes: [String] = []
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(FloeCADStrings.format("cad.workbench.assembly.referencePickerHint",
                                               "Pick the real geometry used by the %@ reference.",
                                               side))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        captureSelection()
                    } label: {
                        Label(FloeCADStrings.text("cad.workbench.assembly.useViewportSelection",
                                                  "Use viewport selection"),
                              systemImage: "cursorarrow.rays")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("CADReferenceUseSelection")
                }

                if !faces.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.assembly.faceCandidates",
                                                "Planes & axes")) {
                        ForEach(Array(faces.enumerated()), id: \.offset) { _, row in
                            Button {
                                pick(row, kind: "face")
                            } label: {
                                candidateLabel(row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("CADReferenceFace-\(row["index"] ?? 0)")
                        }
                    }
                }
                if !edges.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.assembly.edgeCandidates",
                                                "Edges")) {
                        ForEach(Array(edges.enumerated()), id: \.offset) { _, row in
                            Button {
                                pick(row, kind: "edge")
                            } label: {
                                candidateLabel(row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("CADReferenceEdge-\(row["index"] ?? 0)")
                        }
                    }
                }
                if !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.format("cad.workbench.assembly.pickFor",
                                                   "Reference %@ · %@", side, instanceName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) { dismiss() }
                }
            }
            .task { loadCandidates() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func candidateLabel(_ row: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row["label"] as? String ?? "—")
                    .font(.callout)
                Spacer(minLength: 4)
                if let kind = row["kind"] as? String {
                    PanelBadge(text: kind == "edge"
                               ? FloeCADStrings.text("cad.workbench.assembly.badgeEdge", "edge")
                               : (kind == "cylindrical"
                                  ? FloeCADStrings.text("cad.workbench.assembly.badgeAxis", "axis")
                                  : FloeCADStrings.text("cad.workbench.assembly.badgePlane", "plane")))
                }
            }
            if let point = row["point"] as? [Double], point.count == 3 {
                Text(String(format: "point (%.2f, %.2f, %.2f)",
                            point[0], point[1], point[2]))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let direction = row["direction"] as? [Double], direction.count == 3 {
                Text(String(format: "direction (%.2f, %.2f, %.2f)",
                            direction[0], direction[1], direction[2]))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func loadCandidates() {
        busy = true
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "referenceCandidates",
                                   args: ["instanceID": instanceID])
        faces = reply["faces"] as? [[String: Any]] ?? []
        edges = reply["edges"] as? [[String: Any]] ?? []
        notes = reply["notes"] as? [String] ?? []
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
        busy = false
    }

    private func pick(_ row: [String: Any], kind: String) {
        guard let index = row["index"] as? Int,
              let token = row["query_token"] as? String else { return }
        busy = true
        errorText = nil
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "reference", args: [
            "instanceID": instanceID,
            kind: [ "index": index, "query_token": token ],
        ])
        busy = false
        if let draft = CADAssemblyReferenceDraft(reply: reply,
                                                 label: row["label"] as? String
                                                    ?? "\(kind) \(index)") {
            onPick(draft)
            dismiss()
        } else {
            errorText = reply["message"] as? String
        }
    }

    private func captureSelection() {
        busy = true
        errorText = nil
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "reference",
                                   args: ["instanceID": instanceID,
                                          "useSelection": true])
        busy = false
        if let draft = CADAssemblyReferenceDraft(reply: reply,
                                                 label: "Live selection") {
            onPick(draft)
            dismiss()
        } else {
            errorText = reply["message"] as? String
                ?? FloeCADStrings.text("cad.workbench.assembly.noSelection",
                                       "Nothing usable is selected in the viewport for this instance.")
        }
    }
}

/// Named exploded views: persisted offsets only. Creating, updating and
/// previewing never touches the stored instance transforms or body geometry;
/// the preview rows report the transient placements the host can render and
/// Preview/Reset drive the document's live transient viewport state.
private struct CADExplodedViewsSheet: View {
    let document: FloeCADDocument
    let report: CADAssemblyReport
    /// The document session's live transient preview (shared with the
    /// viewport). Preview activates it; Reset deactivates it.
    let preview: CADExplodedViewPreview
    @Binding var busy: Bool
    let onChanged: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var views: [[String: Any]] = []
    @State private var editingID: String?
    @State private var name = ""
    @State private var directionX = "1"
    @State private var directionY = "1"
    @State private var directionZ = "1"
    @State private var distance = "40"
    @State private var included: Set<String> = []
    @State private var entryDistance: [String: String] = [:]
    @State private var entryDirection: [String: String] = [:]
    @State private var errorText: String?

    /// The saved-view row currently applied to the transient viewport preview.
    /// Reading the document-owned state here keeps the sheet honest: a preview
    /// started elsewhere shows up, and a reset removes the rows.
    private var activePreviewRow: [String: Any]? {
        guard let id = preview.viewID?.uuidString else { return nil }
        return views.first { $0["id"] as? String == id }
    }

    private var previewRows: [[String: Any]] {
        activePreviewRow?["offsets"] as? [[String: Any]] ?? []
    }

    private var previewName: String? {
        preview.viewName ?? activePreviewRow?["name"] as? String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(FloeCADStrings.text("cad.workbench.assembly.explodedName", "View name"),
                              text: $name)
                        .accessibilityIdentifier("CADExplodedName")
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "X", text: $directionX)
                        CADPanelNumberField(title: "Y", text: $directionY)
                        CADPanelNumberField(title: "Z", text: $directionZ)
                    }
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.assembly.explodedDistance",
                                                                   "Distance (mm)"),
                                        text: $distance,
                                        identifier: "CADExplodedDistance")
                    Text(FloeCADStrings.text("cad.workbench.assembly.explodedHint",
                                             "A view is display/drawing state. It never changes the base placements."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(editingID == nil
                         ? FloeCADStrings.text("cad.workbench.assembly.newExplodedView", "New exploded view")
                         : FloeCADStrings.text("cad.workbench.assembly.editExplodedView", "Edit exploded view"))
                }

                Section(FloeCADStrings.text("cad.workbench.assembly.explodedInstances",
                                            "Per-instance direction & distance")) {
                    ForEach(report.instances) { instance in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(instance.name, isOn: Binding(
                                get: { included.contains(instance.id) },
                                set: { value in
                                    if value { included.insert(instance.id) }
                                    else { included.remove(instance.id) }
                                }))
                            if included.contains(instance.id) {
                                HStack(spacing: 8) {
                                    TextField(FloeCADStrings.text("cad.workbench.assembly.entryDirection",
                                                                  "dir x,y,z (inherit)"),
                                              text: Binding(
                                                get: { entryDirection[instance.id] ?? "" },
                                                set: { entryDirection[instance.id] = $0 }))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    TextField(FloeCADStrings.text("cad.workbench.assembly.entryDistance",
                                                                  "mm (inherit)"),
                                              text: Binding(
                                                get: { entryDistance[instance.id] ?? "" },
                                                set: { entryDistance[instance.id] = $0 }))
                                        .frame(width: 100)
                                        .keyboardType(.decimalPad)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section {
                    Button(editingID == nil
                           ? FloeCADStrings.text("cad.workbench.assembly.addExplodedView", "Add view")
                           : FloeCADStrings.text("cad.workbench.assembly.updateExplodedView", "Update view")) {
                        saveView()
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("CADExplodedSave")
                    if editingID != nil {
                        Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                            resetForm()
                        }
                    }
                }

                if !views.isEmpty {
                    Section(FloeCADStrings.text("cad.workbench.assembly.explodedViews", "Saved views")) {
                        ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                            let id = view["id"] as? String ?? ""
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(view["name"] as? String ?? "—")
                                        .font(.callout)
                                    Text(String(format: "· %@ mm · %@ parts",
                                                "\(view["distanceMM"] as? Double ?? 0)",
                                                "\(view["entryCount"] as? Int ?? 0)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    if preview.viewID?.uuidString == id {
                                        PanelBadge(text: FloeCADStrings.text(
                                            "cad.workbench.assembly.previewing", "previewing"),
                                                   tint: .blue)
                                    }
                                    if let missing = view["missingInstanceIDs"] as? [String],
                                       !missing.isEmpty {
                                        PanelBadge(text: FloeCADStrings.format(
                                            "cad.workbench.assembly.explodedMissing",
                                            "%@ missing", missing.count), tint: .orange)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Button(FloeCADStrings.text("cad.workbench.assembly.preview", "Preview")) {
                                        preview(id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button(FloeCADStrings.text("cad.workbench.assembly.edit", "Edit")) {
                                        beginEdit(view)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button(role: .destructive) {
                                        remove(id)
                                    } label: {
                                        Text(FloeCADStrings.text("cad.ui.common.delete", "Delete"))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier("CADExplodedView-\(id)")
                        }
                    }
                }

                if !previewRows.isEmpty {
                    Section(FloeCADStrings.format("cad.workbench.assembly.explodedPreviewTitle",
                                                  "Preview · %@", previewName ?? "")) {
                        ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row["name"] as? String ?? "—")
                                    .font(.caption)
                                Spacer()
                                if let offset = row["offset"] as? [Double], offset.count == 3 {
                                    Text(String(format: "(%.2f, %.2f, %.2f)",
                                                offset[0], offset[1], offset[2]))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button(FloeCADStrings.text("cad.workbench.assembly.resetExploded",
                                                   "Reset preview")) {
                            resetPreview()
                        }
                        .accessibilityIdentifier("CADExplodedReset")
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.assembly.explodedViews",
                                                 "Exploded views"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.close", "Close")) { dismiss() }
                }
            }
            .task {
                loadViews()
                if editingID == nil, included.isEmpty {
                    included = Set(report.instances.map(\.id))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadViews() {
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "explodedViews", args: [:])
        views = reply["views"] as? [[String: Any]] ?? []
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        }
    }

    private func beginEdit(_ view: [String: Any]) {
        editingID = view["id"] as? String
        name = view["name"] as? String ?? ""
        if let direction = view["direction"] as? [Double], direction.count == 3 {
            directionX = CADPanelTransform.format(direction[0])
            directionY = CADPanelTransform.format(direction[1])
            directionZ = CADPanelTransform.format(direction[2])
        }
        if let value = view["distanceMM"] as? Double {
            distance = CADPanelTransform.format(value)
        }
        included = []
        entryDistance = [:]
        entryDirection = [:]
        for entry in view["entries"] as? [[String: Any]] ?? [] {
            guard let instanceID = entry["instanceID"] as? String else { continue }
            included.insert(instanceID)
            if let value = entry["distanceMM"] as? Double {
                entryDistance[instanceID] = CADPanelTransform.format(value)
            }
            if let direction = entry["direction"] as? [Double], direction.count == 3 {
                entryDirection[instanceID] = direction.map(CADPanelTransform.format)
                    .joined(separator: ",")
            }
        }
    }

    private func resetForm() {
        editingID = nil
        name = ""
        directionX = "1"; directionY = "1"; directionZ = "1"
        distance = "40"
        // A new view defaults to every current instance so "Add view" is
        // immediately meaningful; users uncheck the parts that should stay put.
        included = Set(report.instances.map(\.id))
        entryDistance = [:]
        entryDirection = [:]
        errorText = nil
    }

    private func saveView() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let dx = Double(directionX), let dy = Double(directionY),
              let dz = Double(directionZ), dx != 0 || dy != 0 || dz != 0 else {
            errorText = FloeCADStrings.text("cad.workbench.assembly.badDirection",
                                            "Direction must be a non-zero x,y,z.")
            return
        }
        guard let distanceValue = Double(distance), distanceValue >= 0 else {
            errorText = FloeCADStrings.text("cad.workbench.assembly.badDistance",
                                            "Distance must be a non-negative number.")
            return
        }
        var entries: [[String: Any]] = []
        for instance in report.instances where included.contains(instance.id) {
            var entry: [String: Any] = ["instanceID": instance.id]
            if let text = entryDistance[instance.id],
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let value = Double(text), value >= 0 else {
                    errorText = FloeCADStrings.text("cad.workbench.assembly.badDistance",
                                                    "Entry distance must be a non-negative number.")
                    return
                }
                entry["distanceMM"] = value
            }
            if let text = entryDirection[instance.id],
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let parts = text.split(separator: ",").compactMap {
                    Double($0.trimmingCharacters(in: .whitespaces))
                }
                guard parts.count == 3, parts.contains(where: { $0 != 0 }) else {
                    errorText = FloeCADStrings.text("cad.workbench.assembly.badDirection",
                                                    "Entry direction must be x,y,z.")
                    return
                }
                entry["direction"] = parts
            }
            entries.append(entry)
        }
        var args: [String: Any] = [
            "name": name,
            "direction": [dx, dy, dz],
            "distanceMM": distanceValue,
            "entries": entries,
        ]
        if let editingID { args["id"] = editingID }
        busy = true
        errorText = nil
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = service.handle(action: editingID == nil ? "addExplodedView" : "updateExplodedView",
                                       args: args)
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            if reply["ok"] as? Bool == true {
                resetForm()
                loadViews()
            } else {
                errorText = reply["message"] as? String
            }
        }
    }

    private func remove(_ id: String) {
        busy = true
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = service.handle(action: "removeExplodedView", args: ["id": id])
            if reply["mutated"] as? Bool == true { _ = await document.save() }
            busy = false
            onChanged(reply)
            // Removing the previewed view resets the document's transient
            // state in the service; the sheet derives its rows from that state,
            // so the offset list disappears with it.
            if reply["ok"] as? Bool == true { loadViews() } else {
                errorText = reply["message"] as? String
            }
        }
    }

    /// Applies the view to the TRANSIENT viewport preview. The service owns the
    /// activation so the assistant read action and this button share one path;
    /// no document write, undo entry or dirty flag is involved.
    private func preview(_ id: String) {
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "previewExplodedView", args: ["id": id])
        onChanged(reply)
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        } else {
            errorText = nil
        }
    }

    /// Returns the viewport to the stored base placements. The saved view
    /// itself is untouched; the rows disappear because the state is off.
    private func resetPreview() {
        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "resetExplodedView", args: [:])
        onChanged(reply)
        if reply["ok"] as? Bool != true {
            errorText = reply["message"] as? String
        } else {
            errorText = nil
        }
    }
}

#endif
