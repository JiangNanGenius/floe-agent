// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor struct CADMaterialGraphPanel:View {
    let document:FloeCADDocument
    let bodyID:BodyID
    @State private var graph=CADMaterialNodeGraph.checker()
    @State private var selected:UUID?
    @State private var imageRows:[[String:Any]]=[]
    @State private var message:String?
    @State private var busy=false
    @State private var remoteActive=false
    @State private var remoteRunID=""
    @State private var sourceCount=0
    @State private var generation=UUID()
    @State private var operation:Task<Void,Never>?
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(FloeCADStrings.text("cad.nodes.scope","Opaque linear-color nodes bake into color, roughness and metallic textures. No scripts or displacement."))
                    Picker(FloeCADStrings.text("cad.nodes.node","Node"),selection:$selected) {
                        ForEach(graph.nodes,id:\.id) { node in Text(label(node)).tag(Optional(node.id)) }
                    }
                    Button(FloeCADStrings.text("cad.nodes.add","Add value node")) { let node=CADMaterialNode(operation:.value,value:0.5);graph.nodes.append(node);selected=node.id }.disabled(graph.nodes.count>=32)
                    if let index=graph.nodes.firstIndex(where:{$0.id==selected}) {
                        Picker(FloeCADStrings.text("cad.nodes.operation","Operation"),selection:Binding(get:{graph.nodes[index].operation},set:{ value in
                            graph.nodes[index].operation=value;graph.nodes[index].inputs=[];graph.nodes[index].value=0.5;graph.nodes[index].color=SIMD4(0.5,0.5,0.5,1);graph.nodes[index].factor=0.5;graph.nodes[index].frequency=8
                            if [.mix,.multiply,.checker].contains(value) { graph.nodes[index].inputs=Array(graph.nodes.filter{$0.id != selected}.prefix(2).map(\.id)) }
                        })) {
                            ForEach([CADMaterialNode.Operation.value,.color,.image,.mix,.multiply,.checker],id:\.rawValue) { Text($0.rawValue).tag($0) }
                        }
                        if [.mix,.multiply,.checker].contains(graph.nodes[index].operation) {
                            ForEach(0..<2,id:\.self) { edge in
                                Picker(FloeCADStrings.text("cad.nodes.input","Input")+" \(edge+1)",selection:Binding(get:{graph.nodes[index].inputs.count>edge ? graph.nodes[index].inputs[edge]:nil},set:{ id in
                                    guard let id else { return };while graph.nodes[index].inputs.count<=edge { graph.nodes[index].inputs.append(id) };graph.nodes[index].inputs[edge]=id
                                })) { Text("—").tag(Optional<UUID>.none);ForEach(graph.nodes.filter{$0.id != selected},id:\.id) { Text(label($0)).tag(Optional($0.id)) } }
                            }
                        }
                        if graph.nodes[index].operation == .value { numeric(index,\.value,"cad.nodes.value","Value") }
                        if graph.nodes[index].operation == .mix { numeric(index,\.factor,"cad.nodes.mix","Mix factor") }
                        if graph.nodes[index].operation == .color {
                            ColorPicker(FloeCADStrings.text("cad.nodes.op.color","Color"),selection:Binding(get:{
                                let c=graph.nodes[index].color ?? SIMD4(0.5,0.5,0.5,1);return Color(red:c.x,green:c.y,blue:c.z)
                            },set:{ color in
                                var r:CGFloat=0;var g:CGFloat=0;var b:CGFloat=0;var a:CGFloat=0
                                if UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) { graph.nodes[index].color=SIMD4(Double(r),Double(g),Double(b),1) }
                            }),supportsOpacity:false).accessibilityIdentifier("CADMaterialNodeColor")
                        }
                        if graph.nodes[index].operation == .checker { Stepper(FloeCADStrings.text("cad.nodes.frequency","Checker frequency")+" \(graph.nodes[index].frequency ?? 8)",value:Binding(get:{graph.nodes[index].frequency ?? 8},set:{graph.nodes[index].frequency=$0}),in:1...64) }
                        if graph.nodes[index].operation == .image {
                            Picker(FloeCADStrings.text("cad.nodes.image","Existing image"),selection:Binding(get:{graph.nodes[index].imageID?.uuidString ?? ""},set:{id in
                                graph.nodes[index].imageID=UUID(uuidString:id);graph.nodes[index].imageSHA256=imageRows.first{$0["id"] as? String==id}?["sha256"] as? String
                            })) { Text("—").tag("");ForEach(imageRows.compactMap{$0["id"] as? String},id:\.self) { id in Text(imageRows.first{$0["id"] as? String==id}?["name"] as? String ?? FloeCADStrings.text("cad.nodes.image","Existing image")).tag(id) } }
                        }
                        Button(FloeCADStrings.text("cad.nodes.remove","Remove node")) { graph.nodes.remove(at:index);selected=graph.nodes.first?.id }.disabled(graph.nodes.count<=1 || graph.nodes.contains(where:{$0.inputs.contains(graph.nodes[index].id)}) || graph.outputs.values.contains(graph.nodes[index].id))
                    }
                    ForEach(["baseColor","roughness","metallic"],id:\.self) { slot in
                        Picker(slotTitle(slot),selection:Binding(get:{graph.outputs[slot]},set:{graph.outputs[slot]=$0})) {
                            Text("—").tag(Optional<UUID>.none);ForEach(graph.nodes,id:\.id) { Text(label($0)).tag(Optional($0.id)) }
                        }
                    }
                    Text(FloeCADStrings.text("cad.nodes.mapping","Choose UVs or a projected mapping in the inspector. Unlinked outputs keep their baked textures.")).font(.caption).foregroundStyle(.secondary)
                    Picker(FloeCADStrings.text("cad.nodes.resolution","Resolution"),selection:$graph.resolution) { ForEach([64,128,256],id:\.self) { Text(String($0)).tag($0) } }
                    Button(FloeCADStrings.text("cad.nodes.bake","Bake and apply")) { bake() }.accessibilityIdentifier("CADMaterialGraphBake")
                }.disabled(busy || remoteActive || document.isReadOnly)
                if busy || remoteActive {
                    ProgressView()
                    Button(FloeCADStrings.text("cad.nodes.cancel","Cancel bake")) {
                        if let operation { operation.cancel() } else { _ = CADMaterialGraphService(document:document).control("graph.cancel",["run_id":remoteRunID]) }
                    }.accessibilityIdentifier("CADMaterialGraphCancel")
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button(FloeCADStrings.text("cad.nodes.reload","Reload saved graph")) { load() }.disabled(busy || remoteActive)
            }.navigationTitle(FloeCADStrings.text("cad.nodes.title","Material nodes"))
        }.onAppear { generation=UUID();load() }
        .onReceive(NotificationCenter.default.publisher(for:CADMaterialGraphService.stateDidChange,object:document)) { _ in status() }
        .onDisappear { generation=UUID();operation=nil;busy=false }
        .accessibilityIdentifier("CADMaterialGraphPanel")
    }
    private func label(_ node:CADMaterialNode) -> String { node.operation.title+" \((graph.nodes.firstIndex(where:{$0.id==node.id}) ?? 0)+1)" }
    private func slotTitle(_ slot:String) -> String {
        switch slot {
        case "baseColor":FloeCADStrings.text("cad.nodes.outputColor","Color output")
        case "roughness":FloeCADStrings.text("cad.nodes.outputRoughness","Roughness output")
        default:FloeCADStrings.text("cad.nodes.outputMetallic","Metallic output")
        }
    }
    private func numeric(_ index:Int,_ path:WritableKeyPath<CADMaterialNode,Double?>,_ key:String,_ fallback:String) -> some View {
        VStack(alignment:.leading) { Text(FloeCADStrings.text(key,fallback));Slider(value:Binding(get:{graph.nodes[index][keyPath:path] ?? 0.5},set:{graph.nodes[index][keyPath:path]=$0}),in:0...1) }
    }
    private func status() {
        let row=CADMaterialGraphService(document:document).control("graph.status",[:]);remoteActive=row["active"] as? Bool ?? false;remoteRunID=row["run_id"] as? String ?? ""
    }
    private func load() {
        sourceCount=document.liveChangeCount;message=nil
        let row=CADMaterialGraphService(document:document).control("graph.get",["body_id":bodyID.raw.uuidString]);imageRows=row["inputs"] as? [[String:Any]] ?? []
        graph=document.session.document.body(with:bodyID)?.material?.nodeGraph ?? .checker();selected=graph.nodes.first?.id;status()
    }
    private func bake() {
        guard !busy else { return };message=nil
        do {
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)) as! [String:Any]
            for key in ["images","recipeSHA256","bakedSHA256"] { raw[key]=nil }
            busy=true;let owner=generation
            operation=Task { @MainActor in
                defer { if generation==owner { busy=false;operation=nil;status() } }
                let reply=await CADMaterialService(document:document).handleAsync(action:"graph.bake",args:["body_id":bodyID.raw.uuidString,"expected_change_count":sourceCount,"graph":raw])
                guard reply["ok"] as? Bool==true else { if generation==owner { message=reply["message"] as? String };return }
                let command=document.pendingOwnedCommand
                if Task.isCancelled { if let command { _ = document.rollbackOwnedCommand(command) };return }
                let saved=await document.save()
                if !saved.succeeded { if let command { _ = document.rollbackOwnedCommand(command) };if generation==owner { message=saved.error };return }
                if generation==owner,!document.isClosed { load() }
            }
        } catch { message=error.localizedDescription }
    }
}
private extension CADMaterialNode.Operation {
    var title:String {
        switch self {
        case .value:FloeCADStrings.text("cad.nodes.op.value","Value")
        case .color:FloeCADStrings.text("cad.nodes.op.color","Color")
        case .image:FloeCADStrings.text("cad.nodes.op.image","Image")
        case .mix:FloeCADStrings.text("cad.nodes.op.mix","Mix")
        case .multiply:FloeCADStrings.text("cad.nodes.op.multiply","Multiply")
        case .checker:FloeCADStrings.text("cad.nodes.op.checker","Checker")
        }
    }
}
#endif
