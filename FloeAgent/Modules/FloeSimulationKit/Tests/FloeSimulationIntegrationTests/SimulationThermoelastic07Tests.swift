import Foundation
import Testing
import FloeEngineeringCore
import FloeSimulationCore
import FloeSimulationEngineering
import FloeSimulationFields
import FloeSimulationRuntime
import FloeSimulationUI

private func thermo07Requests() throws -> (SimulationRequest,SimulationRequest) {
    let source=SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"d",count:64))
    let mesh=SimulationMesh(source:source,nodes:[.zero,.init(0.1,0,0),.init(0,0.1,0),.init(0,0,0.1)],elements:[.init(kind:.tetrahedron4,nodes:[0,1,2,3],regionID:"solid")],boundaries:[.init(id:"face-x",sourceEntityID:"face-x",nodeIndices:[0,2,3],facets:[.init(elementIndex:0,localFace:1)])])
    let material=SimulationMaterial(name:"Synthetic thermoelastic solid",properties:["youngModulusPa":210e9,"poissonRatio":0.3,"thermalExpansionPerKelvin":1e-5,"densityKgPerCubicMeter":2000,"specificHeatJPerKgK":500,"thermalConductivityWPerMeterK":45])
    var heat=EngineeringSimulationConfiguration();heat.initialTemperatureKelvin=300;heat.volumeHeatSourcesWPerCubicMeter=["solid":1e9];heat.relativeTolerance=1e-12;heat.time = .init(durationSeconds:0.1,stepSeconds:0.02,outputIntervalSeconds:0.05)
    var heatStudy=SimulationStudy(name:"Thermal source",kind:.thermalTransient,materialAssignments:["solid":material.id]);heatStudy.meshID=mesh.id;try heatStudy.setConfiguration(heat)
    var stress=EngineeringSimulationConfiguration();stress.referenceTemperatureKelvin=300;stress.relativeTolerance=1e-11
    stress.constraints=[.init(selection:.nodes([0])),.init(selection:.nodes([1]),fixedAxes:[false,true,true]),.init(selection:.nodes([2]),fixedAxes:[false,false,true])]
    var stressStudy=SimulationStudy(name:"Thermal deformation",kind:.thermalStress,materialAssignments:["solid":material.id]);stressStudy.meshID=mesh.id;try stressStudy.setConfiguration(stress)
    return (.init(source:source,study:heatStudy,mesh:mesh,materials:[material]),.init(source:source,study:stressStudy,mesh:mesh,materials:[material]))
}
private func thermo07Core(temperatures:[Double],fullyFixed:Bool=false) -> ThermoelasticRequest {
    let nodes=[MeshNode(.init(0,0,0)),MeshNode(.init(100,0,0)),MeshNode(.init(0,100,0)),MeshNode(.init(0,0,100))]
    let supports:[DisplacementBC]=fullyFixed ? (0..<4).map { .init(node:$0,constrained:[true,true,true],prescribedMM:[0,0,0]) }:[.init(node:0,constrained:[true,true,true],prescribedMM:[0,0,0]),.init(node:1,constrained:[false,true,true],prescribedMM:[0,0,0]),.init(node:2,constrained:[false,false,true],prescribedMM:[0,0,0])]
    return .init(mechanical:.init(meshNodes:nodes,meshElements:[.init(0,1,2,3)],material:.init(id:"synthetic",name:"Synthetic",elasticModulusMPa:210000,poissonRatio:0.3,provenance:"synthetic"),displacementBCs:supports,tolerance:.init(relativeResidual:1e-11)),thermalExpansionPerKelvin:1e-5,nodalTemperatureKelvin:temperatures,referenceTemperatureKelvin:300)
}
@Test func thermo07AnalyticFreeExpansionRestrainedStressAndTemperatureVarianceEnergy() throws {
    let free=try thermo07Core(temperatures:[400,400,400,400]).solve()
    #expect(abs(free.nodalDisplacementMM[1].x-0.1)<1e-10);#expect(abs(free.nodalDisplacementMM[2].y-0.1)<1e-10);#expect(abs(free.nodalDisplacementMM[3].z-0.1)<1e-10)
    #expect(free.elements[0].meanStressMPa.allSatisfy { abs($0)<1e-6 });#expect(free.elasticEnergyJ<1e-15);#expect(free.equilibriumResidualN<1e-6)
    let fixed=try thermo07Core(temperatures:[400,400,400,400],fullyFixed:true).solve()
    #expect(fixed.nodalDisplacementMM.allSatisfy {$0 == .zero})
    for sigma in fixed.elements[0].meanStressMPa.prefix(3) { #expect(abs(sigma+525)<1e-9) }
    let reaction=try #require(fixed.reactions.first {$0.node==1 && $0.component==0})
    #expect(abs(reaction.valueN+875000)<1e-5)
    #expect(abs(fixed.elasticEnergyJ-131.25)<1e-9);#expect(fixed.elements[0].vonMisesOfMeanStressMPa<1e-9)
    let gradient=try thermo07Core(temperatures:[300,400,300,300],fullyFixed:true).solve()
    #expect(abs(gradient.elements[0].meanTemperatureKelvin-325)<1e-12)
    #expect(abs(gradient.elements[0].meanStressMPa[0]+131.25)<1e-9)
    #expect(abs(gradient.elasticEnergyJ-13.125)<1e-10)
    var zero=thermo07Core(temperatures:[300,350,400,450]);zero.thermalExpansionPerKelvin=0
    zero.mechanical.concentratedLoads=[.init(node:1,components:.init(100,0,0))]
    zero.mechanical.bodyLoads=[.init(componentsPerVolume:.init(0,0,0.001))]
    zero.mechanical.pressureLoads=[.init(element:0,face:1,pressureMPa:-0.01)]
    let mechanical=try zero.mechanical.solve(),noExpansion=try zero.solve()
    #expect(noExpansion.nodalDisplacementMM==mechanical.nodalDisplacementMM)
    for (a,b) in zip(noExpansion.elements[0].meanStressMPa,mechanical.elements[0].stressMPa) { #expect(abs(a-b)<1e-10) }
}
@MainActor @Test func thermo07ActualHeatToDefaultWorkbenchSaveReopenAndExplicitFrame() async throws {
    var (heat,stress)=try thermo07Requests()
    let temperature=try await MFEMTransientHeatSimulationDriver().solve(heat) { _ in }
    #expect(temperature.frames.count==3)
    var configuration=try stress.study.configuration(as:EngineeringSimulationConfiguration.self);configuration.temperatureResultID=temperature.id;try stress.study.setConfiguration(configuration)
    let evidence=ProcessInfo.processInfo.environment["FLOE_THERMO_TEST_ROOT"],base=evidence.map {URL(fileURLWithPath:$0,isDirectory:true)} ?? FileManager.default.temporaryDirectory
    let directory=base.appendingPathComponent("thermo07-workbench-"+UUID().uuidString,isDirectory:true)
    defer {if evidence==nil {try? FileManager.default.removeItem(at:directory)}}
    let archive=try SimulationArchiveStore(directory:directory);try await archive.saveResult(temperature,request:heat)
    let document=SimulationWorkspaceDocument(source:heat.source,materials:heat.materials,studies:[heat.study,stress.study],meshes:[try #require(heat.mesh)],resultIDs:[temperature.id])
    let model=try SimulationWorkbenchFactory.make(document:document,directory:directory);model.selectedStudyID=stress.study.id
    let tools=SimulationWorkbenchFactory.tools(for:model,authorize:{_,_,_ in}),snapshot=await model.workspace.snapshot()
    let capabilities=try await tools.executableCapabilities(.init(taskID:UUID(),source:heat.source,expectedGeneration:snapshot.generation))
    #expect(capabilities.contains {$0.id=="floe.thermoelastic.tet4" && $0.supportedStudies==[.thermalStress]})
    await model.run()
    for _ in 0..<300 { if await model.coordinator.snapshots().last?.status.isTerminal==true {break};try await Task.sleep(for:.milliseconds(10)) }
    let job=try #require(await model.coordinator.snapshots().last);#expect(job.status == .completed)
    await model.showResult(try #require(job.resultID));let result=try #require(model.result),frame=try #require(result.frames.first)
    #expect(result.backend.id=="floe.thermoelastic.tet4");#expect(result.diagnostics["temperatureFrameID"]=="2");#expect(frame.timeSeconds==0.1)
    let displacement=try #require(frame.fields.first {$0.id=="displacement"}),sigma=try #require(frame.fields.first {$0.id=="thermoelastic_stress"})
    #expect(displacement.unit=="m");#expect(abs(displacement.values[3]-0.0001)<1e-11);#expect(sigma.values.allSatisfy {abs($0)<1})
    #expect(await model.save());await model.export();let csv=try String(contentsOf:try #require(model.exportURL),encoding:.utf8)
    #expect(csv.contains("thermoelastic_stress"));#expect(csv.contains("thermal_strain"));#expect(csv.contains("elastic_strain"))
    await model.close()
    let reopened=try await SimulationWorkbenchFactory.openOrCreate(initial:document,directory:directory)
    let summary=try #require(reopened.savedResults.first {$0.kind == .thermalStress});await reopened.showSavedResult(summary)
    #expect(reopened.result?.frames==result.frames);await reopened.close()
    let backend=Tet4ThermoelasticSimulationBackend(loadTemperature:{try await archive.readResultSnapshot($0)})
    configuration.temperatureFrameID=1;try stress.study.setConfiguration(configuration)
    let middle=try await backend.solve(stress) {_ in},middleU=try #require(middle.frames[0].fields.first {$0.id=="displacement"})
    #expect(abs(middleU.values[3]-0.00005)<1e-11);#expect(middle.frames[0].timeSeconds==0.05)
    configuration.temperatureFrameID=999;try stress.study.setConfiguration(configuration)
    await #expect(throws:(any Error).self) {try await backend.solve(stress) {_ in}}
    _ = heat
}
@MainActor @Test func thermo07RejectsWrongLineageUnitsFramesAndArchiveCorruption() async throws {
    var (heat,request)=try thermo07Requests()
    // Synthetic sealed fixture exercises lineage validation without rerunning a
    // temperature solver. The actual heat-to-mechanics test is above.
    let temperature=SimulationResult(requestID:heat.id,source:heat.source,studyID:heat.study.id,studyRevision:heat.study.revision,backend:.init(id:"fixture.temperature",version:"1",supportedStudies:[.thermalTransient],isAvailable:true),mesh:heat.mesh,frames:[.init(id:0,timeSeconds:0,fields:[.init(id:"temperature",name:"Temperature",unit:"K",location:.node,components:1,values:[400,400,400,400])])])
    var c=try request.study.configuration(as:EngineeringSimulationConfiguration.self);c.temperatureResultID=temperature.id;try request.study.setConfiguration(c)
    let original=SimulationArchivedResult(request:heat,result:temperature)
    let loader=Tet4ThermoelasticSimulationBackend(loadTemperature:{_ in original})
    var changed=request;changed.mesh?.nodes[1].x=0.2
    await #expect(throws:(any Error).self) {try await loader.solve(changed) {_ in}}
    changed=request;changed.materials[0].properties["thermalExpansionPerKelvin"]=2e-5
    await #expect(throws:(any Error).self) {try await loader.solve(changed) {_ in}}
    changed=request;changed.source.revision+=1;changed.mesh?.source=changed.source
    await #expect(throws:(any Error).self) {try await loader.solve(changed) {_ in}}
    var wrong=original;wrong.result.frames[0].fields[0].unit="C";let wrongUnits=wrong
    await #expect(throws:(any Error).self) {try await Tet4ThermoelasticSimulationBackend(loadTemperature:{_ in wrongUnits}).solve(request) {_ in}}
    #expect(throws:(any Error).self) {try Tet4ThermoelasticSimulationBackend().validate(request)}
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("thermo07-seal-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    let archive=try SimulationArchiveStore(directory:directory);try await archive.saveResult(temperature,request:heat)
    let restored=try await archive.readResultSnapshot(temperature.id);#expect(restored.request==heat);#expect(restored.result.frames==temperature.frames)
    let chunk=directory.appendingPathComponent("results/"+temperature.id.uuidString+"/0-0-real.f64")
    var bytes=try Data(contentsOf:chunk);bytes[0]^=1;try bytes.write(to:chunk)
    await #expect(throws:(any Error).self) {try await archive.readResultSnapshot(temperature.id)}
    let legacy=try JSONEncoder().encode(EngineeringSimulationConfiguration());#expect(try JSONDecoder().decode(EngineeringSimulationConfiguration.self,from:legacy).temperatureFrameID==nil)
    _ = heat
}
@MainActor @Test func thermo07CoreBudgetsCancellationAndSingularSupportsStayGuarded() async throws {
    var input=thermo07Core(temperatures:[400,400,400,400])
    #expect(throws:EngineeringError.cancelled) {try input.solve(control:.init(isCancelled:{true}))}
    input.mechanical.budget.maxEstimatedBytes=1;#expect(throws:(any Error).self) {try input.solve()}
    input=thermo07Core(temperatures:[400,400,400,400]);input.mechanical.budget.maxWallSeconds=1e-15;#expect(throws:(any Error).self) {try input.solve()}
    input=thermo07Core(temperatures:[400,400,400,400]);input.mechanical.displacementBCs=[.init(node:0,constrained:[true,true,true],prescribedMM:[0,0,0])]
    #expect(throws:(any Error).self) {try input.solve()}
    input=thermo07Core(temperatures:[-1,400,400,400]);#expect(throws:(any Error).self) {try input.solve()}
    input=thermo07Core(temperatures:[400,400]);#expect(throws:(any Error).self) {try input.solve()}
    var (heat,request)=try thermo07Requests()
    let backend=Tet4ThermoelasticSimulationBackend(loadTemperature:{_ in throw SimulationError.cancelled})
    var configuration=try request.study.configuration(as:EngineeringSimulationConfiguration.self);configuration.temperatureResultID=UUID();try request.study.setConfiguration(configuration)
    _ = heat
    let task=Task {try await backend.solve(request) {_ in}};task.cancel()
    await #expect(throws:CancellationError.self) {try await task.value}
}
@Test func thermo07SavedSnapshotCombinesNodalBodyAndPressureLoadsInSI() async throws {
    var (heat,request)=try thermo07Requests()
    let temperature=SimulationResult(requestID:heat.id,source:heat.source,studyID:heat.study.id,studyRevision:heat.study.revision,backend:.init(id:"fixture.temperature",version:"1",supportedStudies:[.thermalTransient],isAvailable:true),mesh:heat.mesh,frames:[.init(id:0,fields:[.init(id:"temperature",name:"Temperature",unit:"K",location:.node,components:1,values:[400,400,400,400])])])
    let snapshot=SimulationArchivedResult(request:heat,result:temperature)
    var c=try request.study.configuration(as:EngineeringSimulationConfiguration.self)
    c.temperatureResultID=temperature.id;c.referenceTemperatureKelvin=400
    c.forces=[.init(selection:.nodes([1]),value:.init(100,0,0))]
    c.pressures=[.init(selection:.boundary("face-x"),value:10000)]
    c.bodyForceNewtonsPerCubicMeter = .init(0,0,1000);try request.study.setConfiguration(c)
    let coupled=try await Tet4ThermoelasticSimulationBackend(loadTemperature:{_ in snapshot}).solve(request) {_ in}
    var reference=request;reference.study.kind = .structuralStatic;c.temperatureResultID=nil;try reference.study.setConfiguration(c)
    let mechanical=try await LegacyEngineeringSimulationBackend().solve(reference) {_ in}
    let a=try #require(coupled.frames[0].fields.first {$0.id=="displacement"}),b=try #require(mechanical.frames[0].fields.first {$0.id=="displacement"})
    #expect(a.values==b.values)
    let sa=try #require(coupled.frames[0].fields.first {$0.id=="thermoelastic_stress"}),sb=try #require(mechanical.frames[0].fields.first {$0.id=="stress"})
    for (x,y) in zip(sa.values,sb.values) {#expect(abs(x-y)<1e-6)}
    _ = heat
}
@MainActor @Test func thermo07AITemplatesExposeTemperatureInputsAndRunSavedSnapshot() async throws {
    var (heat,request)=try thermo07Requests()
    let temperature=SimulationResult(requestID:heat.id,source:heat.source,studyID:heat.study.id,studyRevision:heat.study.revision,backend:.init(id:"fixture.temperature",version:"1",supportedStudies:[.thermalTransient],isAvailable:true),mesh:heat.mesh,frames:[.init(id:0,fields:[.init(id:"temperature",name:"Temperature",unit:"K",location:.node,components:1,values:[400,400,400,400])])])
    var c=try request.study.configuration(as:EngineeringSimulationConfiguration.self);c.temperatureResultID=temperature.id;try request.study.setConfiguration(c)
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("thermo07-tools-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:directory)}
    let archive=try SimulationArchiveStore(directory:directory);try await archive.saveResult(temperature,request:heat)
    let document=SimulationWorkspaceDocument(source:heat.source,materials:heat.materials,studies:[heat.study,request.study],meshes:[try #require(heat.mesh)],resultIDs:[temperature.id])
    let model=try SimulationWorkbenchFactory.make(document:document,directory:directory),tools=SimulationWorkbenchFactory.tools(for:model,authorize:{_,_,_ in})
    let current=await model.workspace.snapshot(),context=SimulationToolContext(taskID:UUID(),source:heat.source,expectedGeneration:current.generation)
    let template=try #require(try await tools.templates(context).first {$0.kind == .thermalStress})
    guard case .object(let values)=template.configuration else {Issue.record("Expected a structural configuration object");await model.close();return}
    #expect(values["temperatureResultID"] == .null);#expect(values["temperatureFrameID"] == .null)
    #expect(template.materialPropertyUnits["thermalExpansionPerKelvin"]=="1/K")
    let id=try await tools.start(studyID:request.study.id,expectedStudyRevision:request.study.revision,context:context)
    for _ in 0..<300 {if try await tools.jobs(context).first(where:{$0.id==id})?.status.isTerminal==true {break};try await Task.sleep(for:.milliseconds(10))}
    let job=try #require(try await tools.jobs(context).first {$0.id==id});#expect(job.status == .completed)
    let result=try await model.coordinator.result(try #require(job.resultID))
    #expect(result.backend.id=="floe.thermoelastic.tet4");#expect(result.diagnostics["temperatureResultID"]==temperature.id.uuidString)
    await model.close();_ = heat
}
