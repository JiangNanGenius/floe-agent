// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

public nonisolated struct CADSimulationSkeletonSource: Codable, Sendable {
    public nonisolated struct Joint: Codable, Sendable {
        public var id: String
        public var parentID: String?
        public var restTranslationMM: [Double]
        public var restRotation: [Double]
    }
    public nonisolated struct Influence: Codable, Sendable { public var boneID:String; public var weight:Double }
    public nonisolated struct Vertex: Codable, Sendable { public var index:Int; public var influences:[Influence] }
    public nonisolated struct Delta: Codable, Sendable { public var index:Int; public var offsetMM:[Double] }
    public nonisolated struct Morph: Codable, Sendable { public var name:String; public var deltas:[Delta] }
    public nonisolated struct Key: Codable, Sendable {
        public var timeSeconds:Double
        public var translationsMM:[[Double]]
        public var rotations:[[Double]]
        public var morphWeights:[Double]
    }
    public var objectID:String
    public var placement:[Double]
    public var durationSeconds:Double
    public var joints:[Joint]
    public var skin:[Vertex]
    public var morphs:[Morph]
    public var keys:[Key]
}

public nonisolated struct CADSimulationAnimationSource: Sendable {
    public var clips:[CADAnimationClip]
    public var activeClipID:UUID?
    public var skeleton:CADSimulationSkeletonSource?
    public nonisolated struct Pose:Sendable {
        public var translationMeters:SIMD3<Double>
        public var rotation:SIMD4<Double>
        public var scale:SIMD3<Double>
    }
    public nonisolated struct Frame:Sendable {
        public var timeSeconds:Double
        public var objects:[String:Pose]
        public var camera:CADSimulationCamera?
    }
    public var frames:[Frame]
    public var durationSeconds:Double?
}

public nonisolated struct CADSimulationGLBSource: Sendable {
    public nonisolated struct Target: Sendable {
        public var objectID:String
        public var nodeIndex:Int
        public var originMM:[Double]
    }
    public var data:Data
    public var targets:[Target]
}

public nonisolated struct CADSimulationExportPart: Sendable {
    public var objectID:String
    public var positionsMM:[SIMD3<Float>]
    public var indices:[UInt32]
    public var translationMM:SIMD3<Double>
    public var rotation:SIMD4<Double>
    public var color:SIMD4<Float>
    public init(objectID:String,positionsMM:[SIMD3<Float>],indices:[UInt32],translationMM:SIMD3<Double>,rotation:SIMD4<Double> = SIMD4(0,0,0,1),color:SIMD4<Float> = SIMD4(0.65,0.65,0.7,1)) {
        self.objectID = objectID; self.positionsMM = positionsMM; self.indices = indices; self.translationMM = translationMM; self.rotation = rotation; self.color = color
    }
}

