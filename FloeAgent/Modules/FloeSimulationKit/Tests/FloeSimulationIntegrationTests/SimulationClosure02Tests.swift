import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationEngineering
import FloeSimulationFields
import FloeSimulationPhysics
import FloeSimulationRuntime

private func closureSource() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"c",count:64)) }
private func closureDirectory() throws -> URL {
    var repository = URL(fileURLWithPath:#filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let directory = repository.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); return directory
}
private func sideTaggedCube(_ source: SimulationSourceRef) throws -> SimulationMesh {
    var mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(1,1,1))
    let faces = try SimulationMeshTopology.exteriorFaces(mesh).filter { abs($0.outwardNormal.z) < 0.5 }
    mesh.boundaries.append(.init(id:"sides",sourceEntityID:"fixture/sides",nodeIndices:Array(mesh.nodes.indices),facets:faces.map { .init(elementIndex:$0.elementIndex,localFace:$0.localFace) }))
    return mesh
}

@Test func closure02ExactFacetsKeepCapHeatFluxOut() async throws {
    let source = closureSource(), mesh = try sideTaggedCube(source)
    let material = SimulationMaterial(name:"Conductor",properties:["thermalConductivityWPerMeterK":10])
    var configuration = EngineeringSimulationConfiguration()
    configuration.fixedTemperatures = [.init(selection:.nodes(Array(mesh.nodes.indices)),value:300)]
    configuration.faceHeatFluxes = [.init(selection:.boundary("sides"),value:2)]
    var study = SimulationStudy(name:"Side flux",kind:.thermalSteady,materialAssignments:["body":material.id])
    study.meshID = mesh.id; try study.setConfiguration(configuration)
    let result = try await LegacyEngineeringSimulationBackend().solve(.init(source:source,study:study,mesh:mesh,materials:[material])) { _ in }
    let flux = try #require(result.frames[0].fields.first { $0.id == "boundary_heat_flow" })
    // Four side faces, each 1 m², at 2 W/m² outward. The fixed-temperature
    // boundary supplies 8 W to balance that loss; the two caps carry no flux.
    #expect(abs(flux.values.reduce(0,+)-8) < 1e-8)
}

@Test func closure02InterfaceMappingUsesOnlyExactFacets() throws {
    let source = closureSource(), mesh = try sideTaggedCube(source)
    var target = SimulationMesh(source:source,nodes:[.init(0,0.5,0.5),.init(0,0.5,0.6)],elements:[.init(kind:.line2,nodes:[0,1],regionID:"probe")],boundaries:[.init(id:"point",sourceEntityID:"probe",nodeIndices:[0])])
    let mapping = try SimulationInterfaceMapBuilder.build(source:mesh,sourceBoundary:"sides",destination:target,destinationBoundary:"point")
    #expect(mapping.rows.count == 1)
    target.nodes[0] = .init(0.5,0.5,1)
    #expect(throws:SimulationError.self) { try SimulationInterfaceMapBuilder.build(source:mesh,sourceBoundary:"sides",destination:target,destinationBoundary:"point") }
}

@Test func closure02MalformedFacetConnectivityThrowsWithoutTrapping() throws {
    let mesh = SimulationMesh(source:closureSource(),nodes:[.zero],elements:[.init(kind:.hexahedron8,nodes:[0],regionID:"body")])
    #expect(throws:SimulationError.self) { try mesh.nodes(of:.init(elementIndex:0,localFace:3)) }
}

@Test func closure02SharedMeshReplacementAdvancesEveryStudy() async throws {
    let directory = try closureDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = closureSource(), archive = try SimulationArchiveStore(directory:directory), coordinator = SimulationCoordinator()
    var mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(1,1,1))
    var first = SimulationStudy(name:"First",kind:.structuralStatic), second = SimulationStudy(name:"Second",kind:.thermalSteady)
    first.meshID = mesh.id; second.meshID = mesh.id
    let store = SimulationWorkspaceStore(document:.init(source:source,studies:[first,second],meshes:[mesh]),archive:archive,coordinator:coordinator)
    let tools = SimulationToolService(workspace:store,coordinator:coordinator,archive:archive) { _,_,_ in }
    mesh.nodes[1].x = 1.1
    var unsafe = await store.snapshot().document; unsafe.meshes = [mesh]
    await #expect(throws:SimulationError.self) { try await store.commit(unsafe,expectedGeneration:0) }
    let saved = try await tools.putMesh(mesh,studyID:first.id,context:.init(taskID:UUID(),source:source,expectedGeneration:0))
    #expect(saved.document.studies.map(\.revision) == [1,1])
    await #expect(throws:SimulationError.self) { try await store.start(studyID:second.id,expectedStudyRevision:0,expectedGeneration:saved.generation) }
}

