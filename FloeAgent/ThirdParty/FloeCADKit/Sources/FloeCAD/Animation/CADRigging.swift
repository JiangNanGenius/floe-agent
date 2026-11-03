// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

nonisolated struct CADRigPose: Codable, Equatable, Sendable {
    var translation: SIMD3<Double> = .zero
    var rotation: SIMD4<Double> = SIMD4(0, 0, 0, 1)
    var valid: Bool { [translation.x,translation.y,translation.z,rotation.x,rotation.y,rotation.z,rotation.w].allSatisfy { $0.isFinite && abs($0) <= 1e5 } && abs(simd_length(rotation) - 1) < 1e-6 }
    var matrix: simd_double4x4 {
        var value = simd_double4x4(simd_quatd(vector: rotation)); value.columns.3 = SIMD4(translation, 1); return value
    }
    static func mix(_ a: Self, _ b: Self, _ t: Double) -> Self {
        Self(translation: a.translation * (1-t) + b.translation * t,
             rotation: simd_slerp(simd_quatd(vector:a.rotation),simd_quatd(vector:b.rotation),t).vector)
    }
}
nonisolated struct CADRigJoint: Codable, Equatable, Sendable {
    var id: UUID = UUID(); var name: String; var parent: UUID?; var rest: CADRigPose
}
nonisolated struct CADRigInfluence: Codable, Equatable, Sendable { var jointID: UUID; var weight: Double }
nonisolated struct CADRigWeight: Codable, Equatable, Sendable { var vertexID: UUID; var influences: [CADRigInfluence] }
nonisolated struct CADRigDelta: Codable, Equatable, Sendable { var vertexID: UUID; var delta: SIMD3<Double> }
nonisolated struct CADRigMorph: Codable, Equatable, Sendable { var id: UUID = UUID(); var name: String; var deltas: [CADRigDelta]; var weight: Double = 0 }
nonisolated struct CADRigKey: Codable, Equatable, Sendable { var time: Double; var poses: [CADRigPose]; var morphWeights: [Double] }

