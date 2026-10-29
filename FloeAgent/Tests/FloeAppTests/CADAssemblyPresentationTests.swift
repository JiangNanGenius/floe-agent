#if canImport(UIKit) && canImport(RealityKit)
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyPresentationTests: XCTestCase {
    func testPresentationKeepsPlacedInstancesWhenTheirDefinitionIsHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADAssemblyPresentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("parts.floecad"), name: "Parts")
        defer { document.close() }
        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Part"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": ["sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]]]])
        _ = try run(["op": "feature.extrude", "args": ["sketchID": sketchID, "seedPoint": [20, 10], "distance": 10]])
        let source = try XCTUnwrap(document.session.document.bodies.first)
        let visibleID = UUID(), hiddenID = UUID()
        let assembly = CADAssembly(instances: [
            .init(id: visibleID, name: "Placed part", bodyID: source.id.raw,
                  transform: CADTransform(position: SIMD3(140, 20, 30))),
            .init(id: hiddenID, name: "Hidden instance", bodyID: source.id.raw, isHidden: true),
            .init(name: "Missing source", bodyID: UUID()),
        ])
        document.session.perform(SetAssemblyDataCommand(before: document.session.document.assemblyData, after: try assembly.encoded()))
        document.session.perform(SetItemVisibilityCommand(item: .body(source.id), isHidden: true))
        let snapshot = document.sceneSnapshot()
        let placed = try XCTUnwrap(snapshot.bodies.first { $0.id == visibleID })
        XCTAssertEqual(placed.sourceBodyID, source.id.raw)
        XCTAssertFalse(placed.isHidden)
        XCTAssertEqual(placed.transform[12], 140, accuracy: 1e-8)
        XCTAssertEqual(placed.transform[13], 20, accuracy: 1e-8)
        XCTAssertEqual(placed.transform[14], 30, accuracy: 1e-8)
        XCTAssertEqual(placed.mesh.positions, source.render.positions)
        XCTAssertFalse(snapshot.bodies.contains { $0.id == hiddenID })
        XCTAssertEqual(Set(snapshot.bodies.filter { !$0.isHidden }.map(\.id)),
                       Set(document.viewModel().scene.bodies.map { $0.id.raw }))
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.sceneSnapshot().bodies.first { $0.id == visibleID }?.sourceBodyID, source.id.raw)
    }
}
#endif
