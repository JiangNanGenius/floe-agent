//
//  CADDatumPlaneKindsEditorTests.swift
//  FloeCADKitTests
//
//  M07 — native editor source for the angle command/tool, the three-point
//  sheet path and the Items edit/reselect methods. These tests drive the real
//  EditorViewModel + document + service; Root owns the actual iPad run.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADDatumPlaneKindsEditorTests: XCTestCase {
    private func sourceFixture() async throws -> (directory: URL, document: FloeCADDocument,
                                                  source: FeatureNode, lineID: UUID) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatumPlaneKindsEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("Editor.floecad"), name: "Editor")
        let lineID = UUID()
        let entities: [SketchEntity] = [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 30)),
            .line(id: lineID, a: SIMD2(50, 5), b: SIMD2(60, 5)),
        ]
        let sketch = Sketch(name: "Source", plane: .ground, entities: entities)
        let source = FeatureNode(name: "Plate", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [entities[0].id],
                                holeEntityIDs: [], seedPoint: SIMD2(20, 15)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [BodyID()])
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)],
                                          title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return (directory, document, source, lineID)
    }

    private func tapTopFace(_ model: EditorViewModel) {
        model.handle(.tap(ray: Ray(
            origin: SIMD3<Float>(SketchPlane.ground.toWorld(SIMD2(20, 15))) + SIMD3(0, 100, 0),
            direction: SIMD3(0, -1, 0))))
    }

    private func anglePlane(_ document: FloeCADDocument) -> ConstructionPlane? {
        document.session.document.planes.first {
            if case .angle? = $0.definition { return true }
            return false
        }
    }

    private func threePointPlane(_ document: FloeCADDocument) -> ConstructionPlane? {
        document.session.document.planes.first {
            if case .threePoints? = $0.definition { return true }
            return false
        }
    }

    func testAngleCommandUsesNativeFacePickerAndSameServiceEdit() async throws {
        let f = try await sourceFixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        tapTopFace(model)
        XCTAssertNotNil(model.currentDatumFaceSelection)
        XCTAssertTrue(model.runCommand("plane.angle"),
                      "plane.angle must have a real dispatcher case on a selected face")
        guard case let .anglePlane(angle, hinge)? = model.toolContext?.kind else {
            return XCTFail("the angle plane tool must be armed with an angle/hinge")
        }
        XCTAssertEqual(angle, 30, accuracy: 1e-12)
        XCTAssertEqual(hinge, SIMD2<Double>(1, 0))

        model.setAnglePlaneAngle(30)
        model.commitTool()
        XCTAssertNil(model.errorMessage)
        let plane = try XCTUnwrap(anglePlane(f.document))
        guard case let .angle(definition)? = plane.definition else {
            return XCTFail("angle definition was not stored")
        }
        XCTAssertEqual(definition.angle.value, 30, accuracy: 1e-12)
        XCTAssertEqual(definition.hinge, SIMD2<Double>(1, 0))
        XCTAssertEqual(plane.plane.normal.y, cos(30 * .pi / 180), accuracy: 1e-9)
        let planeID = plane.id

        // The Items edit sheet calls this same view-model method and pins
        // the definition's exact stored formula (DatumPlaneSheets passes
        // `definition.angle.formula`). The native angle bar commits
        // `String(angle)`, so this datum's stored formula is "30.0", not
        // the integer spelling "30"; a mismatched fence is the intended
        // stale-CAS refusal, not an edit.
        let storedFormula = try XCTUnwrap(definition.angle.formula)
        XCTAssertEqual(storedFormula, "30.0")
        XCTAssertTrue(model.updateDatumPlane(planeID, action: "datum.anglePlane.update",
            args: ["expression": "45", "expected_expression": storedFormula,
                   "hinge_x": 1, "hinge_y": 0]))
        XCTAssertEqual(try XCTUnwrap(anglePlane(f.document)).plane.normal.y,
                       cos(45 * .pi / 180), accuracy: 1e-9)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(anglePlane(f.document)).plane.normal.y,
                       cos(30 * .pi / 180), accuracy: 1e-9)
        model.redo()
        XCTAssertEqual(try XCTUnwrap(anglePlane(f.document)).plane.normal.y,
                       cos(45 * .pi / 180), accuracy: 1e-9)

        // Source reselect from the native picker (the sheet's button path).
        tapTopFace(model)
        let selection = try XCTUnwrap(model.currentDatumFaceSelection)
        XCTAssertTrue(model.reselectDatumSource(planeID, action: "datum.anglePlane.update",
                                                selection: selection))
        let reselected = try XCTUnwrap(anglePlane(f.document))
        XCTAssertEqual(reselected.id, planeID)
        XCTAssertEqual(reselected.plane.origin.y, 10, accuracy: 1e-6)
    }

    func testThreePointCommandCandidatesCreateEditAndUndo() async throws {
        let f = try await sourceFixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        XCTAssertTrue(model.runCommand("plane.threePoints"))
        XCTAssertTrue(model.showThreePointPlaneSheet)
        model.showThreePointPlaneSheet = false

        let candidates = model.threePointAnchorCandidates
        XCTAssertGreaterThanOrEqual(candidates.count, 3)
        let refs = Array(candidates.prefix(3).map(\.ref))
        XCTAssertEqual(refs.count, 3)
        XCTAssertTrue(model.createThreePointPlane(refs))
        XCTAssertNil(model.errorMessage)
        let plane = try XCTUnwrap(threePointPlane(f.document))
        let planeID = plane.id
        guard case let .threePoints(definition)? = plane.definition else {
            return XCTFail("three-point definition was not stored")
        }
        XCTAssertEqual(definition.points, refs)
        let firstOrigin = plane.plane.origin
        let sourceSketch = try XCTUnwrap(
            f.document.session.document.sketches.first { $0.id == candidates[0].sketchID })
        let firstWorld = sourceSketch.plane.toWorld(candidates[0].point)
        XCTAssertEqual(firstOrigin.x, firstWorld.x, accuracy: 1e-6)
        XCTAssertEqual(firstOrigin.y, firstWorld.y, accuracy: 1e-6)
        XCTAssertEqual(firstOrigin.z, firstWorld.z, accuracy: 1e-6)

        // The edit sheet replaces all three persisted anchors; the plane id is
        // unchanged and undo/redo covers the whole edit.
        let swapped = [refs[1], refs[0], refs[2]]
        let payload: [[String: Any]] = swapped.map {
            ["sketch_id": $0.sketchID.raw.uuidString,
             "entity_id": $0.entityID.uuidString, "role": $0.role.rawValue]
        }
        XCTAssertTrue(model.updateDatumPlane(planeID, action: "datum.threePointPlane.update",
            args: ["points": payload, "expected_points": refs.map { ref in
                ["sketch_id": ref.sketchID.raw.uuidString,
                 "entity_id": ref.entityID.uuidString, "role": ref.role.rawValue] as [String: Any]
            }]))
        guard case let .threePoints(edited) = try XCTUnwrap(
            f.document.session.document.planes.first { $0.id == planeID }?.definition) else {
            return XCTFail("lost three-point definition")
        }
        XCTAssertEqual(edited.points, swapped)
        model.undo()
        guard case let .threePoints(restored) = try XCTUnwrap(
            f.document.session.document.planes.first { $0.id == planeID }?.definition) else {
            return XCTFail("lost three-point definition after undo")
        }
        XCTAssertEqual(restored.points, refs)
        model.redo()
        XCTAssertEqual(try XCTUnwrap(threePointPlane(f.document)?.definition), .threePoints(edited))
    }

    func testReopenedThreePointDatumAndChildFollowTheNativeHistoryParentEdit() async throws {
        var documents: [FloeCADDocument] = []
        defer {
            for document in documents where !document.isClosed { document.close() }
            CADDatumPlaneFormFixture.removeAllFixtures()
        }
        let document = try await CADDatumPlaneFormFixture.open(
            mode: .threePoint, reset: true, reopen: false)
        documents.append(document)
        let anchorA = try XCTUnwrap(document.session.document.sketches.first { $0.name == "Anchor A" })
        let anchorB = try XCTUnwrap(document.session.document.sketches.first { $0.name == "Anchor B" })
        func record(_ label: String, _ document: FloeCADDocument) throws {
            let encoder = cadRecordEncoder()
            let data = try encoder.encode(document.session.document.sketches)
            let planes = try encoder.encode(document.session.document.planes)
            let attachment = XCTAttachment(string: "\(label)\nSKETCHES\n"
                + String(decoding: data, as: UTF8.self) + "\nPLANES\n"
                + String(decoding: planes, as: UTF8.self))
            attachment.name = "Exact synthetic M07 records \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try record("seed", document)
        let lineA = try XCTUnwrap(anchorA.entities.first)
        let lineB = try XCTUnwrap(anchorB.entities.first)
        let refs = [
            SketchAnchorRef(sketchID: anchorA.id, entityID: lineA.id, role: .endpointA),
            SketchAnchorRef(sketchID: anchorB.id, entityID: lineB.id, role: .endpointA),
            SketchAnchorRef(sketchID: anchorB.id, entityID: lineB.id, role: .endpointB),
        ]
        XCTAssertTrue(document.viewModel().createThreePointPlane(refs))
        try record("created", document)
        let planeID = try XCTUnwrap(threePointPlane(document)).id
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save failed")
        try record("saved", document)
        document.close()

        // Exact same reopen preparation as the UI: installs a real dependent
        // sketch/extrusion, then edits the parent through History's VM method.
        let reopened = try await CADDatumPlaneFormFixture.open(
            mode: .threePoint, reset: false, reopen: true)
        documents.append(reopened)
        try record("reopened", reopened)
        let parent = try XCTUnwrap(reopened.session.document.features.nodes.first { $0.name == "ParentPlate" })
        let child = try XCTUnwrap(reopened.session.document.sketches.first { $0.name == "Three point child" })
        XCTAssertEqual(try XCTUnwrap(threePointPlane(reopened)).plane.origin.y, 10, accuracy: 1e-6)
        reopened.viewModel().editFeatureScalar(parent.id, key: .primary, value: 20)
        try record("parent-edited", reopened)
        let readback = CADDatumPlaneFormFixture.readback(document: reopened, focus: .threePoint)
        let diagnostics = "\(readback.plane) | \(readback.bodies) | \(readback.errors)"
        XCTAssertEqual(try XCTUnwrap(threePointPlane(reopened)).id, planeID)
        XCTAssertEqual(try XCTUnwrap(threePointPlane(reopened)).plane.origin.y, 20,
                       accuracy: 1e-6, diagnostics)
        XCTAssertEqual(try XCTUnwrap(reopened.session.document.sketches.first { $0.id == anchorA.id }).plane.origin.y,
                       20, accuracy: 1e-6, diagnostics)
        XCTAssertEqual(try XCTUnwrap(reopened.session.document.sketches.first { $0.id == child.id }).plane.origin.y,
                       20, accuracy: 1e-6, diagnostics)
        XCTAssertTrue(reopened.session.lastReferenceErrors.isEmpty, diagnostics)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty, diagnostics)
    }

    func testOffsetCommandStillArmsExistingDatumToolAndThreePointCandidateRolesAreReal() async throws {
        let f = try await sourceFixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        tapTopFace(model)
        XCTAssertTrue(model.runCommand("plane.offset"))
        guard case .offsetPlane? = model.toolContext?.kind else {
            return XCTFail("plane.offset must arm the existing offset datum tool")
        }
        model.cancelTool()

        let candidates = model.threePointAnchorCandidates
        XCTAssertTrue(candidates.contains { $0.role == .endpointA })
        XCTAssertTrue(candidates.contains { $0.role == .endpointB })
        XCTAssertFalse(candidates.contains { $0.role == .whole })
        XCTAssertFalse(candidates.contains { $0.role == .radiusOnly })
        for candidate in candidates {
            let sketch = f.document.session.document.sketches.first { $0.id == candidate.sketchID }
            XCTAssertNotNil(sketch, "a candidate must name a live sketch")
            XCTAssertNotNil(sketch?.entities.first { $0.id == candidate.entityID },
                            "a candidate must name a live entity")
        }
    }
}
