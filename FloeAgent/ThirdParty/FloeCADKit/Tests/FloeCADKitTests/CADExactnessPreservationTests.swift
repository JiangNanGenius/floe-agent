import XCTest
import Foundation
import Dispatch
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

// MARK: - M28: mesh boolean exactness, heavy input and cancellation

/// App-hosted source tests for the original M28 gap. They drive the REAL
/// `CADMeshService` over real document sessions (and a real OCCT B-rep handle
/// for the analytic fixtures); the cancellation case uses the actual
/// `withTaskCancellationHandler` path and a deterministic CSG checkpoint, not
/// a wall-clock sleep or source-string inspection.
@MainActor
final class CADMeshBooleanSafetyM28Tests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADMeshM28-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: workDir.appendingPathComponent("\(name).floecad"),
                                         name: name)
    }

    private func cube(center: Vector = Vector(0, 0, 0), size: Double = 10) -> Euclid.Mesh {
        .cube(center: center, size: Vector(size, size, size))
    }

    @discardableResult
    private func addMeshBody(_ document: FloeCADDocument,
                             name: String,
                             mesh: Euclid.Mesh,
                             transform: Transform3D = .identity) -> Body {
        let body = Body(name: name, transform: transform, primitive: nil,
                        euclidMesh: mesh, revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    @discardableResult
    private func addAnalyticBody(_ document: FloeCADDocument,
                                 name: String,
                                 mesh: Euclid.Mesh,
                                 transform: Transform3D = .identity) -> Body {
        var body = Body(name: name, transform: transform, primitive: nil,
                        euclidMesh: mesh, revision: 1)
        body.brep = OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10),
                                              placement: .identity)
        XCTAssertNotNil(body.brep, "the exactness fixture must carry a real OCCT B-rep")
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    private func booleanArgs(op: String, target: Body, tools: [Body],
                             forceMesh: Bool = false) -> [String: Any] {
        var args: [String: Any] = ["op": op,
                                   "target": target.id.raw.uuidString,
                                   "tools": tools.map { $0.id.raw.uuidString }]
        if forceMesh { args["forceMesh"] = true }
        return args
    }

    private func assertDocumentUnchanged(_ document: FloeCADDocument,
                                         bodies: [UUID], changeCount: Int,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), bodies,
                       "a refused/cancelled op must not add or remove bodies",
                       file: file, line: line)
        XCTAssertEqual(document.session.changeCount, changeCount,
                       "a refused/cancelled op must not add an undo entry",
                       file: file, line: line)
    }

    // MARK: Exactness

    func testM28BooleanRefusesPreciseInputUnlessForcedAndLabelsTheResultMesh() async throws {
        let document = try await makeDocument("M28Precise")
        defer { document.close() }
        let service = CADMeshService(document: document)
        let target = addAnalyticBody(document, name: "Precise Target", mesh: cube())
        let tool = addAnalyticBody(document, name: "Precise Tool",
                                   mesh: cube(center: Vector(5, 0, 0)))
        let args = booleanArgs(op: "union", target: target, tools: [tool])

        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let refused = service.handle(action: "boolean", args: args)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "brep_body_refused")
        XCTAssertEqual(refused["inputExactness"] as? String, "precise")
        XCTAssertEqual(refused["brepBodyCount"] as? Int, 2)
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)

        var previewArgs = args
        previewArgs["forceMesh"] = true
        previewArgs["preview"] = true
        let preview = service.handle(action: "boolean", args: previewArgs)
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["preview"] as? Bool, true)
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        XCTAssertEqual(preview["exactness"] as? String, "mesh")
        XCTAssertEqual(preview["inputExactness"] as? String, "precise")
        XCTAssertEqual(preview["brepDropped"] as? Bool, true)
        XCTAssertEqual(preview["droppedBRepBodyCount"] as? Int, 2)
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)

        var forcedArgs = args
        forcedArgs["forceMesh"] = true
        let forced = service.handle(action: "boolean", args: forcedArgs)
        XCTAssertEqual(forced["ok"] as? Bool, true, forced["message"] as? String ?? "")
        XCTAssertEqual(forced["exactness"] as? String, "mesh")
        XCTAssertEqual(forced["inputExactness"] as? String, "precise")
        XCTAssertEqual(forced["brepDropped"] as? Bool, true)
        XCTAssertEqual(forced["droppedBRepBodyCount"] as? Int, 2)
        XCTAssertEqual(document.session.document.bodies.count, 1)
        let output = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNil(output.brep, "a forced mesh result must not claim analytic exactness")
        XCTAssertNil(output.primitive)
        XCTAssertEqual(MeasureKit.volume(of: output), 1500, accuracy: 1e-3)

        // The single commit is one undo step and restores the exact inputs.
        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.count, 2)
        XCTAssertEqual(document.session.document.bodies.filter { $0.brep != nil }.count, 2,
                       "undo must restore both analytic B-reps")
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.count, 1)
    }

    func testM28BooleanMixedAndMeshInputsReportTheirTrueExactness() async throws {
        let mixedDocument = try await makeDocument("M28Mixed")
        defer { mixedDocument.close() }
        let mixedService = CADMeshService(document: mixedDocument)
        let analytic = addAnalyticBody(mixedDocument, name: "Mixed Target", mesh: cube())
        let meshTool = addMeshBody(mixedDocument, name: "Mixed Tool",
                                   mesh: cube(center: Vector(5, 0, 0)))
        let mixedArgs = booleanArgs(op: "union", target: analytic, tools: [meshTool])

        let mixedBodies = mixedDocument.session.document.bodies.map(\.id.raw)
        let mixedChangeCount = mixedDocument.session.changeCount
        let refused = mixedService.handle(action: "boolean", args: mixedArgs)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "brep_body_refused")
        XCTAssertEqual(refused["inputExactness"] as? String, "mixed")
        XCTAssertEqual(refused["brepBodyCount"] as? Int, 1)
        assertDocumentUnchanged(mixedDocument, bodies: mixedBodies,
                                changeCount: mixedChangeCount)

        var forcedArgs = mixedArgs
        forcedArgs["forceMesh"] = true
        let forced = mixedService.handle(action: "boolean", args: forcedArgs)
        XCTAssertEqual(forced["ok"] as? Bool, true, forced["message"] as? String ?? "")
        XCTAssertEqual(forced["exactness"] as? String, "mesh")
        XCTAssertEqual(forced["inputExactness"] as? String, "mixed")
        XCTAssertEqual(forced["brepDropped"] as? Bool, true)
        XCTAssertEqual(forced["droppedBRepBodyCount"] as? Int, 1)
        let mixedOutput = try XCTUnwrap(mixedDocument.session.document.bodies.first)
        XCTAssertNil(mixedOutput.brep)
        XCTAssertEqual(MeasureKit.volume(of: mixedOutput), 1500, accuracy: 1e-3)
        mixedDocument.session.undo()
        XCTAssertNotNil(mixedDocument.session.document.body(with: analytic.id)?.brep,
                        "undo must restore the analytic input of a mixed boolean")
        XCTAssertNil(mixedDocument.session.document.body(with: meshTool.id)?.brep)

        let meshDocument = try await makeDocument("M28MeshOnly")
        defer { meshDocument.close() }
        let meshService = CADMeshService(document: meshDocument)
        let first = addMeshBody(meshDocument, name: "Mesh A", mesh: cube())
        let second = addMeshBody(meshDocument, name: "Mesh B",
                                 mesh: cube(center: Vector(5, 0, 0)))
        let meshReply = meshService.handle(action: "boolean",
                                           args: booleanArgs(op: "union", target: first,
                                                             tools: [second]))
        XCTAssertEqual(meshReply["ok"] as? Bool, true, meshReply["message"] as? String ?? "")
        XCTAssertEqual(meshReply["exactness"] as? String, "mesh")
        XCTAssertEqual(meshReply["inputExactness"] as? String, "mesh")
        XCTAssertEqual(meshReply["brepDropped"] as? Bool, false)
        XCTAssertEqual(meshReply["droppedBRepBodyCount"] as? Int, 0)
        let meshOutput = try XCTUnwrap(meshDocument.session.document.bodies.first)
        XCTAssertNil(meshOutput.brep)
        XCTAssertEqual(MeasureKit.volume(of: meshOutput), 1500, accuracy: 1e-3)
    }

    func testM28ProposalPreviewCarriesMeshBooleanExactness() async throws {
        let document = try await makeDocument("M28ProposalPreview")
        defer { document.close() }
        let analytic = addAnalyticBody(document, name: "Preview Target", mesh: cube())
        let meshTool = addMeshBody(document, name: "Preview Tool",
                                   mesh: cube(center: Vector(5, 0, 0)))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded)

        let operation: [String: Any] = [
            "op": "mesh.boolean",
            "args": booleanArgs(op: "union", target: analytic, tools: [meshTool],
                                forceMesh: true),
        ]
        let operationData = try JSONSerialization.data(withJSONObject: operation)
        let operationJSON = try XCTUnwrap(String(data: operationData, encoding: .utf8))
        let proposal = try await CADProposalService().propose(
            document: document, operationJSON: operationJSON,
            summary: "M28 forced mesh union")
        XCTAssertFalse(proposal.preview.failed, proposal.preview.serviceMessage ?? "")
        XCTAssertEqual(proposal.preview.serviceOperation, "mesh.boolean")
        XCTAssertEqual(proposal.preview.serviceInputExactness, "mixed")
        XCTAssertEqual(proposal.preview.serviceExactness, "mesh")
        XCTAssertEqual(proposal.preview.serviceDroppedBRepBodyCount, 1)
        XCTAssertEqual(proposal.preview.bodyCountBefore, 2)
        XCTAssertEqual(proposal.preview.bodyCountAfter, 1)
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "a proposal preview must not mutate the live document")
    }

    // MARK: Heavy input and deadline refusal

    func testM28BooleanRefusesHeavyInputWithoutTouchingTheDocument() async throws {
        let document = try await makeDocument("M28Heavy")
        defer { document.close() }
        let service = CADMeshService(document: document)

        let positions: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]
        let normals = [SIMD3<Float>](repeating: [0, 0, 1], count: positions.count)
        var indices = [UInt32](repeating: 0, count: (CADMeshService.maxInputTriangles + 1) * 3)
        indices[0] = 0
        indices[1] = 1
        indices[2] = 2
        let heavy = Body(id: BodyID(), name: "Heavy",
                         transform: .identity,
                         render: RenderMesh(positions: positions, normals: normals,
                                            indices: indices),
                         edges: FeatureEdgeSet(segments: []),
                         revision: 1)
        XCTAssertEqual(heavy.render.triangleCount, CADMeshService.maxInputTriangles + 1,
                       "the fixture must exceed the real per-operation triangle cap")
        document.session.perform(AddBodyCommand(body: heavy, title: "Heavy fixture"))
        let tool = addMeshBody(document, name: "Light", mesh: cube())

        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let reply = service.handle(action: "boolean",
                                   args: ["op": "union",
                                          "target": heavy.id.raw.uuidString,
                                          "tools": [tool.id.raw.uuidString]])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "too_many_triangles")
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)
        XCTAssertEqual(document.session.document.body(with: heavy.id)?.render.triangleCount,
                       CADMeshService.maxInputTriangles + 1)
    }

    func testM28BooleanEmptyFailureLeavesNoHalfBodyOrUndoEntry() async throws {
        let document = try await makeDocument("M28EmptyFailure")
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Empty A", mesh: cube())
        let far = addMeshBody(document, name: "Empty B",
                              mesh: cube(center: Vector(100, 0, 0)))

        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count
        let reply = service.handle(action: "boolean",
                                   args: booleanArgs(op: "intersect", target: first,
                                                     tools: [far]))
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "empty_geometry")
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount)

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded)
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.session.document.bodies.count, 2,
                       "an empty boolean refuses, leaving both inputs intact")
    }

    func testM28BooleanDeadlineRefusalIsNotReportedAsCancellation() async throws {
        let document = try await makeDocument("M28Deadline")
        defer { document.close() }
        // The public limit stays 10 seconds. A zero limit deterministically
        // takes the REAL deadline branch without sleeping or measuring the
        // host, so the test cannot flake under load.
        let service = CADMeshService(document: document, wallClockLimitSeconds: 0)
        let first = addMeshBody(document, name: "Deadline A", mesh: cube())
        let second = addMeshBody(document, name: "Deadline B",
                                 mesh: cube(center: Vector(5, 0, 0)))

        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let reply = service.handle(action: "boolean",
                                   args: booleanArgs(op: "union", target: first,
                                                     tools: [second]))
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "limit_time")
        XCTAssertNotEqual(reply["error"] as? String, "cancelled")
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)
    }

    // MARK: Cancellation

    func testM28BooleanAlreadyCancelledCallerCommitsNothing() async throws {
        let document = try await makeDocument("M28AlreadyCancelled")
        defer { document.close() }
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Cancelled A", mesh: cube())
        let second = addMeshBody(document, name: "Cancelled B",
                                 mesh: cube(center: Vector(5, 0, 0)))
        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let targetID = first.id.raw.uuidString
        let toolID = second.id.raw.uuidString
        let box = M28ReplyBox()

        let task = Task { @MainActor () -> Void in
            box.value = await service.handleAsync(
                action: "boolean",
                args: ["op": "union", "target": targetID, "tools": [toolID]])
        }
        task.cancel()
        await task.value
        let reply = try XCTUnwrap(box.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "cancelled")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)
    }

    func testM28BooleanCancellationDuringEuclidCSGNeverCommitsPartialGeometry() async throws {
        let document = try await makeDocument("M28RunningCancel")
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Run A", mesh: cube())
        let second = addMeshBody(document, name: "Run B",
                                 mesh: cube(center: Vector(5, 0, 0)))
        // A dense overlapping sphere keeps the real Euclid BSP running long
        // enough to hit the CSG cancellation checkpoints deterministically.
        let tool = addMeshBody(document, name: "Run tool",
                               mesh: .sphere(radius: 6, slices: 64, stacks: 48))

        let successful = service.handle(action: "boolean",
                                        args: booleanArgs(op: "union", target: first,
                                                          tools: [second]))
        XCTAssertEqual(successful["ok"] as? Bool, true, successful["message"] as? String ?? "")
        let unionID = try XCTUnwrap(successful["outputBodyID"] as? String)
        let unionBody = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == unionID
        })
        XCTAssertEqual(MeasureKit.volume(of: unionBody), 1500, accuracy: 1e-3)
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "the successful union consumes its two inputs and keeps the sphere")

        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count
        let targetID = unionBody.id.raw.uuidString
        let toolID = tool.id.raw.uuidString
        let box = M28ReplyBox()
        let gate = M28CancellationGate(cancelAt: 4)
        let token = CADMeshCancellation(checkpoint: { gate.checkpoint() })

        let task = Task { @MainActor () -> Void in
            box.value = await service.handleAsync(
                action: "boolean",
                args: ["op": "union", "target": targetID, "tools": [toolID]],
                cancellation: token)
        }
        let canceller = Task.detached {
            // The gate counts only Euclid's Dispatch worker checks, so this
            // waits for the real CSG. Cancelling from this detached task is
            // the native cancel actor's path: Task.cancel flips the
            // handler-owned token while MainActor is still inside CSG.
            gate.waitForEntered()
            task.cancel()
            gate.recordHandlerCancelled(token.isCancelled)
            gate.release.signal()
        }
        await task.value
        await canceller.value

        XCTAssertGreaterThanOrEqual(gate.count, 4,
                                    "the cancellation must be observed inside Euclid CSG")
        XCTAssertTrue(gate.handlerCancelledToken,
                      "the cancellation handler must flip the token before Task.cancel returns")
        let reply = try XCTUnwrap(box.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "cancelled")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        assertDocumentUnchanged(document, bodies: bodies, changeCount: changeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount,
                       "a cancelled CSG must not add an undo entry")

        // The cancelled attempt stays out of history: undo still reaches the
        // earlier successful union, and redo reproduces only that body.
        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.count, 3)
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.count, 2)
        XCTAssertEqual(MeasureKit.volume(of: try XCTUnwrap(
            document.session.document.bodies.first { $0.id.raw.uuidString == unionID })), 1500, accuracy: 1e-3)

        // Saved and reopened geometry is exactly the two committed bodies; no
        // half body survived the cancellation.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded)
        XCTAssertFalse(document.hasUnsavedChanges)
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.session.document.bodies.count, 2)
        let reopenedVolumes = reopened.session.document.bodies.map { MeasureKit.volume(of: $0) }.sorted()
        XCTAssertEqual(reopenedVolumes.max() ?? 0, 1500, accuracy: 1e-2,
                       "the committed union survives save/reopen exactly")
        XCTAssertGreaterThan(reopenedVolumes.min() ?? 0, 0,
                             "the untouched sphere survives beside it")
    }
}

/// MainActor reply slot for the cancellation Task: `[String: Any]` is not
/// Sendable, so the child task returns Void and the test reads this slot on
/// MainActor after joining it.
@MainActor
private final class M28ReplyBox {
    var value: [String: Any]?
}

/// Deterministic CSG checkpoint used by the cancellation test. It counts ONLY
/// observations made from Euclid's Dispatch CSG worker threads (the service
/// boundary checks run on MainActor and are ignored); at the threshold it
/// blocks the worker until the detached canceller has requested task
/// cancellation, so no wall-clock timing decides the test.
nonisolated private final class M28CancellationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let cancelAt: Int
    private var observations = 0
    private var handlerObservedToken = false

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    func checkpoint() {
        guard !Thread.isMainThread else { return }
        lock.lock()
        observations += 1
        let shouldWait = observations == cancelAt
        lock.unlock()
        guard shouldWait else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }

    func waitForEntered() {
        _ = entered.wait(timeout: .now() + 10)
    }

    func recordHandlerCancelled(_ value: Bool) {
        lock.lock()
        handlerObservedToken = value
        lock.unlock()
    }

    var handlerCancelledToken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlerObservedToken
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}
