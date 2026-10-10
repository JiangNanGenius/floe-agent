//
//  CADScriptAndMeshTests.swift
//  FloeCADKitTests
//
//  Focused tests for the ShapeScript bridge (`ShapeScriptKit`), the script
//  record service (`CADScriptService`) and the mesh editing service
//  (`CADMeshService`).
//
//  Units note: ShapeScript's world units are arbitrary; this bridge maps them
//  1:1 to FloeCAD millimetres, so a `cube { size 10 }` is a 10 mm cube.
//
//  Uncertainty note: error line numbers come from ShapeScript's lexer/parser
//  ranges. These tests assert that a line is reported and that it is inside
//  the user source; they do not pin an exact line where the parser's range
//  choice is not contractually fixed.
//

import XCTest
import simd
import Euclid
@testable import FloeCAD

final class CADScriptAndMeshTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADScriptMesh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let url = workDir.appendingPathComponent("\(name).floecad")
        return try await FloeCADDocument.create(at: url, name: name)
    }

    @discardableResult
    private func addMeshBody(_ document: FloeCADDocument,
                             name: String,
                             mesh: Euclid.Mesh,
                             transform: Transform3D = .identity) -> Body {
        let body = Body(name: name,
                        transform: transform,
                        primitive: nil,
                        euclidMesh: mesh,
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    @discardableResult
    private func addRenderBody(_ document: FloeCADDocument,
                               name: String,
                               render: RenderMesh) -> Body {
        let body = Body(id: BodyID(),
                        name: name,
                        transform: .identity,
                        primitive: nil,
                        render: render,
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    // MARK: 1. Valid source

    func testShapeScriptKitValidSourceProducesMesh() {
        let outcome = ShapeScriptKit.evaluate(source: "cube { size 10 }")
        XCTAssertNil(outcome.errorCode, outcome.errorMessage ?? "")
        let mesh = outcome.mesh
        XCTAssertNotNil(mesh, "a valid cube script must produce a mesh")
        XCTAssertEqual(outcome.polygonCount, 6)
        XCTAssertEqual(outcome.triangleCount, 12)
        XCTAssertEqual(mesh?.triangleCount, 12)
        let aabb = mesh!.localAABB
        XCTAssertEqual(Double(aabb.min.x), -5, accuracy: 1e-4)
        XCTAssertEqual(Double(aabb.max.x), 5, accuracy: 1e-4)
        XCTAssertEqual(Double(aabb.min.y), -5, accuracy: 1e-4)
        XCTAssertEqual(Double(aabb.max.z), 5, accuracy: 1e-4)
    }

    // MARK: 2. Parse / runtime errors

    func testShapeScriptErrorsAreReportedNotCrash() {
        let parse = ShapeScriptKit.evaluate(source: "cube {\n  size 10\n")
        XCTAssertEqual(parse.errorCode, "parse_error", parse.errorMessage ?? "")
        XCTAssertNotNil(parse.errorLine, "parse errors must report a line number")
        XCTAssertNil(parse.mesh)

        let runtime = ShapeScriptKit.evaluate(source: "no_such_command_xyz")
        XCTAssertEqual(runtime.errorCode, "runtime_error", runtime.errorMessage ?? "")
        XCTAssertNil(runtime.mesh)
        XCTAssertEqual(runtime.triangleCount, 0)
    }

    // MARK: 3. Imports are refused (no file read)

    func testShapeScriptImportIsRefusedWithoutReadingFiles() throws {
        // A REAL, readable ShapeScript file exists at this path. If the bridge
        // read it, the scene would contain its cube; the refusal must win.
        let evil = workDir.appendingPathComponent("evil.shape")
        try "cube { size 1000 }".write(to: evil, atomically: true, encoding: .utf8)

        let outcome = ShapeScriptKit.evaluate(source: #"import "\#(evil.path)""#)
        XCTAssertNil(outcome.mesh)
        XCTAssertNotNil(outcome.errorCode, "an import must fail, not load a file")
        XCTAssertEqual(outcome.triangleCount, 0)
        XCTAssertEqual(outcome.polygonCount, 0)
    }

    // MARK: 4. Limits

    func testShapeScriptLimits() {
        var byteLimits = ShapeScriptLimits()
        byteLimits.maxSourceBytes = 64
        let oversized = ShapeScriptKit.evaluate(source: String(repeating: "cube\n", count: 40),
                                                limits: byteLimits)
        XCTAssertEqual(oversized.errorCode, "limit_source")

        var geometryLimits = ShapeScriptLimits()
        geometryLimits.maxTriangles = 10
        let tooFine = ShapeScriptKit.evaluate(source: "sphere", limits: geometryLimits)
        XCTAssertEqual(tooFine.errorCode, "limit_geometry", tooFine.errorMessage ?? "")

        var timeLimits = ShapeScriptLimits()
        timeLimits.maxWallClockSeconds = 0.5
        let started = Date()
        let timeout = ShapeScriptKit.evaluate(source: "for 1 to 1000000000 {}",
                                              limits: timeLimits)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(timeout.errorCode, "limit_time", timeout.errorMessage ?? "")
        XCTAssertNil(timeout.mesh)
        XCTAssertLessThan(elapsed, 5, "the wall-clock deadline must stop a hostile loop")
    }

    // MARK: 5. Script service preview/apply/undo/persistence

    func testScriptServicePreviewApplyUndoAndPersistence() async throws {
        let document = try await makeDocument("Scripts")
        let service = CADScriptService(document: document)
        let put = await service.handle(action: "put", args: [
            "name": "ParamCube",
            "source": "cube { size param_size }",
            "parameters": ["size": 4.0],
        ])
        XCTAssertEqual(put["ok"] as? Bool, true, put["message"] as? String ?? "")
        XCTAssertEqual(put["mutated"] as? Bool, true, "record edits are document state")
        let scriptID = try XCTUnwrap((put["script"] as? [String: Any])?["id"] as? String)

        let beforeCount = document.session.document.bodies.count
        let changeCountBefore = document.session.changeCount
        let preview = await service.handle(action: "preview", args: ["id": scriptID])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["triangleCount"] as? Int, 12)
        XCTAssertEqual(document.session.document.bodies.count, beforeCount,
                       "preview must not create a body")
        XCTAssertEqual(document.session.changeCount, changeCountBefore,
                       "preview must not mutate the document")

        let apply = await service.handle(action: "apply", args: ["id": scriptID])
        XCTAssertEqual(apply["ok"] as? Bool, true, apply["message"] as? String ?? "")
        XCTAssertEqual(apply["mutated"] as? Bool, true)
        XCTAssertEqual(apply["exactness"] as? String, "mesh")
        let outputID = try XCTUnwrap(apply["outputBodyID"] as? String)
        XCTAssertEqual(document.session.document.bodies.count, beforeCount + 1)
        let body = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == outputID
        })
        XCTAssertEqual(body.render.triangleCount, 12)
        // The parameter prelude made param_size = 4, so the cube spans ±2 mm.
        let aabb = body.render.localAABB
        XCTAssertEqual(Double(aabb.max.x), 2, accuracy: 1e-3)

        // ONE undo reverses the apply; the result binding must report drift
        // (the record may not claim an output the document no longer has).
        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.count, beforeCount)
        var list = await service.handle(action: "list", args: [:])
        var scripts = try XCTUnwrap(list["scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.first?["stale"] as? Bool, true,
                       "an undo must invalidate the recorded result binding")
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.count, beforeCount + 1)
        list = await service.handle(action: "list", args: [:])
        scripts = try XCTUnwrap(list["scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.first?["stale"] as? Bool, false,
                       "redo restores the exact recorded mesh")

        // A manual edit of the output body is never silently overwritten: the
        // default apply refuses; fork keeps the edit and creates a new output;
        // the next default apply rebuilds the (now matching) forked output.
        let live = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == outputID
        })
        var edited = live
        edited.render = EuclidBridge.renderMesh(from: .cube(center: Vector(8, 8, 8),
                                                            size: Vector(1, 1, 1)))
        document.session.perform(ReplaceBodyCommand(title: "Manual edit",
                                                    before: live, after: edited))
        let refused = await service.handle(action: "apply", args: ["id": scriptID])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "output_changed")
        let forked = await service.handle(action: "apply", args: ["id": scriptID, "conflict": "fork"])
        XCTAssertEqual(forked["ok"] as? Bool, true, forked["message"] as? String ?? "")
        let forkedID = try XCTUnwrap(forked["outputBodyID"] as? String)
        XCTAssertNotEqual(forkedID, outputID, "fork must create a new output body")
        XCTAssertNotNil(document.session.document.bodies.first { $0.id.raw.uuidString == outputID },
                        "fork must keep the manually edited body")
        let rebuilt = await service.handle(action: "apply", args: ["id": scriptID])
        XCTAssertEqual(rebuilt["ok"] as? Bool, true, rebuilt["message"] as? String ?? "")
        XCTAssertEqual(rebuilt["outputBodyID"] as? String, forkedID,
                       "a matching output is rebuilt in place")

        // Records survive save/reopen (Project.scriptsData round trip).
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADScriptService(document: reopened)
        let reopenedList = await reopenedService.handle(action: "list", args: [:])
        XCTAssertEqual(reopenedList["ok"] as? Bool, true)
        let reopenedScripts = try XCTUnwrap(reopenedList["scripts"] as? [[String: Any]])
        XCTAssertEqual(reopenedScripts.count, 1)
        XCTAssertEqual(reopenedScripts.first?["outputBodyID"] as? String, forkedID)
        XCTAssertEqual(reopenedScripts.first?["stale"] as? Bool, false)
        reopened.close()
    }

    /// The recorded `outputDocumentRevision` is enforced, not just stored:
    /// after ANY committed document change (here an unrelated import + save,
    /// with the script output body itself untouched), an automatic re-apply
    /// is refused until the caller explicitly chooses fork or rebuild.
    func testScriptApplyEnforcesRecordedDocumentRevision() async throws {
        let document = try await makeDocument("ScriptRevision")
        let service = CADScriptService(document: document)
        let put = await service.handle(action: "put", args: [
            "name": "Cube", "source": "cube { size 4 }",
        ])
        let scriptID = try XCTUnwrap((put["script"] as? [String: Any])?["id"] as? String)
        let applied = await service.handle(action: "apply", args: ["id": scriptID])
        XCTAssertEqual(applied["ok"] as? Bool, true, applied["message"] as? String ?? "")
        let outputID = try XCTUnwrap(applied["outputBodyID"] as? String)
        var save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        // An unrelated committed change moves the document past the recorded
        // revision; the script output body itself stays byte-identical.
        let importOutcome = document.nativeImportData(
            STLExporter.binarySTL(bodies: [try XCTUnwrap(
                document.session.document.bodies.first { $0.id.raw.uuidString == outputID })]),
            format: "stl", fileName: "copy.stl", unitScale: nil)
        XCTAssertTrue(importOutcome.isOK, importOutcome.message ?? "")
        save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        // Auto re-apply refuses on the revision rule alone (hash unchanged).
        let refused = await service.handle(action: "apply", args: ["id": scriptID])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "output_changed")
        let listAfter = await service.handle(action: "list", args: [:])
        let scriptsAfter = try XCTUnwrap(listAfter["scripts"] as? [[String: Any]])
        let recordedRevision = try XCTUnwrap(scriptsAfter.first?["outputDocumentRevision"] as? Int)
        XCTAssertGreaterThan(document.revision, recordedRevision)
        XCTAssertTrue((refused["message"] as? String)?.contains("revision") == true,
                      "the refusal must name the revision rule: \(refused["message"] ?? "")")

        // rebuild is the explicit choice and updates the binding in place.
        let rebuilt = await service.handle(action: "apply",
                                           args: ["id": scriptID, "conflict": "rebuild"])
        XCTAssertEqual(rebuilt["ok"] as? Bool, true, rebuilt["message"] as? String ?? "")
        XCTAssertEqual(rebuilt["outputBodyID"] as? String, outputID)
    }

    // MARK: 6. Boolean volumes

    func testMeshBooleanUnionSubtractAndEmptyRefusal() async throws {
        let document = try await makeDocument("Booleans")
        let service = CADMeshService(document: document)
        let first = addMeshBody(document, name: "A",
                                mesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)))
        let second = addMeshBody(document, name: "B",
                                 mesh: .cube(center: Vector(5, 0, 0), size: Vector(10, 10, 10)))

        let union = service.handle(action: "boolean", args: [
            "op": "union",
            "target": first.id.raw.uuidString,
            "tools": [second.id.raw.uuidString],
        ])
        XCTAssertEqual(union["ok"] as? Bool, true, union["message"] as? String ?? "")
        XCTAssertEqual(union["exactness"] as? String, "mesh")
        XCTAssertEqual(document.session.document.bodies.count, 1,
                       "inputs are consumed in the same one undo step")
        let unionBody = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(MeasureKit.bodyVolume(unionBody.render), 1500, accuracy: 1e-3)

        document.session.undo()
        XCTAssertEqual(document.session.document.bodies.count, 2)
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.count, 1)
        document.session.undo()

        let subtract = service.handle(action: "boolean", args: [
            "op": "subtract",
            "target": first.id.raw.uuidString,
            "tools": [second.id.raw.uuidString],
        ])
        XCTAssertEqual(subtract["ok"] as? Bool, true, subtract["message"] as? String ?? "")
        let subtractBody = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(MeasureKit.bodyVolume(subtractBody.render), 500, accuracy: 1e-3)
        document.session.undo()

        // Disjoint intersection is empty: refused, document unchanged.
        let disjoint = addMeshBody(document, name: "Far",
                                   mesh: .cube(center: Vector(100, 0, 0), size: Vector(10, 10, 10)))
        let countBefore = document.session.document.bodies.count
        let empty = service.handle(action: "boolean", args: [
            "op": "intersect",
            "target": first.id.raw.uuidString,
            "tools": [disjoint.id.raw.uuidString],
        ])
        XCTAssertEqual(empty["ok"] as? Bool, false)
        XCTAssertEqual(empty["error"] as? String, "empty_geometry")
        XCTAssertEqual(document.session.document.bodies.count, countBefore)
    }

    // MARK: 7. B-rep exactness guard

    func testMeshOpsRefuseAnalyticBRepUnlessForced() async throws {
        let document = try await makeDocument("Exactness")
        let service = CADMeshService(document: document)

        var analytic = Body(name: "Analytic",
                            primitive: nil,
                            euclidMesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                            revision: 1)
        analytic.brep = OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10),
                                                  placement: .identity)
        XCTAssertNotNil(analytic.brep, "the OCCT box handle must build")
        document.session.perform(AddBodyCommand(body: analytic))
        let tool = addMeshBody(document, name: "Tool",
                               mesh: .cube(center: Vector(5, 0, 0), size: Vector(10, 10, 10)))

        let refused = service.handle(action: "boolean", args: [
            "op": "union",
            "target": analytic.id.raw.uuidString,
            "tools": [tool.id.raw.uuidString],
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "brep_body_refused")
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "a refusal must leave the document unchanged")
        XCTAssertNotNil(document.session.document.body(with: analytic.id)?.brep)

        // Non-destructive ops keep exactness.
        let moved = service.handle(action: "transform", args: [
            "bodyID": analytic.id.raw.uuidString,
            "translate": [1.0, 0.0, 0.0],
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, moved["message"] as? String ?? "")
        XCTAssertEqual(moved["exactness"] as? String, "preserved")
        XCTAssertNotNil(document.session.document.body(with: analytic.id)?.brep)

        // forceMesh acknowledges the downgrade.
        let forced = service.handle(action: "boolean", args: [
            "op": "union",
            "target": analytic.id.raw.uuidString,
            "tools": [tool.id.raw.uuidString],
            "forceMesh": true,
        ])
        XCTAssertEqual(forced["ok"] as? Bool, true, forced["message"] as? String ?? "")
        XCTAssertEqual(forced["exactness"] as? String, "mesh")
        let forcedID = try XCTUnwrap(forced["outputBodyID"] as? String)
        let forcedBody = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == forcedID
        })
        XCTAssertNil(forcedBody.brep)
        XCTAssertEqual(document.session.document.bodies.count, 1)
    }

    // MARK: 8. Repair / simplify / normals / boundary

    func testMeshRepairSimplifyNormalsAndBoundary() async throws {
        let document = try await makeDocument("MeshQuality")
        let service = CADMeshService(document: document)

        // Two coincident good triangles plus one collinear degenerate.
        let positions: [SIMD3<Float>] = [
            [0, 0, 0], [1, 0, 0], [0, 1, 0],
            [0, 0, 0], [1, 0, 0], [0, 1, 0],
            [0, 0, 0], [1, 0, 0], [2, 0, 0],
        ]
        let normals = [SIMD3<Float>](repeating: [0, 0, 1], count: 9)
        let ragged = RenderMesh(positions: positions, normals: normals,
                                indices: [0, 1, 2, 3, 4, 5, 6, 7, 8])
        let raggedBody = addRenderBody(document, name: "Ragged", render: ragged)
        XCTAssertEqual(raggedBody.render.triangleCount, 3)

        let repaired = service.handle(action: "repair", args: [
            "bodyID": raggedBody.id.raw.uuidString,
            "tolerance": 1e-6,
        ])
        XCTAssertEqual(repaired["ok"] as? Bool, true, repaired["message"] as? String ?? "")
        let repairEntry = (repaired["bodies"] as? [[String: Any]])?.first
        XCTAssertEqual(repairEntry?["weldedVertices"] as? Int, 5)
        XCTAssertEqual(repairEntry?["removedTriangles"] as? Int, 1)
        let repairedBody = try XCTUnwrap(document.session.document.body(with: raggedBody.id))
        XCTAssertEqual(repairedBody.render.triangleCount, 2)
        XCTAssertEqual(repairedBody.render.positions.count, 4)

        let normalsResponse = service.handle(action: "recomputeNormals", args: [
            "bodyID": raggedBody.id.raw.uuidString,
        ])
        XCTAssertEqual(normalsResponse["ok"] as? Bool, true,
                       normalsResponse["message"] as? String ?? "")
        let normalized = try XCTUnwrap(document.session.document.body(with: raggedBody.id))
        for normal in normalized.render.normals {
            XCTAssertTrue(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
            XCTAssertEqual(Double(simd_length(normal)), 1, accuracy: 1e-3)
        }

        // A single triangle has exactly three boundary edges.
        let single = RenderMesh(positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0]],
                                normals: [[0, 0, 1], [0, 0, 1], [0, 0, 1]],
                                indices: [0, 1, 2])
        let singleBody = addRenderBody(document, name: "Single", render: single)
        let boundary = service.handle(action: "boundary", args: [
            "bodyID": singleBody.id.raw.uuidString,
        ])
        XCTAssertEqual(boundary["ok"] as? Bool, true)
        XCTAssertEqual(boundary["boundaryEdgeCount"] as? Int, 3)
        XCTAssertEqual(boundary["nonManifoldEdgeCount"] as? Int, 0)
        let singleEntry = (boundary["bodies"] as? [[String: Any]])?.first
        XCTAssertNotNil(singleEntry?["bounds"])

        // Cluster simplification of a dense sphere; never below 4 triangles.
        let sphereBody = addMeshBody(document, name: "Dense",
                                     mesh: .sphere(radius: 5, slices: 32, stacks: 24))
        let before = sphereBody.render.triangleCount
        XCTAssertGreaterThan(before, 100)
        let simplified = service.handle(action: "simplify", args: [
            "bodyID": sphereBody.id.raw.uuidString,
            "ratio": 0.25,
        ])
        XCTAssertEqual(simplified["ok"] as? Bool, true, simplified["message"] as? String ?? "")
        let simplifiedEntry = (simplified["bodies"] as? [[String: Any]])?.first
        let after = try XCTUnwrap(simplifiedEntry?["afterTriangles"] as? Int)
        XCTAssertGreaterThanOrEqual(after, 4)
        XCTAssertLessThan(after, before)
    }

    // MARK: 9. Combine / transform / material / image / text

    func testMeshCombineTransformMaterialAndUnavailableOps() async throws {
        let document = try await makeDocument("Combine")
        let service = CADMeshService(document: document)

        var offset = Transform3D.identity
        offset.translation = SIMD3(20, 0, 0)
        let first = addMeshBody(document, name: "C1",
                                mesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)))
        let second = addMeshBody(document, name: "C2",
                                 mesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                                 transform: offset)

        let combined = service.handle(action: "combine", args: [
            "bodyIDs": [first.id.raw.uuidString, second.id.raw.uuidString],
            "name": "Merged",
        ])
        XCTAssertEqual(combined["ok"] as? Bool, true, combined["message"] as? String ?? "")
        XCTAssertEqual(document.session.document.bodies.count, 1)
        let merged = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(MeasureKit.bodyVolume(merged.render), 2000, accuracy: 1e-3,
                       "world transforms must be applied before merging")

        let transformed = service.handle(action: "transform", args: [
            "bodyID": merged.id.raw.uuidString,
            "translate": [0, 10, 0],
            "rotate": ["axis": [0, 1, 0], "angleDegrees": 90],
            "scale": 2,
        ])
        XCTAssertEqual(transformed["ok"] as? Bool, true, transformed["message"] as? String ?? "")
        let movedBody = try XCTUnwrap(document.session.document.body(with: merged.id))
        XCTAssertEqual(movedBody.transform.translation.y, 10, accuracy: 1e-9)
        XCTAssertEqual(movedBody.transform.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(MeasureKit.volume(of: movedBody), 16000, accuracy: 0.05)

        let material = service.handle(action: "material", args: [
            "bodyID": merged.id.raw.uuidString,
            "color": [1, 0, 0],
            "metallic": 0.5,
            "roughness": 0.4,
            "opacity": 0.8,
        ])
        XCTAssertEqual(material["ok"] as? Bool, true, material["message"] as? String ?? "")
        let painted = try XCTUnwrap(document.session.document.body(with: merged.id))
        XCTAssertEqual(painted.material?.baseColor.x ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(painted.material?.baseColor.w ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(painted.material?.metallic ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(painted.material?.roughness ?? -1, 0.4, accuracy: 1e-9)

        // 1×1 transparent PNG, inline (no file paths anywhere).
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let image = service.handle(action: "image", args: [
            "bodyID": merged.id.raw.uuidString,
            "imageBase64": pngBase64,
        ])
        XCTAssertEqual(image["ok"] as? Bool, true, image["message"] as? String ?? "")
        XCTAssertNotNil(document.session.document.body(with: merged.id)?.material?.baseColorTexture)

        // Text has no standalone mesh path in this service; it must say so.
        let text = service.handle(action: "text", args: ["text": "F", "size": 10, "depth": 2])
        XCTAssertEqual(text["ok"] as? Bool, false)
        XCTAssertEqual(text["error"] as? String, "text_mesh_unavailable")
    }
}
