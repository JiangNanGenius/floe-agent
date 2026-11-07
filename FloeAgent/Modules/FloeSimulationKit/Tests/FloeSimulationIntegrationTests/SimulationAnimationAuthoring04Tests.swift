import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationUI
import FloeSimulationPhysics
import FloeSimulationAnimation

@MainActor @Test func animation04AuthoredRagdollRunsAndDrivesActualMesh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ragdoll04-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"a",count:64))
    let store = try SimulationArchiveStore(directory:directory)
    let model = SimulationWorkbenchModel(document:.init(source:source),coordinator:.init(archive:store),archive:store)
    let original:[SimulationVector3] = [.init(0,1,0),.init(0.1,1,0),.init(0,1.1,0)]
    model.setSourceMeshes([.init(id:"mesh",positionsMeters:original,indices:[0,1,2])])
    var graph = SimulationAnimationGraph(source:source,durationSeconds:0.1,bones:[.init(id:"root",restLocal:.init(translation:.init(0,1,0))),.init(id:"middle",parentID:"root",restLocal:.init(translation:.init(0.3,0,0))),.init(id:"tip",parentID:"middle",restLocal:.init(translation:.init(0.3,0,0)))])
    model.writeAnimationGraph(graph); await model.bindSourceMesh("mesh")
    #expect(model.errorDetails == nil)
    model.setMeshMorph(objectID:"mesh",name:"Stretch",vertexIndex:1,offset:.init(0.1,0,0))
    #expect(model.errorDetails == nil)
    model.createRagdoll(pinRoot:true)
    #expect(model.errorDetails == nil); #expect(model.physics.bodies.count == 3); #expect(model.physics.joints.count == 2)
    var physics = model.physics; physics.time.stepSeconds = 0.002; physics.time.outputIntervalSeconds = 0.025
    model.writeConfiguration(physics)
    let study = try #require(model.selectedStudy), request = SimulationRequest(source:source,study:study)
    let result = try await RapierSimulationBackend().solve(request) { _ in }
    try await store.saveResult(result,request:request)
    let records = try await store.savedResults(); await model.showSavedResult(try #require(records.first))
    var retimed = model.animationGraph; retimed.durationSeconds = 0.2
    retimed.layers.append(.init(tracks:[.init(targetID:"camera",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:0.2,transform:.init(translation:.init(0,0,1)))])]))
    model.writeAnimationGraph(retimed)
    model.attachCurrentPhysicsCache(); graph = model.animationGraph
    #expect(graph.layers.last?.tracks.first?.keys.last?.timeSeconds == 0.1)
    #expect(graph.physicsBindings.count == 3)
    let pose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:0.1,physics:result)
    let deformed = try SimulationAnimationMeshDeformer.deform(original,sourceObjectID:"mesh",graph:graph,pose:pose)
    #expect(abs(deformed[1].x-original[1].x)>0.05)
    let before = graph; model.setMeshMorph(objectID:"mesh",name:"Bad",vertexIndex:99,offset:.zero)
    #expect(model.animationGraph == before); #expect(model.errorDetails != nil)
    await model.close()
}
