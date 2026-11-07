import Foundation
import FloeSimulationCore

public struct SimulationVertexInfluence: Codable, Equatable, Sendable {
    public var boneID: String
    public var weight: Double
    public init(boneID:String,weight:Double) { self.boneID = boneID; self.weight = weight }
}
public struct SimulationVertexSkin: Codable, Equatable, Sendable {
    public var vertexIndex: Int
    public var influences: [SimulationVertexInfluence]
    public init(vertexIndex:Int,influences:[SimulationVertexInfluence]) { self.vertexIndex = vertexIndex; self.influences = influences }
}
public struct SimulationMorphDelta: Codable, Equatable, Sendable {
    public var vertexIndex: Int
    public var offset: SimulationVector3
    public init(vertexIndex:Int,offset:SimulationVector3) { self.vertexIndex = vertexIndex; self.offset = offset }
}
public struct SimulationMeshMorph: Codable, Equatable, Sendable {
    public var name: String
    public var deltas: [SimulationMorphDelta]
    public init(name:String,deltas:[SimulationMorphDelta]) { self.name = name; self.deltas = deltas }
}
/// Only bindings live in the animation graph. The host retains the sole source Mesh.
public struct SimulationAnimationMeshBinding: Codable, Equatable, Sendable {
    public var sourceObjectID: String
    public var skin: [SimulationVertexSkin]
    public var morphs: [SimulationMeshMorph]
    public init(sourceObjectID:String,skin:[SimulationVertexSkin] = [],morphs:[SimulationMeshMorph] = []) {
        self.sourceObjectID = sourceObjectID; self.skin = skin; self.morphs = morphs
    }
    public func validate(boneIDs:Set<String>) throws {
        guard !sourceObjectID.isEmpty, skin.count <= 900_000, morphs.count <= 64,
              Set(skin.map(\.vertexIndex)).count == skin.count else { throw SimulationError.invalidInput("Invalid Mesh binding or vertex budget.") }
        for row in skin {
            guard row.vertexIndex >= 0, (1...4).contains(row.influences.count),
                  Set(row.influences.map(\.boneID)).count == row.influences.count,
                  row.influences.allSatisfy({ boneIDs.contains($0.boneID) && $0.weight.isFinite && $0.weight > 0 }),
                  abs(row.influences.reduce(0) { $0+$1.weight }-1) < 1e-8 else { throw SimulationError.invalidInput("Mesh skin weights must sum to one and reference existing bones.") }
        }
        var total = 0
        for morph in morphs {
            total += morph.deltas.count
            guard !morph.name.isEmpty, total <= 1_000_000, Set(morph.deltas.map(\.vertexIndex)).count == morph.deltas.count,
                  morph.deltas.allSatisfy({ $0.vertexIndex >= 0 && $0.offset.isFinite }) else { throw SimulationError.invalidInput("Invalid Mesh Morph deltas.") }
        }
    }
}

public enum SimulationAnimationMeshDeformer {
    public static func deform(_ positions:[SimulationVector3],sourceObjectID:String,graph:SimulationAnimationGraph,pose:SimulationAnimationPose) throws -> [SimulationVector3] {
        guard positions.count <= 900_000, positions.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("Invalid source Mesh vertices.") }
        guard let binding = graph.meshBindings?.first(where: { $0.sourceObjectID == sourceObjectID }) else { return positions }
        try binding.validate(boneIDs:Set(graph.bones.map(\.id)))
        let weights = pose.morphWeights[sourceObjectID] ?? Array(repeating:0,count:binding.morphs.count)
        guard weights.count == binding.morphs.count, weights.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("Morph weights do not match this Mesh.") }
        var result = positions
        for (morph,weight) in zip(binding.morphs,weights) where weight != 0 {
            for delta in morph.deltas {
                guard result.indices.contains(delta.vertexIndex) else { throw SimulationError.staleSource }
                result[delta.vertexIndex] = result[delta.vertexIndex]+delta.offset*weight
            }
        }
        guard !binding.skin.isEmpty else { return result }
        guard binding.skin.count == positions.count else { throw SimulationError.invalidInput("Bind every source Mesh vertex before skeletal playback.") }
        var rest: [String:SimulationAnimationTransform] = [:]
        for bone in graph.bones {
            rest[bone.id] = try bone.parentID.map {
                guard let parent = rest[$0] else { throw SimulationError.invalidInput("Order the skeleton parents before their children.") }
                return try SimulationAnimationMath.compose(parent,bone.restLocal)
            } ?? bone.restLocal
        }
        for (i,row) in binding.skin.enumerated() {
            if i & 4095 == 0 { try Task.checkCancellation() }
            guard result.indices.contains(row.vertexIndex) else { throw SimulationError.staleSource }
            let point = result[row.vertexIndex]
            var transformed = SimulationVector3.zero
            for influence in row.influences {
                guard let bind = rest[influence.boneID], let posed = pose.worldBones[influence.boneID] else { throw SimulationError.staleSource }
                let p = SimulationAnimationMath.rotate(SimulationAnimationMath.inverse(bind.rotation),point-bind.translation)
                let local = SimulationVector3(p.x/bind.scale.x,p.y/bind.scale.y,p.z/bind.scale.z)
                let scaled = SimulationVector3(local.x*posed.scale.x,local.y*posed.scale.y,local.z*posed.scale.z)
                transformed = transformed+(SimulationAnimationMath.rotate(posed.rotation,scaled)+posed.translation)*influence.weight
            }
            guard transformed.isFinite else { throw SimulationError.invalidInput("The skeletal pose produced invalid vertices.") }
            result[row.vertexIndex] = transformed
        }
        return result
    }
    /// A useful initial binding; weights remain explicit and editable through the same graph.
    public static func bindNearest(positions:[SimulationVector3],sourceObjectID:String,bones:[SimulationAnimationBone]) throws -> SimulationAnimationMeshBinding {
        guard !bones.isEmpty, bones.count <= 4096, Set(bones.map(\.id)).count == bones.count, positions.count <= 200_000,
              positions.count*bones.count <= 10_000_000 else { throw SimulationError.resourceLimit("Use fewer bones or a lower resolution Mesh for initial binding.") }
        var world:[String:SimulationAnimationTransform] = [:]
        for bone in bones {
            guard !bone.id.isEmpty, bone.restLocal.translation.isFinite, bone.restLocal.scale.isFinite,
                  min(bone.restLocal.scale.x,bone.restLocal.scale.y,bone.restLocal.scale.z) > 0, bone.restLocal.rotation.isFinite else { throw SimulationError.invalidInput("Use a valid skeleton for Mesh binding.") }
            world[bone.id] = try bone.parentID.map {
                guard let parent = world[$0] else { throw SimulationError.invalidInput("Order the skeleton parents before their children.") }
                return try SimulationAnimationMath.compose(parent,bone.restLocal)
            } ?? bone.restLocal
        }
        let skin = try positions.enumerated().map { index,point in
            if index & 1023 == 0 { try Task.checkCancellation() }
            guard point.isFinite, let bone = bones.min(by: { (world[$0.id]!.translation-point).length < (world[$1.id]!.translation-point).length }) else { throw SimulationError.invalidInput("Invalid Mesh binding position.") }
            return SimulationVertexSkin(vertexIndex:index,influences:[.init(boneID:bone.id,weight:1)])
        }
        return .init(sourceObjectID:sourceObjectID,skin:skin)
    }
}
