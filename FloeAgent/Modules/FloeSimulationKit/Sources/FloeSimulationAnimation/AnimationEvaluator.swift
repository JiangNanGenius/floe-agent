import Foundation
import FloeSimulationCore

public enum SimulationAnimationMath {
    public static func multiply(_ a: SimulationQuaternion, _ b: SimulationQuaternion) -> SimulationQuaternion {
        .init(x:a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,y:a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,z:a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,w:a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z)
    }
    public static func inverse(_ q: SimulationQuaternion) -> SimulationQuaternion { .init(x:-q.x,y:-q.y,z:-q.z,w:q.w) }
    public static func rotate(_ q: SimulationQuaternion, _ value: SimulationVector3) -> SimulationVector3 {
        let axis = SimulationVector3(q.x,q.y,q.z), twice = axis.cross(value) * 2
        return value + twice * q.w + axis.cross(twice)
    }
    public static func slerp(_ a: SimulationQuaternion, _ b: SimulationQuaternion, _ t: Double) -> SimulationQuaternion {
        var b = b, dot = a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w
        if dot < 0 { b = .init(x:-b.x,y:-b.y,z:-b.z,w:-b.w); dot = -dot }
        let p: Double, q: Double
        if dot > 0.9995 { p = 1-t; q = t }
        else { let angle = acos(min(1,max(-1,dot))); p = sin((1-t)*angle)/sin(angle); q = sin(t*angle)/sin(angle) }
        let value = SimulationQuaternion(x:a.x*p+b.x*q,y:a.y*p+b.y*q,z:a.z*p+b.z*q,w:a.w*p+b.w*q)
        let norm = sqrt(value.x*value.x+value.y*value.y+value.z*value.z+value.w*value.w)
        return .init(x:value.x/norm,y:value.y/norm,z:value.z/norm,w:value.w/norm)
    }
    public static func interpolate(_ a: SimulationAnimationTransform, _ b: SimulationAnimationTransform, _ t: Double) -> SimulationAnimationTransform {
        .init(translation:a.translation+(b.translation-a.translation)*t, rotation:slerp(a.rotation,b.rotation,t), scale:a.scale+(b.scale-a.scale)*t)
    }
    private static func product(_ a: SimulationVector3, _ b: SimulationVector3) -> SimulationVector3 { .init(a.x*b.x,a.y*b.y,a.z*b.z) }
    private static func quotient(_ a: SimulationVector3, _ b: SimulationVector3) -> SimulationVector3 { .init(a.x/b.x,a.y/b.y,a.z/b.z) }
    public static func compose(_ parent: SimulationAnimationTransform, _ local: SimulationAnimationTransform) throws -> SimulationAnimationTransform {
        let uniform = abs(parent.scale.x-parent.scale.y) < 1e-10 && abs(parent.scale.x-parent.scale.z) < 1e-10
        let identityRotation = abs(local.rotation.w) > 1-1e-10
        guard uniform || identityRotation else { throw SimulationError.unsupported("Apply nonuniform parent scale before rotating a skeletal hierarchy.") }
        return .init(translation:parent.translation+rotate(parent.rotation,product(parent.scale,local.translation)),rotation:multiply(parent.rotation,local.rotation),scale:product(parent.scale,local.scale))
    }
    public static func local(_ world: SimulationAnimationTransform, relativeTo parent: SimulationAnimationTransform) -> SimulationAnimationTransform {
        .init(translation:quotient(rotate(inverse(parent.rotation),world.translation-parent.translation),parent.scale),rotation:multiply(inverse(parent.rotation),world.rotation),scale:quotient(world.scale,parent.scale))
    }
    public static func fromTo(_ first: SimulationVector3, _ second: SimulationVector3) throws -> SimulationQuaternion {
        guard first.length > 1e-12, second.length > 1e-12 else { throw SimulationError.invalidInput("A zero-length bone cannot be oriented.") }
        let a = first/first.length, b = second/second.length, dot = min(1,max(-1,a.dot(b)))
        if dot > 1-1e-12 { return .identity }
        if dot < -1+1e-12 {
            let basis = abs(a.x) < abs(a.y) ? (abs(a.x) < abs(a.z) ? SimulationVector3(1,0,0) : .init(0,0,1)) : (abs(a.y) < abs(a.z) ? .init(0,1,0) : .init(0,0,1))
            let cross = a.cross(basis), axis = cross/cross.length
            return .init(x:axis.x,y:axis.y,z:axis.z,w:0)
        }
        let cross = a.cross(b), scalar = sqrt((1+dot)*2)
        return .init(x:cross.x/scalar,y:cross.y/scalar,z:cross.z/scalar,w:scalar/2)
    }
}

