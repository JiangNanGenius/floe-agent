import Foundation
import Testing
import FloeChemistryCore
@testable import FloeChemistryEngine

@Test func nativeStaticCoordinatesAndCoordinateFreeGraphsStayDistinct() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChemistryProjectStore(root: root)
    let service = try ChemistryService(store: store, authorize: { _ in })
    let project = try await service.create(title: "Native coordinates")
    let water = try await service.importObject(project.id, title: "Planar water", format: "xyz", source: waterXYZ)
    #expect(water.facts?["coordinateSetCount"]?.number == 0)
    #expect(!water.requires3DPreparation)
    let reopened = try await ChemistryProjectStore(root: root).load(project.id)
    #expect(!reopened.objects[0].requires3DPreparation)
    let runID = try await service.start(project.id, objectID: water.id, method: "uff.energy")
    #expect(try await service.wait(project.id, runID: runID).status == .succeeded)
    let graph = try await service.importObject(project.id, title: "Connectivity", format: "smi", source: "CCO")
    #expect(graph.requires3DPreparation)
    await #expect(throws: ChemistryError.requiresPrepared3DStructure) {
        try await service.start(project.id, objectID: graph.id, method: "uff.energy")
    }
}

@Test func nativeMOLDeclaredAs2DStillNeedsPreparation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let native = NativeChemistryBackend()
    let result = try await native.evaluate(.init(operation: "export", format: "xyz", data: waterXYZ,
                                                options: .object(["outputFormat": .string("mol")])))
    var lines = try #require(result["text"]?.string).components(separatedBy: "\n")
    lines[1] = "  synthetic2D"
    let service = try ChemistryService(store: ChemistryProjectStore(root: root), authorize: { _ in })
    let project = try await service.create(title: "2D drawing")
    let drawing = try await service.importObject(project.id, title: "Drawing", format: "mol", source: lines.joined(separator: "\n"))
    #expect(drawing.requires3DPreparation)
    await #expect(throws: ChemistryError.requiresPrepared3DStructure) {
        try await service.start(project.id, objectID: drawing.id, method: "uff.energy")
    }
}
