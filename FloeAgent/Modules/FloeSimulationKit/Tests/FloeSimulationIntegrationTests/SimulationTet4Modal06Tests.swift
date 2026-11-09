import Foundation
import Testing
import FloeEngineeringCore
import FloeSimulationCore
import FloeSimulationEngineering
import FloeSimulationGeometry
import FloeSimulationRuntime
import FloeSimulationUI

private func modalRequest(coupled:Bool=true,length:Double=1,density:Double=2000) throws -> SimulationRequest {
    let source=SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"c",count:64))
    let mesh=SimulationMesh(source:source,nodes:[.zero,.init(length,0,0),.init(0,length,0),.init(0,0,length)],elements:[.init(kind:.tetrahedron4,nodes:[0,1,2,3],regionID:"solid")])
    let material=SimulationMaterial(name:"Synthetic modal reference",properties:["youngModulusPa":120e6,"poissonRatio":0.25,"densityKgPerCubicMeter":density])
    var c=EngineeringSimulationConfiguration();c.relativeTolerance=1e-10;c.requestedModes=coupled ? 6:3
    c.constraints = coupled ? [.init(selection:.nodes([0])),.init(selection:.nodes([1]),fixedAxes:[false,true,true]),.init(selection:.nodes([2]),fixedAxes:[false,false,true])] : [.init(selection:.nodes([0,2,3]))]
    var study=SimulationStudy(name:"Constrained tet4 modes",kind:.modal,materialAssignments:["solid":material.id]);study.meshID=mesh.id;try study.setConfiguration(c)
    return .init(source:source,study:study,mesh:mesh,materials:[material])
}
private func dot(_ a:[Double],_ b:[Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
private func mv(_ a:[[Double]],_ x:[Double]) -> [Double] { a.map { dot($0,x) } }
private struct Reference:Decodable {
    struct Case:Decodable { var freeDOFs:[Int];var stiffnessNPerMeter:[[Double]];var massKg:[[Double]];var frequencyHz:[Double];var massNormalizedFreeVectors:[[Double]] }
    var caseB:Case
}
@Test func modal06AnalyticEigenvaluesAndPhysicalScaling() async throws {
    let backend=Tet4ModalSimulationBackend(),request=try modalRequest(coupled:false)
    let result=try await backend.solve(request) { _ in }
    #expect(result.frames.count==3);#expect(result.backend.supportedStudies==[.modal]);#expect(result.mesh?.nodes==request.mesh?.nodes)
    let eigenvalues=[240000.0,240000.0,720000.0]
    for (frame,expected) in zip(result.frames,eigenvalues) {
        let f=try #require(frame.frequencyHz);#expect(abs(pow(2*Double.pi*f,2)/expected-1)<1e-12)
        let shape=try #require(frame.fields.first { $0.id=="mode_shape" });#expect(shape.unit=="1");#expect(shape.components==3)
        for n in [0,2,3] { #expect(shape.values[n*3..<n*3+3].allSatisfy { $0==0 }) }
    }
    let base=try await backend.solve(modalRequest()) { _ in }
    for scaled in [try modalRequest(density:8000),try modalRequest(length:2)] {
        let changed=try await backend.solve(scaled) { _ in }
        for (a,b) in zip(changed.frames,base.frames) { #expect(abs(2*(try #require(a.frequencyHz))/(try #require(b.frequencyHz))-1)<1e-11) }
    }
}
@Test func modal06IndependentCoupledReferenceCoordinatorArchiveAndPreview() async throws {
    let request=try modalRequest(),original=try #require(request.mesh)
    // Independently derived SI elastic-energy and consistent-mass reference.
    // Cholesky + Jacobi, without the production Core/Accelerate implementation.
    let reference=Reference.Case(
        freeDOFs:[3,6,7,9,10,11],
        stiffnessNPerMeter:[[24000000.0,0.0,8000000.0,0.0,0.0,8000000.0],[0.0,8000000.0,0.0,0.0,0.0,0.0],[8000000.0,0.0,24000000.0,0.0,0.0,8000000.0],[0.0,0.0,0.0,8000000.0,0.0,0.0],[0.0,0.0,0.0,0.0,8000000.0,0.0],[8000000.0,0.0,8000000.0,0.0,0.0,24000000.0]],
        massKg:[[33.333333333333336,16.666666666666668,0.0,16.666666666666668,0.0,0.0],[16.666666666666668,33.333333333333336,0.0,16.666666666666668,0.0,0.0],[0.0,0.0,33.333333333333336,0.0,16.666666666666668,0.0],[16.666666666666668,16.666666666666668,0.0,33.333333333333336,0.0,0.0],[0.0,0.0,16.666666666666668,0.0,33.333333333333336,0.0],[0.0,0.0,0.0,0.0,0.0,33.333333333333336]],
        frequencyHz:[60.38005027999612,72.99639701245044,110.26577908435843,117.65285055756976,141.0630636553924,203.42413033452794],
        massNormalizedFreeVectors:[[0.02968892004114755,0.08862623877574584,-0.009846130640819331,0.08862623877574585,-0.007375432986917037,-0.008266802162861204],[-0.007641154340883903,0.010639396373323994,0.04149289245864013,0.010639396373324018,0.14723939053842888,-0.015941473781884513],[8.326672684688674e-17,-0.17320508075688779,-3.730718842576494e-17,0.1732050807568877,1.41681213258114e-17,-4.901726775177564e-17],[0.05465932878351648,-0.025762871849363402,0.058968748811812834,-0.025762871849363503,-0.05257406893232165,-0.15715096133703105],[-0.14020236375466122,0.05868710430647045,0.14311807552896771,0.05868710430647058,-0.10303819779961787,0.010671685878200913],[0.14634150389301803,-0.05407671650045423,0.11925307839747223,-0.05407671650045429,-0.06989464880971812,0.06976546328252678]])
    let evidence=ProcessInfo.processInfo.environment["FLOE_MODAL_TEST_ROOT"]
    let base=evidence.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory
    let root=base.appendingPathComponent("modal06-"+UUID().uuidString,isDirectory:true)
    defer { if evidence==nil { try? FileManager.default.removeItem(at:root) } }
    let archive=try SimulationArchiveStore(directory:root)
    let coordinator=SimulationCoordinator(backends:[LegacyEngineeringSimulationBackend(),Tet4ModalSimulationBackend()],archive:archive)
    let id=try await coordinator.start(request)
    for _ in 0..<300 {
        if await coordinator.snapshots().first(where:{$0.id==id})?.status.isTerminal==true { break }
        try await Task.sleep(for:.milliseconds(10))
    }
    let job=try #require(await coordinator.snapshots().first { $0.id==id })
    #expect(job.status == .completed);#expect(job.backendID=="floe.modal.tet4")
    let result=try await coordinator.result(try #require(job.resultID));#expect(result.frames.count==6)
    var vectors:[[Double]]=[]
    for (index,frame) in result.frames.enumerated() {
        let f=try #require(frame.frequencyHz);#expect(abs(f/reference.frequencyHz[index]-1)<1e-10)
        let shape=try #require(frame.fields.first { $0.id=="mode_shape" }),vector=reference.freeDOFs.map { shape.values[$0] }
        let mass=try #require(frame.fields.first { $0.id=="modal_mass" }?.values.first),stiffness=try #require(frame.fields.first { $0.id=="modal_stiffness" }?.values.first)
        #expect(abs(dot(vector,mv(reference.massKg,vector))/mass-1)<1e-11)
        #expect(abs(dot(vector,mv(reference.stiffnessNPerMeter,vector))/stiffness-1)<1e-11)
        #expect(abs(stiffness/mass/pow(2*Double.pi*f,2)-1)<1e-10)
        let referenceVector=reference.massNormalizedFreeVectors[index],mVector=mv(reference.massKg,vector)
        #expect(abs(abs(dot(referenceVector,mVector))/sqrt(mass)-1)<1e-10)
        for prior in vectors { #expect(abs(dot(prior,mVector))/sqrt(dot(prior,mv(reference.massKg,prior))*mass)<1e-10) }
        vectors.append(vector)
        let maximum=stride(from:0,to:shape.values.count,by:3).map { hypot(hypot(shape.values[$0],shape.values[$0+1]),shape.values[$0+2]) }.max()!
        #expect(abs(maximum-1)<1e-12)
        let displayed=try SimulationModalShapeDisplay.positions(mesh:original,field:shape,scale:1)
        let distance=zip(displayed,original.nodes).map { ($0-$1).length }.max()!
        #expect(abs(distance/(sqrt(3)*0.02)-1)<1e-12)
        #expect(try SimulationModalShapeDisplay.positions(mesh:original,field:shape,scale:0)==original.nodes)
    }
    let reopened=try SimulationArchiveStore(directory:root),restored=try await reopened.readResult(result.id)
    #expect(restored.frames==result.frames);#expect(restored.diagnostics==result.diagnostics);#expect(restored.source==request.source)
    let csv=try await reopened.exportCSV(restored),text=try String(contentsOf:csv,encoding:.utf8)
    #expect(text.contains("frequency_hz"));#expect(text.contains("mode_shape"));#expect(text.contains("modal_mass"));#expect(text.contains("modal_stiffness"))
    #expect(request.mesh==original);await coordinator.close()
}
@MainActor @Test func modal06RejectsUnsupportedSingularBudgetAndCancelledWork() async throws {
    let backend=Tet4ModalSimulationBackend();var request=try modalRequest()
    request.materials[0].properties.removeValue(forKey:"densityKgPerCubicMeter")
    #expect(throws:(any Error).self) { try backend.validate(request) }
    request=try modalRequest();var c=try request.study.configuration(as:EngineeringSimulationConfiguration.self)
    c.constraints=[];try request.study.setConfiguration(c);#expect(throws:(any Error).self) { try backend.validate(request) }
    request=try modalRequest();c=try request.study.configuration(as:EngineeringSimulationConfiguration.self)
    c.forces=[.init(selection:.nodes([1]),value:.init(1,0,0))];try request.study.setConfiguration(c);#expect(throws:(any Error).self) { try backend.validate(request) }
    c.forces=[];c.preloadedResultID=UUID();try request.study.setConfiguration(c);#expect(throws:(any Error).self) { try backend.validate(request) }
    c.preloadedResultID=nil;c.constraints[0].displacementMeters.x=0.001;try request.study.setConfiguration(c);#expect(throws:(any Error).self) { try backend.validate(request) }
    request=try modalRequest();request.budget.maximumResultValues=83;#expect(throws:(any Error).self) { try backend.validate(request) }
    request=try modalRequest();c=try request.study.configuration(as:EngineeringSimulationConfiguration.self);c.constraints=[.init(selection:.nodes([0]))];try request.study.setConfiguration(c)
    await #expect(throws:(any Error).self) { try await backend.solve(request) { _ in } }
    let nodes=[MeshNode(.init(0,0,0)),MeshNode(.init(1000,0,0)),MeshNode(.init(0,1000,0)),MeshNode(.init(0,0,1000))]
    let material=EngineeringMaterial(id:"reference",name:"Reference",elasticModulusMPa:120,poissonRatio:0.25,massDensityKgPerMM3:2e-6,provenance:"synthetic")
    var input=EngineeringModalRequest(meshNodes:nodes,meshElements:[.init(0,1,2,3)],material:material,displacementBCs:[.init(node:0,constrained:[true,true,true],prescribedMM:[0,0,0]),.init(node:1,constrained:[false,true,true],prescribedMM:[0,0,0]),.init(node:2,constrained:[false,false,true],prescribedMM:[0,0,0])])
    #expect(throws:EngineeringError.cancelled) { try input.solve(control:.init(isCancelled:{true})) }
    input.budget.maxEstimatedBytes=1;#expect(throws:(any Error).self) { try input.solve() }
    input.budget.maxEstimatedBytes=1<<30;input.budget.maxWallSeconds=1e-15;#expect(throws:(any Error).self) { try input.solve() }
    var manyNodes:[MeshNode]=[],manyElements:[Tetrahedron]=[],supports:[DisplacementBC]=[]
    for i in 0..<60 {
        let offset=manyNodes.count
        manyNodes += nodes.map { .init(.init($0.position.x+Double(i)*2000,$0.position.y,$0.position.z)) }
        manyElements.append(.init(offset,offset+1,offset+2,offset+3));supports.append(.init(node:offset,constrained:[true,true,true],prescribedMM:[0,0,0]))
    }
    input = .init(meshNodes:manyNodes,meshElements:manyElements,material:material,displacementBCs:supports)
    #expect(throws:(any Error).self) { try input.solve() }
    let cancelRequest=try modalRequest(),task=Task { try await backend.solve(cancelRequest) { _ in } };task.cancel()
    await #expect(throws:(any Error).self) { try await task.value }
    let valid=try await backend.solve(modalRequest(coupled:false)) { _ in },shape=try #require(valid.frames.first?.fields.first)
    #expect(throws:(any Error).self) { try SimulationModalShapeDisplay.positions(mesh:try #require(valid.mesh),field:shape,scale:.infinity) }
}
@MainActor @Test func modal06DefaultWorkbenchFactoryDiscoveryRunSaveReopenAndExport() async throws {
    let request=try modalRequest(),mesh=try #require(request.mesh)
    let document=SimulationWorkspaceDocument(source:request.source,materials:request.materials,studies:[request.study],meshes:[mesh])
    let evidence=ProcessInfo.processInfo.environment["FLOE_MODAL_TEST_ROOT"]
    let base=evidence.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory
    let directory=base.appendingPathComponent("workbench-modal06-"+UUID().uuidString,isDirectory:true)
    defer { if evidence==nil { try? FileManager.default.removeItem(at:directory) } }
    let model=try SimulationWorkbenchFactory.make(document:document,directory:directory)
    let tools=SimulationWorkbenchFactory.tools(for:model,authorize:{ _,_,_ in })
    let snapshot=await model.workspace.snapshot(),context=SimulationToolContext(taskID:UUID(),source:request.source,expectedGeneration:snapshot.generation)
    let capabilities=try await tools.executableCapabilities(context)
    #expect(capabilities.contains { $0.id=="floe.modal.tet4" && $0.supportedStudies==[.modal] })
    await model.run()
    for _ in 0..<300 {
        if await model.coordinator.snapshots().last?.status.isTerminal==true { break }
        try await Task.sleep(for:.milliseconds(10))
    }
    let job=try #require(await model.coordinator.snapshots().last)
    #expect(job.status == .completed);#expect(model.errorDetails==nil)
    await model.showResult(try #require(job.resultID))
    #expect(model.currentField?.id=="mode_shape");#expect(model.currentFrame?.frequencyHz != nil)
    model.frameIndex=5;#expect(abs((try #require(model.currentFrame?.frequencyHz))/203.42413033452794-1)<1e-10)
    #expect(await model.save());await model.export()
    let csv=try #require(model.exportURL),text=try String(contentsOf:csv,encoding:.utf8)
    #expect(text.contains("mode_shape"));#expect(text.contains("modal_mass"))
    await model.close()
    let reopened=try await SimulationWorkbenchFactory.openOrCreate(initial:document,directory:directory)
    let saved=try #require(reopened.savedResults.first);await reopened.showSavedResult(saved)
    #expect(reopened.result?.frames.count==6);#expect(reopened.currentField?.id=="mode_shape");#expect(reopened.errorDetails==nil)
    await reopened.close()
}
