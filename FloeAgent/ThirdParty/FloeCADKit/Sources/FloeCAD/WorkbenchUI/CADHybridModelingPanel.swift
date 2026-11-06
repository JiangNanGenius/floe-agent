// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

struct CADHybridModelingPanel:View {
    let document:FloeCADDocument
    @Bindable var viewModel:EditorViewModel
    let selectedBodyIDs:[UUID]
    @State private var target:UUID?
    @State private var toolBody:UUID?
    @State private var kind="hole"
    @State private var shape="cylinder"
    @State private var centerX="0"
    @State private var centerY="0"
    @State private var centerZ="0"
    @State private var radius="2"
    @State private var depth="12"
    @State private var width="4"
    @State private var length="4"
    @State private var height="12"
    @State private var axis=CADPanelAxisPreset.zPlus
    @State private var operationID:UUID?
    @State private var allowMeshResult=false
    @State private var discardOutputUV=false
    @State private var tolerance="0.00001"
    @State private var outcome:[String:Any]=[:]
    @State private var pending:[String:Any]?
    @State private var task:Task<Void,Never>?
    @State private var runID:UUID?
    @State private var busy=false
    private var targetID:UUID? {selectedBodyIDs.count==1 ? selectedBodyIDs.first:target}
    private var current:CADHybridFeatureDefinition? {
        guard let targetID else {return nil}
        let id=BodyID(raw:targetID),graph=document.session.document.features
        guard let writer=document.session.lastBodyWriters[id],let node=graph.nodes.first(where:{$0.id==writer && !$0.suppressed}),
              case let .hybrid(definition,_)=node.kind else {return nil};return definition
    }
    private func t(_ key:String,_ en:String)->String {FloeCADStrings.text("cad.mesh.hybrid."+key,en)}
    var body:some View {
        PanelSection(title:t("title","Hybrid modeling")) {
            Text(t("scope","Add editable holes, cuts and bosses to a closed mesh, or combine it with a solid. The original bodies are kept."))
                .font(.caption).foregroundStyle(.secondary)
            if selectedBodyIDs.count>1 {
                Picker(t("target","Target"),selection:$target) {
                    Text(t("chooseTarget","Choose target…")).tag(UUID?.none)
                    ForEach(document.panelBodyOptions.filter{selectedBodyIDs.contains($0.id)}) {body in Text(body.name).tag(UUID?.some(body.id))}
                }.accessibilityIdentifier("CADHybridTarget")
            }
            Picker(t("kind","Feature"),selection:$kind) {
                Text(t("hole","Hole")).tag("hole");Text(t("cut","Cut")).tag("cut");Text(t("boss","Boss")).tag("boss")
                Text(t("union","Union")).tag("union");Text(t("subtract","Subtract")).tag("subtract");Text(t("intersect","Intersect")).tag("intersect")
            }
            Picker(t("tool","Tool"),selection:$shape) {
                Text(t("cylinder","Cylinder")).tag("cylinder");Text(t("box","Box")).tag("box");Text(t("bodyTool","Selected body")).tag("body")
            }
            if shape=="body" {
                Picker(t("bodyTool","Selected body"),selection:$toolBody) {
                    Text(t("chooseTool","Choose tool…")).tag(UUID?.none)
                    ForEach(document.panelBodyOptions.filter{selectedBodyIDs.contains($0.id) && $0.id != targetID}) {body in Text(body.name).tag(UUID?.some(body.id))}
                }.accessibilityIdentifier("CADHybridTool")
            } else {
                HStack {
                    CADPanelNumberField(title:t("centerX","Centre X (mm)"),text:$centerX)
                    CADPanelNumberField(title:t("centerY","Centre Y (mm)"),text:$centerY)
                    CADPanelNumberField(title:t("centerZ","Centre Z (mm)"),text:$centerZ)
                }
                if shape=="cylinder" {
                    HStack {
                        CADPanelNumberField(title:t("radius","Radius (mm)"),text:$radius)
                        CADPanelNumberField(title:t("depth","Depth (mm)"),text:$depth)
                    }
                    Picker(t("axis","Axis"),selection:$axis) {
                        ForEach(CADPanelAxisPreset.allCases) {value in Text(value.label).tag(value)}
                    }
                } else {
                    HStack {
                        CADPanelNumberField(title:t("width","Width (mm)"),text:$width)
                        CADPanelNumberField(title:t("length","Length (mm)"),text:$length)
                        CADPanelNumberField(title:t("height","Height (mm)"),text:$height)
                    }
                }
            }
            Toggle(t("allowMesh","Allow a derived mesh from exact solid inputs"),isOn:$allowMeshResult)
            Toggle(t("discardUV","Allow an untextured result; keep original textures"),isOn:$discardOutputUV)
            if let current {
                Picker(t("storedFeature","Stored feature"),selection:$operationID) {
                    Text(t("newFeature","New feature")).tag(UUID?.none)
                    ForEach(Array(current.operations.enumerated()),id:\.element.id) {index,operation in
                        Text("\(index+1) · \(operationLabel(operation.kind))").tag(UUID?.some(operation.id))
                    }
                }.accessibilityIdentifier("CADHybridStoredFeature")
            }
            PanelActionGrid {
                PanelActionButton(title:FloeCADStrings.label("cad.workbench.mesh.preview","Preview"),systemImage:"eye",disabled:busy || targetID==nil) {previewFeature()}
                    .accessibilityIdentifier("CADHybridPreview")
                if let current,operationID != nil,current.operations.count>1 {
                    PanelActionButton(title:FloeCADStrings.label("cad.ui.common.delete","Delete"),systemImage:"trash",disabled:busy) {previewRemoval()}
                        .accessibilityIdentifier("CADHybridRemove")
                }
            }
            if let current {Text(FloeCADStrings.format("cad.mesh.hybrid.featureCount","%@ editable features · original mesh kept",current.operations.count)).font(.caption).foregroundStyle(.secondary)}
        }
        PanelSection(title:FloeCADStrings.text("cad.mesh.faceted.title","Mesh / sheets to solid")) {
            Text(FloeCADStrings.text("cad.mesh.faceted.scope","Convert a small closed mesh or sew exact sheets into a solid. Complex scans may need simplification or manual reconstruction."))
                .font(.caption).foregroundStyle(.secondary)
            CADPanelNumberField(title:FloeCADStrings.text("cad.mesh.faceted.tolerance","Sewing tolerance (mm)"),text:$tolerance)
            Text(FloeCADStrings.text("cad.mesh.recognition.scope","Simple recognition currently supports boxes aligned to the model axes."))
                .font(.caption).foregroundStyle(.secondary)
            PanelActionGrid {
                PanelActionButton(title:FloeCADStrings.label("cad.mesh.faceted.convert","Preview solid"),systemImage:"cube",disabled:busy || selectedBodyIDs.isEmpty) {previewConversion()}
                    .accessibilityIdentifier("CADFacetedConvert")
                PanelActionButton(title:FloeCADStrings.label("cad.mesh.recognition.inspect","Recognize simple features"),systemImage:"viewfinder",disabled:busy || selectedBodyIDs.count != 1) {recognize()}
                    .accessibilityIdentifier("CADMeshRecognize")
                if (outcome["candidates"] as? [[String:Any]])?.isEmpty==false {
                    PanelActionButton(title:FloeCADStrings.label("cad.mesh.recognition.create","Preview recognized box"),systemImage:"shippingbox",disabled:busy || selectedBodyIDs.count != 1) {previewRecognizedBox()}
                        .accessibilityIdentifier("CADMeshRecognizeCreate")
                }
            }
            if let pending,let mesh=pending["mesh"] as? [String:Any] {
                CADTransientPreviewView(mesh:mesh)
                PanelActionButton(title:FloeCADStrings.label("cad.workbench.mesh.apply","Apply"),systemImage:"checkmark.circle",disabled:busy) {apply(pending)}
                    .accessibilityIdentifier("CADHybridApply")
            }
            if let triangles=outcome["triangleCount"] as? Int {Text("\(triangles) △").font(.caption)}
            if let volume=outcome["volumeMM3"] as? Double {Text(FloeCADStrings.format("cad.mesh.hybrid.volume","Volume: %@ mm³",String(format:"%.6g",volume))).font(.caption)}
            if let message=outcome["message"] as? String {
                DisclosureGroup(FloeCADStrings.text("cad.ui.common.details","Details")) {Text(message).font(.caption).textSelection(.enabled)}
            }
            if busy {
                HStack {ProgressView().controlSize(.small);PanelActionButton(title:FloeCADStrings.label("cad.ui.common.cancel","Cancel"),systemImage:"xmark.circle") {cancel()}}
            }
        }
        .accessibilityIdentifier("CADHybridPanel")
        .onDisappear {cancel()}
        .onChange(of:selectedBodyIDs) {_,_ in cancel();outcome=[:];operationID=nil;target=nil;toolBody=nil;populateCentre()}
        .onChange(of:operationID) {_,_ in pending=nil;populateFeature()}
        .onChange(of:allowMeshResult) {_,_ in pending=nil}
        .onChange(of:discardOutputUV) {_,_ in pending=nil}
        .onChange(of:centerX) {_,_ in pending=nil}.onChange(of:centerY) {_,_ in pending=nil}.onChange(of:centerZ) {_,_ in pending=nil}
        .onChange(of:radius) {_,_ in pending=nil}.onChange(of:depth) {_,_ in pending=nil}
        .onChange(of:width) {_,_ in pending=nil}.onChange(of:length) {_,_ in pending=nil}.onChange(of:height) {_,_ in pending=nil}
        .onChange(of:kind) {_,_ in pending=nil}.onChange(of:shape) {_,_ in pending=nil}.onChange(of:axis) {_,_ in pending=nil}
        .onChange(of:target) {_,_ in pending=nil}.onChange(of:toolBody) {_,_ in pending=nil}.onChange(of:tolerance) {_,_ in pending=nil}
    }
    private func operationLabel(_ kind:CADHybridOperation.Kind)->String {t(kind.rawValue,kind.rawValue.capitalized)}
    private func populateCentre() {
        guard let selected=selectedBodyIDs.count==1 ? selectedBodyIDs.first:nil,
              let body=document.session.document.body(with:BodyID(raw:selected)),let first=body.render.positions.first else {return}
        var low=body.transform.applying(to:SIMD3<Double>(first)),high=low
        for p in body.render.positions {let world=body.transform.applying(to:SIMD3<Double>(p));low=simd_min(low,world);high=simd_max(high,world)}
        let center=(low+high)/2;centerX=String(format:"%.6g",center.x);centerY=String(format:"%.6g",center.y);centerZ=String(format:"%.6g",center.z)
        depth=String(format:"%.6g",high.z-low.z+2)
    }
    private func populateFeature() {
        guard let id=operationID,let operation=current?.operations.first(where:{$0.id==id}) else {return}
        kind=operation.kind.rawValue
        func center(_ c:SIMD3<Double>){centerX=String(c.x);centerY=String(c.y);centerZ=String(c.z)}
        switch operation.tool {
        case let .cylinder(r,d,c,a,_):shape="cylinder";radius=String(r);depth=String(d);center(c)
            if let preset=CADPanelAxisPreset.allCases.first(where:{$0.vector==a}) {axis=preset}
        case let .box(size,c):shape="box";width=String(size.x);length=String(size.y);height=String(size.z);center(c)
        case let .body(source):shape="body";toolBody=source.sourceBodyID.raw
        }
    }
    private func featureArgs() -> [String:Any]? {
        guard let targetID else {return nil}
        var args:[String:Any]=["bodyID":targetID.uuidString,"kind":kind,"shape":shape,"preview":true,
            "allowMeshResult":allowMeshResult,"discardOutputUV":discardOutputUV]
        if let current {args["definitionDigest"]=current.digest}
        if let operationID {args["operationID"]=operationID.uuidString}
        if shape=="body" {guard let toolBody else {return nil};args["toolBodyID"]=toolBody.uuidString}
        else {
            guard let x=Double(centerX),let y=Double(centerY),let z=Double(centerZ),[x,y,z].allSatisfy(\.isFinite) else {return nil}
            args["center"]=[x,y,z]
            if shape=="box" {guard let w=Double(width),let l=Double(length),let h=Double(height) else {return nil};args["size"]=[w,l,h]}
            else {guard let r=Double(radius),let d=Double(depth) else {return nil};args["radius"]=r;args["depth"]=d;args["axis"]=[axis.vector.x,axis.vector.y,axis.vector.z]}
        }
        return args
    }
    private func previewFeature() {
        guard let args=featureArgs() else {outcome=["message":t("invalid","Choose the target and enter finite tool dimensions.")];return}
        preview(action:operationID==nil ? "hybrid.add":"hybrid.update",args:args)
    }
    private func previewRemoval() {
        guard let targetID,let operationID,let current else {return}
        preview(action:"hybrid.remove",args:["bodyID":targetID.uuidString,"operationID":operationID.uuidString,"definitionDigest":current.digest,"preview":true])
    }
    private func previewConversion() {
        guard let tolerance=Double(tolerance),tolerance.isFinite else {return}
        preview(action:"faceted.convert",args:["bodyIDs":selectedBodyIDs.map(\.uuidString),"tolerance":tolerance,"discardOutputUV":discardOutputUV,"preview":true])
    }
    private func recognize() {
        guard let id=selectedBodyIDs.count==1 ? selectedBodyIDs.first:nil else {return}
        start {await CADMeshService(document:document).handleAsync(action:"recognition.inspect",args:["bodyID":id.uuidString])}
    }
    private func previewRecognizedBox() {
        guard let id=selectedBodyIDs.count==1 ? selectedBodyIDs.first:nil,let digest=outcome["sourceSHA256"] as? String else {return}
        preview(action:"recognition.create",args:["bodyID":id.uuidString,"sourceSHA256":digest,"candidate":"axis-aligned-box","discardOutputUV":discardOutputUV,"preview":true])
    }
    private func preview(action:String,args:[String:Any]) {
        start {var result=await CADMeshService(document:document).handleAsync(action:action,args:args)
            if result["ok"] as? Bool==true {result["applyAction"]=action;result["applyArgs"]=args};return result}
    }
    private func apply(_ preview:[String:Any]) {
        guard let action=preview["applyAction"] as? String,var args=preview["applyArgs"] as? [String:Any] else {return}
        args["preview"]=false;args["expectedPreviewHash"]=preview["previewHash"];args["expectedChangeCount"]=preview["previewChangeCount"];args["expectedRevision"]=preview["previewRevision"]
        start {await CADMeshService(document:document).handleAsync(action:action,args:args)}
    }
    private func start(_ work:@escaping @MainActor () async -> [String:Any]) {
        task?.cancel();pending=nil;let id=UUID();runID=id;busy=true
        task=Task {@MainActor in let result=await work();guard runID==id,!Task.isCancelled,!document.isClosed else {return}
            busy=false;outcome=result;if result["preview"] as? Bool==true {pending=result}
            if result["mutated"] as? Bool==true,let raw=result["bodyID"] as? String,let id=UUID(uuidString:raw) {viewModel.selection=[BodyID(raw:id)]}
        }
    }
    private func cancel(){task?.cancel();task=nil;runID=nil;busy=false;pending=nil;_=CADMeshService.cancelActiveOperation(for:document)}
}
#endif
