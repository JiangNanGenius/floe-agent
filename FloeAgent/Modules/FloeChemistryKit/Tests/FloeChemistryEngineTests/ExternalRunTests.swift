import Foundation
import Testing
import FloeChemistryCore
@testable import FloeChemistryEngine

private func capabilityFixture(_ methods: [String] = ["fixture.structure"]) throws -> ChemistryWorkerCapabilities {
    let value: JSONValue = .object(["ok": .bool(true), "result": .object([
        "protocolVersion": .number(1), "methods": .array(methods.map(JSONValue.string)),
        "engines": .object(["contractFixture": .string("1")]),
        "unavailable": .object(["xtb": .string("Not configured in this contract fixture.")])
    ])])
    return try ChemistryWorkerCapabilities.decode(JSONEncoder().encode(value))
}

private func boundFixture(_ prepared: ChemistryPreparedRun, result: JSONValue? = nil, error: String? = nil) throws -> Data {
    guard case .object(var value) = try JSONDecoder().decode(JSONValue.self, from: prepared.requestData()) else { throw ChemistryError.invalid("Invalid fixture.") }
    value.removeValue(forKey: "requestJSON"); value["ok"] = .bool(error == nil)
    value["result"] = result; value["error"] = error.map(JSONValue.string)
    return try JSONEncoder().encode(JSONValue.object(value))
}

private func externalFixture() async throws -> (ChemistryProjectStore, ChemistryService, ChemistryProject, ChemicalObject, ChemistryExecutionOwner) {
    let store = try ChemistryProjectStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let service = try ChemistryService(store: store, authorize: { _ in })
    try await service.registerExternalWorker(environmentID: "configured.fixture", capabilities: capabilityFixture())
    let project = try await service.create(title: "External calculation contract")
    let object = try await service.importObject(project.id, title: "Water", format: "xyz", source: waterXYZ)
    return (store, service, project, object, .init(taskID: UUID(), hostRunID: UUID()))
}

@Test func bundledWorkerInventoryIsAvailableAndVerified() throws {
    let files = try ChemistryWorkerDeployment.files(), digests = try ChemistryWorkerDeployment.digests()
    #expect(files.count == 6 && digests.count == 5)
    #expect(ChemistryWorkerDeployment.protocolVersion == 1)
    for (name, digest) in digests { #expect(ChemistryProjectStore.digest(files[name]!) == digest) }
}

@Test func richSourceCanReachItsWorkerWithoutLossyNativeConversion() async throws {
    let (store, service, project, _, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try await service.registerExternalWorker(environmentID: "configured.fixture", capabilities: capabilityFixture(["rdkit.embed", "gemmi.crystal"]))
    let stereo = "C[C@H](O)F"
    let input = try await service.importObject(project.id, title: "Stereo input", format: "smi", source: stereo, deferPreparation: true)
    #expect(input.source == stereo && input.originalSource == stereo)
    #expect(input.facts?["preparationRequired"] == .bool(true) && input.facts?["mass"] == nil)
    let prepared = try await service.prepareExternal(project.id, objectID: input.id, method: "rdkit.embed",
        environmentID: "configured.fixture", owner: owner)
    let request = try JSONDecoder().decode(ChemistryRequest.self, from: Data(prepared.requestJSON.utf8))
    #expect(request.data == stereo && request.format == "smi")
    let cif = "data_retained\n_cell_length_a 4.12\n"
    let crystal = try await service.importObject(project.id, title: "CIF source", kind: .crystal, format: "cif", source: cif, deferPreparation: true)
    #expect(crystal.source == cif && crystal.originalFormat == "cif" && crystal.facts?["preparationRequired"] == .bool(true))
}

@Test func externalPrepareReadbackAndDynamicCapabilities() async throws {
    let (store, service, project, object, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    let bytes = try prepared.requestData()
    let saved = try await store.load(project.id)
    #expect(saved.runs[0].status == .queued && saved.runs[0].externalExecution?.jobID == nil)
    #expect(prepared.identity.taskID == owner.taskID && prepared.identity.hostRunID == owner.hostRunID)
    await #expect(throws: (any Error).self) {
        try await service.start(project.id, objectID: object.id, method: "fixture.structure", environmentID: "configured.fixture")
    }
    // A new service has no in-memory task and no registered fixture backend. Reading
    // preserves the genuine external lifecycle and does not replay or publish a revision.
    let reopened = try ChemistryService(store: ChemistryProjectStore(root: store.root), authorize: { _ in })
    #expect(try await reopened.project(project.id).runs[0].status == .queued)
    let recovered = try await reopened.preparedExternal(project.id, runID: prepared.runID, owner: owner)
    #expect(try recovered.requestData() == bytes)
    #expect(try await store.load(project.id).revision == saved.revision)
    await #expect(throws: (any Error).self) {
        try await reopened.preparedExternal(project.id, runID: prepared.runID, owner: .init(taskID: UUID(), hostRunID: owner.hostRunID))
    }
    try await service.removeExternalWorker(environmentID: "configured.fixture")
    #expect(await service.capabilities()["configured.fixture"] == nil)
    try await service.registerExternalWorker(environmentID: "configured.fixture", capabilities: capabilityFixture(["fixture.reprobed"]))
    #expect(await service.capabilities()["configured.fixture"] == ["fixture.reprobed"])
    #expect(try await service.preparedExternal(project.id, runID: prepared.runID, owner: owner) == prepared)
    await #expect(throws: (any Error).self) {
        try await service.registerExternalWorker(environmentID: "native.local", capabilities: capabilityFixture())
    }
}

