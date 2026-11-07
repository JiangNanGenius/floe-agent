import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationRuntime

private actor MeshingGate {
    var entered = false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct GatedMeshDriver: SimulationGeometryDriver {
    var gate: MeshingGate
    var isAvailable: Bool { true }
    func generate(_ geometry: SimulationGeometrySnapshot, settings: SimulationMeshSettings, budget: SimulationBudget, progress: @escaping SimulationProgressHandler) async throws -> SimulationMesh {
        await gate.wait()
        return try SimulationBoxMesher.generate(source:geometry.source,maximum:.init(0.01,0.01,0.01),budget:budget)
    }
}
private func eventuallyMesh(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
    throw SimulationError.solverFailure("Timed out waiting for the meshing lifecycle fixture.")
}

@Test func closure02MesherKeepsOwnershipUntilNativeStopAndRejectsLateMesh() async throws {
    var repository = URL(fileURLWithPath:#filePath); for _ in 0..<6 { repository.deleteLastPathComponent() }
    let directory = repository.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"e",count:64))
    let study = SimulationStudy(name:"Meshing",kind:.structuralStatic), archive = try SimulationArchiveStore(directory:directory)
    let workspace = SimulationWorkspaceStore(document:.init(source:source,studies:[study]),archive:archive,coordinator:SimulationCoordinator())
    let gate = MeshingGate()
    let service = SimulationMeshingService(workspace:workspace,mesher:.init(driver:GatedMeshDriver(gate:gate))) { source in
        let surface = SimulationMesh(source:source,nodes:[.zero,.init(1,0,0),.init(0,1,0),.init(0,0,1)],elements:[[0,2,1],[0,1,3],[0,3,2],[1,2,3]].map { .init(kind:.triangle3,nodes:$0,regionID:"surface") })
        return .init(source:source,surface:surface,sourceLengthToMeters:1)
    }
    let id = try await service.start(studyID:study.id,source:source,expectedGeneration:0,settings:.init())
    try await eventuallyMesh { await gate.entered }
    var changed = await workspace.snapshot().document
    changed.source.revision += 1; changed.source.contentSHA256 = String(repeating:"f",count:64)
    _ = try await workspace.commit(changed,expectedGeneration:0)
    try await eventuallyMesh { await service.snapshots().first { $0.id == id }?.status == .cancelling }
    await #expect(throws:SimulationError.self) { try await service.start(studyID:study.id,source:changed.source,expectedGeneration:1,settings:.init()) }
    await gate.release()
    try await eventuallyMesh { await service.snapshots().first { $0.id == id }?.status == .stale }
    #expect(await workspace.snapshot().document.meshes.isEmpty)
}

@Test func closure02MesherCommitsMeshAndSettingsToSharedWorkspace() async throws {
    var repository = URL(fileURLWithPath:#filePath); for _ in 0..<6 { repository.deleteLastPathComponent() }
    let directory = repository.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"e",count:64))
    let study = SimulationStudy(name:"Meshing",kind:.structuralStatic), archive = try SimulationArchiveStore(directory:directory)
    let workspace = SimulationWorkspaceStore(document:.init(source:source,studies:[study]),archive:archive,coordinator:SimulationCoordinator())
    let gate = MeshingGate(), settings = SimulationMeshSettings(maximumSizeMeters:0.002,minimumSizeMeters:0.0002)
    let service = SimulationMeshingService(workspace:workspace,mesher:.init(driver:GatedMeshDriver(gate:gate))) { source in
        let surface = SimulationMesh(source:source,nodes:[.zero,.init(1,0,0),.init(0,1,0)],elements:[.init(kind:.triangle3,nodes:[0,1,2],regionID:"fixture")])
        return .init(source:source,surface:surface,sourceLengthToMeters:1)
    }
    let id = try await service.start(studyID:study.id,source:source,expectedGeneration:0,settings:settings)
    try await eventuallyMesh { await gate.entered }; await gate.release()
    try await eventuallyMesh { await service.snapshots().first { $0.id == id }?.status.isTerminal == true }
    #expect(await service.snapshots().first { $0.id == id }?.status == .completed)
    let saved = await workspace.snapshot()
    #expect(saved.document.meshes.count == 1 && saved.document.meshSettings == settings)
    #expect(saved.document.studies.first?.meshID == saved.document.meshes.first?.id)
    #expect(try await archive.readDocument() == saved.document)
}
