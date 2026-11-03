//
//  CADMeshPanelView.swift
//  FloeCADKit
//
//  Mesh panel for the Floe workbench: explicit body checklist (never an
//  implicit first body), boolean target/tools pickers, parameterized
//  transform/repair/simplify/material operations, a real boundary-check
//  report as the pre-apply preview, and an explicit acknowledgement before a
//  destructive op drops an analytic B-rep (`forceMesh`).
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct CADMeshPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var selected: Set<UUID> = []
    @State private var outcome: [String: Any] = [:]
    @State private var busy = false
    @State private var booleanOp = "union"
    @State private var booleanTarget: UUID?
    @State private var translateX = "0"
    @State private var translateY = "0"
    @State private var translateZ = "0"
    @State private var rotateAxis: CADPanelAxisPreset = .zPlus
    @State private var rotateDegrees = "90"
    @State private var uniformScale = ""
    @State private var tolerance = "0.001"
    @State private var simplifyRatio = "0.5"
    @State private var materialRed = "0.8"
    @State private var materialGreen = "0.8"
    @State private var materialBlue = "0.85"
    @State private var materialOpacity = "1"
    @State private var imageID: UUID?
    @State private var allowMeshDowngrade = false
    @State private var pending: PendingMeshOperation?
    /// The in-flight operation's owner task. It is unstructured (`Task {}`),
    /// not a structured child: the view only subscribes to and cancels this
    /// handle, while the service owns the detached worker and the document
    /// close path fences it too. `operationID` is the identity fence that
    /// prevents a late continuation from publishing into a newer operation.
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID: UUID?

    private struct PendingMeshOperation: Identifiable {
        let id = UUID()
        var title: String
        var args: [String: Any]
        var destructive: Bool
        /// Whether this preview's request carried the user's explicit
        /// `forceMesh` consent. Apply uses this captured value, never a newer
        /// toggle state, so a later opt-in cannot authorize an older preview
        /// and a revocation can only invalidate it.
        var downgradeAcknowledged: Bool
        var previewLines: [String]
        var mesh: [String: Any]
        var previewHash: String
        var previewRevision: Int?
        var previewChangeCount: Int?
    }

    private var bodies: [CADPanelBodyOption] { document.panelBodyOptions }

    private var selectedIDs: [UUID] { bodies.map(\.id).filter { selected.contains($0) } }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.mesh", "Mesh"),
                             identifier: "CADMeshPanel") {
            PanelBadge(text: FloeCADStrings.format("cad.workbench.mesh.selected", "%@ bodies selected",
                                                   selectedIDs.count),
                       tint: selectedIDs.count >= 1 ? .green : .secondary)

            CADVoxelRemeshPanel(document: document, viewModel: viewModel, selectedBodyIDs: selectedIDs)

            CADPolygonMeshPanel(document: document, viewModel: viewModel,
                selectedBodyIDs: selectedIDs, forceMesh: allowMeshDowngrade)

            if bodies.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.mesh.empty", "No bodies to work with yet."),
                    hint: FloeCADStrings.text("cad.workbench.mesh.emptyHint",
                                              "Sketch and extrude a solid first; mesh operations run on tessellations and keep analytic B-rep bodies intact unless you explicitly allow a downgrade."))
            } else {
                PanelSection(title: FloeCADStrings.text("cad.workbench.mesh.bodies", "Bodies")) {
                    ForEach(bodies) { body in
                        Button {
                            if selected.contains(body.id) { selected.remove(body.id) }
                            else { selected.insert(body.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(body.id)
                                      ? "checkmark.square.fill" : "square")
                                Text(body.name).foregroundStyle(.primary)
                                Spacer()
                                if let count = document.session.document.bodies
                                    .first(where: { $0.id.raw == body.id })?.render.triangleCount {
                                    Text("\(count) △")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("CADMeshBody-\(body.id.uuidString)")
                    }
                    HStack(spacing: 10) {
                        panelHitTarget(Button(FloeCADStrings.text("cad.workbench.mesh.useViewport",
                                                                  "Use viewport selection")) {
                            selected = Set(viewModel.selection.map(\.raw))
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small))
                        panelHitTarget(Button(FloeCADStrings.text("cad.workbench.mesh.clearSelection",
                                                                  "Clear")) {
                            selected = []
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small))
                    }
                }

                PanelSection(title: FloeCADStrings.text("cad.workbench.mesh.boolean", "Boolean")) {
                    Picker(FloeCADStrings.text("cad.workbench.mesh.operation", "Operation"),
                           selection: $booleanOp) {
                        Text(FloeCADStrings.text("cad.workbench.mesh.union", "Union")).tag("union")
                        Text(FloeCADStrings.text("cad.workbench.mesh.subtract", "Subtract")).tag("subtract")
                        Text(FloeCADStrings.text("cad.workbench.mesh.intersect", "Intersect")).tag("intersect")
                    }
                    .pickerStyle(.segmented)
                    Picker(FloeCADStrings.text("cad.workbench.mesh.target", "Target (kept)"),
                           selection: $booleanTarget) {
                        Text(FloeCADStrings.text("cad.workbench.mesh.pickTarget", "Pick target…"))
                            .tag(UUID?.none)
                        ForEach(bodies.filter { selected.contains($0.id) }) { body in
                            Text(body.name).tag(UUID?.some(body.id))
                        }
                    }
                    .accessibilityIdentifier("CADMeshBooleanTarget")
                    PanelActionGrid {
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.preview", "Preview"),
                                          systemImage: "eye",
                                          disabled: busy || booleanTarget == nil || selectedIDs.count < 2) {
                            previewBoolean()
                        }
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.combine", "Combine"),
                                          systemImage: "square.on.square",
                                          disabled: busy || selectedIDs.count < 2) {
                            previewCombine()
                        }
                    }
                }

                PanelSection(title: FloeCADStrings.text("cad.workbench.mesh.singleBody", "Single body")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "Tx", text: $translateX)
                        CADPanelNumberField(title: "Ty", text: $translateY)
                        CADPanelNumberField(title: "Tz", text: $translateZ)
                    }
                    HStack(spacing: 10) {
                        Picker("", selection: $rotateAxis) {
                            ForEach(CADPanelAxisPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.mesh.degrees", "Degrees"),
                                            text: $rotateDegrees)
                    }
                    CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.mesh.scaleOptional",
                                                                   "Uniform scale (empty = keep)"),
                                        text: $uniformScale,
                                        allowsEmpty: true)
                    PanelActionGrid {
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.transform", "Transform"),
                                          systemImage: "move.3d",
                                          disabled: busy || selectedIDs.isEmpty) {
                            applyTransform()
                        }
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.normals", "Normals"),
                                          systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                                          disabled: busy || selectedIDs.isEmpty) {
                            single("recomputeNormals", extra: [:])
                        }
                    }
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.mesh.tolerance",
                                                                       "Repair tolerance (mm)"),
                                            text: $tolerance)
                        CADPanelNumberField(title: FloeCADStrings.text("cad.workbench.mesh.simplifyRatio",
                                                                       "Simplify ratio (0–1)"),
                                            text: $simplifyRatio)
                    }
                    PanelActionGrid {
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.repair", "Repair"),
                                          systemImage: "wrench.and.screwdriver",
                                          disabled: busy || selectedIDs.isEmpty) {
                            previewSingle("repair", title: "Repair",
                                          extra: ["tolerance": Double(tolerance) ?? 1e-3])
                        }
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.simplify", "Simplify"),
                                          systemImage: "arrow.down.right.and.arrow.up.left",
                                          disabled: busy || selectedIDs.isEmpty) {
                            previewSingle("simplify", title: "Simplify",
                                          extra: ["ratio": Double(simplifyRatio) ?? 0.5])
                        }
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.boundary", "Boundary check"),
                                          systemImage: "square.on.square.dashed",
                                          disabled: busy || selectedIDs.isEmpty) {
                            boundaryCheck()
                        }
                    }
                }

                PanelSection(title: FloeCADStrings.text("cad.workbench.mesh.material", "Material")) {
                    HStack(spacing: 10) {
                        CADPanelNumberField(title: "R", text: $materialRed)
                        CADPanelNumberField(title: "G", text: $materialGreen)
                        CADPanelNumberField(title: "B", text: $materialBlue)
                        CADPanelNumberField(title: "A", text: $materialOpacity)
                    }
                    PanelActionGrid {
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.applyMaterial",
                                                                      "Apply material"),
                                          systemImage: "paintpalette",
                                          disabled: busy || selectedIDs.isEmpty) {
                            applyMaterial()
                        }
                    }
                    if !document.session.document.images.isEmpty {
                        let images = document.session.document.images
                        Picker(FloeCADStrings.text("cad.workbench.mesh.image", "Texture image"),
                               selection: $imageID) {
                            Text(FloeCADStrings.text("cad.workbench.mesh.pickImage", "Pick image…"))
                                .tag(UUID?.none)
                            ForEach(images) { image in
                                Text(image.name).tag(UUID?.some(image.id.raw))
                            }
                        }
                        .accessibilityIdentifier("CADMeshImage")
                        PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.applyImage",
                                                                      "Apply image"),
                                          systemImage: "photo",
                                          disabled: busy || selectedIDs.isEmpty || imageID == nil) {
                            single("image", extra: ["imageID": imageID?.uuidString ?? ""])
                        }
                    }
                }

                Toggle(FloeCADStrings.text("cad.workbench.mesh.allowDowngrade",
                                           "Allow destructive mesh edits on analytic bodies (drops B-rep)"),
                       isOn: $allowMeshDowngrade)
                    .font(.callout)
                    .accessibilityIdentifier("CADMeshForceDowngrade")

                if let pending {
                    PanelSection(title: pending.title) {
                        CADTransientPreviewView(mesh: pending.mesh)
                        ForEach(pending.previewLines, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                        PanelActionGrid {
                            PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.apply", "Apply"),
                                              systemImage: "checkmark.circle") {
                                applyPending(pending)
                            }
                            PanelActionButton(title: FloeCADStrings.label("cad.ui.common.cancel", "Cancel"),
                                              systemImage: "xmark.circle") {
                                self.pending = nil
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("CADMeshPending")
                }
            }
            if busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    PanelActionButton(title: FloeCADStrings.label("cad.ui.common.cancel", "Cancel"),
                                      systemImage: "xmark.circle") {
                        cancelOperation()
                    }
                    .accessibilityIdentifier("CADMeshCancelOperation")
                }
            }
            repairOutcomeView
        }
        .onDisappear {
            // A panel switch can hide this view without discarding its @State.
            // Cancel the owned operation, then drop the local busy/identity so
            // returning shows enabled actions instead of a permanent spinner.
            // The service/document still own and fence the detached worker.
            cancelOperation()
            operationTask = nil
            operationID = nil
            busy = false
        }
        .onChange(of: allowMeshDowngrade) { _, isAllowed in
            // Revoking the explicit consent invalidates any preview that was
            // computed under it, in flight or already shown. The user must opt
            // in and preview again; a destructive preview can never become
            // actionable through a later toggle change. The in-flight request
            // is additionally fenced where its reply is published.
            if !isAllowed { pending = nil }
        }
    }

    // MARK: Operations

    private func previewBoolean() {
        guard let target = booleanTarget else { return }
        let tools = selectedIDs.filter { $0 != target }
        guard !tools.isEmpty else { return }
        let args: [String: Any] = ["action": "boolean", "op": booleanOp,
                                   "target": target.uuidString,
                                   "tools": tools.map(\.uuidString)]
        preview(args: args,
                title: localizedConstraintKind(booleanOp) + " — " + name(of: target),
                destructive: true)
    }

    private func previewCombine() {
        preview(args: ["action": "combine", "bodyIDs": selectedIDs.map(\.uuidString)],
                title: "Combine", destructive: true)
    }

    private func previewSingle(_ action: String, title: String, extra: [String: Any]) {
        var args = extra
        args["action"] = action
        args["bodyIDs"] = selectedIDs.map(\.uuidString)
        preview(args: args, title: title, destructive: true)
    }

    private func single(_ action: String, extra: [String: Any]) {
        var args = extra
        args["action"] = action
        args["bodyIDs"] = selectedIDs.map(\.uuidString)
        if action == "image" {
            args = extra
            args["action"] = action
            args["bodyIDs"] = selectedIDs.map(\.uuidString)
        }
        perform(args)
    }

    private func applyTransform() {
        var args: [String: Any] = ["action": "transform",
                                   "bodyIDs": selectedIDs.map(\.uuidString)]
        if let x = Double(translateX), let y = Double(translateY), let z = Double(translateZ),
           x != 0 || y != 0 || z != 0 {
            args["translate"] = [x, y, z]
        }
        if let degrees = Double(rotateDegrees), degrees != 0 {
            args["rotate"] = ["axis": [rotateAxis.vector.x, rotateAxis.vector.y, rotateAxis.vector.z],
                              "angleDegrees": degrees]
        }
        if let scale = Double(uniformScale), scale > 0 {
            args["scale"] = [scale, scale, scale]
        }
        perform(args)
    }

    private func applyMaterial() {
        var args: [String: Any] = ["action": "material",
                                   "bodyIDs": selectedIDs.map(\.uuidString)]
        if let r = Double(materialRed), let g = Double(materialGreen), let b = Double(materialBlue) {
            args["color"] = [r, g, b]
        }
        if let opacity = Double(materialOpacity) { args["opacity"] = opacity }
        perform(args)
    }

    private func boundaryCheck() {
        perform(["action": "boundary", "bodyIDs": selectedIDs.map(\.uuidString)])
    }

    /// Transient preview before apply: the service snapshots the inputs on
    /// the main actor, computes the actual result geometry off the UI and
    /// returns a bounded mesh snapshot + content hash. Apply passes those exact
    /// values back so the committed result is provably the one inspected.
    ///
    /// The explicit "Allow destructive mesh edits" consent is captured into the
    /// request at submission: with it off (the default) the service still
    /// refuses a precise B-rep; with it on the request carries `forceMesh`, so
    /// the user inspects the real downgraded result instead of a refusal. A
    /// later toggle change never rewrites this request.
    private func preview(args: [String: Any], title: String, destructive: Bool) {
        operationTask?.cancel()
        let id = UUID()
        operationID = id
        // The consent that governs this request is the toggle state now, not
        // whenever the reply arrives or Apply is tapped.
        let downgradeAcknowledged = destructive && allowMeshDowngrade
        // An older Apply preview must not stay actionable while a new
        // computation is in flight.
        pending = nil
        outcome = [:]
        busy = true
        operationTask = Task { @MainActor in
            // Identity-scoped cleanup: only this operation may clear busy or
            // the task handle, never a newer operation that replaced it.
            defer { finishOperation(id) }
            let service = CADMeshService(document: document)
            var previewArgs = args
            previewArgs["preview"] = true
            if downgradeAcknowledged { previewArgs["forceMesh"] = true }
            let reply = await service.handleAsync(
                action: args["action"] as? String ?? "boundary",
                args: previewArgs)
            // A cancel between the service returning and this continuation
            // must not publish a preview; the owner task and its service
            // worker have already been joined by handleAsync.
            guard operationID == id, !Task.isCancelled else { return }
            // Revoking consent while the request was running invalidates its
            // result: never publish an actionable destructive preview the
            // current UI state no longer permits.
            guard !destructive || !downgradeAcknowledged || allowMeshDowngrade else { return }
            guard reply["ok"] as? Bool == true,
                  let mesh = reply["mesh"] as? [String: Any],
                  let hash = reply["previewHash"] as? String else {
                // A refusal (e.g. brep_body_refused / empty result) is shown
                // as-is; nothing is applied.
                outcome = reply
                return
            }
            var lines: [String] = []
            let triangles = reply["triangleCount"] as? Int ?? 0
            lines.append(FloeCADStrings.format("cad.workbench.mesh.previewTriangles",
                                               "%@ triangles in the result", triangles))
            lines.append(contentsOf: simplificationLines(reply))
            if reply["repairComplete"] as? Bool == false {
                lines.append(FloeCADStrings.text("cad.mesh.cleanupIncomplete", "Unresolved mesh issues were found."))
            }
            if destructive && !downgradeAcknowledged {
                lines.append(FloeCADStrings.text("cad.workbench.mesh.downgradeHint",
                                                 "Analytic bodies will be refused unless “Allow destructive mesh edits” is on."))
            }
            pending = PendingMeshOperation(title: title,
                                           args: args,
                                           destructive: destructive,
                                           downgradeAcknowledged: downgradeAcknowledged,
                                           previewLines: lines,
                                           mesh: mesh,
                                           previewHash: hash,
                                           previewRevision: reply["previewRevision"] as? Int,
                                           previewChangeCount: reply["previewChangeCount"] as? Int)
        }
    }

    @ViewBuilder
    private var repairOutcomeView: some View {
        if outcome["repairComplete"] as? Bool == false {
            Label(FloeCADStrings.text(
                outcome["ok"] as? Bool == false ? "cad.mesh.repairUnavailable" : "cad.mesh.cleanupIncomplete",
                outcome["ok"] as? Bool == false
                    ? "These issues could not be repaired automatically. The original model is unchanged."
                    : "Unresolved mesh issues were found."), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .accessibilityIdentifier("CADMeshIntegrityWarning")
        } else {
            PanelOutcome(reply: localizedOutcome)
        }
        if !repairReports.isEmpty {
            DisclosureGroup(FloeCADStrings.text("cad.mesh.inspectDetails", "Inspection details")) {
                integrityCount("cad.mesh.openEdges", "Open edges", key: "boundaryEdgeCount")
                integrityCount("cad.mesh.nonManifoldEdges", "Non-manifold edges", key: "nonManifoldEdgeCount")
                integrityCount("cad.mesh.selfIntersections", "Self-intersections", key: "selfIntersectionPairCount")
                integrityCount("cad.mesh.degenerates", "Degenerate triangles", key: "degenerateTriangleCount")
                LabeledContent(FloeCADStrings.text("cad.mesh.orientation", "Face orientation"),
                    value: FloeCADStrings.text(needsOrientationReview ? "cad.mesh.needsReview" : "cad.mesh.noIssue",
                        needsOrientationReview ? "Needs review" : "No issue found"))
            }
        }
        if !simplificationLines(outcome).isEmpty {
            DisclosureGroup(FloeCADStrings.text("cad.mesh.inspectDetails", "Inspection details")) {
                ForEach(simplificationLines(outcome), id: \.self) { Text($0).font(.callout) }
            }
            .accessibilityIdentifier("CADMeshSimplificationDetails")
        }
    }

    private var localizedOutcome: [String: Any] {
        let messages: [String: (String, String)] = [
            "face_material_simplification_unavailable": ("cad.mesh.faceMaterialsUnavailable", "These face materials cannot be preserved. The model is unchanged."),
            "simplification_inspection_failed": ("cad.mesh.inspectionFailed", "Could not finish checking the model. Try again."),
            "simplification_changes_features": ("cad.mesh.changeTooLarge", "This would change a boundary or seam. Try less simplification."),
            "limit_time": ("cad.mesh.processingTimedOut", "Processing timed out. Try a smaller selection."),
        ]
        guard let code = outcome["error"] as? String, let entry = messages[code] else { return outcome }
        var reply = outcome
        reply["message"] = FloeCADStrings.text(entry.0, entry.1)
        return reply
    }

    private func simplificationLines(_ reply: [String: Any]) -> [String] {
        let reports = (reply["bodies"] as? [[String: Any]] ?? []).compactMap { $0["quality"] as? [String: Any] }
        guard !reports.isEmpty else { return [] }
        var lines: [String] = []
        if let distance = reports.compactMap({ $0["surfaceSampledMaxDistanceMM"] as? Double }).max() {
            lines.append(FloeCADStrings.format("cad.mesh.sampledDeviation", "Sampled surface deviation: %.4f mm", distance))
        }
        if let boundary = reports.compactMap({ $0["boundarySampledMaxDistanceMM"] as? Double }).max() {
            lines.append(FloeCADStrings.format("cad.mesh.boundaryDeviation", "Sampled boundary deviation: %.4f mm", boundary))
        }
        let volume = reports.compactMap { $0["signedVolumeDeltaMM3"] as? Double }.reduce(0,+)
        lines.append(FloeCADStrings.format("cad.mesh.signedVolumeChange", "Signed volume change: %.4f mm³", volume))
        if reports.allSatisfy({ $0["uvAndHardEdgeSeamsPreserved"] as? Bool == true }) {
            lines.append(FloeCADStrings.text("cad.mesh.seamsPreserved", "Texture seams and hard edges preserved"))
        }
        return lines
    }

    private var repairReports: [[String: Any]] {
        (outcome["bodies"] as? [[String: Any]] ?? []).compactMap { $0["afterIntegrity"] as? [String: Any] }
    }

    private var needsOrientationReview: Bool {
        repairReports.contains { report in
            ["inconsistentWinding", "reversedClosedShell", "orientationNeedsReview"].contains {
                report[$0] as? Bool == true
            }
        }
    }

    private func integrityCount(_ key: String, _ fallback: String, key field: String) -> some View {
        LabeledContent(FloeCADStrings.text(key, fallback),
                       value: String(repairReports.reduce(0) { $0 + ($1[field] as? Int ?? 0) }))
    }

    private func applyPending(_ operation: PendingMeshOperation) {
        var args = operation.args
        // Apply only the consent captured with this preview. Reading the live
        // toggle to *grant* consent here would let a later opt-in authorize a
        // preview that was never inspected under that consent.
        if operation.destructive, operation.downgradeAcknowledged {
            // Re-check revocation locally: `onChange` clears the pending card,
            // but if this Apply still runs, re-preview through the real service
            // (which now refuses the precise body) instead of silently applying
            // a downgrade the user no longer permits.
            guard allowMeshDowngrade else {
                pending = nil
                preview(args: operation.args, title: operation.title,
                        destructive: operation.destructive)
                return
            }
            args["forceMesh"] = true
        }
        args["expectedPreviewHash"] = operation.previewHash
        if let revision = operation.previewRevision { args["expectedRevision"] = revision }
        if let count = operation.previewChangeCount { args["expectedChangeCount"] = count }
        pending = nil
        perform(args)
    }

    private func perform(_ args: [String: Any]) {
        operationTask?.cancel()
        let id = UUID()
        operationID = id
        // A pending preview from an earlier computation is stale by definition
        // once a new edit starts; never leave its Apply button actionable.
        pending = nil
        // A new operation replaces the previous outcome line; an old refusal
        // must not be read as the result of this request.
        outcome = [:]
        busy = true
        operationTask = Task { @MainActor in
            defer { finishOperation(id) }
            let reply = await CADMeshService(document: document).handleAsync(
                action: args["action"] as? String ?? "boundary", args: args)
            if reply["mutated"] as? Bool == true {
                // The service already committed this edit atomically. Saving it
                // is a consequence owned by the document, not by the panel's
                // presentation state, so it runs before the cancellation fence
                // and is not skipped when the user cancels after the commit.
                await persistAdmittedEdit()
            }
            // Never publish a cancelled/stale completion. An admitted edit was
            // already saved above even when the guard returns.
            guard operationID == id, !Task.isCancelled else { return }
            outcome = reply
        }
    }

    /// Persist a geometry edit the service already admitted. The independent
    /// MainActor owner task keeps the save from being cancelled with the panel
    /// operation; a later save by a newer operation still wins by revision.
    private func persistAdmittedEdit() async {
        let document = self.document
        await Task { @MainActor in
            _ = await document.save()
        }.value
    }

    /// User cancel: cancel the owned operation task. `handleAsync`'s
    /// cancellation handler flips the service token, cancels its detached
    /// worker and joins it before this owner task returns; the identity fence
    /// above then discards any late preview/outcome. `busy` drops immediately
    /// so the panel is usable, while the scoped `finishOperation` cleanup runs
    /// only if this operation still owns the panel.
    private func cancelOperation() {
        operationTask?.cancel()
        busy = false
    }

    /// Clear operation state only when `id` still owns the panel. A replaced
    /// operation can never clear the newer operation's task or busy spinner.
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operationTask = nil
        busy = false
    }

    private func name(of id: UUID) -> String {
        bodies.first { $0.id == id }?.name ?? String(id.uuidString.prefix(8))
    }

    private func localizedConstraintKind(_ op: String) -> String {
        switch op {
        case "union": return FloeCADStrings.text("cad.workbench.mesh.union", "Union")
        case "subtract": return FloeCADStrings.text("cad.workbench.mesh.subtract", "Subtract")
        case "intersect": return FloeCADStrings.text("cad.workbench.mesh.intersect", "Intersect")
        default: return op
        }
    }
}
#endif
