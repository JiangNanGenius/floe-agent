import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationPhysics
import FloeSimulationAnimation
import FloeSimulationEngineering
import FloeSimulationGeometry
import FloeSimulationFields

private func source() -> SimulationSourceRef { .init(projectID: UUID(),documentID: UUID(),revision: 1,contentSHA256: String(repeating:"a",count:64)) }

@Test func tet4AdapterUsesSIAndReturnsActualDisplacement() async throws {
    let source = source(), material = SimulationMaterial(name:"Steel",properties:["youngModulusPa":200e9,"poissonRatio":0])
    let mesh = SimulationMesh(source:source,nodes:[.zero,.init(0.001,0,0),.init(0,0.001,0),.init(0,0,0.001)],elements:[.init(kind:.tetrahedron4,nodes:[0,1,2,3],regionID:"body")])
    var configuration = EngineeringSimulationConfiguration()
    configuration.constraints = [.init(selection:.nodes([0,2,3]))]
    configuration.forces = [.init(selection:.nodes([1]),value:.init(100,0,0))]
    var study = SimulationStudy(name:"Tet",kind:.structuralStatic,materialAssignments:["body":material.id])
    try study.setConfiguration(configuration)
    let request = SimulationRequest(source:source,study:study,mesh:mesh,materials:[material])
    let result = try await LegacyEngineeringSimulationBackend().solve(request) { _ in }
    let displacement = try #require(result.frames[0].fields.first { $0.id == "displacement" })
    #expect(abs(displacement.values[3] - 3e-6) < 1e-14)
    try result.validate(for:request)
}

@Test func rapierRunsBoxCollisionAndSoftCloth() async throws {
    var configuration = PhysicsSimulationConfiguration()
    var floor = SimulationPhysicsBody(sourceObjectID:"floor"); floor.motion = .fixed; floor.translation = .init(0,-0.1,0); floor.collider.halfExtents = .init(5,0.1,5)
    var box = SimulationPhysicsBody(sourceObjectID:"box"); box.translation = .init(0,2,0); box.collider.halfExtents = .init(0.2,0.2,0.2)
    var cloth = SimulationPhysicsSoftBody(sourceObjectID:"cloth",kind:.cloth); cloth.dimensions = [4,4,2]; cloth.pinnedIndices = [0,3]; cloth.origin = .init(1,2,0)
    configuration.bodies = [floor,box]; configuration.softBodies = [cloth]; configuration.time.durationSeconds = 1
    var study = SimulationStudy(name:"Collision",kind:.rigidBody); try study.setConfiguration(configuration)
    let request = SimulationRequest(source:source(),study:study)
    let result = try await RapierSimulationBackend().solve(request) { _ in }
    let last = try #require(result.frames.last)
    let position = try #require(last.fields.first { $0.id == "body_position" })
    #expect(position.values[4] > 0.17 && position.values[4] < 0.3)
    let vertices = try #require(last.fields.first { $0.id == "soft/" + cloth.id.uuidString })
    #expect(vertices.values.count == 48)
    #expect(abs(vertices.values[1]-2) < 1e-8)
    #expect(result.frames.count > 20)
}

@Test func cameraTrackAndPhysicsSampleTogetherAndBake() async throws {
    let source = source(), body = SimulationPhysicsBody(sourceObjectID:"body")
    var configuration = PhysicsSimulationConfiguration(); configuration.gravity = .zero; configuration.bodies = [body]
    var study = SimulationStudy(name:"Physics",kind:.rigidBody); try study.setConfiguration(configuration)
    let physics = try await RapierSimulationBackend().solve(.init(source:source,study:study)) { _ in }
    let camera = SimulationAnimationTrack(targetID:"camera",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:1,transform:.init(translation:.init(2,0,0)))])
    let graph = SimulationAnimationGraph(source:source,layers:[.init(tracks:[camera])],physicsResultID:physics.id,physicsBindings:[.init(targetID:"body",bodyID:body.id)])
    let pose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:0.5,physics:physics)
    #expect(pose.objects["camera"]?.translation.x == 1)
    #expect(pose.objects["body"]?.translation == .zero)
    let bake = try await SimulationAnimationBaker.bake(graph,physics:physics,framesPerSecond:10) { _ in }
    #expect(bake.frames.count == 11)
    #expect(bake.frames.last?.objects["camera"]?.translation.x == 2)
}