@MainActor public extension FloeCADDocument {
    /// The same authored rig/clip, captured without writing preview or editor state.
    func simulationAnimationSource() throws -> CADSimulationAnimationSource {
        guard !isClosed else { throw CADDocumentError(code:"source_unavailable",message:"Reopen the model first.") }
        var skeleton:CADSimulationSkeletonSource?
        if let record = try CADRigCodec.read(session.document.sceneSettingsData) {
            let playback = try CADRiggingService(document:self).playback(record)
            guard let body = session.document.bodies.first(where: { $0.id.raw == record.bodyID }) else { throw CADRigError.stale }
            let matrix = body.transform.matrix
            let weights = Dictionary(uniqueKeysWithValues:record.weights.map { ($0.vertexID,$0.influences) })
            let skin = try playback.vertexIDs.enumerated().map { index,id in
                guard let values = weights[id] else { throw CADRigError.stale }
                return CADSimulationSkeletonSource.Vertex(index:index,influences:values.map { .init(boneID:$0.jointID.uuidString.lowercased(),weight:$0.weight) })
            }
            let morphs = record.morphs.map { morph in
                let deltas = Dictionary(uniqueKeysWithValues:morph.deltas.map { ($0.vertexID,$0.delta) })
                return CADSimulationSkeletonSource.Morph(name:morph.name,deltas:playback.vertexIDs.enumerated().compactMap { index,id in
                    deltas[id].map { .init(index:index,offsetMM:[$0.x,$0.y,$0.z]) }
                })
            }
            let poseKeys = record.keys.isEmpty ? [CADRigKey(time:0,poses:record.poses,morphWeights:record.morphs.map(\.weight))] : record.keys
            skeleton = .init(objectID:body.id.raw.uuidString.lowercased(),
                placement:[matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z,matrix.columns.0.w,matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z,matrix.columns.1.w,matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z,matrix.columns.2.w,matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z,matrix.columns.3.w],
                durationSeconds:record.duration,joints:record.joints.map {
                    .init(id:$0.id.uuidString.lowercased(),parentID:$0.parent?.uuidString.lowercased(),restTranslationMM:[$0.rest.translation.x,$0.rest.translation.y,$0.rest.translation.z],restRotation:[$0.rest.rotation.x,$0.rest.rotation.y,$0.rest.rotation.z,$0.rest.rotation.w])
                },skin:skin,morphs:morphs,keys:poseKeys.map { key in
                    .init(timeSeconds:key.time,translationsMM:key.poses.map { [$0.translation.x,$0.translation.y,$0.translation.z] },rotations:key.poses.map { [$0.rotation.x,$0.rotation.y,$0.rotation.z,$0.rotation.w] },morphWeights:key.morphWeights)
                })
        }
        let animation = animationDocument
        var frames:[CADSimulationAnimationSource.Frame] = []
        if let clip = animation.activeClip, clip.rigID == nil, !clip.tracks.isEmpty || clip.physicsCacheID != nil {
            guard clip.duration.isFinite, (0.000001...600).contains(clip.duration) else { throw CADDocumentError(code:"animation_duration",message:"Choose an animation duration between zero and ten minutes.") }
            let scene = sceneSnapshot(includeExplodedPreview:false,includeAnimationPreview:false)
            let origins = Dictionary(uniqueKeysWithValues:scene.bodies.filter { !$0.isHidden }.map { body in
                let count = Double(max(1,body.mesh.positions.count)), m = body.transform
                let matrix = simd_double4x4(SIMD4(m[0],m[1],m[2],m[3]),SIMD4(m[4],m[5],m[6],m[7]),SIMD4(m[8],m[9],m[10],m[11]),SIMD4(m[12]*0.001,m[13]*0.001,m[14]*0.001,m[15]))
                let center = body.mesh.positions.reduce(SIMD3<Double>.zero) { $0+SIMD3(Double($1.x)*0.001/count,Double($1.y)*0.001/count,Double($1.z)*0.001/count) }
                return (body.id,(matrix,matrix*SIMD4(center,1)))
            })
            let targetCount = max(1,clip.physicsCacheID == nil ? clip.tracks.count:origins.count)
            let count = min(Int(ceil(clip.duration*30))+1,max(2,50_000/targetCount))
            for index in 0..<count {
                try Task.checkCancellation()
                let time = clip.duration*Double(index)/Double(count-1), evaluation = try evaluateAnimation(clipID:clip.id,time:time)
                guard evaluation.issues.isEmpty else { throw CADDocumentError(code:"animation_source",message:"Review the existing animation's source bindings before importing it.") }
                let matrices = CADAnimationPresentationAdapter.instanceMatrices(evaluation,document:self)
                var poses:[String:CADSimulationAnimationSource.Pose] = [:]
                for (id,matrix) in matrices {
                    guard let (baseline,center) = origins[id] else { continue }
                    let current = simd_double4x4(SIMD4<Double>(matrix.columns.0),SIMD4<Double>(matrix.columns.1),SIMD4<Double>(matrix.columns.2),SIMD4<Double>(matrix.columns.3))
                    let delta = current*simd_inverse(baseline), position = delta*center
                    let x = SIMD3(delta.columns.0.x,delta.columns.0.y,delta.columns.0.z), y = SIMD3(delta.columns.1.x,delta.columns.1.y,delta.columns.1.z), z = SIMD3(delta.columns.2.x,delta.columns.2.y,delta.columns.2.z)
                    let scale = SIMD3(simd_length(x),simd_length(y),simd_length(z))
                    guard min(scale.x,scale.y,scale.z)>1e-12,simd_determinant(simd_double3x3(columns:(x,y,z)))>0 else { throw CADDocumentError(code:"animation_placement",message:"Apply reflected or singular placement before importing animation.") }
                    let rotation = simd_double3x3(columns:(x/scale.x,y/scale.y,z/scale.z))
                    guard abs(simd_dot(rotation.columns.0,rotation.columns.1))+abs(simd_dot(rotation.columns.0,rotation.columns.2))+abs(simd_dot(rotation.columns.1,rotation.columns.2))<1e-7 else { throw CADDocumentError(code:"animation_placement",message:"Apply sheared placement before importing animation.") }
                    poses[id.uuidString.lowercased()] = .init(translationMeters:SIMD3(position.x,position.y,position.z),rotation:simd_quatd(rotation).vector,scale:scale)
                }
                var camera:CADSimulationCamera?
                if let value = evaluation.camera {
                    let back = SIMD3(cos(value.elevationRadians)*sin(value.azimuthRadians),sin(value.elevationRadians),cos(value.elevationRadians)*cos(value.azimuthRadians))
                    let right = simd_normalize(simd_cross(SIMD3<Double>(0,1,0),back)), up = simd_cross(back,right)
                    camera = .init(positionMeters:value.target+back*value.distance,rotation:simd_quatd(simd_double3x3(columns:(right,up,back))).vector,verticalFOVDegrees:value.fovYDegrees)
                }
                frames.append(.init(timeSeconds:time,objects:poses,camera:camera))
            }
        }
        return .init(clips:animation.clips,activeClipID:animation.activeClipID,skeleton:skeleton,frames:frames,durationSeconds:animation.activeClip?.duration)
    }

