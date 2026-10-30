//
//  CADSketchEditTests.swift
//  FloeCADKitTests
//
//  Focused behavior tests for the native existing-document editing surface:
//  line/rect/circle geometry edits, driving length/angle/diameter dimensions,
//  feature suppress/restore/delete/reorder with dependency checks, the
//  editable flags query, and the trusted selection-context snapshot.
//
//  These drive the SAME production services the agent tool calls
//  (`CADParameterService`, `FloeCADDocument.nativeQueryJSON`,
//  `CADSelectionContext.capture`); no fake renderer or fake result is used.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADSketchEditTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADSketchEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func makeDocument(_ name: String = "SketchEdit") async throws -> FloeCADDocument {
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

    private func entityRow(_ document: FloeCADDocument, sketchID: String,
                           entityID: String) throws -> [String: Any] {
        let row = try sketchRow(document, sketchID: sketchID)
        let entities = try XCTUnwrap(row["entityRows"] as? [[String: Any]])
        return try XCTUnwrap(entities.first { ($0["id"] as? String) == entityID })
    }

    private func featureRow(_ document: FloeCADDocument, featureID: String) throws -> [String: Any] {
        let rows = try queryRows(document, "features")
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == featureID })
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

    private func addSketch(_ document: FloeCADDocument, name: String,
                           entities: String) throws -> (sketchID: String, entityIDs: [String]) {
        let created = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(created["sketchID"] as? String)
        _ = try run(document, #"{"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":\#(entities)}}"#)
        let row = try sketchRow(document, sketchID: sketchID)
        let entityRows = try XCTUnwrap(row["entityRows"] as? [[String: Any]])
        return (sketchID, entityRows.compactMap { $0["id"] as? String })
    }

    private func makePlateWithHole(_ document: FloeCADDocument) throws
        -> (plateSketch: String, plateFeature: String, holeSketch: String,
            holeFeature: String, bodyID: String) {
        let plate = try addSketch(
            document, name: "Plate",
            entities: #"[{"kind":"rect","min":[0,0],"max":[100,60]}]"#)
        let plateExtrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plate.sketchID)","seedPoint":[50,30],
         "distance":10}}
        """)
        let plateBodyID = try XCTUnwrap(
            (plateExtrude["producedBodyIDs"] as? [String])?.first
                ?? (plateExtrude["changedBodyIDs"] as? [String])?.first)
        let featuresAfterPlate = try queryRows(document, "features")
        let plateFeatureRow = try XCTUnwrap(featuresAfterPlate.first {
            ($0["kind"] as? String) == "extrude"
                && (($0["referencedSketches"] as? [String]) ?? []).contains(plate.sketchID)
        })
        let plateFeatureID = try XCTUnwrap(plateFeatureRow["id"] as? String)

        let hole = try addSketch(
            document, name: "Hole",
            entities: #"[{"kind":"circle","center":[50,30],"radius":5}]"#)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(hole.sketchID)","seedPoint":[50,30],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plateBodyID)"]}}
        """)
        let features = try queryRows(document, "features")
        let holeFeature = try XCTUnwrap(features.first {
            (($0["referencedSketches"] as? [String]) ?? []).contains(hole.sketchID)
        })
        let holeFeatureID = try XCTUnwrap(holeFeature["id"] as? String)
        let bodyID = try firstBodyID(document)
        return (plate.sketchID, plateFeatureID, hole.sketchID, holeFeatureID, bodyID)
    }

    // MARK: - Entity geometry

    func testLineRectAndCircleEditsAreRealAndUndoable() async throws {
        let document = try await makeDocument()
        let parameters = CADParameterService(document: document)

        // 1. Line endpoints.
        let line = try addSketch(
            document, name: "Line",
            entities: #"[{"kind":"line","a":[0,0],"b":[10,0]}]"#)
        let lineEntity = try XCTUnwrap(line.entityIDs.first)
        let lineResult = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": line.sketchID,
            "entity_id": lineEntity,
            "a": [2, 3],
            "b": [12, 3],
            "expected_a": [0, 0],
        ])
        XCTAssertEqual(lineResult["ok"] as? Bool, true, "\(lineResult)")
        var row = try entityRow(document, sketchID: line.sketchID, entityID: lineEntity)
        XCTAssertEqual(row["kind"] as? String, "line")
        XCTAssertEqual(row["a"] as? [Double], [2, 3])
        XCTAssertEqual(row["b"] as? [Double], [12, 3])
        XCTAssertEqual(row["lengthMM"] as? Double ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(row["editable"] as? Bool, true)
        XCTAssertEqual(row["update_fields"] as? [String], ["a", "b"])

        // Undo restores the original endpoint, redo re-applies the edit.
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        row = try entityRow(document, sketchID: line.sketchID, entityID: lineEntity)
        XCTAssertEqual(row["a"] as? [Double], [0, 0])
        XCTAssertEqual(parameters.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        row = try entityRow(document, sketchID: line.sketchID, entityID: lineEntity)
        XCTAssertEqual(row["a"] as? [Double], [2, 3])

        // 2. Rectangle position + dimensions.
        let rect = try addSketch(
            document, name: "Rect",
            entities: #"[{"kind":"rect","min":[0,0],"max":[10,5]}]"#)
        let rectEntity = try XCTUnwrap(rect.entityIDs.first)
        let rectResult = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": rect.sketchID,
            "entity_id": rectEntity,
            "center": [5, 5],
            "width": 20,
            "height": 8,
        ])
        XCTAssertEqual(rectResult["ok"] as? Bool, true, "\(rectResult)")
        row = try entityRow(document, sketchID: rect.sketchID, entityID: rectEntity)
        XCTAssertEqual(row["kind"] as? String, "rect")
        XCTAssertEqual(row["min"] as? [Double], [-5, 1])
        XCTAssertEqual(row["max"] as? [Double], [15, 9])
        XCTAssertEqual(row["widthMM"] as? Double ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(row["heightMM"] as? Double ?? -1, 8, accuracy: 1e-9)

        // A stale size fence is refused with no mutation.
        let changeBefore = document.session.changeCount
        let stale = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": rect.sketchID,
            "entity_id": rectEntity,
            "width": 30,
            "expected_width": 10,
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "size_mismatch")
        XCTAssertEqual(document.session.changeCount, changeBefore)

        // 3. Circle center + radius.
        let circle = try addSketch(
            document, name: "Circle",
            entities: #"[{"kind":"circle","center":[0,0],"radius":2}]"#)
        let circleEntity = try XCTUnwrap(circle.entityIDs.first)
        let circleResult = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circleEntity,
            "center": [5, 6],
            "radius": 3,
            "expected_radius": 2,
        ])
        XCTAssertEqual(circleResult["ok"] as? Bool, true, "\(circleResult)")
        row = try entityRow(document, sketchID: circle.sketchID, entityID: circleEntity)
        XCTAssertEqual(row["center"] as? [Double], [5, 6])
        XCTAssertEqual(row["radius"] as? Double ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(row["diameterMM"] as? Double ?? -1, 6, accuracy: 1e-9)

        // 4. Unsupported entity kinds report editable=false and refuse edits.
        let arc = try addSketch(
            document, name: "Arc",
            entities: #"[{"kind":"arc","center":[0,0],"radius":4,"startAngle":0,"endAngle":1.57}]"#)
        let arcEntity = try XCTUnwrap(arc.entityIDs.first)
        row = try entityRow(document, sketchID: arc.sketchID, entityID: arcEntity)
        XCTAssertEqual(row["editable"] as? Bool, false)
        XCTAssertNil(row["update_action"])
        let arcEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": arc.sketchID,
            "entity_id": arcEntity,
            "radius": 5,
        ])
        XCTAssertEqual(arcEdit["ok"] as? Bool, false)
        XCTAssertEqual(arcEdit["error"] as? String, "unsupported_entity")
    }

    func testDrivingLengthAngleDiameterAndRectangleWidthDimensions() async throws {
        let document = try await makeDocument()
        let parameters = CADParameterService(document: document)

        // Two lines from a common origin: a length on one, an angle between both.
        let lines = try addSketch(
            document, name: "Lines",
            entities: #"[{"kind":"line","a":[0,0],"b":[10,0]},{"kind":"line","a":[0,0],"b":[0,10]}]"#)
        let lineA = try XCTUnwrap(lines.entityIDs.first)
        let lineB = try XCTUnwrap(lines.entityIDs.dropFirst().first)

        let length = parameters.handle(action: "setSketchDimension", args: [
            "sketch_id": lines.sketchID,
            "entity_id": lineA,
            "kind": "length",
            "value": 20,
        ])
        XCTAssertEqual(length["ok"] as? Bool, true, "\(length)")
        let lengthDimension = try XCTUnwrap(length["dimension"] as? [String: Any])
        XCTAssertEqual(lengthDimension["kind"] as? String, "distance")
        XCTAssertEqual(lengthDimension["value"] as? Double ?? -1, 20, accuracy: 1e-9)
        var row = try entityRow(document, sketchID: lines.sketchID, entityID: lineA)
        XCTAssertEqual(row["lengthMM"] as? Double ?? -1, 20, accuracy: 1e-6)

        let angle = parameters.handle(action: "setSketchDimension", args: [
            "sketch_id": lines.sketchID,
            "entity_ids": [lineA, lineB],
            "kind": "angle",
            "value": 45,
        ])
        XCTAssertEqual(angle["ok"] as? Bool, true, "\(angle)")
        let angleDimension = try XCTUnwrap(angle["dimension"] as? [String: Any])
        XCTAssertEqual(angleDimension["kind"] as? String, "angle")
        XCTAssertEqual(angleDimension["value"] as? Double ?? -1, 45, accuracy: 1e-9)
        XCTAssertEqual(angleDimension["unit"] as? String, "deg")

        // The constraints query exposes the dimension as editable with the
        // same id and a degree display value (stored radians underneath).
        let constraints = try queryRows(document, "constraints")
        let angleRow = try XCTUnwrap(constraints.first {
            ($0["id"] as? String) == (angleDimension["id"] as? String)
        })
        XCTAssertEqual(angleRow["row_kind"] as? String, "dimension")
        XCTAssertEqual(angleRow["editable"] as? Bool, true)
        XCTAssertEqual(angleRow["update_action"] as? String, "setSketchDimension")
        XCTAssertEqual(angleRow["display_value"] as? Double ?? -1, 45, accuracy: 1e-6)

        // Diameter on a circle.
        let circle = try addSketch(
            document, name: "Hole",
            entities: #"[{"kind":"circle","center":[50,50],"radius":5}]"#)
        let circleEntity = try XCTUnwrap(circle.entityIDs.first)
        let diameter = parameters.handle(action: "setSketchDimension", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circleEntity,
            "kind": "diameter",
            "value": 12,
        ])
        XCTAssertEqual(diameter["ok"] as? Bool, true, "\(diameter)")
        row = try entityRow(document, sketchID: circle.sketchID, entityID: circleEntity)
        XCTAssertEqual(row["radius"] as? Double ?? -1, 6, accuracy: 1e-6)
        XCTAssertEqual(row["diameterMM"] as? Double ?? -1, 12, accuracy: 1e-6)

        // Rectangle width (stored as the solver's horizontal distance).
        let rect = try addSketch(
            document, name: "Width",
            entities: #"[{"kind":"rect","min":[0,0],"max":[10,5]}]"#)
        let rectEntity = try XCTUnwrap(rect.entityIDs.first)
        let width = parameters.handle(action: "setSketchDimension", args: [
            "sketch_id": rect.sketchID,
            "entity_id": rectEntity,
            "kind": "width",
            "value": 30,
        ])
        XCTAssertEqual(width["ok"] as? Bool, true, "\(width)")
        let widthDimension = try XCTUnwrap(width["dimension"] as? [String: Any])
        XCTAssertEqual(widthDimension["kind"] as? String, "horizontal")
        row = try entityRow(document, sketchID: rect.sketchID, entityID: rectEntity)
        XCTAssertEqual(row["widthMM"] as? Double ?? -1, 30, accuracy: 1e-6)

        // Editing the same circle's radius updates its matching diameter
        // dimension in the same undo step, so the stored sketch never keeps a
        // stale driving value.
        let circleEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circleEntity,
            "radius": 7,
            "expected_radius": 6,
        ])
        XCTAssertEqual(circleEdit["ok"] as? Bool, true, "\(circleEdit)")
        row = try entityRow(document, sketchID: circle.sketchID, entityID: circleEntity)
        XCTAssertEqual(row["radius"] as? Double ?? -1, 7, accuracy: 1e-6)
        let dimensionRows = try queryRows(document, "constraints")
        let editedDimension = try XCTUnwrap(dimensionRows.first {
            ($0["id"] as? String) == (diameter["dimension"].flatMap {
                ($0 as? [String: Any])?["id"] as? String
            } ?? "")
        })
        XCTAssertEqual(editedDimension["display_value"] as? Double ?? -1, 14, accuracy: 1e-6)
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        row = try entityRow(document, sketchID: circle.sketchID, entityID: circleEntity)
        XCTAssertEqual(row["radius"] as? Double ?? -1, 6, accuracy: 1e-6)
        XCTAssertEqual(parameters.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        row = try entityRow(document, sketchID: circle.sketchID, entityID: circleEntity)
        XCTAssertEqual(row["radius"] as? Double ?? -1, 7, accuracy: 1e-6)

        // A stale expected value is refused without mutation, then removal is
        // an ordinary undoable step.
        let before = document.session.changeCount
        let stale = parameters.handle(action: "setSketchDimension", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circleEntity,
            "kind": "diameter",
            "value": 8,
            "expected_value": 10,
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "value_mismatch")
        XCTAssertEqual(document.session.changeCount, before)

        let removed = parameters.handle(action: "removeSketchDimension", args: [
            "sketch_id": circle.sketchID,
            "dimension_id": diameter["dimension"].flatMap { ($0 as? [String: Any])?["id"] as? String } ?? "",
        ])
        XCTAssertEqual(removed["ok"] as? Bool, true, "\(removed)")
        XCTAssertEqual(removed["mutated"] as? Bool, true)
    }

    // MARK: - Feature history

    func testFeatureSuppressRestoreDeleteMoveWithDependencyChecks() async throws {
        let document = try await makeDocument()
        let parameters = CADParameterService(document: document)
        let fixture = try makePlateWithHole(document)
        let plateVolume = 100.0 * 60.0 * 10.0
        let holeVolume = plateVolume - Double.pi * 5 * 5 * 10

        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), holeVolume, accuracy: 1e-3)

        // Deleting the plate is refused because the hole cut consumes its body.
        let refusedDelete = parameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.plateFeature,
        ])
        XCTAssertEqual(refusedDelete["ok"] as? Bool, false, "\(refusedDelete)")
        XCTAssertEqual(refusedDelete["error"] as? String, "has_dependents")
        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), holeVolume, accuracy: 1e-3)

        // Suppress the hole cut → plate only, then restore.
        let suppress = parameters.handle(action: "feature.suppress", args: [
            "feature_id": fixture.holeFeature,
            "suppressed": true,
        ])
        XCTAssertEqual(suppress["ok"] as? Bool, true, "\(suppress)")
        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), plateVolume, accuracy: 1e-3)
        let restore = parameters.handle(action: "feature.suppress", args: [
            "feature_id": fixture.holeFeature,
            "suppressed": false,
        ])
        XCTAssertEqual(restore["ok"] as? Bool, true, "\(restore)")
        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), holeVolume, accuracy: 1e-3)

        // Moving the hole cut before the plate breaks the body dependency and
        // is refused without changing the history order.
        let beforeMove = try queryRows(document, "features").compactMap { $0["id"] as? String }
        let badMove = parameters.handle(action: "feature.move", args: [
            "feature_id": fixture.holeFeature,
            "to_index": 0,
        ])
        XCTAssertEqual(badMove["ok"] as? Bool, false, "\(badMove)")
        XCTAssertEqual(badMove["error"] as? String, "dependency_order")
        let afterMove = try queryRows(document, "features").compactMap { $0["id"] as? String }
        XCTAssertEqual(afterMove, beforeMove)

        // Delete the (leaf) hole cut, then undo it.
        let delete = parameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.holeFeature,
        ])
        XCTAssertEqual(delete["ok"] as? Bool, true, "\(delete)")
        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), plateVolume, accuracy: 1e-3)
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(try volume(document, bodyID: fixture.bodyID), holeVolume, accuracy: 1e-3)

        // The advertised feature actions are all executable by this service.
        let feature = try featureRow(document, featureID: fixture.plateFeature)
        let actions = try XCTUnwrap(feature["actions"] as? [String])
        for action in ["feature.suppress", "feature.delete", "feature.move"] {
            XCTAssertTrue(actions.contains(action), "missing advertised action \(action)")
            XCTAssertTrue(CADParameterService.actions.contains(action), "\(action) is not executable")
        }
    }

    func testFeatureParameterEditableFlagsMatchTypedUpdates() async throws {
        let document = try await makeDocument()
        let fixture = try makePlateWithHole(document)
        // A transform node has no typed numeric parameter updater; its
        // translation/scale rows must not claim editable.
        _ = try run(document, """
        {"op":"feature.transform","args":{"bodyID":"\(fixture.bodyID)","translation":[5,0,0]}}
        """)
        let rows = try queryRows(document, "features")
        let transform = try XCTUnwrap(rows.first { ($0["kind"] as? String) == "transform" })
        XCTAssertEqual(transform["update_supported"] as? Bool, false)
        let parameters = try XCTUnwrap(transform["parameters"] as? [[String: Any]])
        for parameter in parameters {
            XCTAssertEqual(parameter["editable"] as? Bool, false,
                           "transform parameter \(parameter["name"] ?? "?") claims an unsupported edit")
        }
        // An extrude does expose a real typed distance edit.
        let extrude = try XCTUnwrap(rows.first { ($0["kind"] as? String) == "extrude" })
        XCTAssertEqual(extrude["update_supported"] as? Bool, true)
        let extrudeParameters = try XCTUnwrap(extrude["parameters"] as? [[String: Any]])
        let distance = try XCTUnwrap(extrudeParameters.first { ($0["name"] as? String) == "distance" })
        XCTAssertEqual(distance["editable"] as? Bool, true)
    }

    // MARK: - Selection context

    func testSelectionContextUsesLiveIdsAndRevision() async throws {
        let document = try await makeDocument()
        let fixture = try makePlateWithHole(document)
        let bodyID = try XCTUnwrap(UUID(uuidString: fixture.bodyID))
        let body = try XCTUnwrap(document.session.document.body(with: BodyID(raw: bodyID)))

        // A real face pick over the first mesh triangle.
        let facePick = CADSelectionContext.FaceTrianglePick(
            bodyID: bodyID, triangles: [0], curved: false)
        // A real edge pick from the body's own crease segment list.
        var edgePick: CADSelectionContext.EdgeSegmentPick?
        if body.edges.segments.count >= 2 {
            let a = body.edges.segments[0]
            let b = body.edges.segments[1]
            edgePick = CADSelectionContext.EdgeSegmentPick(
                bodyID: bodyID,
                start: SIMD3(Double(a.x), Double(a.y), Double(a.z)),
                end: SIMD3(Double(b.x), Double(b.y), Double(b.z)),
                isConvex: true)
        }
        let holeSketchID = try XCTUnwrap(UUID(uuidString: fixture.holeSketch))
        let holeSketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw == holeSketchID
        })
        let circleID = try XCTUnwrap(holeSketch.entities.first?.id)

        let context = CADSelectionContext.capture(
            document: document,
            bodyIDs: [BodyID(raw: bodyID)],
            facePicks: [facePick],
            edgePicks: edgePick.map { [$0] } ?? [],
            sketchID: holeSketch.id,
            sketchEntityIDs: [circleID],
            instanceIDs: [])
        XCTAssertEqual(context.documentRevision, Int64(document.revision))
        XCTAssertEqual(context.changeCount, document.session.changeCount)
        XCTAssertEqual(context.bodies.map(\.id), [bodyID.uuidString])
        XCTAssertEqual(context.bodies.first?.name, body.name)
        XCTAssertEqual(context.faces.count, 1)
        XCTAssertGreaterThan(context.faces[0].areaMM2, 0)
        XCTAssertEqual(context.faces[0].normal.count, 3)
        XCTAssertEqual(context.edges.count, edgePick == nil ? 0 : 1)
        XCTAssertEqual(context.sketch?.id, holeSketch.id.raw.uuidString)
        XCTAssertEqual(context.sketch?.entityIDs, [circleID.uuidString])
        XCTAssertFalse(context.promptText().isEmpty)
        let json = context.jsonObject()
        XCTAssertEqual(json["document_revision"] as? Int64, Int64(document.revision))
        XCTAssertNotNil(json["bodies"] as? [[String: Any]])
        XCTAssertNotNil(json["sketch"] as? [String: Any])
    }
}
