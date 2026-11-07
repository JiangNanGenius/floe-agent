import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationAnimation
import FloeSimulationRuntime
import FloeSimulationUI
import CoreGraphics
import ImageIO

@Test func animation04MorphAndWeightedSkinActuallyDeformMeshVertices() throws {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"d",count:64))
    let root = SimulationAnimationBone(id:"root"), q = sqrt(0.5)
    var graph = SimulationAnimationGraph(source:source,durationSeconds:1,layers:[.init(tracks:[.init(targetID:"root",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:1,transform:.init(rotation:.init(z:q,w:q)))])])],bones:[root],morphTracks:[.init(targetID:"mesh",timesSeconds:[0,1],weights:[[0],[1]])])
    graph.meshBindings = [.init(sourceObjectID:"mesh",skin:(0..<3).map { .init(vertexIndex:$0,influences:[.init(boneID:"root",weight:1)]) },morphs:[.init(name:"Stretch",deltas:[.init(vertexIndex:0,offset:.init(0.5,0,0))])])]
    let original:[SimulationVector3] = [.init(1,0,0),.init(0,1,0),.zero]
    let pose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:1)
    let mesh = try SimulationAnimationMeshDeformer.deform(original,sourceObjectID:"mesh",graph:graph,pose:pose)
    #expect(abs(mesh[0].x) < 1e-12); #expect(abs(mesh[0].y-1.5) < 1e-12)
    #expect(abs(mesh[1].x+1) < 1e-12); #expect(original[0] == .init(1,0,0))
    #expect(try JSONDecoder().decode(SimulationAnimationGraph.self,from:JSONEncoder().encode(graph)) == graph)
}
@Test func animation04BindingRejectsBadWeightsAndUsesBindPose() throws {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"d",count:64))
    let bone = SimulationAnimationBone(id:"root",restLocal:.init(translation:.init(2,0,0)))
    var graph = SimulationAnimationGraph(source:source,bones:[bone])
    graph.meshBindings = [try SimulationAnimationMeshDeformer.bindNearest(positions:[.init(3,0,0)],sourceObjectID:"mesh",bones:graph.bones)]
    let pose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:0)
    #expect(try SimulationAnimationMeshDeformer.deform([.init(3,0,0)],sourceObjectID:"mesh",graph:graph,pose:pose) == [.init(3,0,0)])
    graph.meshBindings?[0].skin[0].influences[0].weight = 0.5
    #expect(throws:(any Error).self) { try graph.validate() }
}