/// Additive scene record. It references the sole authored polygon cage; it
/// does not own another body, rest mesh, camera, material or assembly pose.
public nonisolated struct CADRigRecord: Codable, Equatable, Sendable {
    var version = 1
    var id = UUID(); var bodyID: UUID; var featureID: UUID; var sourceSHA256: String
    var joints: [CADRigJoint]; var poses: [CADRigPose]; var weights: [CADRigWeight]
    var morphs: [CADRigMorph] = []; var keys: [CADRigKey] = []
    var duration: Double = 2; var clipID: UUID = UUID()
    func validate() throws {
        guard version == 1, (1...16).contains(joints.count), joints.filter({$0.parent == nil}).count == 1, joints.first?.parent == nil, poses.count == joints.count,
              sourceSHA256.count == 64, sourceSHA256.allSatisfy(\.isHexDigit),
              (1...256).contains(weights.count), morphs.count <= 4, keys.count <= 64,
              duration.isFinite, (0.1...10).contains(duration),
              Set(joints.map(\.id)).count == joints.count, Set(weights.map(\.vertexID)).count == weights.count,
              Set(morphs.map(\.id)).count == morphs.count, poses.allSatisfy(\.valid) else { throw CADRigError.invalid }
        var prior = Set<UUID>()
        for joint in joints {
            guard !joint.name.isEmpty, joint.name.count <= 80, joint.rest.valid,
                  joint.parent.map({ prior.contains($0) }) ?? true else { throw CADRigError.invalid }
            prior.insert(joint.id)
        }
        let vertices = Set(weights.map(\.vertexID))
        for row in weights {
            guard (1...4).contains(row.influences.count), Set(row.influences.map(\.jointID)).count == row.influences.count,
                  row.influences.allSatisfy({ prior.contains($0.jointID) && $0.weight.isFinite && $0.weight > 0 && $0.weight <= 1 }),
                  abs(row.influences.reduce(0) { $0 + $1.weight } - 1) <= 1e-8 else { throw CADRigError.invalid }
        }
        for morph in morphs {
            guard !morph.name.isEmpty, morph.name.count <= 80, morph.weight.isFinite, (-1...1).contains(morph.weight),
                  morph.deltas.count <= 256, Set(morph.deltas.map(\.vertexID)).count == morph.deltas.count,
                  morph.deltas.allSatisfy({ vertices.contains($0.vertexID) && finite($0.delta) }) else { throw CADRigError.invalid }
        }
        var last = -Double.infinity
        for key in keys {
            guard key.time.isFinite, (0...duration).contains(key.time), key.time > last,
                  key.poses.count == joints.count, key.poses.allSatisfy(\.valid), key.morphWeights.count == morphs.count,
                  key.morphWeights.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { throw CADRigError.invalid }
            last = key.time
        }
    }
    func finite(_ p: SIMD3<Double>) -> Bool { [p.x,p.y,p.z].allSatisfy { $0.isFinite && abs($0) <= 1e5 } }
    func sample(_ time: Double?) -> (poses: [CADRigPose], weights: [Double]) {
        guard let time, !keys.isEmpty else { return (poses,morphs.map(\.weight)) }
        let t = min(max(time.isFinite ? time : 0,0),duration)
        guard let b = keys.firstIndex(where: { $0.time >= t }) else { return (keys.last!.poses,keys.last!.morphWeights) }
        if b == 0 { return (keys[0].poses,keys[0].morphWeights) }
        let a = keys[b-1], z = keys[b], f = (t-a.time)/(z.time-a.time)
        return (zip(a.poses,z.poses).map { CADRigPose.mix($0.0,$0.1,f) },zip(a.morphWeights,z.morphWeights).map { $0.0*(1-f)+$0.1*f })
    }
    func world(_ poses: [CADRigPose]) -> [simd_double4x4] {
        var result: [simd_double4x4] = [], ids: [UUID:Int] = [:]
        for (index,joint) in joints.enumerated() {
            let parent = joint.parent.flatMap { ids[$0] }.map { result[$0] } ?? matrix_identity_double4x4
            result.append(parent * poses[index].matrix); ids[joint.id] = index
        }
        return result
    }
}
public nonisolated struct CADRigDeformation: Equatable, Sendable {
    public var bodyID: UUID; public var positions: [SIMD3<Float>]; public var normals: [SIMD3<Float>]
    /// Content identity, not document changeCount: metadata/save changes must
    /// not rebuild an unchanged stage or revoke an active export lease.
    var contentRevision:UInt64 {
        var data=Data()
        for p in positions + normals { for value in [p.x,p.y,p.z] {
            var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) }
        } }
        return UInt64(CADMaterialTexture.digest(data).prefix(16),radix:16) ?? 0
    }
}
public nonisolated struct CADRigPlayback: Equatable, Sendable {
    var record: CADRigRecord; var vertexIDs: [UUID]; var render: RenderMesh
    func evaluate(at time: Double?) throws -> CADRigDeformation {
        try record.validate()
        let sampled = record.sample(time), rest = record.world(record.joints.map(\.rest)), posed = record.world(sampled.poses)
        let matrices = zip(posed,rest).map { $0.0 * simd_inverse($0.1) }
        let jointIndex = Dictionary(uniqueKeysWithValues: record.joints.enumerated().map { ($0.element.id,$0.offset) })
        let weights = Dictionary(uniqueKeysWithValues: record.weights.map { ($0.vertexID,$0.influences) })
        var deltas: [UUID:SIMD3<Double>] = [:]
        for (index,morph) in record.morphs.enumerated() { for delta in morph.deltas { deltas[delta.vertexID,default:.zero] += delta.delta * sampled.weights[index] } }
        guard vertexIDs.count == render.positions.count, render.positions.count <= 4096, render.indices.count <= 3072 else { throw CADRigError.invalid }
        var positions: [SIMD3<Float>] = []; positions.reserveCapacity(vertexIDs.count)
        for (index,id) in vertexIDs.enumerated() {
            if index & 255 == 0, Task.isCancelled { throw CADRigError.cancelled }
            guard let influences = weights[id] else { throw CADRigError.stale }
            let p = SIMD3<Double>(render.positions[index]) + (deltas[id] ?? .zero)
            var result = SIMD4<Double>.zero
            for influence in influences { guard let j = jointIndex[influence.jointID] else { throw CADRigError.invalid }; result += (matrices[j] * SIMD4(p,1)) * influence.weight }
            guard record.finite(SIMD3(result.x,result.y,result.z)) else { throw CADRigError.invalid }
            positions.append(SIMD3(Float(result.x),Float(result.y),Float(result.z)))
        }
        var normals = [SIMD3<Float>](repeating:.zero,count:positions.count)
        for i in stride(from:0,to:render.indices.count,by:3) {
            let a=Int(render.indices[i]), b=Int(render.indices[i+1]), c=Int(render.indices[i+2])
            guard positions.indices.contains(a),positions.indices.contains(b),positions.indices.contains(c) else { throw CADRigError.invalid }
            let n=simd_cross(positions[b]-positions[a],positions[c]-positions[a])
            guard simd_length(n)>1e-10 else { throw CADRigError.degenerate }
            normals[a]+=n;normals[b]+=n;normals[c]+=n
        }
        guard normals.allSatisfy({ simd_length($0)>1e-10 }) else { throw CADRigError.degenerate }
        return CADRigDeformation(bodyID:record.bodyID,positions:positions,normals:normals.map(simd_normalize))
    }
}
nonisolated enum CADRigError: String, Error, LocalizedError {
    case invalid="invalid_rig", stale="rig_source_changed", unsupported="rig_scope", cancelled="rig_cancelled", degenerate="rig_degenerate"
    var errorDescription: String? {
        switch self {
        case .invalid: FloeCADStrings.text("cad.rig.invalid","Check the joint, vertex weights and shape-key values.")
        case .stale: FloeCADStrings.text("cad.rig.stale","The polygon source changed. Bind it again before editing or export.")
        case .unsupported: FloeCADStrings.text("cad.rig.scope","Bind one polygon cage without enabled modifiers. CAD solids, IK and FBX authoring are outside this scope.")
        case .cancelled: FloeCADStrings.text("cad.rig.cancelled","The operation was cancelled.")
        case .degenerate: FloeCADStrings.text("cad.rig.degenerate","This pose collapses a triangle. Adjust the pose or weights.")
        }
    }
}
nonisolated enum CADRigCodec {
    static func read(_ data: Data?) throws -> CADRigRecord? {
        guard let data else { return nil }
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard let raw=root?["rigging"], !(raw is NSNull) else { return nil }
        let bytes=try JSONSerialization.data(withJSONObject:raw)
        guard bytes.count <= 512*1024, let row=raw as? [String:Any],
              Set(row.keys).isSubset(of:["version","id","bodyID","featureID","sourceSHA256","joints","poses","weights","morphs","keys","duration","clipID"]) else { throw CADRigError.invalid }
        func rows(_ raw:Any?,_ keys:Set<String>) -> [[String:Any]]? {
            guard let values=raw as? [[String:Any]],values.allSatisfy({Set($0.keys).isSubset(of:keys)}) else { return nil };return values
        }
        func pose(_ raw:Any?) -> Bool { guard let value=raw as? [String:Any] else { return false };return Set(value.keys)==Set(["translation","rotation"]) }
        guard let joints=rows(row["joints"],["id","name","parent","rest"]),joints.allSatisfy({pose($0["rest"])}),
              let poses=row["poses"] as? [Any],poses.allSatisfy({pose($0)}),
              let weights=rows(row["weights"],["vertexID","influences"]),weights.allSatisfy({rows($0["influences"],["jointID","weight"]) != nil}),
              let morphs=rows(row["morphs"],["id","name","deltas","weight"]),morphs.allSatisfy({rows($0["deltas"],["vertexID","delta"]) != nil}),
              let keys=rows(row["keys"],["time","poses","morphWeights"]),keys.allSatisfy({ ($0["poses"] as? [Any])?.allSatisfy({pose($0)}) == true }) else { throw CADRigError.invalid }
        let result=try JSONDecoder().decode(CADRigRecord.self,from:bytes);try result.validate();return result
    }
}
