// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import simd

@MainActor struct CADRiggingPanel: View {
    let document:FloeCADDocument
    @State private var candidates:[[String:Any]]=[]
    @State private var bodyID="",jointID="",vertexID="",jointName="Joint",duration="2"
    @State private var x="0",y="0",z="0",angle="0",keyTime="0",dx="0",dy="0",dz="0"
    @State private var jointWeights:[UUID:String]=[:],morphWeights:[UUID:String]=[:]
    @State private var record:CADRigRecord?,vertices:[String]=[]
    @State private var message:String?,busy=false
    @State private var export:GLBFileDocument?,showExport=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(FloeCADStrings.text("cad.rig.scope","Bind one polygon cage without enabled modifiers. CAD solids, IK and FBX authoring are outside this scope.")).font(.callout).foregroundStyle(.secondary)
            Picker(FloeCADStrings.text("cad.rig.mesh","Polygon mesh"),selection:$bodyID) {
                Text("—").tag("")
                ForEach(candidates.compactMap { $0["body_id"] as? String },id:\.self) { id in Text(candidates.first { $0["body_id"] as? String==id }?["name"] as? String ?? id).tag(id) }
            }
            field("cad.rig.duration","Duration (s)",$duration)
            Button(FloeCADStrings.text("cad.rig.bind","Bind / replace rig")) { if let seconds=Double(duration) { run("rig.bind",["body_id":bodyID,"duration":seconds]) } }.disabled(bodyID.isEmpty).accessibilityIdentifier("CADRigBind")
            if let record {
                Picker(FloeCADStrings.text("cad.rig.joint","Joint"),selection:$jointID) { ForEach(record.joints,id:\.id) { Text($0.name).tag($0.id.uuidString) } }
                TextField(FloeCADStrings.text("cad.rig.name","Name"),text:$jointName).textFieldStyle(.roundedBorder)
                field("cad.rig.x","Local X (mm)",$x);field("cad.rig.y","Local Y (mm)",$y);field("cad.rig.z","Local Z (mm)",$z)
                field("cad.rig.angle","Rotate local Z by (°)",$angle)
                HStack {
                    Button(FloeCADStrings.text("cad.rig.addJoint","Add child")) { poseCommand("rig.joint.add") }
                    Button(FloeCADStrings.text("cad.rig.editBind","Set bind pose")) { poseCommand("rig.joint.bind") }
                    Button(FloeCADStrings.text("cad.rig.applyPose","Apply pose")) { poseCommand("rig.pose") }.accessibilityIdentifier("CADRigApplyPose")
                }
                Picker(FloeCADStrings.text("cad.rig.vertex","Control vertex"),selection:$vertexID) { ForEach(vertices,id:\.self) { id in Text(String(id.prefix(8))).tag(id) } }
                Text(FloeCADStrings.text("cad.rig.weightScope","Enter up to four positive influences. Apply normalizes their sum.")).font(.caption)
                ForEach(record.joints,id:\.id) { joint in
                    HStack { Text(joint.name);Spacer();TextField("0",text:Binding(get:{jointWeights[joint.id] ?? "0"},set:{jointWeights[joint.id]=$0})).textFieldStyle(.roundedBorder).frame(width:110) }.frame(minHeight:44)
                }
                Button(FloeCADStrings.text("cad.rig.applyWeights","Apply weights")) {
                    var rows:[[String:Any]]=[]
                    for joint in record.joints { guard let value=Double(jointWeights[joint.id] ?? "0"),value.isFinite,value>=0 else { message=CADRigError.invalid.localizedDescription;return };if value>0 { rows.append(["joint_id":joint.id.uuidString,"weight":value]) } }
                    run("rig.weight",["vertex_id":vertexID,"influences":rows])
                }.accessibilityIdentifier("CADRigWeights")
                field("cad.rig.dx","Shape delta X (mm)",$dx);field("cad.rig.dy","Shape delta Y (mm)",$dy);field("cad.rig.dz","Shape delta Z (mm)",$dz)
                Button(FloeCADStrings.text("cad.rig.addShape","Add shape key for vertex")) {
                    guard let a=Double(dx),let b=Double(dy),let c=Double(dz) else { return }
                    run("rig.morph",["name":jointName,"deltas":[["vertex_id":vertexID,"delta":[a,b,c]]],"weight":0.0])
                }
                ForEach(record.morphs,id:\.id) { morph in
                    HStack {
                        Text(morph.name)
                        TextField("0",text:Binding(get:{morphWeights[morph.id] ?? String(morph.weight)},set:{morphWeights[morph.id]=$0})).textFieldStyle(.roundedBorder).frame(width:90)
                        Button(FloeCADStrings.text("cad.rig.applyShape","Apply shape")) { if let value=Double(morphWeights[morph.id] ?? String(morph.weight)) { run("rig.morph.weight",["morph_id":morph.id.uuidString,"weight":value]) } }
                    }.frame(minHeight:44)
                }
                field("cad.rig.time","Key time (s)",$keyTime)
                Button(FloeCADStrings.text("cad.rig.capture","Capture pose key")) { if let time=Double(keyTime) { run("rig.key",["time":time]) } }.accessibilityIdentifier("CADRigCaptureKey")
                Text(record.keys.map { String(format:"%.2f",$0.time) }.joined(separator:" · ")).font(.caption).monospacedDigit()
                HStack {
                    Button(FloeCADStrings.text("cad.rig.clearKeys","Clear keys")) { run("rig.keys.clear",[:]) }
                    Button(FloeCADStrings.text("cad.rig.createClip","Create / update clip")) { run("rig.clip",["name":jointName]) }.accessibilityIdentifier("CADRigCreateClip")
                }
                Text(FloeCADStrings.text("cad.rig.timeline","Replay and frame/video export use the Present timeline. GLB includes this part’s authored skin, shape keys and animation.")).font(.caption).foregroundStyle(.secondary)
                Button(FloeCADStrings.text("cad.rig.export","Export GLB animation")) {
                    do { export=GLBFileDocument(data:try document.riggedGLB());showExport=true } catch { message=error.localizedDescription }
                }.accessibilityIdentifier("CADRigExport")
                Button(FloeCADStrings.text("cad.rig.remove","Remove rig")) { run("rig.remove",[:]) }
            }
            if busy { ProgressView() };if let message { Text(message).font(.callout).foregroundStyle(.red) }
        }.buttonStyle(.bordered).disabled(busy || document.isReadOnly)
        .onAppear { reload() }
        .onChange(of:document.liveChangeCount) { _,_ in if !busy { reload() } }
        .onChange(of:jointID) { _,_ in loadPose() }
        .onChange(of:vertexID) { _,_ in loadWeights() }
        .fileExporter(isPresented:$showExport,document:export,contentType:UTType(filenameExtension:"glb") ?? .data,defaultFilename:"rig-animation") { result in if case .failure(let error)=result { message=error.localizedDescription } }
        .accessibilityIdentifier("CADRigPanel")
    }
    private func field(_ key:String,_ fallback:String,_ value:Binding<String>) -> some View {
        HStack { Text(FloeCADStrings.text(key,fallback));Spacer();TextField("",text:value).textFieldStyle(.roundedBorder).frame(width:130) }.frame(minHeight:44)
    }
    private func reload() {
        let reply=CADRiggingService(document:document).handle(action:"rig.get",args:[:]);candidates=reply["candidates"] as? [[String:Any]] ?? []
        if let row=reply["record"],let bytes=try? JSONSerialization.data(withJSONObject:row),let value=try? JSONDecoder().decode(CADRigRecord.self,from:bytes) {
            record=value;bodyID=value.bodyID.uuidString;duration=String(value.duration)
            if !value.joints.contains(where: { $0.id.uuidString==jointID }) { jointID=value.joints.first?.id.uuidString ?? "" }
            vertices=(reply["vertices"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }
            if !vertices.contains(vertexID) { vertexID=vertices.first ?? "" }
            for morph in value.morphs { morphWeights[morph.id]=String(morph.weight) }
            loadPose();loadWeights()
        } else { record=nil;vertices=[] }
        if reply["ok"] as? Bool != true || reply["state"] as? String == "stale" { message=reply["message"] as? String ?? CADRigError.stale.localizedDescription }
    }
    private func loadPose() {
        guard let record,let index=record.joints.firstIndex(where: { $0.id.uuidString==jointID }) else { return }
        let pose=record.poses[index];x=String(pose.translation.x);y=String(pose.translation.y);z=String(pose.translation.z)
        angle="0";jointName=record.joints[index].name
    }
    private func loadWeights() {
        jointWeights=[:];guard let row=record?.weights.first(where: { $0.vertexID.uuidString==vertexID }) else { return }
        for value in row.influences { jointWeights[value.jointID]=String(value.weight) }
    }
    private func poseCommand(_ action:String) {
        guard let a=Double(x),let b=Double(y),let c=Double(z),let degrees=Double(angle),[a,b,c,degrees].allSatisfy(\.isFinite) else { message=CADRigError.invalid.localizedDescription;return }
        let delta=simd_quatd(angle:degrees * .pi / 180,axis:SIMD3(0,0,1))
        let base=record.flatMap { r in r.joints.firstIndex(where: { $0.id.uuidString==jointID }).map { simd_quatd(vector:r.poses[$0].rotation) } }
        let q=(action=="rig.joint.add" ? delta : ((base ?? simd_quatd(angle:0,axis:SIMD3(0,0,1))) * delta)).vector
        var args:[String:Any]=["joint_id":jointID,"name":jointName,"translation":[a,b,c],"rotation":[q.x,q.y,q.z,q.w]]
        if action=="rig.joint.add" { args["parent_id"]=jointID }
        run(action,args)
    }
    private func run(_ action:String,_ args:[String:Any]) {
        guard !busy,!document.isClosed else { return };busy=true;message=nil
        Task { @MainActor in
            defer { busy=false }
            var args=args;args["expected_change_count"]=document.liveChangeCount
            let reply=CADViewOverlayService(document:document).handle(action:action,args:args)
            guard reply["ok"] as? Bool==true else { message=reply["message"] as? String;return }
            if reply["mutated"] as? Bool==true {
                let command=document.pendingOwnedCommand
                let saved=await document.save()
                guard saved.succeeded else { if let command { _ = document.rollbackOwnedCommand(command) };message=saved.error;return }
            }
            if !document.isClosed { reload() }
        }
    }
}
#endif
