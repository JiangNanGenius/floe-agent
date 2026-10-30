//
//  CADSketchEntityEditingTests.swift
//  FloeCADKitTests
//
//  M01: continued editing of EXISTING arc, ellipse and spline entities by
//  stable id, plus explicit single-entity deletion. These tests drive the real
//  production services (`CADParameterService`, the native query, the solver
//  residual gate, the undo stack and the package round-trip) — no fake
//  renderer and no helper that merely mirrors the implementation.
//
//  The sketch stores arc angles and ellipse rotation in radians; the typed
//  edit contract is degrees, exactly like `setSketchDimension` and the UI.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADSketchEntityEditingTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADSketchEntityEditing-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func makeDocument(_ name: String = "EntityEditing") async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
    }

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

    private func sketchRow(_ document: FloeCADDocument, sketchID: String) throws -> [String: Any] {
        let rows = try queryRows(document, "sketches")
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == sketchID })
    }

    private func entityRows(_ document: FloeCADDocument, sketchID: String) throws -> [[String: Any]] {
        let row = try sketchRow(document, sketchID: sketchID)
        return try XCTUnwrap(row["entityRows"] as? [[String: Any]])
    }

    private func entityRow(_ document: FloeCADDocument, sketchID: String,
                           entityID: String) throws -> [String: Any] {
        let rows = try entityRows(document, sketchID: sketchID)
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == entityID })
    }

    private func addSketch(_ document: FloeCADDocument, name: String,
                           entities: String) throws -> (sketchID: String, entityIDs: [String]) {
        let created = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(created["sketchID"] as? String)
        _ = try run(document, #"{"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":\#(entities)}}"#)
        let rows = try entityRows(document, sketchID: sketchID)
        return (sketchID, rows.compactMap { $0["id"] as? String })
    }

    private func firstID(of kind: String, in rows: [[String: Any]]) throws -> String {
        try XCTUnwrap(rows.first { ($0["kind"] as? String) == kind }?["id"] as? String,
                      "missing \(kind) entity row")
    }

    private struct MixedSketch {
        var sketchID: String
        var arcID: String
        var ellipseID: String
        var splineID: String
        var lineID: String
    }

    private func makeMixedSketch(_ document: FloeCADDocument,
                                 name: String = "Mixed") throws -> MixedSketch {
        let created = try addSketch(
            document, name: name,
            entities: #"""
            [{"kind":"arc","center":[0,0],"radius":10,"startAngle":0,"endAngle":1.5707963267948966},
             {"kind":"ellipse","center":[30,0],"radiusX":5,"radiusY":3,"rotation":0},
             {"kind":"spline","points":[[0,20],[5,25],[10,20],[15,25]],"closed":false},
             {"kind":"line","a":[0,40],"b":[10,40]}]
            """#)
        let rows = try entityRows(document, sketchID: created.sketchID)
        return MixedSketch(
            sketchID: created.sketchID,
            arcID: try firstID(of: "arc", in: rows),
            ellipseID: try firstID(of: "ellipse", in: rows),
            splineID: try firstID(of: "spline", in: rows),
            lineID: try firstID(of: "line", in: rows))
    }

    private func dimensionRow(_ document: FloeCADDocument, id: String) throws -> [String: Any] {
        let rows = try queryRows(document, "constraints")
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == id })
    }

    private func volume(_ document: FloeCADDocument, bodyID: String) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        XCTAssertTrue(outcome.isOK, "measure failed: \(outcome.errorCode ?? "")")
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
        return try XCTUnwrap(object["volumeMM3"] as? Double)
    }

    private func firstBodyID(_ document: FloeCADDocument) throws -> String {
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodies = try XCTUnwrap(object["bodies"] as? [[String: Any]])
        return try XCTUnwrap(bodies.first?["id"] as? String)
    }

    // MARK: - Query / update contract

    func testQueryAdvertisesOnlyRealArcEllipseSplineEdits() async throws {
        let document = try await makeDocument()
        let mixed = try makeMixedSketch(document)
        let service = CADParameterService(document: document)

        XCTAssertTrue(CADParameterService.actions.contains("updateSketchEntity"))
        XCTAssertTrue(CADParameterService.actions.contains("deleteSketchEntity"))
        XCTAssertEqual(CADParameterService.editableSketchEntityKinds,
                       Set(["line", "rect", "circle", "arc", "ellipse", "spline"]))

        let list = service.handle(action: "list", args: [:])
        XCTAssertEqual(list["ok"] as? Bool, true, "\(list)")
        let update = try XCTUnwrap(list["sketch_entity_update"] as? [String: Any])
        XCTAssertEqual(update["action"] as? String, "updateSketchEntity")
        XCTAssertEqual(Set(try XCTUnwrap(update["supported_entity_kinds"] as? [String])),
                       ["line", "rect", "circle", "arc", "ellipse", "spline"])
        let delete = try XCTUnwrap(list["sketch_entity_delete"] as? [String: Any])
        XCTAssertEqual(delete["action"] as? String, "deleteSketchEntity")

        let arc = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.arcID)
        XCTAssertEqual(arc["editable"] as? Bool, true)
        XCTAssertEqual(arc["update_action"] as? String, "updateSketchEntity")
        XCTAssertEqual(try XCTUnwrap(arc["update_fields"] as? [String]),
                       ["center", "radius", "diameter", "start_angle_deg",
                        "end_angle_deg", "sweep_angle_deg"])
        XCTAssertEqual(arc["delete_action"] as? String, "deleteSketchEntity")
        XCTAssertEqual(arc["sweepAngleDegrees"] as? Double ?? -1, 90, accuracy: 1e-6)

        let ellipse = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.ellipseID)
        XCTAssertEqual(ellipse["editable"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(ellipse["update_fields"] as? [String]),
                       ["center", "radius_x", "radius_y", "rotation_deg"])
        XCTAssertEqual(ellipse["rotationDegrees"] as? Double ?? 1, 0, accuracy: 1e-9)

        let spline = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.splineID)
        XCTAssertEqual(spline["editable"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(spline["update_fields"] as? [String]),
                       ["points", "point_index", "point"])
        XCTAssertEqual(spline["pointCount"] as? Int, 4)
        XCTAssertEqual(spline["points"] as? [[Double]],
                       [[0, 20], [5, 25], [10, 20], [15, 25]])
        XCTAssertEqual(spline["point_identity"] as? String, "zero-based index in points")

        // The native hit-testing surface used by the live sketch editor exposes
        // every spline fit point (not only its two ends) with stable indices.
        let entity = try XCTUnwrap(document.session.document.sketches
            .first { $0.id.raw.uuidString == mixed.sketchID }?
            .entities.first { $0.id.uuidString == mixed.splineID })
        let handles = SketchHitTester.controlPoints(of: entity)
        XCTAssertEqual(handles.count, 4)
        XCTAssertEqual(handles[0].kind, .lineStart)
        XCTAssertEqual(handles[1].kind, .splinePoint(1))
        XCTAssertEqual(handles[2].kind, .splinePoint(2))
        XCTAssertEqual(handles[3].kind, .lineEnd)
    }

    // MARK: - Arc / ellipse / spline edits

    func testMixedArcEllipseSplineEditsPreserveIdentityConstraintsAndUndo() async throws {
        let document = try await makeDocument()
        let mixed = try makeMixedSketch(document)
        let service = CADParameterService(document: document)
        let baselineRows = try entityRows(document, sketchID: mixed.sketchID)
        let baselineIDs = baselineRows.compactMap { $0["id"] as? String }
        XCTAssertEqual(baselineIDs.count, 4)

        // An unrelated line dimension must survive every edit below untouched.
        let lineDimension = service.handle(action: "setSketchDimension", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.lineID,
            "kind": "length",
            "value": 10,
        ])
        XCTAssertEqual(lineDimension["ok"] as? Bool, true, "\(lineDimension)")
        let lineDimensionID = try XCTUnwrap(
            (lineDimension["dimension"] as? [String: Any])?["id"] as? String)

        // An arc angle dimension is a matching driving value: changing the
        // arc sweep updates it in the SAME undo step instead of going stale.
        let arcAngle = service.handle(action: "setSketchDimension", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
            "kind": "angle",
            "value": 90,
        ])
        XCTAssertEqual(arcAngle["ok"] as? Bool, true, "\(arcAngle)")
        let arcDimensionID = try XCTUnwrap(
            (arcAngle["dimension"] as? [String: Any])?["id"] as? String)

        // 1. Arc angle (start 0° -> 30°, end 90° -> 150°; sweep 90° -> 120°).
        let arcEdit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
            "start_angle_deg": 30.0,
            "end_angle_deg": 150.0,
            "expected_start_angle_deg": 0.0,
            "expected_end_angle_deg": 90.0,
            "expected_sweep_angle_deg": 90.0,
        ])
        XCTAssertEqual(arcEdit["ok"] as? Bool, true, "\(arcEdit)")
        XCTAssertEqual(arcEdit["mutated"] as? Bool, true)
        XCTAssertEqual((arcEdit["entity"] as? [String: Any])?["kind"] as? String, "arc")
        var arcRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.arcID)
        XCTAssertEqual(arcRow["id"] as? String, mixed.arcID)
        XCTAssertEqual(arcRow["startAngleDegrees"] as? Double ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(arcRow["endAngleDegrees"] as? Double ?? -1, 150, accuracy: 1e-6)
        XCTAssertEqual(arcRow["sweepAngleDegrees"] as? Double ?? -1, 120, accuracy: 1e-6)
        XCTAssertEqual(arcRow["radius"] as? Double ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(arcEdit["updated_dimension_ids"] as? [String]),
                       [arcDimensionID])
        let updatedArcDimension = try dimensionRow(document, id: arcDimensionID)
        XCTAssertEqual(updatedArcDimension["display_value"] as? Double ?? -1, 120, accuracy: 1e-6)

        // 2. Ellipse axes + rotation, same stable id.
        let ellipseEdit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.ellipseID,
            "radius_x": 8.0,
            "radius_y": 4.0,
            "rotation_deg": 30.0,
            "expected_radius_x": 5.0,
            "expected_radius_y": 3.0,
            "expected_rotation_deg": 0.0,
        ])
        XCTAssertEqual(ellipseEdit["ok"] as? Bool, true, "\(ellipseEdit)")
        var ellipseRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.ellipseID)
        XCTAssertEqual(ellipseRow["id"] as? String, mixed.ellipseID)
        XCTAssertEqual(ellipseRow["radiusX"] as? Double ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(ellipseRow["radiusY"] as? Double ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(ellipseRow["rotationDegrees"] as? Double ?? -1, 30, accuracy: 1e-6)

        // 3. One spline control point by its zero-based stable index, then a
        // second successive edit of a different point on the same entity.
        let firstSplineEdit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.splineID,
            "point_index": 2,
            "point": [12.0, 30.0],
            "expected_point": [10.0, 20.0],
        ])
        XCTAssertEqual(firstSplineEdit["ok"] as? Bool, true, "\(firstSplineEdit)")
        var splineRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.splineID)
        XCTAssertEqual(splineRow["id"] as? String, mixed.splineID)
        XCTAssertEqual(splineRow["points"] as? [[Double]],
                       [[0, 20], [5, 25], [12, 30], [15, 25]])
        let secondSplineEdit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.splineID,
            "point_index": 1,
            "point": [6.0, 28.0],
            "expected_point": [5.0, 25.0],
        ])
        XCTAssertEqual(secondSplineEdit["ok"] as? Bool, true, "\(secondSplineEdit)")
        splineRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.splineID)
        XCTAssertEqual(splineRow["points"] as? [[Double]],
                       [[0, 20], [6, 28], [12, 30], [15, 25]])

        // Exact unaffected ids, geometry and constraints.
        let afterRows = try entityRows(document, sketchID: mixed.sketchID)
        XCTAssertEqual(afterRows.compactMap { $0["id"] as? String }, baselineIDs)
        let unaffectedLine = try entityRow(document, sketchID: mixed.sketchID,
                                           entityID: mixed.lineID)
        XCTAssertEqual(try XCTUnwrap(unaffectedLine["b"] as? [Double]), [10, 40])
        let lineDimensionAfter = try dimensionRow(document, id: lineDimensionID)
        XCTAssertEqual(lineDimensionAfter["display_value"] as? Double ?? -1, 10, accuracy: 1e-9)
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == mixed.sketchID
        })
        XCTAssertTrue(sketch.validateConstraintRefs())

        // Undo the four geometry edits in reverse order; redo restores them.
        for _ in 0..<4 {
            XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        }
        arcRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.arcID)
        XCTAssertEqual(arcRow["sweepAngleDegrees"] as? Double ?? -1, 90, accuracy: 1e-6)
        ellipseRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.ellipseID)
        XCTAssertEqual(ellipseRow["radiusX"] as? Double ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(ellipseRow["rotationDegrees"] as? Double ?? 1, 0, accuracy: 1e-6)
        splineRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.splineID)
        XCTAssertEqual(splineRow["points"] as? [[Double]],
                       [[0, 20], [5, 25], [10, 20], [15, 25]])
        for _ in 0..<4 {
            XCTAssertEqual(service.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        }
        arcRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.arcID)
        XCTAssertEqual(arcRow["sweepAngleDegrees"] as? Double ?? -1, 120, accuracy: 1e-6)
        ellipseRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.ellipseID)
        XCTAssertEqual(ellipseRow["radiusX"] as? Double ?? -1, 8, accuracy: 1e-9)
        splineRow = try entityRow(document, sketchID: mixed.sketchID, entityID: mixed.splineID)
        XCTAssertEqual(splineRow["points"] as? [[Double]],
                       [[0, 20], [6, 28], [12, 30], [15, 25]])
    }

    // MARK: - Delete

    func testDeleteSpecifiedEntityKeepsOthersAndRefusesSharedReferences() async throws {
        let document = try await makeDocument()
        let mixed = try makeMixedSketch(document)
        let service = CADParameterService(document: document)

        let lineDimension = service.handle(action: "setSketchDimension", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.lineID,
            "kind": "length",
            "value": 10,
        ])
        XCTAssertEqual(lineDimension["ok"] as? Bool, true, "\(lineDimension)")
        let lineDimensionID = try XCTUnwrap(
            (lineDimension["dimension"] as? [String: Any])?["id"] as? String)

        // A distance dimension between arc center and ellipse center also
        // anchors the ellipse; deleting the arc is therefore a SHARED
        // reference and must be an explicit refusal, not a silent cascade.
        let shared = service.handle(action: "setSketchDimension", args: [
            "sketch_id": mixed.sketchID,
            "kind": "distance",
            "value": 30.0,
            "refs": [
                ["entity_id": mixed.arcID, "role": "center"],
                ["entity_id": mixed.ellipseID, "role": "center"],
            ],
        ])
        XCTAssertEqual(shared["ok"] as? Bool, true, "\(shared)")
        let sharedDimensionID = try XCTUnwrap(
            (shared["dimension"] as? [String: Any])?["id"] as? String)

        let beforeCount = document.session.changeCount
        let beforeIDs = try entityRows(document, sketchID: mixed.sketchID).compactMap {
            $0["id"] as? String
        }
        let refused = service.handle(action: "deleteSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "shared_references")
        let references = try XCTUnwrap(refused["references"] as? [[String: Any]])
        XCTAssertTrue(references.contains { ($0["id"] as? String) == sharedDimensionID })
        XCTAssertEqual(document.session.changeCount, beforeCount)
        XCTAssertEqual(try entityRows(document, sketchID: mixed.sketchID).compactMap {
            $0["id"] as? String
        }, beforeIDs)

        // Remove that shared dimension explicitly, then the single entity.
        let removeShared = service.handle(action: "removeSketchDimension", args: [
            "sketch_id": mixed.sketchID,
            "dimension_id": sharedDimensionID,
        ])
        XCTAssertEqual(removeShared["ok"] as? Bool, true, "\(removeShared)")
        let deleted = service.handle(action: "deleteSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        XCTAssertEqual(deleted["mutated"] as? Bool, true)
        XCTAssertEqual((deleted["deleted_entity"] as? [String: Any])?["id"] as? String,
                       mixed.arcID)
        let afterRows = try entityRows(document, sketchID: mixed.sketchID)
        let afterIDs = afterRows.compactMap { $0["id"] as? String }
        XCTAssertEqual(afterIDs, [mixed.ellipseID, mixed.splineID, mixed.lineID])
        XCTAssertEqual(try entityRow(document, sketchID: mixed.sketchID,
                                     entityID: mixed.ellipseID)["radiusX"] as? Double, 5)
        XCTAssertEqual(try entityRow(document, sketchID: mixed.sketchID,
                                     entityID: mixed.splineID)["pointCount"] as? Int, 4)
        let lineDimensionAfter = try dimensionRow(document, id: lineDimensionID)
        XCTAssertEqual(lineDimensionAfter["display_value"] as? Double ?? -1, 10, accuracy: 1e-9)
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == mixed.sketchID
        })
        XCTAssertTrue(sketch.validateConstraintRefs())

        // Undo restores the arc with the same id and the untouched others.
        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        let restored = try entityRows(document, sketchID: mixed.sketchID)
        XCTAssertEqual(restored.compactMap { $0["id"] as? String }, beforeIDs)
        XCTAssertEqual(try entityRow(document, sketchID: mixed.sketchID,
                                     entityID: mixed.arcID)["radius"] as? Double, 10)
    }

    func testDeleteRemovesOwnedDimensionAndOptInSharedReference() async throws {
        let document = try await makeDocument()
        let service = CADParameterService(document: document)

        // Owned: one arc angle dimension references only that arc.
        let first = try addSketch(
            document, name: "Owned",
            entities: #"[{"kind":"arc","center":[0,0],"radius":10,"startAngle":0,"endAngle":1.5707963267948966},{"kind":"ellipse","center":[30,0],"radiusX":5,"radiusY":3,"rotation":0}]"#)
        let firstRows = try entityRows(document, sketchID: first.sketchID)
        let firstArc = try firstID(of: "arc", in: firstRows)
        let firstEllipse = try firstID(of: "ellipse", in: firstRows)
        let angle = service.handle(action: "setSketchDimension", args: [
            "sketch_id": first.sketchID,
            "entity_id": firstArc,
            "kind": "angle",
            "value": 90,
        ])
        XCTAssertEqual(angle["ok"] as? Bool, true, "\(angle)")
        let angleID = try XCTUnwrap((angle["dimension"] as? [String: Any])?["id"] as? String)
        let ownedDelete = service.handle(action: "deleteSketchEntity", args: [
            "sketch_id": first.sketchID,
            "entity_id": firstArc,
        ])
        XCTAssertEqual(ownedDelete["ok"] as? Bool, true, "\(ownedDelete)")
        XCTAssertEqual(try XCTUnwrap(ownedDelete["removed_reference_ids"] as? [String]),
                       [angleID])
        XCTAssertEqual(try entityRows(document, sketchID: first.sketchID).compactMap {
            $0["id"] as? String
        }, [firstEllipse])

        // Shared with the explicit opt-in: the dimension that also anchored
        // the ellipse is removed, the ellipse itself is not.
        let second = try addSketch(
            document, name: "Shared",
            entities: #"[{"kind":"arc","center":[0,0],"radius":10,"startAngle":0,"endAngle":1.5707963267948966},{"kind":"ellipse","center":[30,0],"radiusX":5,"radiusY":3,"rotation":0}]"#)
        let secondRows = try entityRows(document, sketchID: second.sketchID)
        let secondArc = try firstID(of: "arc", in: secondRows)
        let secondEllipse = try firstID(of: "ellipse", in: secondRows)
        let shared = service.handle(action: "setSketchDimension", args: [
            "sketch_id": second.sketchID,
            "kind": "distance",
            "value": 30.0,
            "refs": [
                ["entity_id": secondArc, "role": "center"],
                ["entity_id": secondEllipse, "role": "center"],
            ],
        ])
        XCTAssertEqual(shared["ok"] as? Bool, true, "\(shared)")
        let sharedID = try XCTUnwrap((shared["dimension"] as? [String: Any])?["id"] as? String)
        let optInDelete = service.handle(action: "deleteSketchEntity", args: [
            "sketch_id": second.sketchID,
            "entity_id": secondArc,
            "remove_shared_references": true,
        ])
        XCTAssertEqual(optInDelete["ok"] as? Bool, true, "\(optInDelete)")
        XCTAssertEqual(optInDelete["shared_references_removed"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(optInDelete["removed_reference_ids"] as? [String]),
                       [sharedID])
        XCTAssertEqual(try entityRows(document, sketchID: second.sketchID).compactMap {
            $0["id"] as? String
        }, [secondEllipse])
        XCTAssertEqual(try queryRows(document, "constraints").filter {
            ($0["id"] as? String) == sharedID
        }.count, 0)
    }

    // MARK: - Refusal and rollback

    func testInvalidEditRefusesWithoutHalfChanges() async throws {
        let document = try await makeDocument()
        let mixed = try makeMixedSketch(document)
        let service = CADParameterService(document: document)

        let countBefore = document.session.changeCount
        let undoBefore = document.session.undoStack.undoCommands.count
        let redoBefore = document.session.undoStack.redoCommands.count

        // A stale optimistic fence refuses without changing anything.
        let stale = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
            "start_angle_deg": 45.0,
            "expected_start_angle_deg": 90.0,
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false, "\(stale)")
        XCTAssertEqual(stale["error"] as? String, "angle_mismatch")
        XCTAssertEqual(document.session.changeCount, countBefore)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redoBefore)

        // A saved Lock is a target-less solver fence: the typed edit must
        // refuse instead of re-locking the proposed values.
        let lock = SketchConstraint(
            kind: .fixed,
            refs: [ConstraintRef(entityID: UUID(uuidString: mixed.arcID)!, role: .whole)])
        document.session.perform(AddSketchConstraintCommand(
            sketchID: SketchID(raw: UUID(uuidString: mixed.sketchID)!),
            constraint: lock))
        let locked = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
            "radius": 12.0,
        ])
        XCTAssertEqual(locked["ok"] as? Bool, false, "\(locked)")
        XCTAssertEqual(locked["error"] as? String, "locked_entity")
        XCTAssertEqual(try entityRow(document, sketchID: mixed.sketchID,
                                     entityID: mixed.arcID)["radius"] as? Double, 10)

        // A tangent on an ellipse is not a solver-supported relationship (the
        // solver only lowers tangents with radius variables). Editing the
        // ellipse must refuse with the referenced ids instead of silently
        // leaving the saved relationship stale.
        let tangent = SketchConstraint(
            kind: .tangent,
            refs: [ConstraintRef(entityID: UUID(uuidString: mixed.ellipseID)!, role: .whole),
                   ConstraintRef(entityID: UUID(uuidString: mixed.lineID)!, role: .whole)])
        document.session.perform(AddSketchConstraintCommand(
            sketchID: SketchID(raw: UUID(uuidString: mixed.sketchID)!),
            constraint: tangent))
        let countBeforeDependent = document.session.changeCount
        let dependent = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.ellipseID,
            "radius_x": 9.0,
        ])
        XCTAssertEqual(dependent["ok"] as? Bool, false, "\(dependent)")
        XCTAssertEqual(dependent["error"] as? String, "dependent_reference")
        XCTAssertEqual(document.session.changeCount, countBeforeDependent)
        XCTAssertEqual(try entityRow(document, sketchID: mixed.sketchID,
                                     entityID: mixed.ellipseID)["radiusX"] as? Double, 5)
    }

    // MARK: - Connected parametric edits

    /// M01 preserves other ENTITY IDs and CONSTRAINTS, not every other
    /// coordinate. A saved driving distance must still be satisfiable by
    /// moving the RELATED circle, in the same undo step as the edited center.
    func testConnectedDistanceDimensionMovesRelatedCircleInOneUndoStep() async throws {
        let document = try await makeDocument()
        let created = try addSketch(
            document, name: "Connected Distance",
            entities: #"""
            [{"kind":"circle","center":[0,0],"radius":3},
             {"kind":"circle","center":[30,0],"radius":4}]
            """#)
        let rows = try entityRows(document, sketchID: created.sketchID)
        let firstCircle = try firstID(of: "circle", in: rows)
        let secondCircle = try XCTUnwrap(
            rows.compactMap { $0["id"] as? String }.first { $0 != firstCircle })
        let service = CADParameterService(document: document)

        let distance = service.handle(action: "setSketchDimension", args: [
            "sketch_id": created.sketchID,
            "kind": "distance",
            "value": 30.0,
            "refs": [
                ["entity_id": firstCircle, "role": "center"],
                ["entity_id": secondCircle, "role": "center"],
            ],
        ])
        XCTAssertEqual(distance["ok"] as? Bool, true, "\(distance)")
        let dimensionID = try XCTUnwrap(
            (distance["dimension"] as? [String: Any])?["id"] as? String)

        // Changing the first center alone leaves the saved 30 mm distance
        // unsatisfied at its old position. The production solver must move the
        // RELATED second circle instead of refusing the connected edit.
        let edit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": created.sketchID,
            "entity_id": firstCircle,
            "center": [10.0, 0.0],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstCircle)["center"] as? [Double],
                       [10, 0])
        let secondRow = try entityRow(document, sketchID: created.sketchID,
                                      entityID: secondCircle)
        XCTAssertEqual(secondRow["id"] as? String, secondCircle)
        let movedCenter = try XCTUnwrap(secondRow["center"] as? [Double])
        XCTAssertEqual(movedCenter[0], 40, accuracy: 1e-3,
                       "the saved distance must move the related circle, not be refused")
        XCTAssertEqual(movedCenter[1], 0, accuracy: 1e-6)
        XCTAssertEqual(secondRow["radius"] as? Double ?? -1, 4, accuracy: 1e-9)
        let dimensionAfter = try dimensionRow(document, id: dimensionID)
        XCTAssertEqual(dimensionAfter["display_value"] as? Double ?? -1, 30, accuracy: 1e-6)
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == created.sketchID
        })
        XCTAssertTrue(sketch.validateConstraintRefs())

        // The edited circle AND the related circle are one undo step.
        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstCircle)["center"] as? [Double],
                       [0, 0])
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: secondCircle)["center"] as? [Double],
                       [30, 0])
        XCTAssertEqual(service.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstCircle)["center"] as? [Double],
                       [10, 0])
        let redoneCenter = try XCTUnwrap(
            try entityRow(document, sketchID: created.sketchID,
                          entityID: secondCircle)["center"] as? [Double])
        XCTAssertEqual(redoneCenter[0], 40, accuracy: 1e-3)
    }

    /// A saved horizontal constraint is an ordinary supported line relation:
    /// editing one endpoint must let the solver move the OTHER endpoint of the
    /// same primitive. Only the caller-named endpoint is held.
    func testConnectedHorizontalConstraintMovesOtherEndpointInOneUndoStep() async throws {
        let document = try await makeDocument()
        let created = try addSketch(
            document, name: "Connected Horizontal",
            entities: #"[{"kind":"line","a":[0,0],"b":[10,0]}]"#)
        let rows = try entityRows(document, sketchID: created.sketchID)
        let lineID = try firstID(of: "line", in: rows)
        let horizontal = SketchConstraint(
            kind: .horizontal,
            refs: [ConstraintRef(entityID: UUID(uuidString: lineID)!, role: .whole)])
        document.session.perform(AddSketchConstraintCommand(
            sketchID: SketchID(raw: UUID(uuidString: created.sketchID)!),
            constraint: horizontal))
        let service = CADParameterService(document: document)

        let edit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": created.sketchID,
            "entity_id": lineID,
            "a": [0.0, 5.0],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        let row = try entityRow(document, sketchID: created.sketchID, entityID: lineID)
        XCTAssertEqual(row["a"] as? [Double], [0, 5])
        let followingEndpoint = try XCTUnwrap(row["b"] as? [Double])
        XCTAssertEqual(followingEndpoint.count, 2)
        // The caller's endpoint above is exact. The related endpoint comes
        // from the numeric solver: independently check the horizontal line
        // at 5 mm, well below its 1e-3 structural-residual acceptance limit.
        XCTAssertEqual(followingEndpoint[0], 10, accuracy: 1e-8)
        XCTAssertEqual(followingEndpoint[1], 5, accuracy: 1e-8,
                       "the other endpoint follows the saved horizontal constraint")
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == created.sketchID
        })
        XCTAssertTrue(sketch.constraints.contains { $0.id == horizontal.id })
        XCTAssertTrue(sketch.validateConstraintRefs())

        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        let restored = try entityRow(document, sketchID: created.sketchID, entityID: lineID)
        XCTAssertEqual(restored["a"] as? [Double], [0, 0])
        XCTAssertEqual(restored["b"] as? [Double], [10, 0])
    }

    /// A saved Coincident weld must carry an edited endpoint to its partner
    /// without changing either entity id or the constraint.
    func testConnectedCoincidentFollowerMovesWithEditedLineInOneUndoStep() async throws {
        let document = try await makeDocument()
        let created = try addSketch(
            document, name: "Connected Coincident",
            entities: #"""
            [{"kind":"line","a":[0,0],"b":[10,0]},
             {"kind":"line","a":[10,0],"b":[20,0]}]
            """#)
        let rows = try entityRows(document, sketchID: created.sketchID)
        let firstLine = try firstID(of: "line", in: rows)
        let secondLine = try XCTUnwrap(
            rows.compactMap { $0["id"] as? String }.first { $0 != firstLine })
        let coincident = SketchConstraint(kind: .coincident, refs: [
            ConstraintRef(entityID: UUID(uuidString: firstLine)!, role: .endpointB),
            ConstraintRef(entityID: UUID(uuidString: secondLine)!, role: .endpointA),
        ])
        document.session.perform(AddSketchConstraintCommand(
            sketchID: SketchID(raw: UUID(uuidString: created.sketchID)!),
            constraint: coincident))
        let service = CADParameterService(document: document)

        let edit = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": created.sketchID,
            "entity_id": firstLine,
            "b": [12.0, 3.0],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstLine)["b"] as? [Double], [12, 3])
        let secondRow = try entityRow(document, sketchID: created.sketchID,
                                      entityID: secondLine)
        XCTAssertEqual(secondRow["id"] as? String, secondLine)
        XCTAssertEqual(secondRow["a"] as? [Double], [12, 3],
                       "the coincident partner follows the edited endpoint")
        XCTAssertEqual(secondRow["b"] as? [Double], [20, 0])
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == created.sketchID
        })
        XCTAssertTrue(sketch.constraints.contains { $0.id == coincident.id })
        XCTAssertTrue(sketch.validateConstraintRefs())

        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstLine)["b"] as? [Double], [10, 0])
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: secondLine)["a"] as? [Double], [10, 0])
    }

    /// A real lock on the RELATED entity makes the connected move genuinely
    /// unsatisfiable: the edit must refuse with no half-change.
    func testLockedRelatedEntityRefusesUnsatisfiableConnectedEdit() async throws {
        let document = try await makeDocument()
        let created = try addSketch(
            document, name: "Locked Related",
            entities: #"""
            [{"kind":"circle","center":[0,0],"radius":3},
             {"kind":"circle","center":[30,0],"radius":4}]
            """#)
        let rows = try entityRows(document, sketchID: created.sketchID)
        let firstCircle = try firstID(of: "circle", in: rows)
        let secondCircle = try XCTUnwrap(
            rows.compactMap { $0["id"] as? String }.first { $0 != firstCircle })
        let service = CADParameterService(document: document)
        let distance = service.handle(action: "setSketchDimension", args: [
            "sketch_id": created.sketchID,
            "kind": "distance",
            "value": 30.0,
            "refs": [
                ["entity_id": firstCircle, "role": "center"],
                ["entity_id": secondCircle, "role": "center"],
            ],
        ])
        XCTAssertEqual(distance["ok"] as? Bool, true, "\(distance)")
        let lock = SketchConstraint(
            kind: .fixed,
            refs: [ConstraintRef(entityID: UUID(uuidString: secondCircle)!, role: .center)])
        document.session.perform(AddSketchConstraintCommand(
            sketchID: SketchID(raw: UUID(uuidString: created.sketchID)!),
            constraint: lock))
        let countBefore = document.session.changeCount

        let refused = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": created.sketchID,
            "entity_id": firstCircle,
            "center": [10.0, 0.0],
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "constraint_conflict")
        XCTAssertEqual(document.session.changeCount, countBefore)
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: firstCircle)["center"] as? [Double], [0, 0])
        XCTAssertEqual(try entityRow(document, sketchID: created.sketchID,
                                     entityID: secondCircle)["center"] as? [Double], [30, 0])
    }

    func testFailedDependentRebuildRollsBackTheEllipseEdit() async throws {
        let document = try await makeDocument()
        let sketch = try addSketch(
            document, name: "Broken Profile",
            entities: #"[{"kind":"rect","min":[0,0],"max":[20,20]},{"kind":"ellipse","center":[30,10],"radiusX":3,"radiusY":2,"rotation":0}]"#)
        let rows = try entityRows(document, sketchID: sketch.sketchID)
        let rectID = try firstID(of: "rect", in: rows)
        let ellipseID = try firstID(of: "ellipse", in: rows)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch.sketchID)","seedPoint":[10,10],
         "distance":5}}
        """)

        // Create a genuinely broken dependent rebuild without a document
        // command, exactly as the existing failed-rebuild regression does.
        // The edit below must then be refused and leave the ellipse untouched.
        document.session.preview { design in
            guard let index = design.sketches.firstIndex(where: {
                $0.id.raw.uuidString == sketch.sketchID
            }) else { return }
            design.sketches[index].entities.removeAll { $0.id.uuidString == rectID }
        }
        let before = try entityRow(document, sketchID: sketch.sketchID, entityID: ellipseID)
        let service = CADParameterService(document: document)
        let reply = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.sketchID,
            "entity_id": ellipseID,
            "center": [31.0, 11.0],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["error"] as? String, "rebuild_failed")
        XCTAssertEqual(reply["rolled_back"] as? Bool, true)
        let after = try entityRow(document, sketchID: sketch.sketchID, entityID: ellipseID)
        XCTAssertEqual(after["center"] as? [Double], before["center"] as? [Double])
        XCTAssertEqual(after["radiusX"] as? Double, before["radiusX"] as? Double)
    }

    // MARK: - Dependent feature recompute

    func testSplineControlPointEditRebuildsDependentExtrude() async throws {
        let document = try await makeDocument()
        let spline = try addSketch(
            document, name: "Spline Profile",
            entities: #"[{"kind":"spline","points":[[0,0],[50,0],[45,10],[30,17],[0,12]],"closed":true}]"#)
        let splineID = try XCTUnwrap(spline.entityIDs.first)
        let extruded = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(spline.sketchID)","seedPoint":[10,5],
         "distance":7}}
        """)
        let bodyID = try XCTUnwrap(
            (extruded["producedBodyIDs"] as? [String])?.first
                ?? (extruded["changedBodyIDs"] as? [String])?.first
                ?? (try? firstBodyID(document)))
        let controlsBefore: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(50, 0), SIMD2(45, 10), SIMD2(30, 17), SIMD2(0, 12),
        ]
        let controlsAfter: [SIMD2<Double>] = [
            SIMD2(0, 0), SIMD2(50, 0), SIMD2(52, 18), SIMD2(30, 17), SIMD2(0, 12),
        ]
        let beforeArea = abs(CatmullRomBezier.signedArea(
            CatmullRomBezier.spans(controlsBefore, closed: true)))
        let afterArea = abs(CatmullRomBezier.signedArea(
            CatmullRomBezier.spans(controlsAfter, closed: true)))
        let before = try volume(document, bodyID: bodyID)
        XCTAssertEqual(before, beforeArea * 7, accuracy: max(1e-6, abs(beforeArea * 7) * 1e-5))
        let features = try queryRows(document, "features")
        let featureRow = try XCTUnwrap(features.first {
            (($0["referencedSketches"] as? [String]) ?? []).contains(spline.sketchID)
        })
        let featureID = try XCTUnwrap(featureRow["id"] as? String)

        // Move one fit point outward; the dependent extrude is replayed in the
        // SAME undo step and the body keeps its identity.
        let service = CADParameterService(document: document)
        let edited = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": spline.sketchID,
            "entity_id": splineID,
            "point_index": 2,
            "point": [52.0, 18.0],
            "expected_point": [45.0, 10.0],
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        let dependentIDs = try XCTUnwrap(edited["dependent_feature_ids"] as? [String])
        XCTAssertEqual(dependentIDs, [featureID])
        let after = try volume(document, bodyID: bodyID)
        XCTAssertEqual(after, afterArea * 7, accuracy: max(1e-6, abs(afterArea * 7) * 1e-5))
        XCTAssertGreaterThan(after, before, "outward spline point must create a larger solid")
        XCTAssertEqual(try firstBodyID(document), bodyID,
                       "the replayed extrude keeps the produced body id")

        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try volume(document, bodyID: bodyID), before, accuracy: 1e-6)
        XCTAssertEqual(service.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try volume(document, bodyID: bodyID), after, accuracy: 1e-6)

        // The recomputed state, stable ids and body identity survive reopen.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(try volume(reopened, bodyID: bodyID), after, accuracy: 1e-6)
        let row = try entityRow(reopened, sketchID: spline.sketchID, entityID: splineID)
        XCTAssertEqual(row["points"] as? [[Double]],
                       [[0, 0], [50, 0], [52, 18], [30, 17], [0, 12]])
        reopened.close()
    }

    // MARK: - Save / reopen

    func testEditsAndIdentitySurviveSaveAndReopen() async throws {
        let url = workDir.appendingPathComponent("reopen-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Reopen")
        let mixed = try makeMixedSketch(document)
        let service = CADParameterService(document: document)

        XCTAssertEqual(service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.arcID,
            "sweep_angle_deg": 135.0,
        ])["ok"] as? Bool, true)
        XCTAssertEqual(service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.ellipseID,
            "radius_y": 6.5,
            "rotation_deg": -20.0,
        ])["ok"] as? Bool, true)
        XCTAssertEqual(service.handle(action: "updateSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.splineID,
            "points": [[0, 20], [7, 30], [12, 18], [16, 26]],
        ])["ok"] as? Bool, true)
        XCTAssertEqual(service.handle(action: "deleteSketchEntity", args: [
            "sketch_id": mixed.sketchID,
            "entity_id": mixed.lineID,
        ])["ok"] as? Bool, true)

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let expectedIDs = [mixed.arcID, mixed.ellipseID, mixed.splineID]
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let rows = try entityRows(reopened, sketchID: mixed.sketchID)
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, expectedIDs)
        let arc = try entityRow(reopened, sketchID: mixed.sketchID, entityID: mixed.arcID)
        XCTAssertEqual(arc["sweepAngleDegrees"] as? Double ?? -1, 135, accuracy: 1e-6)
        let ellipse = try entityRow(reopened, sketchID: mixed.sketchID,
                                    entityID: mixed.ellipseID)
        XCTAssertEqual(ellipse["radiusY"] as? Double ?? -1, 6.5, accuracy: 1e-9)
        XCTAssertEqual(ellipse["rotationDegrees"] as? Double ?? 1, -20, accuracy: 1e-6)
        let spline = try entityRow(reopened, sketchID: mixed.sketchID,
                                   entityID: mixed.splineID)
        XCTAssertEqual(spline["points"] as? [[Double]],
                       [[0, 20], [7, 30], [12, 18], [16, 26]])
        let sketch = try XCTUnwrap(reopened.session.document.sketches.first {
            $0.id.raw.uuidString == mixed.sketchID
        })
        XCTAssertTrue(sketch.validateConstraintRefs())
        reopened.close()
    }
}
