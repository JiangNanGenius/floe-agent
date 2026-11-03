// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

@MainActor public final class CADRiggingService {
    public static let reads: Set<String> = ["rig.get"]
    public static let mutations: Set<String> = ["rig.bind","rig.joint.add","rig.joint.bind","rig.joint.remove","rig.pose","rig.weight","rig.morph","rig.morph.weight","rig.key","rig.keys.clear","rig.clip","rig.remove"]
    let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document=document }
    public func handle(action: String,args: [String:Any]) -> [String:Any] {
        do {
            guard !document.isClosed else { throw CADRigError.stale }
            if action == "rig.get" { return try get() }
            guard Self.mutations.contains(action), !document.isReadOnly, document.session.writeBlock == nil else { throw CADRigError.unsupported }
            guard !Task.isCancelled else { throw CADRigError.cancelled }
            if let raw=args["expected_change_count"] { guard try number(raw) == Double(document.liveChangeCount) else { throw CADRigError.stale } }
            let before=try CADRigCodec.read(document.session.document.sceneSettingsData)
            var animation=document.animationLoadState();guard animation.issues.isEmpty else { throw CADRigError.invalid }
            if action == "rig.remove" {
                guard let old=before else { return ["ok":true,"mutated":false] }
                animation.animation.clips.removeAll { $0.id == old.clipID && $0.rigID == old.id }
                try commit(nil,animation:animation.animation);return ["ok":true,"mutated":true]
            }
            var record: CADRigRecord
            if action == "rig.bind" {
                let bodyID=try uuid(args["body_id"]), source=try source(bodyID)
                let root=CADRigJoint(name:FloeCADStrings.text("cad.rig.root","Root"),rest:CADRigPose())
                record=CADRigRecord(bodyID:bodyID,featureID:source.node.id.raw,sourceSHA256:source.definition.digest,
                    joints:[root],poses:[root.rest],weights:source.definition.cage.vertices.map { CADRigWeight(vertexID:$0.id,influences:[CADRigInfluence(jointID:root.id,weight:1)]) })
                record.duration=try optional(args["duration"],2)
                if let old=before { animation.animation.clips.removeAll { $0.id == old.clipID && $0.rigID == old.id } }
            } else {
                guard let stored=before else { throw CADRigError.invalid };record=stored;_ = try playback(stored)
                switch action {
                case "rig.joint.add":
                    guard record.keys.isEmpty, record.joints.count < 16 else { throw CADRigError.invalid }
                    let parent:UUID? = try args["parent_id"].map { try uuid($0) } ?? record.joints.first?.id
                    if let parent, !record.joints.contains(where: { $0.id == parent }) { throw CADRigError.invalid }
                    let rest=try pose(args),joint=CADRigJoint(name:try name(args["name"],fallback:"Joint"),parent:parent,rest:rest)
                    record.joints.append(joint);record.poses.append(rest)
                case "rig.joint.bind":
                    guard record.keys.isEmpty else { throw CADRigError.invalid }
                    let index=try jointIndex(record,args);record.joints[index].rest=try pose(args);record.poses[index]=record.joints[index].rest
                case "rig.joint.remove":
                    let index=try jointIndex(record,args),id=record.joints[index].id
                    guard record.keys.isEmpty,record.joints.count>1,!record.joints.contains(where: { $0.parent == id }),
                          !record.weights.contains(where: { $0.influences.contains(where: { $0.jointID == id }) }) else { throw CADRigError.invalid }
                    record.joints.remove(at:index);record.poses.remove(at:index)
                case "rig.pose": record.poses[try jointIndex(record,args)]=try pose(args)
                case "rig.weight":
                    let id=try uuid(args["vertex_id"])
                    guard let index=record.weights.firstIndex(where: { $0.vertexID == id }),let rows=args["influences"] as? [[String:Any]],(1...4).contains(rows.count) else { throw CADRigError.invalid }
                    var influences=try rows.map { CADRigInfluence(jointID:try uuid($0["joint_id"]),weight:try number($0["weight"])) }
                    guard influences.allSatisfy({ $0.weight>0 }),Set(influences.map(\.jointID)).count==influences.count else { throw CADRigError.invalid }
                    let sum=influences.reduce(0) { $0+$1.weight };guard sum.isFinite && sum>0 else { throw CADRigError.invalid }
                    for i in influences.indices { influences[i].weight /= sum }
                    influences.sort { $0.jointID.uuidString < $1.jointID.uuidString };record.weights[index].influences=influences
                case "rig.morph":
                    guard record.keys.isEmpty,let rows=args["deltas"] as? [[String:Any]],rows.count<=256 else { throw CADRigError.invalid }
                    let id=try args["morph_id"].map { try uuid($0) } ?? UUID()
                    let morph=CADRigMorph(id:id,name:try name(args["name"],fallback:"Shape key"),deltas:try rows.map { CADRigDelta(vertexID:try uuid($0["vertex_id"]),delta:try vector($0["delta"])) },weight:try optional(args["weight"],0))
                    if let index=record.morphs.firstIndex(where: { $0.id == id }) { record.morphs[index]=morph }
                    else { guard record.morphs.count<4 else { throw CADRigError.invalid };record.morphs.append(morph) }
                case "rig.morph.weight":
                    let id=try uuid(args["morph_id"]);guard let index=record.morphs.firstIndex(where: { $0.id == id }) else { throw CADRigError.invalid };record.morphs[index].weight=try number(args["weight"])
                case "rig.key":
                    let time=try number(args["time"]);record.keys.removeAll { abs($0.time-time)<1e-9 }
                    guard record.keys.count<64 else { throw CADRigError.invalid }
                    record.keys.append(CADRigKey(time:time,poses:record.poses,morphWeights:record.morphs.map(\.weight)));record.keys.sort { $0.time<$1.time }
                case "rig.keys.clear": record.keys=[]
                case "rig.clip":
                    guard record.keys.count>=2,record.keys.first?.time==0,record.keys.last?.time==record.duration else { throw CADRigError.invalid }
                    var clip=CADAnimationClip(id:record.clipID,name:try name(args["name"],fallback:"Rig animation"),duration:record.duration,isLooping:true)
                    clip.rigID=record.id
                    if let index=animation.animation.clips.firstIndex(where: { $0.id == clip.id }) {
                        guard animation.animation.clips[index].rigID==record.id else { throw CADRigError.invalid };animation.animation.clips[index]=clip
                    } else { guard animation.animation.clips.count<CADAnimationDocument.maximumClips else { throw CADRigError.invalid };animation.animation.clips.append(clip) }
                    animation.animation.activeClipID=clip.id
                default: throw CADRigError.invalid
                }
            }
            try record.validate();let prepared=try playback(record);_ = try prepared.evaluate(at:nil)
            // Validate every authored endpoint, never commit an immediately
            // collapsed triangle. Intermediate failures still fail evaluation.
            if action == "rig.weight" { for key in record.keys { _ = try prepared.evaluate(at:key.time) } }
            try commit(record,animation:animation.animation)
            return ["ok":true,"mutated":true,"rig_id":record.id.uuidString,"body_id":record.bodyID.uuidString,"change_count":document.liveChangeCount]
        } catch let error as CADRigError { return ["ok":false,"mutated":false,"error":error.rawValue,"message":error.localizedDescription] }
        catch { return ["ok":false,"mutated":false,"error":"invalid_rig","message":error.localizedDescription] }
    }
    func source(_ id: UUID) throws -> (node:FeatureNode,definition:CADPolygonMeshDefinition,body:Body) {
        let bodyID=BodyID(raw:id)
        guard let body=document.session.document.body(with:bodyID),body.brep==nil,body.surfaceBRep==nil,
              body.render.positions.count<=4096,body.render.indices.count<=3072,body.materialFaceBindings.isEmpty,
              let current=CADPolygonMeshService.currentCage(in:document.session,bodyID:bodyID),
              current.definition.cage.vertices.count<=256,!current.definition.modifiers.contains(where: \.enabled) else { throw CADRigError.unsupported }
        return (current.node,current.definition,current.body)
    }
    func playback(_ record: CADRigRecord) throws -> CADRigPlayback {
        try record.validate();let source=try source(record.bodyID)
        guard source.node.id.raw==record.featureID,source.definition.digest==record.sourceSHA256,
              Set(record.weights.map(\.vertexID))==Set(source.definition.cage.vertices.map(\.id)) else { throw CADRigError.stale }
        var map:[SIMD3<Float>:[UUID]]=[:]
        for vertex in source.definition.cage.vertices { map[SIMD3<Float>(vertex.point),default:[]].append(vertex.id) }
        let ids=try source.body.render.positions.map { p -> UUID in guard let row=map[p],row.count==1 else { throw CADRigError.stale };return row[0] }
        return CADRigPlayback(record:record,vertexIDs:ids,render:source.body.render)
    }
    private func get() throws -> [String:Any] {
        let record=try CADRigCodec.read(document.session.document.sceneSettingsData)
        var result:[String:Any]=["ok":true,"mutated":false,"state":record==nil ? "empty" : ((try? playback(record!))==nil ? "stale":"ready")]
        result["candidates"]=document.session.document.bodies.compactMap { body -> [String:Any]? in guard (try? source(body.id.raw)) != nil else { return nil };return ["body_id":body.id.raw.uuidString,"name":body.name] }
        if let record { result["record"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) }
        if let record,let source=try? source(record.bodyID) { result["vertices"]=source.definition.cage.vertices.map { ["id":$0.id.uuidString,"point":[$0.point.x,$0.point.y,$0.point.z]] as [String:Any] } }
        return result
    }
    private func commit(_ record: CADRigRecord?,animation: CADAnimationDocument) throws {
        var settings=document.cameraSceneSettings();settings.rigging=record
        var animation=animation
        if let selected=animation.activeClipID,!animation.clips.contains(where: { $0.id==selected }) { animation.activeClipID=animation.clips.first?.id }
        if record != nil { animation.schemaVersion=max(animation.schemaVersion,CADAnimationDocument.rigSchemaVersion) }
        let scene=try JSONEncoder().encode(settings),bytes=try CADAnimationCodec.encode(animation.sanitized())
        guard !Task.isCancelled,!document.isClosed,document.session.writeBlock==nil else { throw CADRigError.cancelled }
        document.session.perform(CompositeCommand(title:FloeCADStrings.text("cad.rig.title","Rig and shape keys"),commands:[
            SetSceneSettingsDataCommand(before:document.session.document.sceneSettingsData,after:scene),
            SetAnimationDataCommand(title:"Rig",before:document.session.document.animationData,after:bytes)]))
        guard document.session.document.sceneSettingsData==scene,document.session.document.animationData==bytes else { throw CADRigError.stale }
    }
    private func number(_ value:Any?) throws -> Double { guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else { throw CADRigError.invalid };return n.doubleValue }
    private func optional(_ value:Any?,_ fallback:Double) throws -> Double { try value.map { try number($0) } ?? fallback }
    private func uuid(_ value:Any?) throws -> UUID { guard let s=value as? String,let id=UUID(uuidString:s) else { throw CADRigError.invalid };return id }
    private func name(_ value:Any?,fallback:String) throws -> String { let name=(value as? String ?? fallback).trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty,name.count<=80 else { throw CADRigError.invalid };return name }
    private func vector(_ value:Any?) throws -> SIMD3<Double> { guard let a=value as? [Any],a.count==3 else { throw CADRigError.invalid };return try SIMD3(number(a[0]),number(a[1]),number(a[2])) }
    private func pose(_ args:[String:Any]) throws -> CADRigPose {
        let p=try args["translation"].map { try vector($0) } ?? .zero
        var q=SIMD4<Double>(0,0,0,1)
        if let values=args["rotation"] as? [Any],values.count==4 { q=try SIMD4(number(values[0]),number(values[1]),number(values[2]),number(values[3])) }
        else if args["rotation"] != nil { throw CADRigError.invalid }
        let result=CADRigPose(translation:p,rotation:q);guard result.valid else { throw CADRigError.invalid };return result
    }
    private func jointIndex(_ record:CADRigRecord,_ args:[String:Any]) throws -> Int { let id=try uuid(args["joint_id"]);guard let index=record.joints.firstIndex(where: { $0.id==id }) else { throw CADRigError.invalid };return index }
}
@MainActor extension FloeCADDocument {
    func rigPlayback() -> CADRigPlayback? {
        guard viewOverlayState.activeSection==nil,let record=try? CADRigCodec.read(session.document.sceneSettingsData) else { return nil }
        return try? CADRiggingService(document:self).playback(record)
    }
    func validateRigClip(_ clip:CADAnimationClip) throws {
        guard let id=clip.rigID else { return }
        guard let playback=rigPlayback(),playback.record.id==id,playback.record.clipID==clip.id,
              playback.record.duration==clip.duration,clip.tracks.isEmpty,
              playback.record.keys.count>=2,playback.record.keys.first?.time==0,playback.record.keys.last?.time==clip.duration else { throw CADRigError.stale }
    }
    func riggedGLB() throws -> Data {
        guard let playback=rigPlayback(),let clip=animationDocument.clips.first(where: { $0.id==playback.record.clipID }) else { throw CADRigError.stale }
        try validateRigClip(clip)
        let body=try CADRiggingService(document:self).source(playback.record.bodyID).body
        let tables=session.faceRangeTables(for:[body])
        return try CADRigGLB.make(body:body,playback:playback,faceTables:tables.tables,revisions:tables.revisions)
    }
}
