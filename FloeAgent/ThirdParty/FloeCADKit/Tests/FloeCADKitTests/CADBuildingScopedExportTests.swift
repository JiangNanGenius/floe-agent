// SPDX-License-Identifier: MPL-2.0
import XCTest
import CoreGraphics
@testable import FloeCAD

@MainActor
final class CADBuildingScopedExportTests: XCTestCase {
    func testTwoFloorGeometryRemainsIndependentAcrossSolidAndPlanExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScopedBuilding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await FloeCADDocument.create(at: root.appendingPathComponent("Source.floecad"), name: "Two floors")
        defer { source.close() }
        var model = CADBuildingDocument(name: "Two floors")
        let ground = CADBuildingStorey(name: "Ground"), upper = CADBuildingStorey(name: "Upper", elevationMM: 3400)
        model.storeys = [ground, upper]
        let wall = CADBuildingElement(storeyID: ground.id, kind: .wall, name: "Cut wall", a: [0,0], b: [6000,0])
        let door = CADBuildingElement(storeyID: ground.id, kind: .door, name: "Ground door", a: wall.a, b: wall.b,
                                      thicknessMM: 35, heightMM: 2100, hostID: wall.id, offsetMM: 700, widthMM: 900)
        let beam = CADBuildingElement(storeyID: upper.id, kind: .beam, name: "Upper beam", a: [10000,500], b: [13000,500],
                                      thicknessMM: 200, heightMM: 400)
        let duct = CADBuildingElement(storeyID: upper.id, kind: .duct, name: "Upper duct", a: [14000,1000], b: [16000,1000],
                                      thicknessMM: 300, heightMM: 400)
        model.elements = [wall, door, beam, duct]
        try source.setBuilding(model)
        let saved = await source.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let undoCount = source.session.undoStack.undoCommands.count
        XCTAssertEqual(source.summary().drawingPageCount, 0)
        XCTAssertEqual(try source.buildingExportSelection(.storey(upper.id)).elements.map(\.id), [beam.id, duct.id])
        XCTAssertEqual(try source.buildingExportSelection(.discipline(.structure)).bodyIDs, [beam.bodyID])
        XCTAssertEqual(try source.buildingExportSelection(.discipline(.mep)).bodyIDs, [duct.bodyID])
        XCTAssertThrowsError(try source.buildingExportSelection(.elements([UUID()])))
        for (element, context) in [(wall, door), (door, wall)] {
            let copy = try await source.createScopedBuildingExportDocument(.elements([element.id]), at: root.appendingPathComponent(element.name + ".floecad"))
            defer { copy.close() }
            let subset = try XCTUnwrap(copy.building())
            XCTAssertEqual(subset.elements.map(\.id), [element.id])
            XCTAssertEqual(subset.exportContext?.references.map(\.id), [context.id])
            XCTAssertEqual(copy.session.document.bodies.map(\.id.raw), [element.bodyID])
            let original = try XCTUnwrap(source.session.document.body(with: .init(raw: element.bodyID)))
            let body = try XCTUnwrap(copy.session.document.bodies.first)
            XCTAssertEqual(body.transform, original.transform)
            let volume = OCCTKernel.volume(try XCTUnwrap(body.brep))
            let expected: Double = element.kind == .wall ? 6000*200*3000 - 900*200*2100 : 899.5*35*2099.5
            XCTAssertEqual(volume, expected, accuracy: 1)
            XCTAssertEqual(volume, OCCTKernel.volume(try XCTUnwrap(original.brep)), accuracy: 1)
            let input = try copy.buildingIFCInterchangeInput(.wholeProject)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
            let mesh = try XCTUnwrap(json["geometry"] as? [[String: Any]])
            XCTAssertEqual(mesh.compactMap { $0["bodyID"] as? String }, [element.bodyID.uuidString])
        }
        let plan = try await source.createScopedBuildingPlan(.storey(upper.id), at: root.appendingPathComponent("Upper.floecad"))
        defer { plan.close() }
        XCTAssertTrue(plan.session.document.bodies.isEmpty)
        XCTAssertEqual(Set(plan.session.document.sketches.map(\.id.raw)), [duct.id, beam.id])
        let projected = try XCTUnwrap(plan.session.document.sketches.first { $0.id.raw == beam.id })
        XCTAssertEqual(projected.plane, .offsetGround(y: 3400))
        var points: [SIMD2<Double>] = []
        for entity in projected.entities {
            guard case let .line(_, a, b) = entity else { return XCTFail("Expected editable projected edges") }
            points += [a, b]
        }
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()), 10000, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).max()), 13000, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).min()), 400, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).max()), 600, accuracy: 1e-6)
        let whole = try await source.createScopedBuildingPlan(.wholeProject, at: root.appendingPathComponent("Both.floecad"))
        defer { whole.close() }
        let drawing = try whole.buildingPlanInterchange(format: "pdf", storeys: model.storeys)
        let provider = try XCTUnwrap(CGDataProvider(data: drawing as CFData))
        XCTAssertEqual(CGPDFDocument(provider)?.numberOfPages, 2)
        let dxf = String(decoding: try plan.buildingPlanInterchange(format: "dxf", storeys: [upper]), as: UTF8.self)
        XCTAssertTrue(dxf.contains("\n30\n3400.0\n"))
        XCTAssertTrue(dxf.contains("Upper-Upperbeam"))
        XCTAssertFalse(dxf.contains("Cutwall"))
        let disk = await FloeCADDocument.storedIdentity(at: source.url)
        XCTAssertEqual(disk?.contentSHA256, saved.contentSHA256)
        XCTAssertEqual(disk?.revision, saved.revision)
        XCTAssertEqual(source.session.undoStack.undoCommands.count, undoCount)
        XCTAssertEqual(try source.building(), model)
    }
}
