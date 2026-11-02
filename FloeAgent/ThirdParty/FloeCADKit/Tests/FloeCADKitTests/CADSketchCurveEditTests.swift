// SPDX-License-Identifier: MPL-2.0
// M03/M04 exact native curves + production service/session/store.
// General intervals and normal offsets remain exact definitions, never fits.
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADSketchCurveEditTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeCurveEdit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { if let directory { try? FileManager.default.removeItem(at: directory) } }

    private func near(_ p: SIMD2<Double>, _ q: SIMD2<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, q.x, accuracy: 1e-7, file: file, line: line)
        XCTAssertEqual(p.y, q.y, accuracy: 1e-7, file: file, line: line)
    }
    private func make(_ entities: [SketchEntity], constraints: [SketchConstraint] = []) async throws -> (FloeCADDocument, Sketch) {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Curve edits")
        let sketch = Sketch(plane: .ground, entities: entities, constraints: constraints)
        document.session.perform(AddSketchCommand(sketch: sketch))
        return (document, sketch)
    }
    private func entity(_ id: UUID, in document: FloeCADDocument, sketch: Sketch) throws -> SketchEntity {
        try XCTUnwrap(document.session.document.sketches.first(where: { $0.id == sketch.id })?.entities.first(where: { $0.id == id }))
    }
    private func current(_ document: FloeCADDocument, _ sketch: Sketch) throws -> Sketch {
        try XCTUnwrap(document.session.document.sketches.first(where: { $0.id == sketch.id }))
    }
    private func curve(_ action: String, document: FloeCADDocument, sketch: Sketch, id: UUID,
                       boundary: UUID? = nil, pick: [Double]? = nil, distance: Double? = nil) -> [String: Any] {
        var args: [String: Any] = ["sketch_id": sketch.id.raw.uuidString, "entity_id": id.uuidString]
        if let boundary { args["boundary_id"] = boundary.uuidString }
        if let pick { args["pick"] = pick }
        if let distance { args["distance"] = distance }
        return CADParameterService(document: document).handle(action: action, args: args)
    }
    private func circleRadius(_ entity: SketchEntity) throws -> Double {
        switch entity {
        case let .circle(_, _, radius), let .arc(_, _, radius, _, _): return radius
        default: XCTFail("expected a circular curve"); throw NSError(domain: "CurveTest", code: 1)
        }
    }

    func testVersionedDefinitionMaterializesGeneralBasesExactly() throws {
        for entity in [
            SketchEntity.ellipse(id: UUID(), center: SIMD2(2,3), radiusX: 7, radiusY: 3, rotation: 0.37),
            .spline(id: UUID(), points: [SIMD2(-10,-10),SIMD2(-5,0),SIMD2(5,0),SIMD2(10,10)], closed: false),
        ] {
            let definition = try SketchCurveDefinition(entity)
            let bytes = try JSONEncoder().encode(definition)
            XCTAssertEqual(try JSONDecoder().decode(SketchCurveDefinition.self, from: bytes), definition)
            XCTAssertTrue(definition.canMaterializeInterval)
            XCTAssertEqual(try definition.materialized(id: entity.id), entity)
            let offset = try definition.normalOffset(by: 0.25)
            XCTAssertTrue(offset.isDerivedNormalOffset)
            guard case let .exactCurve(_, persisted) = try offset.materialized(id: UUID()) else {
                return XCTFail("general offset was flattened")
            }
            XCTAssertEqual(persisted, offset)
            XCTAssertEqual(try JSONDecoder().decode(SketchCurveDefinition.self,
                from: JSONEncoder().encode(offset)), offset)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["version"] = 99
            XCTAssertThrowsError(try JSONDecoder().decode(SketchCurveDefinition.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertThrowsError(try SketchCurveParameterInterval(lower: 1, upper: 1))
    }

    func testNativeArcTrimUsesSelectedBoundaryAndKeepsItsIdentity() throws {
        let id = UUID(); let boundaryID = UUID()
        let arc = SketchEntity.arc(id: id, center: .zero, radius: 10, startAngle: 0, endAngle: .pi)
        let boundary = SketchEntity.line(id: boundaryID, a: SIMD2(0,-20), b: SIMD2(0,20))
        let result = try SketchCurveEditKernel.edit(arc, boundary: boundary, pick: SIMD2(-8,5), kind: .trim)
        XCTAssertEqual(result.entities.count, 1); XCTAssertEqual(result.entities[0].id, id)
        guard case let .arc(_, center, radius, start, end) = result.entities[0] else { return XCTFail("arc was flattened") }
        near(center, .zero); XCTAssertEqual(radius, 10); XCTAssertEqual(start, 0); XCTAssertEqual(end, .pi/2, accuracy: 1e-8)
        XCTAssertEqual(result.boundaryID, boundaryID)
    }

    func testNativeArcExtensionStopsAtSelectedBoundary() throws {
        let id = UUID()
        let arc = SketchEntity.arc(id: id, center: .zero, radius: 10, startAngle: 0, endAngle: .pi/4)
        let boundary = SketchEntity.line(id: UUID(), a: SIMD2(0,-20), b: SIMD2(0,20))
        let result = try SketchCurveEditKernel.edit(arc, boundary: boundary,
            pick: SIMD2(10*cos(.pi/4),10*sin(.pi/4)), kind: .extend)
        guard case let .arc(newID, _, radius, start, end) = result.entities[0] else { return XCTFail() }
        XCTAssertEqual(newID, id); XCTAssertEqual(radius, 10); XCTAssertEqual(start, 0)
        XCTAssertEqual(end, .pi/2, accuracy: 1e-8)
    }

    func testNativeEllipseBoundaryIsExactAndSplitsMapIDsExplicitly() throws {
        let id = UUID(); let boundaryID = UUID()
        let source = SketchEntity.arc(id: id, center: .zero, radius: 5, startAngle: 0, endAngle: .pi)
        let ellipse = SketchEntity.ellipse(id: boundaryID, center: .zero, radiusX: 7, radiusY: 3, rotation: 0)
        let result = try SketchCurveEditKernel.edit(source, boundary: ellipse, pick: SIMD2(0,5), kind: .trim)
        XCTAssertEqual(result.entities.count, 2); XCTAssertEqual(result.entities[0].id, id)
        XCTAssertNotEqual(result.entities[1].id, id)
        let angle = asin(sqrt(5.4)/5)
        XCTAssertEqual(result.definitions[0].interval.upper, angle, accuracy: 1e-7)
        XCTAssertEqual(result.definitions[1].interval.lower, .pi-angle, accuracy: 1e-7)
        for definition in result.definitions {
            for parameter in [definition.interval.lower, definition.interval.upper] {
                let p = try definition.point(at: parameter)
                XCTAssertEqual(simd_length(p), 5, accuracy: 1e-7)
            }
        }
        // This residual would expose a tessellated ellipse boundary.
        let cut = try result.definitions[0].point(at: result.definitions[0].interval.upper)
        XCTAssertEqual(cut.x*cut.x/49 + cut.y*cut.y/9, 1, accuracy: 1e-8)
    }

    func testNativeFitSplineBoundaryUsesOriginalCurveNotItsPolyline() throws {
        let source = SketchEntity.line(id: UUID(), a: SIMD2(0,-20), b: SIMD2(0,20))
        let boundary = SketchEntity.spline(id: UUID(), points: [SIMD2(-10,-10),SIMD2(-5,0),SIMD2(5,0),SIMD2(10,10)], closed: false)
        let result = try SketchCurveEditKernel.edit(source, boundary: boundary, pick: SIMD2(0,10), kind: .trim)
        guard case let .line(id, a, b) = result.entities[0] else { return XCTFail() }
        XCTAssertEqual(id, source.id); near(a, SIMD2(0,-20)); near(b, .zero)
    }

    func testConstraintRefusalPreservesConstraintGeometryUndoAndRedo() async throws {
        let arcID = UUID(), boundaryID = UUID()
        let arc = SketchEntity.arc(id: arcID, center: .zero, radius: 10, startAngle: 0, endAngle: .pi)
        let line = SketchEntity.line(id: boundaryID, a: SIMD2(0,-20), b: SIMD2(0,20))
        let constraint = SketchConstraint(kind: .fixed, refs: [.init(entityID: arcID, role: .whole)])
        let (document, sketch) = try await make([arc,line], constraints: [constraint]); defer { document.close() }
        document.session.perform(UpdateSketchEntityCommand(sketchID: sketch.id, before: line,
            after: .line(id: boundaryID, a: SIMD2(1,-20), b: SIMD2(1,20))))
        document.session.undo()
        let before = try current(document, sketch), undo = document.session.undoStack.undoCommands.count, redo = document.session.undoStack.redoCommands.count
        let reply = curve("trimSketchCurve", document: document, sketch: sketch, id: arcID, boundary: boundaryID, pick: [-8,5])
        XCTAssertEqual(reply["ok"] as? Bool, false); XCTAssertEqual(reply["error"] as? String, "curve_edit_references")
        XCTAssertEqual(reply["affected_constraint_ids"] as? [String], [constraint.id.uuidString])
        XCTAssertEqual(try current(document, sketch), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redo)
    }

    func testLinkedOffsetFollowsSourceKeepsIDsAndUndoIsOneStep() async throws {
        let sourceID = UUID(); let source = SketchEntity.circle(id: sourceID, center: .zero, radius: 5)
        let (document, sketch) = try await make([source]); defer { document.close() }
        let reply = curve("offsetSketchCurve", document: document, sketch: sketch, id: sourceID, distance: 2)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let id = try XCTUnwrap((reply["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        let linkID = try XCTUnwrap((reply["link_id"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 7)
        let service = CADParameterService(document: document)
        let update = service.handle(action: "updateSketchEntity", args: ["sketch_id": sketch.id.raw.uuidString, "entity_id": sourceID.uuidString, "radius": 8.0])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 10)
        XCTAssertEqual(try current(document, sketch).curveOffsetLinks.first?.id, linkID)
        document.session.undo()
        XCTAssertEqual(try circleRadius(entity(sourceID, in: document, sketch: sketch)), 5)
        XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 7)
        document.session.redo()
        XCTAssertEqual(try circleRadius(entity(sourceID, in: document, sketch: sketch)), 8)
        XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 10)
        let direct = service.handle(action: "updateSketchEntity", args: ["sketch_id": sketch.id.raw.uuidString, "entity_id": id.uuidString, "radius": 20.0])
        XCTAssertEqual(direct["error"] as? String, "linked_curve_target")
        let unlink = service.handle(action: "unlinkSketchOffset", args: ["sketch_id": sketch.id.raw.uuidString, "link_id": linkID.uuidString])
        XCTAssertEqual(unlink["ok"] as? Bool, true); XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 10)
        XCTAssertTrue(try current(document, sketch).curveOffsetLinks.isEmpty)
    }

    func testCollapseFromSourceEditIsAtomicAndReturnsExactRelationIDs() async throws {
        let sourceID = UUID(); let (document, sketch) = try await make([.circle(id: sourceID, center: .zero, radius: 5)])
        defer { document.close() }
        let created = curve("offsetSketchCurve", document: document, sketch: sketch, id: sourceID, distance: -2)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let before = try current(document, sketch), undo = document.session.undoStack.undoCommands.count, redo = document.session.undoStack.redoCommands.count
        let reply = CADParameterService(document: document).handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.id.raw.uuidString, "entity_id": sourceID.uuidString, "radius": 1.0])
        XCTAssertEqual(reply["ok"] as? Bool, false); XCTAssertEqual(reply["error"] as? String, "curve_offset_collapse")
        XCTAssertEqual(Set(reply["affected_entity_ids"] as? [String] ?? []), Set([sourceID.uuidString] + (created["created_entity_ids"] as? [String] ?? [])))
        XCTAssertEqual(try current(document, sketch), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo); XCTAssertEqual(document.session.undoStack.redoCommands.count, redo)
    }

    func testOffsetRebuildUsesExactOCCTProfileAndSaveReopenPreservesLink() async throws {
        let sourceID = UUID(); let (document, sketch) = try await make([.circle(id: sourceID, center: .zero, radius: 5)])
        let url = document.url
        let created = curve("offsetSketchCurve", document: document, sketch: sketch, id: sourceID, distance: 2)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let id = try XCTUnwrap((created["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        let command = #"{"op":"feature.extrude","args":{"sketchID":"\#(sketch.id.raw.uuidString)","seedPoint":[6,0],"distance":3}}"#
        let extrude = document.executeJSON(Data(command.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNotNil(body.brep)
        let update = CADParameterService(document: document).handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.id.raw.uuidString, "entity_id": sourceID.uuidString, "radius": 5.25])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try circleRadius(entity(id, in: document, sketch: sketch)), 7.25)
        let measure = document.measureJSON(["kind": "body", "bodyID": body.id.raw.uuidString])
        XCTAssertTrue(measure.isOK, measure.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: measure.payload) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(object["volumeMM3"] as? Double), 25 * .pi * 3, accuracy: 1e-5)
        let expected = try current(document, sketch)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThanOrEqual(document.project.formatVersion, 7)
        document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try current(reopened, sketch), expected)
        XCTAssertEqual(try circleRadius(entity(id, in: reopened, sketch: sketch)), 7.25)
    }

    func testNormalDistanceForStraightSplineSubtypeAndCircularEllipse() throws {
        let line = SketchEntity.spline(id: UUID(), points: [SIMD2(0,0),SIMD2(3,4)], closed: false)
        let definition = try SketchCurveDefinition(line), shifted = try definition.normalOffset(by: 2)
        for parameter in [0.0,0.25,0.5,1.0] {
            let delta = try shifted.point(at: parameter) - definition.point(at: parameter)
            XCTAssertEqual(simd_length(delta), 2, accuracy: 1e-10)
            XCTAssertEqual(simd_dot(delta, SIMD2(3.0,4.0)), 0, accuracy: 1e-10)
        }
        let circular = SketchEntity.ellipse(id: UUID(), center: SIMD2(2,3), radiusX: 5, radiusY: 5, rotation: 0.7)
        let basis = try SketchCurveDefinition(circular), offset = try basis.normalOffset(by: 2)
        for parameter in [0.0,0.4,1.3,2.8,5.2] {
            let delta = try offset.point(at: parameter) - basis.point(at: parameter)
            XCTAssertEqual(simd_length(delta), 2, accuracy: 1e-9)
        }
        let nearCircle = SketchEntity.ellipse(id: UUID(), center: .zero, radiusX: 5, radiusY: 5.000000000001, rotation: 0)
        let exact = try SketchCurveDefinition(nearCircle).normalOffset(by: 1)
        XCTAssertTrue(exact.isDerivedNormalOffset) // near-circle is NOT collapsed to a circle
        XCTAssertTrue(SketchOffset.offset(entities: [nearCircle], by: 1).isEmpty)
    }

    func testFutureLinkIsOpaqueAndStaleKnownCacheCannotBeSaved() throws {
        let source = SketchEntity.circle(id: UUID(), center: .zero, radius: 5)
        let definition = try SketchCurveDefinition(source); let id = UUID()
        let target = try definition.normalOffset(by: 2).materialized(id: id)
        let link = try SketchCurveOffsetLink(sourceID: source.id, targetID: id, distance: 2, definition: definition)
        var sketch = Sketch(plane: .ground, entities: [source,target], curveOffsetLinks: [link])
        var document = DesignDocument(); document.sketches = [sketch]
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: DesignDocument()), 1)
        XCTAssertGreaterThanOrEqual(CADDocumentFormat.requiredFormat(document: document), 7)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sketch)) as? [String: Any])
        var links = try XCTUnwrap(object["curveOffsetLinks"] as? [[String: Any]]); links[0]["version"] = 99; object["curveOffsetLinks"] = links
        let data = try JSONSerialization.data(withJSONObject: object)
        let row = CADBlobRecord(blobID: sketch.id.raw, data: data, sha256: "")
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [row])
        XCTAssertTrue(assessment.isOpaqueReadOnly); XCTAssertTrue(assessment.opaqueSketches.contains(sketch.id.raw))
        XCTAssertGreaterThanOrEqual(assessment.requiredVersion, 7)
        let cached = try CADDocumentFormat.cachedSketch(from: data)
        XCTAssertEqual(cached.entities, sketch.entities); XCTAssertTrue(cached.curveOffsetLinks.isEmpty)
        sketch.entities[1] = .circle(id: id, center: .zero, radius: 99)
        XCTAssertThrowsError(try SketchCurveOffsetKit.validateStored(sketch))
        let stale = CADBlobRecord(blobID: sketch.id.raw, data: try JSONEncoder().encode(sketch), sha256: "")
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [stale]))
    }

    func testMalformedCyclicAndManualTargetTransitionsAreRejected() throws {
        let a = SketchEntity.circle(id: UUID(), center: .zero, radius: 5)
        let b = SketchEntity.circle(id: UUID(), center: .zero, radius: 6)
        let da = try SketchCurveDefinition(a), db = try SketchCurveDefinition(b)
        let ab = try SketchCurveOffsetLink(sourceID: a.id, targetID: b.id, distance: 1, definition: da)
        let ba = try SketchCurveOffsetLink(sourceID: b.id, targetID: a.id, distance: -1, definition: db)
        let cycle = Sketch(plane: .ground, entities: [a,b], curveOffsetLinks: [ab,ba])
        XCTAssertThrowsError(try SketchCurveOffsetKit.resolve(cycle))
        let valid = Sketch(plane: .ground, entities: [a,b], curveOffsetLinks: [ab])
        var changed = valid; changed.entities[1] = .circle(id: b.id, center: .zero, radius: 8)
        XCTAssertThrowsError(try SketchCurveOffsetKit.validateTransition(before: valid, after: changed))
        var missing = valid; missing.entities.remove(at: 0)
        XCTAssertThrowsError(try SketchCurveOffsetKit.resolve(missing))
        let remapped = SketchCurveOffsetLink.remappingValidated(ab, sourceID: UUID(), targetID: UUID())
        XCTAssertNotEqual(remapped.sourceID, ab.sourceID); XCTAssertNotEqual(remapped.targetID, ab.targetID)
        XCTAssertEqual(remapped.distance, ab.distance); XCTAssertEqual(remapped.intervalPolicy, "followSource")
    }
    func testNormalDistanceIsPhysicalOnAnObliqueUnitPlaneAndScaledPlaneIsRefused() throws {
        let plane = SketchPlane(origin: SIMD3(3,4,5), xAxis: SIMD3(1,0,0), yAxis: SIMD3(0,0.6,0.8))
        try SketchCurveOffsetKit.validatePlane(plane)
        let basis = try SketchCurveDefinition(.line(id: UUID(), a: .zero, b: SIMD2(3,4)))
        let offset = try basis.normalOffset(by: 2)
        let a = try basis.point(at: 0.4), b = try offset.point(at: 0.4)
        let delta = plane.toWorld(b) - plane.toWorld(a)
        XCTAssertEqual(simd_length(delta), 2, accuracy: 1e-10)
        XCTAssertEqual(simd_dot(delta, plane.toWorld(SIMD2(3,4)) - plane.toWorld(.zero)), 0, accuracy: 1e-10)
        var scaled = plane; scaled.xAxis *= 2
        XCTAssertThrowsError(try SketchCurveOffsetKit.validatePlane(scaled))
    }

}
