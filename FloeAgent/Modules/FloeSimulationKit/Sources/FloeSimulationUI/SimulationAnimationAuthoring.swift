import Foundation
import FloeSimulationCore
import FloeSimulationPhysics
import FloeSimulationAnimation

public extension SimulationWorkbenchModel {
    /// Generates editable collision bodies, actual joints and bone/cache bindings.
    func createRagdoll(pinRoot:Bool = false) {
        guard !isClosed,sourceAvailable,!preparingSourceMesh,!baking else { return }
        do {
            var graph = animationGraph; try graph.validate()
            guard !graph.bones.isEmpty,graph.bones.count <= 256 else { throw SimulationError.invalidInput("Create or import up to 256 bones before generating a ragdoll.") }
            var world:[String:SimulationAnimationTransform] = [:]
            for bone in graph.bones { world[bone.id] = try bone.parentID.map { try SimulationAnimationMath.compose(world[$0]!,bone.restLocal) } ?? bone.restLocal }
            var config = PhysicsSimulationConfiguration(), bodies:[String:SimulationPhysicsBody] = [:]
            config.time.durationSeconds = graph.durationSeconds
            var bindings:[SimulationAnimationPhysicsBinding] = []
            for bone in graph.bones {
                let pose = world[bone.id]!
                let next = graph.bones.first { $0.parentID == bone.id }.flatMap { world[$0.id] }
                let previous = bone.parentID.flatMap { world[$0] }
                let length = (next.map { $0.translation-pose.translation } ?? previous.map { pose.translation-$0.translation } ?? .init(0,0.1,0)).length
                guard length.isFinite,length>1e-8 else { throw SimulationError.invalidInput("Separate coincident joints before generating a ragdoll.") }
                var body = SimulationPhysicsBody(sourceObjectID:"ragdoll/"+bone.id)
                body.translation = pose.translation; body.rotation = pose.rotation
                body.collider = .init(kind:.sphere); body.collider.radius = max(0.00001,length*0.08)
                body.angularDamping = 0.15; body.linearDamping = 0.05; body.massKg = max(0.01,length)
                if let next {
                    let segment = next.translation-pose.translation
                    body.translation = (pose.translation+next.translation)*0.5
                    body.rotation = try SimulationAnimationMath.fromTo(.init(0,1,0),segment)
                    body.collider = .init(kind:.capsule); body.collider.radius = max(0.00001,length*0.08); body.collider.halfHeight = length*0.3
                }
                if pinRoot,bone.parentID == nil { body.motion = .fixed }
                bodies[bone.id] = body; config.bodies.append(body)
                let bodyPose = SimulationAnimationTransform(translation:body.translation,rotation:body.rotation)
                bindings.append(.init(targetID:bone.id,bodyID:body.id,bodyFromTarget:SimulationAnimationMath.local(pose,relativeTo:bodyPose)))
            }
            for bone in graph.bones {
                guard let parent = bone.parentID,let first = bodies[parent],let second = bodies[bone.id] else { continue }
                let anchor = world[bone.id]!.translation
                var joint = SimulationPhysicsJoint(kind:.spherical,firstBody:first.id,secondBody:second.id)
                joint.firstAnchor = SimulationAnimationMath.rotate(SimulationAnimationMath.inverse(first.rotation),anchor-first.translation)
                joint.secondAnchor = SimulationAnimationMath.rotate(SimulationAnimationMath.inverse(second.rotation),anchor-second.translation)
                config.joints.append(joint)
            }
            try config.validate(budget:.init())
            graph.physicsResultID = nil; graph.physicsBindings = bindings; try graph.validate()
            // One ordinary saved study; the source Mesh and its editor undo are unchanged.
            createStudy(.rigidBody); renameStudy(simulationText("Ragdoll","布娃娃")); writeConfiguration(config); writeAnimationGraph(graph)
            displaysAnimation = false; clearError()
        } catch { recordSourceError(error) }
    }

    func setMeshMorph(objectID:String,name:String,vertexIndex:Int,offset:SimulationVector3,startWeight:Double = 0,endWeight:Double = 1) {
        guard !isClosed,sourceAvailable,!baking else { return }
        do {
            guard let mesh = sourceMeshes.first(where: { $0.id == objectID }),mesh.positionsMeters.indices.contains(vertexIndex),
                  !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,offset.isFinite,startWeight.isFinite,endWeight.isFinite else { throw SimulationError.invalidInput("Choose a source vertex, a Morph name and finite offsets and weights.") }
            var graph = animationGraph, bindings = graph.meshBindings ?? []
            if !bindings.contains(where: { $0.sourceObjectID == objectID }) { bindings.append(.init(sourceObjectID:objectID)) }
            let index = bindings.firstIndex { $0.sourceObjectID == objectID }!
            var morphs = bindings[index].morphs
            if !morphs.contains(where: { $0.name == name }) { morphs.append(.init(name:name,deltas:[])) }
            let target = morphs.firstIndex { $0.name == name }!
            morphs[target].deltas.removeAll { $0.vertexIndex == vertexIndex }
            if offset != .zero { morphs[target].deltas.append(.init(vertexIndex:vertexIndex,offset:offset)) }
            bindings[index].morphs = morphs; graph.meshBindings = bindings
            var first = Array(repeating:0.0,count:morphs.count), last = first
            if let old = graph.morphTracks.first(where: { $0.targetID == objectID }),old.weights.first?.count == morphs.count {
                first = old.weights.first!; last = old.weights.last!
            }
            first[target] = startWeight; last[target] = endWeight
            graph.morphTracks.removeAll { $0.targetID == objectID }
            graph.morphTracks.append(.init(targetID:objectID,timesSeconds:[0,graph.durationSeconds],weights:[first,last]))
            try graph.validate(); writeAnimationGraph(graph); clearError()
        } catch { recordSourceError(error) }
    }
}