@Test func externalReceiptsResultsAndIdempotentCompletion() async throws {
    let (store, service, project, object, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    let jobID = UUID()
    await #expect(throws: (any Error).self) {
        try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: UUID(), jobID: jobID)
    }
    let adopted = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: jobID)
    #expect(adopted.status == .running)
    let revision = try await store.load(project.id).revision
    _ = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: jobID)
    #expect(try await store.load(project.id).revision == revision)
    await #expect(throws: (any Error).self) {
        try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: UUID())
    }
    let actualStructure = try await NativeChemistryBackend().evaluate(.init(operation: "parse", format: "xyz", data: waterXYZ))
    let output = try boundFixture(prepared, result: actualStructure)
    let another = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    await #expect(throws: (any Error).self) {
        try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID,
            response: boundFixture(another, result: actualStructure))
    }
    await #expect(throws: (any Error).self) {
        try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, response: Data(output.prefix(40)))
    }
    #expect(try await service.project(project.id).runs[0].status == .running)
    let completed = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, response: output)
    #expect(completed.status == .succeeded && completed.result?["atomCount"]?.number == 3)
    let completedRevision = try await store.load(project.id).revision
    _ = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, response: output)
    #expect(try await store.load(project.id).revision == completedRevision)
    let applied = try await service.apply(project.id, runID: prepared.runID, expectedObjectRevision: 0)
    #expect(applied.revision == 1 && applied.facts?["formula"]?.string == "H2O")
}

@Test func externalCancellationFailureAndAuthorizationFences() async throws {
    let (store, service, project, object, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    let jobID = UUID()
    _ = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: jobID)
    await #expect(throws: (any Error).self) { try await service.cancel(project.id, runID: prepared.runID) }
    await #expect(throws: (any Error).self) {
        try await service.terminateExternal(project.id, runID: prepared.runID, owner: owner, jobID: nil, status: .cancelled, error: "Wrong receipt")
    }
    _ = try await service.terminateExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, status: .cancelled, error: "Owned job was stopped")
    let late = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID,
        response: boundFixture(prepared, result: .object(["contractFixture": .bool(true)])))
    #expect(late.status == .cancelled && late.result == nil)
    let denied = try ChemistryService(store: store, authorize: { access in
        if access.action == .compute { throw ChemistryError.unavailable("Compute denied") }
    })
    await #expect(throws: ChemistryError.unavailable("Compute denied")) {
        try await denied.terminateExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, status: .failed, error: "Denied")
    }
    let failure = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure", environmentID: "configured.fixture", owner: owner)
    let failureJob = UUID()
    _ = try await service.adoptExternal(project.id, runID: failure.runID, owner: owner, attemptID: failure.identity.attemptID, jobID: failureJob)
    let failed = try await service.finishExternal(project.id, runID: failure.runID, owner: owner, jobID: failureJob,
        response: boundFixture(failure, error: "Bound engine failure"))
    #expect(failed.status == .failed && failed.error == "Bound engine failure" && failed.result == nil)
}

