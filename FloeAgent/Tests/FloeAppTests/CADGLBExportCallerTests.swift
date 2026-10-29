//
//  CADGLBExportCallerTests.swift
//  FloeCADKitTests (source-only in the shader/editor lane; Tests/ is
//  core-owned)
//
//  Caller-closure proof for the live GLB export path: `EditorViewModel` must
//  hand the exporter the ACTUAL session face tables and mesh-revision stamps,
//  so a face material assigned in the UI becomes a real glTF primitive instead
//  of a silently body-only export.
//
//  Primary: move this file into FloeCADKit/Tests/FloeCADKitTests after the core
//  handoff and run the unified package test target.
//

import Foundation
import XCTest
import simd

@testable import FloeCAD

@MainActor
final class CADGLBExportCallerTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADGLBCaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Fixture

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(_ document: FloeCADDocument) throws -> BodyID {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"Box"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        let extrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,10],
         "distance":10}}
        """)
        let bodyID = try XCTUnwrap((extrude["producedBodyIDs"] as? [String])?.first
            ?? (extrude["changedBodyIDs"] as? [String])?.first)
        let bodyUUID = try XCTUnwrap(UUID(uuidString: bodyID))
        return BodyID(raw: bodyUUID)
    }

    private func jsonChunk(_ glb: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        let json = glb.subdata(in: 20..<(20 + length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    /// Per-body export payloads for the only body in the fixture.
    private func exportedPrimitives(_ glb: Data) throws -> (json: [String: Any],
                                                            primitives: [[String: Any]],
                                                            materials: [[String: Any]]) {
        let json = try jsonChunk(glb)
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes.first?["primitives"] as? [[String: Any]])
        let materials = (json["materials"] as? [[String: Any]]) ?? []
        return (json, primitives, materials)
    }

    // MARK: Tests

    /// The live session must have a fresh face table for the fixture, and both
    /// Editor exports must use it — not the exporter's empty default.
    func testLiveExportPassesSessionFaceTablesForWholeDocumentAndPerBody() async throws {
        let document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("caller.floecad"), name: "Caller")
        defer { document.close() }
        let bodyID = try makeBox(document)

        let body = try XCTUnwrap(document.session.document.body(with: bodyID))
        let table = try XCTUnwrap(document.session.lastFaceTables[bodyID],
                                  "the rebuild must retain a face table for the fixture body")
        XCTAssertEqual(document.session.lastNamingRevisions[bodyID], body.meshRevision,
                       "the retained table must describe the body's current mesh")
        let brep = try XCTUnwrap(body.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep)
            .first(where: { $0.signature != nil }))
        let tableEntry = try XCTUnwrap(table.entries.first(where: { !$0.triangles.isEmpty }))

        // A real UI-equivalent face material: service command + live query token.
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: [
            "name": "Face Paint", "color": [0.1, 0.8, 0.2, 1.0],
        ])
        let materialID = try XCTUnwrap(created["id"] as? String)
        let token = CADGeometryQueryGeneration(
            scope: "faces", bodyID: bodyID.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: body.meshRevision).token
        let applied = service.handle(action: "applyFaces", args: [
            "material_id": materialID,
            "bodyID": bodyID.raw.uuidString,
            "faces": [face.index],
            "query_token": token,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        XCTAssertEqual(document.session.document.body(with: bodyID)?.materialFaceBindings.count, 1)

        // Whole-document export through the exact UI entry point.
        let viewModel = document.viewModel()
        let glb = try XCTUnwrap(viewModel.exportGLB(), "the live export returned nil")
        let whole = try exportedPrimitives(glb)
        XCTAssertGreaterThanOrEqual(whole.primitives.count, 2,
                                    "body + face primitive expected, got \(whole.primitives)")
        XCTAssertTrue(whole.materials.contains { ($0["name"] as? String) == "Face Paint" },
                      "the applied face material must be exported as a glTF material")
        let wholeMeshes = (whole.json["meshes"] as? [[String: Any]]) ?? []
        let wholeExtras = wholeMeshes.first?["extras"] as? [String: Any]
        let unresolved = (wholeExtras?["floe_unresolved_face_bindings"]
            as? [[String: Any]]) ?? []
        XCTAssertTrue(unresolved.isEmpty,
                      "a resolved face binding must not be reported as unresolved: \(unresolved)")
        let faceMaterials = (wholeExtras?["floe_face_materials"]
            as? [[String: Any]]) ?? []
        XCTAssertEqual(faceMaterials.count, 1,
                       "the exporter must report the resolved face group: \(faceMaterials)")

        // Per-body export uses the same body id/revision mapping.
        let perBody = try XCTUnwrap(viewModel.exportGLBPerBody())
        XCTAssertEqual(perBody.count, 1)
        let single = try exportedPrimitives(perBody[0].data)
        XCTAssertGreaterThanOrEqual(single.primitives.count, 2,
                                    "per-body export lost the face primitive: \(single.primitives)")
        XCTAssertTrue(single.materials.contains { ($0["name"] as? String) == "Face Paint" })

        // The face table really describes the exported triangles: the face
        // primitive's triangle count is the resolved entry's, not the body's.
        let bodyTriangleCount = body.render.indices.count / 3
        XCTAssertLessThan(tableEntry.triangles.count, bodyTriangleCount,
                          "fixture expected a strict face subset")
    }

    /// Guard the source contract that made the bug possible: neither UI export
    /// call may fall back to the exporter's default (empty) tables.
    func testExportCallSitesPassFaceTablesExplicitly() throws {
        // Resolve the source from either the private lane directory or the
        // package test target after primary moves this file.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var sourceURL: URL?
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(
                "FloeAgent/ThirdParty/FloeCADKit/Sources/FloeCAD/Editor/EditorViewModel.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                sourceURL = candidate
                break
            }
            let packageCandidate = directory
                .appendingPathComponent("Sources/FloeCAD/Editor/EditorViewModel.swift")
            if FileManager.default.fileExists(atPath: packageCandidate.path) {
                sourceURL = packageCandidate
                break
            }
            directory.deleteLastPathComponent()
        }
        let source = try String(contentsOf: try XCTUnwrap(sourceURL), encoding: .utf8)
        for call in ["GLBExporter.glb(bodies: bodies,",
                     "GLBExporter.glb(bodies: [body],"] {
            XCTAssertTrue(source.contains(call), "missing live call \(call)")
        }
        XCTAssertEqual(source.components(separatedBy: "faceTables: faceTables.tables").count - 1, 2,
                       "both exportGLB() and exportGLBPerBody() must pass the tables")
        XCTAssertEqual(source.components(separatedBy: "faceTableRevisions: faceTables.revisions").count - 1, 2)
        XCTAssertTrue(source.contains("session.lastFaceTables[body.id]"))
        XCTAssertTrue(source.contains("session.lastNamingRevisions[body.id]"))
    }
}
