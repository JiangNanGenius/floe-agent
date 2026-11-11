import Foundation
import Testing
import FloeChemistryCore
@testable import FloeChemistryEngine

/// Object removal and late-callback durability for the chemistry project.
/// The UI-layer quiesce/generation fences are object-compiled with the
/// FloeChemistryUI target; these tests lock the durable service semantics.
@Suite("Chemistry object removal lifecycle", .serialized)
struct ObjectRemovalLifecycleTests {
    private func fixture(title: String = "Removal lifecycle") async throws -> (ChemistryProjectStore, ChemistryService, ChemistryProject) {
        let store = try ChemistryProjectStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = try ChemistryService(store: store, authorize: { _ in })
        let project = try await service.create(title: title)
        return (store, service, project)
    }

    @Test func removalDropsObjectAndItsDocumentBlocksAndPreservesEverythingElse() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let first = try await service.importObject(project.id, title: "First spectrum", kind: .spectrum, format: "csv", source: "x,y\n0,0\n1,2\n")
        let second = try await service.importObject(project.id, title: "Second spectrum", kind: .spectrum, format: "csv", source: "x,y\n0,1\n1,3\n")
        _ = try await service.addText(project.id, text: "Standalone note")
        let before = try await service.project(project.id)
        #expect(before.objects.count == 2 && before.blocks.count == 3)

        let removed = try await service.removeObject(project.id, objectID: second.id, expectedObjectRevision: second.revision)
        #expect(removed.objects.map(\.id) == [first.id])
        #expect(removed.blocks.allSatisfy { $0.objectID != second.id })
        #expect(removed.blocks.count == 2)
        #expect(removed.revision == before.revision + 1)

