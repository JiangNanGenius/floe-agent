import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationPhysics
import FloeSimulationUI

private func testDirectory() throws -> URL {
    var repository = URL(fileURLWithPath:#filePath)
    for _ in 0..<6 { repository.deleteLastPathComponent() }
    let directory = repository.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); return directory
}
private func testSource() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"b",count:64)) }
private enum WaitFailure: Error { case timedOut }
private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
    throw WaitFailure.timedOut
}
private actor WorkerGate {
    private var started = Set<UUID>()
    private var waiting: [UUID:CheckedContinuation<Void,Never>] = [:]
    func enter(_ id: UUID) async { started.insert(id); await withCheckedContinuation { waiting[id] = $0 } }
    func hasStarted(_ id: UUID) -> Bool { started.contains(id) }
    func release(_ id: UUID) { waiting.removeValue(forKey:id)?.resume() }
}
private struct ControlledBackend: SimulationBackend {
    var gate: WorkerGate
    var descriptor: SimulationBackendDescriptor { .init(id:"controlled-fixture",version:"1",supportedStudies:[.rigidBody],isAvailable:true) }
    func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        // Models a native worker that can only stop at its next safe boundary.
        await gate.enter(request.id)
        return .init(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,frames:[.init(id:0,fields:[.init(id:"value",name:"Value",unit:"1",location:.global,components:1,values:[1])])])
    }
}

@Test func cancellationKeepsTheQueueUntilNativeWorkerStops() async throws {
    let gate = WorkerGate(), coordinator = SimulationCoordinator(backends:[ControlledBackend(gate:gate)]), source = testSource()
    let first = SimulationRequest(source:source,study:.init(name:"First",kind:.rigidBody)), second = SimulationRequest(source:source,study:.init(name:"Second",kind:.rigidBody))
    try await coordinator.start(first); try await eventually { await gate.hasStarted(first.id) }
    try await coordinator.start(second); await coordinator.cancel(first.id)
    let pending = await coordinator.snapshots()
    #expect(pending.first { $0.id == first.id }?.status == .cancelling)
    #expect(pending.first { $0.id == second.id }?.status == .queued)
    #expect(await gate.hasStarted(second.id) == false)
    await gate.release(first.id); try await eventually { await gate.hasStarted(second.id) }
    #expect(await coordinator.snapshots().first { $0.id == first.id }?.status == .cancelled)
    await gate.release(second.id)
    try await eventually { await coordinator.snapshots().first { $0.id == second.id }?.status == .completed }
}

@Test func revisedStudyRejectsLateNativeResults() async throws {
    let gate = WorkerGate(), coordinator = SimulationCoordinator(backends:[ControlledBackend(gate:gate)])
    let request = SimulationRequest(source:testSource(),study:.init(name:"Original",kind:.rigidBody))
    try await coordinator.start(request); try await eventually { await gate.hasStarted(request.id) }
    await coordinator.invalidateStudy(request.study.id,source:request.source,revision:request.study.revision+1)
    await gate.release(request.id)
    try await eventually { await coordinator.snapshots().first { $0.id == request.id }?.status == .stale }
    #expect(await coordinator.snapshots().first { $0.id == request.id }?.resultID == nil)
    await #expect(throws:SimulationError.self) { try await coordinator.start(request) }
}

@Test @MainActor func uiAndToolsShareCommittedWorkspaceAndRejectStaleEdits() async throws {
    let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let document = SimulationWorkspaceDocument(source:testSource())
    let model = try SimulationWorkbenchFactory.make(document:document,directory:directory)
    model.createStudy(.electrostatic); #expect(await model.save())
    let tools = SimulationWorkbenchFactory.tools(for:model) { _,_,_ in }
    let observer = Task { await model.observe() }; defer { observer.cancel() }
    let snapshot = await model.workspace.snapshot()
    let context = SimulationToolContext(taskID:UUID(),source:document.source,expectedGeneration:snapshot.generation)
    #expect(try await tools.read(context).document.studies == model.document.studies)
    _ = try await tools.putMaterial(.init(name:"Air",properties:["relativePermittivity":1]),context:context)
    try await eventually { await MainActor.run { model.document.materials.count == 1 } }
    await #expect(throws:SimulationError.self) { try await tools.putMaterial(.init(name:"Stale",properties:[:]),context:context) }
    #expect(await model.workspace.snapshot().document.materials.count == 1)
}

@Test func toolAuthorizationCannotComeFromSavedInput() async throws {
    enum Denied: Error { case denied }
    let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = testSource(), document = SimulationWorkspaceDocument(source:source), coordinator = SimulationCoordinator()
    let archive = try SimulationArchiveStore(directory:directory), store = SimulationWorkspaceStore(document:document,archive:archive,coordinator:coordinator)
    let tools = SimulationToolService(workspace:store,coordinator:coordinator,archive:archive) { _,_,_ in throw Denied.denied }
    await #expect(throws:Denied.self) { try await tools.putStudy(.init(name:"Unauthorized",kind:.rigidBody),context:.init(taskID:UUID(),source:source,expectedGeneration:0)) }
    #expect(await store.snapshot().document.studies.isEmpty)
}

@Test func particleBirthLifetimeAndSeedReachRapier() async throws {
    var configuration = ParticleSimulationConfiguration(), emitter = SimulationParticleEmitter()
    emitter.burstCount = 2; emitter.particlesPerSecond = 0; emitter.startSeconds = 0.25; emitter.endSeconds = 0.5; emitter.lifetimeSeconds = 0.2
    emitter.origin = .zero; emitter.halfExtents = .zero; emitter.velocity = .init(1,0,0); emitter.velocitySpread = .zero; emitter.dragPerSecond = 0
    configuration.emitters = [emitter]; configuration.gravity = .zero
    let firstScene = try configuration.physicsConfiguration(budget:.init()), secondScene = try configuration.physicsConfiguration(budget:.init())
    #expect(firstScene == secondScene)
    // Separate coincident particles so their mutual collision does not change the lifetime probe.
    configuration.emitters[0].burstCount = 1
    var study = SimulationStudy(name:"Particles",kind:.particles); try study.setConfiguration(configuration)
    let request = SimulationRequest(source:testSource(),study:study)
    let result = try await ParticleSimulationBackend().solve(request) { _ in }
    #expect(result.frames.first?.fields.first { $0.id == "body_visible" }?.values == [0])
    #expect(result.frames.last?.fields.first { $0.id == "body_visible" }?.values == [0])
    #expect(result.frames.contains { $0.fields.first { $0.id == "body_visible" }?.values == [1] })
    let position = try #require(result.frames.last?.fields.first { $0.id == "body_position" }?.values)
    #expect(position[0] > 0.19 && position[0] < 0.22)
}

@Test @MainActor func reopeningRestoresEditedStudyAndRejectsSymlinkStorage() async throws {
    let directory = try testDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let document = SimulationWorkspaceDocument(source:testSource())
    let model = try SimulationWorkbenchFactory.make(document:document,directory:directory)
    model.createStudy(.radioFrequency); model.renameStudy("Saved antenna")
    #expect(await model.save())
    let reopened = try await SimulationWorkbenchFactory.openOrCreate(initial:document,directory:directory)
    #expect(reopened.document.studies.first?.name == "Saved antenna")
    #expect(reopened.document.studies.first?.configuration == model.document.studies.first?.configuration)
    let outside = directory.appendingPathComponent("outside",isDirectory:true)
    try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
    try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("exports"),withDestinationURL:outside)
    await #expect(throws:SimulationError.self) { try await model.archive.saveAttachment(["value":1],id:UUID(),fileExtension:"animation.json") }
    #expect(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
}
