import Foundation
import Testing
import FloeChemistryCore
@testable import FloeChemistryEngine

let waterXYZ = "3\nwater\nO 0 0 0\nH 1.2 0 0\nH -0.2 1.1 0\n"

@Test func actualNativeChemistry() async throws {
    let native = NativeChemistryBackend()
    let water = try await native.evaluate(ChemistryRequest(operation: "parse", format: "xyz", data: waterXYZ))
    #expect(water["atomCount"]?.number == 3)
    #expect(water["formula"]?.string == "H2O")
    #expect(abs((water["mass"]?.number ?? 0) - 18.015) < 0.02)
    let ethanol = try await native.evaluate(ChemistryRequest(operation: "parse", format: "smi", data: "CCO"))
    #expect(ethanol["formula"]?.string == "C2H6O")
    let caffeine = try await native.evaluate(ChemistryRequest(operation: "parse", format: "smi", data: "Cn1c(=O)c2c(ncn2C)n(C)c1=O"))
    #expect(caffeine["formula"]?.string == "C8H10N4O2")
    #expect(abs((caffeine["mass"]?.number ?? 0) - 194.19) < 0.05)
    let optimized = try await native.evaluate(ChemistryRequest(operation: "uff.optimize", format: "xyz", data: waterXYZ, options: .object(["iterations": .number(100)])))
    #expect(optimized["energy"]!.number! <= optimized["initialEnergy"]!.number!)
    #expect(optimized["energy"]!.number!.isFinite)
    let exported = try await native.evaluate(ChemistryRequest(operation: "export", format: "cjson", data: optimized["cjson"]!.string!, options: .object(["outputFormat": .string("sdf")])))
    let readBack = try await native.evaluate(ChemistryRequest(operation: "parse", format: "sdf", data: exported["text"]!.string!))
    #expect(readBack["atomCount"]?.number == 3)
    await #expect(throws: (any Error).self) { try await native.evaluate(ChemistryRequest(operation: "parse", format: "xyz", data: "not xyz")) }
}

@Test func realServicePipelineAndStaleApply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChemistryProjectStore(root: root)
    let service = try ChemistryService(store: store, authorize: { _ in })
    let p = try await service.create(title: "Qualification")
    let object = try await service.importObject(p.id, title: "Water", format: "xyz", source: waterXYZ)
    let runID = try await service.start(p.id, objectID: object.id, method: "uff.optimize", options: .object(["iterations": .number(100)]))
    let run = try await service.wait(p.id, runID: runID)
    #expect(run.status == .succeeded)
    #expect(run.input.revision == 0 && run.inputDigest.count == 64)
    let updated = try await service.apply(p.id, runID: runID, expectedObjectRevision: 0)
    #expect(updated.revision == 1)
    await #expect(throws: (any Error).self) { try await service.apply(p.id, runID: runID, expectedObjectRevision: 0) }
    let reopened = try await ChemistryProjectStore(root: root).load(p.id)
    #expect(reopened.objects[0].revision == 1 && reopened.runs[0].result != nil)
    #expect(reopened.blocks[0].objectID == object.id)
    let xyz = try await service.export(p.id, objectID: object.id, format: "xyz")
    #expect(xyz.contains("O"))
}

@Test func authorizationAndCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChemistryProjectStore(root: root)
    let denied = try ChemistryService(store: store, authorize: { _ in throw ChemistryError.unavailable("Denied") })
    await #expect(throws: ChemistryError.unavailable("Denied")) { try await denied.create(title: "Denied") }
    #expect(try await store.list().isEmpty)
    let delayed = ConfiguredChemistryBackend(environmentID: "test.environment", engineVersion: "qualification", methods: ["delay"]) { _ in
        try await Task.sleep(for: .seconds(20)); return .string("late")
    }
    let service = try ChemistryService(store: store, backends: [NativeChemistryBackend(), delayed], authorize: { _ in })
    let p = try await service.create(title: "Cancel")
    let o = try await service.importObject(p.id, title: "Water", format: "xyz", source: waterXYZ)
    let r = try await service.start(p.id, objectID: o.id, method: "delay", environmentID: "test.environment")
    try await service.cancel(p.id, runID: r)
    let result = try await service.wait(p.id, runID: r)
    #expect(result.status == .cancelled && result.result == nil)
}
