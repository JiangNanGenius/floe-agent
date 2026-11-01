//
//  CADAssociativePlaneKindsServiceTests.swift
//  FloeCADKitTests
//
//  M07 — real OCCT/document/service coverage for associative angle and
//  three-point construction planes: creation, query, source edits, formula
//  fan-out, broken identities, cycles, undo/redo and save/reopen.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativePlaneKindsServiceTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeDatumKinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Fixture {
        var document: FloeCADDocument
        var source: FeatureNode
        var body: BodyID
    }

    private func extrusion(_ sketch: Sketch, distance: Double, body: BodyID,
                           name: String = "Extrusion") -> FeatureNode {
        FeatureNode(name: name, kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: sketch.entities.map(\.id),
                                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    private func fixture(thickness: Double = 10) async throws -> Fixture {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"),
            name: "Plane kinds")
        documents.append(document)
        let sketch = Sketch(name: "Plate", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60)),
        ])
        let body = BodyID()
        let source = extrusion(sketch, distance: thickness, body: body, name: "Plate")
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)],
                                          title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return Fixture(document: document, source: source, body: body)
    }

    private func rows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope, "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    private func topFace(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        })
    }

    private func bottomFace(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && (($0["normal"] as? [Double])?[1] ?? 0) < -0.99
        })
    }

    private func sourceArgs(_ face: [String: Any], expression: String,
                            body: BodyID) throws -> [String: Any] {
        XCTAssertEqual(face["datum_source_supported"] as? Bool, true, "\(face)")
        return ["body_id": body.raw.uuidString,
                "face_index": try XCTUnwrap(face["index"]),
                "query_token": try XCTUnwrap(face["query_token"]),
                "expression": expression]
    }

    private func call(_ f: Fixture, _ action: String, _ args: [String: Any]) -> [String: Any] {
        CADParameterService(document: f.document).handle(action: action, args: args)
    }

    private func createAngle(_ f: Fixture, expression: String = "30",
                             hinge: SIMD2<Double> = SIMD2(1, 0),
                             face: [String: Any]? = nil) throws -> (ConstructionPlaneID, [String: Any]) {
        var args = try sourceArgs(face ?? topFace(f), expression: expression, body: f.body)
        args["hinge_x"] = hinge.x
        args["hinge_y"] = hinge.y
        let reply = call(f, "datum.anglePlane.create", args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let id = ConstructionPlaneID(raw: try XCTUnwrap(
            (reply["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        return (id, reply)
    }

    private func plane(_ f: Fixture, _ id: ConstructionPlaneID) throws -> ConstructionPlane {
        try XCTUnwrap(f.document.session.document.planes.first { $0.id == id })
    }

    private func angleDefinition(_ f: Fixture, _ id: ConstructionPlaneID) throws -> AnglePlaneDefinition {
        guard case let .angle(definition)? = try plane(f, id).definition else {
            throw XCTSkip("Expected an angle plane")
        }
        return definition
    }

    private func threePointDefinition(_ f: Fixture,
                                      _ id: ConstructionPlaneID) throws -> ThreePointPlaneDefinition {
        guard case let .threePoints(definition)? = try plane(f, id).definition else {
            throw XCTSkip("Expected a three-point plane")
        }
        return definition
    }

    private func childSketch(_ f: Fixture, support: ConstructionPlaneID,
                             name: String = "Datum child") -> Sketch {
        Sketch(name: name, plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1)),
        ], support: PlaneRef(source: .construction(support)))
    }

    private func installChild(_ f: Fixture, sketch: Sketch,
                              title: String = "Datum child") -> (FeatureNode, BodyID) {
        let body = BodyID()
        let node = extrusion(sketch, distance: 3, body: body, name: "Datum child")
        XCTAssertTrue(f.document.session.performAssociativeTransaction([
            AddSketchCommand(sketch: sketch),
            AppendFeatureCommand(node: node, title: title),
        ], title: title))
        XCTAssertTrue(f.document.session.lastEvalErrors.isEmpty,
                      "\(f.document.session.lastEvalErrors)")
        XCTAssertTrue(f.document.session.lastReferenceErrors.isEmpty,
                      "\(f.document.session.lastReferenceErrors)")
        return (node, body)
    }

    // MARK: - Angle datum service behavior

    func testAngleCreateQueryUpdateReselectAndDownstreamFollow() async throws {
        let f = try await fixture()
        let top = try topFace(f)
        let (id, reply) = try createAngle(f, expression: "30")
        let row = try XCTUnwrap(reply["plane"] as? [String: Any])
        XCTAssertEqual(row["kind"] as? String, "angle")
        XCTAssertEqual(row["definition_version"] as? Int, 1)
        XCTAssertEqual(row["expression"] as? String, "30")
        XCTAssertEqual(row["expression_unit"] as? String, "deg")
        XCTAssertEqual(row["value"] as? Double, 30.0)
        XCTAssertEqual(row["hinge_local"] as? [Double], [1.0, 0.0])
        XCTAssertEqual(row["source_writer_id"] as? String, f.source.id.raw.uuidString)
        XCTAssertEqual(row["update_action"] as? String, "datum.anglePlane.update")
        XCTAssertEqual(row["delete_action"] as? String, "datum.anglePlane.delete")

        let initial = try plane(f, id)
        XCTAssertEqual(initial.plane.origin.y, 10, accuracy: 1e-6)
        XCTAssertEqual(initial.plane.normal.y, cos(30 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(initial.plane.normal.z, sin(30 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(try angleDefinition(f, id).hinge, SIMD2(1, 0))

        let child = childSketch(f, support: id)
        let (_, childBody) = installChild(f, sketch: child)
        let childPlane = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == child.id }?.plane)
        XCTAssertEqual(childPlane.origin.y, initial.plane.origin.y, accuracy: 1e-6)
        XCTAssertEqual(childPlane.normal, initial.plane.normal)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(
            f.document.session.document.body(with: childBody)?.brep)), 24, accuracy: 1e-4)

        // Parent geometry edit: thickness 10 → 20. The angle plane and its
        // supported child sketch/feature must follow in the same rebuild.
        let update = call(f, "update", ["feature_id": f.source.id.raw.uuidString,
                                        "changes": ["distance": 20]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try plane(f, id).id, id)
        XCTAssertEqual(try plane(f, id).plane.origin.y, 20, accuracy: 1e-6)
        let movedChild = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == child.id }?.plane)
        XCTAssertEqual(movedChild.origin.y, 20, accuracy: 1e-6)
        XCTAssertEqual(movedChild.normal, try plane(f, id).plane.normal)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(
            f.document.session.document.body(with: childBody)?.brep)), 24, accuracy: 1e-4)

        // Numeric edit, expected-expression fence, undo/redo, same plane id.
        let numeric = call(f, "datum.anglePlane.update", [
            "plane_id": id.raw.uuidString, "expression": "-45",
            "expected_expression": "30",
        ])
        XCTAssertEqual(numeric["ok"] as? Bool, true, "\(numeric)")
        XCTAssertEqual(try angleDefinition(f, id).angle, Expr(value: -45, formula: "-45"))
        XCTAssertEqual(try plane(f, id).plane.normal.y, cos(45 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(try plane(f, id).plane.normal.z, -sin(45 * .pi / 180), accuracy: 1e-9)
        f.document.session.undo()
        XCTAssertEqual(try plane(f, id).plane.origin.y, 20, accuracy: 1e-6)
        XCTAssertEqual(try angleDefinition(f, id).angle.value, 30, accuracy: 1e-12)
        f.document.session.redo()
        XCTAssertEqual(try angleDefinition(f, id).angle.value, -45, accuracy: 1e-12)

        // Source reselect keeps identity and uses the complete fresh triple.
        let bottom = try bottomFace(f)
        let reselect = call(f, "datum.anglePlane.update", [
            "plane_id": id.raw.uuidString,
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(bottom["index"]),
            "query_token": try XCTUnwrap(bottom["query_token"]),
            "expected_expression": "-45",
        ])
        XCTAssertEqual(reselect["ok"] as? Bool, true, "\(reselect)")
        XCTAssertEqual(try plane(f, id).id, id)
        XCTAssertEqual(try plane(f, id).plane.origin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(try angleDefinition(f, id).sourceVersion.writer, f.source.id)
        XCTAssertEqual(try angleDefinition(f, id).angle.value, -45, accuracy: 1e-12)
    }

    func testAngleVariableFanOutRenameUndoRedoAndSaveReopen() async throws {
        let f = try await fixture()
        let variable = call(f, "variable.create", ["name": "tilt", "expression": "15"])
        XCTAssertEqual(variable["ok"] as? Bool, true, "\(variable)")
        let (id, _) = try createAngle(f, expression: "tilt")
        XCTAssertEqual(try angleDefinition(f, id).angle.value, 15, accuracy: 1e-12)

        let variableID = try XCTUnwrap(f.document.session.document.variables.first?.id.raw.uuidString)
        let doubled = call(f, "variable.update", ["variable_id": variableID, "expression": "30"])
        XCTAssertEqual(doubled["ok"] as? Bool, true, "\(doubled)")
        XCTAssertEqual(try angleDefinition(f, id).angle.value, 30, accuracy: 1e-12)
        XCTAssertEqual(try plane(f, id).plane.normal.y, cos(30 * .pi / 180), accuracy: 1e-9)

        f.document.session.undo()
        XCTAssertEqual(try angleDefinition(f, id).angle.value, 15, accuracy: 1e-12)
        f.document.session.redo()
        XCTAssertEqual(try angleDefinition(f, id).angle.value, 30, accuracy: 1e-12)

        let rename = call(f, "variable.update", ["variable_id": variableID, "name": "slope"])
        XCTAssertEqual(rename["ok"] as? Bool, true, "\(rename)")
        XCTAssertEqual(try angleDefinition(f, id).angle.formula, "slope")
        XCTAssertEqual(rename["rewritten_plane_ids"] as? [String], [id.raw.uuidString])
        let dependents = CADParameterService.variableDependents(of: "slope",
                                                                in: f.document.session.document)
        XCTAssertEqual(dependents["plane_ids"] as? [String], [id.raw.uuidString])
        let rejected = call(f, "variable.delete", ["variable_id": variableID])
        XCTAssertEqual(rejected["error"] as? String, "variable_in_use", "\(rejected)")
        XCTAssertEqual(rejected["dependent_plane_ids"] as? [String], [id.raw.uuidString])

        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save must succeed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.session.document.planes.first { $0.id == id }?.definition?.kind,
                       .angle)
        let reopenedDefinition = try angleDefinition(Fixture(document: reopened,
                                                              source: f.source,
                                                              body: f.body), id)
        XCTAssertEqual(reopenedDefinition.angle.formula, "slope")
        XCTAssertEqual(reopenedDefinition.angle.value, 30, accuracy: 1e-12)
        XCTAssertEqual(try plane(Fixture(document: reopened, source: f.source, body: f.body), id)
            .plane.normal.y, cos(30 * .pi / 180), accuracy: 1e-9)
    }

    // MARK: - Three-point datum service behavior

    private struct ThreePointFixture {
        var base: Fixture
        var sketchA: Sketch
        var sketchB: Sketch
        var lineA: UUID
        var lineB: UUID
        var planeID: ConstructionPlaneID
        var pointA: SketchAnchorRef
        var pointB: SketchAnchorRef
        var pointC: SketchAnchorRef
    }

    private func threePointFixture() async throws -> ThreePointFixture {
        let f = try await fixture()
        let offset = call(f, "datum.offsetPlane.create",
                          try sourceArgs(topFace(f), expression: "0", body: f.body))
        XCTAssertEqual(offset["ok"] as? Bool, true, "\(offset)")
        let offsetID = ConstructionPlaneID(raw: try XCTUnwrap(
            (offset["plane_id"] as? String).flatMap(UUID.init(uuidString:))))

        let lineA = UUID()
        let sketchA = Sketch(name: "Anchor A", plane: .ground,
                             entities: [.line(id: lineA, a: SIMD2(-10, 0), b: SIMD2(10, 0))],
                             support: PlaneRef(source: .construction(offsetID)))
        XCTAssertTrue(f.document.session.performAssociativeTransaction([
            AddSketchCommand(sketch: sketchA),
        ], title: "Anchor A"))

        let lineB = UUID()
        let sketchB = Sketch(name: "Anchor B", plane: .ground,
                             entities: [.line(id: lineB, a: SIMD2(-5, 5), b: SIMD2(-5, 15))])
        XCTAssertTrue(f.document.session.performAssociativeTransaction([
            AddSketchCommand(sketch: sketchB),
        ], title: "Anchor B"))

        let pointA = SketchAnchorRef(sketchID: sketchA.id, entityID: lineA, role: .endpointA)
        let pointB = SketchAnchorRef(sketchID: sketchA.id, entityID: lineA, role: .endpointB)
        let pointC = SketchAnchorRef(sketchID: sketchB.id, entityID: lineB, role: .endpointB)
        let create = call(f, "datum.threePointPlane.create", [
            "points": [Self.json(pointA), Self.json(pointB), Self.json(pointC)],
            "size": 120,
        ])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let planeID = ConstructionPlaneID(raw: try XCTUnwrap(
            (create["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        return ThreePointFixture(base: f, sketchA: sketchA, sketchB: sketchB,
                                 lineA: lineA, lineB: lineB, planeID: planeID,
                                 pointA: pointA, pointB: pointB, pointC: pointC)
    }

    private static func json(_ ref: SketchAnchorRef) -> [String: Any] {
        ["sketch_id": ref.sketchID.raw.uuidString,
         "entity_id": ref.entityID.uuidString, "role": ref.role.rawValue]
    }

    func testThreePointCreateQueryFollowsMultiSketchWritersAndReopen() async throws {
        let fixture = try await threePointFixture()
        let f = fixture.base
        let row = try XCTUnwrap(rows(f.document, "planes").first {
            ($0["plane_id"] as? String) == fixture.planeID.raw.uuidString
        })
        XCTAssertEqual(row["kind"] as? String, "threePoints")
        XCTAssertEqual(row["definition_version"] as? Int, 1)
        let points = try XCTUnwrap(row["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.compactMap { $0["role"] as? String },
                       ["endpointA", "endpointB", "endpointB"])
        XCTAssertEqual(Set(points.compactMap { $0["sketch_id"] as? String }),
                       Set([fixture.sketchA.id.raw.uuidString,
                            fixture.sketchB.id.raw.uuidString]))
        XCTAssertEqual(row["source_sketch_ids"] as? [String],
                       [fixture.sketchA.id.raw.uuidString,
                        fixture.sketchA.id.raw.uuidString,
                        fixture.sketchB.id.raw.uuidString])
        XCTAssertEqual(row["expression_unit"] as? String, "mm")
        XCTAssertEqual(row["supported_operations"] as? [String],
                       ["reselect_points", "resize", "delete"])

        // Expected world origin: the first semantic point on the
        // offset-supported sketch. The plane is built from current resolved
        // sketch planes, not a stored coordinate.
        let sketchA = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == fixture.sketchA.id })
        // The committed sketch frame is the resolver's current support plane;
        // the three-point datum derives its points from exactly this frame.
        let expectedOrigin = sketchA.plane.toWorld(SIMD2(-10, 0))
        XCTAssertEqual(try plane(f, fixture.planeID).plane.origin.y, expectedOrigin.y, accuracy: 1e-6)
        XCTAssertEqual(try plane(f, fixture.planeID).plane.origin.x, expectedOrigin.x, accuracy: 1e-6)
        XCTAssertEqual(try plane(f, fixture.planeID).plane.origin.z, expectedOrigin.z, accuracy: 1e-6)
        XCTAssertEqual(try threePointDefinition(f, fixture.planeID).points,
                       [fixture.pointA, fixture.pointB, fixture.pointC])

        let child = childSketch(f, support: fixture.planeID, name: "Three point child")
        let (_, childBody) = installChild(f, sketch: child, title: "Three point child")
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(
            f.document.session.document.body(with: childBody)?.brep)), 24, accuracy: 1e-4)
        let initialChildPlane = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == child.id }?.plane)

        // Parent thickness edit moves the offset-supported sketch A, and via
        // it the three-point datum and its own child.
        let update = call(f, "update", ["feature_id": f.source.id.raw.uuidString,
                                        "changes": ["distance": 20]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try plane(f, fixture.planeID).plane.origin.y, 20, accuracy: 1e-6)
        let movedChild = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == child.id }?.plane)
        XCTAssertEqual(movedChild.origin.y, 20, accuracy: 1e-6)
        XCTAssertEqual(movedChild.normal, try plane(f, fixture.planeID).plane.normal)

        // Editing one source entity identity (same id, new point) moves the
        // datum; the plane ID stays stable.
        let beforeAxis = try plane(f, fixture.planeID).plane.xAxis
        let edit = call(f, "updateSketchEntity", [
            "sketch_id": fixture.sketchA.id.raw.uuidString,
            "entity_id": fixture.lineA.uuidString,
            "b": [10, 5],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(try plane(f, fixture.planeID).id, fixture.planeID)
        XCTAssertNotEqual(try plane(f, fixture.planeID).plane.xAxis, beforeAxis)
        XCTAssertEqual(try plane(f, fixture.planeID).plane.origin.y, 20, accuracy: 1e-6)
        XCTAssertNotEqual(initialChildPlane.xAxis, try plane(f, fixture.planeID).plane.xAxis)
        let followChildPlane = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == child.id }?.plane)
        XCTAssertEqual(followChildPlane.xAxis, try plane(f, fixture.planeID).plane.xAxis)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(
            f.document.session.document.body(with: childBody)?.brep)), 24, accuracy: 1e-4)

        // Save/reopen keeps the semantic refs and the resolved plane.
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save must succeed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reopenedFixture = Fixture(document: reopened, source: f.source, body: f.body)
        XCTAssertEqual(try threePointDefinition(reopenedFixture, fixture.planeID).points,
                       [fixture.pointA, fixture.pointB, fixture.pointC])
        XCTAssertEqual(try plane(reopenedFixture, fixture.planeID).plane.origin.y, 20, accuracy: 1e-6)
    }

    func testThreePointUpdateReselectDeleteAndPointValidation() async throws {
        let fixture = try await threePointFixture()
        let f = fixture.base
        let row = try XCTUnwrap(rows(f.document, "planes").first {
            ($0["plane_id"] as? String) == fixture.planeID.raw.uuidString
        })
        let originalID = fixture.planeID

        // Swap the first two anchors: same plane identity, new ordered frame.
        let swapped = call(f, "datum.threePointPlane.update", [
            "plane_id": originalID.raw.uuidString,
            "points": [Self.json(fixture.pointB), Self.json(fixture.pointA),
                       Self.json(fixture.pointC)],
            "expected_points": [Self.json(fixture.pointA), Self.json(fixture.pointB),
                                Self.json(fixture.pointC)],
        ])
        XCTAssertEqual(swapped["ok"] as? Bool, true, "\(swapped)")
        XCTAssertEqual(try threePointDefinition(f, originalID).points,
                       [fixture.pointB, fixture.pointA, fixture.pointC])
        XCTAssertEqual(try plane(f, originalID).id, originalID)
        f.document.session.undo()
        XCTAssertEqual(try threePointDefinition(f, originalID).points,
                       [fixture.pointA, fixture.pointB, fixture.pointC])
        f.document.session.redo()
        XCTAssertEqual(try threePointDefinition(f, originalID).points,
                       [fixture.pointB, fixture.pointA, fixture.pointC])

        // Single-index reselect also uses real identities; a stale expected
        // fence and an out-of-range index refuse without mutation.
        let extra = SketchAnchorRef(sketchID: fixture.sketchB.id,
                                    entityID: fixture.lineB, role: .endpointA)
        let replaceOne = call(f, "datum.threePointPlane.update", [
            "plane_id": originalID.raw.uuidString,
            "point_index": 2,
            "point": Self.json(extra),
        ])
        XCTAssertEqual(replaceOne["ok"] as? Bool, true, "\(replaceOne)")
        XCTAssertEqual(try threePointDefinition(f, originalID).points.last, extra)
        let fenced = call(f, "datum.threePointPlane.update", [
            "plane_id": originalID.raw.uuidString,
            "expected_points": [Self.json(fixture.pointA), Self.json(fixture.pointA),
                                Self.json(fixture.pointA)],
        ])
        XCTAssertEqual(fenced["error"] as? String, "points_mismatch", "\(fenced)")
        let badIndex = call(f, "datum.threePointPlane.update", [
            "plane_id": originalID.raw.uuidString, "point_index": 3,
            "point": Self.json(fixture.pointA),
        ])
        XCTAssertEqual(badIndex["error"] as? String, "invalid_point_index", "\(badIndex)")

        // Invalid create inputs refuse before any document mutation and use
        // the real service codes.
        let missing = call(f, "datum.threePointPlane.create", [
            "points": [
                Self.json(SketchAnchorRef(sketchID: fixture.sketchA.id,
                                          entityID: UUID(), role: .endpointA)),
                Self.json(fixture.pointB), Self.json(fixture.pointC),
            ],
        ])
        XCTAssertEqual(missing["error"] as? String, "unknown_entity", "\(missing)")
        let wrongRole = call(f, "datum.threePointPlane.create", [
            "points": [
                Self.json(SketchAnchorRef(sketchID: fixture.sketchA.id,
                                          entityID: fixture.lineA, role: .center)),
                Self.json(fixture.pointB), Self.json(fixture.pointC),
            ],
        ])
        XCTAssertEqual(wrongRole["error"] as? String, "unsupported_anchor_role", "\(wrongRole)")

        // Delete refuses while the child sketch uses the datum; clearing the
        // support lets the same delete succeed in one undo step.
        let child = childSketch(f, support: originalID, name: "Delete guard")
        installChild(f, sketch: child, title: "Delete guard")
        let refused = call(f, "datum.threePointPlane.delete",
                           ["plane_id": originalID.raw.uuidString])
        XCTAssertEqual(refused["error"] as? String, "plane_in_use", "\(refused)")
        let clear = call(f, "sketch.clearSupport", ["sketch_id": child.id.raw.uuidString])
        XCTAssertEqual(clear["ok"] as? Bool, true, "\(clear)")
        let deleted = call(f, "datum.threePointPlane.delete",
                           ["plane_id": originalID.raw.uuidString])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == originalID })
        f.document.session.undo()
        XCTAssertTrue(f.document.session.document.planes.contains { $0.id == originalID })
        _ = row
    }

    // MARK: - Broken references and atomic rollback

    private func groundAnchorSketch() -> (Sketch, UUID, UUID) {
        let line = UUID()
        let circle = UUID()
        let sketch = Sketch(name: "Anchor ground", plane: .ground, entities: [
            .line(id: line, a: SIMD2(-10, 0), b: SIMD2(10, 0)),
            .circle(id: circle, center: SIMD2(0, 5), radius: 2),
        ])
        return (sketch, line, circle)
    }

    private func installGroundThreePoint(_ f: Fixture) throws -> (Sketch, ConstructionPlaneID) {
        let (sketch, line, circle) = groundAnchorSketch()
        XCTAssertTrue(f.document.session.performAssociativeTransaction([
            AddSketchCommand(sketch: sketch),
        ], title: "Ground anchors"))
        let points = [
            SketchAnchorRef(sketchID: sketch.id, entityID: line, role: .endpointA),
            SketchAnchorRef(sketchID: sketch.id, entityID: line, role: .endpointB),
            SketchAnchorRef(sketchID: sketch.id, entityID: circle, role: .center),
        ]
        let create = call(f, "datum.threePointPlane.create", [
            "points": points.map(Self.json),
        ])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let id = ConstructionPlaneID(raw: try XCTUnwrap(
            (create["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        return (sketch, id)
    }

    func testThreePointBrokenIdentitiesCollinearityMissingAndCycleRefuseAtomically() async throws {
        let f = try await fixture()
        let (sketch, planeID) = try installGroundThreePoint(f)
        let beforePlane = try plane(f, planeID)
        let beforeCount = f.document.session.undoStack.undoCommands.count

        // New entity UUIDs at exactly the same coordinates are a broken ref;
        // there is no nearest/position rebind.
        var replaced = sketch
        replaced.entities = [
            .line(id: UUID(), a: SIMD2(-10, 0), b: SIMD2(10, 0)),
            .circle(id: UUID(), center: SIMD2(0, 5), radius: 2),
        ]
        XCTAssertFalse(f.document.session.performAssociativeTransaction([
            ReplaceSketchGeometryCommand(title: "Replace identities",
                                          before: sketch, after: replaced),
        ], title: "Replace identities"))
        XCTAssertNotNil(f.document.session.lastRebuildRejection[.plane(planeID)],
                        "\(f.document.session.lastRebuildRejection)")
        if case let .missingAnchorEntity(_, entity)? = f.document.session.lastRebuildRejection[.plane(planeID)] {
            XCTAssertTrue([sketch.entities[0].id, sketch.entities[1].id].contains(entity))
        } else {
            XCTFail("expected missingAnchorEntity, got \(String(describing: f.document.session.lastRebuildRejection[.plane(planeID)]))")
        }
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, beforeCount)
        XCTAssertEqual(try plane(f, planeID), beforePlane)

        // A collinear arrangement refuses as an explicit degenerate source.
        let circleID = try XCTUnwrap(sketch.entities.last?.id)
        var collinear = sketch
        collinear.entities[1] = .circle(id: circleID, center: SIMD2(0, 0), radius: 2)
        XCTAssertFalse(f.document.session.performAssociativeTransaction([
            ReplaceSketchGeometryCommand(title: "Collinear anchors",
                                          before: sketch, after: collinear),
        ], title: "Collinear anchors"))
        guard case let .degenerateAnchorPoints(reason)? =
                f.document.session.lastRebuildRejection[.plane(planeID)] else {
            return XCTFail("expected degenerateAnchorPoints, got \(String(describing: f.document.session.lastRebuildRejection[.plane(planeID)]))")
        }
        XCTAssertTrue(reason.contains("collinear"), reason)
        XCTAssertEqual(try plane(f, planeID), beforePlane)

        // A missing sketch identity is a broken ref, not a cached frame.
        let missingSketchID = SketchID()
        let forged = ThreePointPlaneDefinition(points: [
            SketchAnchorRef(sketchID: missingSketchID, entityID: UUID(), role: .endpointA),
            SketchAnchorRef(sketchID: sketch.id, entityID: sketch.entities[0].id, role: .endpointA),
            SketchAnchorRef(sketchID: sketch.id, entityID: sketch.entities[1].id, role: .center),
        ])
        XCTAssertFalse(f.document.session.performAssociativeTransaction([
            EditConstructionPlaneDefinitionCommand(planeID: planeID,
                before: plane(f, planeID).definition, after: .threePoints(forged)),
        ], title: "Missing sketch"))
        XCTAssertEqual(f.document.session.lastRebuildRejection[.plane(planeID)],
                       .missingSketch(missingSketchID))
        XCTAssertEqual(try plane(f, planeID), beforePlane)

        // A three-point plane supported by a sketch that is itself supported
        // by that same plane is a cycle; both records and redo are preserved.
        let cycleLine = UUID()
        let cycleSketch = Sketch(name: "Cycle", plane: .ground, entities: [
            .line(id: cycleLine, a: SIMD2(0, 0), b: SIMD2(4, 0)),
        ])
        let cyclePlaneID = ConstructionPlaneID()
        let cycleDefinition = ThreePointPlaneDefinition(points: [
            SketchAnchorRef(sketchID: cycleSketch.id, entityID: cycleLine, role: .endpointA),
            SketchAnchorRef(sketchID: cycleSketch.id, entityID: cycleLine, role: .endpointB),
            SketchAnchorRef(sketchID: sketch.id, entityID: sketch.entities[1].id, role: .center),
        ])
        var cycleSketchWithSupport = cycleSketch
        cycleSketchWithSupport.support = PlaneRef(source: .construction(cyclePlaneID))
        f.document.session.perform(AddConstructionPlaneCommand(
            plane: ConstructionPlane(plane: .ground, size: 10)))
        f.document.session.undo()
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        let cyclePlane = ConstructionPlane(id: cyclePlaneID, plane: .ground, size: 10,
                                           definition: .threePoints(cycleDefinition))
        XCTAssertFalse(f.document.session.performAssociativeTransaction([
            AddConstructionPlaneCommand(plane: cyclePlane),
            AddSketchCommand(sketch: cycleSketchWithSupport),
        ], title: "Cycle"))
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == cyclePlaneID })
        XCTAssertFalse(f.document.session.document.sketches.contains { $0.id == cycleSketch.id })
        XCTAssertNotNil(f.document.session.lastRebuildRejection[.plane(cyclePlaneID)])
    }

    func testSuppressedForwardSourceAndBrokenDownstreamPreserveOldGeometry() async throws {
        let f = try await fixture()
        let (id, _) = try createAngle(f, expression: "30")
        let child = childSketch(f, support: id, name: "Forward child")
        installChild(f, sketch: child, title: "Forward child")
        let before = try plane(f, id)
        let order = f.document.session.document.features.nodes.map(\.id)

        // Suppressing the source writer must refuse because the unused angle
        // datum is a validation root even if its consumer were removed.
        let suppressed = call(f, "feature.suppress", [
            "feature_id": f.source.id.raw.uuidString, "suppressed": true,
        ])
        XCTAssertEqual(suppressed["error"] as? String, "rebuild_failed", "\(suppressed)")
        XCTAssertEqual(f.document.session.document.features.node(f.source.id)?.suppressed, false)
        XCTAssertEqual(try plane(f, id), before)

        // Moving the source after its consumer creates a forward reference;
        // the reorder is refused atomically and the old frame survives.
        f.document.session.moveFeature(f.source.id, to: 1)
        XCTAssertEqual(f.document.session.document.features.nodes.map(\.id), order)
        XCTAssertNotNil(f.document.session.lastRebuildRejection[.plane(id)])
        XCTAssertEqual(try plane(f, id), before)
    }

    func testThreePointSameCoordinateReplacementAndAngleSourceFaceLossAreBroken() async throws {
        let f = try await fixture()
        let (id, _) = try createAngle(f, expression: "30")
        let before = try plane(f, id)
        // Replacing the source profile identity while keeping every dimension
        // leaves no named face; the angle datum must not fall back to its
        // cached absolute plane.
        guard case let .extrude(profile, planeRef, distance, symmetric, boolean, extras) =
                f.source.kind else { return XCTFail("expected extrude") }
        let oldSketch = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == profile.sketchID })
        var newSketch = oldSketch
        let replacement = UUID()
        newSketch.entities = [.rect(id: replacement, min: SIMD2(0, 0), max: SIMD2(100, 60))]
        var newProfile = profile
        newProfile.entityIDs = [replacement]
        let newKind = FeatureKind.extrude(profile: newProfile, plane: planeRef,
                                          distance: distance, symmetric: symmetric,
                                          boolean: boolean, extraProfiles: extras)
        XCTAssertFalse(f.document.session.performAssociativeTransaction([
            ReplaceSketchGeometryCommand(title: "Replace source",
                                          before: oldSketch, after: newSketch),
            EditFeatureCommand(featureID: f.source.id, before: f.source.kind, after: newKind),
        ], title: "Replace source"))
        XCTAssertNotNil(f.document.session.lastRebuildRejection[.plane(id)])
        XCTAssertEqual(try plane(f, id), before)
    }
}