@Test func externalApplyRetainsMOLAndFencesSameRevisionChanges() async throws {
    let (store, service, project, object, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    let jobID = UUID()
    _ = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: jobID)
    let native = NativeChemistryBackend()
    let mol = try await native.evaluate(.init(operation: "export", format: "xyz", data: waterXYZ, options: .object(["outputFormat": .string("mol")])))
    let result: JSONValue = .object(["molblock": mol["text"]!])
    _ = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID, response: boundFixture(prepared, result: result))
    var changed = try await store.load(project.id)
    changed.objects[0].source += "\n"
    let sourceRevision = changed.revision
    _ = try await store.save(changed, expectedRevision: sourceRevision)
    await #expect(throws: (any Error).self) { try await service.apply(project.id, runID: prepared.runID, expectedObjectRevision: 0) }
    // Restore the exact frozen object, simulating a deliberate project restoration.
    changed = try await store.load(project.id); changed.objects[0] = object
    _ = try await store.save(changed, expectedRevision: changed.revision)
    let applied = try await service.apply(project.id, runID: prepared.runID, expectedObjectRevision: 0)
    #expect(applied.format == "mol" && applied.originalFormat == "xyz" && applied.facts?["atomCount"]?.number == 3)
}

@Test func restoredHistoryCannotResurrectACancelledExternalAttempt() async throws {
    let (store, service, project, object, owner) = try await externalFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
        environmentID: "configured.fixture", owner: owner)
    let jobID = UUID()
    _ = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner, attemptID: prepared.identity.attemptID, jobID: jobID)
    let runningVersion = try #require(await store.history(project.id).first)
    _ = try await service.terminateExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID,
        status: .cancelled, error: "Actual owned job stopped")
    let currentRevision = try await store.load(project.id).revision
    let restored = try await service.restore(runningVersion, expectedRevision: currentRevision)
    #expect(restored.runs[0].status == .interrupted && restored.runs[0].finishedAt != nil)
    let late = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID,
        response: boundFixture(prepared, result: .object(["contractFixture": .bool(true)])))
    #expect(late.status == .interrupted && late.result == nil)
    #expect(try await store.load(project.id).revision == restored.revision)
}

private actor ApplyRestoreGate {
    var armed = false
    var editCalls = 0
    var paused = false
    var observer: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func authorize(_ access: ChemistryAccess) async {
        guard armed, access.action == .edit else { return }
        editCalls += 1
        guard editCalls == 3 else { return }
        paused = true; observer?.resume(); observer = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

@Test func applyingResultRechecksRunAtCommitAfterRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = ApplyRestoreGate(), store = try ChemistryProjectStore(root: root)
    let service = try ChemistryService(store: store, authorize: { await gate.authorize($0) })
    let project = try await service.create(title: "Apply/restore race")
    let object = try await service.importObject(project.id, title: "Water", format: "xyz", source: waterXYZ)
    let beforeRun = try #require(await store.history(project.id).first)
    let runID = try await service.start(project.id, objectID: object.id, method: "uff.energy")
    #expect(try await service.wait(project.id, runID: runID).status == .succeeded)
    await gate.arm()
    let applying = Task { try await service.apply(project.id, runID: runID, expectedObjectRevision: object.revision) }
    await gate.waitUntilPaused()
    let current = try await store.load(project.id)
    let restored = try await service.restore(beforeRun, expectedRevision: current.revision)
    #expect(restored.objects[0] == object && restored.runs.isEmpty)
    await gate.resume()
    await #expect(throws: (any Error).self) { try await applying.value }
    let final = try await store.load(project.id)
    #expect(final.objects[0] == object && final.runs.isEmpty && final.revision == restored.revision)
}