private func animation04BaseGLB() throws -> Data {
    var binary = Data()
    func floats(_ values:[Float]) { for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { binary.append(contentsOf:$0) } } }
    floats([0,0,0,1,0,0,0,1,0]); floats([0,0,1,0,0,1,0,0,1])
    for value:UInt32 in [0,1,2] { var bits = value.littleEndian; withUnsafeBytes(of:&bits) { binary.append(contentsOf:$0) } }
    floats([0,0,1,0,0,1])
    let provider = try #require(CGDataProvider(data:Data([255,0,0,255]) as CFData))
    let image = try #require(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let png = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil); #expect(CGImageDestinationFinalize(destination))
    binary.append(png as Data)
    let root:[String:Any] = ["asset":["version":"2.0"],"scene":0,"scenes":[["nodes":[0]]],
        "nodes":[["mesh":0,"matrix":[1,0,0,0,0,1,0,0,0,0,1,0,2,0,0,1]]],
        "meshes":[["primitives":[["attributes":["POSITION":0,"NORMAL":1,"TEXCOORD_0":3],"indices":2,"material":0]]]],
        "materials":[["name":"Retained material","pbrMetallicRoughness":["baseColorFactor":[0.2,0.5,0.8,1],"baseColorTexture":["index":0],"metallicFactor":0.2,"roughnessFactor":0.7]]],
        "images":[["mimeType":"image/png","bufferView":4]],"textures":[["source":0]],
        "buffers":[["byteLength":binary.count]],
        "bufferViews":[["buffer":0,"byteOffset":0,"byteLength":36,"target":34962],["buffer":0,"byteOffset":36,"byteLength":36,"target":34962],["buffer":0,"byteOffset":72,"byteLength":12,"target":34963],["buffer":0,"byteOffset":84,"byteLength":24,"target":34962],["buffer":0,"byteOffset":108,"byteLength":png.length]],
        "accessors":[["bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]],["bufferView":1,"componentType":5126,"count":3,"type":"VEC3"],["bufferView":2,"componentType":5125,"count":3,"type":"SCALAR"],["bufferView":3,"componentType":5126,"count":3,"type":"VEC2"]]]
    var json = try JSONSerialization.data(withJSONObject:root,options:.sortedKeys)
    while json.count%4 != 0 { json.append(32) }; while binary.count%4 != 0 { binary.append(0) }
    var output = Data()
    func word(_ value:UInt32) { var value = value.littleEndian; withUnsafeBytes(of:&value) { output.append(contentsOf:$0) } }
    word(0x46546c67); word(2); word(UInt32(28+json.count+binary.count)); word(UInt32(json.count)); word(0x4e4f534a); output.append(json); word(UInt32(binary.count)); word(0x004e4942); output.append(binary)
    return output
}
private func animation04Parts(_ data:Data) throws -> (root:[String:Any],binary:Data) {
    let count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset:12,as:UInt32.self).littleEndian) }
    let root = try #require(JSONSerialization.jsonObject(with:data.subdata(in:20..<(20+count))) as? [String:Any])
    return (root,data.subdata(in:(28+count)..<data.count))
}
private func animation04Values(_ accessor:Int,_ parts:(root:[String:Any],binary:Data)) throws -> [Double] {
    let accessors = try #require(parts.root["accessors"] as? [[String:Any]]), views = try #require(parts.root["bufferViews"] as? [[String:Any]])
    let row = accessors[accessor], view = views[try #require(row["bufferView"] as? Int)]
    #expect(row["componentType"] as? Int == 5126)
    let offset = (view["byteOffset"] as? Int ?? 0)+(row["byteOffset"] as? Int ?? 0), count = try #require(row["count"] as? Int)
    let width = row["type"] as? String == "VEC3" ? 3:row["type"] as? String == "VEC4" ? 4:row["type"] as? String == "MAT4" ? 16:1
    return (0..<(count*width)).map { index in parts.binary.withUnsafeBytes { Double(Float(bitPattern:$0.loadUnaligned(fromByteOffset:offset+index*4,as:UInt32.self).littleEndian)) } }
}
private func animation04Record(_ data:Data,name:String) throws {
    #if os(macOS)
    if let path = ProcessInfo.processInfo.environment["FLOE_SIMULATION_EXPORT_EVIDENCE_PATH"] {
        try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
        try data.write(to:URL(fileURLWithPath:path).appendingPathComponent(name),options:.atomic)
    }
    #endif
}
@Test func animation04GLBPreservesTextureAndExportsActualSkinMorphAndMotion() async throws {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"d",count:64)), q = sqrt(0.5)
    let bone = SimulationAnimationBone(id:"root",restLocal:.init(translation:.init(2,0,0)))
    let boneTrack = SimulationAnimationTrack(targetID:"root",keys:[.init(timeSeconds:0,transform:bone.restLocal),.init(timeSeconds:1,transform:.init(translation:.init(2,0,0),rotation:.init(z:q,w:q)))])
    let meshTrack = SimulationAnimationTrack(targetID:"mesh",keys:[.init(timeSeconds:0,transform:.init(translation:.init(2,0,0))),.init(timeSeconds:1,transform:.init(translation:.init(3,0,0)))])
    var graph = SimulationAnimationGraph(source:source,layers:[.init(tracks:[boneTrack,meshTrack])],bones:[bone],morphTracks:[.init(targetID:"mesh",timesSeconds:[0,1],weights:[[0],[1]])])
    graph.meshBindings = [.init(sourceObjectID:"mesh",skin:(0..<3).map { .init(vertexIndex:$0,influences:[.init(boneID:"root",weight:1)]) },morphs:[.init(name:"Stretch",deltas:[.init(vertexIndex:1,offset:.init(0.5,0,0))])])]
    let base = try animation04BaseGLB(), bake = try await SimulationAnimationBaker.bake(graph,framesPerSecond:2) { _ in }
    let output = try SimulationAnimationGLBExporter.export(baseGLB:base,graph:graph,bake:bake,targets:[.init(sourceObjectID:"mesh",nodeIndex:0,originMeters:.init(2,0,0))],unitsPerMeter:1)
    let before = try animation04Parts(base), after = try animation04Parts(output)
    for key in ["materials","images","textures"] { #expect(try JSONSerialization.data(withJSONObject:#require(before.root[key]),options:.sortedKeys) == JSONSerialization.data(withJSONObject:#require(after.root[key]),options:.sortedKeys)) }
    #expect(after.binary.prefix(before.binary.count-3) == before.binary.prefix(before.binary.count-3))
    let nodes = try #require(after.root["nodes"] as? [[String:Any]]), skins = try #require(after.root["skins"] as? [[String:Any]])
    #expect(nodes[0]["matrix"] == nil); #expect(nodes[0]["skin"] as? Int == 0); #expect(skins.count == 1)
    #expect(nodes[0]["translation"] == nil)
    #expect(!nodes.contains { ($0["children"] as? [Int])?.contains(0) == true })
    let motionNode = try #require(nodes.firstIndex { ($0["extras"] as? [String:Any])?["floe_animation_target"] as? String == "mesh" })
    let animation = try #require((after.root["animations"] as? [[String:Any]])?.last), channels = try #require(animation["channels"] as? [[String:Any]]), samplers = try #require(animation["samplers"] as? [[String:Any]])
    let translation = try #require(channels.first { ($0["target"] as? [String:Any])?["node"] as? Int == motionNode && ($0["target"] as? [String:Any])?["path"] as? String == "translation" })
    let sampler = samplers[try #require(translation["sampler"] as? Int)], values = try animation04Values(#require(sampler["output"] as? Int),after)
    #expect(values.suffix(3) == [3,0,0])
    let mesh = try #require((after.root["meshes"] as? [[String:Any]])?.first), primitive = try #require((mesh["primitives"] as? [[String:Any]])?.first)
    let target = try #require((primitive["targets"] as? [[String:Int]])?.first)
    #expect(try animation04Values(#require(target["POSITION"]),after)[3] == 0.5)
    #expect(target["NORMAL"] != nil)
    try animation04Record(output,name:"skin-morph-motion.glb")
}
@Test func animation04GLBExportsSoftVertexCacheAndRefusesStaleBake() async throws {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"d",count:64))
    var graph = SimulationAnimationGraph(source:source)
    let bake = try await SimulationAnimationBaker.bake(graph,framesPerSecond:2) { _ in }
    let positions = bake.frames.map { frame in [SimulationVector3(2,frame.timeSeconds,0),.init(3,frame.timeSeconds,0),.init(2,1+frame.timeSeconds,0)] }
    let base = try animation04BaseGLB(), target = SimulationGLBTarget(sourceObjectID:"mesh",nodeIndex:0,originMeters:.init(2,0,0))
    let output = try SimulationAnimationGLBExporter.export(baseGLB:base,graph:graph,bake:bake,targets:[target],vertexFrames:[.init(sourceObjectID:"mesh",positionsMeters:positions)],unitsPerMeter:1)
    let parts = try animation04Parts(output), mesh = try #require((parts.root["meshes"] as? [[String:Any]])?.first), primitive = try #require((mesh["primitives"] as? [[String:Any]])?.first)
    let targets = try #require(primitive["targets"] as? [[String:Int]])
    #expect(targets.count == 3); #expect(try animation04Values(#require(targets[2]["POSITION"]),parts)[1] == 1)
    let nodes = try #require(parts.root["nodes"] as? [[String:Any]])
    #expect(nodes[0]["matrix"] == nil)
    try animation04Record(output,name:"soft-mesh-cache.glb")
    graph.durationSeconds = 2
    #expect(throws:(any Error).self) { try SimulationAnimationGLBExporter.export(baseGLB:base,graph:graph,bake:bake,targets:[target],unitsPerMeter:1) }
}

