import XCTest
import Foundation
import Dispatch
import Darwin
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

/// Deterministic CSG checkpoint used by the cancellation test. Production
/// invokes this ONLY through `CADMeshCancellation.kernelIsCancelled`, the
/// callback handed to Euclid CSG; preparation and pre-commit guards use the
/// side-effect-free getter, so the non-main predicate is a real kernel witness
/// rather than service bookkeeping. At the threshold it blocks the worker until
/// the detached canceller has requested task cancellation, so no wall-clock
/// timing decides the test.
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

// MARK: - X08: off-main heavy mesh work and source-fenced commit

/// App-hosted source tests for the original X08 boundary. They drive the REAL
/// `CADMeshService` over real documents and real Euclid CSG/welding, hold a
/// deterministic scheduling gate around that real compute, and measure the
/// MainActor heartbeat while the worker is genuinely in flight. A fault gate
/// makes timing deterministic; it never stubs result geometry.
@MainActor
final class CADMeshBackgroundX08Tests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADMeshX08-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CADMeshService.testHeavyComputeProbe = nil
        CADMeshService.testBeforeCommitProbe = nil
        CADMeshService.testComputeObservation = nil
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
    private func addRenderBody(_ document: FloeCADDocument,
                               name: String,
                               render: RenderMesh,
                               transform: Transform3D = .identity) -> Body {
        // The edges payload is intentionally empty: FeatureEdgeExtractor would
        // itself subscript a malformed index buffer before the service sees it.
        let body = Body(id: BodyID(), name: name, transform: transform,
                        render: render, edges: FeatureEdgeSet(segments: []), revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    private func booleanArgs(op: String, target: Body, tools: [Body]) -> [String: Any] {
        ["op": op,
         "target": target.id.raw.uuidString,
         "tools": tools.map { $0.id.raw.uuidString }]
    }

    private func nearLimitBooleanDocument() async throws -> (FloeCADDocument, [Body], Int) {
        let document = try await makeDocument("X08NearLimitBoolean")
        var bodies: [Body] = []
        // 16 x ~29.7k triangles is just under the real 500k / 16-body caps.
        for index in 0..<16 {
            let mesh = Euclid.Mesh.sphere(radius: 6, slices: 150, stacks: 100)
            var transform = Transform3D.identity
            transform.translation = SIMD3(Double(index % 4) * 2, Double(index / 4) * 2, 0)
            bodies.append(addMeshBody(document, name: "Near \(index + 1)",
                                      mesh: mesh, transform: transform))
        }
        let total = bodies.reduce(0) { $0 + $1.render.triangleCount }
        print("X08 near-limit boolean input triangles: \(total) across \(bodies.count) bodies")
        XCTAssertLessThanOrEqual(total, CADMeshService.maxInputTriangles)
        XCTAssertGreaterThanOrEqual(total, 450_000,
                                    "the near-limit fixture must exercise the real upper bound")
        XCTAssertEqual(bodies.count, CADMeshService.maxInputBodies)
        guard total <= CADMeshService.maxInputTriangles else {
            XCTFail("near-limit fixture produced \(total) triangles, above the service cap")
            throw NSError(domain: "X08Fixture", code: 1)
        }
        return (document, bodies, total)
    }

    private func nearLimitGridMesh(nx: Int, ny: Int) -> RenderMesh {
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity((nx + 1) * (ny + 1))
        for y in 0...ny {
            for x in 0...nx {
                positions.append(SIMD3(Float(x), Float(y), 0))
            }
        }
        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(positions.count)
        for _ in positions { normals.append(SIMD3(0, 0, 1)) }
        var indices = [UInt32]()
        indices.reserveCapacity(nx * ny * 6)
        let row = UInt32(nx + 1)
        for y in 0..<ny {
            for x in 0..<nx {
                let i = UInt32(y) * row + UInt32(x)
                indices.append(contentsOf: [i, i + 1, i + row,
                                            i + 1, i + row + 1, i + row])
            }
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: Actual Euclid boolean, heartbeat, undo/save/reopen

    func testX08BooleanRunsOffMainAndKeepsMainActorResponsive() async throws {
        let document = try await makeDocument("X08Boolean")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Target", mesh: cube())
        let second = addMeshBody(document, name: "Dense tool",
                                 mesh: .sphere(radius: 6, slices: 48, stacks: 32))
        let bodiesBefore = document.session.document.bodies.map(\.id.raw)
        let changeCountBefore = document.session.changeCount
        let undoCountBefore = document.session.undoStack.undoCommands.count

        let probe = X08ComputeProbe(hold: 0.8)
        CADMeshService.testHeavyComputeProbe = { probe.checkpoint(action: $0, triangles: $1) }
        let observations = X08ComputeObservationBox()
        CADMeshService.testComputeObservation = { observations.record($0) }
        let memory = X08ProcessFootprintSampler()
        memory.start()
        let heartbeat = X08Heartbeat()
        heartbeat.start()
        let box = M28ReplyBox()
        let requestStart = ContinuousClock.now
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: first, tools: [second]))
        }
        await probe.waitEntered()
        let gateStart = ContinuousClock.now
        try await Task.sleep(nanoseconds: 800_000_000)
        probe.releaseGate()
        let gateObservedSeconds = seconds(gateStart.duration(to: .now))
        await task.value
        let requestSeconds = seconds(requestStart.duration(to: .now))
        heartbeat.stop()
        let memorySnapshot = memory.stop()

        let reply = try XCTUnwrap(box.value)
        let observation = observations.all.first
        var metrics: [String: Any] = [
            "inputTriangles": observation?.inputTriangles ?? probe.triangles,
            "inputBodies": observation?.inputBodies ?? 2,
            "computeRanOnMain": observation?.ranOnMainThread ?? probe.ranOnMain,
            "probeRanOnMain": probe.ranOnMain,
            "mainActorMaxGapSeconds": heartbeat.maxGap,
            "mainActorTicks": heartbeat.ticks,
            "computeSeconds": observation?.computeSeconds ?? -1,
            "computeOutcome": observation?.outcome ?? "unobserved",
            "requestSeconds": requestSeconds,
            "probeGateConfiguredSeconds": probe.configuredHoldSeconds,
            "probeGateObservedSeconds": gateObservedSeconds,
            "memory": memoryMetrics(memorySnapshot),
            "changeCountDelta": document.session.changeCount - changeCountBefore,
            "undoDelta": document.session.undoStack.undoCommands.count - undoCountBefore,
        ]
        metrics.merge(replyMetrics(reply)) { _, new in new }
        attachX08Metrics("boolean-responsive", fields: metrics)

        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        XCTAssertFalse(probe.ranOnMain, "the real Euclid boolean must run off the MainActor")
        XCTAssertEqual(probe.action, "boolean")
        XCTAssertGreaterThan(probe.triangles, 1_000)
        print("X08 boolean input triangles: \(probe.triangles)")
        XCTAssertGreaterThanOrEqual(heartbeat.ticks, 20,
                                    "the MainActor heartbeat must actually run during compute")
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "the MainActor was blocked for \(heartbeat.maxGap)s during off-main compute")
        XCTAssertEqual(document.session.document.bodies.count, 1)
        XCTAssertNotEqual(document.session.document.bodies.map(\.id.raw), bodiesBefore)

        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), bodiesBefore)
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.count, 1)

        let committedVolume = MeasureKit.volume(of: try XCTUnwrap(
            document.session.document.bodies.first))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.session.document.bodies.count, 1,
                       "the single committed boolean survives save/reopen")
        XCTAssertEqual(MeasureKit.volume(of: try XCTUnwrap(
            reopened.session.document.bodies.first)), committedVolume, accuracy: 1e-2)
    }

    // MARK: Near the real triangle/body cap

    func testX08NearLimitBooleanEitherCommitsOnceOrRefusesAtDeadlineWithoutBlockingMain() async throws {
        let (document, bodies, totalTriangles) = try await nearLimitBooleanDocument()
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let target = bodies[0]
        let tools = Array(bodies.dropFirst())
        let changeCountBefore = document.session.changeCount
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let undoCountBefore = document.session.undoStack.undoCommands.count

        let probe = X08ComputeProbe(hold: 0.2)
        CADMeshService.testHeavyComputeProbe = { probe.checkpoint(action: $0, triangles: $1) }
        let observations = X08ComputeObservationBox()
        CADMeshService.testComputeObservation = { observations.record($0) }
        let memory = X08ProcessFootprintSampler()
        memory.start()
        let heartbeat = X08Heartbeat()
        heartbeat.start()
        let box = M28ReplyBox()
        let requestStart = ContinuousClock.now
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: target, tools: tools))
        }
        await probe.waitEntered()
        let gateStart = ContinuousClock.now
        try await Task.sleep(nanoseconds: 200_000_000)
        probe.releaseGate()
        let gateObservedSeconds = seconds(gateStart.duration(to: .now))
        await task.value
        let requestSeconds = seconds(requestStart.duration(to: .now))
        heartbeat.stop()
        let memorySnapshot = memory.stop()

        let reply = try XCTUnwrap(box.value)
        let observation = observations.all.first
        var metrics: [String: Any] = [
            "inputTriangles": observation?.inputTriangles ?? probe.triangles,
            "inputBodies": bodies.count,
            "fixtureTriangles": totalTriangles,
            "computeRanOnMain": observation?.ranOnMainThread ?? probe.ranOnMain,
            "probeRanOnMain": probe.ranOnMain,
            "mainActorMaxGapSeconds": heartbeat.maxGap,
            "mainActorTicks": heartbeat.ticks,
            "computeSeconds": observation?.computeSeconds ?? -1,
            "computeOutcome": observation?.outcome ?? "unobserved",
            "requestSeconds": requestSeconds,
            "probeGateConfiguredSeconds": probe.configuredHoldSeconds,
            "probeGateObservedSeconds": gateObservedSeconds,
            "memory": memoryMetrics(memorySnapshot),
            "changeCountDelta": document.session.changeCount - changeCountBefore,
            "undoDelta": document.session.undoStack.undoCommands.count - undoCountBefore,
        ]
        metrics.merge(replyMetrics(reply)) { _, new in new }
        attachX08Metrics("near-cap-boolean", fields: metrics)

        XCTAssertFalse(probe.ranOnMain)
        XCTAssertEqual(probe.triangles, totalTriangles)
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "near-limit boolean blocked the MainActor for \(heartbeat.maxGap)s")
        if reply["ok"] as? Bool == true {
            XCTAssertEqual(document.session.document.bodies.count, 1)
            XCTAssertEqual(document.session.changeCount, changeCountBefore + 1)
            document.session.undo()
            XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore)
            document.session.redo()
            XCTAssertEqual(document.session.document.bodies.count, 1)
        } else {
            XCTAssertEqual(reply["error"] as? String, "limit_time", "\(reply)")
            XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore)
            XCTAssertEqual(document.session.changeCount, changeCountBefore,
                           "a deadline refusal must not add an undo entry")
        }
    }

    func testX08NearLimitSimplificationRunsOffMainAndKeepsMainActorResponsive() async throws {
        let document = try await makeDocument("X08NearLimitSimplify")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let render = nearLimitGridMesh(nx: 400, ny: 600)
        print("X08 simplification input triangles: \(render.triangleCount)")
        XCTAssertEqual(render.triangleCount, 480_000)
        let body = addRenderBody(document, name: "Grid", render: render)
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let changeCountBefore = document.session.changeCount
        let undoCountBefore = document.session.undoStack.undoCommands.count

        let probe = X08ComputeProbe(hold: 0.8)
        CADMeshService.testHeavyComputeProbe = { probe.checkpoint(action: $0, triangles: $1) }
        let observations = X08ComputeObservationBox()
        CADMeshService.testComputeObservation = { observations.record($0) }
        let memory = X08ProcessFootprintSampler()
        memory.start()
        let heartbeat = X08Heartbeat()
        heartbeat.start()
        let box = M28ReplyBox()
        let requestStart = ContinuousClock.now
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "simplify",
                args: ["bodyID": body.id.raw.uuidString, "tolerance": 1.5])
        }
        await probe.waitEntered()
        let gateStart = ContinuousClock.now
        try await Task.sleep(nanoseconds: 800_000_000)
        probe.releaseGate()
        let gateObservedSeconds = seconds(gateStart.duration(to: .now))
        await task.value
        let requestSeconds = seconds(requestStart.duration(to: .now))
        heartbeat.stop()
        let memorySnapshot = memory.stop()

        let reply = try XCTUnwrap(box.value)
        let observation = observations.all.first
        var metrics: [String: Any] = [
            "inputTriangles": observation?.inputTriangles ?? probe.triangles,
            "inputBodies": observation?.inputBodies ?? 1,
            "computeRanOnMain": observation?.ranOnMainThread ?? probe.ranOnMain,
            "probeRanOnMain": probe.ranOnMain,
            "mainActorMaxGapSeconds": heartbeat.maxGap,
            "mainActorTicks": heartbeat.ticks,
            "computeSeconds": observation?.computeSeconds ?? -1,
            "computeOutcome": observation?.outcome ?? "unobserved",
            "requestSeconds": requestSeconds,
            "probeGateConfiguredSeconds": probe.configuredHoldSeconds,
            "probeGateObservedSeconds": gateObservedSeconds,
            "memory": memoryMetrics(memorySnapshot),
            "changeCountDelta": document.session.changeCount - changeCountBefore,
            "undoDelta": document.session.undoStack.undoCommands.count - undoCountBefore,
        ]
        metrics.merge(replyMetrics(reply)) { _, new in new }
        attachX08Metrics("near-cap-simplify", fields: metrics)

        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertEqual(probe.action, "simplify")
        XCTAssertEqual(probe.triangles, 480_000)
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "near-limit simplification blocked the MainActor for \(heartbeat.maxGap)s")
        let entries = try XCTUnwrap(reply["bodies"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["beforeTriangles"] as? Int, 480_000)
        let after = try XCTUnwrap(entries.first?["afterTriangles"] as? Int)
        XCTAssertGreaterThanOrEqual(after, 4)
        XCTAssertLessThan(after, 480_000)
        XCTAssertEqual(document.session.document.bodies.count, 1)
        XCTAssertEqual(document.session.document.bodies.first?.render.triangleCount, after)

        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore)
        XCTAssertEqual(document.session.document.bodies.first?.render.triangleCount, 480_000)
    }

    // MARK: Cancellation / source fence

    func testX08OwnerCancelDuringRealEuclidCSGDiscardsThePartialResult() async throws {
        let document = try await makeDocument("X08OwnerCancel")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Run A", mesh: cube())
        let second = addMeshBody(document, name: "Run B", mesh: cube(center: Vector(5, 0, 0)))
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
        let bodies = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count
        let gate = M28CancellationGate(cancelAt: 4)
        let token = CADMeshCancellation(checkpoint: { gate.checkpoint() })
        let observations = X08ComputeObservationBox()
        CADMeshService.testComputeObservation = { observations.record($0) }
        let memory = X08ProcessFootprintSampler()
        memory.start()
        let box = M28ReplyBox()
        let heartbeat = X08Heartbeat()
        heartbeat.start()
        let requestStart = ContinuousClock.now
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: unionBody, tools: [tool]),
                cancellation: token)
        }
        await Task.detached { gate.waitForEntered() }.value
        let checkpointEnteredAt = ContinuousClock.now
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelAt = ContinuousClock.now
        let cancelRequestedAfterSeconds = seconds(requestStart.duration(to: cancelAt))
        XCTAssertTrue(CADMeshService.cancelActiveOperation(for: document))
        XCTAssertTrue(token.isCancelled,
                      "the owner cancel must flip the shared token before the caller returns")
        gate.release.signal()
        let releaseAt = ContinuousClock.now
        let cancelToReleaseSeconds = seconds(cancelAt.duration(to: releaseAt))
        await task.value
        let joinAfterCancelSeconds = seconds(cancelAt.duration(to: .now))
        let releaseToJoinSeconds = seconds(releaseAt.duration(to: .now))
        let requestSeconds = seconds(requestStart.duration(to: .now))
        heartbeat.stop()
        let memorySnapshot = memory.stop()

        let reply = try XCTUnwrap(box.value)
        let observation = observations.all.first
        var metrics: [String: Any] = [
            "inputTriangles": observation?.inputTriangles ?? 0,
            "inputBodies": observation?.inputBodies ?? 2,
            "computeRanOnMain": observation?.ranOnMainThread ?? false,
            "mainActorMaxGapSeconds": heartbeat.maxGap,
            "mainActorTicks": heartbeat.ticks,
            "computeSeconds": observation?.computeSeconds ?? -1,
            "computeOutcome": observation?.outcome ?? "unobserved",
            "requestSeconds": requestSeconds,
            "computeScope": "detached input validation + real Euclid CSG; computeSeconds includes the deterministic M28 checkpoint hold, recorded separately below",
            "checkpointCount": gate.count,
            "checkpointEnteredAfterSeconds": seconds(requestStart.duration(to: checkpointEnteredAt)),
            "cancelRequestedAfterSeconds": cancelRequestedAfterSeconds,
            "cancelToReleaseSeconds": cancelToReleaseSeconds,
            "joinAfterCancelSeconds": joinAfterCancelSeconds,
            "releaseToJoinSeconds": releaseToJoinSeconds,
            "gateHeldSeconds": seconds(checkpointEnteredAt.duration(to: cancelAt)),
            "memory": memoryMetrics(memorySnapshot),
            "changeCountDelta": document.session.changeCount - changeCount,
            "undoDelta": document.session.undoStack.undoCommands.count - undoCount,
        ]
        metrics.merge(replyMetrics(reply)) { _, new in new }
        attachX08Metrics("owner-cancel", fields: metrics)

        XCTAssertGreaterThanOrEqual(gate.count, 4,
                                    "cancellation must be observed inside real Euclid CSG")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "cancelled")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        XCTAssertLessThan(heartbeat.maxGap, 0.5)
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), bodies)
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount,
                       "a cancelled CSG must not add an undo entry")
    }

    func testX08NewerRunReplacesCancelledOwnerWithoutLosingItsRecordOrCommittingLate() async throws {
        let document = try await makeDocument("X08OwnerReplace")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let firstA = addMeshBody(document, name: "Replace A1", mesh: cube())
        let firstB = addMeshBody(document, name: "Replace A2",
                                 mesh: cube(center: Vector(5, 0, 0)))
        let secondA = addMeshBody(document, name: "Replace B1",
                                  mesh: cube(center: Vector(0, 5, 0)))
        let secondB = addMeshBody(document, name: "Replace B2",
                                  mesh: cube(center: Vector(5, 5, 0)))
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let changeBefore = document.session.changeCount
        let undoBefore = document.session.undoStack.undoCommands.count

        let gate = X08SequencedComputeGate()
        CADMeshService.testHeavyComputeProbe = { gate.checkpoint(action: $0, triangles: $1) }
        let observations = X08ComputeObservationBox()
        CADMeshService.testComputeObservation = { observations.record($0) }
        let memory = X08ProcessFootprintSampler()
        memory.start()
        let heartbeat = X08Heartbeat()
        heartbeat.start()
        let firstBox = M28ReplyBox()
        let secondBox = M28ReplyBox()
        let requestStart = ContinuousClock.now
        let firstTask = Task { @MainActor in
            firstBox.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: firstA, tools: [firstB]))
        }
        await gate.waitFirstEntered()
        let firstEnteredAt = ContinuousClock.now
        let secondTask = Task { @MainActor in
            secondBox.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: secondA, tools: [secondB]))
        }
        await gate.waitSecondEntered()
        let secondEnteredAt = ContinuousClock.now
        let active = try XCTUnwrap(service.activeOperationStatus())
        XCTAssertEqual(active["action"] as? String, "boolean")
        XCTAssertEqual(active["cancelRequested"] as? Bool, false,
                       "the newer operation must own the record after replacing the old one")

        gate.releaseFirst()
        await firstTask.value
        let firstReply = try XCTUnwrap(firstBox.value)
        let oldJoinAt = ContinuousClock.now
        XCTAssertEqual(firstReply["ok"] as? Bool, false)
        XCTAssertEqual(firstReply["error"] as? String, "cancelled")
        let activeAfterOldJoin = try XCTUnwrap(
            service.activeOperationStatus(),
            "the old run's finish must not remove the newer operation record")
        XCTAssertEqual(activeAfterOldJoin["action"] as? String, "boolean")
        XCTAssertEqual(document.session.changeCount, changeBefore,
                       "the still-gated newer run must not have committed")
        XCTAssertEqual(document.session.document.bodies.count, 4)

        gate.releaseSecond()
        await secondTask.value
        let secondReply = try XCTUnwrap(secondBox.value)
        let doneAt = ContinuousClock.now
        heartbeat.stop()
        let memorySnapshot = memory.stop()

        let firstObservation = observations.all.first
        let secondObservation = observations.all.dropFirst().first
        var metrics: [String: Any] = [
            "inputTriangles": gate.firstInputTriangles + gate.secondInputTriangles,
            "firstInputTriangles": gate.firstInputTriangles,
            "secondInputTriangles": gate.secondInputTriangles,
            "inputBodies": 4,
            "computeRanOnMain": (firstObservation?.ranOnMainThread ?? gate.firstRanOnMain)
                || (secondObservation?.ranOnMainThread ?? gate.secondRanOnMain),
            "firstComputeRanOnMain": firstObservation?.ranOnMainThread ?? gate.firstRanOnMain,
            "secondComputeRanOnMain": secondObservation?.ranOnMainThread ?? gate.secondRanOnMain,
            "probeFirstRanOnMain": gate.firstRanOnMain,
            "probeSecondRanOnMain": gate.secondRanOnMain,
            "mainActorMaxGapSeconds": heartbeat.maxGap,
            "mainActorTicks": heartbeat.ticks,
            "firstComputeSeconds": firstObservation?.computeSeconds ?? -1,
            "firstComputeOutcome": firstObservation?.outcome ?? "unobserved",
            "secondComputeSeconds": secondObservation?.computeSeconds ?? -1,
            "secondComputeOutcome": secondObservation?.outcome ?? "unobserved",
            "requestSeconds": seconds(requestStart.duration(to: doneAt)),
            "firstEnteredAfterSeconds": seconds(requestStart.duration(to: firstEnteredAt)),
            "secondEnteredAfterSeconds": seconds(requestStart.duration(to: secondEnteredAt)),
            "oldJoinedAfterSecondEnteredSeconds": seconds(secondEnteredAt.duration(to: oldJoinAt)),
            "secondCommittedAfterOldJoinSeconds": seconds(oldJoinAt.duration(to: doneAt)),
            "memory": memoryMetrics(memorySnapshot),
            "changeCountDelta": document.session.changeCount - changeBefore,
            "undoDelta": document.session.undoStack.undoCommands.count - undoBefore,
        ]
        metrics.merge(replyMetrics(secondReply)) { _, new in new }
        metrics["firstResultOk"] = firstReply["ok"] as? Bool ?? false
        metrics["firstResultError"] = firstReply["error"] as? String ?? ""
        attachX08Metrics("owner-replacement", fields: metrics)

        XCTAssertEqual(firstReply["ok"] as? Bool, false)
        XCTAssertEqual(firstReply["error"] as? String, "cancelled")
        XCTAssertEqual(secondReply["ok"] as? Bool, true, secondReply["message"] as? String ?? "")
        XCTAssertEqual(document.session.changeCount, changeBefore + 1,
                       "exactly the newer operation commits")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1,
                       "exactly one new undo entry")
        XCTAssertEqual(document.session.document.bodies.count, 3)
        XCTAssertNotNil(document.session.document.body(with: firstA.id))
        XCTAssertNotNil(document.session.document.body(with: firstB.id))
        XCTAssertNil(document.session.document.body(with: secondA.id))
        XCTAssertNil(document.session.document.body(with: secondB.id))
        XCTAssertNil(service.activeOperationStatus())
        document.session.undo()
        XCTAssertEqual(Set(document.session.document.bodies.map(\.id.raw)), Set(idsBefore))
    }

    func testX08EditedSourceDuringComputeIsRefusedWithoutTouchingGeometryOrHistory() async throws {
        let document = try await makeDocument("X08EditedSource")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Edit A", mesh: cube())
        let second = addMeshBody(document, name: "Edit B", mesh: cube(center: Vector(5, 0, 0)))
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let gate = X08CommitGate()
        CADMeshService.testBeforeCommitProbe = { gate.checkpoint() }

        let box = M28ReplyBox()
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: first, tools: [second]))
        }
        await gate.waitEntered()
        var moved = first.transform
        moved.translation += SIMD3(2, 0, 0)
        document.session.perform(TransformBodiesCommand(
            title: "Edit source", before: [first.id: first.transform], after: [first.id: moved]))
        let changeCountAfterEdit = document.session.changeCount
        let undoCountAfterEdit = document.session.undoStack.undoCommands.count
        gate.releaseGate()
        await task.value

        let reply = try XCTUnwrap(box.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "source_changed", "\(reply)")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore)
        XCTAssertEqual(document.session.changeCount, changeCountAfterEdit,
                       "a stale result must not add a second undo entry")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCountAfterEdit)
        XCTAssertNotNil(document.session.document.body(with: first.id))
    }

    func testX08ClosedSourceDuringComputeIsRefused() async throws {
        let document = try await makeDocument("X08ClosedSource")
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "Close A", mesh: cube())
        let second = addMeshBody(document, name: "Close B", mesh: cube(center: Vector(5, 0, 0)))
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let gate = X08CommitGate()
        CADMeshService.testBeforeCommitProbe = { gate.checkpoint() }

        let box = M28ReplyBox()
        let task = Task { @MainActor in
            box.value = await service.handleAsync(
                action: "boolean",
                args: booleanArgs(op: "union", target: first, tools: [second]))
        }
        await gate.waitEntered()
        document.close()
        gate.releaseGate()
        await task.value

        let reply = try XCTUnwrap(box.value)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "closed", "\(reply)")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore)
        XCTAssertEqual(document.session.changeCount, changeCount)
    }

    func testX08ReadOnlyDocumentRefusesBeforeDispatch() async throws {
        let url = workDir.appendingPathComponent("X08ReadOnly.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .definitionKind)
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        XCTAssertTrue(document.isReadOnly)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let probe = X08ObserveProbe()
        CADMeshService.testHeavyComputeProbe = { probe.record(action: $0, triangles: $1) }
        let reply = await CADMeshService(document: document).handleAsync(
            action: "boolean",
            args: ["op": "union",
                   "target": body.id.raw.uuidString,
                   "tools": [UUID().uuidString]])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "read_only", "\(reply)")
        XCTAssertFalse(probe.seen, "a read-only document must refuse before dispatching a worker")
    }

    // MARK: The proposal/tool path uses the same off-main owner

    func testX08ProposalPreviewRunsTheBooleanOffMain() async throws {
        let document = try await makeDocument("X08Proposal")
        defer { if !document.isClosed { document.close() } }
        let first = addMeshBody(document, name: "Proposal A", mesh: cube())
        let second = addMeshBody(document, name: "Proposal B",
                                 mesh: cube(center: Vector(5, 0, 0)))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let probe = X08ObserveProbe()
        CADMeshService.testHeavyComputeProbe = { probe.record(action: $0, triangles: $1) }
        let operation: [String: Any] = [
            "op": "mesh.boolean",
            "args": booleanArgs(op: "union", target: first, tools: [second]),
        ]
        let data = try JSONSerialization.data(withJSONObject: operation)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let proposal = try await CADProposalService().propose(
            document: document, operationJSON: json, summary: "X08 off-main preview")
        XCTAssertFalse(proposal.preview.failed, proposal.preview.serviceMessage ?? "")
        XCTAssertEqual(proposal.preview.serviceOperation, "mesh.boolean")
        XCTAssertEqual(proposal.preview.serviceExactness, "mesh")
        XCTAssertEqual(proposal.preview.bodyCountBefore, 2)
        XCTAssertEqual(proposal.preview.bodyCountAfter, 1)
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "a proposal preview must not mutate the live document")
        XCTAssertTrue(probe.seen, "the proposal executor must reach the detached mesh worker")
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertEqual(probe.action, "boolean")
        XCTAssertGreaterThan(probe.triangles, 0)
    }

    // MARK: Malformed frozen input

    /// One focused real-input test over the corrupt buffers a reopened
    /// MeshBlob can carry. Each case is a real document body driven through
    /// the real service; the expected refusal must arrive before Euclid
    /// conversion, and valid work on the same document must still succeed.
    func testX08MalformedFrozenInputIsRefusedBeforeEuclidAndValidWorkStillCommits() async throws {
        for (label, render, transform) in malformedRenderInputs() {
            try await assertMalformedInputRefused(label, render: render, transform: transform)
        }
    }

    private func assertMalformedInputRefused(_ label: String,
                                             render: RenderMesh,
                                             transform: Transform3D) async throws {
        let document = try await makeDocument("X08Malformed-\(label)")
        defer { if !document.isClosed { document.close() } }
        let service = CADMeshService(document: document)
        let validTarget = addMeshBody(document, name: "Safe target", mesh: cube())
        let validTool = addMeshBody(document, name: "Safe tool",
                                    mesh: cube(center: Vector(5, 0, 0)))
        let malformed = addRenderBody(document, name: "Malformed \(label)",
                                      render: render, transform: transform)
        let idsBefore = document.session.document.bodies.map(\.id.raw)
        let changeBefore = document.session.changeCount
        let undoBefore = document.session.undoStack.undoCommands.count
        let renderBefore = malformed.render
        let transformBefore = malformed.transform

        let refusalProbe = X08ObserveProbe()
        CADMeshService.testHeavyComputeProbe = {
            refusalProbe.record(action: $0, triangles: $1)
        }
        let started = ContinuousClock.now
        let reply = await service.handleAsync(
            action: "boolean",
            args: booleanArgs(op: "union", target: malformed, tools: [validTool]))
        let requestSeconds = seconds(started.duration(to: .now))

        XCTAssertFalse(reply["ok"] as? Bool ?? true, "\(label): \(reply)")
        XCTAssertEqual(reply["error"] as? String, "invalid_mesh", "\(label): \(reply)")
        XCTAssertFalse(reply["mutated"] as? Bool ?? false, "\(label)")
        XCTAssertTrue(refusalProbe.seen,
                      "\(label): validation must run in the detached worker")
        XCTAssertFalse(refusalProbe.ranOnMain, "\(label): validation must not run on MainActor")
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore, "\(label)")
        XCTAssertEqual(document.session.changeCount, changeBefore, "\(label)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore, "\(label)")
        let stored = try XCTUnwrap(document.session.document.body(with: malformed.id))
        XCTAssertEqual(stored.meshRevision, malformed.meshRevision, "\(label)")
        XCTAssertEqual(stored.render.indices, renderBefore.indices, "\(label)")
        XCTAssertEqual(stored.render.positions.count, renderBefore.positions.count, "\(label)")
        XCTAssertEqual(stored.render.normals.count, renderBefore.normals.count, "\(label)")
        XCTAssertEqual(stored.render.texcoords?.count, renderBefore.texcoords?.count,
                       "\(label)")
        // Bit patterns rather than Float equality: NaN fixtures must compare
        // as unchanged bytes even though NaN != NaN.
        XCTAssertEqual(stored.render.positions.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] },
                       renderBefore.positions.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }, label)
        XCTAssertEqual(stored.render.normals.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] },
                       renderBefore.normals.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }, label)
        XCTAssertEqual(stored.render.texcoords?.flatMap { [$0.x.bitPattern, $0.y.bitPattern] },
                       renderBefore.texcoords?.flatMap { [$0.x.bitPattern, $0.y.bitPattern] }, label)
        XCTAssertEqual(stored.transform.translation.x.bitPattern,
                       transformBefore.translation.x.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.translation.y.bitPattern,
                       transformBefore.translation.y.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.translation.z.bitPattern,
                       transformBefore.translation.z.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.scale.bitPattern,
                       transformBefore.scale.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.rotation.real.bitPattern,
                       transformBefore.rotation.real.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.rotation.imag.x.bitPattern,
                       transformBefore.rotation.imag.x.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.rotation.imag.y.bitPattern,
                       transformBefore.rotation.imag.y.bitPattern, "\(label)")
        XCTAssertEqual(stored.transform.rotation.imag.z.bitPattern,
                       transformBefore.rotation.imag.z.bitPattern, "\(label)")

        let validProbe = X08ObserveProbe()
        CADMeshService.testHeavyComputeProbe = {
            validProbe.record(action: $0, triangles: $1)
        }
        let good = await service.handleAsync(
            action: "boolean",
            args: booleanArgs(op: "union", target: validTarget, tools: [validTool]))
        XCTAssertEqual(good["ok"] as? Bool, true, "\(label): \(good["message"] as? String ?? "")")
        XCTAssertTrue(validProbe.seen, "\(label): valid work after refusal must run")
        XCTAssertFalse(validProbe.ranOnMain, "\(label)")
        XCTAssertEqual(document.session.changeCount, changeBefore + 1, "\(label)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1, "\(label)")
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "\(label): malformed body plus the one valid result")
        let validChangeCountDelta = document.session.changeCount - changeBefore
        let validUndoDelta = document.session.undoStack.undoCommands.count - undoBefore
        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), idsBefore, "\(label)")

        attachX08Metrics("refusal-\(label)", fields: [
            "inputTriangles": refusalProbe.triangles,
            "inputBodies": 2,
            "computeRanOnMain": refusalProbe.ranOnMain,
            "probeRanOnMain": refusalProbe.ranOnMain,
            "requestSeconds": requestSeconds,
            "resultOk": reply["ok"] as? Bool ?? false,
            "resultError": reply["error"] as? String ?? "",
            "validWorkAfterRefusalOk": good["ok"] as? Bool ?? false,
            "changeCountDelta": validChangeCountDelta,
            "undoDelta": validUndoDelta,
        ])
    }

    /// Corrupt-but-decodable inputs. MeshBlob already bounds-checks indices; it
    /// does not reject non-finite floats or a UV/normal buffer mismatch, which
    /// are the persistence-adjacent defects this service must refuse.
    private func malformedRenderInputs() -> [(String, RenderMesh, Transform3D)] {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let normals = [SIMD3<Float>(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)]
        let indices: [UInt32] = [0, 1, 2]
        var nanTransform = Transform3D.identity
        nanTransform.translation = SIMD3(.nan, 0, 0)
        var zeroScale = Transform3D.identity
        zeroScale.scale = 0
        var zeroRotation = Transform3D.identity
        zeroRotation.rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 0)
        return [
            ("out-of-range-index",
             RenderMesh(positions: positions, normals: normals, indices: [0, 1, 3]),
             .identity),
            ("truncated-indices",
             RenderMesh(positions: positions, normals: normals, indices: [0, 1, 2, 0]),
             .identity),
            ("nan-position",
             RenderMesh(positions: [positions[0], positions[1], SIMD3(.nan, 1, 0)],
                        normals: normals, indices: indices),
             .identity),
            ("nan-normal",
             RenderMesh(positions: positions,
                        normals: [normals[0], SIMD3(.nan, 0, 1), normals[2]],
                        indices: indices),
             .identity),
            ("normals-count-mismatch",
             RenderMesh(positions: positions + [SIMD3(1, 1, 0)],
                        normals: normals, indices: indices),
             .identity),
            ("nan-texcoord",
             RenderMesh(positions: positions, normals: normals, indices: indices,
                        texcoords: [SIMD2(0, 0), SIMD2(.nan, 0), SIMD2(0, 1)]),
             .identity),
            ("texcoord-count-mismatch",
             RenderMesh(positions: positions, normals: normals, indices: indices,
                        texcoords: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]),
             .identity),
            ("nan-transform",
             RenderMesh(positions: positions, normals: normals, indices: indices),
             nanTransform),
            ("zero-scale",
             RenderMesh(positions: positions, normals: normals, indices: indices),
             zeroScale),
            ("zero-rotation",
             RenderMesh(positions: positions, normals: normals, indices: indices),
             zeroRotation),
        ]
    }

    // MARK: Measurement helpers

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Small .keepAlways attachment carrying exact measured values. No build
    /// result, threshold name or synthesized peak is attached; Root reads the
    /// real numbers from the xcresult or the printed line.
    private func attachX08Metrics(_ name: String,
                                  fields: [String: Any],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        var payload: [String: Any] = [
            "case": name,
            "computeScope": "detached input validation + real Euclid/render/weld work; the explicit scheduling gate runs before this measurement",
            "memoryScope": "task_vm_info phys_footprint of this XCTest process, sampled every 50 ms from before the request until it returns; includes XCTest/Euclid caches, not device memory pressure",
        ]
        payload.merge(fields) { _, new in new }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("X08 metrics must be a valid JSON object", file: file, line: line)
            return
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "X08_METRICS_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("X08_METRICS \(name) \(text)")
    }

    private func replyMetrics(_ reply: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = ["resultOk": reply["ok"] as? Bool ?? false]
        if let error = reply["error"] as? String { fields["resultError"] = error }
        if let mutated = reply["mutated"] as? Bool { fields["resultMutated"] = mutated }
        if let triangles = reply["triangleCount"] as? Int {
            fields["resultTriangles"] = triangles
        }
        return fields
    }

    private func memoryMetrics(_ snapshot: X08ProcessFootprintSampler.Snapshot)
        -> [String: Any] {
        ["baselineBytes": snapshot.baselineBytes,
         "peakBytes": snapshot.peakBytes,
         "endBytes": snapshot.endBytes,
         "samples": snapshot.sampleCount,
         "samplingAvailable": snapshot.baselineBytes > 0,
         "accounting": "task_vm_info.phys_footprint",
         "samplingIntervalMilliseconds": 50]
    }
}

