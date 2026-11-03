// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct CADVoxelRemeshPanel: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    let selectedBodyIDs: [UUID]
    @State private var voxelSize = "1"
    @State private var maxDeviation = "4"
    @State private var outcome: [String: Any] = [:]
    @State private var pending: [String: Any]?
    @State private var task: Task<Void,Never>?
    @State private var operationID: UUID?
    @State private var busy = false
    private var selected: UUID? { selectedBodyIDs.count == 1 ? selectedBodyIDs.first : nil }
    private var isReconstruction: Bool {
        guard let selected else { return false }
        return document.session.document.features.nodes.contains { node in
            if case .voxelRemesh = node.kind { return node.outputBodyIDs.contains { $0.raw == selected } && !node.suppressed }; return false
        }
    }
    var body: some View {
        PanelSection(title:FloeCADStrings.text("cad.mesh.voxel.title","Voxel reconstruction")) {
            Text(FloeCADStrings.text("cad.mesh.voxel.scope","Rebuild one enclosed scan as a uniform voxel surface. The original scan is kept; textures are not transferred."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                CADPanelNumberField(title:FloeCADStrings.text("cad.mesh.voxel.size","Voxel size (mm)"),text:$voxelSize)
                CADPanelNumberField(title:FloeCADStrings.text("cad.mesh.voxel.deviation","Deviation limit (mm)"),text:$maxDeviation)
            }
            PanelActionGrid {
                PanelActionButton(title:FloeCADStrings.label("cad.workbench.mesh.preview","Preview"),systemImage:"eye",
                                  disabled:busy || selected == nil) { preview() }
                    .accessibilityIdentifier("CADVoxelPreview")
                if isReconstruction {
                    PanelActionButton(title:FloeCADStrings.label("cad.mesh.voxel.inspect","Inspect reconstruction"),systemImage:"ruler",
                                      disabled:busy || selected == nil) { inspect() }
                        .accessibilityIdentifier("CADVoxelInspect")
                }
            }
            if let pending, let mesh = pending["mesh"] as? [String: Any] {
                CADTransientPreviewView(mesh:mesh)
                PanelActionButton(title:FloeCADStrings.label("cad.workbench.mesh.apply","Apply"),systemImage:"checkmark.circle",disabled:busy) { apply(pending) }
                    .accessibilityIdentifier("CADVoxelApply")
            }
            if let grid = outcome["gridDimensions"] as? [Int] {
                Text(FloeCADStrings.format("cad.mesh.voxel.grid","Grid: %@ × %@ × %@",grid[0],grid[1],grid[2])).font(.caption)
            }
            if let size = outcome["voxelSizeMM"] as? Double {
                Text(FloeCADStrings.format("cad.mesh.voxel.actualSize","Actual voxel size: %@ mm",String(format:"%.6g",size))).font(.caption)
            }
            if let sampled = outcome["surfaceSampledMaxDistanceMM"] as? Double,
               let upper = outcome["surfaceDistanceUpperBoundMM"] as? Double {
                Text(FloeCADStrings.format("cad.mesh.voxel.measured","Sampled deviation: %@ mm; full-surface upper bound: %@ mm",String(format:"%.6g",sampled),String(format:"%.6g",upper))).font(.caption)
            }
            if let count = outcome["quadCount"] as? Int {
                Text(FloeCADStrings.format("cad.mesh.voxel.quads","%@ quads · closed mesh",count)).font(.caption)
            }
            if let message = outcome["message"] as? String {
                if let error = outcome["error"] as? String {
                    Text(errorSummary(error)).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(FloeCADStrings.text("cad.mesh.voxel.details","Details")) { Text(message).font(.caption).textSelection(.enabled) }
                } else { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    PanelActionButton(title:FloeCADStrings.label("cad.ui.common.cancel","Cancel"),systemImage:"xmark.circle") { cancel() }
                        .accessibilityIdentifier("CADVoxelCancel")
                }
            }
        }
        .accessibilityIdentifier("CADVoxelPanel")
        .onDisappear { cancel() }
        .onChange(of:selectedBodyIDs) { _,_ in cancel(); outcome = [:] }
        .onChange(of:voxelSize) { _,_ in pending = nil }
        .onChange(of:maxDeviation) { _,_ in pending = nil }
    }
    private func errorSummary(_ code: String) -> String {
        switch code {
        case "voxel_budget_exceeded": return FloeCADStrings.text("cad.mesh.voxel.budgetError","Use larger voxels or a larger deviation limit to fit the reconstruction budget.")
        case "voxel_deviation_exceeded": return FloeCADStrings.text("cad.mesh.voxel.distanceError","The result exceeds the deviation limit. Try smaller voxels.")
        case "voxel_scope_unavailable": return FloeCADStrings.text("cad.mesh.voxel.scopeError","This scan cannot be reconstructed at this voxel size. See details.")
        case "cancelled": return FloeCADStrings.text("cad.mesh.voxel.cancelled","Reconstruction cancelled. The scan was kept.")
        case "timeout": return FloeCADStrings.text("cad.mesh.voxel.timeout","Reconstruction reached its time limit. Try larger voxels.")
        default: return FloeCADStrings.text("cad.mesh.voxel.requestError","Check the selected body and reconstruction values. See details.")
        }
    }
    private func preview() {
        guard let selected, let size = Double(voxelSize), let deviation = Double(maxDeviation), size.isFinite, deviation.isFinite else {
            outcome = ["message":FloeCADStrings.text("cad.mesh.voxel.invalid","Enter a finite voxel size and deviation limit.")]; return
        }
        let update = isReconstruction
        start {
            var args: [String:Any] = ["bodyID":selected.uuidString,"voxelSize":size,"maxDeviation":deviation,"preview":true]
            if update {
                let current = await CADMeshService(document:document).handleAsync(action:"voxel.inspect",args:["bodyID":selected.uuidString])
                guard current["ok"] as? Bool == true, let digest = current["definitionDigest"] as? String else { return current }
                args["definitionDigest"] = digest
            }
            let action = update ? "voxel.update" : "voxel.remesh"
            var result = await CADMeshService(document:document).handleAsync(action:action,args:args)
            if result["ok"] as? Bool == true { args["action"] = action; result["applyArgs"] = args }
            return result
        }
    }
    private func inspect() {
        guard let selected else { return }
        start { await CADMeshService(document:document).handleAsync(action:"voxel.inspect",args:["bodyID":selected.uuidString]) }
    }
    private func apply(_ preview: [String:Any]) {
        guard var args = preview["applyArgs"] as? [String:Any], let action = args.removeValue(forKey:"action") as? String else { return }
        args["preview"] = false
        args["expectedPreviewHash"] = preview["previewHash"]
        args["expectedChangeCount"] = preview["previewChangeCount"]
        args["expectedRevision"] = preview["previewRevision"]
        start { await CADMeshService(document:document).handleAsync(action:action,args:args) }
    }
    private func start(_ work: @escaping @MainActor () async -> [String:Any]) {
        task?.cancel(); pending = nil; let id = UUID(); operationID = id; busy = true
        task = Task { @MainActor in
            let result = await work()
            guard operationID == id, !Task.isCancelled, !document.isClosed else { return }
            busy = false; outcome = result
            if result["action"] as? String == "voxel.inspect", result["ok"] as? Bool == true {
                if let size = result["voxelSizeMM"] as? Double { voxelSize = String(format:"%.8g",size) }
                if let cap = result["maxDeviationMM"] as? Double { maxDeviation = String(format:"%.8g",cap) }
            }
            if result["preview"] as? Bool == true { pending = result }
            else if result["mutated"] as? Bool == true, let raw = result["bodyID"] as? String, let body = UUID(uuidString:raw) {
                viewModel.selection = [BodyID(raw:body)]
            }
        }
    }
    private func cancel() {
        task?.cancel(); operationID = nil; busy = false; pending = nil
        _ = CADMeshService.cancelActiveOperation(for:document)
    }
}
#endif
