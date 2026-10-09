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

    private struct PendingMeshOperation: Identifiable {
        let id = UUID()
        var title: String
        var args: [String: Any]
        var destructive: Bool
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
                    .accessibilityIdentifier("CADMeshPending")
                }
            }
            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)
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

    /// Transient preview before apply: the service computes the actual result
    /// geometry on its own copies (no document mutation) and returns a bounded
    /// mesh snapshot + content hash. Apply passes those exact values back so
    /// the committed result is provably the one the user inspected.
    private func preview(args: [String: Any], title: String, destructive: Bool) {
        busy = true
        Task { @MainActor in
            let service = CADMeshService(document: document)
            var previewArgs = args
            previewArgs["preview"] = true
            let reply = service.handle(action: args["action"] as? String ?? "boundary",
                                       args: previewArgs)
            guard reply["ok"] as? Bool == true,
                  let mesh = reply["mesh"] as? [String: Any],
                  let hash = reply["previewHash"] as? String else {
                // A refusal (e.g. brep_body_refused / empty result) is shown
                // as-is; nothing is applied.
                outcome = reply
                busy = false
                return
            }
            var lines: [String] = []
            let triangles = reply["triangleCount"] as? Int ?? 0
            lines.append(FloeCADStrings.format("cad.workbench.mesh.previewTriangles",
                                               "%@ triangles in the result", triangles))
            if destructive && !allowMeshDowngrade {
                lines.append(FloeCADStrings.text("cad.workbench.mesh.downgradeHint",
                                                 "Analytic bodies will be refused unless “Allow destructive mesh edits” is on."))
            }
            pending = PendingMeshOperation(title: title,
                                           args: args,
                                           destructive: destructive,
                                           previewLines: lines,
                                           mesh: mesh,
                                           previewHash: hash,
                                           previewRevision: reply["previewRevision"] as? Int,
                                           previewChangeCount: reply["previewChangeCount"] as? Int)
            busy = false
        }
    }

    private func applyPending(_ operation: PendingMeshOperation) {
        var args = operation.args
        if operation.destructive, allowMeshDowngrade { args["forceMesh"] = true }
        args["expectedPreviewHash"] = operation.previewHash
        if let revision = operation.previewRevision { args["expectedRevision"] = revision }
        if let count = operation.previewChangeCount { args["expectedChangeCount"] = count }
        pending = nil
        perform(args)
    }

    private func perform(_ args: [String: Any]) {
        busy = true
        Task { @MainActor in
            let reply = CADMeshService(document: document).handle(
                action: args["action"] as? String ?? "boundary", args: args)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            outcome = reply
            busy = false
        }
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
