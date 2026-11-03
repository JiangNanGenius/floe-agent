#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct CADPolygonMeshPanel: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    var selectedBodyIDs: [UUID]
    var forceMesh: Bool
    @State private var distance = 2.0
    @State private var fraction = 0.5
    @State private var tolerance = 0.001
    @State private var busy = false
    @State private var message = ""
    @State private var diagnostic = ""
    @State private var operation: Task<Void,Never>?
    @State private var operationID: UUID?
    private func t(_ key: String, _ text: String) -> String { FloeCADStrings.text("cad.mesh.topology." + key,text) }
    private var options: [(id: BodyID,name: String)] {
        let graph = document.session.document.features
        let applied = graph.nodes.prefix(max(0,min(graph.rollbackIndex ?? graph.nodes.count,graph.nodes.count)))
        return applied.compactMap { node in
            guard !node.suppressed, case .polygonCage = node.kind, let id = node.outputBodyIDs.first,
                  document.session.document.body(with: id)?.brep == nil,
                  document.session.document.body(with: id) != nil,
                  applied.last(where: { !$0.suppressed && $0.outputBodyIDs.contains(id) })?.id == node.id else { return nil }
            return (id,node.name)
        }
    }
    var body: some View {
        PanelSection(title: t("title","Polygon editing")) {
            HStack {
                Button(t("create","Create polygon box")) { run("topology.create") }
                    .accessibilityIdentifier("PolygonCageCreate")
                Button(t("capture","Capture selected body")) {
                    guard let id = selectedBodyIDs.first else { return }
                    run("topology.capture",["bodyID":id.uuidString,"forceMesh":forceMesh])
                }.disabled(selectedBodyIDs.count != 1)
            }.disabled(busy)
            Picker(t("cage","Editable cage"),selection: Binding(
                get: { viewModel.polygonCageEditingBody?.raw },
                set: { if let id = $0 { viewModel.beginPolygonCageEditing(BodyID(raw:id)) } else { viewModel.endPolygonCageEditing() } })) {
                Text(t("choose","Choose a cage")).tag(UUID?.none)
                ForEach(options,id: \.id) { option in Text(option.name).tag(Optional(option.id.raw)) }
            }.disabled(busy)
            if let active = viewModel.activePolygonCage {
                Toggle(t("showCage","Show control cage"),isOn: $viewModel.polygonCageShowControl)
                    .accessibilityIdentifier("PolygonShowControlCage")
                Picker(t("selection","Selection"),selection: $viewModel.polygonPickMode) {
                    Text(t("face","Face")).tag(EditorViewModel.PolygonPickMode.face)
                    Text(t("edge","Edge")).tag(EditorViewModel.PolygonPickMode.edge)
                    Text(t("vertex","Vertex")).tag(EditorViewModel.PolygonPickMode.vertex)
                }.pickerStyle(.segmented)
                Text(t("tapHint","Tap the control cage to select an element.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(t("distance","Distance"))
                    ExpressionValueField(placeholder: "mm",value: $distance,clamp: nil,identifier: "PolygonEditDistance")
                    Text("mm").foregroundStyle(.secondary)
                }
                HStack {
                    Button(t("extrude","Extrude face")) { faceEdit("topology.extrude") }
                        .disabled(viewModel.polygonFaceSelection == nil).accessibilityIdentifier("PolygonExtrudeFace")
                    Button(t("inset","Inset face")) { faceEdit("topology.inset") }
                        .disabled(viewModel.polygonFaceSelection == nil).accessibilityIdentifier("PolygonInsetFace")
                }.disabled(busy || !viewModel.polygonCageShowControl)
                HStack {
                    Text(t("cutPosition","Cut position"))
                    Slider(value: $fraction,in: 0.05...0.95)
                    Button(t("loopCut","Loop cut")) {
                        if let edge = viewModel.polygonEdgeSelection { run("topology.loopCut",["edgeID":edge.uuidString,"fraction":fraction]) }
                    }.disabled(viewModel.polygonEdgeSelection == nil).accessibilityIdentifier("PolygonLoopCut")
                }.disabled(busy || !viewModel.polygonCageShowControl)
                HStack {
                    Text(t("weldTolerance","Weld tolerance"))
                    ExpressionValueField(placeholder: "mm",value: $tolerance,clamp: nil,identifier: "PolygonWeldTolerance")
                    Text("mm").foregroundStyle(.secondary)
                    Button(t("weld","Weld vertices")) { run("topology.weld",["vertexIDs":viewModel.polygonVertexSelection.map(\.uuidString),"tolerance":tolerance]) }
                        .disabled(viewModel.polygonVertexSelection.count < 2).accessibilityIdentifier("PolygonWeldVertices")
                }.disabled(busy || !viewModel.polygonCageShowControl)
                Text(t("modifiers","Modifiers")).font(.headline)
                HStack {
                    Button(t("subdivision","Subdivision")) { run("modifier.add",["kind":"subdivision","levels":1]) }
                    Button(t("mirror","Mirror")) { run("modifier.add",["kind":"mirror","axis":0,"offset":0]) }
                    Button(t("bevel","Bevel")) {
                        if let edge = viewModel.polygonEdgeSelection { run("modifier.add",["kind":"bevel","edgeID":edge.uuidString,"width":distance]) }
                    }.disabled(viewModel.polygonEdgeSelection == nil)
                }.disabled(busy)
                ForEach(Array(active.definition.modifiers.enumerated()),id: \.element.id) { index,modifier in
                    VStack(alignment: .leading) {
                        HStack {
                            Toggle(modifierTitle(modifier),isOn: Binding(get: { modifier.enabled },set: { run("modifier.update",["modifierID":modifier.id.uuidString,"enabled":$0]) }))
                            Button { run("modifier.move",["modifierID":modifier.id.uuidString,"index":index - 1]) } label: { Image(systemName:"arrow.up") }.disabled(index == 0)
                                .accessibilityLabel(t("moveUp","Move modifier up"))
                            Button { run("modifier.move",["modifierID":modifier.id.uuidString,"index":index + 1]) } label: { Image(systemName:"arrow.down") }.disabled(index + 1 == active.definition.modifiers.count)
                                .accessibilityLabel(t("moveDown","Move modifier down"))
                            Button(role: .destructive) { run("modifier.remove",["modifierID":modifier.id.uuidString]) } label: { Image(systemName:"minus.circle") }
                                .accessibilityLabel(t("removeModifier","Remove modifier"))
                        }
                        modifierParameters(modifier)
                    }.disabled(busy)
                }
                Button(t("finish","Finish editing")) { viewModel.endPolygonCageEditing() }.disabled(busy)
            }
            if viewModel.polygonCageEditingBody != nil, viewModel.activePolygonCage == nil {
                Text(t("captureRequired","Capture this body again after its mesh has changed.")).font(.caption).foregroundStyle(.secondary)
                Button(t("finish","Finish editing")) { viewModel.endPolygonCageEditing() }
            }
            if busy { ProgressView() }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !diagnostic.isEmpty {
                DisclosureGroup(t("details","Details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
            }
        }
        .onChange(of: document.session.changeCount) { _,_ in
            if viewModel.polygonCageEditingBody != nil { viewModel.refreshPolygonCageSelection() }
        }
        .onDisappear { operation?.cancel(); operationID = nil; busy = false }
    }
    private func modifierTitle(_ modifier: CADPolygonMeshDefinition.Modifier) -> String {
        switch modifier.operation {
        case .subdivision: return t("subdivision","Subdivision")
        case .mirror: return t("mirror","Mirror")
        case .bevel: return t("bevel","Bevel")
        }
    }
    @ViewBuilder private func modifierParameters(_ modifier: CADPolygonMeshDefinition.Modifier) -> some View {
        switch modifier.operation {
        case .subdivision(let levels):
            Stepper(t("levels","Levels") + " \(levels)",value: Binding(get: { levels },set: { run("modifier.update",["modifierID":modifier.id.uuidString,"kind":"subdivision","levels":$0]) }),in: 1...2)
        case let .mirror(axis,offset):
            HStack {
                Picker(t("axis","Axis"),selection: Binding(get: { axis },set: { run("modifier.update",["modifierID":modifier.id.uuidString,"kind":"mirror","axis":$0,"offset":offset]) })) {
                    Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2)
                }
                ExpressionValueField(placeholder:"mm",value: Binding(get: { offset },set: { run("modifier.update",["modifierID":modifier.id.uuidString,"kind":"mirror","axis":axis,"offset":$0]) }),clamp: nil,identifier: "PolygonMirrorOffset")
            }
        case let .bevel(edge,width):
            ExpressionValueField(placeholder:"mm",value: Binding(get: { width },set: { run("modifier.update",["modifierID":modifier.id.uuidString,"kind":"bevel","edgeID":edge.uuidString,"width":$0]) }),clamp: nil,identifier:"PolygonBevelWidth")
        }
    }
    private func faceEdit(_ action: String) {
        if let face = viewModel.polygonFaceSelection { run(action,["faceID":face.uuidString,"distance":distance]) }
    }
    private func run(_ action: String, _ fields: [String: Any] = [:]) {
        guard !busy else { return }
        var args = fields
        if args["bodyID"] == nil, let id = viewModel.polygonCageEditingBody { args["bodyID"] = id.raw.uuidString }
        if let digest = viewModel.polygonSelectionDigest { args["cageDigest"] = digest }
        busy = true; message = ""; diagnostic = ""
        let id = UUID(); operationID = id
        operation = Task { @MainActor in
            defer { if operationID == id { busy = false; operation = nil; operationID = nil } }
            let reply = await CADMeshService(document: document).handleAsync(action: action,args: args)
            if reply["mutated"] as? Bool == true {
                let saved = await document.save()
                guard operationID == id, !Task.isCancelled else { return }
                if !saved.succeeded {
                    viewModel.refreshPolygonCageSelection()
                    message = t("saveFailed","The mesh changed but could not be saved. Try saving again.")
                    diagnostic = saved.error ?? ""
                    return
                }
                if action == "topology.create" || action == "topology.capture",
                   let raw = reply["bodyID"] as? String, let id = UUID(uuidString: raw) { viewModel.beginPolygonCageEditing(BodyID(raw:id)) }
                viewModel.refreshPolygonCageSelection()
            }
            guard operationID == id, !Task.isCancelled else { return }
            if reply["ok"] as? Bool == true { message = t("applied","Applied") }
            else { message = t("failed","The mesh could not be updated. The previous shape was kept."); diagnostic = reply["message"] as? String ?? "" }
        }
    }
}
#endif
