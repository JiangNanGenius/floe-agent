// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import simd
import FloeCAD
import FloeSimulationCore
import FloeSimulationAnimation
import FloeSimulationPhysics
import FloeSimulationUI

nonisolated enum CADSimulationAnimationBridge {
    static func graph(_ captured:CADSimulationAnimationSource,source:SimulationSourceRef) throws -> SimulationAnimationGraph? {
        guard captured.skeleton != nil || !captured.frames.isEmpty else { return nil }
        var graph = SimulationAnimationGraph(source:source,durationSeconds:max(captured.durationSeconds ?? 1,captured.skeleton?.durationSeconds ?? 0))
        var tracks:[SimulationAnimationTrack] = []
        func transform(_ t:[Double],_ q:[Double]) throws -> SimulationAnimationTransform {
            guard t.count == 3,q.count == 4 else { throw SimulationError.staleSource }
            return .init(translation:.init(t[0]*0.001,t[1]*0.001,t[2]*0.001),rotation:.init(x:q[0],y:q[1],z:q[2],w:q[3]))
        }
        if let rig = captured.skeleton {
            let m = rig.placement
            guard m.count == 16,m.allSatisfy(\.isFinite) else { throw SimulationError.staleSource }
            let linear = simd_double3x3(columns:(SIMD3(m[0],m[1],m[2]),SIMD3(m[4],m[5],m[6]),SIMD3(m[8],m[9],m[10])))
            let scale = SIMD3(simd_length(linear.columns.0),simd_length(linear.columns.1),simd_length(linear.columns.2))
            guard min(scale.x,scale.y,scale.z)>1e-12,simd_determinant(linear)>0 else { throw SimulationError.unsupported("Apply reflected or singular placement before importing a rig.") }
            let basis = simd_double3x3(columns:(linear.columns.0/scale.x,linear.columns.1/scale.y,linear.columns.2/scale.z))
            guard abs(simd_dot(basis.columns.0,basis.columns.1))+abs(simd_dot(basis.columns.0,basis.columns.2))+abs(simd_dot(basis.columns.1,basis.columns.2))<1e-8 else { throw SimulationError.unsupported("Apply sheared placement before importing a rig.") }
            let q = simd_quatd(basis).vector
            let placement = SimulationAnimationTransform(translation:.init(m[12]*0.001,m[13]*0.001,m[14]*0.001),rotation:.init(x:q.x,y:q.y,z:q.z,w:q.w),scale:.init(scale.x,scale.y,scale.z))
            var remaining = rig.joints, ordered:[CADSimulationSkeletonSource.Joint] = [], ids = Set<String>()
            while !remaining.isEmpty {
                guard let index = remaining.firstIndex(where: { $0.parentID == nil || ids.contains($0.parentID!) }) else { throw SimulationError.invalidInput("The imported skeleton has a cyclic or missing parent.") }
                let joint = remaining.remove(at:index); ordered.append(joint); ids.insert(joint.id)
            }
            for joint in ordered {
                let local = try transform(joint.restTranslationMM,joint.restRotation)
                graph.bones.append(.init(id:joint.id,parentID:joint.parentID,restLocal:joint.parentID == nil ? try SimulationAnimationMath.compose(placement,local):local))
                guard let index = rig.joints.firstIndex(where: { $0.id == joint.id }) else { throw SimulationError.staleSource }
                let keys = try rig.keys.map { key -> SimulationAnimationKey in
                    guard key.translationsMM.indices.contains(index),key.rotations.indices.contains(index) else { throw SimulationError.staleSource }
                    let local = try transform(key.translationsMM[index],key.rotations[index])
                    return .init(timeSeconds:key.timeSeconds,transform:joint.parentID == nil ? try SimulationAnimationMath.compose(placement,local):local)
                }
                if !keys.isEmpty { tracks.append(.init(targetID:joint.id,keys:keys)) }
            }
            graph.meshBindings = [try .init(sourceObjectID:rig.objectID,
                skin:rig.skin.map { .init(vertexIndex:$0.index,influences:$0.influences.map { .init(boneID:$0.boneID,weight:$0.weight) }) },
                morphs:rig.morphs.map { morph in .init(name:morph.name,deltas:try morph.deltas.map { delta in
                    guard delta.offsetMM.count == 3 else { throw SimulationError.staleSource }
                    let v = linear*SIMD3(delta.offsetMM[0],delta.offsetMM[1],delta.offsetMM[2])*0.001
                    return .init(vertexIndex:delta.index,offset:.init(v.x,v.y,v.z))
                }) })]
            if !rig.morphs.isEmpty,!rig.keys.isEmpty { graph.morphTracks = [.init(targetID:rig.objectID,timesSeconds:rig.keys.map(\.timeSeconds),weights:rig.keys.map(\.morphWeights))] }
        }
        let objectIDs = Set(captured.frames.flatMap { $0.objects.keys })
        for id in objectIDs.sorted() {
            let keys = try captured.frames.map { frame -> SimulationAnimationKey in
                guard let pose = frame.objects[id] else { throw SimulationError.invalidInput("The existing animation has incomplete model samples.") }
                return .init(timeSeconds:frame.timeSeconds,transform:.init(translation:.init(pose.translationMeters.x,pose.translationMeters.y,pose.translationMeters.z),rotation:.init(x:pose.rotation.x,y:pose.rotation.y,z:pose.rotation.z,w:pose.rotation.w),scale:.init(pose.scale.x,pose.scale.y,pose.scale.z)))
            }
            tracks.append(.init(targetID:id,keys:keys))
        }
        let cameras = captured.frames.filter { $0.camera != nil }
        if !cameras.isEmpty {
            guard cameras.count == captured.frames.count else { throw SimulationError.invalidInput("The existing animation has incomplete camera samples.") }
            tracks.append(.init(targetID:"camera",keys:cameras.map { frame in
                let c = frame.camera!
                return .init(timeSeconds:frame.timeSeconds,transform:.init(translation:.init(c.positionMeters.x,c.positionMeters.y,c.positionMeters.z),rotation:.init(x:c.rotation.x,y:c.rotation.y,z:c.rotation.z,w:c.rotation.w)))
            }))
            graph.cameraKeys = cameras.map { .init(timeSeconds:$0.timeSeconds,projection:.init(verticalFOVDegrees:$0.camera!.verticalFOVDegrees,orthographicHeightMeters:$0.camera!.orthographicHeightMeters)) }
        }
        graph.layers = [.init(tracks:tracks)]; try graph.validate(); return graph
    }

    static func glb(base:CADSimulationGLBSource,request:SimulationAnimationExportRequest) throws -> Data {
        let targets = base.targets.map { SimulationGLBTarget(sourceObjectID:$0.objectID,nodeIndex:$0.nodeIndex,originMeters:.init($0.originMM[0]*0.001,$0.originMM[1]*0.001,$0.originMM[2]*0.001)) }
        let ids = request.physics?.diagnostics["softSourceObjectIDs"].flatMap { try? JSONDecoder().decode([String:String].self,from:Data($0.utf8)) } ?? [:]
        var frames:[SimulationAnimationVertexFrames] = []
        for (id,target) in ids {
            let key = "soft/"+id
            guard targets.contains(where: { $0.sourceObjectID == target }) else { throw SimulationError.invalidInput("Bind soft-body geometry to a model Mesh before exporting GLB.") }
            let mapping = request.physics?.diagnostics[key+"/sourceVertexToParticle"].flatMap { try? JSONDecoder().decode([UInt32].self,from:Data($0.utf8)) }
            let samples = try request.bake.frames.map { pose -> [SimulationVector3] in
                try Task.checkCancellation()
                guard let vertices = pose.softVertices[key] else { throw SimulationError.staleSource }
                guard let mapping else { return vertices }
                guard mapping.allSatisfy({ Int($0) < vertices.count }) else { throw SimulationError.staleSource }
                return mapping.map { vertices[Int($0)] }
            }
            frames.append(.init(sourceObjectID:target,positionsMeters:samples))
        }
        return try SimulationAnimationGLBExporter.export(baseGLB:base.data,graph:request.graph,bake:request.bake,targets:targets,vertexFrames:frames)
    }
}
#endif