@MainActor private func animation04Model(_ directory:URL) throws -> SimulationWorkbenchModel {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"e",count:64))
    let archive = try SimulationArchiveStore(directory:directory)
    let document = SimulationWorkspaceDocument(source:source)
    let model = SimulationWorkbenchModel(document:document,coordinator:.init(archive:archive),archive:archive)
    model.writeAnimationGraph(.init(source:source,layers:[.init(tracks:[.init(targetID:"mesh",keys:[.init(timeSeconds:0,transform:.init(translation:.init(2,0,0))),.init(timeSeconds:1,transform:.init(translation:.init(3,0,0)))])])]))
    return model
}
@MainActor @Test func animation04ExportActuallyPersistsReopensAndDetectsCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animation04-exports-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let model = try animation04Model(directory), base = try animation04BaseGLB()
    model.animationExportHandler = { request in
        let glb = try SimulationAnimationGLBExporter.export(baseGLB:base,graph:request.graph,bake:request.bake,targets:[.init(sourceObjectID:"mesh",nodeIndex:0,originMeters:.init(2,0,0))],unitsPerMeter:1)
        try glb.write(to:request.outputURL,options:.atomic)
    }
    await model.bakeAnimation(format:.glb,framesPerSecond:2)
    #expect(model.errorDetails == nil)
    let file = try #require(model.exportURL), id = try #require(model.savedAnimationExports.first?.id), source = model.document.source
    let before = try Data(contentsOf:file)
    #expect(before.prefix(4) == Data([0x67,0x6c,0x54,0x46]))
    await model.close()
    let reopened = try SimulationArchiveStore(directory:directory)
    let records = try await reopened.savedAnimationExports(source:source)
    #expect(records.count == 1); #expect(records[0].format == .glb); #expect(records[0].frameCount == 3)
    let restored = try await reopened.animationExportURL(id:id,source:source)
    #expect(try Data(contentsOf:restored) == before)
    var damaged = before; damaged[damaged.count-1] ^= 1; try damaged.write(to:restored,options:.atomic)
    await #expect(throws:(any Error).self) { try await reopened.animationExportURL(id:id,source:source) }
}
private actor AnimationExportGate04 {
    var ready = false
    var readyWaiters:[CheckedContinuation<Void,Never>] = []
    var finish:CheckedContinuation<Void,Never>?
    var released = false
    func started() { ready = true; for value in readyWaiters { value.resume() }; readyWaiters = [] }
    func waitUntilStarted() async { if !ready { await withCheckedContinuation { readyWaiters.append($0) } } }
    func waitUntilReleased() async { if !released { await withCheckedContinuation { finish = $0 } } }
    func release() { released = true; finish?.resume(); finish = nil }
}
@MainActor @Test func animation04ExportRejectsAConcurrentWorkspaceEditAndCleansStaging() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animation04-race-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let model = try animation04Model(directory), gate = AnimationExportGate04(), base = try animation04BaseGLB()
    model.animationExportHandler = { request in
        await gate.started(); await gate.waitUntilReleased()
        let glb = try SimulationAnimationGLBExporter.export(baseGLB:base,graph:request.graph,bake:request.bake,targets:[.init(sourceObjectID:"mesh",nodeIndex:0,originMeters:.init(2,0,0))],unitsPerMeter:1)
        try glb.write(to:request.outputURL,options:.atomic)
    }
    let export = Task { await model.bakeAnimation(format:.glb,framesPerSecond:2) }
    await gate.waitUntilStarted()
    let snapshot = await model.workspace.snapshot()
    _ = try await model.workspace.commit(snapshot.document,expectedGeneration:snapshot.generation)
    await gate.release(); await export.value
    #expect(model.exportURL == nil); #expect(model.errorDetails != nil)
    #expect(try await model.archive.savedAnimationExports(source:model.document.source).isEmpty)
    let files = try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent("exports").path)
    #expect(files.isEmpty)
    await model.close()
}
@MainActor @Test func animation04CancelDrainsOwnedExporterWithoutPublishingAFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animation04-cancel-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let model = try animation04Model(directory), gate = AnimationExportGate04()
    model.animationExportHandler = { _ in await gate.started(); try await Task.sleep(for:.seconds(30)) }
    let export = Task { await model.bakeAnimation(format:.glb,framesPerSecond:2) }
    await gate.waitUntilStarted(); model.cancelBake(); await export.value
    #expect(!model.baking); #expect(model.exportURL == nil)
    #expect(try await model.archive.savedAnimationExports(source:model.document.source).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent("exports").path).isEmpty)
    await model.close()
}

