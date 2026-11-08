import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationEngineering
import FloeSimulationFields
import FloeSimulationRuntime
import FloeSimulationUI

private func heatRequest() throws -> SimulationRequest {
    let source=SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"b",count:64))
    let mesh=SimulationMesh(source:source,nodes:[.zero,.init(1,0,0),.init(0,1,0),.init(0,0,1)],elements:[.init(kind:.tetrahedron4,nodes:[0,1,2,3],regionID:"solid")],boundaries:[.init(id:"outer",sourceEntityID:"outer",nodeIndices:[0,1,2,3],facets:(0..<4).map { .init(elementIndex:0,localFace:$0) })])
    let material=SimulationMaterial(name:"Synthetic heat medium",properties:["thermalConductivityWPerMeterK":3,"densityKgPerCubicMeter":2,"specificHeatJPerKgK":5])
    var c=EngineeringSimulationConfiguration();c.initialTemperatureKelvin=300;c.relativeTolerance=1e-12;c.volumeHeatSourcesWPerCubicMeter=["solid":20];c.time = .init(durationSeconds:0.3,stepSeconds:0.03,outputIntervalSeconds:0.1)
    var study=SimulationStudy(name:"Transient heat SI",kind:.thermalTransient,materialAssignments:["solid":material.id]);study.meshID=mesh.id;try study.setConfiguration(c)
    return .init(source:source,study:study,mesh:mesh,materials:[material])
}
@Test func transientHeat05SIFramesAndActualArchiveRoundTrip() async throws {
    let request=try heatRequest(),sourceNodes=try #require(request.mesh?.nodes)
    let result=try await MFEMTransientHeatSimulationDriver().execute(request) { _ in }
    #expect(result.frames.count==4);#expect(result.frames.last?.timeSeconds==0.3)
    #expect(result.backend.supportedStudies==[.thermalTransient]);#expect(result.source==request.source)
    for frame in result.frames {
        let t=try #require(frame.timeSeconds),values=try #require(frame.fields.first { $0.id=="temperature" })
        #expect(values.unit=="K");for value in values.values { #expect(abs(value-(300+2*t))<1e-8) }
        #expect(frame.fields.first { $0.id=="heat_flux" }?.unit=="W/m²")
    }
    #expect(abs(try #require(Double(result.diagnostics["peakEnergyBalanceResidualW"] ?? "")))<1e-8)
    #expect(request.mesh?.nodes==sourceNodes)
    let evidence=ProcessInfo.processInfo.environment["FLOE_HEAT_TEST_ROOT"]
    let base=evidence.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory
    let root=base.appendingPathComponent("heat05-"+UUID().uuidString,isDirectory:true)
    defer { if evidence==nil { try? FileManager.default.removeItem(at:root) } }
    let archive=try SimulationArchiveStore(directory:root);try await archive.saveResult(result,request:request)
    let reopened=try SimulationArchiveStore(directory:root),restored=try await reopened.readResult(result.id)
    #expect(restored.source==result.source);#expect(restored.frames==result.frames);#expect(restored.diagnostics==result.diagnostics)
    let csv=try await reopened.exportCSV(restored),text=try String(contentsOf:csv,encoding:.utf8)
    #expect(text.contains("temperature"));#expect(text.contains("heat_flux"));#expect(text.contains("0.3"))
}
@MainActor @Test func transientHeat05RejectsMissingInputsAndPreservesTheConfiguredClock() async throws {
    let driver=MFEMTransientHeatSimulationDriver();var request=try heatRequest()
    request.materials[0].properties.removeValue(forKey:"specificHeatJPerKgK")
    #expect(throws:(any Error).self) { try driver.validate(request) }
    request=try heatRequest();var c=try request.study.configuration(as:EngineeringSimulationConfiguration.self)
    c.forces=[.init(selection:.nodes([1]),value:.init(1,0,0))];try request.study.setConfiguration(c)
    #expect(throws:(any Error).self) { try driver.validate(request) }
    request=try heatRequest();request.budget.maximumResultValues=9
    #expect(throws:(any Error).self) { try driver.validate(request) }
    request=try heatRequest();c=try request.study.configuration(as:EngineeringSimulationConfiguration.self)
    c.time = .init(durationSeconds:1e-18,stepSeconds:1e-20,outputIntervalSeconds:5e-19);c.volumeHeatSourcesWPerCubicMeter=[:];try request.study.setConfiguration(c)
    let small=try await driver.execute(request) { _ in }
    #expect(small.frames.last?.timeSeconds==1e-18);#expect(small.diagnostics["nativeStepCount"]=="100")
    // A much larger output interval must still include the final frame even
    // when duration/outputInterval underflows to zero in Double arithmetic.
    c.time.outputIntervalSeconds=1e308;try request.study.setConfiguration(c)
    let finalOnly=try await driver.execute(request) { _ in }
    #expect(finalOnly.frames.count==2);#expect(finalOnly.frames.last?.timeSeconds==1e-18)
    c.volumeHeatSourcesWPerCubicMeter=["solid":20];try request.study.setConfiguration(c)
    await #expect(throws:(any Error).self) { try await driver.execute(request) { _ in } }
    let cancelledRequest=try heatRequest()
    let task=Task { try await driver.execute(cancelledRequest) { _ in } };task.cancel()
    await #expect(throws:(any Error).self) { try await task.value }
}

@MainActor @Test func transientHeat05FactoryRunsAndSavesTheNativeBackend() async throws {
    let request = try heatRequest()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("heat-factory-" + UUID().uuidString, isDirectory: true)
    let document = SimulationWorkspaceDocument(source: request.source, materials: request.materials,
        studies: [request.study], meshes: [try #require(request.mesh)])
    let model = try SimulationWorkbenchFactory.make(document: document, directory: root)
    do {
        let available = await model.coordinator.capabilities()
        #expect(available.contains { $0.id == "floe.heat.mfem" && $0.isAvailable && $0.supportedStudies == [.thermalTransient] })
        let id = try await model.coordinator.start(request)
        var finished: SimulationJobSnapshot?
        for _ in 0..<250 {
            if let job = await model.coordinator.snapshots().first(where: { $0.id == id }), job.status.isTerminal {
                finished = job
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let job = try #require(finished)
        #expect(job.status == .completed, Comment(rawValue: job.error ?? "The native heat run did not complete"))
        #expect(job.backendID == "floe.heat.mfem")
        let resultID = try #require(job.resultID)
        let reopened = try SimulationArchiveStore(directory: root)
        let result = try await reopened.readResult(resultID)
        #expect(result.source == request.source)
        #expect(result.backend.id == "floe.heat.mfem")
        let final = try #require(result.frames.last)
        #expect(final.timeSeconds == 0.3)
        let temperatures = try #require(final.fields.first { $0.id == "temperature" })
        #expect(temperatures.values.count == 4)
        for value in temperatures.values { #expect(abs(value - 300.6) < 1e-8) }
        await model.close()
        try FileManager.default.removeItem(at: root)
    } catch {
        await model.close()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}