public enum SimulationAnimationEvaluator {
    public static func evaluate(_ graph: SimulationAnimationGraph, timeSeconds: Double, physics: SimulationResult? = nil) throws -> SimulationAnimationPose {
        try graph.validate()
        guard timeSeconds.isFinite, (0...graph.durationSeconds).contains(timeSeconds) else { throw SimulationError.invalidInput("The animation time is outside its clip.") }
        if !graph.physicsBindings.isEmpty, physics == nil { throw SimulationError.invalidInput("The animation's physics cache is missing.") }
        if let physics { guard physics.source == graph.source, graph.physicsResultID == physics.id else { throw SimulationError.staleSource } }
        let math = SimulationAnimationMath.self
        var objects: [String:SimulationAnimationTransform] = [:]
        var locals = Dictionary(uniqueKeysWithValues: graph.bones.map { ($0.id,$0.restLocal) })
        for layer in graph.layers where layer.weight > 0 {
            for track in layer.tracks {
                let sampled = sample(track, at: timeSeconds)
                let prior = locals[track.targetID] ?? objects[track.targetID] ?? .identity
                let value = layer.additive ? try math.compose(prior,math.interpolate(.identity,sampled,layer.weight)) : math.interpolate(prior,sampled,layer.weight)
                if locals[track.targetID] != nil { locals[track.targetID] = value } else { objects[track.targetID] = value }
            }
        }
        func worlds(_ local: [String:SimulationAnimationTransform]) throws -> [String:SimulationAnimationTransform] {
            var values: [String:SimulationAnimationTransform] = [:]
            for bone in graph.bones { values[bone.id] = try bone.parentID.map { try math.compose(values[$0]!,local[bone.id]!) } ?? local[bone.id]! }
            return values
        }
        var world = try worlds(locals)
        for chain in graph.ikChains where chain.weight > 0 {
            let root = world[chain.rootID]!, middle = world[chain.middleID]!, end = world[chain.endID]!
            let a = (middle.translation-root.translation).length, b = (end.translation-middle.translation).length
            let targetDelta = chain.targetMeters-root.translation
            guard a > 1e-12, b > 1e-12, targetDelta.length > 1e-12 else { throw SimulationError.invalidInput("IK needs nonzero bone lengths and target distance.") }
            let direction = targetDelta/targetDelta.length, distance = min(a+b-1e-12,max(abs(a-b)+1e-12,targetDelta.length))
            var pole = chain.poleMeters-root.translation; pole = pole-direction*pole.dot(direction)
            if pole.length < 1e-12 { let basis = abs(direction.y)<0.9 ? SimulationVector3(0,1,0) : .init(1,0,0); pole = basis-direction*basis.dot(direction) }
            pole = pole/pole.length
            let cosine = min(1,max(-1,(a*a+distance*distance-b*b)/(2*a*distance)))
            let elbow = root.translation+direction*(a*cosine)+pole*(a*sqrt(max(0,1-cosine*cosine)))
            let delta = try math.fromTo(middle.translation-root.translation,elbow-root.translation)
            var newRoot = root; newRoot.rotation = math.slerp(root.rotation,math.multiply(delta,root.rotation),chain.weight)
            let rootBone = graph.bones.first { $0.id == chain.rootID }!
            locals[chain.rootID] = rootBone.parentID.map { math.local(newRoot,relativeTo:world[$0]!) } ?? newRoot
            world = try worlds(locals)
            let updatedMiddle = world[chain.middleID]!, updatedEnd = world[chain.endID]!
            let middleDelta = try math.fromTo(updatedEnd.translation-updatedMiddle.translation,chain.targetMeters-updatedMiddle.translation)
            var newMiddle = updatedMiddle; newMiddle.rotation = math.slerp(updatedMiddle.rotation,math.multiply(middleDelta,updatedMiddle.rotation),chain.weight)
            locals[chain.middleID] = math.local(newMiddle,relativeTo:world[chain.rootID]!)
            world = try worlds(locals)
        }
        var softVertices: [String:[SimulationVector3]] = [:]
        var hiddenObjects = Set<String>()
        if let physics {
            let sampled = try SimulationPhysicsCacheSampler.sample(physics, timeSeconds: timeSeconds)
            softVertices = sampled.softVertices
            let order = Dictionary(uniqueKeysWithValues: graph.bones.enumerated().map { ($0.element.id,$0.offset) })
            for binding in graph.physicsBindings.sorted(by: { (order[$0.targetID] ?? Int.max) < (order[$1.targetID] ?? Int.max) }) where binding.control != .keyframed {
                if sampled.visibility[binding.bodyID] == false { hiddenObjects.insert(binding.targetID) }
                guard let body = sampled.bodies[binding.bodyID] else { throw SimulationError.invalidInput("An animation binding refers to a missing physics body.") }
                let driven = try math.compose(body,binding.bodyFromTarget), weight = binding.control == .dynamic ? 1 : binding.weight
                if let bone = graph.bones.first(where: { $0.id == binding.targetID }) {
                    let mixed = math.interpolate(world[bone.id]!,driven,weight)
                    locals[bone.id] = bone.parentID.map { math.local(mixed,relativeTo:world[$0]!) } ?? mixed
                    world = try worlds(locals)
                } else { objects[binding.targetID] = math.interpolate(objects[binding.targetID] ?? .identity,driven,weight) }
            }
        }
        var morphs: [String:[Double]] = [:]
        for track in graph.morphTracks {
            let upper = track.timesSeconds.firstIndex { $0 >= timeSeconds } ?? track.timesSeconds.count-1
            let lower = max(0,upper-1), a = track.timesSeconds[lower], b = track.timesSeconds[upper]
            let weight = b>a ? min(1,max(0,(timeSeconds-a)/(b-a))) : 0
            morphs[track.targetID] = zip(track.weights[lower],track.weights[upper]).map { $0+($1-$0)*weight }
        }
        var projection:SimulationAnimationCameraProjection?
        if let keys = graph.cameraKeys {
            let upper = keys.firstIndex { $0.timeSeconds >= timeSeconds } ?? keys.count-1, lower = max(0,upper-1)
            let a = keys[lower], b = keys[upper], alpha = b.timeSeconds>a.timeSeconds ? min(1,max(0,(timeSeconds-a.timeSeconds)/(b.timeSeconds-a.timeSeconds))):0
            let height = a.projection.orthographicHeightMeters.flatMap { first in b.projection.orthographicHeightMeters.map { first+($0-first)*alpha } }
            projection = .init(verticalFOVDegrees:a.projection.verticalFOVDegrees+(b.projection.verticalFOVDegrees-a.projection.verticalFOVDegrees)*alpha,orthographicHeightMeters:height)
        }
        return .init(timeSeconds:timeSeconds,objects:objects,localBones:locals,worldBones:world,morphWeights:morphs,softVertices:softVertices,hiddenObjects:hiddenObjects,cameraProjection:projection)
    }
    private static func sample(_ track: SimulationAnimationTrack, at time: Double) -> SimulationAnimationTransform {
        let upper = track.keys.firstIndex { $0.timeSeconds >= time } ?? track.keys.count-1
        let lower = max(0,upper-1), a = track.keys[lower], b = track.keys[upper]
        let weight = b.timeSeconds>a.timeSeconds ? min(1,max(0,(time-a.timeSeconds)/(b.timeSeconds-a.timeSeconds))) : 0
        return SimulationAnimationMath.interpolate(a.transform,b.transform,weight)
    }
}

