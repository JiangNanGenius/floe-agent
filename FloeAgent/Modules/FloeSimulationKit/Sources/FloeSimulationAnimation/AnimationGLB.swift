import Foundation
import CryptoKit
import simd
import FloeSimulationCore

public struct SimulationGLBTarget: Sendable {
    public var sourceObjectID:String
    public var nodeIndex:Int
    public var originMeters:SimulationVector3
    public init(sourceObjectID:String,nodeIndex:Int,originMeters:SimulationVector3) {
        self.sourceObjectID = sourceObjectID; self.nodeIndex = nodeIndex; self.originMeters = originMeters
    }
}
public struct SimulationAnimationVertexFrames: Sendable {
    public var sourceObjectID:String
    public var positionsMeters:[[SimulationVector3]]
    public init(sourceObjectID:String,positionsMeters:[[SimulationVector3]]) { self.sourceObjectID = sourceObjectID; self.positionsMeters = positionsMeters }
}

/// Adds actual sampled animation/skin/Morph data to the host's existing GLB,
/// preserving its meshes, PBR materials, images and texture references.
public enum SimulationAnimationGLBExporter {
    public static func export(baseGLB:Data,graph:SimulationAnimationGraph,bake:SimulationAnimationBake,
                              targets:[SimulationGLBTarget],vertexFrames:[SimulationAnimationVertexFrames] = [],
                              unitsPerMeter:Double = 1000,maximumBytes:Int = 128*1024*1024) throws -> Data {
        try graph.validate(); try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data:try encoder.encode(graph)).map { String(format:"%02x",$0) }.joined()
        guard graph.source == bake.source, graph.physicsResultID == bake.physicsResultID, bake.graphSHA256 == digest else { throw SimulationError.staleSource }
        guard baseGLB.count >= 28, baseGLB.count <= maximumBytes, unitsPerMeter.isFinite, unitsPerMeter > 0,
              maximumBytes <= 256*1024*1024, bake.frames.count >= 2, bake.frames.count <= 144_001,
              targets.count <= 8192, Set(targets.map(\.sourceObjectID)).count == targets.count,
              Set(targets.map(\.nodeIndex)).count == targets.count,
              bake.frames.first?.timeSeconds == 0, bake.frames.last?.timeSeconds == graph.durationSeconds,
              zip(bake.frames,bake.frames.dropFirst()).allSatisfy({ $0.timeSeconds.isFinite && $0.timeSeconds < $1.timeSeconds }) else { throw SimulationError.invalidInput("Invalid animation export identity, time or budget.") }
        func uint(_ offset:Int) throws -> UInt32 {
            guard offset >= 0, offset <= baseGLB.count-4 else { throw SimulationError.corruptArchive("Invalid GLB bounds.") }
            return baseGLB.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian }
        }
        guard try uint(0) == 0x46546c67, try uint(4) == 2, try uint(8) == baseGLB.count,
              try uint(16) == 0x4e4f534a else { throw SimulationError.corruptArchive("Use a valid glTF 2 binary scene.") }
        let jsonLength = Int(try uint(12)), binHeader = 20+jsonLength
        guard jsonLength <= baseGLB.count-28, jsonLength.isMultiple(of:4), try uint(binHeader+4) == 0x004e4942,
              var root = try JSONSerialization.jsonObject(with:baseGLB.subdata(in:20..<binHeader)) as? [String:Any],
              var nodes = root["nodes"] as? [[String:Any]], var meshes = root["meshes"] as? [[String:Any]],
              var views = root["bufferViews"] as? [[String:Any]], var accessors = root["accessors"] as? [[String:Any]],
              let buffers = root["buffers"] as? [[String:Any]], buffers.count == 1, buffers[0]["uri"] == nil,
              let originalBytes = buffers[0]["byteLength"] as? Int, originalBytes >= 0,
              originalBytes <= Int(try uint(binHeader)), Int(try uint(binHeader))+binHeader+8 == baseGLB.count,
              targets.allSatisfy({ nodes.indices.contains($0.nodeIndex) && $0.originMeters.isFinite }) else { throw SimulationError.corruptArchive("The GLB scene cannot be animated safely.") }
        var bin = baseGLB.subdata(in:(binHeader+8)..<(binHeader+8+originalBytes))
        var samplers:[[String:Any]] = [], channels:[[String:Any]] = [], skins = root["skins"] as? [[String:Any]] ?? []
        func floats(_ values:[Double]) throws -> Data {
            guard values.count <= maximumBytes/4 else { throw SimulationError.resourceLimit("Reduce the animation export size.") }
            var data = Data(capacity:values.count*4)
            for (index,value) in values.enumerated() {
                if index & 16383 == 0 { try Task.checkCancellation() }
                guard value.isFinite, Float(value).isFinite else { throw SimulationError.invalidInput("Animation values must be finite.") }
                var bits = Float(value).bitPattern.littleEndian
                withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) }
            }
            return data
        }
        func append(_ bytes:Data,component:Int = 5126,count:Int,type:String,target:Int? = nil,minimum:[Double]? = nil,maximum:[Double]? = nil) throws -> Int {
            while bin.count%4 != 0 { bin.append(0) }
            guard bytes.count <= maximumBytes-bin.count else { throw SimulationError.resourceLimit("Reduce duration, sampling rate or Mesh resolution for GLB export.") }
            var view:[String:Any] = ["buffer":0,"byteOffset":bin.count,"byteLength":bytes.count]
            if let target { view["target"] = target }
            let viewID = views.count; views.append(view); bin.append(bytes)
            var accessor:[String:Any] = ["bufferView":viewID,"componentType":component,"count":count,"type":type]
            if let minimum { accessor["min"] = minimum }; if let maximum { accessor["max"] = maximum }
            let id = accessors.count; accessors.append(accessor); return id
        }
        func values(_ index:Int,components:Int,requiredType:String) throws -> [[Double]] {
            guard accessors.indices.contains(index), accessors[index]["type"] as? String == requiredType,
                  accessors[index]["sparse"] == nil, let count = accessors[index]["count"] as? Int, (1...900_000).contains(count),
                  let viewID = accessors[index]["bufferView"] as? Int, views.indices.contains(viewID),
                  let length = views[viewID]["byteLength"] as? Int, length >= 0,
                  views[viewID]["buffer"] as? Int == 0,
                  let component = accessors[index]["componentType"] as? Int, [5121,5123,5125,5126].contains(component) else { throw SimulationError.corruptArchive("Invalid base GLB accessor.") }
            let size = component == 5121 ? 1:component == 5123 ? 2:4
            let stride = views[viewID]["byteStride"] as? Int ?? components*size
            let relative = accessors[index]["byteOffset"] as? Int ?? 0, start = views[viewID]["byteOffset"] as? Int ?? 0
            guard stride >= components*size, stride <= 256, relative >= 0, start >= 0,
                  length <= originalBytes-start, relative <= length,
                  (count-1)*stride+components*size <= length-relative else { throw SimulationError.corruptArchive("Base GLB accessor exceeds its buffer.") }
            return try (0..<count).map { row in
                if row & 4095 == 0 { try Task.checkCancellation() }
                return (0..<components).map { column in
                    let offset = start+relative+row*stride+column*size
                    return bin.withUnsafeBytes { bytes in
                        switch component {
                        case 5121: return Double(bytes.load(fromByteOffset:offset,as:UInt8.self))
                        case 5123: return Double(bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self).littleEndian)
                        case 5125: return Double(bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian)
                        default: return Double(Float(bitPattern:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian))
                        }
                    }
                }
            }
        }
        func channel(_ accessor:Int,node:Int,path:String,interpolation:String = "LINEAR",time:Int) {
            let id = samplers.count; samplers.append(["input":time,"output":accessor,"interpolation":interpolation])
            channels.append(["sampler":id,"target":["node":node,"path":path]])
        }
        func materializeTRS(_ node:Int) throws {
            guard let values = nodes[node]["matrix"] as? [Double] else { return }
            guard values.count == 16, values.allSatisfy(\.isFinite), abs(values[3])+abs(values[7])+abs(values[11])+abs(values[15]-1) < 1e-10 else { throw SimulationError.corruptArchive("Invalid animated node matrix.") }
            let x = SIMD3(values[0],values[1],values[2]), y = SIMD3(values[4],values[5],values[6]), z = SIMD3(values[8],values[9],values[10])
            var scale = SIMD3(simd_length(x),simd_length(y),simd_length(z))
            guard min(scale.x,scale.y,scale.z)>1e-12 else { throw SimulationError.corruptArchive("An animated node has singular placement.") }
            if simd_dot(x,simd_cross(y,z)) < 0 { scale.x = -scale.x }
            let rotation = simd_double3x3(columns:(x/scale.x,y/scale.y,z/scale.z))
            guard abs(simd_dot(rotation.columns.0,rotation.columns.1))+abs(simd_dot(rotation.columns.0,rotation.columns.2))+abs(simd_dot(rotation.columns.1,rotation.columns.2)) < 1e-8 else { throw SimulationError.unsupported("Apply sheared placement before animation export.") }
            let q = simd_quatd(rotation)
            nodes[node].removeValue(forKey:"matrix"); nodes[node]["translation"] = [values[12],values[13],values[14]]
            nodes[node]["rotation"] = [q.imag.x,q.imag.y,q.imag.z,q.real]; nodes[node]["scale"] = [scale.x,scale.y,scale.z]
        }
        let times = try append(floats(bake.frames.map(\.timeSeconds)),count:bake.frames.count,type:"SCALAR",minimum:[0],maximum:[graph.durationSeconds])
        func transformChannels(_ poses:[SimulationAnimationTransform],node:Int,hidden:[Bool]? = nil) throws {
            guard poses.count == bake.frames.count else { throw SimulationError.invalidInput("An animation target has missing samples.") }
            let translations = poses.flatMap { [$0.translation.x*unitsPerMeter,$0.translation.y*unitsPerMeter,$0.translation.z*unitsPerMeter] }
            var rotations:[Double] = [], previous:SimulationQuaternion?
            for value in poses {
                var q = value.rotation
                guard q.isFinite, abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1) < 1e-6 else { throw SimulationError.invalidInput("Invalid animation quaternion.") }
                if let p = previous, p.x*q.x+p.y*q.y+p.z*q.z+p.w*q.w < 0 { q = .init(x:-q.x,y:-q.y,z:-q.z,w:-q.w) }
                previous = q; rotations += [q.x,q.y,q.z,q.w]
            }
            let scales = poses.enumerated().flatMap { index,p in hidden?[index] == true ? [0.0,0.0,0.0]:[p.scale.x,p.scale.y,p.scale.z] }
            channel(try append(floats(translations),count:poses.count,type:"VEC3"),node:node,path:"translation",time:times)
            channel(try append(floats(rotations),count:poses.count,type:"VEC4"),node:node,path:"rotation",time:times)
            channel(try append(floats(scales),count:poses.count,type:"VEC3"),node:node,path:"scale",interpolation:hidden?.contains(true) == true ? "STEP":"LINEAR",time:times)
            nodes[node].removeValue(forKey:"matrix")
            let first = poses[0]
            nodes[node]["translation"] = [first.translation.x*unitsPerMeter,first.translation.y*unitsPerMeter,first.translation.z*unitsPerMeter]
            nodes[node]["rotation"] = [first.rotation.x,first.rotation.y,first.rotation.z,first.rotation.w]
            nodes[node]["scale"] = hidden?.first == true ? [0.0,0.0,0.0]:[first.scale.x,first.scale.y,first.scale.z]
        }
        let targetIDs = Set(targets.map(\.sourceObjectID)), cacheIDs = Set(vertexFrames.map(\.sourceObjectID))
        guard cacheIDs.count == vertexFrames.count, cacheIDs.isSubset(of:targetIDs),
              Set((graph.meshBindings ?? []).map(\.sourceObjectID)).isSubset(of:targetIDs) else { throw SimulationError.staleSource }
        let animatedObjects = Set(bake.frames.flatMap { $0.objects.keys }).subtracting(["camera"])
        guard animatedObjects.isSubset(of:targetIDs) else { throw SimulationError.invalidInput("An animation track refers to an object outside this model.") }
        var restWorld:[String:SimulationAnimationTransform] = [:]
        for bone in graph.bones { restWorld[bone.id] = try bone.parentID.map { try SimulationAnimationMath.compose(restWorld[$0]!,bone.restLocal) } ?? bone.restLocal }
        if bake.frames.contains(where: { $0.objects["camera"] != nil }) {
            let poses = try bake.frames.map { frame -> SimulationAnimationTransform in
                guard let camera = frame.objects["camera"] else { throw SimulationError.invalidInput("The camera has missing animation samples.") }; return camera
            }
            var cameras = root["cameras"] as? [[String:Any]] ?? []
            let cameraID = cameras.count, cameraNode = nodes.count
            nodes.append(["name":"Floe animated camera","camera":cameraID])
            let projections = bake.frames.map { $0.cameraProjection ?? .init() }, first = projections[0]
            if let height = first.orthographicHeightMeters {
                cameras.append(["type":"orthographic","orthographic":["xmag":height/2,"ymag":height/2,"znear":0.001,"zfar":100_000]])
            } else {
                cameras.append(["type":"perspective","perspective":["yfov":first.verticalFOVDegrees*Double.pi/180,"znear":0.001]])
            }
            if projections.contains(where: { $0 != first }) {
                var extensions = root["extensionsUsed"] as? [String] ?? []
                if !extensions.contains("KHR_animation_pointer") { extensions.append("KHR_animation_pointer") }; root["extensionsUsed"] = extensions
                func lensChannel(_ values:[Double],_ pointer:String) throws {
                    let output = try append(floats(values),count:values.count,type:"SCALAR"), id = samplers.count
                    samplers.append(["input":times,"output":output,"interpolation":"LINEAR"])
                    channels.append(["sampler":id,"target":["path":"pointer","extensions":["KHR_animation_pointer":["pointer":pointer]]]])
                }
                if first.orthographicHeightMeters != nil {
                    let heights = projections.compactMap(\.orthographicHeightMeters)
                    guard heights.count == projections.count else { throw SimulationError.invalidInput("Use a consistent camera projection throughout the animation.") }
                    try lensChannel(heights.map { $0/2 },"/cameras/\(cameraID)/orthographic/ymag")
                    try lensChannel(heights.map { $0/2 },"/cameras/\(cameraID)/orthographic/xmag")
                } else { try lensChannel(projections.map { $0.verticalFOVDegrees*Double.pi/180 },"/cameras/\(cameraID)/perspective/yfov") }
            }
            root["cameras"] = cameras
            try transformChannels(poses,node:cameraNode)
            let unitNode = nodes.count; nodes.append(["name":"Floe camera units","scale":[1/unitsPerMeter,1/unitsPerMeter,1/unitsPerMeter],"children":[cameraNode]])
            guard var scenes = root["scenes"] as? [[String:Any]], !scenes.isEmpty else { throw SimulationError.corruptArchive("The GLB needs an active scene.") }
            let scene = root["scene"] as? Int ?? 0
            guard scenes.indices.contains(scene) else { throw SimulationError.corruptArchive("Invalid active GLB scene.") }
            var roots = scenes[scene]["nodes"] as? [Int] ?? []; roots.append(unitNode); scenes[scene]["nodes"] = roots; root["scenes"] = scenes
        }
        if !graph.bones.isEmpty, !(graph.meshBindings ?? []).contains(where: { !$0.skin.isEmpty }) {
            var jointNodes:[String:Int] = [:], roots:[Int] = []
            for bone in graph.bones {
                let node = nodes.count; nodes.append(["name":bone.id]); jointNodes[bone.id] = node
                if let parentID = bone.parentID, let parent = jointNodes[parentID] {
                    var children = nodes[parent]["children"] as? [Int] ?? []; children.append(node); nodes[parent]["children"] = children
                } else { roots.append(node) }
                let poses = try bake.frames.map { frame in
                    guard let pose = frame.localBones[bone.id] else { throw SimulationError.staleSource }; return pose
                }
                try transformChannels(poses,node:node,hidden:bake.frames.map { $0.hiddenObjects.contains(bone.id) })
            }
            let unitNode = nodes.count; nodes.append(["name":"Floe skeleton units","scale":[1/unitsPerMeter,1/unitsPerMeter,1/unitsPerMeter],"children":roots])
            guard var scenes = root["scenes"] as? [[String:Any]], scenes.indices.contains(root["scene"] as? Int ?? 0) else { throw SimulationError.corruptArchive("The GLB needs an active scene.") }
            let scene = root["scene"] as? Int ?? 0
            var sceneRoots = scenes[scene]["nodes"] as? [Int] ?? []; sceneRoots.append(unitNode); scenes[scene]["nodes"] = sceneRoots; root["scenes"] = scenes
        }
        for target in targets {
            try Task.checkCancellation()
            let node = target.nodeIndex
            guard let meshID = nodes[node]["mesh"] as? Int, meshes.indices.contains(meshID),
                  var primitives = meshes[meshID]["primitives"] as? [[String:Any]], !primitives.isEmpty,
                  let attributes = primitives[0]["attributes"] as? [String:Any], let positionID = attributes["POSITION"] as? Int,
                  primitives.allSatisfy({ ($0["attributes"] as? [String:Any])?["POSITION"] as? Int == positionID }) else { throw SimulationError.corruptArchive("An animation target must name one actual Mesh node.") }
            let base = try values(positionID,components:3,requiredType:"VEC3")
            guard base.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw SimulationError.corruptArchive("Invalid base Mesh positions.") }
            var indices:[Int] = []
            for primitive in primitives {
                guard primitive["mode"] as? Int ?? 4 == 4, let index = primitive["indices"] as? Int else { throw SimulationError.corruptArchive("Use indexed triangle Meshes for animation export.") }
                indices += try values(index,components:1,requiredType:"SCALAR").map { Int($0[0]) }
            }
            guard indices.count.isMultiple(of:3), indices.allSatisfy({ base.indices.contains($0) }) else { throw SimulationError.corruptArchive("Invalid base Mesh triangle indices.") }
            let cache = vertexFrames.first { $0.sourceObjectID == target.sourceObjectID }
            let binding = graph.meshBindings?.first { $0.sourceObjectID == target.sourceObjectID }
            var motionNode = node
            if let binding, !binding.skin.isEmpty, cache == nil {
                // Animate a common parent, leaving the skinned Mesh node at
                // identity. Both its joint globals and its geometry then move
                // together in every conforming glTF skinning implementation.
                let wrapper = nodes.count
                let attachments = nodes[node].removeValue(forKey:"children") as? [Int] ?? []
                var value:[String:Any] = ["name":(nodes[node]["name"] as? String ?? target.sourceObjectID)+" motion","children":[node]+attachments,"extras":["floe_animation_target":target.sourceObjectID]]
                for key in ["matrix","translation","rotation","scale"] {
                    if let transform = nodes[node].removeValue(forKey:key) { value[key] = transform }
                }
                for parent in 0..<wrapper {
                    if let children = nodes[parent]["children"] as? [Int], children.contains(node) { nodes[parent]["children"] = children.map { $0 == node ? wrapper:$0 } }
                }
                if var scenes = root["scenes"] as? [[String:Any]] {
                    for i in scenes.indices { if let roots = scenes[i]["nodes"] as? [Int] { scenes[i]["nodes"] = roots.map { $0 == node ? wrapper:$0 } } }
                    root["scenes"] = scenes
                }
                nodes.append(value); motionNode = wrapper
            }
            if cache == nil, bake.frames.contains(where: { $0.objects[target.sourceObjectID] != nil || $0.hiddenObjects.contains(target.sourceObjectID) }) {
                let poses = bake.frames.map { $0.objects[target.sourceObjectID] ?? .init(translation:target.originMeters) }
                try transformChannels(poses,node:motionNode,hidden:bake.frames.map { $0.hiddenObjects.contains(target.sourceObjectID) })
            }
            if let binding, !binding.skin.isEmpty, cache == nil {
                guard nodes[node]["skin"] == nil, binding.skin.count == base.count else { throw SimulationError.invalidInput("The Mesh skin does not match the source vertices.") }
                let byVertex = Dictionary(uniqueKeysWithValues:binding.skin.map { ($0.vertexIndex,$0.influences) })
                let boneIndex = Dictionary(uniqueKeysWithValues:graph.bones.enumerated().map { ($0.element.id,$0.offset) })
                var jointBytes = Data(), weightValues:[Double] = []
                for vertex in base.indices {
                    guard let row = byVertex[vertex] else { throw SimulationError.staleSource }
                    for slot in 0..<4 {
                        let influence = row.indices.contains(slot) ? row[slot]:nil
                        var id = UInt16(influence.flatMap { boneIndex[$0.boneID] } ?? 0).littleEndian
                        withUnsafeBytes(of:&id) { jointBytes.append(contentsOf:$0) }; weightValues.append(influence?.weight ?? 0)
                    }
                }
                let jointsAccessor = try append(jointBytes,component:5123,count:base.count,type:"VEC4",target:34962)
                let weightsAccessor = try append(floats(weightValues),count:base.count,type:"VEC4",target:34962)
                for i in primitives.indices {
                    var values = primitives[i]["attributes"] as? [String:Any] ?? [:]
                    values["JOINTS_0"] = jointsAccessor; values["WEIGHTS_0"] = weightsAccessor; primitives[i]["attributes"] = values
                }
                var jointNodes:[Int] = [], matrices:[Double] = []
                for bone in graph.bones {
                    jointNodes.append(nodes.count); nodes.append(["name":bone.id])
                    let transform = restWorld[bone.id]!
                    var matrix = simd_double4x4(simd_quatd(ix:transform.rotation.x,iy:transform.rotation.y,iz:transform.rotation.z,r:transform.rotation.w))
                    matrix.columns.0 *= transform.scale.x; matrix.columns.1 *= transform.scale.y; matrix.columns.2 *= transform.scale.z
                    matrix.columns.3 = SIMD4((transform.translation.x-target.originMeters.x)*unitsPerMeter,(transform.translation.y-target.originMeters.y)*unitsPerMeter,(transform.translation.z-target.originMeters.z)*unitsPerMeter,1)
                    let inverse = simd_inverse(matrix)
                    matrices += (0..<4).flatMap { column in (0..<4).map { inverse[column][$0] } }
                }
                for (index,bone) in graph.bones.enumerated() {
                    let parent = bone.parentID.flatMap { boneIndex[$0] }.map { jointNodes[$0] } ?? motionNode
                    var children = nodes[parent]["children"] as? [Int] ?? []; children.append(jointNodes[index]); nodes[parent]["children"] = children
                    let poses = try bake.frames.map { frame -> SimulationAnimationTransform in
                        guard var pose = frame.localBones[bone.id] else { throw SimulationError.staleSource }
                        if bone.parentID == nil { pose.translation = pose.translation-target.originMeters }; return pose
                    }
                    try transformChannels(poses,node:jointNodes[index])
                }
                // Skin globals already carry the scene's unit/placement
                // transform through the joints. Keep the skinned Mesh itself
                // at scene root and identity, as glTF requires for portability.
                for parent in nodes.indices {
                    if let children = nodes[parent]["children"] as? [Int], children.contains(node) { nodes[parent]["children"] = children.filter { $0 != node } }
                }
                if var scenes = root["scenes"] as? [[String:Any]] {
                    for i in scenes.indices {
                        var roots = scenes[i]["nodes"] as? [Int] ?? []
                        if !roots.contains(node) { roots.append(node) }; scenes[i]["nodes"] = roots
                    }
                    root["scenes"] = scenes
                }
                let inverseAccessor = try append(floats(matrices),count:graph.bones.count,type:"MAT4")
                nodes[node]["skin"] = skins.count; skins.append(["joints":jointNodes,"inverseBindMatrices":inverseAccessor])
            }
            var deltas:[[[Double]]] = [], morphWeights:[[Double]] = [], morphNames:[String] = []
            if let cache {
                guard cache.positionsMeters.count == bake.frames.count,
                      cache.positionsMeters.allSatisfy({ $0.count == base.count && $0.allSatisfy(\.isFinite) }),
                      base.count <= maximumBytes/max(1,bake.frames.count)/96,
                      bake.frames.count <= maximumBytes/max(1,bake.frames.count)/16 else { throw SimulationError.resourceLimit("Reduce the soft Mesh resolution, duration or sampling rate for GLB export.") }
                for frame in cache.positionsMeters {
                    deltas.append(frame.enumerated().map { index,p in [(p.x-target.originMeters.x)*unitsPerMeter-base[index][0],(p.y-target.originMeters.y)*unitsPerMeter-base[index][1],(p.z-target.originMeters.z)*unitsPerMeter-base[index][2]] })
                }
                morphWeights = bake.frames.indices.map { frame in bake.frames.indices.map { $0 == frame ? 1:0 } }
                morphNames = bake.frames.indices.map { "Frame \($0)" }
            } else if let binding, !binding.morphs.isEmpty {
                for morph in binding.morphs {
                    var values = Array(repeating:[0.0,0.0,0.0],count:base.count)
                    for delta in morph.deltas {
                        guard values.indices.contains(delta.vertexIndex) else { throw SimulationError.staleSource }
                        values[delta.vertexIndex] = [delta.offset.x*unitsPerMeter,delta.offset.y*unitsPerMeter,delta.offset.z*unitsPerMeter]
                    }
                    deltas.append(values); morphNames.append(morph.name)
                }
                morphWeights = try bake.frames.map { frame in
                    let weights = frame.morphWeights[target.sourceObjectID] ?? Array(repeating:0,count:deltas.count)
                    guard weights.count == deltas.count else { throw SimulationError.invalidInput("The exported Morph weights do not match the Mesh.") }; return weights
                }
            }
            if !deltas.isEmpty {
                try materializeTRS(node)
                let normalID = attributes["NORMAL"] as? Int
                let originalNormals = try normalID.map { try values($0,components:3,requiredType:"VEC3") }
                var morphAccessors:[[String:Int]] = []
                for delta in deltas {
                    try Task.checkCancellation()
                    let lo = (0..<3).map { axis in delta.map { $0[axis] }.min() ?? 0 }, hi = (0..<3).map { axis in delta.map { $0[axis] }.max() ?? 0 }
                    var target = ["POSITION":try append(floats(delta.flatMap { $0 }),count:base.count,type:"VEC3",target:34962,minimum:lo,maximum:hi)]
                    if let originalNormals, originalNormals.count == base.count {
                        let positions = zip(base,delta).map { SIMD3($0[0]+$1[0],$0[1]+$1[1],$0[2]+$1[2]) }
                        var normals = Array(repeating:SIMD3<Double>.zero,count:base.count)
                        for i in stride(from:0,to:indices.count,by:3) {
                            let a = indices[i], b = indices[i+1], c = indices[i+2], n = simd_cross(positions[b]-positions[a],positions[c]-positions[a])
                            normals[a] += n; normals[b] += n; normals[c] += n
                        }
                        let values = normals.enumerated().flatMap { i,n -> [Double] in
                            let value = simd_length_squared(n)>1e-30 ? simd_normalize(n):SIMD3(originalNormals[i][0],originalNormals[i][1],originalNormals[i][2])
                            return [value.x-originalNormals[i][0],value.y-originalNormals[i][1],value.z-originalNormals[i][2]]
                        }
                        target["NORMAL"] = try append(floats(values),count:base.count,type:"VEC3",target:34962)
                    }
                    morphAccessors.append(target)
                }
                for i in primitives.indices { primitives[i]["targets"] = morphAccessors }
                meshes[meshID]["weights"] = morphWeights[0]
                var extras = meshes[meshID]["extras"] as? [String:Any] ?? [:]; extras["targetNames"] = morphNames; meshes[meshID]["extras"] = extras
                channel(try append(floats(morphWeights.flatMap { $0 }),count:bake.frames.count*deltas.count,type:"SCALAR"),node:node,path:"weights",time:times)
            }
            meshes[meshID]["primitives"] = primitives
        }
        guard !channels.isEmpty else { throw SimulationError.invalidInput("Bind animation tracks, a skeleton or a physics cache to this Mesh before exporting.") }
        var animations = root["animations"] as? [[String:Any]] ?? []
        animations.append(["name":"Floe Physics & Animation","samplers":samplers,"channels":channels,"extras":["floe_source_sha256":graph.source.contentSHA256,"floe_graph_sha256":bake.graphSHA256]])
        root["animations"] = animations; root["nodes"] = nodes; root["meshes"] = meshes; root["accessors"] = accessors; root["bufferViews"] = views; root["buffers"] = [["byteLength":bin.count]]
        if !skins.isEmpty { root["skins"] = skins }
        var json = try JSONSerialization.data(withJSONObject:root,options:.sortedKeys)
        while json.count%4 != 0 { json.append(32) }; while bin.count%4 != 0 { bin.append(0) }
        let total = 28+json.count+bin.count
        guard total <= maximumBytes else { throw SimulationError.resourceLimit("The animated GLB exceeds its export budget.") }
        var result = Data(capacity:total)
        func word(_ value:UInt32) { var value = value.littleEndian; withUnsafeBytes(of:&value) { result.append(contentsOf:$0) } }
        word(0x46546c67); word(2); word(UInt32(total)); word(UInt32(json.count)); word(0x4e4f534a); result.append(json); word(UInt32(bin.count)); word(0x004e4942); result.append(bin)
        try Task.checkCancellation(); return result
    }
}
