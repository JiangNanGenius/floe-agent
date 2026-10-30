import XCTest
import simd
import Euclid
@testable import FloeCAD

@MainActor
final class CADExactnessPreservationTests: XCTestCase {
    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let result = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(result.isOK, "\(result.message ?? "") — \(json)", file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
    }

    private func makePlate(_ document: FloeCADDocument) throws -> Body {
        let sketch = try XCTUnwrap(try run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[50,30],"distance":10}}
        """)
        let plate = try XCTUnwrap(document.session.document.bodies.first)
        let hole = try XCTUnwrap(try run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(hole)","entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(hole)","seedPoint":[50,30],"distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plate.id.raw.uuidString)"]}}
        """)
        return try XCTUnwrap(document.session.document.bodies.first)
    }

    private func topFace(_ body: Body) throws -> PlanarFace {
        for triangle in 0..<body.render.triangleCount {
            if let face = FaceTopology.planarFace(in: body.render, seedTriangle: triangle), face.normal.y > 0.99 {
                return face
            }
        }
        throw NSError(domain: "missingTopFace", code: 1)
    }

    private func select(_ body: Body, face: PlanarFace, on model: EditorViewModel, distance: Double = 2) {
        let t = body.transform
        let plane = SketchPlane(origin: t.applying(to: face.origin),
                                xAxis: t.rotation.act(face.basisX), yAxis: t.rotation.act(face.basisY))
        model.selection = [body.id]
        model.mode = .faceSelected(body.id)
        model.toolContext = EditorViewModel.ToolContext(
            profile: Profile(loop: face.outline.map { $0 * t.scale }, kind: .polygonal, sourceEntityIDs: []),
            holes: face.holes.map { Profile(loop: $0.map { $0 * t.scale }, kind: .polygonal, sourceEntityIDs: []) },
            plane: plane, sketchID: nil, sourceBody: body.id, faceTriangles: face.triangles,
            kind: .extrude(distance: distance), preview: body)
    }

    private func assertSTEP(_ bodies: [Body], volume: Double, count: Int = 1,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        guard case let .success(data, skipped) = STEPKit.export(bodies: bodies) else {
            return XCTFail("STEP must export every exact result", file: file, line: line)
        }
        XCTAssertTrue(skipped.isEmpty, file: file, line: line)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("CYLINDRICAL_SURFACE"), file: file, line: line)
        let solids = STEPKit.solids(from: data)
        XCTAssertEqual(solids.count, count, file: file, line: line)
        XCTAssertEqual(solids.reduce(0) { $0 + OCCTKernel.volume($1) }, volume, accuracy: 1e-3, file: file, line: line)
    }

    func testAgentPushPullPreservesHoleAndRejectsUnsupportedEditsWithoutMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("plate.floecad"), name: "Exact")
        defer { document.close() }
        let body = try makePlate(document)
        let brep = try XCTUnwrap(body.brep)
        let index = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 }?.index)
        _ = try run(document, """
        {"op":"feature.pushPull","args":{"bodyID":"\(body.id.raw.uuidString)","face":[\(index)],"distance":2}}
        """)
        let pushed = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNotNil(pushed.brep)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(pushed.brep)), (6000 - 25 * .pi) * 12, accuracy: 1e-3)
        try assertSTEP([pushed], volume: (6000 - 25 * .pi) * 12)
        let save = await document.save()
        XCTAssertTrue(save.succeeded)
        XCTAssertFalse(document.hasUnsavedChanges)
        let bytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(pushed.brep)))
        let history = document.session.document.features.nodes.count
        let undo = document.session.undoStack.undoCommands.count
        let currentIndex = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(pushed.brep)).first { $0.normal.y > 0.99 }?.index)
        for operation in [
            "\"op\":\"feature.scaleFace\",\"factor\":1.2",
            "\"op\":\"feature.rotateFace\",\"angleDegrees\":10",
            "\"op\":\"feature.moveFace\",\"delta\":[1,0,0]"
        ] {
            let parts = operation.components(separatedBy: ",")
            let op = parts[0]
            let args = parts.dropFirst().joined(separator: ",")
            let response = document.executeJSON(Data("{\(op),\"args\":{\"bodyID\":\"\(pushed.id.raw.uuidString)\",\"face\":[\(currentIndex)],\(args)}}".utf8))
            XCTAssertFalse(response.isOK)
            XCTAssertEqual(response.errorCode, "exact_edit_unsupported")
            XCTAssertEqual(document.session.document.features.nodes.count, history)
            XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
            XCTAssertFalse(document.hasUnsavedChanges)
            XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies.first?.brep)), bytes)
        }
        let savedAgain = await document.save()
        XCTAssertTrue(savedAgain.succeeded)
        document.session.undo()
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(document.session.document.bodies.first?.brep)), (6000 - 25 * .pi) * 10, accuracy: 1e-3)
        document.session.redo()
        try assertSTEP(document.session.document.bodies, volume: (6000 - 25 * .pi) * 12)
    }

    func testKernelRefusedPushPullRestoresExactBodyHistoryAndUndoWithFreshGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("refused.floecad"), name: "Refused")
        defer { document.close() }
        let plate = try makePlate(document)
        let index = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(plate.brep)).first { $0.normal.y > 0.99 }?.index)
        // Retain a real pre-existing redo entry. A failed rebuild must neither
        // consume this successful edit nor make the rejected feature redoable.
        _ = try run(document, """
        {"op":"feature.pushPull","args":{"bodyID":"\(plate.id.raw.uuidString)","face":[\(index)],"distance":2}}
        """)
        document.session.undo()
        let savedBefore = await document.save()
        XCTAssertTrue(savedBefore.succeeded)
        XCTAssertFalse(document.hasUnsavedChanges)
        let before = try XCTUnwrap(document.session.document.body(with: plate.id))
        let bytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(before.brep)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let history = try encoder.encode(document.session.document.features)
        let featureCount = document.session.document.features.nodes.count
        let undoTitles = document.session.undoStack.undoCommands.map(\.title)
        let redoTitles = document.session.undoStack.redoCommands.map(\.title)
        XCTAssertFalse(redoTitles.isEmpty)
        let generation = document.session.changeCount
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(before.brep)).first { $0.normal.y > 0.99 }?.index)

        // This is a supported planar operation, not an unsupported-operation
        // preflight: the exact cutter reaches OCCT and removes the entire solid.
        let response = document.executeJSON(Data("""
        {"op":"feature.pushPull","args":{"bodyID":"\(before.id.raw.uuidString)","face":[\(face)],"distance":-100}}
        """.utf8))
        XCTAssertFalse(response.isOK)
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(response.errorCode, "feature_failed")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
        XCTAssertEqual(payload["undoSteps"] as? Int, 0)
        let failedFeature = try XCTUnwrap(payload["featureID"] as? String)
        let errors = try XCTUnwrap(payload["evalErrors"] as? [String: String])
        XCTAssertNotNil(errors[failedFeature], "the rejected kernel evaluation must retain its own diagnostic")

        let restored = try XCTUnwrap(document.session.document.body(with: before.id))
        XCTAssertEqual(document.session.document.bodies.count, 1)
        XCTAssertTrue(restored.brep === before.brep)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(restored.brep)), bytes)
        XCTAssertEqual(restored.transform, before.transform)
        XCTAssertEqual(restored.meshRevision, before.meshRevision)
        XCTAssertEqual(restored.render.positions, before.render.positions)
        XCTAssertEqual(restored.render.indices, before.render.indices)
        XCTAssertEqual(try encoder.encode(document.session.document.features), history)
        XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), undoTitles)
        XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), redoTitles)
        XCTAssertGreaterThan(document.session.changeCount, generation,
                             "rollback must fence query generations rather than revive old references")
        try assertSTEP([restored], volume: (6000 - 25 * Double.pi) * 10)
        let savedAfter = await document.save()
        XCTAssertTrue(savedAfter.succeeded, "kernel refusal must leave an exact document that can still save")
        XCTAssertFalse(document.hasUnsavedChanges)

        document.session.redo()
        XCTAssertEqual(document.session.document.features.nodes.count, featureCount + 1)
        try assertSTEP(document.session.document.bodies, volume: (6000 - 25 * Double.pi) * 12)
        XCTAssertFalse(document.session.undoStack.canRedo, "only the pre-existing successful edit may be redone")
    }

    func testTransformedUIPushPullNoOpCancelAndExactSplit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("placed.floecad"), name: "Placed")
        defer { document.close() }
        let plate = try makePlate(document)
        // Import a real STEP to exercise a seed body, with no source feature
        // graph to mask UI geometry replacement on the next rebuild.
        guard case let .success(step, _) = STEPKit.export(bodies: [plate]) else { return XCTFail("STEP failed") }
        let handle = try XCTUnwrap(STEPKit.solids(from: step).first)
        var placed = Body(name: "Placed plate", euclidMesh: plate.euclidMesh(), revision: 0)
        XCTAssertTrue(placed.adoptBRep(handle))
        placed.transform = Transform3D(translation: SIMD3(70, -20, 45),
                                      rotation: simd_quatd(angle: .pi / 3, axis: simd_normalize(SIMD3(1, 2, 3))), scale: 1.5)
        document.session.perform(AddBodyCommand(body: placed, title: "Import STEP"))
        let model = document.viewModel()
        let face = try topFace(placed)
        select(placed, face: face, on: model)
        model.beginMove()
        model.updateMove(delta: SIMD3(0.2, 0.3, 0.4))
        model.cancelTool()
        let restored = try XCTUnwrap(document.session.document.body(with: placed.id))
        XCTAssertTrue(restored.brep === placed.brep)
        XCTAssertEqual(restored.transform, placed.transform)
        select(restored, face: face, on: model)
        model.beginMove()
        model.updateMove(delta: .zero)
        model.endMove()
        XCTAssertTrue(document.session.document.body(with: placed.id)?.brep === placed.brep)
        select(restored, face: face, on: model)
        model.beginMove()
        model.updateMove(delta: SIMD3<Float>(placed.transform.rotation.act(SIMD3(0, 3, 0))))
        model.endMove()
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(document.session.document.body(with: placed.id)?.brep)),
                       (6000 - 25 * Double.pi) * 12, accuracy: 1e-3)
        document.session.undo()
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(document.session.document.body(with: placed.id)?.brep)),
                       (6000 - 25 * Double.pi) * 10, accuracy: 1e-3)
        select(restored, face: face, on: model, distance: 3)
        model.commitTool()
        let pushed = try XCTUnwrap(document.session.document.body(with: placed.id))
        XCTAssertNotNil(pushed.brep)
        XCTAssertEqual(pushed.transform, placed.transform)
        let localVolume = (6000 - 25 * Double.pi) * 12
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(pushed.brep)), localVolume, accuracy: 1e-3)
        try assertSTEP([pushed], volume: localVolume * pow(1.5, 3))
        let splitPlane = SketchPlane(origin: placed.transform.applying(to: SIMD3(50, 6, -30)),
            xAxis: placed.transform.rotation.act(SIMD3(1, 0, 0)),
            yAxis: placed.transform.rotation.act(SIMD3(0, 0, -1)))
        let halves = try KernelOps.exactSplit(body: pushed, plane: splitPlane)
        XCTAssertNotNil(halves.0.brep)
        XCTAssertNotNil(halves.1.brep)
        try assertSTEP([halves.0, halves.1], volume: localVolume * pow(1.5, 3), count: 2)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(halves.0.brep)), localVolume * pow(1.5, 3) / 2, accuracy: 1e-3)
    }

    func testMeshOnlyFaceEditingRemainsAvailable() {
        let mesh = Euclid.Mesh.primitive(.box(width: 20, depth: 30, height: 10))
        let body = Body(name: "Mesh", euclidMesh: mesh, revision: 0)
        let face = (0..<body.render.triangleCount).compactMap {
            FaceTopology.planarFace(in: body.render, seedTriangle: $0)
        }.first!
        XCTAssertNil(body.brep)
        XCTAssertFalse(KernelOps.moveFace(mesh: mesh, face: face, delta: SIMD3(1, 0, 0)).polygons.isEmpty)
        XCTAssertFalse(KernelOps.scaleFace(mesh: mesh, face: face, factor: 0.8).polygons.isEmpty)
        XCTAssertFalse(KernelOps.rotateFace(mesh: mesh, face: face, angle: 0.1, axis: SIMD3(0, 1, 0)).polygons.isEmpty)
    }
}
