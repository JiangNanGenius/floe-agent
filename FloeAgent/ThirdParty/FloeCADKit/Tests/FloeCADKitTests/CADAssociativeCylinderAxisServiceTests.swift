//
//  CADAssociativeCylinderAxisServiceTests.swift
//  FloeCADKitTests
//
//  M08 R2 — real OCCT/document/service coverage for the CYLINDRICAL
//  associative construction axis: creation from an actual cylinder face, the
//  exact analytic axis point (not the centroid), offset refusal, reselect,
//  source-loss refusal, a REAL circular-pattern consumer and save/reopen.
//
//  Requires the OCCT kernel (the document tests always do).
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeCylinderAxisServiceTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCylinderAxis-\(UUID().uuidString)")
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
        var source: FeatureNode
        var body: BodyID
    }

    /// A real OCCT cylinder primitive: radius 6 mm, height 20 mm, axis +Y
    /// through the body origin.
    private func fixture(radius: Double = 6, height: Double = 20,
                         name: String = "Post") async throws -> Fixture {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Cylinder")
        documents.append(document)
        let body = BodyID()
        let source = FeatureNode(
            name: name,
            kind: .primitive(spec: .cylinder(radius: radius, height: height),
                             placement: .identity),
            outputBodyIDs: [body])
        document.session.recordAndRebuild([source], title: name)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return Fixture(document: document, source: source, body: body)
    }

    private func rows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope, "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    private func cylindricalFace(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && ($0["kind"] as? String) == "cylindrical"
        })
    }

    private func planarFace(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && ($0["kind"] as? String) == "planar"
        })
    }

    private func call(_ f: Fixture, _ action: String, _ args: [String: Any]) -> [String: Any] {
        CADParameterService(document: f.document).handle(action: action, args: args)
    }

    private func axisID(_ reply: [String: Any]) throws -> ConstructionAxisID {
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return ConstructionAxisID(raw: try XCTUnwrap(
            (reply["axis_id"] as? String).flatMap(UUID.init(uuidString:))))
    }

    private func axis(_ f: Fixture, _ id: ConstructionAxisID) throws -> ConstructionAxis {
        try XCTUnwrap(f.document.session.document.axes.first { $0.id == id })
    }

    /// Creation args, or update args when `axis` is supplied.
    ///
    /// `datum.axis.update` identifies the row it edits with `axis_id`; a
    /// source triple alone is a create, not an update of an existing axis.
    private func cylinderAxisArgs(
        _ f: Fixture, face: [String: Any], axis: ConstructionAxisID? = nil
    ) throws -> [String: Any] {
        var args: [String: Any] = ["kind": "cylinder", "body_id": f.body.raw.uuidString,
                                   "face_index": try XCTUnwrap(face["index"]),
                                   "query_token": try XCTUnwrap(face["query_token"])]
        if let axis { args["axis_id"] = axis.raw.uuidString }
        return args
    }

    private func distanceToLine(_ point: SIMD3<Double>, origin: SIMD3<Double>,
                                direction: SIMD3<Double>) -> Double {
        let d = point - origin
        let unit = simd_normalize(direction)
        return simd_length(d - unit * simd_dot(d, unit))
    }

    private enum FixtureError: Error { case faceIsNotACylinder(Int) }

    /// The kernel's own analytic cylinder axis for the same body face.
    private func kernelCylinderAxis(_ f: Fixture, at index: Int)
        throws -> (point: SIMD3<Double>, direction: SIMD3<Double>, radius: Double) {
        let body = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let brep = try XCTUnwrap(body.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.index == index })
        guard case let .cylindrical(radius) = face.signature?.kind else {
            XCTFail("face \(index) is not cylindrical")
            throw FixtureError.faceIsNotACylinder(index)
        }
        let point = try XCTUnwrap(face.axisPoint)
        return (point, face.normal, radius)
    }

    /// One REAL circular-pattern consumer of the cylinder axis.
    @discardableResult
    private func addCircularPattern(_ f: Fixture, axisID: ConstructionAxisID,
                                    count: Int = 2, totalAngle: Double = .pi) throws -> FeatureID {
        let node = FeatureNode(
            name: "Pattern",
            kind: .pattern(
                body: BodyRef(producer: f.source.id, bodyID: f.body),
                spec: PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                                  count: count, spacing: 0, totalAngle: totalAngle,
                                  rotateInstances: true,
                                  axisRef: ConstructionAxisRef(axisID))),
            outputBodyIDs: (1..<count).map { _ in BodyID() })
        f.document.session.perform(AppendFeatureCommand(node: node, title: "Pattern"))
        f.document.session.rebuildFrom(f.source.id)
        return node.id
    }

    private func patternNode(_ f: Fixture) throws -> FeatureNode {
        try XCTUnwrap(f.document.session.document.features.nodes.first {
            if case .pattern = $0.kind { return true }
            return false
        })
    }

    private func patternCopies(_ f: Fixture, _ node: FeatureNode) -> [Body] {
        node.outputBodyIDs.compactMap { f.document.session.document.body(with: $0) }
    }

    // MARK: - Create / exact analytic line / query

    func testCylinderAxisCreateUsesTheExactAnalyticAxisPoint() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        XCTAssertEqual(face["kind"] as? String, "cylindrical")
        XCTAssertEqual(face["datum_source_supported"] as? Bool, true,
                       "a cylindrical face is a valid construction-axis source: \(face)")
        XCTAssertEqual(face["datum_action"] as? String, "datum.axis.create")
        XCTAssertEqual(face["datum_axis_kind"] as? String, "cylinder")

        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))
        let record = try axis(f, id)
        guard case let .cylinder(definition)? = record.definition else {
            return XCTFail("a cylinder axis must store a cylinder definition")
        }
        XCTAssertEqual(definition.version, CylinderAxisDefinition.supportedVersion)
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(definition.sourceVersion.bodyID, f.body)

        let kernel = try kernelCylinderAxis(f, at: try XCTUnwrap(face["index"] as? Int))
        XCTAssertEqual(distanceToLine(kernel.point, origin: record.origin,
                                      direction: record.direction), 0, accuracy: 1e-6,
                       "the resolved line must pass through the kernel's analytic axis point")
        XCTAssertEqual(abs(simd_dot(simd_normalize(record.direction),
                                    simd_normalize(kernel.direction))), 1, accuracy: 1e-9,
                       "the resolved direction is the analytic cylinder direction")
        guard case let .cylindrical(radius) = definition.source.signature.kind else {
            return XCTFail("the persisted FaceRef must carry the cylindrical signature")
        }
        XCTAssertEqual(radius, kernel.radius, accuracy: 1e-9)

        let row = try XCTUnwrap(rows(f.document, "axes").first {
            ($0["axis_id"] as? String) == id.raw.uuidString
        })
        XCTAssertEqual(row["kind"] as? String, "cylinder")
        XCTAssertEqual(row["surface_mode"] as? String, "cylinder")
        XCTAssertEqual(row["definition_version"] as? Int, 1)
        XCTAssertEqual(row["offset_supported"] as? Bool, false)
        XCTAssertEqual(row["status"] as? String, "resolved")
        XCTAssertEqual(row["frame_status"] as? String, "resolved")
        XCTAssertEqual(row["source_writer_id"] as? String, f.source.id.raw.uuidString)
        XCTAssertNotNil(row["frame"])

        // No offset: a cylinder is rotationally symmetric, so a perpendicular
        // displacement has no source-defined direction.
        let refused = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "offset": "5",
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "offset_unsupported")

        // A radius edit on the source keeps the SAME analytic centre line: the
        // axis must stay resolved and still pass through it (a cached centroid
        // would drift with the new centroid).
        let resized = call(f, "update", [
            "feature_id": f.source.id.raw.uuidString, "changes": ["radius": 9],
        ])
        XCTAssertEqual(resized["ok"] as? Bool, true, "\(resized)")
        let resizedRecord = try axis(f, id)
        let refreshedFace = try cylindricalFace(f)
        let resizedKernel = try kernelCylinderAxis(
            f, at: try XCTUnwrap(refreshedFace["index"] as? Int))
        XCTAssertEqual(resizedKernel.radius, 9, accuracy: 1e-6)
        XCTAssertEqual(distanceToLine(resizedKernel.point, origin: resizedRecord.origin,
                                      direction: resizedRecord.direction), 0, accuracy: 1e-6,
                       "a radius edit must not move the centre line")
        XCTAssertNil(f.document.session.lastReferenceErrors[.axis(id)])
    }

    func testCylinderAxisReselectsTheCylinderAndRefusesAPlanarFace() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))

        // Re-selecting the SAME unchanged source is the service's explicit
        // no_change, not a silent rewrite.
        let refresh = try cylindricalFace(f)
        let noChange = call(f, "datum.axis.update", try cylinderAxisArgs(f, face: refresh, axis: id))
        XCTAssertEqual(noChange["ok"] as? Bool, false, "\(noChange)")
        XCTAssertEqual(noChange["error"] as? String, "no_change")

        // Resize the source, then RESELECT the same named face: the definition
        // must take the current cylindrical signature (a real reselect) and
        // keep its identity and kind.
        let resized = call(f, "update", [
            "feature_id": f.source.id.raw.uuidString, "changes": ["radius": 9],
        ])
        XCTAssertEqual(resized["ok"] as? Bool, true, "\(resized)")
        let resizedFace = try cylindricalFace(f)
        let reselect = call(f, "datum.axis.update", try cylinderAxisArgs(f, face: resizedFace, axis: id))
        XCTAssertEqual(reselect["ok"] as? Bool, true, "\(reselect)")
        guard case let .cylinder(definition)? = try axis(f, id).definition else {
            return XCTFail("reselect must keep the cylinder kind")
        }
        guard case let .cylindrical(radius) = definition.source.signature.kind else {
            return XCTFail("the reselected FaceRef must stay cylindrical")
        }
        XCTAssertEqual(radius, 9, accuracy: 1e-6)

        // A planar cap is NOT a cylinder source, and the refusal must not
        // silently create a planar-normal axis.
        let cap = try planarFace(f)
        let refused = call(f, "datum.axis.update", try cylinderAxisArgs(f, face: cap, axis: id))
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "named_cylinder_source_required")
        guard case .cylinder? = try axis(f, id).definition else {
            return XCTFail("a refused reselect must not change the definition")
        }
    }

    func testCylinderAxisRejectsAStaleQueryToken() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))
        // Any document edit invalidates the generation the token was minted in.
        _ = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "size": 42,
        ])
        let stale = call(f, "datum.axis.update", try cylinderAxisArgs(f, face: face, axis: id))
        XCTAssertEqual(stale["ok"] as? Bool, false, "\(stale)")
        XCTAssertEqual(stale["error"] as? String, "stale_query")
    }

    // MARK: - Real pattern consumer

    func testCylinderAxisDrivesARealCircularPattern() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))
        _ = try addCircularPattern(f, axisID: id, count: 2, totalAngle: .pi)
        let node = try patternNode(f)
        let copies = patternCopies(f, node)
        XCTAssertEqual(copies.count, 1)
        // 180° about the cylinder's +Y axis maps +X onto −X.
        let copy = try XCTUnwrap(copies.first)
        let rotated = copy.transform.rotation.act(SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(rotated.x, -1, accuracy: 1e-6)
        XCTAssertEqual(rotated.y, 0, accuracy: 1e-6)
        XCTAssertEqual(copy.transform.translation.x, 0, accuracy: 1e-6)
        XCTAssertEqual(copy.transform.translation.z, 0, accuracy: 1e-6)

        // The axis query reports the actual consumer.
        let row = try XCTUnwrap(rows(f.document, "axes").first {
            ($0["axis_id"] as? String) == id.raw.uuidString
        })
        XCTAssertEqual(row["used_by_pattern_feature_ids"] as? [String], [node.id.raw.uuidString])
        XCTAssertEqual(row["used_by_feature_ids"] as? [String], [node.id.raw.uuidString])

        // Deleting the axis is refused while the pattern consumes it.
        let refused = call(f, "datum.axis.delete", ["axis_id": id.raw.uuidString])
        XCTAssertEqual(refused["error"] as? String, "axis_in_use")
        XCTAssertEqual(refused["dependent_pattern_feature_ids"] as? [String],
                       [node.id.raw.uuidString])
    }

    func testBrokenCylinderSourceRefusesAtomicallyAndKeepsThePreviousDocument() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))
        try addCircularPattern(f, axisID: id, count: 3, totalAngle: 2 * .pi)
        f.document.session.rebuildFrom(f.source.id)
        XCTAssertEqual(patternCopies(f, try patternNode(f)).count, 2)

        // Suppress the cylinder's writer: the axis has no snapshot to resolve.
        let suppress = call(f, "feature.suppress", [
            "feature_id": f.source.id.raw.uuidString, "suppressed": true,
        ])
        // The edit itself must be refused (a broken consumer), and the document
        // must keep the previous geometry and axis state.
        XCTAssertEqual(suppress["ok"] as? Bool, false, "\(suppress)")
        XCTAssertEqual(suppress["error"] as? String, "rebuild_failed")
        XCTAssertEqual(f.document.session.document.features.node(f.source.id)?.suppressed, false)
        XCTAssertEqual(patternCopies(f, try patternNode(f)).count, 2)
        XCTAssertNil(f.document.session.lastReferenceErrors[.axis(id)],
                     "the live document still resolves the axis")
    }

    // MARK: - Save / reopen

    func testSaveReopenKeepsCylinderAxisAndItsPatternConsumer() async throws {
        let f = try await fixture()
        let face = try cylindricalFace(f)
        let id = try axisID(call(f, "datum.axis.create", try cylinderAxisArgs(f, face: face)))
        try addCircularPattern(f, axisID: id, count: 3, totalAngle: 2 * .pi)
        f.document.session.rebuildFrom(f.source.id)
        let before = patternCopies(f, try patternNode(f)).map(\.transform.translation)
        let kernel = try kernelCylinderAxis(f, at: try XCTUnwrap(face["index"] as? Int))
        let originBefore = try axis(f, id).origin
        let directionBefore = try axis(f, id).direction

        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save must succeed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let reopenedAxis = try XCTUnwrap(reopened.session.document.axes.first { $0.id == id })
        guard case .cylinder? = reopenedAxis.definition else {
            return XCTFail("the cylinder definition must survive reopen")
        }
        XCTAssertEqual(reopenedAxis.origin.x, originBefore.x, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.origin.y, originBefore.y, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.origin.z, originBefore.z, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.x, directionBefore.x, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.y, directionBefore.y, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.z, directionBefore.z, accuracy: 1e-9)
        XCTAssertEqual(distanceToLine(kernel.point, origin: reopenedAxis.origin,
                                      direction: reopenedAxis.direction), 0, accuracy: 1e-6,
                       "the reopened line still passes through the analytic axis point")

        let reopenedPattern = try XCTUnwrap(reopened.session.document.features.nodes.first {
            if case .pattern = $0.kind { return true }
            return false
        })
        guard case let .pattern(_, spec) = reopenedPattern.kind else {
            return XCTFail("the pattern node must survive reopen")
        }
        XCTAssertEqual(spec.axisRef?.axisID, id)
        let reopenedCopies = reopenedPattern.outputBodyIDs.compactMap {
            reopened.session.document.body(with: $0)
        }.map(\.transform.translation)
        XCTAssertEqual(reopenedCopies.count, before.count)
        for (actual, expected) in zip(reopenedCopies, before) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(actual.z, expected.z, accuracy: 1e-9)
        }
    }
}