@Test func animation04CameraLensAndStandaloneBonesAreRealGLBChannels() async throws {
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"a",count:64))
    var graph = SimulationAnimationGraph(source:source,layers:[.init(tracks:[
        .init(targetID:"camera",keys:[.init(timeSeconds:0,transform:.init(translation:.init(0,0,3))),.init(timeSeconds:1,transform:.init(translation:.init(0,1,3)))]),
        .init(targetID:"root",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:1,transform:.init(translation:.init(0,1,0)))])
    ])],bones:[.init(id:"root"),.init(id:"child",parentID:"root",restLocal:.init(translation:.init(0,1,0)))])
    graph.cameraKeys = [.init(timeSeconds:0,projection:.init(verticalFOVDegrees:60)),.init(timeSeconds:1,projection:.init(verticalFOVDegrees:30))]
    let midpoint = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:0.5)
    #expect(midpoint.cameraProjection?.verticalFOVDegrees == 45)
    let bake = try await SimulationAnimationBaker.bake(graph,framesPerSecond:2) { _ in }
    let data = try SimulationAnimationGLBExporter.export(baseGLB:animation04BaseGLB(),graph:graph,bake:bake,targets:[.init(sourceObjectID:"mesh",nodeIndex:0,originMeters:.init(2,0,0))],unitsPerMeter:1)
    let parts = try animation04Parts(data), animation = try #require((parts.root["animations"] as? [[String:Any]])?.last)
    let channels = try #require(animation["channels"] as? [[String:Any]]), samplers = try #require(animation["samplers"] as? [[String:Any]])
    let pointer = try #require(channels.first { ($0["target"] as? [String:Any])?["path"] as? String == "pointer" })
    let sampler = samplers[try #require(pointer["sampler"] as? Int)]
    let lens = try animation04Values(#require(sampler["output"] as? Int),parts)
    #expect(abs(try #require(lens.last)-Double.pi/6) < 1e-6)
    #expect((pointer["target"] as? [String:Any])?["node"] == nil)
    let nodes = try #require(parts.root["nodes"] as? [[String:Any]])
    #expect(nodes.contains { $0["name"] as? String == "child" })
    try animation04Record(data,name:"camera-skeleton-motion.glb")
    graph.cameraKeys?[1].projection.orthographicHeightMeters = 1
    #expect(throws:(any Error).self) { try graph.validate() }
}