@Test func resultChunksRoundtripAndDetectTampering() async throws {
    var repository = URL(fileURLWithPath:#filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let directory = repository.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let archive = try SimulationArchiveStore(directory:directory)
    let request = SimulationRequest(source:source(),study:.init(name:"Field",kind:.electrostatic))
    let result = SimulationResult(requestID:request.id,source:request.source,studyID:request.study.id,backend:.init(id:"fixture",version:"1",supportedStudies:[.electrostatic],isAvailable:true),frames:[.init(id:0,fields:[.init(id:"potential",name:"Potential",unit:"V",location:.global,components:1,values:[1,2,3])])])
    try await archive.saveResult(result,request:request)
    #expect(try await archive.readResult(result.id) == result)
    let chunk = directory.appendingPathComponent("results/"+result.id.uuidString+"/0-0-real.f64")
    try Data(repeating:0,count:24).write(to:chunk)
    await #expect(throws:SimulationError.self) { try await archive.readResult(result.id) }
}

@Test func boxMeshTagsAndAdjointInterfacePreserveLoads() throws {
    let mesh = try SimulationBoxMesher.generate(source:source(),maximum:.init(0.01,0.02,0.03),divisions:[2,2,2])
    #expect(mesh.elements.count == 48)
    #expect(mesh.boundaries.count == 6)
    let faces = try SimulationMeshTopology.exteriorFaces(mesh)
    #expect(faces.count == 48)
    let mapping = SimulationInterfaceMap(sourceMeshID:UUID(),destinationMeshID:UUID(),sourceNodeCount:2,rows:[[.init(sourceNode:0,weight:0.25),.init(sourceNode:1,weight:0.75)]])
    let forces = try mapping.transferLoads([.init(4,8,12)])
    #expect(forces.reduce(.zero,+) == .init(4,8,12))
    let displacement = [SimulationVector3(1,2,3),.init(4,5,6)]
    let moved = try mapping.interpolate(displacement)
    #expect(abs(forces[0].dot(displacement[0])+forces[1].dot(displacement[1]) - SimulationVector3(4,8,12).dot(moved[0])) < 1e-12)
}

@Test func steadyHeatAdapterPreservesKelvinAndHeatFlow() async throws {
    let source = source(), material = SimulationMaterial(name:"Conductor",properties:["thermalConductivityWPerMeterK":10])
    let mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.2,0.01,0.01),divisions:[2,1,1])
    var configuration = EngineeringSimulationConfiguration()
    configuration.fixedTemperatures = [.init(selection:.boundary("xmin"),value:300),.init(selection:.boundary("xmax"),value:400)]
    var study = SimulationStudy(name:"Conduction",kind:.thermalSteady,materialAssignments:["body":material.id]); study.meshID = mesh.id; try study.setConfiguration(configuration)
    let request = SimulationRequest(source:source,study:study,mesh:mesh,materials:[material])
    let result = try await LegacyEngineeringSimulationBackend().solve(request) { _ in }
    let temperatures = try #require(result.frames[0].fields.first { $0.id == "temperature" })
    for (index,node) in mesh.nodes.enumerated() { #expect(abs(temperatures.values[index]-(300+500*node.x)) < 1e-8) }
    let flows = try #require(result.frames[0].fields.first { $0.id == "boundary_heat_flow" })
    let hot = mesh.nodes.indices.filter { mesh.nodes[$0].x > 0.15 }.reduce(0.0) { $0+flows.values[$1] }
    #expect(abs(hot-0.5) < 1e-8)
    #expect(abs(flows.values.reduce(0,+)) < 1e-8)
}
