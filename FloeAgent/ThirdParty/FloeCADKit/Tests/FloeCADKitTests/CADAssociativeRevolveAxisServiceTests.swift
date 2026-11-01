//
//  CADAssociativeRevolveAxisServiceTests.swift
//  FloeCADKitTests
//
//  M08 R2 — the REAL revolve consumer of an associative construction axis.
//
//  A revolve's kernel axis is 2D in the sketch plane, so this covers: attach
//  through `feature.update`, the resolved world line being converted into that
//  basis, a parent axis edit changing the actual volume, an explicit detach
//  freezing the CURRENT line, undo/redo, save/reopen, and the refusals
//  (non-coplanar axis, deleting the axis source).
//
//  Requires the OCCT kernel (the document tests always do).
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeRevolveAxisServiceTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRevolveAxis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixture

    private struct Fixture {
        var document: FloeCADDocument
        var sketch: Sketch
        var profileID: UUID
        var axisLineID: UUID
        var body: BodyID
        var revolve: FeatureNode
        var boxBody: BodyID
    }

    /// Ground-plane rectangular profile (sketch u 24…34, v −10…10) and a
    /// construction line at u = 20. Revolving about that line gives an exact
    /// annulus: outer 14 mm, inner 4 mm, height 20 mm.
    private func fixture(axisU: Double = 20) async throws -> Fixture {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Revolve")
        documents.append(document)
        let profileID = UUID()
        let lineID = UUID()
        let sketch = Sketch(name: "Revolve profile", plane: .ground, entities: [
            .rect(id: profileID, min: SIMD2(24, -10), max: SIMD2(34, 10)),
            .line(id: lineID, a: SIMD2(axisU, -20), b: SIMD2(axisU, 20)),
        ])
        let body = BodyID()
        let revolve = FeatureNode(
            name: "Revolve",
            kind: .revolve(
                profile: ProfileRef(sketchID: sketch.id, entityIDs: [profileID],
                                    holeEntityIDs: [], seedPoint: SIMD2(29, 0)),
                plane: PlaneRef(source: .sketch(sketch.id)),
                axis: AxisRef(source: .explicit(
                    RevolveAxis(point: SIMD2(axisU, 0), direction: SIMD2(0, 1)))),
                angle: Expr(value: 360),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [body])
        // A second, unrelated body whose top face gives a NON-coplanar axis.
        let boxBody = BodyID()
        let box = FeatureNode(
            name: "Box", kind: .primitive(
                spec: .box(width: 20, depth: 20, height: 10), placement: .identity),
            outputBodyIDs: [boxBody])
        document.session.recordAndRebuild(
            [revolve, box], extra: [AddSketchCommand(sketch: sketch)], title: "Revolve")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        XCTAssertTrue(document.session.lastReferenceErrors.isEmpty,
                      "\(document.session.lastReferenceErrors)")
        return Fixture(document: document, sketch: sketch, profileID: profileID,
                       axisLineID: lineID, body: body, revolve: revolve, boxBody: boxBody)
    }

    private func rows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope, "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    private func call(_ f: Fixture, _ action: String, _ args: [String: Any]) -> [String: Any] {
        CADParameterService(document: f.document).handle(action: action, args: args)
    }

    private func revolveNode(_ f: Fixture) throws -> FeatureNode {
        try XCTUnwrap(f.document.session.document.features.node(f.revolve.id))
    }

    private func volume(_ f: Fixture, _ bodyID: BodyID) throws -> Double {
        let body = try XCTUnwrap(f.document.session.document.body(with: bodyID))
        return OCCTKernel.volume(try XCTUnwrap(body.brep))
    }

    private func updateAxisLine(_ f: Fixture, toU u: Double) -> [String: Any] {
        call(f, "updateSketchEntity", [
            "sketch_id": f.sketch.id.raw.uuidString,
            "entity_id": f.axisLineID.uuidString,
            "a": [u, -20], "b": [u, 20],
        ])
    }

    private func twoPointAxis(_ f: Fixture) throws -> ConstructionAxisID {
        let reply = call(f, "datum.axis.create", [
            "kind": "twoPoints",
            "points": [
                ["sketch_id": f.sketch.id.raw.uuidString,
                 "entity_id": f.axisLineID.uuidString, "role": "endpointA"],
                ["sketch_id": f.sketch.id.raw.uuidString,
                 "entity_id": f.axisLineID.uuidString, "role": "endpointB"],
            ],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return ConstructionAxisID(raw: try XCTUnwrap(
            (reply["axis_id"] as? String).flatMap(UUID.init(uuidString:))))
    }

    private func attach(_ f: Fixture, _ axis: ConstructionAxisID) -> [String: Any] {
        call(f, "update", ["feature_id": f.revolve.id.raw.uuidString,
                           "changes": ["axis_id": axis.raw.uuidString]])
    }

    private func detach(_ f: Fixture) -> [String: Any] {
        call(f, "update", ["feature_id": f.revolve.id.raw.uuidString,
                           "changes": ["axis_id": NSNull()]])
    }

    private var annulusVolume: Double { Double.pi * 180 * 20 }

    // MARK: - Attach + follow

    func testRevolveAttachesToTheAxisAndFollowsItsSourceEdit() async throws {
        let f = try await fixture()
        let axis = try twoPointAxis(f)
        let initial = try volume(f, f.body)
        XCTAssertEqual(initial, annulusVolume, accuracy: 0.01)

        let reply = attach(f, axis)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["mutated"] as? Bool, true)
        guard case let .revolve(_, _, ref, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(ref.source, .constructionAxis(axis),
                       "the node must persist the axis IDENTITY")
        // The converted line is the same line, so the geometry is unchanged.
        XCTAssertEqual(try volume(f, f.body), initial, accuracy: 1e-6)

        // The query reports the actual revolve consumer.
        let row = try XCTUnwrap(rows(f.document, "axes").first {
            ($0["axis_id"] as? String) == axis.raw.uuidString
        })
        XCTAssertEqual(row["used_by_revolve_feature_ids"] as? [String],
                       [f.revolve.id.raw.uuidString])
        XCTAssertEqual(row["status"] as? String, "resolved")

        // Editing the axis SOURCE moves the axis; the actual volume must move
        // with it (outer 12, inner 2, height 20).
        let moved = updateAxisLine(f, toU: 22)
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let expected = Double.pi * (144 - 4) * 20
        XCTAssertEqual(try volume(f, f.body), expected, accuracy: 0.01,
                       "the revolve must spin about the CURRENT axis line")
        XCTAssertNotEqual(try volume(f, f.body), initial, accuracy: 1e-6)

        // Deleting the axis is refused while the revolve consumes it.
        let refused = call(f, "datum.axis.delete", ["axis_id": axis.raw.uuidString])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "axis_in_use")
        XCTAssertEqual(refused["dependent_revolve_feature_ids"] as? [String],
                       [f.revolve.id.raw.uuidString])
    }

    func testAttachRefusesANonCoplanarAxisWithoutChangingTheDocument() async throws {
        let f = try await fixture()
        let initial = try volume(f, f.body)
        // A real face axis on the box's +Y face: its line is perpendicular to
        // the ground plane, so the 2D revolve kernel cannot consume it.
        let faces = try rows(f.document, "faces").filter {
            ($0["bodyID"] as? String) == f.boxBody.raw.uuidString
                && ($0["kind"] as? String) == "planar"
                && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        }
        let face = try XCTUnwrap(faces.first)
        let create = call(f, "datum.axis.create", [
            "kind": "face", "body_id": f.boxBody.raw.uuidString,
            "face_index": try XCTUnwrap(face["index"]),
            "query_token": try XCTUnwrap(face["query_token"]),
        ])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let axis = ConstructionAxisID(raw: try XCTUnwrap(
            (create["axis_id"] as? String).flatMap(UUID.init(uuidString:))))

        let refused = attach(f, axis)
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "axis_not_in_plane")
        guard case let .revolve(_, _, ref, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(ref.source, .explicit(RevolveAxis(point: SIMD2(20, 0),
                                                         direction: SIMD2(0, 1))),
                       "a refused attach must not repoint the revolve")
        XCTAssertEqual(try volume(f, f.body), initial, accuracy: 1e-6)
    }

    // MARK: - Detach freezes the CURRENT line

    func testDetachFreezesTheCurrentLineAndStopsFollowingTheSource() async throws {
        let f = try await fixture()
        let axis = try twoPointAxis(f)
        XCTAssertEqual(attach(f, axis)["ok"] as? Bool, true)
        let moved = updateAxisLine(f, toU: 22)
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let attachedVolume = try volume(f, f.body)
        XCTAssertEqual(attachedVolume, Double.pi * 140 * 20, accuracy: 0.01)

        let cleared = detach(f)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "\(cleared)")
        guard case let .revolve(_, _, ref, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        guard case let .explicit(line) = ref.source else {
            return XCTFail("detaching must install an explicit line")
        }
        // The frozen line is the CURRENT axis (u = 22), not the creation-time
        // one (u = 20) — clearing after an upstream edit must not jump back.
        XCTAssertEqual(line.point.x, 22, accuracy: 1e-6)
        XCTAssertEqual(abs(line.direction.y), 1, accuracy: 1e-9)
        XCTAssertEqual(try volume(f, f.body), attachedVolume, accuracy: 1e-6,
                       "detaching must keep the geometry")

        // Move only the reference line, keeping it outside the profile's
        // u=24...34 rectangle. Moving the ordinary sketch line to u=30 would
        // split that profile at the seed and change its region independently
        // of the frozen revolve axis (FeatureGraph.resolveProfile).
        let later = updateAxisLine(f, toU: 12)
        XCTAssertEqual(later["ok"] as? Bool, true, "\(later)")
        let relocatedSource = try XCTUnwrap(f.document.session.currentResolvedAxis(axis))
        XCTAssertEqual(relocatedSource.origin.x, 12, accuracy: 1e-6,
                       "the detached axis source itself must really move")
        guard case let .revolve(_, _, stillDetached, _, _) = try revolveNode(f).kind else {
            return XCTFail("the detached revolve disappeared")
        }
        XCTAssertEqual(stillDetached.source, .explicit(line),
                       "the source edit must not restore an association")
        XCTAssertEqual(try volume(f, f.body), attachedVolume, accuracy: 1e-6)

        // Undo the source edit, then undo the detach: the relationship returns.
        f.document.session.undo()
        XCTAssertEqual(try volume(f, f.body), attachedVolume, accuracy: 1e-6)
        f.document.session.undo()
        guard case let .revolve(_, _, restored, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(restored.source, .constructionAxis(axis))
        XCTAssertEqual(try volume(f, f.body), attachedVolume, accuracy: 0.01)
        f.document.session.redo()
        guard case let .revolve(_, _, redone, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(redone.source, .explicit(line))
    }

    func testDetachRefusesWhenTheAxisSourceNoLongerResolves() async throws {
        let f = try await fixture()
        let axis = try twoPointAxis(f)
        XCTAssertEqual(attach(f, axis)["ok"] as? Bool, true)

        // Deleting the axis's source line would leave the revolve with no
        // resolvable current line, so the delete itself must roll back.
        let deleted = call(f, "deleteSketchEntity", [
            "sketch_id": f.sketch.id.raw.uuidString,
            "entity_id": f.axisLineID.uuidString,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, false, "\(deleted)")
        XCTAssertEqual(deleted["error"] as? String, "rebuild_failed")
        XCTAssertEqual(deleted["rolled_back"] as? Bool, true)
        XCTAssertNotNil(f.document.session.document.sketches.first {
            $0.id == f.sketch.id
        }?.entities.first { $0.id == f.axisLineID },
                        "the refused delete must preserve the source line")
        XCTAssertEqual(try volume(f, f.body), annulusVolume, accuracy: 0.01)
        guard case let .revolve(_, _, ref, _, _) = try revolveNode(f).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(ref.source, .constructionAxis(axis))
    }

    // MARK: - Save / reopen

    func testSavedRevolveKeepsTheAxisIdentityAndTheAttachedGeometry() async throws {
        let f = try await fixture()
        let axis = try twoPointAxis(f)
        XCTAssertEqual(attach(f, axis)["ok"] as? Bool, true)
        let moved = updateAxisLine(f, toU: 22)
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let expected = try volume(f, f.body)

        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save must succeed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let node = try XCTUnwrap(reopened.session.document.features.node(f.revolve.id))
        guard case let .revolve(_, _, ref, _, _) = node.kind else {
            return XCTFail("the revolve node did not survive reopen")
        }
        XCTAssertEqual(ref.source, .constructionAxis(axis),
                       "the axis identity, not a baked line, must be persisted")
        let body = try XCTUnwrap(reopened.session.document.body(with: f.body))
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep)), expected, accuracy: 0.01)
    }
}
