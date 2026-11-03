// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// Add skin/morph/animation channels to the existing material/texture GLB
/// writer. No mesh-format fork and no camera/material/body authority here.
nonisolated enum CADRigGLB {
    static func make(body:Body,playback:CADRigPlayback,faceTables:[BodyID:FaceTable],revisions:[BodyID:UInt64]) throws -> Data {
        try playback.record.validate();let record=playback.record
        guard record.keys.count>=2,record.keys.first?.time==0,record.keys.last?.time==record.duration else { throw CADRigError.invalid }
        let m=body.transform.matrix
        let matrix=[m.columns.0.x,m.columns.0.y,m.columns.0.z,m.columns.0.w,m.columns.1.x,m.columns.1.y,m.columns.1.z,m.columns.1.w,m.columns.2.x,m.columns.2.y,m.columns.2.z,m.columns.2.w,m.columns.3.x,m.columns.3.y,m.columns.3.z,m.columns.3.w]
        // Geometry must stay body-local. Joint siblings and mesh share this
        // one body placement, beneath the exporter's sole mm->m root scale.
        let base=GLBExporter.glb(bodies:[body],faceTables:faceTables,faceTableRevisions:revisions,
            sceneGraph:[GLBSceneNode(name:"RigSpace",matrix:matrix,children:[GLBSceneNode(name:body.name,bodyIndex:0)])])
        func uint(_ offset:Int) throws -> UInt32 { guard offset>=0,offset+4<=base.count else { throw CADRigError.invalid };return base.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian } }
        guard base.count<=16*1024*1024,try uint(0)==0x46546c67,try uint(4)==2,try uint(8)==base.count else { throw CADRigError.invalid }
        let length=Int(try uint(12)),binHeader=20+length
        guard try uint(16)==0x4e4f534a,binHeader+8<=base.count,try uint(binHeader+4)==0x004e4942,
              var root=try JSONSerialization.jsonObject(with:base.subdata(in:20..<binHeader)) as? [String:Any],
              var nodes=root["nodes"] as? [[String:Any]],var meshes=root["meshes"] as? [[String:Any]],meshes.count==1,
              var accessors=root["accessors"] as? [[String:Any]],var views=root["bufferViews"] as? [[String:Any]],
              let buffers=root["buffers"] as? [[String:Any]],let originalBytes=buffers.first?["byteLength"] as? Int,
              originalBytes<=Int(try uint(binHeader)),binHeader+8+originalBytes<=base.count,
              let meshNode=nodes.firstIndex(where: { $0["mesh"] as? Int == 0 }),
              let space=nodes.firstIndex(where: { ($0["children"] as? [Int])?.contains(meshNode) == true && $0["matrix"] != nil }) else { throw CADRigError.invalid }
        var bin=base.subdata(in:(binHeader+8)..<(binHeader+8+originalBytes))
        func append(_ bytes:Data,component:Int,count:Int,type:String,target:Int?=nil,minimum:[Double]?=nil,maximum:[Double]?=nil) -> Int {
            while bin.count%4 != 0 { bin.append(0) }
            var view:[String:Any]=["buffer":0,"byteOffset":bin.count,"byteLength":bytes.count]
            if let target { view["target"]=target };let viewID=views.count;views.append(view);bin.append(bytes)
            var accessor:[String:Any]=["bufferView":viewID,"componentType":component,"count":count,"type":type]
            if let minimum { accessor["min"]=minimum };if let maximum { accessor["max"]=maximum }
            let id=accessors.count;accessors.append(accessor);return id
        }
        func floats(_ values:[Double]) -> Data { var data=Data();for value in values { var bits=Float(value).bitPattern.littleEndian;withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) } };return data }
        func vec3(_ values:[SIMD3<Double>],target:Int?=nil) -> Int {
            var lo=SIMD3<Double>(repeating:.infinity),hi=SIMD3<Double>(repeating:-.infinity)
            for p in values { lo=simd_min(lo,p);hi=simd_max(hi,p) }
            return append(floats(values.flatMap { [$0.x,$0.y,$0.z] }),component:5126,count:values.count,type:"VEC3",target:target,minimum:[lo.x,lo.y,lo.z],maximum:[hi.x,hi.y,hi.z])
        }
        let jointIndex=Dictionary(uniqueKeysWithValues:record.joints.enumerated().map { ($0.element.id,$0.offset) })
        let vertexWeights=Dictionary(uniqueKeysWithValues:record.weights.map { ($0.vertexID,$0.influences) })
        var jointBytes=Data(),weightValues:[Double]=[]
        for id in playback.vertexIDs {
            guard let influences=vertexWeights[id] else { throw CADRigError.stale }
            for i in 0..<4 {
                let influence=i<influences.count ? influences[i]:nil
                var value=UInt16(influence.flatMap { jointIndex[$0.jointID] } ?? 0).littleEndian
                withUnsafeBytes(of:&value) { jointBytes.append(contentsOf:$0) };weightValues.append(influence?.weight ?? 0)
            }
        }
        let jointsAccessor=append(jointBytes,component:5123,count:playback.vertexIDs.count,type:"VEC4",target:34962)
        let weightAccessor=append(floats(weightValues),component:5126,count:playback.vertexIDs.count,type:"VEC4",target:34962)
        var morphAccessors:[Int]=[]
        for morph in record.morphs {
            let deltas=Dictionary(uniqueKeysWithValues:morph.deltas.map { ($0.vertexID,$0.delta) })
            morphAccessors.append(vec3(playback.vertexIDs.map { deltas[$0] ?? .zero },target:34962))
        }
        guard var primitives=meshes[0]["primitives"] as? [[String:Any]] else { throw CADRigError.invalid }
        for i in primitives.indices {
            guard var attributes=primitives[i]["attributes"] as? [String:Any] else { throw CADRigError.invalid }
            attributes["JOINTS_0"]=jointsAccessor;attributes["WEIGHTS_0"]=weightAccessor;primitives[i]["attributes"]=attributes
            if !morphAccessors.isEmpty { primitives[i]["targets"]=morphAccessors.map { ["POSITION":$0] } }
        }
        meshes[0]["primitives"]=primitives
        if !record.morphs.isEmpty { meshes[0]["weights"]=record.morphs.map(\.weight);var extras=meshes[0]["extras"] as? [String:Any] ?? [:];extras["targetNames"]=record.morphs.map(\.name);meshes[0]["extras"]=extras }
        var jointNodes:[Int]=[]
        for (i,joint) in record.joints.enumerated() {
            let pose=record.poses[i],id=nodes.count;jointNodes.append(id)
            nodes.append(["name":joint.name,"translation":[pose.translation.x,pose.translation.y,pose.translation.z],"rotation":[pose.rotation.x,pose.rotation.y,pose.rotation.z,pose.rotation.w],"extras":["floe_joint_id":joint.id.uuidString]])
        }
        var spaceChildren=nodes[space]["children"] as? [Int] ?? []
        for (index,joint) in record.joints.enumerated() {
            if let parent=joint.parent.flatMap({jointIndex[$0]}) { var children=nodes[jointNodes[parent]]["children"] as? [Int] ?? [];children.append(jointNodes[index]);nodes[jointNodes[parent]]["children"]=children }
            else { spaceChildren.append(jointNodes[index]) }
        }
        nodes[space]["children"]=spaceChildren
        let inverse=record.world(record.joints.map(\.rest)).map(simd_inverse)
        let matrixValues=inverse.flatMap { m in [m.columns.0.x,m.columns.0.y,m.columns.0.z,m.columns.0.w,m.columns.1.x,m.columns.1.y,m.columns.1.z,m.columns.1.w,m.columns.2.x,m.columns.2.y,m.columns.2.z,m.columns.2.w,m.columns.3.x,m.columns.3.y,m.columns.3.z,m.columns.3.w] }
        let inverseAccessor=append(floats(matrixValues),component:5126,count:inverse.count,type:"MAT4")
        nodes[meshNode]["skin"]=0;nodes[meshNode]["extras"]=["floe_rig_id":record.id.uuidString,"floe_source_sha256":record.sourceSHA256]
        let timeAccessor=append(floats(record.keys.map(\.time)),component:5126,count:record.keys.count,type:"SCALAR",minimum:[0],maximum:[record.duration])
        var samplers:[[String:Any]]=[],channels:[[String:Any]]=[]
        func channel(output:Int,node:Int,path:String) { let sampler=samplers.count;samplers.append(["input":timeAccessor,"output":output,"interpolation":"LINEAR"]);channels.append(["sampler":sampler,"target":["node":node,"path":path]]) }
        for index in record.joints.indices {
            let translations=record.keys.map { $0.poses[index].translation }
            channel(output:vec3(translations),node:jointNodes[index],path:"translation")
            // Sign-consistent quaternion representatives make LINEAR glTF
            // SLERP follow the same shortest arc as the native evaluator.
            var previous:SIMD4<Double>?,rotations:[Double]=[]
            for key in record.keys { var q=key.poses[index].rotation;if let previous,simd_dot(previous,q)<0 { q = -q };previous=q;rotations += [q.x,q.y,q.z,q.w] }
            channel(output:append(floats(rotations),component:5126,count:record.keys.count,type:"VEC4"),node:jointNodes[index],path:"rotation")
        }
        if !record.morphs.isEmpty { channel(output:append(floats(record.keys.flatMap(\.morphWeights)),component:5126,count:record.keys.count*record.morphs.count,type:"SCALAR"),node:meshNode,path:"weights") }
        root["skins"]=[["joints":jointNodes,"skeleton":jointNodes[0],"inverseBindMatrices":inverseAccessor]]
        root["animations"]=[["name":"Rig animation","samplers":samplers,"channels":channels]]
        root["nodes"]=nodes;root["meshes"]=meshes;root["accessors"]=accessors;root["bufferViews"]=views;root["buffers"]=[["byteLength":bin.count]]
        var json=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys]);while json.count%4 != 0 { json.append(32) };while bin.count%4 != 0 { bin.append(0) }
        let total=12+8+json.count+8+bin.count;guard total<=16*1024*1024,!Task.isCancelled else { throw CADRigError.cancelled }
        var output=Data()
        func word(_ value:UInt32) { var v=value.littleEndian;withUnsafeBytes(of:&v) { output.append(contentsOf:$0) } }
        word(0x46546c67);word(2);word(UInt32(total));word(UInt32(json.count));word(0x4e4f534a);output.append(json);word(UInt32(bin.count));word(0x004e4942);output.append(bin)
        return output
    }
}