    /// Reuses the ordinary material/texture GLB writer. Only private value copies
    /// are recentered for animation; the saved source and its undo stack stay intact.
    func simulationGLBSource(expectedGeometrySHA256:String,extraParts:[CADSimulationExportPart] = []) throws -> CADSimulationGLBSource {
        let geometry = try simulationGeometry()
        guard geometry.contentSHA256 == expectedGeometrySHA256 else { throw CADDocumentError(code:"source_changed",message:"The model changed. Try exporting again.") }
        let scene = sceneSnapshot(includeExplodedPreview:false,includeAnimationPreview:false)
        var bodies:[Body] = [], nodes:[GLBSceneNode] = [], origins:[String:[Double]] = [:]
        var faceTables:[BodyID:FaceTable] = [:], revisions:[BodyID:UInt64] = [:]
        for captured in geometry.bodies {
            try Task.checkCancellation()
            guard let placed = scene.bodies.first(where: { $0.id == captured.id }),
                  var body = session.document.bodies.first(where: { $0.id.raw == (placed.sourceBodyID ?? captured.id) }) else { throw CADDocumentError(code:"source_changed",message:"A model part changed.") }
            let count = Double(captured.positionsMM.count)
            let center = captured.positionsMM.reduce(SIMD3<Double>.zero) { $0+SIMD3($1[0]/count,$1[1]/count,$1[2]/count) }
            let original = body
            let table = session.faceRangeTable(for:body)
            body = Body(id:BodyID(raw:captured.id),name:captured.name,transform:.identity,primitive:body.primitive,render:body.render,revision:body.meshRevision)
            body.material = original.material; body.materialFaceBindings = original.materialFaceBindings
            body.uvData = original.uvData; body.brep = original.brep; body.surfaceBRep = original.surfaceBRep
            body.render.positions = captured.positionsMM.map { SIMD3(Float($0[0]-center.x),Float($0[1]-center.y),Float($0[2]-center.z)) }
            body.render.indices = captured.indices
            body.render.texcoords = placed.mesh.renderTexcoords ?? placed.mesh.texcoords
            var normals = Array(repeating:SIMD3<Float>.zero,count:body.render.positions.count)
            for i in stride(from:0,to:captured.indices.count,by:3) {
                let a = Int(captured.indices[i]), b = Int(captured.indices[i+1]), c = Int(captured.indices[i+2])
                let n = simd_cross(body.render.positions[b]-body.render.positions[a],body.render.positions[c]-body.render.positions[a])
                normals[a] += n; normals[b] += n; normals[c] += n
            }
            body.render.normals = normals.map { simd_length_squared($0) > 1e-20 ? simd_normalize($0):SIMD3(0,1,0) }
            if var table {
                if table.nativeBodyID != nil { table.nativeBodyID = body.id; table.nativeMeshRevision = body.meshRevision }
                faceTables[body.id] = table; revisions[body.id] = body.meshRevision
            }
            let objectID = captured.id.uuidString.lowercased(), origin = [center.x,center.y,center.z]
            origins[objectID] = origin
            nodes.append(.init(name:captured.name,bodyIndex:bodies.count,
                matrix:[1,0,0,0,0,1,0,0,0,0,1,0,center.x,center.y,center.z,1],extras:["floe_simulation_object_id":objectID]))
            bodies.append(body)
        }
        guard extraParts.count <= 4096 else { throw CADDocumentError(code:"export_size",message:"Reduce the number of exported particles or bodies.") }
        for part in extraParts where origins[part.objectID] == nil {
            try Task.checkCancellation()
            guard !part.positionsMM.isEmpty, part.positionsMM.count <= 200_000, part.indices.count.isMultiple(of:3),
                  part.indices.allSatisfy({ Int($0) < part.positionsMM.count }), part.positionsMM.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  simd_length(part.rotation)>1e-12 else { throw CADDocumentError(code:"export_geometry",message:"A simulated body has invalid geometry.") }
            var normals = Array(repeating:SIMD3<Float>.zero,count:part.positionsMM.count)
            for i in stride(from:0,to:part.indices.count,by:3) {
                let a = Int(part.indices[i]), b = Int(part.indices[i+1]), c = Int(part.indices[i+2])
                let n = simd_cross(part.positionsMM[b]-part.positionsMM[a],part.positionsMM[c]-part.positionsMM[a]); normals[a] += n; normals[b] += n; normals[c] += n
            }
            let render = RenderMesh(positions:part.positionsMM,normals:normals.map { simd_length_squared($0)>1e-20 ? simd_normalize($0):SIMD3(0,1,0) },indices:part.indices)
            var body = Body(id:BodyID(),name:part.objectID,transform:.identity,primitive:nil,render:render,revision:1)
            body.material = BodyMaterialSpec(baseColor:SIMD4(Double(part.color.x),Double(part.color.y),Double(part.color.z),Double(part.color.w)),metallic:0,roughness:0.5)
            var matrix = simd_double4x4(simd_quatd(vector:part.rotation)); matrix.columns.3 = SIMD4(part.translationMM,1)
            nodes.append(.init(name:part.objectID,bodyIndex:bodies.count,
                matrix:(0..<4).flatMap { column in (0..<4).map { matrix[column][$0] } },extras:["floe_simulation_object_id":part.objectID]))
            origins[part.objectID] = [part.translationMM.x,part.translationMM.y,part.translationMM.z]; bodies.append(body)
        }
        let data = GLBExporter.glb(bodies:bodies,faceTables:faceTables,faceTableRevisions:revisions,sceneGraph:nodes)
        guard data.count >= 20 else { throw CADDocumentError(code:"export_failed",message:"The model could not be exported.") }
        let length = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset:12,as:UInt32.self).littleEndian) }
        guard length <= data.count-20, let json = try JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+length))) as? [String:Any],let exported = json["nodes"] as? [[String:Any]] else { throw CADDocumentError(code:"export_failed",message:"The exported scene could not be read.") }
        let targets = exported.enumerated().compactMap { index,node -> CADSimulationGLBSource.Target? in
            guard let extras = node["extras"] as? [String:Any],let id = extras["floe_simulation_object_id"] as? String,let origin = origins[id] else { return nil }
            return .init(objectID:id,nodeIndex:index,originMM:origin)
        }
        guard targets.count == bodies.count else { throw CADDocumentError(code:"export_failed",message:"An exported model part lost its identity.") }
        return .init(data:data,targets:targets)
    }
}
