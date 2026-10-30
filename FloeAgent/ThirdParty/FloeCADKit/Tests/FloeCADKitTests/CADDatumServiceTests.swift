import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADDatumServiceTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeDatumService-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }
    override func tearDown() async throws {
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private struct Fixture { var document: FloeCADDocument; var source: FeatureNode; var body: BodyID }
    private func fixture(box: Bool = false) async throws -> Fixture {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Datum service")
        documents.append(document)
        let body = BodyID()
        let node: FeatureNode
        if box {
            node = FeatureNode(name: "Box", kind: .primitive(spec: .box(width: 100, depth: 60, height: 10),
                placement: .identity), outputBodyIDs: [body])
            document.session.recordAndRebuild([node], title: "Box")
        } else {
            let sketch = Sketch(name: "Plate", plane: .ground, entities: [
                .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60))])
            node = extrude(sketch, distance: 10, body: body)
            document.session.recordAndRebuild([node], extra: [AddSketchCommand(sketch: sketch)], title: "Plate")
        }
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return Fixture(document: document, source: node, body: body)
    }
    private func extrude(_ sketch: Sketch, distance: Double, body: BodyID = BodyID()) -> FeatureNode {
        FeatureNode(name: "Extrusion", kind: .extrude(profile: ProfileRef(sketchID: sketch.id,
            entityIDs: sketch.entities.map(\.id), holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance), symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [body])
    }
    private func rows(_ document: FloeCADDocument, scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope, "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }
    private func top(_ f: Fixture) throws -> [String: Any] {
        try XCTUnwrap(rows(f.document, scope: "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        })
    }
    private func sourceArgs(_ f: Fixture, face: [String: Any]? = nil, expression: String = "5") throws -> [String: Any] {
        let selectedFace = try face ?? top(f)
        XCTAssertEqual(selectedFace["datum_source_supported"] as? Bool, true, "\(selectedFace)")
        return ["body_id": f.body.raw.uuidString, "face_index": try XCTUnwrap(selectedFace["index"]),
                "query_token": try XCTUnwrap(selectedFace["query_token"]), "expression": expression]
    }
    private func call(_ document: FloeCADDocument, _ action: String, _ args: [String: Any]) -> [String: Any] {
        CADParameterService(document: document).handle(action: action, args: args)
    }
    private func create(_ f: Fixture, expression: String = "5") throws -> ConstructionPlaneID {
        let result = call(f.document, "datum.offsetPlane.create", try sourceArgs(f, expression: expression))
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertNotNil(result["plane"])
        return ConstructionPlaneID(raw: try XCTUnwrap((result["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
    }
    private func plane(_ f: Fixture, _ id: ConstructionPlaneID) throws -> ConstructionPlane {
        try XCTUnwrap(f.document.session.document.planes.first { $0.id == id })
    }
    private func definition(_ plane: ConstructionPlane) throws -> OffsetPlaneDefinition {
        let value: OffsetPlaneDefinition?
        if case let .offset(definition)? = plane.definition { value = definition } else { value = nil }
        return try XCTUnwrap(value)
    }
    private func addSketch(_ f: Fixture) -> Sketch {
        let sketch = Sketch(name: "Child profile", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))])
        f.document.session.perform(AddSketchCommand(sketch: sketch))
        return sketch
    }

    func testCreateDiscoveryAndSingleUndoFromNamedExtrude() async throws {
        let f = try await fixture()
        let count = f.document.session.changeCount
        let face = try top(f)
        XCTAssertNotNil(face["kernel_element_name"])
        XCTAssertEqual(face["face_index_space"] as? String, "occt_kernel_1_based")
        XCTAssertEqual(face["source_writer_id"] as? String, f.source.id.raw.uuidString)
        XCTAssertEqual(f.document.session.changeCount, count, "discovery is read-only")
        let id = try create(f, expression: " 0 ")
        let datum = try plane(f, id)
        XCTAssertEqual(try definition(datum).distance, Expr(value: 0, formula: " 0 "))
        XCTAssertEqual(datum.plane.origin.y, 10, accuracy: 1e-6)
        let row = try XCTUnwrap(rows(f.document, scope: "planes").first)
        XCTAssertEqual(row["plane_id"] as? String, id.raw.uuidString)
        XCTAssertEqual(row["source_writer_id"] as? String, f.source.id.raw.uuidString)
        XCTAssertEqual(row["definition_version"] as? Int, 1)
        XCTAssertEqual(row["status"] as? String, "resolved")
        f.document.session.undo()
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == id })
        f.document.session.redo()
        XCTAssertEqual(try plane(f, id).plane.origin.y, 10, accuracy: 1e-6)
    }

    func testSupportedBoxPrimitiveSourceUsesExactKernelName() async throws {
        let f = try await fixture(box: true)
        let id = try create(f)
        let definition = try definition(plane(f, id))
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(definition.source.elementName?.source, .primitiveFace(.boxFace(.py)))
        XCTAssertEqual(try plane(f, id).plane.origin.y, 15, accuracy: 1e-6)
        let update = call(f.document, "update", ["feature_id": f.source.id.raw.uuidString, "changes": ["height": 20]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try plane(f, id).plane.origin.y, 25, accuracy: 1e-6)
    }

    func testUpdateRetainsIdentitySourceAndAttachmentAndOneUndo() async throws {
        let f = try await fixture()
        let id = try create(f)
        let before = try plane(f, id)
        let result = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString, "expression": "-2", "size": 44])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        let after = try plane(f, id)
        XCTAssertEqual(after.id, id)
        XCTAssertEqual(after.size, 44)
        XCTAssertEqual(after.plane.origin.y, 8, accuracy: 1e-6)
        XCTAssertEqual(try definition(after).sourceVersion, try definition(before).sourceVersion)
        XCTAssertEqual(try definition(after).attachment, try definition(before).attachment)
        f.document.session.undo()
        XCTAssertEqual(try plane(f, id), before)
        f.document.session.redo()
        XCTAssertEqual(try plane(f, id).size, 44)
    }

    func testSourceReselectRetainsIDAndRejectsPartialSource() async throws {
        let f = try await fixture()
        let id = try create(f)
        let before = try definition(plane(f, id))
        let side = try XCTUnwrap(rows(f.document, scope: "faces").first {
            ($0["bodyID"] as? String) == f.body.raw.uuidString && (($0["normal"] as? [Double])?[0] ?? 0) > 0.99
        })
        var args = try sourceArgs(f, face: side, expression: "3")
        args["plane_id"] = id.raw.uuidString
        let result = call(f.document, "datum.offsetPlane.update", args)
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        let changed = try definition(plane(f, id))
        XCTAssertNotEqual(changed.source.elementName, before.source.elementName)
        XCTAssertEqual(try plane(f, id).id, id)
        f.document.session.undo()
        XCTAssertEqual(try definition(plane(f, id)), before)
        let partial = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString, "body_id": f.body.raw.uuidString])
        XCTAssertEqual(partial["error"] as? String, "incomplete_source")
        XCTAssertTrue(f.document.session.undoStack.canRedo)
    }

    func testSourceThicknessAndVariableOffsetDriveSupportedExactBody() async throws {
        let f = try await fixture()
        let createdVariable = call(f.document, "variable.create", ["name": "gap", "expression": "5"])
        XCTAssertEqual(createdVariable["ok"] as? Bool, true)
        let variable = try XCTUnwrap(f.document.session.document.variables.first)
        let id = try create(f, expression: "gap")
        let sketch = addSketch(f)
        let support = call(f.document, "sketch.setSupport", ["sketch_id": sketch.id.raw.uuidString, "plane_id": id.raw.uuidString])
        XCTAssertEqual(support["ok"] as? Bool, true, "\(support)")
        let child = extrude(sketch, distance: 3)
        f.document.session.recordAndRebuild([child], title: "Child")
        let update = call(f.document, "update", ["feature_id": f.source.id.raw.uuidString, "changes": ["distance": 20]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try plane(f, id).plane.origin.y, 25, accuracy: 1e-6)
        XCTAssertEqual(f.document.session.document.sketches.first { $0.id == sketch.id }?.plane.origin.y, 25)
        let variableUpdate = call(f.document, "variable.update", ["variable_id": variable.id.raw.uuidString, "expression": "8"])
        XCTAssertEqual(variableUpdate["ok"] as? Bool, true, "\(variableUpdate)")
        let body = try XCTUnwrap(f.document.session.document.body(with: child.outputBodyIDs[0]))
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep)), 24, accuracy: 1e-5)
        let minY = try XCTUnwrap(body.render.positions.map { body.transform.applying(to: SIMD3<Double>($0)).y }.min())
        XCTAssertEqual(minY, 28, accuracy: 1e-4)
        f.document.session.undo()
        XCTAssertEqual(try plane(f, id).plane.origin.y, 25, accuracy: 1e-6)
    }

    func testSetClearSupportRetainsLocalGeometryAndOneUndoRedo() async throws {
        let f = try await fixture()
        let id = try create(f)
        let sketch = addSketch(f)
        XCTAssertEqual(call(f.document, "sketch.setSupport", ["sketch_id": sketch.id.raw.uuidString, "plane_id": id.raw.uuidString])["ok"] as? Bool, true)
        let supported = try XCTUnwrap(f.document.session.document.sketches.first { $0.id == sketch.id })
        XCTAssertEqual(supported.support, PlaneRef(source: .construction(id)))
        XCTAssertEqual(supported.entities, sketch.entities)
        XCTAssertEqual(supported.plane.origin.y, 15, accuracy: 1e-6)
        let row = try XCTUnwrap(rows(f.document, scope: "sketches").first { ($0["id"] as? String) == sketch.id.raw.uuidString })
        XCTAssertEqual((row["support"] as? [String: Any])?["plane_id"] as? String, id.raw.uuidString)
        XCTAssertEqual(call(f.document, "sketch.clearSupport", ["sketch_id": sketch.id.raw.uuidString])["ok"] as? Bool, true)
        let detached = try XCTUnwrap(f.document.session.document.sketches.first { $0.id == sketch.id })
        XCTAssertNil(detached.support)
        XCTAssertEqual(detached.plane, supported.plane)
        XCTAssertEqual(detached.entities, sketch.entities)
        XCTAssertEqual(detached.constraints, sketch.constraints)
        f.document.session.undo()
        XCTAssertEqual(f.document.session.document.sketches.first { $0.id == sketch.id }?.support, supported.support)
        f.document.session.redo()
        XCTAssertNil(f.document.session.document.sketches.first { $0.id == sketch.id }?.support)
    }

    func testDeletionRefusesExactDependenciesThenSucceedsAfterDetach() async throws {
        let f = try await fixture()
        let id = try create(f)
        let sketch = addSketch(f)
        XCTAssertEqual(call(f.document, "sketch.setSupport", ["sketch_id": sketch.id.raw.uuidString, "plane_id": id.raw.uuidString])["ok"] as? Bool, true)
        let child = extrude(sketch, distance: 3)
        f.document.session.recordAndRebuild([child], title: "Child")
        let refusal = call(f.document, "datum.offsetPlane.delete", ["plane_id": id.raw.uuidString])
        XCTAssertEqual(refusal["error"] as? String, "plane_in_use")
        XCTAssertEqual(refusal["dependent_sketch_ids"] as? [String], [sketch.id.raw.uuidString])
        XCTAssertEqual(refusal["dependent_feature_ids"] as? [String], [child.id.raw.uuidString])
        XCTAssertEqual(call(f.document, "sketch.clearSupport", ["sketch_id": sketch.id.raw.uuidString])["ok"] as? Bool, true)
        let deleted = call(f.document, "datum.offsetPlane.delete", ["plane_id": id.raw.uuidString])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == id })
        XCTAssertNotNil(f.document.session.document.body(with: child.outputBodyIDs[0]))
        f.document.session.undo()
        XCTAssertTrue(f.document.session.document.planes.contains { $0.id == id })
    }

    func testStaleTokenWrongScopeAndRenderOrdinalDoNotCreateOrDestroyRedo() async throws {
        let f = try await fixture()
        var args = try sourceArgs(f)
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        let stale = call(f.document, "datum.offsetPlane.create", args)
        XCTAssertEqual(stale["error"] as? String, "stale_query")
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        args = try sourceArgs(f)
        let token = try XCTUnwrap(args["query_token"] as? String)
        args["query_token"] = token.replacingOccurrences(of: ":faces:", with: ":edges:")
        XCTAssertEqual(call(f.document, "datum.offsetPlane.create", args)["error"] as? String, "stale_query")
        args = try sourceArgs(f)
        args["face_index"] = 0 // first render triangle is not a 1-based OCCT face
        XCTAssertEqual(call(f.document, "datum.offsetPlane.create", args)["error"] as? String, "invalid_source")
        args["face_index"] = 9999 // never reinterpret an out-of-range render ordinal
        XCTAssertEqual(call(f.document, "datum.offsetPlane.create", args)["error"] as? String, "named_planar_source_required")
        XCTAssertTrue(f.document.session.document.planes.isEmpty)
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        XCTAssertEqual(f.document.project.formatVersion, 1)
    }

    func testInvalidExpressionSizeUnknownAndContradictoryArgsLeavePlainFormatAndBytes() async throws {
        let f = try await fixture()
        XCTAssertEqual(call(f.document, "variable.create", ["name": "width", "expression": "3"])["ok"] as? Bool, true)
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let generation = f.document.session.changeCount
        let base = try sourceArgs(f)
        for expression in ["1 / 0", "missing + 1", "sqrt(-1)", "", "2 * (3 +",
                           "2 cm", "2 m", "2 in", "2 ft", "2 deg", "2 garbage", "sqrt(9) garbage", "sqrt9garbage", "2 width"] {
            var args = base; args["expression"] = expression
            XCTAssertEqual(call(f.document, "datum.offsetPlane.create", args)["error"] as? String, "invalid_expression")
        }
        for size in [0.0, -1.0, Double.infinity] {
            var args = base; args["size"] = size
            XCTAssertEqual(call(f.document, "datum.offsetPlane.create", args)["error"] as? String, "invalid_size")
        }
        var unknown = base; unknown["faceIndex"] = 1
        XCTAssertEqual(call(f.document, "datum.offsetPlane.create", unknown)["error"] as? String, "unknown_argument")
        var contradictory = base; contradictory["action"] = "datum.offsetPlane.delete"
        XCTAssertEqual(call(f.document, "datum.offsetPlane.create", contradictory)["error"] as? String, "contradictory_action")
        XCTAssertEqual(f.document.session.changeCount, generation)
        XCTAssertTrue(f.document.session.document.planes.isEmpty)
        XCTAssertEqual(f.document.project.formatVersion, 1)
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
    }

    func testSaveReopenRetainsDefinitionSupportAndContinuedExpressionEdit() async throws {
        var f = try await fixture()
        let id = try create(f, expression: "2 + 3")
        let sketch = addSketch(f)
        XCTAssertEqual(call(f.document, "sketch.setSupport", ["sketch_id": sketch.id.raw.uuidString, "plane_id": id.raw.uuidString])["ok"] as? Bool, true)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(f.document.url).schemaVersion, 2)
        let url = f.document.url
        let before = try definition(plane(f, id))
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened); f.document = reopened
        XCTAssertEqual(try definition(plane(f, id)), before)
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == sketch.id }?.support, PlaneRef(source: .construction(id)))
        let result = call(reopened, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString, "expression": "9"])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(try plane(f, id).plane.origin.y, 19, accuracy: 1e-6)
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == sketch.id }?.plane.origin.y, 19)
    }

    func testReadOnlyRefusesAllFiveActionsBeforeParsingAndDiscoveryStaysReadOnly() async throws {
        let f = try await fixture()
        let id = try create(f)
        let count = f.document.session.changeCount
        f.document.project.formatVersion = Project.currentFormatVersion + 1
        for action in CADDatumService.actions {
            let result = CADDatumService(document: f.document).handle(action: action, args: [:])
            XCTAssertEqual(result["error"] as? String, "read_only", "\(action): \(result)")
        }
        XCTAssertEqual(f.document.session.changeCount, count)
        let planeRow = try XCTUnwrap(rows(f.document, scope: "planes").first { ($0["plane_id"] as? String) == id.raw.uuidString })
        XCTAssertEqual(planeRow["kind"] as? String, "offset")
        XCTAssertEqual(planeRow["status"] as? String, "read_only")
        XCTAssertEqual(planeRow["frame_status"] as? String, "cached")
        XCTAssertEqual(planeRow["editable"] as? Bool, false)
        XCTAssertNil(planeRow["support_action"])
        XCTAssertNil(planeRow["update_action"])
        XCTAssertNil(planeRow["delete_action"])
        XCTAssertTrue(try rows(f.document, scope: "faces").allSatisfy { ($0["datum_source_supported"] as? Bool) != true })
    }

    func testUnprovenBakedRotationDoesNotAdvertiseOrCreateSource() async throws {
        let f = try await fixture(box: true)
        let after = FeatureKind.primitive(spec: .box(width: 100, depth: 60, height: 10),
            placement: Transform3D(translation: .zero, rotation: simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0)), scale: 1))
        f.document.session.editFeature(f.source.id, to: after)
        let face = try top(f)
        XCTAssertEqual(face["datum_source_supported"] as? Bool, false)
        XCTAssertNil(face["kernel_element_name"])
        let result = call(f.document, "datum.offsetPlane.create", ["body_id": f.body.raw.uuidString,
            "face_index": try XCTUnwrap(face["index"]), "query_token": try XCTUnwrap(face["query_token"]), "expression": "1"])
        XCTAssertEqual(result["error"] as? String, "named_planar_source_required")
        XCTAssertTrue(f.document.session.document.planes.isEmpty)
    }
    func testExpectedExpressionMismatchPreservesRedoAndRejectsWrongType() async throws {
        let f = try await fixture()
        let id = try create(f, expression: " 2 + 3 ")
        let before = try plane(f, id)
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        let count = f.document.session.changeCount
        let mismatch = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString,
            "expression": "9", "expected_expression": "2 + 3"])
        XCTAssertEqual(mismatch["error"] as? String, "expression_mismatch")
        XCTAssertEqual(f.document.session.changeCount, count)
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        XCTAssertEqual(try plane(f, id), before)
        let wrongType = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString,
            "expression": "9", "expected_expression": 5])
        XCTAssertEqual(wrongType["error"] as? String, "bad_expected_expression")
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        let accepted = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString,
            "expression": "9", "expected_expression": " 2 + 3 "])
        XCTAssertEqual(accepted["ok"] as? Bool, true, "\(accepted)")
        XCTAssertEqual(try plane(f, id).plane.origin.y, 19, accuracy: 1e-6)
    }

    func testSourceAcquisitionKeepsProvenanceAndUsesActualTransformWriter() async throws {
        let f = try await fixture()
        let transformed = FeatureNode(name: "Actual writer", kind: .transform(
            body: BodyRef(producer: f.source.id, bodyID: f.body),
            delta: Transform3D(translation: SIMD3(4, 7, -2), scale: 2)), outputBodyIDs: [BodyID()])
        f.document.session.recordAndRebuild([transformed], title: "Transform")
        let id = try create(f)
        let definition = try definition(plane(f, id))
        XCTAssertEqual(definition.source.body.producer, f.source.id)
        XCTAssertEqual(definition.source.creator, f.source.id)
        XCTAssertEqual(definition.source.elementName?.creator, f.source.id)
        XCTAssertEqual(definition.sourceVersion.writer, transformed.id)
        XCTAssertEqual(definition.sourceVersion.bodyID, f.body)
        XCTAssertEqual(try plane(f, id).plane.origin.y, 32, accuracy: 1e-6,
            "transformed top is 10*2+7; offset remains 5 world mm")
    }

    func testBatchedMultiBodySourceDiscoveryDoesNotMutateOrLoseRedo() async throws {
        let f = try await fixture()
        let other = BodyID()
        let box = FeatureNode(name: "Second body", kind: .primitive(spec: .box(width: 8, depth: 9, height: 10),
            placement: .identity), outputBodyIDs: [other])
        f.document.session.recordAndRebuild([box], title: "Second body")
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        let count = f.document.session.changeCount
        let revisions = Dictionary(uniqueKeysWithValues: f.document.session.document.bodies.map { ($0.id, $0.meshRevision) })
        let missing = BodyID()
        let sources = f.document.session.associativeSources(for: [f.body, other, missing])
        XCTAssertEqual(Set(sources.keys), [f.body, other])
        XCTAssertEqual(sources[f.body]?.version.writer, f.source.id)
        XCTAssertEqual(sources[other]?.version.writer, box.id)
        XCTAssertNil(sources[missing])
        let faces = try rows(f.document, scope: "faces")
        for (body, writer) in [(f.body, f.source.id), (other, box.id)] {
            let bodyRows = faces.filter { ($0["bodyID"] as? String) == body.raw.uuidString }
            XCTAssertFalse(bodyRows.isEmpty)
            XCTAssertTrue(bodyRows.allSatisfy { ($0["datum_source_supported"] as? Bool) == true })
            XCTAssertTrue(bodyRows.allSatisfy { ($0["source_writer_id"] as? String) == writer.raw.uuidString })
        }
        XCTAssertEqual(f.document.session.changeCount, count)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: f.document.session.document.bodies.map { ($0.id, $0.meshRevision) }), revisions)
        XCTAssertTrue(f.document.session.undoStack.canRedo)
    }

    func testOpaqueAssociationDiscoveryLabelsCachedUnsupportedSemantics() async throws {
        let url = directory.appendingPathComponent("opaque.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .definitionKind)
        let bytes = try CADAssociativeFormatFixture.bytes(url)
        let opened = try await FloeCADDocument.open(at: url)
        documents.append(opened)
        XCTAssertTrue(opened.project.hasOpaqueAssociations)
        XCTAssertTrue(opened.isReadOnly)
        let count = opened.session.changeCount
        let opaqueRows = try rows(opened, scope: "planes")
        XCTAssertFalse(opaqueRows.isEmpty)
        for row in opaqueRows {
            XCTAssertEqual(row["kind"] as? String, "unsupported")
            XCTAssertEqual(row["semantics"] as? String, "opaque")
            XCTAssertEqual(row["status"] as? String, "read_only")
            XCTAssertEqual(row["frame_status"] as? String, "cached")
            XCTAssertEqual(row["editable"] as? Bool, false)
            XCTAssertNil(row["support_action"])
            XCTAssertNil(row["update_action"])
            XCTAssertNil(row["delete_action"])
        }
        XCTAssertEqual(opened.session.changeCount, count)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
    }

    func testExistingMillimetreSuffixResolvesAndPreservesExactSourceAndUndo() async throws {
        let f = try await fixture()
        let id = try create(f, expression: "2 mm")
        let created = try plane(f, id)
        XCTAssertEqual(try definition(created).distance, Expr(value: 2, formula: "2 mm"))
        XCTAssertEqual(created.plane.origin.y, 12, accuracy: 1e-6)
        let descriptor = try XCTUnwrap(rows(f.document, scope: "planes").first {
            ($0["plane_id"] as? String) == id.raw.uuidString
        })
        XCTAssertEqual(descriptor["expression"] as? String, "2 mm")
        XCTAssertEqual(descriptor["expression_unit"] as? String, "mm")
        XCTAssertEqual(descriptor["value"] as? Double, 2)
        f.document.session.undo()
        XCTAssertFalse(f.document.session.document.planes.contains { $0.id == id })
        f.document.session.redo()
        XCTAssertEqual(try plane(f, id), created)
        XCTAssertEqual(try definition(plane(f, id)).distance.formula, "2 mm")
        // Existing evaluate retains its legacy suffix contract; only the new
        // service entry applies the stricter declared-millimetre policy.
        XCTAssertEqual(ExpressionEvaluator.evaluate("2 cm", variables: [:]), 2)
        XCTAssertNil(ExpressionEvaluator.evaluateStrict("2 cm", variables: [:]))
        XCTAssertEqual(ExpressionEvaluator.evaluateStrict(" = sqrt(9) + 1 ", variables: [:]), 4)
        XCTAssertEqual(call(f.document, "variable.create", ["name": "width", "expression": "4"])["ok"] as? Bool, true)
        let variableEnd = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString,
            "expression": "width", "expected_expression": "2 mm"])
        XCTAssertEqual(variableEnd["ok"] as? Bool, true, "\(variableEnd)")
        XCTAssertEqual(try definition(plane(f, id)).distance, Expr(value: 4, formula: "width"))
        let explicitMM = call(f.document, "datum.offsetPlane.update", ["plane_id": id.raw.uuidString,
            "expression": " = width + 1 mm ", "expected_expression": "width"])
        XCTAssertEqual(explicitMM["ok"] as? Bool, true, "\(explicitMM)")
        XCTAssertEqual(try definition(plane(f, id)).distance, Expr(value: 5, formula: " = width + 1 mm "))
        XCTAssertEqual(try plane(f, id).plane.origin.y, 15, accuracy: 1e-6)
        f.document.session.undo()
        XCTAssertEqual(try definition(plane(f, id)).distance, Expr(value: 4, formula: "width"))
    }

}
