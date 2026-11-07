import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationUI
import FloeSimulationAnimation

private actor HostSource03 {
    var current = true
    var invoked = false
    func requireCurrent() throws { if !current { throw SimulationError.staleSource } }
    func edit() { current = false }
    func enter() { invoked = true }
}
private struct HostBackend03: SimulationBackend {
    let host: HostSource03
    var descriptor: SimulationBackendDescriptor { .init(id:"host-source-03",version:"1",supportedStudies:[.rigidBody],isAvailable:true) }
    func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        await host.enter(); await host.edit()
        return .init(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,
            frames:[.init(id:0,fields:[.init(id:"value",name:"Value",unit:"1",location:.global,components:1,values:[1])])])
    }
}
private func source03() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:String(repeating:"a",count:64)) }
private func terminal03(_ coordinator: SimulationCoordinator, _ id: UUID) async throws -> SimulationJobSnapshot {
    for _ in 0..<200 {
        if let job = await coordinator.snapshots().first(where:{ $0.id == id }), job.status.isTerminal { return job }
        try await Task.sleep(for:.milliseconds(10))
    }
    throw SimulationError.solverFailure("Host source fixture did not finish.")
}
@Test func liveSource03EditDuringSolveCannotPublishCurrentResult() async throws {
    let host = HostSource03(), coordinator = SimulationCoordinator(backends:[HostBackend03(host:host)],validateSource:{ _ in try await host.requireCurrent() })
    let id = try await coordinator.start(.init(source:source03(),study:.init(name:"Bound",kind:.rigidBody)))
    let job = try await terminal03(coordinator,id)
    #expect(job.status == .stale && job.resultID == nil)
    #expect(await host.invoked)
}
@Test func liveSource03ClosedSourceNeverEntersNativeBackend() async throws {
    let host = HostSource03(); await host.edit()
    let coordinator = SimulationCoordinator(backends:[HostBackend03(host:host)],validateSource:{ _ in try await host.requireCurrent() })
    let id = try await coordinator.start(.init(source:source03(),study:.init(name:"Bound",kind:.rigidBody)))
    #expect(try await terminal03(coordinator,id).status == .stale)
    #expect(await !host.invoked)
}
@Test @MainActor func liveSource03VisibleModelFencesAndRebindsSameGeometry() async throws {
    var root = URL(fileURLWithPath:#filePath); for _ in 0..<6 { root.deleteLastPathComponent() }
    let directory = root.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = source03(), model = try SimulationWorkbenchFactory.make(document:.init(source:source),directory:directory)
    model.invalidateLiveSource(); #expect(!model.sourceAvailable)
    #expect(await model.refreshSource(source)); #expect(model.sourceAvailable)
    await model.close(); #expect(await model.refreshSource(source) == false)
}
@Test @MainActor func liveSource03BakePersistsTheSharedGraphAndInvalidationClearsItsExport() async throws {
    var root = URL(fileURLWithPath:#filePath); for _ in 0..<6 { root.deleteLastPathComponent() }
    let directory = root.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = source03(), model = try SimulationWorkbenchFactory.make(document:.init(source:source),directory:directory)
    let graph = SimulationAnimationGraph(source:source,durationSeconds:0.1,layers:[.init(tracks:[.init(targetID:"part",keys:[.init(timeSeconds:0,transform:.identity),.init(timeSeconds:0.1,transform:.init(translation:.init(1,0,0)))])])])
    model.writeAnimationGraph(graph); await model.bakeAnimation()
    let file = try #require(model.exportURL)
    let baked = try JSONDecoder().decode(SimulationAnimationBake.self,from:Data(contentsOf:file))
    #expect(baked.frames.count == 4 && baked.frames.last?.objects["part"]?.translation.x == 1)
    #expect(try await model.archive.readDocument().animationGraphData != nil)
    model.invalidateLiveSource(); await model.bakeAnimation(); #expect(model.exportURL == nil)
    await model.close()
}
