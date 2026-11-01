//
//  CADAssociativeAxisPointServiceTests.swift
//  FloeCADKitTests
//
//  M08 — real OCCT/document/service coverage for associative construction axes
//  and datum points: creation from a face/edge/two planes/two points, query
//  rows, offset edits, source reselect, a REAL circular-pattern consumer,
//  broken-source refusal, delete guards and save/reopen.
//
//  Requires the OCCT kernel (the document tests always do).
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeAxisPointServiceTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeAxisPoint-\(UUID().uuidString)")
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
        var sketch: Sketch
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
            name: "Axis point")
        documents.append(document)
        let sketch = Sketch(name: "Plate", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60)),
            .line(id: UUID(), a: SIMD2(10, 30), b: SIMD2(90, 30)),
        ])
        let body = BodyID()
        let source = extrusion(sketch, distance: thickness, body: body, name: "Plate")
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)],
                                          title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return Fixture(document: document, source: source, body: body, sketch: sketch)
    }

    private func rows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope, "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    private func face(_ f: Fixture, normalY: Double) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && (($0["normal"] as? [Double])?[1] ?? 0) * normalY > 0.99
        })
    }

    private func topFace(_ f: Fixture) throws -> [String: Any] { try face(f, normalY: 1) }

    private func bottomFace(_ f: Fixture) throws -> [String: Any] { try face(f, normalY: -1) }

    private func face(_ f: Fixture, normalX: Double) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
                && (($0["normal"] as? [Double])?[0] ?? 0) * normalX > 0.99
        })
    }

    private func topEdge(_ f: Fixture) throws -> [String: Any] {
        let bodyRow = try XCTUnwrap(rows(f.document, "edges").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString
        })
        let edges = try XCTUnwrap(bodyRow["edges"] as? [[String: Any]])
        let token = try XCTUnwrap(bodyRow["query_token"] as? String)
        // An edge on the top face (y == thickness) that runs ALONG X: the
        // plate's top rim has two X-aligned edges whose midpoint x is the
        // plate's centre (50). The edge direction is then ±X, so an offset
        // perpendicular to it cannot move the midpoint in x.
        let match = try XCTUnwrap(edges.first {
            guard let midpoint = $0["midpoint"] as? [Double], midpoint.count == 3 else { return false }
            return abs(midpoint[1] - 10) < 1e-6 && abs(midpoint[0] - 50) < 1e-6
        })
        return ["index": try XCTUnwrap(match["index"]), "query_token": token,
                "midpoint": try XCTUnwrap(match["midpoint"])]
    }

    private func call(_ f: Fixture, _ action: String, _ args: [String: Any]) -> [String: Any] {
        CADParameterService(document: f.document).handle(action: action, args: args)
    }

    private func axisID(_ reply: [String: Any]) throws -> ConstructionAxisID {
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return ConstructionAxisID(raw: try XCTUnwrap(
            (reply["axis_id"] as? String).flatMap(UUID.init(uuidString:))))
    }

    private func pointID(_ reply: [String: Any]) throws -> DatumPointID {
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return DatumPointID(raw: try XCTUnwrap(
            (reply["point_id"] as? String).flatMap(UUID.init(uuidString:))))
    }

    private func axis(_ f: Fixture, _ id: ConstructionAxisID) throws -> ConstructionAxis {
        try XCTUnwrap(f.document.session.document.axes.first { $0.id == id })
    }

    private func point(_ f: Fixture, _ id: DatumPointID) throws -> DatumPoint {
        try XCTUnwrap(f.document.session.document.datumPoints.first { $0.id == id })
    }

    /// Per-component vector comparison: XCTest's accuracy overload only accepts
    /// scalar FloatingPoint values, never a SIMD vector.
    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              accuracy: Double = 1e-6, _ label: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(label) x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(label) y", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "\(label) z", file: file, line: line)
    }

    private func faceAxisArgs(_ f: Fixture, face: [String: Any], offset: String = "0") throws
        -> [String: Any] {
        XCTAssertEqual(face["datum_source_supported"] as? Bool, true, "\(face)")
        return ["kind": "face", "body_id": f.body.raw.uuidString,
                "face_index": try XCTUnwrap(face["index"]),
                "query_token": try XCTUnwrap(face["query_token"]),
                "offset": offset]
    }

    private func edgeAxisArgs(_ f: Fixture, offset: String = "0") throws -> [String: Any] {
        let edge = try topEdge(f)
        return ["kind": "edge", "body_id": f.body.raw.uuidString,
                "edge_index": try XCTUnwrap(edge["index"]),
                "query_token": try XCTUnwrap(edge["query_token"]),
                "offset": offset]
    }

    /// One REAL circular-pattern consumer of the axis: recorded exactly the way
    /// the editor records it (append a pattern node after the source node).
    @discardableResult
    private func addCircularPattern(_ f: Fixture, axisID: ConstructionAxisID,
                                    count: Int = 3) throws -> FeatureID {
        let node = FeatureNode(
            name: "Pattern",
            kind: .pattern(
                body: BodyRef(producer: f.source.id, bodyID: f.body),
                spec: PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                                  count: count, spacing: 0, totalAngle: 2 * .pi,
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

    // MARK: - Face axis + real pattern consumer

    func testFaceAxisCreateQueryOffsetAndPatternFollowsTheAxis() async throws {
        let f = try await fixture()
        let id = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: topFace(f))))
        let record = try axis(f, id)
        guard case let .face(definition)? = record.definition else {
            return XCTFail("a face axis must store a face definition")
        }
        XCTAssertEqual(definition.version, FaceAxisDefinition.supportedVersion)
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(definition.sourceVersion.bodyID, f.body)
        XCTAssertEqual(record.origin.y, 10, accuracy: 1e-6)
        XCTAssertEqual(abs(record.direction.y), 1, accuracy: 1e-9)

        let row = try XCTUnwrap(rows(f.document, "axes").first {
            ($0["axis_id"] as? String) == id.raw.uuidString
        })
        XCTAssertEqual(row["kind"] as? String, "face")
        XCTAssertEqual(row["definition_version"] as? Int, 1)
        XCTAssertEqual(row["source_body_id"] as? String, f.body.raw.uuidString)
        XCTAssertEqual(row["source_writer_id"] as? String, f.source.id.raw.uuidString)
        XCTAssertEqual(row["status"] as? String, "resolved")
        XCTAssertEqual(row["update_action"] as? String, "datum.axis.update")
        XCTAssertEqual(row["delete_action"] as? String, "datum.axis.delete")
        XCTAssertEqual(row["value"] as? Double, 0)
        // Creation stored the supplied offset as the exact formula "0"; the
        // sheet's expected_offset CAS fences that stored text, not "absent".
        let storedOffset = try XCTUnwrap(row["formula"] as? String)
        XCTAssertEqual(storedOffset, "0")

        let pattern = try addCircularPattern(f, axisID: id)
        f.document.session.rebuildFrom(f.source.id)
        let copies = patternCopies(f, try patternNode(f))
        XCTAssertEqual(copies.count, 2)

        // Offset the axis within the top face: the pattern copies must move
        // with it because they store the IDENTITY, not a baked line.
        // The resolved line starts at the CURRENT face centroid, so the
        // expectation is anchored on that origin (the ground plane maps the
        // sketch's v to -worldZ, so neither centroid coordinate is zero).
        let baseOrigin = record.origin
        XCTAssertGreaterThan(abs(baseOrigin.x), 1e-6)
        let before = copies.map(\.transform.translation)
        let otherFace = try bottomFace(f)
        let beforeRefusal = f.document.session.changeCount
        let mixed = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "offset": "20", "expected_offset": storedOffset,
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(otherFace["index"]),
            "query_token": try XCTUnwrap(otherFace["query_token"]),
        ])
        XCTAssertEqual(mixed["ok"] as? Bool, false, "\(mixed)")
        XCTAssertEqual(mixed["error"] as? String, "ambiguous_update", "\(mixed)")
        XCTAssertEqual(f.document.session.changeCount, beforeRefusal)
        XCTAssertEqual(try axis(f, id).definition, record.definition)
        XCTAssertEqual(patternCopies(f, try patternNode(f)).map(\.transform.translation), before)
        let edited = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "offset": "20", "expected_offset": storedOffset,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        XCTAssertEqual(try axis(f, id).origin.x, baseOrigin.x + 20, accuracy: 1e-6)
        let afterNode = try patternNode(f)
        XCTAssertEqual(afterNode.id, pattern)
        let after = patternCopies(f, afterNode).map(\.transform.translation)
        XCTAssertEqual(after.count, before.count)
        XCTAssertNotEqual(after, before, "the pattern must follow the edited axis")

        // Undo restores the axis AND every copy transform in one step.
        f.document.session.undo()
        XCTAssertEqual(try axis(f, id).origin.x, baseOrigin.x, accuracy: 1e-6)
        XCTAssertEqual(patternCopies(f, try patternNode(f)).map(\.transform.translation), before)
        f.document.session.redo()
        XCTAssertEqual(try axis(f, id).origin.x, baseOrigin.x + 20, accuracy: 1e-6)
    }

    func testVariableTransactionUpdatesAxisAndPointCachesTogetherThroughUndoAndReopen() async throws {
        let f = try await fixture()
        let variable = call(f, "variable.create", ["name": "datumGap", "expression": "2"])
        XCTAssertEqual(variable["ok"] as? Bool, true, "\(variable)")
        let variableRow = try XCTUnwrap(variable["variable"] as? [String: Any])
        let variableID = try XCTUnwrap(variableRow["id"] as? String)
        let axisID = try self.axisID(call(f, "datum.axis.create",
                                         try faceAxisArgs(f, face: topFace(f), offset: "datumGap * 2")))
        let pointID = try self.pointID(call(f, "datum.point.create", [
            "kind": "axisPoint", "axis_id": axisID.raw.uuidString, "offset": "datumGap",
        ]))
        let initialAxis = try axis(f, axisID)
        let initialPoint = try point(f, pointID)
        let changed = call(f, "variable.update", [
            "variable_id": variableID, "expression": "7", "expected_expression": "2",
        ])
        XCTAssertEqual(changed["ok"] as? Bool, true, "\(changed)")

        func assertValues(_ document: FloeCADDocument, gap: Double,
                          file: StaticString = #filePath, line: UInt = #line) throws {
            let axisRow = try XCTUnwrap(rows(document, "axes").first {
                ($0["axis_id"] as? String) == axisID.raw.uuidString
            }, file: file, line: line)
            let pointRow = try XCTUnwrap(rows(document, "datumPoints").first {
                ($0["point_id"] as? String) == pointID.raw.uuidString
            }, file: file, line: line)
            XCTAssertEqual(axisRow["value"] as? Double, gap * 2, file: file, line: line)
            XCTAssertEqual(pointRow["value"] as? Double, gap, file: file, line: line)
            XCTAssertEqual(axisRow["formula"] as? String, "datumGap * 2", file: file, line: line)
            XCTAssertEqual(pointRow["formula"] as? String, "datumGap", file: file, line: line)
            let currentAxis = try XCTUnwrap(document.session.document.axes.first { $0.id == axisID })
            let currentPoint = try XCTUnwrap(document.session.document.datumPoints.first { $0.id == pointID })
            XCTAssertEqual(currentAxis.origin.x - initialAxis.origin.x, (gap - 2) * 2,
                           accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(simd_distance(currentPoint.position, currentAxis.origin), gap,
                           accuracy: 1e-6, file: file, line: line)
        }
        try assertValues(f.document, gap: 7)
        f.document.session.undo()
        try assertValues(f.document, gap: 2)
        XCTAssertEqual(try axis(f, axisID), initialAxis)
        XCTAssertEqual(try point(f, pointID), initialPoint)
        f.document.session.redo()
        try assertValues(f.document, gap: 7)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save failed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        try assertValues(reopened, gap: 7)
    }

    func testFaceAxisFollowsParentThicknessAndReselectsTheOtherFace() async throws {
        let f = try await fixture()
        let top = try topFace(f)
        let id = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: top)))
        XCTAssertEqual(try axis(f, id).origin.y, 10, accuracy: 1e-6)
        // The drawn length defaults to the face's own size (sqrt area), the
        // display-only extent the service reports; it is not a fixed 100 mm.
        let expectedLength = (try XCTUnwrap(top["areaMM2"] as? Double)).squareRoot()
        XCTAssertEqual(try axis(f, id).length, expectedLength, accuracy: 1e-6)
        try addCircularPattern(f, axisID: id)
        f.document.session.rebuildFrom(f.source.id)
        let before = patternCopies(f, try patternNode(f)).map(\.transform.translation)

        // Parent edit (thickness 10 → 25): the axis follows its frozen writer
        // and the dependent pattern copies move with it in the same rebuild.
        let update = call(f, "update", ["feature_id": f.source.id.raw.uuidString,
                                        "changes": ["distance": 25]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try axis(f, id).origin.y, 25, accuracy: 1e-6)
        let after = patternCopies(f, try patternNode(f)).map(\.transform.translation)
        XCTAssertNotEqual(after, before)

        // Reselect the source face (bottom): same identity, new source.
        let reselect = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString,
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(bottomFace(f)["index"]),
            "query_token": try XCTUnwrap(bottomFace(f)["query_token"]),
        ])
        XCTAssertEqual(reselect["ok"] as? Bool, true, "\(reselect)")
        XCTAssertEqual(try axis(f, id).origin.y, 0, accuracy: 1e-6)
        guard case let .face(definition)? = try axis(f, id).definition else {
            return XCTFail("reselect must keep the face kind")
        }
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
    }

    // MARK: - Edge axis

    func testEdgeAxisCreateOffsetAndReselect() async throws {
        let f = try await fixture()
        let args = try edgeAxisArgs(f, offset: "0")
        let id = try axisID(call(f, "datum.axis.create", args))
        let record = try axis(f, id)
        guard case let .edge(definition)? = record.definition else {
            return XCTFail("an edge axis must store an edge definition")
        }
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(abs(record.direction.x), 1, accuracy: 1e-9, "\(record.direction)")
        let row = try XCTUnwrap(rows(f.document, "axes").first {
            ($0["axis_id"] as? String) == id.raw.uuidString
        })
        XCTAssertEqual(row["kind"] as? String, "edge")
        XCTAssertEqual(row["edge_length"] as? Double, 100)
        XCTAssertEqual(row["offset_supported"] as? Bool, true)

        // The perpendicular offset direction is the edge's own frozen
        // reference (a top rim edge is shared by the cap and a wall, so it may
        // be +Y or ±Z). Assert the exact perpendicular DISPLACEMENT rather
        // than guessing which world axis it is.
        let baseOrigin = record.origin
        let offset = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "offset": "5",
        ])
        XCTAssertEqual(offset["ok"] as? Bool, true, "\(offset)")
        let offsetOrigin = try axis(f, id).origin
        XCTAssertEqual(simd_distance(offsetOrigin, baseOrigin), 5, accuracy: 1e-6)
        XCTAssertEqual(abs(simd_dot(offsetOrigin - baseOrigin, record.direction)), 0,
                       accuracy: 1e-6, "an edge offset is perpendicular to the edge")

        // Offset edits are formula-capable through the shared variable path.
        let variable = call(f, "variable.create", ["name": "axisGap", "expression": "2"])
        XCTAssertEqual(variable["ok"] as? Bool, true, "\(variable)")
        let formula = call(f, "datum.axis.update", [
            "axis_id": id.raw.uuidString, "offset": "axisGap * 2", "expected_offset": "5",
        ])
        XCTAssertEqual(formula["ok"] as? Bool, true, "\(formula)")
        guard case let .edge(updated)? = try axis(f, id).definition else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(updated.offset.formula, "axisGap * 2")
        XCTAssertEqual(updated.offset.value, 4, accuracy: 1e-12)
        let formulaOrigin = try axis(f, id).origin
        XCTAssertEqual(simd_distance(formulaOrigin, baseOrigin), 4, accuracy: 1e-6)

        // Reselect the same edge kind with a fresh generation token (plus a
        // real display-length change so the update is not a no-op). The update
        // must name the edited axis; a source triple alone is a create. It also
        // omits the offset on purpose: a source reselect preserves the current
        // offset formula (the same rule M07 plane reselect already follows).
        var reselectArgs = try edgeAxisArgs(f, offset: "axisGap * 2")
        reselectArgs["axis_id"] = id.raw.uuidString
        reselectArgs["expected_offset"] = "axisGap * 2"
        reselectArgs["size"] = 55
        reselectArgs.removeValue(forKey: "offset")
        let reselect = call(f, "datum.axis.update", reselectArgs)
        XCTAssertEqual(reselect["ok"] as? Bool, true, "\(reselect)")
        XCTAssertEqual(try axis(f, id).length, 55, accuracy: 1e-9)
        guard case let .edge(afterReselect)? = try axis(f, id).definition else {
            return XCTFail("a reselect must keep the edge kind")
        }
        XCTAssertEqual(afterReselect.offset.formula, "axisGap * 2")
        XCTAssertEqual(afterReselect.offset.value, 4, accuracy: 1e-12)
    }

    // MARK: - Two-plane and two-point axes

    func testTwoPlaneAxisFromResolvedPlanesDrivesAPatternAndRefusesParallel() async throws {
        let f = try await fixture()
        let top = try topFace(f)
        let first = call(f, "datum.offsetPlane.create", [
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(top["index"]),
            "query_token": try XCTUnwrap(top["query_token"]),
            "expression": "0",
        ])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        let planeA = ConstructionPlaneID(raw: try XCTUnwrap(
            (first["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        // A VERTICAL side plane: its intersection with the top plane is a
        // real line (two parallel horizontal planes would rightly refuse).
        let side = try face(f, normalX: 1)
        let second = call(f, "datum.offsetPlane.create", [
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(side["index"]),
            "query_token": try XCTUnwrap(side["query_token"]),
            "expression": "0",
        ])
        XCTAssertEqual(second["ok"] as? Bool, true, "\(second)")
        let planeB = ConstructionPlaneID(raw: try XCTUnwrap(
            (second["plane_id"] as? String).flatMap(UUID.init(uuidString:))))

        let twoPlanes = call(f, "datum.axis.create", [
            "kind": "twoPlanes", "plane_ids": [planeA.raw.uuidString, planeB.raw.uuidString],
        ])
        let id = try axisID(twoPlanes)
        let record = try axis(f, id)
        guard case let .twoPlanes(definition)? = record.definition else {
            return XCTFail("a two-plane axis must store both plane ids")
        }
        XCTAssertEqual(definition.planes, [planeA, planeB])
        // The intersection of the top (y = 10) and +X side (x = 100) planes is
        // the line along Z through (100, 10, …).
        XCTAssertEqual(abs(record.direction.z), 1, accuracy: 1e-9, "\(record.direction)")
        XCTAssertEqual(record.origin.x, 100, accuracy: 1e-6)
        XCTAssertEqual(record.origin.y, 10, accuracy: 1e-6)

        // Duplicate/nonexistent plane lists refuse before any mutation.
        // Two references to the SAME plane cannot define a line; the typed
        // definition validation refuses it before anything is written.
        let duplicate = call(f, "datum.axis.create", [
            "kind": "twoPlanes", "plane_ids": [planeA.raw.uuidString, planeA.raw.uuidString],
        ])
        XCTAssertEqual(duplicate["ok"] as? Bool, false, "\(duplicate)")
        XCTAssertEqual(duplicate["error"] as? String, "invalid_definition")

        // Two PARALLEL planes (top y = 10 and y = 15) have no unique line and
        // must refuse instead of inventing one. The first two plane creates
        // advanced the generation, so the original `top` token is stale:
        // re-query the same face for this new named-source action.
        let parallelTop = try topFace(f)
        let parallelPlane = call(f, "datum.offsetPlane.create", [
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(parallelTop["index"]),
            "query_token": try XCTUnwrap(parallelTop["query_token"]),
            "expression": "5",
        ])
        XCTAssertEqual(parallelPlane["ok"] as? Bool, true, "\(parallelPlane)")
        let planeC = ConstructionPlaneID(raw: try XCTUnwrap(
            (parallelPlane["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        let parallel = call(f, "datum.axis.create", [
            "kind": "twoPlanes", "plane_ids": [planeA.raw.uuidString, planeC.raw.uuidString],
        ])
        XCTAssertEqual(parallel["ok"] as? Bool, false, "\(parallel)")
        XCTAssertEqual(parallel["error"] as? String, "parallel_sources")

        try addCircularPattern(f, axisID: id)
        f.document.session.rebuildFrom(f.source.id)
        XCTAssertEqual(patternCopies(f, try patternNode(f)).count, 2)
        XCTAssertNotNil(try axis(f, id))
    }

    func testTwoPointAxisUsesSketchAnchorsAndFollowsTheSketch() async throws {
        let f = try await fixture()
        let line = try XCTUnwrap(f.document.session.document.sketches
            .first { $0.id == f.sketch.id }?.entities.first {
                if case .line = $0 { return true }
                return false
            })
        let first = SketchAnchorRef(sketchID: f.sketch.id, entityID: line.id, role: .endpointA)
        let second = SketchAnchorRef(sketchID: f.sketch.id, entityID: line.id, role: .endpointB)
        let create = call(f, "datum.axis.create", [
            "kind": "twoPoints",
            "points": [["sketch_id": first.sketchID.raw.uuidString,
                        "entity_id": first.entityID.uuidString, "role": "endpointA"],
                       ["sketch_id": second.sketchID.raw.uuidString,
                        "entity_id": second.entityID.uuidString, "role": "endpointB"]],
        ])
        let id = try axisID(create)
        let record = try axis(f, id)
        guard case let .twoPoints(definition)? = record.definition else {
            return XCTFail("a two-point axis must store both anchor identities")
        }
        XCTAssertEqual(definition.points.count, 2)
        // The fixture's line is (10,30)-(90,30) in the GROUND sketch, whose
        // v axis maps to -worldZ: origin (10, 0, -30), direction +X.
        assertVector(record.origin, SIMD3(10, 0, -30), "two-point axis origin")
        XCTAssertEqual(abs(record.direction.x), 1, accuracy: 1e-9)

        // Parent sketch edit: move the line's endpoints; the axis follows.
        let moved = call(f, "updateSketchEntity", [
            "sketch_id": f.sketch.id.raw.uuidString,
            "entity_id": line.id.uuidString,
            "a": [20, 40], "b": [80, 40],
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        assertVector(try axis(f, id).origin, SIMD3(20, 0, -40),
                     "two-point axis origin follows the sketch")
    }

    // MARK: - Datum points

    func testDatumPointKindsResolveAndFollowTheirSources() async throws {
        let f = try await fixture()
        let top = try topFace(f)
        let center = try pointID(call(f, "datum.point.create", [
            "kind": "faceCenter", "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(top["index"]),
            "query_token": try XCTUnwrap(top["query_token"]),
        ]))
        // Top-face centroid: x 50, y 10, and z = -30 (the ground sketch's v
        // axis maps to -worldZ).
        assertVector(try point(f, center).position, SIMD3(50, 10, -30),
                     "top-face centroid")
        let centerRow = try XCTUnwrap(rows(f.document, "datumPoints").first {
            ($0["point_id"] as? String) == center.raw.uuidString
        })
        XCTAssertEqual(centerRow["kind"] as? String, "faceCenter")
        XCTAssertEqual(centerRow["status"] as? String, "resolved")

        // Edge point at +5 mm along the straight top edge.
        let edge = try topEdge(f)
        let onEdge = try pointID(call(f, "datum.point.create", [
            "kind": "edgePoint", "body_id": f.body.raw.uuidString,
            "edge_index": try XCTUnwrap(edge["index"]),
            "query_token": try XCTUnwrap(edge["query_token"]),
            "offset": "5",
        ]))
        let edgeMidpoint = try XCTUnwrap(edge["midpoint"] as? [Double])
        XCTAssertEqual(edgeMidpoint.count, 3)
        let edgeMidpointPosition = SIMD3(edgeMidpoint[0], edgeMidpoint[1], edgeMidpoint[2])
        XCTAssertEqual(try point(f, onEdge).position.y, 10, accuracy: 1e-6)
        // 5 mm ALONG the edge from its midpoint: the edge's own direction may
        // be +X or -X, so assert the distance, not a signed coordinate.
        XCTAssertEqual(simd_distance(try point(f, onEdge).position, edgeMidpointPosition), 5,
                       accuracy: 1e-6)

        // Axis point: 7 mm along the face axis. Each earlier point CREATE
        // advanced the document generation, so ask for a NEW face row (and its
        // current query_token) immediately before this named-source action.
        let axisFace = try topFace(f)
        let faceAxis = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: axisFace)))
        let onAxis = try pointID(call(f, "datum.point.create", [
            "kind": "axisPoint", "axis_id": faceAxis.raw.uuidString, "offset": "7",
        ]))
        XCTAssertEqual(try point(f, onAxis).position.y, 17, accuracy: 1e-6)

        // Axis × plane: the same axis crossing the bottom datum plane. The
        // axis create above advanced the generation again; re-query the face
        // for this second independent named-source action.
        let planeFace = try topFace(f)
        let plane = call(f, "datum.offsetPlane.create", [
            "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(planeFace["index"]),
            "query_token": try XCTUnwrap(planeFace["query_token"]),
            "expression": "-10",
        ])
        XCTAssertEqual(plane["ok"] as? Bool, true, "\(plane)")
        let planeID = ConstructionPlaneID(raw: try XCTUnwrap(
            (plane["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        let crossing = try pointID(call(f, "datum.point.create", [
            "kind": "axisPlane", "axis_id": faceAxis.raw.uuidString,
            "plane_id": planeID.raw.uuidString,
        ]))
        XCTAssertEqual(try point(f, crossing).position.y, 0, accuracy: 1e-6)

        // Midpoint of two datum points.
        let midpoint = try pointID(call(f, "datum.point.create", [
            "kind": "twoPointMidpoint",
            "points": [["point_id": center.raw.uuidString],
                       ["point_id": crossing.raw.uuidString]],
        ]))
        assertVector(try point(f, midpoint).position,
                     (try point(f, center).position + point(f, crossing).position) / 2,
                     "two-point midpoint")

        // Parent edit: thickness 10 → 25 moves every face/axis-derived point in
        // the same rebuild; the two-point midpoint follows both.
        let update = call(f, "update", ["feature_id": f.source.id.raw.uuidString,
                                        "changes": ["distance": 25]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try point(f, center).position.y, 25, accuracy: 1e-6)
        XCTAssertEqual(try point(f, onEdge).position.y, 25, accuracy: 1e-6)
        XCTAssertEqual(try point(f, onAxis).position.y, 32, accuracy: 1e-6)
        XCTAssertEqual(try point(f, midpoint).position.y,
                       (try point(f, center).position.y + point(f, crossing).position.y) / 2,
                       accuracy: 1e-6)
    }

    // MARK: - Refusals

    func testBrokenSourcesRefuseAtomicallyAndPreserveThePreviousDocument() async throws {
        let f = try await fixture()
        let faceAxis = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: topFace(f))))
        XCTAssertEqual(try axis(f, faceAxis).origin.y, 10, accuracy: 1e-6)
        let revision = f.document.revision
        let count = f.document.session.document.axes.count

        // Deleting the source feature while its datum is alive must be refused
        // with the dependency reported and nothing changed.
        let delete = call(f, "feature.delete", ["feature_id": f.source.id.raw.uuidString])
        XCTAssertEqual(delete["ok"] as? Bool, false, "\(delete)")
        XCTAssertEqual(f.document.revision, revision)
        XCTAssertEqual(f.document.session.document.axes.count, count)
        XCTAssertEqual(try axis(f, faceAxis).origin.y, 10, accuracy: 1e-6)

        // Suppressing it is also refused while the definition needs the writer.
        let suppress = call(f, "feature.suppress",
                            ["feature_id": f.source.id.raw.uuidString, "suppressed": true])
        XCTAssertEqual(suppress["ok"] as? Bool, false, "\(suppress)")
        XCTAssertFalse(f.document.session.document.features.nodes[0].suppressed)

        // A stale generation token must refuse before any mutation.
        let stale = call(f, "datum.axis.create", [
            "kind": "face", "body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(topFace(f)["index"]),
            "query_token": "cadq1:faces:\(f.body.raw.uuidString):0:0:0",
        ])
        XCTAssertEqual(stale["error"] as? String, "stale_query")
        XCTAssertEqual(f.document.session.document.axes.count, count)
    }

    func testDeleteRefusesWhileConsumedAndPatternAxisIDCanBeReplaced() async throws {
        let f = try await fixture()
        let firstAxis = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: topFace(f))))
        let pattern = try addCircularPattern(f, axisID: firstAxis)
        f.document.session.rebuildFrom(f.source.id)

        let refused = call(f, "datum.axis.delete", ["axis_id": firstAxis.raw.uuidString])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "axis_in_use")
        XCTAssertEqual(refused["dependent_feature_ids"] as? [String], [pattern.raw.uuidString])

        // The pattern follows a DIFFERENT axis after feature.update axis_id.
        let second = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: topFace(f))))
        let reassign = call(f, "update", [
            "feature_id": pattern.raw.uuidString, "changes": ["axis_id": second.raw.uuidString],
        ])
        XCTAssertEqual(reassign["ok"] as? Bool, true, "\(reassign)")
        guard case let .pattern(_, spec) = try patternNode(f).kind else {
            return XCTFail("pattern node disappeared")
        }
        XCTAssertEqual(spec.axisRef?.axisID, second)
        let removed = call(f, "datum.axis.delete", ["axis_id": firstAxis.raw.uuidString])
        XCTAssertEqual(removed["ok"] as? Bool, true, "\(removed)")

        // Clearing the reference FREEZES the axis's current resolved line (M08
        // R2), so the pattern keeps the geometry it had at this moment instead
        // of jumping back to the creation-time cache.
        let currentLine = try axis(f, second).resolvedLine
        let clear = call(f, "update", [
            "feature_id": pattern.raw.uuidString, "changes": ["axis_id": NSNull()],
        ])
        XCTAssertEqual(clear["ok"] as? Bool, true, "\(clear)")
        guard case let .pattern(_, cleared) = try patternNode(f).kind else {
            return XCTFail("pattern node disappeared")
        }
        XCTAssertNil(cleared.axisRef)
        XCTAssertEqual(cleared.center.x, currentLine.origin.x, accuracy: 1e-9)
        XCTAssertEqual(cleared.center.y, currentLine.origin.y, accuracy: 1e-9)
        XCTAssertEqual(cleared.center.z, currentLine.origin.z, accuracy: 1e-9)
        XCTAssertEqual(cleared.axis, currentLine.direction)
    }

    // MARK: - Save / reopen

    func testSaveReopenKeepsAxisAndPointRelationshipsAndConsumers() async throws {
        let f = try await fixture()
        let subjectAxis = try axisID(call(f, "datum.axis.create", try faceAxisArgs(f, face: topFace(f))))
        let offset = call(f, "datum.axis.update", [
            "axis_id": subjectAxis.raw.uuidString, "offset": "12",
        ])
        XCTAssertEqual(offset["ok"] as? Bool, true, "\(offset)")
        let subjectPoint = try pointID(call(f, "datum.point.create", [
            "kind": "axisPoint", "axis_id": subjectAxis.raw.uuidString, "offset": "3",
        ]))
        let pattern = try addCircularPattern(f, axisID: subjectAxis)
        f.document.session.rebuildFrom(f.source.id)
        let copiesBefore = patternCopies(f, try patternNode(f)).map(\.transform.translation)
        // The resolved offset line (display origin = face centroid + 12 mm), so
        // the reopen comparison is anchored on the actual frame.
        let originBefore = try axis(f, subjectAxis).origin
        let directionBefore = try axis(f, subjectAxis).direction

        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "save must succeed")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let reopenedAxis = try XCTUnwrap(reopened.session.document.axes.first { $0.id == subjectAxis })
        guard case let .face(definition)? = reopenedAxis.definition else {
            return XCTFail("the face definition must survive reopen")
        }
        XCTAssertEqual(definition.offset.value, 12, accuracy: 1e-12)
        XCTAssertEqual(reopenedAxis.origin.x, originBefore.x, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.origin.y, originBefore.y, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.origin.z, originBefore.z, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.x, directionBefore.x, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.y, directionBefore.y, accuracy: 1e-9)
        XCTAssertEqual(reopenedAxis.direction.z, directionBefore.z, accuracy: 1e-9)
        let reopenedPoint = try XCTUnwrap(reopened.session.document.datumPoints.first { $0.id == subjectPoint })
        guard case let .axisPoint(pointDefinition)? = reopenedPoint.definition else {
            return XCTFail("the axis point must survive reopen")
        }
        XCTAssertEqual(pointDefinition.axis, subjectAxis)
        XCTAssertEqual(pointDefinition.offset.value, 3, accuracy: 1e-12)
        XCTAssertEqual(reopenedPoint.position.y, 13, accuracy: 1e-6)

        let reopenedPattern = try XCTUnwrap(reopened.session.document.features.nodes.first {
            $0.id == pattern
        })
        guard case let .pattern(_, spec) = reopenedPattern.kind else {
            return XCTFail("the pattern node must survive reopen")
        }
        XCTAssertEqual(spec.axisRef?.axisID, subjectAxis,
                       "the pattern must still store the axis identity, not a baked line")
        let copiesAfter = patternCopies(
            Fixture(document: reopened, source: f.source, body: f.body, sketch: f.sketch),
            reopenedPattern).map(\.transform.translation)
        XCTAssertEqual(copiesAfter.count, copiesBefore.count)
        for (actual, expected) in zip(copiesAfter, copiesBefore) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(actual.z, expected.z, accuracy: 1e-9)
        }
    }
}