// MARK: - X08 test harness

@MainActor
private final class X08Heartbeat {
    private(set) var maxGap: TimeInterval = 0
    private(set) var ticks = 0
    private var task: Task<Void, Never>?
    private var last = Date()

    func start() {
        task?.cancel()
        last = Date()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
                guard !Task.isCancelled else { break }
                let now = Date()
                let gap = now.timeIntervalSince(last)
                if gap > maxGap { maxGap = gap }
                last = now
                ticks += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

nonisolated private final class X08ComputeProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let hold: TimeInterval
    private var seen = false
    private var ranOnMainThread = true
    private var actionName = ""
    private var triangleCount = 0

    init(hold: TimeInterval) {
        self.hold = hold
    }

    func checkpoint(action: String, triangles: Int) {
        lock.lock()
        seen = true
        ranOnMainThread = Thread.isMainThread
        actionName = action
        triangleCount = triangles
        lock.unlock()
        entered.signal()
        if hold > 0 {
            _ = release.wait(timeout: .now() + hold + 10)
        }
    }

    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.entered.wait(timeout: .now() + 15)
                continuation.resume()
            }
        }
    }

    func releaseGate() {
        release.signal()
    }

    var ranOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return ranOnMainThread
    }

    var action: String {
        lock.lock(); defer { lock.unlock() }
        return actionName
    }

    var triangles: Int {
        lock.lock(); defer { lock.unlock() }
        return triangleCount
    }

    var configuredHoldSeconds: TimeInterval { hold }
}