        // Reopening from disk validates: no dangling block references remain.
        let reopened = try ChemistryService(store: ChemistryProjectStore(root: store.root), authorize: { _ in })
        let reread = try await reopened.project(project.id)
        #expect(reread.objects.map(\.id) == [first.id] && reread.blocks.count == 2)
        #expect(reread.blocks.first(where: { $0.objectID == first.id }) != nil)
        #expect(reread.blocks.first(where: { $0.objectID == nil })?.text == "Standalone note")
    }

    @Test func removalRejectsStaleRevisionsAndUnknownObjects() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let object = try await service.importObject(project.id, title: "Water", format: "xyz", source: waterXYZ)
        let stale = ChemicalObject(id: object.id, title: object.title, kind: object.kind, format: object.format,
                                   source: object.source, revision: object.revision + 9)
        await #expect(throws: ChemistryError.self) {
            _ = try await service.removeObject(project.id, objectID: stale.id, expectedObjectRevision: stale.revision)
        }
        await #expect(throws: ChemistryError.self) {
            _ = try await service.removeObject(project.id, objectID: UUID(), expectedObjectRevision: 0)
        }
        // Failed removals leave the project untouched.
        let after = try await service.project(project.id)
        #expect(after.objects.count == 1 && after.objects.first?.id == object.id)
    }

    @Test func noCoordinatePreparationPendingObjectCanBeRemoved() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pending = try await service.importObject(project.id, title: "Stereo source", format: "smi",
                                                     source: "C[C@H](O)F", deferPreparation: true)
        #expect(pending.facts?["preparationRequired"] == .bool(true) && pending.facts?["mass"] == nil)
        let removed = try await service.removeObject(project.id, objectID: pending.id, expectedObjectRevision: pending.revision)
        #expect(removed.objects.isEmpty && removed.blocks.isEmpty)
        // The authoritative input was the only copy; removing it is final at
        // the object level, while project history still records the revision.
        #expect(try await store.history(project.id).count >= 2)
    }

    @Test func historyRestoreRecoversContentRemovedByMistake() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let kept = try await service.importObject(project.id, title: "Kept", kind: .spectrum, format: "csv", source: "x,y\n0,0\n1,1\n")
        let removedObject = try await service.importObject(project.id, title: "Removed", kind: .spectrum, format: "csv", source: "x,y\n0,2\n1,0\n")
        let snapshot = try await service.project(project.id)
        let revisionWithBoth = snapshot.revision
        #expect(revisionWithBoth > 0)
        _ = try await service.removeObject(project.id, objectID: removedObject.id, expectedObjectRevision: removedObject.revision)
        #expect(try await service.project(project.id).objects.count == 1)

        let target = try #require(await store.history(project.id).first(where: { $0.revision == revisionWithBoth }))
        let restored = try await service.restore(target, expectedRevision: try await service.project(project.id).revision)
        #expect(restored.objects.count == 2)
        #expect(restored.objects.first(where: { $0.id == removedObject.id })?.source == removedObject.source)
        #expect(restored.objects.first(where: { $0.id == kept.id }) != nil)
    }

    @Test func frozenExternalRunSurvivesRemovalAndLateApplyFailsClosed() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let value: JSONValue = .object(["ok": .bool(true), "result": .object([
            "protocolVersion": .number(1), "methods": .array(["fixture.structure"].map(JSONValue.string)),
            "engines": .object(["contractFixture": .string("1")]), "unavailable": .object([:])])])
        let capabilities = try ChemistryWorkerCapabilities.decode(JSONEncoder().encode(value))
        try await service.registerExternalWorker(environmentID: "configured.fixture", capabilities: capabilities)
        let object = try await service.importObject(project.id, title: "Frozen input", format: "xyz", source: waterXYZ)
        let owner = ChemistryExecutionOwner(taskID: UUID(), hostRunID: UUID())
        let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
                                                         environmentID: "configured.fixture", owner: owner)
        let jobID = UUID()
        _ = try await service.adoptExternal(project.id, runID: prepared.runID, owner: owner,
                                            attemptID: prepared.identity.attemptID, jobID: jobID)
        _ = try await service.removeObject(project.id, objectID: object.id, expectedObjectRevision: object.revision)

        // The frozen run keeps its identity and can still finish honestly...
        var envelope = try JSONDecoder().decode(JSONValue.self, from: prepared.requestData())
        if case .object(var body) = envelope {
            body.removeValue(forKey: "requestJSON"); body["ok"] = .bool(true)
            body["result"] = .object(["cjson": .string("{\"chemicalJson\":1}")]); body["error"] = .null
            envelope = .object(body)
        }
        let finished = try await service.finishExternal(project.id, runID: prepared.runID, owner: owner, jobID: jobID,
                                                        response: JSONEncoder().encode(envelope))
        #expect(finished.status == .succeeded)

        // ...but it can never be applied to the removed object.
        await #expect(throws: ChemistryError.self) {
            _ = try await service.apply(project.id, runID: prepared.runID, expectedObjectRevision: object.revision)
        }
        // The project still validates with the run record intact.
        let final = try await service.project(project.id)
        #expect(final.objects.isEmpty && final.runs.count == 1 && final.runs[0].status == .succeeded)
    }

    @Test func terminateExternalAfterObjectRemovalStillRecordsTheOwnedCancellation() async throws {
        // The file-delete reconciliation path terminates the frozen external
        // run after its object was removed; the run record is project-level
        // and must still accept the owned cancellation.
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let value: JSONValue = .object(["ok": .bool(true), "result": .object([
            "protocolVersion": .number(1), "methods": .array(["fixture.structure"].map(JSONValue.string)),
            "engines": .object(["contractFixture": .string("1")]), "unavailable": .object([:])])])
        try await service.registerExternalWorker(environmentID: "configured.fixture", capabilities: try ChemistryWorkerCapabilities.decode(JSONEncoder().encode(value)))
        let object = try await service.importObject(project.id, title: "To remove", format: "xyz", source: waterXYZ)
        let owner = ChemistryExecutionOwner(taskID: UUID(), hostRunID: UUID())
        let prepared = try await service.prepareExternal(project.id, objectID: object.id, method: "fixture.structure",
                                                         environmentID: "configured.fixture", owner: owner)
        _ = try await service.removeObject(project.id, objectID: object.id, expectedObjectRevision: object.revision)
        let terminated = try await service.terminateExternal(project.id, runID: prepared.runID, owner: owner,
            jobID: nil, status: .cancelled, error: "Reconciled as stopped when its chemistry project was deleted.")
        #expect(terminated.status == .cancelled && terminated.finishedAt != nil)
        let final = try await service.project(project.id)
        #expect(final.objects.isEmpty && final.runs.count == 1 && final.runs[0].status == .cancelled)
        #expect(try await store.history(project.id).count >= 3)
    }

    @Test func lateSketchSaveAfterRemovalFailsAndRecoveryDraftSurvives() async throws {
        let (store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let drawing = try await service.createDrawing(project.id, title: "Fragile drawing")
        let ket = "{\"root\":{\"nodes\":[{\"type\":\"atom\",\"id\":1,\"position\":[0,0]}]}}"
        // Simulate a crashed save: the recovery record exists, then the user
        // removes the problem object before the late save callback fires.
        try await store.saveDrawingRecovery(ChemistryDrawingRecovery(projectID: project.id, object: drawing))
        _ = try await service.removeObject(project.id, objectID: drawing.id, expectedObjectRevision: drawing.revision)

        // The late publisher (an old in-flight save) cannot reach the removed object.
        await #expect(throws: ChemistryError.self) {
            _ = try await service.saveSketch(project.id, objectID: drawing.id, expectedObjectRevision: drawing.revision,
                                             ket: ket, format: nil, source: nil, smiles: nil, properties: nil)
        }
        // The unsaved drawing remains recoverable as a copy.
        let recoveries = try await service.drawingRecoveries(project.id)
        let draft = try #require(recoveries.first)
        let recovered = try await service.recoverDrawing(project.id, recoveryID: draft.id)
        #expect(recovered.title.contains("Recovered") && recovered.sketchDocument == drawing.sketchDocument)
        let final = try await service.project(project.id)
        #expect(final.objects.count == 1 && final.blocks.contains(where: { $0.objectID == recovered.id }))
    }
}