public struct SimulationPhysicsCachePose: Sendable {
    public var bodies: [UUID:SimulationAnimationTransform]
    public var softVertices: [String:[SimulationVector3]]
    public var visibility: [UUID:Bool]
}
public enum SimulationPhysicsCacheSampler {
    public static func sample(_ result: SimulationResult, timeSeconds: Double) throws -> SimulationPhysicsCachePose {
        let frames = result.frames
        guard timeSeconds.isFinite, !frames.isEmpty, frames.allSatisfy({ $0.timeSeconds != nil && $0.timeSeconds!.isFinite }),
              zip(frames,frames.dropFirst()).allSatisfy({ $0.timeSeconds! < $1.timeSeconds! }), timeSeconds >= frames[0].timeSeconds! - 1e-10,
              timeSeconds <= frames.last!.timeSeconds! + 1e-10 else { throw SimulationError.invalidInput("The physics cache does not cover the requested time.") }
        let upper = frames.firstIndex { $0.timeSeconds! >= timeSeconds } ?? frames.count-1, lower = max(0,upper-1)
        let a = frames[lower], b = frames[upper], dt = b.timeSeconds! - a.timeSeconds!
        let weight = dt>0 ? min(1,max(0,(timeSeconds-a.timeSeconds!)/dt)) : 0
        let ids = (result.diagnostics["bodyIDs"] ?? "").split(separator: ",").compactMap { UUID(uuidString:String($0)) }
        func field(_ frame: SimulationResultFrame, _ id: String) throws -> [Double] {
            guard let field = frame.fields.first(where: { $0.id == id }) else { throw SimulationError.corruptArchive("A physics cache field is missing.") }
            try field.validate(); return field.values
        }
        var bodies: [UUID:SimulationAnimationTransform] = [:]
        if !ids.isEmpty {
            let ap = try field(a,"body_position"), bp = try field(b,"body_position"), ar = try field(a,"body_rotation"), br = try field(b,"body_rotation")
            guard ap.count == ids.count*3, bp.count == ap.count, ar.count == ids.count*4, br.count == ar.count else { throw SimulationError.corruptArchive("Physics cache pose arrays have inconsistent lengths.") }
            for (i,id) in ids.enumerated() {
                let first = SimulationAnimationTransform(translation:.init(ap[i*3],ap[i*3+1],ap[i*3+2]),rotation:.init(x:ar[i*4],y:ar[i*4+1],z:ar[i*4+2],w:ar[i*4+3]))
                let second = SimulationAnimationTransform(translation:.init(bp[i*3],bp[i*3+1],bp[i*3+2]),rotation:.init(x:br[i*4],y:br[i*4+1],z:br[i*4+2],w:br[i*4+3]))
                bodies[id] = SimulationAnimationMath.interpolate(first,second,weight)
            }
        }
        var soft: [String:[SimulationVector3]] = [:]
        for value in a.fields where value.id.hasPrefix("soft/") {
            let next = try field(b,value.id)
            guard value.components == 3, value.values.count == next.count else { throw SimulationError.corruptArchive("Soft-body cache topology is inconsistent.") }
            soft[value.id] = stride(from:0,to:next.count,by:3).map { index in
                let first = SimulationVector3(value.values[index],value.values[index+1],value.values[index+2]), second = SimulationVector3(next[index],next[index+1],next[index+2])
                return first+(second-first)*weight
            }
        }
        let visibilityFrame = weight >= 1-1e-12 ? b : a
        let visible = visibilityFrame.fields.first { $0.id == "body_visible" }?.values
        if let visible { guard visible.count == ids.count else { throw SimulationError.corruptArchive("Physics visibility does not match its body identities.") } }
        var byID: [UUID:Bool] = [:]
        for (index,id) in ids.enumerated() { byID[id] = visible.map { $0[index] > 0 } ?? true }
        return .init(bodies:bodies,softVertices:soft,visibility:byID)
    }
}
