//
//  CADHoleWorkflowTests.swift
//  FloeCADKitTests
//
//  End-to-end native CAD workflow through the production facade/services:
//  a 100 × 60 × 10 mm plate with a Ø10 through-hole → resize the EXISTING
//  hole to Ø8 by editing the sketch circle's radius (the supported typed
//  route; `pushPull(.cylinderRadial)` is still an unimplemented tranche) →
//  small fillet → matte-metal material with a real PNG and box-projected UV
//  mapping → persisted daylight environment → actual viewport PNG → undo/redo
//  → save/reopen → actual GLB PBR/UV/texture bytes and a second actual PNG.
//
//  Coordinates/units: model space is +Y up in millimetres; the ground-plane
//  rectangle maps to x ∈ [0,100], z ∈ [-60,0], thickness along +Y. glTF is
//  metres/+Y, written by GLBExporter's 0.001 root scale.
//

import XCTest
import simd
import ImageIO
import CoreGraphics
@testable import FloeCAD

@MainActor
final class CADHoleWorkflowTests: XCTestCase {
    private var workDir: URL!

    // 1×1 PNG; a real image the material sniffer and GLB writer embed.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADHoleWorkflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            "the command reply was not a JSON object", file: file, line: line)
    }

    private func queryRows(_ document: FloeCADDocument, _ scope: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(outcome.isOK,
                      "query \(scope) failed: \(outcome.errorCode ?? "") \(outcome.message ?? "")",
                      file: file, line: line)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(object["rows"] as? [[String: Any]], file: file, line: line)
    }

    private func volume(_ document: FloeCADDocument, _ bodyID: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        XCTAssertTrue(outcome.isOK,
                      "measure \(bodyID) failed: \(outcome.errorCode ?? "") \(outcome.message ?? "")",
                      file: file, line: line)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(object["volumeMM3"] as? Double, file: file, line: line)
    }

    private func liveBodyID(_ document: FloeCADDocument,
                            file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let snapshot = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any],
            file: file, line: line)
        let bodies = try XCTUnwrap(snapshot["bodies"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(bodies.first?["id"] as? String, file: file, line: line)
    }

    private func firstBodyID(_ response: [String: Any]) -> String? {
        if let produced = (response["producedBodyIDs"] as? [String])?.first { return produced }
        return (response["changedBodyIDs"] as? [String])?.first
    }

    private func circleRadius(_ document: FloeCADDocument,
                              sketchID: String, entityID: String) -> Double? {
        guard let sketch = document.session.document.sketches.first(where: {
            $0.id.raw.uuidString == sketchID
        }), let entity = sketch.entities.first(where: { $0.id.uuidString == entityID }),
              case let .circle(_, _, radius) = entity else { return nil }
        return radius
    }

    private func glbJSON(_ glb: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        XCTAssertGreaterThan(length, 0)
        let jsonEnd = 20 + length
        XCTAssertLessThanOrEqual(jsonEnd + 8, glb.count)
        let json = glb.subdata(in: 20..<jsonEnd)
        // The binary chunk must be present with real payload bytes; a JSON-only
        // shell would not be a usable GLB.
        let binLength = Int(u32(jsonEnd))
        XCTAssertEqual(u32(jsonEnd + 4), GLBExporter.binChunkType)
        XCTAssertGreaterThan(binLength, 0)
        XCTAssertEqual(jsonEnd + 8 + binLength, glb.count)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func evidenceDirectory() throws -> URL {
        let directory = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("floe-cad-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Fixture

    func testPlateHoleResizeFilletMaterialEnvironmentUndoRedoAndPersistence() async throws {
        let url = workDir.appendingPathComponent("plate-workflow.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "PlateWorkflow")

        // 1. Plate: 100 × 60 rectangle on the ground plane, extruded 10 mm.
        let plateSketchID = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)
        let plateExtrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plateSketchID)","seedPoint":[50,30],
         "distance":10}}
        """)
        let plateBodyID = try XCTUnwrap(firstBodyID(plateExtrude))

        // 2. Hole: Ø10 circle fully inside the plate, symmetric subtract.
        let holeSketchID = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketchID)",
         "entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
        """)
        let holeCut = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeSketchID)","seedPoint":[50,30],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plateBodyID)"]}}
        """)
        XCTAssertNotEqual(holeCut["failed"] as? Bool, true,
                          "the hole subtract reported evaluation errors: \(holeCut)")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "the plate+hole fixture must rebuild clean: \(document.session.lastEvalErrors)")

        let bodiesAfterCut = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodyRows = try XCTUnwrap(bodiesAfterCut["bodies"] as? [[String: Any]])
        XCTAssertEqual(bodyRows.count, 1)
        XCTAssertEqual(bodyRows.first?["brep"] as? Bool, true,
                       "the plate+hole body must keep its analytic B-rep")
        let bodyID = try XCTUnwrap(bodyRows.first?["id"] as? String)

        let plateVolume = 100.0 * 60.0 * 10.0
        let hole10Volume = plateVolume - Double.pi * 5.0 * 5.0 * 10.0
        let hole8Volume = plateVolume - Double.pi * 4.0 * 4.0 * 10.0
        XCTAssertEqual(try volume(document, bodyID), hole10Volume, accuracy: 1e-3,
                       "the Ø10 hole must measure 60000−250π mm³")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)

        // 3. Discovery: query kind=sketches now exposes each entity's stable id
        //    and CURRENT circle radius. The original hole feature still points
        //    at this sketch; the edit changes the sketch input, not the graph.
        var sketchRows = try queryRows(document, "sketches")
        let holeSketchRow = try XCTUnwrap(sketchRows.first { ($0["id"] as? String) == holeSketchID })
        let entityRows = try XCTUnwrap(holeSketchRow["entityRows"] as? [[String: Any]])
        XCTAssertEqual(holeSketchRow["entities"] as? Int, 1)
        let circleRow = try XCTUnwrap(entityRows.first { ($0["kind"] as? String) == "circle" })
        XCTAssertEqual(circleRow["radius"] as? Double ?? -1, 5.0, accuracy: 1e-9)
        XCTAssertEqual(circleRow["diameterMM"] as? Double ?? -1, 10.0, accuracy: 1e-9)
        XCTAssertEqual(circleRow["parameter"] as? String, "radius")
        XCTAssertEqual(circleRow["update_action"] as? String, "updateSketchEntity")
        let entityID = try XCTUnwrap(circleRow["id"] as? String)

        var featureRows = try queryRows(document, "features")
        let holeFeatureRow = try XCTUnwrap(featureRows.first {
            (($0["referencedSketches"] as? [String]) ?? []).contains(holeSketchID)
        })
        let holeFeatureID = try XCTUnwrap(holeFeatureRow["id"] as? String)
        XCTAssertEqual(holeFeatureRow["kind"] as? String, "extrude")
        let holeDependencies = try XCTUnwrap(holeFeatureRow["dependencies"] as? [String: Any])
        XCTAssertEqual(holeDependencies["sketch_ids"] as? [String], [holeSketchID],
                       "the cut must depend on the hole sketch before the edit")

        // 4. The cylindrical face is discoverable with its actual radius and a
        //    current generation token. (This is the data a radial face edit
        //    would need; the graph intentionally still rejects cylinderRadial,
        //    so the supported route below edits the sketch circle instead.)
        var faceRows = try queryRows(document, "faces")
        let cylinderBefore = try XCTUnwrap(faceRows.first {
            ($0["kind"] as? String) == "cylindrical"
                && abs(($0["radiusMM"] as? Double ?? -1) - 5.0) < 1e-6
        })
        let bodyUUID = try XCTUnwrap(UUID(uuidString: bodyID))
        let liveBody = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == bodyUUID })
        let faceToken = try XCTUnwrap(CADGeometryQueryGeneration.parse(
            try XCTUnwrap(cylinderBefore["query_token"] as? String)))
        XCTAssertTrue(faceToken.matches(documentRevision: document.revision,
                                        changeCount: document.session.changeCount,
                                        bodyID: liveBody.id.raw,
                                        meshRevision: liveBody.meshRevision),
                      "the face row must carry a CURRENT generation token")

        // 5. Resize the EXISTING hole: Ø10 → Ø8 by setting the circle radius
        //    5 → 4 with the radius read above as the optimistic fence.
        let parameters = CADParameterService(document: document)
        let changeBeforeStaleEdit = document.session.changeCount
        let staleResize = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": holeSketchID,
            "entity_id": entityID,
            "radius": 4.0,
            "expected_radius": 6.0,
        ])
        XCTAssertEqual(staleResize["ok"] as? Bool, false,
                       "a stale expected radius must be refused: \(staleResize)")
        XCTAssertEqual(staleResize["error"] as? String, "radius_mismatch")
        XCTAssertEqual(document.session.changeCount, changeBeforeStaleEdit,
                       "a refused radius fence must not mutate the document")
        XCTAssertEqual(circleRadius(document, sketchID: holeSketchID, entityID: entityID) ?? -1,
                       5.0, accuracy: 1e-9)

        let resize = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": holeSketchID,
            "entity_id": entityID,
            "radius": 4.0,
            "expected_radius": 5.0,
        ])
        XCTAssertEqual(resize["ok"] as? Bool, true, "\(resize)")
        XCTAssertEqual(resize["mutated"] as? Bool, true)
        let resizedEntity = try XCTUnwrap(resize["entity"] as? [String: Any])
        XCTAssertEqual(resizedEntity["id"] as? String, entityID)
        XCTAssertEqual(resizedEntity["old_radius"] as? Double ?? -1, 5.0, accuracy: 1e-9)
        XCTAssertEqual(resizedEntity["radius"] as? Double ?? -1, 4.0, accuracy: 1e-9)
        XCTAssertEqual(resizedEntity["diameter"] as? Double ?? -1, 8.0, accuracy: 1e-9)
        let dependentIDs = try XCTUnwrap(resize["dependent_feature_ids"] as? [String])
        XCTAssertTrue(dependentIDs.contains(holeFeatureID),
                      "the hole cut must be rebuilt as a dependent feature")

        XCTAssertEqual(try liveBodyID(document), bodyID,
                       "resizing the hole must keep the SAME body, not replace it")
        XCTAssertEqual(circleRadius(document, sketchID: holeSketchID, entityID: entityID) ?? -1,
                       4.0, accuracy: 1e-9)
        XCTAssertEqual(try volume(document, bodyID), hole8Volume, accuracy: 1e-3,
                       "the Ø8 hole must measure 60000−160π mm³")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "the rewritten hole must rebuild clean: \(document.session.lastEvalErrors)")

        // Dependency identity survived: same feature, same sketch ref.
        featureRows = try queryRows(document, "features")
        let holeFeatureAfter = try XCTUnwrap(featureRows.first { ($0["id"] as? String) == holeFeatureID })
        XCTAssertEqual(holeFeatureAfter["kind"] as? String, "extrude")
        XCTAssertEqual((holeFeatureAfter["referencedSketches"] as? [String]) ?? [], [holeSketchID])
        XCTAssertEqual(((holeFeatureAfter["dependencies"] as? [String: Any])?["sketch_ids"] as? [String]) ?? [],
                       [holeSketchID])

        // Re-query proves the stored geometry and face radius actually moved.
        sketchRows = try queryRows(document, "sketches")
        let resizedPlotRow = try XCTUnwrap(sketchRows.first { ($0["id"] as? String) == holeSketchID })
        let resizedEntityRows = try XCTUnwrap(resizedPlotRow["entityRows"] as? [[String: Any]])
        let resizedCircle = try XCTUnwrap(resizedEntityRows.first { ($0["id"] as? String) == entityID })
        XCTAssertEqual(resizedCircle["radius"] as? Double ?? -1, 4.0, accuracy: 1e-9)
        faceRows = try queryRows(document, "faces")
        XCTAssertNotNil(faceRows.first {
            ($0["kind"] as? String) == "cylindrical"
                && abs(($0["radiusMM"] as? Double ?? -1) - 4.0) < 1e-6
        }, "query kind=faces must report the rebuilt Ø8 cylinder, not the old radius")

        // 6. Undo/redo the diameter edit (one step): exact volumes both ways.
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(circleRadius(document, sketchID: holeSketchID, entityID: entityID) ?? -1,
                       5.0, accuracy: 1e-9)
        XCTAssertEqual(try volume(document, bodyID), hole10Volume, accuracy: 1e-3)
        XCTAssertEqual(parameters.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(circleRadius(document, sketchID: holeSketchID, entityID: entityID) ?? -1,
                       4.0, accuracy: 1e-9)
        XCTAssertEqual(try volume(document, bodyID), hole8Volume, accuracy: 1e-3)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)

        // 7. Fillet one vertical outer corner edge (midpoint (0, 5, 0)) by 2 mm.
        //    The edge index is addressed through the current edges token.
        let edgeRows = try queryRows(document, "edges")
        let bodyEdgeRow = try XCTUnwrap(edgeRows.first { ($0["bodyID"] as? String) == bodyID })
        let edgeToken = try XCTUnwrap(bodyEdgeRow["query_token"] as? String)
        let edgeList = try XCTUnwrap(bodyEdgeRow["edges"] as? [[String: Any]])
        let corner = try XCTUnwrap(edgeList.compactMap { row -> (row: [String: Any], distance: Double)? in
            guard let values = row["midpoint"] as? [Double], values.count == 3 else { return nil }
            let midpoint = SIMD3<Double>(values[0], values[1], values[2])
            return (row, simd_length(midpoint - SIMD3<Double>(0, 5, 0)))
        }.min { $0.distance < $1.distance }?.row)
        let cornerDistance = try XCTUnwrap((corner["midpoint"] as? [Double]).map {
            simd_length(SIMD3<Double>($0[0], $0[1], $0[2]) - SIMD3<Double>(0, 5, 0))
        })
        XCTAssertLessThan(cornerDistance, 0.5, "the fillet edge must be the vertical corner at (0,5,0)")
        let cornerIndex = try XCTUnwrap(corner["index"] as? Int)

        let filletCommand = """
        {"op":"feature.fillet","args":{"bodyID":"\(bodyID)","edges":[\(cornerIndex)],
         "radius":2,"query_token":"\(edgeToken)"}}
        """
        try CADStaleReferenceGuard.validate(operationJSON: filletCommand, document: document)
        let filletReply = try run(document, filletCommand)
        XCTAssertNotEqual(filletReply["failed"] as? Bool, true,
                          "the small fillet reported evaluation errors: \(filletReply)")
        XCTAssertNil(filletReply["evalErrors"], "\(filletReply)")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        XCTAssertEqual(try liveBodyID(document), bodyID, "the fillet must keep the same body")

        let volumeAfterFillet = try volume(document, bodyID)
        // A 2 mm round on a 90° straight corner of a 10 mm edge removes
        // r²(1 − π/4) · length = 10·(4 − π) mm³.
        let expectedFilletRemoval = 10.0 * (4.0 - Double.pi)
        XCTAssertEqual(hole8Volume - volumeAfterFillet, expectedFilletRemoval, accuracy: 0.1,
                       "the fillet must remove the exact corner round volume")

        let filletRows = try queryRows(document, "features")
        let filletRow = try XCTUnwrap(filletRows.first { ($0["kind"] as? String) == "fillet" })
        XCTAssertEqual(filletRow["update_supported"] as? Bool, true)
        let filletParameters = try XCTUnwrap(filletRow["parameters"] as? [[String: Any]])
        let filletRadiusRow = try XCTUnwrap(filletParameters.first {
            ($0["name"] as? String) == "radius"
        })
        XCTAssertEqual(filletRadiusRow["value"] as? Double ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(filletRadiusRow["unit"] as? String, "mm")
        let filletEdgeCountRow = try XCTUnwrap(filletParameters.first {
            ($0["name"] as? String) == "edge_count"
        })
        XCTAssertEqual(filletEdgeCountRow["value"] as? Int ?? -1, 1)

        // One undo removes the fillet + its rebuild; redo restores it.
        document.session.undo()
        XCTAssertEqual(try volume(document, bodyID), hole8Volume, accuracy: 1e-3)
        XCTAssertFalse(document.session.document.features.nodes.contains { node in
            if case .fillet = node.kind { return true }
            return false
        })
        document.session.redo()
        XCTAssertEqual(try volume(document, bodyID), volumeAfterFillet, accuracy: 0.1)
        XCTAssertTrue(document.session.document.features.nodes.contains { node in
            if case .fillet = node.kind { return true }
            return false
        })

        // 8. Matte-metal material with a real PNG and box-projected UV mapping.
        let materials = CADMaterialService(document: document)
        let created = materials.handle(action: "create", args: [
            "name": "Matte Aluminum",
            "color": [0.72, 0.74, 0.78, 1.0],
            "metallic": 0.92,
            "roughness": 0.68,
            "textures": [["slot": "baseColor",
                          "base64": png.base64EncodedString()] as [String: Any]],
            "uv_mapping": ["source": "boxProjection", "axis": "y",
                           "scale_mm": [60.0, 40.0], "rotation_degrees": 15.0,
                           "offset": [0.1, -0.2]],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let materialID = try XCTUnwrap(created["id"] as? String)
        let applied = materials.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")

        var appliedBody = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw == bodyUUID
        })
        XCTAssertEqual(appliedBody.material?.materialID, materialID)
        XCTAssertEqual(appliedBody.material?.materialName, "Matte Aluminum")
        XCTAssertEqual(appliedBody.material?.baseColorTexture, png,
                       "the applied snapshot must carry the actual PNG bytes")
        XCTAssertEqual(appliedBody.material?.metallic ?? -1, 0.92, accuracy: 1e-12)
        XCTAssertEqual(appliedBody.material?.roughness ?? -1, 0.68, accuracy: 1e-12)
        XCTAssertEqual(appliedBody.material?.uvMapping?.source, .boxProjection)
        XCTAssertEqual(appliedBody.material?.uvMapping?.axis, .y)
        XCTAssertEqual(appliedBody.material?.uvMapping?.scaleMM, SIMD2(60, 40))

        // Material apply is one undo step; redo restores the exact snapshot.
        XCTAssertEqual(materials.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertNil(document.session.document.bodies.first { $0.id.raw == bodyUUID }?.material)
        XCTAssertEqual(materials.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        appliedBody = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == bodyUUID })
        XCTAssertEqual(appliedBody.material?.materialID, materialID)
        XCTAssertEqual(appliedBody.material?.baseColorTexture, png)

        // 9. Persisted environment: a custom daylight studio.
        var appearance = CADViewAppearance()
        appearance.activeEnvironment = .daylight
        appearance.daylight = CADViewEnvironmentSettings(
            lightIntensity: 2.1, lightDirection: [0.2, 0.9, 0.4],
            backgroundColor: [0.55, 0.7, 0.85])
        appearance.floorVisible = false
        appearance.floorSizeMM = 500
        appearance.shadowsEnabled = false
        let expectedAppearance = appearance.sanitized
        XCTAssertTrue(document.applyViewAppearance(appearance))
        XCTAssertEqual(document.viewAppearance, expectedAppearance)

        // 10. Actual viewport PNG (engineering Metal capture, never fabricated).
        let capture = try document.captureViewportPNG(width: 640, height: 480)
        XCTAssertEqual(capture.renderer, "engineering")
        XCTAssertEqual(capture.revision, document.revision)
        XCTAssertEqual(capture.changeCount, document.session.changeCount)
        XCTAssertEqual(capture.width, 640)
        XCTAssertEqual(capture.height, 480)
        XCTAssertEqual(capture.sha256, CADMaterialTexture.digest(capture.pngData))
        XCTAssertEqual(capture.sha256.count, 64)
        XCTAssertEqual(capture.contentSHA256.count, 64)
        XCTAssertNotEqual(capture.contentSHA256, capture.sha256,
                          "the package identity must stay separate from the image digest")
        XCTAssertEqual(Array(capture.pngData.prefix(8)),
                       [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                       "capture must return real PNG bytes")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(capture.pngData as CFData, nil))
        let capturedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(capturedImage.width, capture.width)
        XCTAssertEqual(capturedImage.height, capture.height)

        // 11. Undo/redo AFTER the viewport image: the last edit is the
        //     environment, so one undo returns to the document default and
        //     redo restores the exact persisted appearance.
        document.session.undo()
        XCTAssertEqual(document.viewAppearance, .default)
        document.session.redo()
        XCTAssertEqual(document.viewAppearance, expectedAppearance)

        // 12. Save and reopen: same body, same geometry, same material,
        //     same appearance, same feature dependencies.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        XCTAssertGreaterThan(save.revision, 0)
        XCTAssertEqual(save.contentSHA256.count, 64)
        let savedRevision = save.revision
        let savedContentSHA = save.contentSHA256
        let savedVolume = try volume(document, bodyID)
        XCTAssertEqual(savedVolume, volumeAfterFillet, accuracy: 0.1)
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertFalse(reopened.isReadOnly)
        XCTAssertEqual(reopened.revision, savedRevision)
        XCTAssertEqual(reopened.contentSHA256, savedContentSHA)
        XCTAssertEqual(reopened.session.document.bodies.count, 1)
        XCTAssertEqual(try liveBodyID(reopened), bodyID,
                       "save/reopen must preserve the SAME body identity")
        XCTAssertEqual(try volume(reopened, bodyID), savedVolume, accuracy: 0.1)
        XCTAssertEqual(circleRadius(reopened, sketchID: holeSketchID, entityID: entityID) ?? -1,
                       4.0, accuracy: 1e-9,
                       "the Ø8 sketch circle must persist")
        XCTAssertEqual(reopened.viewAppearance, expectedAppearance,
                       "the daylight environment must persist")

        let reopenedBody = try XCTUnwrap(reopened.session.document.bodies.first {
            $0.id.raw == bodyUUID
        })
        XCTAssertEqual(reopenedBody.material?.materialID, materialID)
        XCTAssertEqual(reopenedBody.material?.baseColorTexture, png)
        XCTAssertEqual(reopenedBody.material?.materialName, "Matte Aluminum")
        XCTAssertEqual(reopenedBody.material?.metallic ?? -1, 0.92, accuracy: 1e-12)
        XCTAssertEqual(reopenedBody.material?.roughness ?? -1, 0.68, accuracy: 1e-12)
        XCTAssertEqual(reopenedBody.material?.uvMapping?.source, .boxProjection)

        let reopenedFillet = try XCTUnwrap(reopened.session.document.features.nodes.first { node in
            if case .fillet = node.kind { return true }
            return false
        })
        guard case let .fillet(_, filletEdges, filletRadius) = reopenedFillet.kind else {
            return XCTFail("the reopened feature is no longer a fillet")
        }
        XCTAssertEqual(filletEdges.count, 1)
        XCTAssertEqual(filletRadius.value, 2.0, accuracy: 1e-9)
        let reopenedHoleSketchID = try XCTUnwrap(UUID(uuidString: holeSketchID))
        let reopenedHoleFeature = reopened.session.document.features.nodes.first {
            $0.referencedSketchIDs.contains(SketchID(raw: reopenedHoleSketchID))
        }
        XCTAssertEqual(reopenedHoleFeature?.id.raw.uuidString, holeFeatureID,
                       "the original hole feature dependency must survive save/reopen")

        // 13. Reopened actual viewport PNG + GLB bytes.
        let reopenedCapture = try reopened.captureViewportPNG(width: 640, height: 480)
        XCTAssertEqual(reopenedCapture.renderer, "engineering")
        XCTAssertEqual(reopenedCapture.revision, reopened.revision)
        XCTAssertEqual(reopenedCapture.changeCount, reopened.session.changeCount)
        XCTAssertEqual(reopenedCapture.sha256, CADMaterialTexture.digest(reopenedCapture.pngData))
        XCTAssertEqual(Array(reopenedCapture.pngData.prefix(8)),
                       [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let glb = try reopened.nativeExportData(format: "glb", pageID: nil).get().data
        XCTAssertGreaterThan(glb.count, 20)
        let json = try glbJSON(glb)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let root = try XCTUnwrap(nodes.last)
        XCTAssertEqual(root["name"] as? String, "FloeRoot")
        XCTAssertEqual(root["scale"] as? [Double], [0.001, 0.001, 0.001],
                       "glTF is metres with the explicit mm → m root scale")
        let rootExtras = try XCTUnwrap(root["extras"] as? [String: Any])
        XCTAssertEqual(rootExtras["floe_source_units"] as? String, "millimetres")
        XCTAssertEqual(rootExtras["floe_source_up_axis"] as? String, "+Y")

        let glbMaterials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        let glbMaterial = try XCTUnwrap(glbMaterials.first {
            ($0["name"] as? String) == "Matte Aluminum"
        }, "the applied material must be exported by its real name")
        let pbr = try XCTUnwrap(glbMaterial["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double ?? -1, 0.92, accuracy: 1e-6)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double ?? -1, 0.68, accuracy: 1e-6)
        XCTAssertNotNil(pbr["baseColorTexture"])
        let glbImages = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertTrue(glbImages.contains { ($0["mimeType"] as? String) == "image/png" },
                      "the actual PNG must be embedded in the GLB")
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes.first?["primitives"] as? [[String: Any]])
        let attributes = try XCTUnwrap(primitives.first?["attributes"] as? [String: Any])
        let uvAccessor = try XCTUnwrap(attributes["TEXCOORD_0"] as? Int)
        let positionAccessor = try XCTUnwrap(attributes["POSITION"] as? Int)
        XCTAssertNotNil(primitives.first?["material"])
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors[uvAccessor]["type"] as? String, "VEC2")
        let uvCount = try XCTUnwrap(accessors[uvAccessor]["count"] as? Int)
        let positionCount = try XCTUnwrap(accessors[positionAccessor]["count"] as? Int)
        XCTAssertGreaterThan(uvCount, 0)
        XCTAssertEqual(uvCount, positionCount,
                       "every exported vertex must carry one UV pair")

        // Write the actual deliverables for the unified runner to inspect.
        let evidence = try evidenceDirectory()
        let pngURL = evidence.appendingPathComponent("plate-workflow-hole8-fillet.png")
        try reopenedCapture.pngData.write(to: pngURL, options: .atomic)
        print("FLOE_CAD_WORKFLOW_PNG \(pngURL.path)")
        let glbURL = evidence.appendingPathComponent("plate-workflow-hole8-fillet.glb")
        try glb.write(to: glbURL, options: .atomic)
        print("FLOE_CAD_WORKFLOW_GLB \(glbURL.path)")
        XCTAssertEqual(try Data(contentsOf: pngURL), reopenedCapture.pngData)
        XCTAssertEqual(try Data(contentsOf: glbURL), glb)

        reopened.close()
    }
}
