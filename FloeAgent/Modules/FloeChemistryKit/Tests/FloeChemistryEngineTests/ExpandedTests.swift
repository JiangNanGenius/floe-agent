import Foundation
import Testing
import FloeChemistryCore
@testable import FloeChemistryEngine

@Test func crystalMeasurementsAndQuantumExchange() async throws {
    let backend = NativeChemistryBackend()
    let crystal = "{\"chemicalJson\":1,\"atoms\":{\"elements\":{\"number\":[55,17]},\"coords\":{\"3d\":[0,0,0,2.06,2.06,2.06]}},\"unitCell\":{\"a\":4.12,\"b\":4.12,\"c\":4.12,\"alpha\":90,\"beta\":90,\"gamma\":90}}"
    let supercell = try await backend.evaluate(ChemistryRequest(operation: "crystal.supercell", format: "cjson", data: crystal, options: .object(["a": .number(2), "b": .number(2), "c": .number(2)])))
    #expect(supercell["atomCount"]?.number == 16)
    let measurement = try await backend.evaluate(ChemistryRequest(operation: "measure", format: "xyz", data: "3\nright angle\nO 0 0 0\nH 1 0 0\nH 0 1 0", options: .object(["atoms": .array([.number(1), .number(0), .number(2)])])))
    #expect(abs(measurement["angle"]!.number! - 90) < 1e-8)
    #expect(abs(measurement["distance"]!.number! - 1) < 1e-8)
    let qc = "{\"schema_name\":\"qcschema_molecule\",\"schema_version\":2,\"symbols\":[\"H\",\"H\"],\"geometry\":[0,0,0,0,0,1.4],\"molecular_charge\":0,\"molecular_multiplicity\":1}"
    let molecule = try await backend.evaluate(ChemistryRequest(operation: "parse", format: "qcschema", data: qc))
    #expect(molecule["formula"]?.string == "H2")
    let exported = try await backend.evaluate(ChemistryRequest(operation: "export", format: "cjson", data: molecule["cjson"]!.string!, options: .object(["outputFormat": .string("qcschema")])))
    let readBack = try await backend.evaluate(ChemistryRequest(operation: "parse", format: "qcschema", data: exported["text"]!.string!))
    #expect(readBack["formula"]?.string == "H2")
    let length = try await backend.evaluate(ChemistryRequest(operation: "measure", format: "cjson", data: readBack["cjson"]!.string!, options: .object(["atoms": .array([.number(0), .number(1)])])))
    #expect(abs(length["distance"]!.number! - 0.740848) < 0.00001)
}

@Test func biomoleculeTrajectoryAndInvalidEdits() async throws {
    let backend = NativeChemistryBackend()
    let pdb = "ATOM      1  N   GLY A   1      -0.500   0.000   0.000  1.00  0.00           N  \nATOM      2  CA  GLY A   1       0.950   0.000   0.000  1.00  0.00           C  \nATOM      3  C   GLY A   1       1.500   1.400   0.000  1.00  0.00           C  \nATOM      4  O   GLY A   1       0.900   2.400   0.000  1.00  0.00           O  \nEND\n"
    let structure = try await backend.evaluate(ChemistryRequest(operation: "parse", format: "pdb", data: pdb))
    #expect(structure["residueCount"]?.number == 1 && structure["atomCount"]?.number == 4)
    let frames = "1\nframe 0\nHe 0 0 0\n1\nframe 1\nHe 1 0 0\n"
    let result = try await backend.evaluate(ChemistryRequest(operation: "trajectory.frame", format: "xyz", data: frames, options: .object(["frame": .number(1)])))
    #expect(result["coordinateSetCount"]?.number == 2)
    let frame = try JSONDecoder().decode(JSONValue.self, from: Data(result["cjson"]!.string!.utf8))
    #expect(frame["atoms"]?["coords"]?["3d"]?.array?.first?.number == 1)
    await #expect(throws: (any Error).self) { try await backend.evaluate(ChemistryRequest(operation: "parse", format: "smi", data: "N[C@@H](C)C(=O)O")) }
    await #expect(throws: (any Error).self) { try await backend.evaluate(ChemistryRequest(operation: "edit", format: "xyz", data: waterXYZ, options: .object(["edits": .array([.object(["op": .string("atom.remove"), "index": .number(0.5)])])]))) }
}

@Test func actualToolSessionScopeAndWorkerFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try ChemistryService(store: ChemistryProjectStore(root: root), authorize: { _ in })
    let session = ChemistryToolSession(taskID: UUID(), service: service, authorizedProjectIDs: [], canCreate: true)
    let created = try await session.invoke(name: "chemistry.project.create", arguments: .object(["title": .string("AI tool qualification")]))
    let projectID = created["id"]!.string!
    let imported = try await session.invoke(name: "chemistry.object.import", arguments: .object(["projectID": .string(projectID), "title": .string("Water"), "format": .string("xyz"), "source": .string(waterXYZ)]))
    #expect(imported["originalSource"]?.string == waterXYZ)
    let started = try await session.invoke(name: "chemistry.run.start", arguments: .object(["projectID": .string(projectID), "objectID": imported["id"]!, "method": .string("uff.energy")]))
    let run = try await service.wait(UUID(uuidString: projectID)!, runID: UUID(uuidString: started["runID"]!.string!)!)
    #expect(run.status == .succeeded && run.result?["energy"]?.number?.isFinite == true)
    await #expect(throws: (any Error).self) { try await session.invoke(name: "chemistry.project.read", arguments: .object(["projectID": .string(UUID().uuidString), "authorized": .bool(true)])) }
    let worker = ConfiguredChemistryBackend.worker(environmentID: "configured.mac", engineVersion: "fixture", methods: ["failure"]) { _ in Data("{\"ok\":false,\"error\":\"solver failed\"}".utf8) }
    await #expect(throws: ChemistryError.invalid("solver failed")) { try await worker.evaluate(ChemistryRequest(operation: "failure", format: "xyz", data: waterXYZ)) }
}