@Test func closure02LaminateChildMaterialInvalidatesParentStudy() async throws {
    let directory = try closureDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = closureSource(), archive = try SimulationArchiveStore(directory:directory), coordinator = SimulationCoordinator()
    var ply = SimulationMaterial(name:"Ply",properties:["youngModulusPa":1e9])
    let laminate = SimulationMaterial(name:"Laminate",properties:[:],layers:[.init(materialID:ply.id,thicknessMeters:0.001,angleRadians:0)])
    let study = SimulationStudy(name:"Plate",kind:.laminate,materialAssignments:["plate":laminate.id])
    let store = SimulationWorkspaceStore(document:.init(source:source,materials:[ply,laminate],studies:[study]),archive:archive,coordinator:coordinator)
    let tools = SimulationToolService(workspace:store,coordinator:coordinator,archive:archive) { _,_,_ in }
    ply.properties["youngModulusPa"] = 2e9
    let saved = try await tools.putMaterial(ply,context:.init(taskID:UUID(),source:source,expectedGeneration:0))
    #expect(saved.document.studies.first?.revision == 1)
}

@Test func closure02OlderViewCannotReactivateObsoleteSource() async throws {
    let source = closureSource(), coordinator = SimulationCoordinator()
    var updated = source; updated.revision += 1; updated.contentSHA256 = String(repeating:"d",count:64)
    try await coordinator.setCurrentSource(updated)
    await #expect(throws:SimulationError.self) { try await coordinator.setCurrentSource(source) }
    await #expect(throws:SimulationError.self) { try await coordinator.start(.init(source:source,study:.init(name:"Old",kind:.rigidBody))) }
}

@Test func closure02AIToolsCreateRunReadAndExportActualNativeResult() async throws {
    let directory = try closureDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = closureSource(), archive = try SimulationArchiveStore(directory:directory)
    let coordinator = SimulationCoordinator(backends:[RapierSimulationBackend()],archive:archive)
    let store = SimulationWorkspaceStore(document:.init(source:source),archive:archive,coordinator:coordinator)
    let tools = SimulationToolService(workspace:store,coordinator:coordinator,archive:archive) { _,_,_ in }
    var context = SimulationToolContext(taskID:UUID(),source:source,expectedGeneration:0)
    let definitions = try await tools.definitions(context)
    #expect(definitions.contains { $0.name == "simulation.result.field" })
    for definition in definitions { #expect(try JSONSerialization.jsonObject(with:definition.inputSchema) is [String:Any]) }
    var physics = PhysicsSimulationConfiguration(); physics.bodies = [.init(sourceObjectID:"body")]; physics.time.durationSeconds = 0.1
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let input = SimulationToolStudyInput(name:"AI physics",kind:.rigidBody,configuration:try decoder.decode(SimulationJSONValue.self,from:encoder.encode(physics)))
    struct Put: Encodable { var study: SimulationToolStudyInput; var expectedGeneration: UInt64 }
    let receiptData = try await tools.invoke(name:"simulation.study.put",arguments:encoder.encode(Put(study:input,expectedGeneration:context.expectedGeneration)),context:context)
    let receipt = try decoder.decode(SimulationToolCommitReceipt.self,from:receiptData)
    context.expectedGeneration = receipt.generation
    let saved = try await tools.studyInfo(studyID:input.id,context:context)
    guard case .object = saved.configuration else { Issue.record("AI configuration must remain a JSON object"); return }
    struct Run: Encodable { var studyID: UUID; var expectedStudyRevision: UInt64; var expectedGeneration: UInt64 }
    let started = try await tools.invoke(name:"simulation.run",arguments:encoder.encode(Run(studyID:input.id,expectedStudyRevision:0,expectedGeneration:context.expectedGeneration)),context:context)
    let jobID = try #require(decoder.decode([String:UUID].self,from:started)["jobID"])
    var completed: SimulationJobSnapshot?
    for _ in 0..<200 {
        completed = try await tools.jobs(context).first { $0.id == jobID && $0.status.isTerminal }
        if completed != nil { break }; try await Task.sleep(for:.milliseconds(10))
    }
    #expect(completed?.status == .completed)
    let resultID = try #require(completed?.resultID)
    let info = try await tools.resultInfo(resultID:resultID,context:context)
    let frame = try #require(info.frames.first), field = try #require(frame.fields.first { $0.id == "body_position" })
    let page = try await tools.field(resultID:resultID,frameID:frame.id,fieldID:field.id,limit:3,context:context)
    #expect(page.values.count == 3 && page.components == 3 && page.isStale == false)
    #expect(try await tools.savedResults(context).contains { $0.id == resultID })
    let csv = try await tools.export(resultID:resultID,context:context)
    #expect(try String(contentsOf:csv,encoding:.utf8).contains("body_position"))
}
