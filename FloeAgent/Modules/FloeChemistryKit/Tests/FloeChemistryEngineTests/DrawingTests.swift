import Foundation
import Testing
import FloeChemistryCore
import FloeChemistryEngine

@Test func losslessDrawingPersistenceAndConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChemistryProjectStore(root: root)
    let service = try ChemistryService(store: store, authorize: { _ in })
    let project = try await service.create(title: "Drawing")
    let object = try await service.createDrawing(project.id, title: "Draft")
    let mol = try await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "export", format: "xyz", data: waterXYZ, options: .object(["outputFormat": .string("mol")])))
    let source = try #require(mol["text"]?.string)
    let ket = "{\"root\":{\"nodes\":[]},\"annotation\":\"stereo and reaction draft\"}"
    let updated = try await service.saveSketch(project.id, objectID: object.id, expectedObjectRevision: 0, ket: ket, format: "mol", source: source, smiles: "O", properties: ["gross": "H2 O", "molecular-weight": "18.015"])
    #expect(updated.source == source && updated.format == "mol")
    #expect(updated.facts?["atomCount"]?.number == 3)
    #expect(updated.facts?["compositionOnly"] == .bool(false))
    await #expect(throws: (any Error).self) { try await service.start(project.id, objectID: object.id, method: "uff.energy") }
    #expect(try await service.export(project.id, objectID: object.id, format: "ket") == ket)
    #expect(try await service.export(project.id, objectID: object.id, format: "mol") == source)
    await #expect(throws: (any Error).self) {
        try await service.saveSketch(project.id, objectID: object.id, expectedObjectRevision: 0, ket: "{}", format: nil, source: nil, smiles: nil)
    }
    let reopened = try await ChemistryProjectStore(root: root).load(project.id)
    #expect(reopened.objects.first?.sketchDocument == ket)
    #expect(reopened.objects.first?.sketchSMILES == "O")
    let recoveries = try await service.drawingRecoveries(project.id)
    #expect(recoveries.count == 1)
    let recovered = try await service.recoverDrawing(project.id, recoveryID: #require(recoveries.first?.id))
    #expect(recovered.id != object.id && recovered.sketchDocument == "{}")
    #expect(try await service.drawingRecoveries(project.id).isEmpty)
    let draft = try await service.saveSketch(project.id, objectID: object.id, expectedObjectRevision: updated.revision, ket: ket, format: "rxn", source: "$RXN\nretained reaction draft", smiles: nil)
    #expect(draft.kind == .reaction && draft.format == "rxn")
    #expect(draft.facts?["atomCount"] == nil)
    let run = try await service.start(project.id, objectID: object.id, method: "analyze")
    #expect(try await service.wait(project.id, runID: run).status == .failed)
    let moleculeAgain = try await service.saveSketch(project.id,objectID:object.id,expectedObjectRevision:draft.revision,ket:ket,format:"mol",source:source,smiles:"O")
    #expect(moleculeAgain.kind == .molecule)
}

@Test func projectReadCannotPublishARevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store = try ChemistryProjectStore(root:root)
    var project = ChemistryProject(title:"Read-only recovery")
    let object = ChemicalObject(title:"Water",format:"xyz",source:waterXYZ)
    project.objects = [object]
    project.runs = [ChemistryRun(input:object,inputDigest:"fixture",method:"uff.energy",options:.object([:]),environmentID:"native.local",engineVersion:"fixture")]
    let saved = try await store.save(project,expectedRevision:0)
    let reader = try ChemistryService(store:store,authorize:{access in
        guard access.action == .read else {throw ChemistryError.unavailable("Read only")}
    })
    let observed = try await reader.project(saved.id)
    #expect(observed.runs.first?.status == .interrupted)
    let persisted = try await store.load(saved.id)
    #expect(persisted.revision == saved.revision && persisted.runs.first?.status == .queued)
}