nonisolated private final class X08ObserveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seenFlag = false
    private var ranOnMainThread = true
    private var actionName = ""
    private var triangleCount = 0

    func record(action: String, triangles: Int) {
        lock.lock()
        seenFlag = true
        ranOnMainThread = Thread.isMainThread
        actionName = action
        triangleCount = triangles
        lock.unlock()
    }

    var seen: Bool {
        lock.lock(); defer { lock.unlock() }
        return seenFlag
    }

    var ranOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return ranOnMainThread
    }

    var action: String {
        lock.lock(); defer { lock.unlock() }
        return actionName
    }

    var triangles: Int {
        lock.lock(); defer { lock.unlock() }
        return triangleCount
    }
}

nonisolated private final class X08CommitGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func checkpoint() {
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }

    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.entered.wait(timeout: .now() + 15)
                continuation.resume()
            }
        }
    }

    func releaseGate() {
        release.signal()
    }
}

/// Process-footprint sampler used only for X08 evidence. It uses the same
/// `TASK_VM_INFO`/`phys_footprint` accounting as the app's ThreadLoadMetrics
/// and the Qualification host sampler (those samplers are private to their
/// targets, so this test carries the identical kernel read). It samples every
/// 50 ms for the request window and reports baseline/peak/end with the count;
/// it never treats `ProcessInfo.physicalMemory` as process usage.
nonisolated private final class X08ProcessFootprintSampler: @unchecked Sendable {
    struct Snapshot: Sendable {
        let baselineBytes: Int
        let peakBytes: Int
        let endBytes: Int
        let sampleCount: Int
    }

    private let lock = NSLock()
    private var baseline = 0
    private var peak = 0
    private var last = 0
    private var samples = 0
    private var task: Task<Void, Never>?

    func start() {
        lock.lock()
        baseline = Self.readFootprint()
        peak = baseline
        last = baseline
        samples = 1
        lock.unlock()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    func stop() -> Snapshot {
        task?.cancel()
        task = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(baselineBytes: baseline,
                        peakBytes: peak,
                        endBytes: last,
                        sampleCount: samples)
    }

    private func sample() {
        let value = Self.readFootprint()
        lock.lock()
        last = value
        if value > peak { peak = value }
        samples += 1
        lock.unlock()
    }

    private static func readFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

/// Two-run deterministic gate: the first real compute is held until the test
/// starts the replacement, the second until the test has observed the old
/// run's join. Only the pre-compute probe is gated; both results are real.
nonisolated private final class X08SequencedComputeGate: @unchecked Sendable {
    let firstEntered = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let secondRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var firstMain = true
    private var secondMain = true
    private var firstTriangles = 0
    private var secondTriangles = 0

    func checkpoint(action: String, triangles: Int) {
        _ = action
        lock.lock()
        count += 1
        let ordinal = count
        if ordinal == 1 {
            firstMain = Thread.isMainThread
            firstTriangles = triangles
        } else if ordinal == 2 {
            secondMain = Thread.isMainThread
            secondTriangles = triangles
        }
        lock.unlock()
        switch ordinal {
        case 1:
            firstEntered.signal()
            _ = firstRelease.wait(timeout: .now() + 15)
        case 2:
            secondEntered.signal()
            _ = secondRelease.wait(timeout: .now() + 15)
        default:
            break
        }
    }

    func waitFirstEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.firstEntered.wait(timeout: .now() + 15)
                continuation.resume()
            }
        }
    }

    func waitSecondEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.secondEntered.wait(timeout: .now() + 15)
                continuation.resume()
            }
        }
    }

    func releaseFirst() { firstRelease.signal() }
    func releaseSecond() { secondRelease.signal() }

    var firstRanOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return firstMain
    }

    var secondRanOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return secondMain
    }

    var firstInputTriangles: Int {
        lock.lock(); defer { lock.unlock() }
        return firstTriangles
    }

    var secondInputTriangles: Int {
        lock.lock(); defer { lock.unlock() }
        return secondTriangles
    }
}

/// Collects the real compute observations emitted by `CADMeshService`.
nonisolated private final class X08ComputeObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [CADMeshComputeObservation] = []

    func record(_ observation: CADMeshComputeObservation) {
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    var all: [CADMeshComputeObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }
}
