import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationRuntime
import FloeSimulationAnimation
import FloeSimulationUI

private actor SessionWorkerGate {
    private var continuation: CheckedContinuation<Void,Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct SessionWorker: SimulationBackend {
    var gate: SessionWorkerGate
    var descriptor: SimulationBackendDescriptor { .init(id:"00.session-fixture",version:"1",supportedStudies:[.rigidBody],isAvailable:true) }
    func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        await gate.wait()
        return .init(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,frames:[.init(id:0,fields:[.init(id:"value",name:"Value",unit:"1",location:.global,components:1,values:[1])])])
    }
}
private func waitSession(_ predicate: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await predicate() { return };try await Task.sleep(for:.milliseconds(10)) }
    throw SimulationError.solverFailure("The session lifecycle fixture did not advance.")
}

private func sessionDirectory() -> URL {
    var root = URL(fileURLWithPath:#filePath); for _ in 0..<6 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
}
private func sessionSource() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"b",count:64)) }

@Test @MainActor func session02ReopeningChangedCADInvalidatesMeshAndOldAnimationPreview() async throws {
    let directory = sessionDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = sessionSource(), mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(1,1,1))
    var study = SimulationStudy(name:"Keep my setup",kind:.structuralStatic);study.meshID = mesh.id
    let original = try SimulationWorkbenchFactory.make(document:.init(source:source,studies:[study],meshes:[mesh]),directory:directory)
    original.writeAnimationGraph(.init(source:source,layers:[.init(tracks:[.init(targetID:"body",keys:[.init(timeSeconds:0,transform:.identity)])])]))
    #expect(await original.save())
    await original.close()
    var current = source;current.revision += 1;current.contentSHA256 = String(repeating:"c",count:64)
    let reopened = try await SimulationWorkbenchFactory.openOrCreate(initial:.init(source:current),directory:directory)
    #expect(reopened.document.source == current && reopened.document.meshes.isEmpty)
    #expect(reopened.selectedStudy?.name == "Keep my setup" && reopened.selectedStudy?.meshID == nil)
    #expect(reopened.selectedStudy?.revision == study.revision+1)
    reopened.previewAnimation();#expect(reopened.animationPose == nil && reopened.errorDetails != nil)
    #expect(try await reopened.archive.readDocument().source == current)
    await reopened.close()
}

@Test @MainActor func session02OneWorkspaceIsSharedAndClosedHandlesCannotWrite() async throws {
    let directory = sessionDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = sessionSource(), registry = SimulationWorkbenchSessions(), initial = SimulationWorkspaceDocument(source:source)
    let first = try await registry.open(initial:initial,directory:directory)
    let second = try await registry.open(initial:initial,directory:directory)
    #expect(first === second)
    first.createStudy(.rigidBody);#expect(await first.save())
    let tools = SimulationWorkbenchFactory.tools(for:first) { _,_,_ in }
    let snapshot = await first.workspace.snapshot(), context = SimulationToolContext(taskID:UUID(),source:source,expectedGeneration:1)
    #expect(snapshot.generation == 1)
    try await registry.close(directory:directory)
    #expect(first.isClosed && second.isClosed)
    await #expect(throws:SimulationError.self) { try await tools.putMaterial(.init(name:"Late",properties:[:]),context:context) }
    await #expect(throws:SimulationError.self) { try await first.coordinator.start(.init(source:source,study:.init(name:"Late",kind:.rigidBody))) }
    let reopened = try await registry.open(initial:initial,directory:directory)
    #expect(reopened !== first && reopened.document.studies.count == 1)
    #expect(await first.save() == false)
    try await registry.close(directory:directory)
}

@Test @MainActor func session02ClosingWaitsForNativeWorkerBeforeReopening() async throws {
    let directory = sessionDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let source = sessionSource(), registry = SimulationWorkbenchSessions(), gate = SessionWorkerGate()
    let initial = SimulationWorkspaceDocument(source:source)
    let model = try await registry.open(initial:initial,directory:directory,additionalBackends:[SessionWorker(gate:gate)])
    model.createStudy(.rigidBody);#expect(await model.save());await model.run()
    try await waitSession { await gate.entered }
    let close = Task { @MainActor in try await registry.close(directory:directory) }
    try await waitSession { await model.coordinator.snapshots().first?.status == .cancelling }
    await #expect(throws:SimulationError.self) { try await registry.open(initial:initial,directory:directory) }
    await gate.release();try await close.value
    #expect(await model.coordinator.snapshots().first?.status == .cancelled)
    let reopened = try await registry.open(initial:initial,directory:directory)
    #expect(reopened !== model)
    try await registry.close(directory:directory)
}
