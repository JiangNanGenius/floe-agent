import XCTest
import FloeCAD

@MainActor final class CADIdentityCodeChecks: XCTestCase {
    private func addBox(_ cad: FloeCADDocument) throws {
        let sketch = cad.execute(["op":"sketch.create","args":["name":"Identity cube"]])
        XCTAssertTrue(sketch.isOK,sketch.message ?? "")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:sketch.payload) as? [String:Any])
        let id = try XCTUnwrap(payload["sketchID"] as? String)
        for command: [String:Any] in [
            ["op":"sketch.addEntities","args":["sketchID":id,"entities":[["kind":"rect","min":[0,0],"max":[20,20]]]]],
            ["op":"feature.extrude","args":["sketchID":id,"seedPoint":[10,10],"distance":20]]
        ] { let outcome = cad.execute(command); XCTAssertTrue(outcome.isOK,outcome.message ?? "") }
    }
    func testBRepIdentitySurvivesSaveReloadAndMoveButChangesWithGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cad-simulation-identity-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("Before.floecad")
        let original = try await FloeCADDocument.create(at:url,name:"Identity source")
        try addBox(original)
        let before = try original.simulationGeometry()
        XCTAssertNotNil(before.bodies.first?.brep)
        let saved = await original.save(); XCTAssertNil(saved.error)
        XCTAssertEqual(try original.simulationGeometry().contentSHA256,before.contentSHA256)
        original.close()
        let reopened = try await FloeCADDocument.open(at:url)
        let restored = try reopened.simulationGeometry()
        XCTAssertEqual(restored.bodies.first?.id,before.bodies.first?.id)
        XCTAssertEqual(restored.bodies.first?.brep,before.bodies.first?.brep)
        XCTAssertEqual(restored.bodies.first?.faces.map(\.id).sorted(),before.bodies.first?.faces.map(\.id).sorted(),"Saved boundary selections must keep identity")
        XCTAssertEqual(restored.contentSHA256,before.contentSHA256,"Display cache restoration must not expire analysis")
        reopened.close()
        let movedURL = root.appendingPathComponent("After.floecad")
        try FileManager.default.moveItem(at:url,to:movedURL)
        let moved = try await FloeCADDocument.open(at:movedURL)
        XCTAssertEqual(try moved.simulationGeometry().contentSHA256,before.contentSHA256)
        try addBox(moved)
        let multiple = try moved.simulationGeometry()
        XCTAssertEqual(multiple.bodies.count,2)
        XCTAssertNotEqual(multiple.contentSHA256,before.contentSHA256)
        let savedMultiple = await moved.save(); XCTAssertNil(savedMultiple.error)
        moved.close()
        let restoredMultiple = try await FloeCADDocument.open(at:movedURL)
        let multipleAgain = try restoredMultiple.simulationGeometry()
        XCTAssertEqual(multipleAgain.contentSHA256,multiple.contentSHA256,"Surface fallback identity must also survive reload")
        XCTAssertEqual(multipleAgain.bodies.flatMap { $0.faces.map(\.id) }.sorted(),multiple.bodies.flatMap { $0.faces.map(\.id) }.sorted())
        restoredMultiple.close()
    }
}
