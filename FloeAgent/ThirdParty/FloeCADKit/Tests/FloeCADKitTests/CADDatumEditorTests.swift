import Foundation
import XCTest
@testable import FloeCAD

@MainActor
final class CADDatumEditorTests: XCTestCase {
    private func sourceFixture(asymmetricHole: Bool = false) async throws -> (directory: URL, document: FloeCADDocument, source: FeatureNode) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DatumFaceEntry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Editor.floecad"), name: "Editor")
        var entities: [SketchEntity] = [.rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 30))]
        if asymmetricHole { entities.append(.circle(id: UUID(), center: SIMD2(8, 8), radius: 3)) }
        let sketch = Sketch(name: "Source", plane: .ground, entities: entities)
        let source = FeatureNode(name: "Plate", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [entities[0].id],
                                holeEntityIDs: asymmetricHole ? [[entities[1].id]] : [], seedPoint: SIMD2(20, 15)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [BodyID()])
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)], title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return (directory, document, source)
    }

    func testActualFaceTapCreatesAssociativeZeroOffsetAndOneUndo() async throws {
        let f = try await sourceFixture(asymmetricHole: true)
        defer { f.document.close(); try? FileManager.default.removeItem(at: f.directory) }
        let model = f.document.viewModel()
        model.handle(.tap(ray: Ray(origin: SIMD3<Float>(SketchPlane.ground.toWorld(SIMD2(20, 15))) + SIMD3(0, 100, 0), direction: SIMD3(0, -1, 0))))
        let picked = try XCTUnwrap(model.toolContext?.datumSource)
        XCTAssertGreaterThan(picked.basePlane.origin.x, 20, "The exact centroid accounts for the asymmetric bore")
        let count = f.document.session.undoStack.undoCommands.count
        model.beginOffsetPlane()
        model.setOffsetPlaneDistance(0)
        model.commitTool()
        XCTAssertNil(model.errorMessage)
        let plane = try XCTUnwrap(f.document.session.document.planes.first)
        guard case let .offset(definition)? = plane.definition else { return XCTFail("Offset entry lost association") }
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(definition.distance.value, 0)
        XCTAssertEqual(plane.plane.origin.y, 10, accuracy: 1e-4)
        XCTAssertEqual(plane.plane.origin.x, picked.basePlane.origin.x, accuracy: 1e-4)
        XCTAssertEqual(plane.plane.origin.z, picked.basePlane.origin.z, accuracy: 1e-4)
        XCTAssertEqual(plane.plane.xAxis, picked.basePlane.xAxis)
        XCTAssertTrue(model.updateOffsetPlane(plane.id, expression: definition.distance.formula ?? "",
                                             expectedExpression: definition.distance.formula ?? ""))
        XCTAssertNil(model.errorMessage, "Unchanged Done dismisses without an error or undo entry")
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        model.undo()
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == plane.id })
        model.redo()
        XCTAssertEqual(f.document.session.document.planes.first?.id, plane.id)
        XCTAssertTrue(model.updateOffsetPlane(plane.id, expression: "5",
                                             expectedExpression: definition.distance.formula ?? ""))
        XCTAssertEqual(f.document.session.document.planes.first?.id, plane.id)
        XCTAssertEqual(try XCTUnwrap(f.document.session.document.planes.first).plane.origin.y, 15, accuracy: 1e-4)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(f.document.session.document.planes.first).plane.origin.y, 10, accuracy: 1e-4)
    }

    func testFaceSelectionCannotRefreshItsProofAfterAnInterveningEdit() async throws {
        let f = try await sourceFixture()
        defer { f.document.close(); try? FileManager.default.removeItem(at: f.directory) }
        let model = f.document.viewModel()
        model.handle(.tap(ray: Ray(origin: SIMD3<Float>(SketchPlane.ground.toWorld(SIMD2(20, 15))) + SIMD3(0, 100, 0), direction: SIMD3(0, -1, 0))))
        XCTAssertNotNil(model.toolContext?.datumSource)
        model.beginOffsetPlane()
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        let undoCount = f.document.session.undoStack.undoCommands.count
        model.commitTool()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(model.toolContext, "Refusal retains the current edit")
        XCTAssertEqual(f.document.session.document.planes.map(\.id), [sentinel.id])
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, undoCount)
        XCTAssertEqual(f.document.project.formatVersion, 1)
    }

    func testItemsDeleteRefusesAStaticPlaneStillSupportingASketch() async throws {
        let f = try await sourceFixture()
        defer { f.document.close(); try? FileManager.default.removeItem(at: f.directory) }
        let plane = ConstructionPlane(plane: .ground, size: 10)
        let sketch = Sketch(name: "Supported", plane: .ground, support: PlaneRef(source: .construction(plane.id)))
        f.document.session.perform(AddConstructionPlaneCommand(plane: plane))
        f.document.session.perform(AddSketchCommand(sketch: sketch))
        let count = f.document.session.undoStack.undoCommands.count
        let model = f.document.viewModel()
        model.deleteItem(.plane(plane.id))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(f.document.session.document.planes.first { $0.id == plane.id })
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertEqual(f.document.session.document.sketches.first { $0.id == sketch.id }?.support, sketch.support)
    }

    func testItemsSketchEntryRetainsSelectedIdentityForCoincidentPlanes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DatumEntry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Editor.floecad"), name: "Editor")
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = ConstructionPlane(plane: .ground, size: 100)
        let selected = ConstructionPlane(plane: .ground, size: 100)
        document.session.perform(AddConstructionPlaneCommand(plane: first))
        document.session.perform(AddConstructionPlaneCommand(plane: selected))
        let model = document.viewModel()
        model.selectItemPlane(selected.id)
        model.startSketch(tool: .line)
        let sketch = try XCTUnwrap(model.activeSketch)
        XCTAssertEqual(sketch.support, PlaneRef(source: .construction(selected.id)))
        XCTAssertNotEqual(sketch.support, PlaneRef(source: .construction(first.id)))
        XCTAssertEqual(sketch.plane, selected.plane)
        model.finishSketch()
        XCTAssertFalse(document.session.document.sketches.contains { $0.id == sketch.id })
        XCTAssertEqual(document.session.document.planes.count, 2)
    }

    func testExplicitSamePlaneRehostDetachesSupportAndUndoRestoresIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DatumEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Editor.floecad"), name: "Editor")
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let datum = ConstructionPlane(plane: .ground, size: 100)
        var sketch = Sketch(name: "Supported", plane: .ground)
        sketch.support = PlaneRef(source: .construction(datum.id))
        document.session.perform(AddConstructionPlaneCommand(plane: datum))
        document.session.perform(AddSketchCommand(sketch: sketch))
        let undoCount = document.session.undoStack.undoCommands.count
        let model = document.viewModel()
        model.changeSketchPlane(of: sketch.id, to: sketch.plane)
        XCTAssertNil(document.session.document.sketches.first?.support)
        XCTAssertEqual(document.session.document.sketches.first?.plane, sketch.plane)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount + 1)
        model.undo()
        XCTAssertEqual(document.session.document.sketches.first?.support, sketch.support)
        XCTAssertEqual(document.session.document.sketches.first?.entities, sketch.entities)
        model.redo()
        XCTAssertNil(document.session.document.sketches.first?.support)
        XCTAssertEqual(document.session.document.sketches.first?.plane, sketch.plane)
    }
}
