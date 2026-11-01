//
//  CADAssociativeRevolveAxisEditorTests.swift
//  FloeCADKitTests
//
//  M08 R2 native-editor source coverage for the cylinder axis pick and the
//  History-panel axis association menu. Everything routes through the SAME
//  document service the assistant uses; these tests drive the real
//  EditorViewModel in-process.
//
//  Root owns the actual iPad run.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeRevolveAxisEditorTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevolveAxisEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixtures

    private func cylinderDocument(radius: Double = 6, height: Double = 20) async throws
        -> (document: FloeCADDocument, body: BodyID) {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"),
            name: "Cylinder editor")
        documents.append(document)
        let body = BodyID()
        let node = FeatureNode(
            name: "Post", kind: .primitive(
                spec: .cylinder(radius: radius, height: height), placement: .identity),
            outputBodyIDs: [body])
        document.session.recordAndRebuild([node], title: "Post")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return (document, body)
    }

    /// A ground-plane revolve plus a construction line to bind to.
    private func revolveDocument() async throws -> (document: FloeCADDocument,
                                                    body: BodyID, revolve: FeatureNode,
                                                    sketch: Sketch, lineID: UUID) {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"),
            name: "Revolve editor")
        documents.append(document)
        let profileID = UUID()
        let lineID = UUID()
        let sketch = Sketch(name: "Revolve profile", plane: .ground, entities: [
            .rect(id: profileID, min: SIMD2(24, -10), max: SIMD2(34, 10)),
            .line(id: lineID, a: SIMD2(20, -20), b: SIMD2(20, 20)),
        ])
        let body = BodyID()
        let revolve = FeatureNode(
            name: "Revolve",
            kind: .revolve(
                profile: ProfileRef(sketchID: sketch.id, entityIDs: [profileID],
                                    holeEntityIDs: [], seedPoint: SIMD2(29, 0)),
                plane: PlaneRef(source: .sketch(sketch.id)),
                axis: AxisRef(source: .explicit(
                    RevolveAxis(point: SIMD2(20, 0), direction: SIMD2(0, 1)))),
                angle: Expr(value: 360),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [body])
        document.session.recordAndRebuild(
            [revolve], extra: [AddSketchCommand(sketch: sketch)], title: "Revolve")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return (document, body, revolve, sketch, lineID)
    }

    private func onlyAxis(_ document: FloeCADDocument) throws -> ConstructionAxis {
        try XCTUnwrap(document.session.document.axes.first)
    }

    private func assertSameTranslations(
        _ actual: [SIMD3<Double>], _ expected: [SIMD3<Double>],
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, label, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.x, e.x, accuracy: 1e-9, label, file: file, line: line)
            XCTAssertEqual(a.y, e.y, accuracy: 1e-9, label, file: file, line: line)
            XCTAssertEqual(a.z, e.z, accuracy: 1e-9, label, file: file, line: line)
        }
    }

    private func volume(_ document: FloeCADDocument, _ bodyID: BodyID) throws -> Double {
        let body = try XCTUnwrap(document.session.document.body(with: bodyID))
        return OCCTKernel.volume(try XCTUnwrap(body.brep))
    }

    // MARK: - Cylinder pick

    func testCylinderTapCreatesAnAssociativeCylinderAxis() async throws {
        let (document, body) = try await cylinderDocument()
        let model = document.viewModel()
        model.beginAxisTool()
        // A ray from +X toward the cylinder wall at mid-height (the primitive
        // OCCT cylinder spans y 0…height, axis +Y).
        model.handle(.tap(ray: Ray(origin: SIMD3<Float>(20, 10, 0),
                                   direction: SIMD3<Float>(-1, 0, 0))))
        XCTAssertEqual(model.axisPicks.count, 1)
        let picked = try XCTUnwrap(model.axisPickSources.first ?? nil)
        XCTAssertEqual(picked.surface, .cylindrical,
                       "a round face must capture a cylindrical identity")
        XCTAssertEqual(model.axisConstructionLabel, "Axis of Cylinder/Cone")
        model.commitAxis()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")

        let axis = try onlyAxis(document)
        guard case .cylinder? = axis.definition else {
            return XCTFail("a tapped round face must create an associative cylinder axis")
        }
        XCTAssertEqual(model.datumAxisKindLabel(axis.id),
                       FloeCADStrings.text("cad.datum.kind.axisCylinder", "Cylinder Axis"))

        // The resolved line is the actual cylinder centre line, not the face
        // centroid: x/z are (near) zero and the direction is the body axis.
        let cylinderBody = try XCTUnwrap(document.session.document.body(with: body))
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(cylinderBody.brep)).first {
            if case .cylindrical = $0.signature?.kind { return true }
            return false
        })
        let axisPoint = try XCTUnwrap(face.axisPoint)
        let delta = axisPoint - axis.origin
        let unit = simd_normalize(axis.direction)
        XCTAssertEqual(simd_length(delta - unit * simd_dot(delta, unit)), 0, accuracy: 1e-6)
        XCTAssertEqual(abs(simd_dot(unit, simd_normalize(face.normal))), 1, accuracy: 1e-9)
    }

    // MARK: - History panel: pattern association

    func testPatternPanelDetachFreezesTheCurrentLine() async throws {
        let (document, body, _, sketch, lineID) = try await revolveDocument()
        let model = document.viewModel()
        XCTAssertTrue(model.createDatumAxisFromPoints([
            .sketchAnchor(SketchAnchorRef(sketchID: sketch.id, entityID: lineID,
                                          role: .endpointA)),
            .sketchAnchor(SketchAnchorRef(sketchID: sketch.id, entityID: lineID,
                                          role: .endpointB)),
        ]), model.errorMessage ?? "")
        let axis = try onlyAxis(document)

        // A REAL circular pattern recorded through the panel path.
        model.selection = [body]
        model.beginPattern()
        model.patternState?.kind = .circular
        model.patternState?.constructionAxisID = axis.id
        model.patternState?.count = 3
        model.patternState?.totalAngle = 360
        model.commitPattern()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")
        let pattern = try XCTUnwrap(document.session.document.features.nodes.first {
            if case .pattern = $0.kind { return true }
            return false
        })
        guard case let .pattern(_, attached) = pattern.kind else {
            return XCTFail("the pattern node was not recorded")
        }
        XCTAssertEqual(attached.axisRef?.axisID, axis.id)
        let copiesBefore = pattern.outputBodyIDs.compactMap {
            document.session.document.body(with: $0)?.transform.translation
        }
        XCTAssertEqual(copiesBefore.count, 2)

        // The panel detaches at the axis's CURRENT resolved line.
        let currentLine = try onlyAxis(document).resolvedLine
        XCTAssertTrue(model.setFeatureConstructionAxis(pattern.id, axis: nil),
                      model.errorMessage ?? "")
        guard case let .pattern(_, detached) = try XCTUnwrap(
            document.session.document.features.node(pattern.id)).kind else {
            return XCTFail("the pattern node disappeared")
        }
        XCTAssertNil(detached.axisRef)
        XCTAssertEqual(detached.center.x, currentLine.origin.x, accuracy: 1e-9)
        XCTAssertEqual(detached.center.y, currentLine.origin.y, accuracy: 1e-9)
        XCTAssertEqual(detached.center.z, currentLine.origin.z, accuracy: 1e-9)
        XCTAssertEqual(detached.axis.x, currentLine.direction.x, accuracy: 1e-9)
        XCTAssertEqual(detached.axis.y, currentLine.direction.y, accuracy: 1e-9)
        XCTAssertEqual(detached.axis.z, currentLine.direction.z, accuracy: 1e-9)
        let copiesDetached = pattern.outputBodyIDs.compactMap {
            document.session.document.body(with: $0)?.transform.translation
        }
        assertSameTranslations(copiesDetached, copiesBefore,
                               "detaching at the current line must not move the copies")

        // A later axis-source edit no longer moves the detached pattern.
        let moved = CADParameterService(document: document).handle(
            action: "updateSketchEntity", args: [
                "sketch_id": sketch.id.raw.uuidString,
                "entity_id": lineID.uuidString,
                "a": [30, -20], "b": [30, 20],
            ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let copiesAfterMove = pattern.outputBodyIDs.compactMap {
            document.session.document.body(with: $0)?.transform.translation
        }
        assertSameTranslations(copiesAfterMove, copiesBefore,
                               "a detached pattern must keep the frozen line")

        // Undo restores the source edit only; the pattern stays detached.
        document.session.undo()
        guard case let .pattern(_, afterUndo) = try XCTUnwrap(
            document.session.document.features.node(pattern.id)).kind else {
            return XCTFail("the pattern node disappeared")
        }
        XCTAssertNil(afterUndo.axisRef)
    }

    // MARK: - History panel: revolve association

    func testRevolvePanelAttachesDetachesAndKeepsTheActualVolume() async throws {
        let (document, body, revolve, sketch, lineID) = try await revolveDocument()
        let model = document.viewModel()
        let created = model.createDatumAxisFromPoints([
            .sketchAnchor(SketchAnchorRef(sketchID: sketch.id, entityID: lineID,
                                          role: .endpointA)),
            .sketchAnchor(SketchAnchorRef(sketchID: sketch.id, entityID: lineID,
                                          role: .endpointB)),
        ])
        XCTAssertTrue(created, model.errorMessage ?? "")
        let axis = try onlyAxis(document)
        let before = try volume(document, body)
        XCTAssertEqual(before, Double.pi * 180 * 20, accuracy: 0.01)
        XCTAssertTrue(model.featureAxisChoices.contains { $0.id == axis.id })

        XCTAssertTrue(model.setFeatureConstructionAxis(revolve.id, axis: axis.id),
                      model.errorMessage ?? "")
        guard case let .revolve(_, _, ref, _, _) = try XCTUnwrap(
            document.session.document.features.node(revolve.id)).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(ref.source, .constructionAxis(axis.id))
        XCTAssertEqual(try volume(document, body), before, accuracy: 1e-6)

        // Move the axis source; the actual revolve geometry follows.
        let moved = CADParameterService(document: document).handle(
            action: "updateSketchEntity", args: [
                "sketch_id": sketch.id.raw.uuidString,
                "entity_id": lineID.uuidString,
                "a": [22, -20], "b": [22, 20],
            ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let expected = Double.pi * 140 * 20
        XCTAssertEqual(try volume(document, body), expected, accuracy: 0.01)

        XCTAssertTrue(model.setFeatureConstructionAxis(revolve.id, axis: nil),
                      model.errorMessage ?? "")
        guard case let .revolve(_, _, detached, _, _) = try XCTUnwrap(
            document.session.document.features.node(revolve.id)).kind else {
            return XCTFail("the revolve node disappeared")
        }
        guard case let .explicit(line) = detached.source else {
            return XCTFail("detaching must install an explicit line")
        }
        XCTAssertEqual(line.point.x, 22, accuracy: 1e-6)
        XCTAssertEqual(try volume(document, body), expected, accuracy: 1e-6)
    }

    // MARK: - Refusal surfaces

    func testAxisMenuRefusesANonCoplanarAxisAndKeepsTheError() async throws {
        let (document, _, revolve, _, _) = try await revolveDocument()
        let model = document.viewModel()
        // A real box whose +Y top-face axis is perpendicular to the ground
        // revolve plane: the 2D kernel cannot consume it.
        let boxID = BodyID()
        let box = FeatureNode(
            name: "Box", kind: .primitive(
                spec: .box(width: 20, depth: 20, height: 10), placement: .identity),
            outputBodyIDs: [boxID])
        document.session.perform(AppendFeatureCommand(node: box, title: "Box"))
        document.session.rebuildFrom(box.id)

        let outcome = document.nativeQueryJSON(["scope": "faces", "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload)
            as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let boxTop = try XCTUnwrap(rows.first {
            ($0["bodyID"] as? String) == boxID.raw.uuidString
                && ($0["kind"] as? String) == "planar"
                && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        })
        let create = CADParameterService(document: document).handle(
            action: "datum.axis.create", args: [
                "kind": "face", "body_id": boxID.raw.uuidString,
                "face_index": try XCTUnwrap(boxTop["index"]),
                "query_token": try XCTUnwrap(boxTop["query_token"]),
            ])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let axis = ConstructionAxisID(raw: try XCTUnwrap(
            (create["axis_id"] as? String).flatMap(UUID.init(uuidString:))))

        XCTAssertFalse(model.setFeatureConstructionAxis(revolve.id, axis: axis))
        XCTAssertEqual(model.errorMessage,
                       FloeCADStrings.text("cad.feature.axisNotInPlane",
                           "That axis does not lie in the sketch plane, so it cannot drive this revolve."))
        guard case let .revolve(_, _, ref, _, _) = try XCTUnwrap(
            document.session.document.features.node(revolve.id)).kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(ref.source, .explicit(RevolveAxis(point: SIMD2(20, 0),
                                                         direction: SIMD2(0, 1))))
    }
}
