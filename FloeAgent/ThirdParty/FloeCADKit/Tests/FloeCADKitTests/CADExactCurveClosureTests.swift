// SPDX-License-Identifier: MPL-2.0
// Full M03/M04 general-curve source acceptance. These are production/native
// tests; the packet's source-only checks never claim that they have executed.
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADExactCurveClosureTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeExactCurveClosure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func near(_ p: SIMD2<Double>, _ q: SIMD2<Double>, accuracy: Double = 1e-7,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, q.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(p.y, q.y, accuracy: accuracy, file: file, line: line)
    }
    private func make(_ entities: [SketchEntity], constraints: [SketchConstraint] = []) async throws
        -> (FloeCADDocument, Sketch) {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Exact curves")
        let sketch = Sketch(plane: .ground, entities: entities, constraints: constraints)
        document.session.perform(AddSketchCommand(sketch: sketch))
        return (document, sketch)
    }
    private func current(_ document: FloeCADDocument, _ sketch: Sketch) throws -> Sketch {
        try XCTUnwrap(document.session.document.sketches.first(where: { $0.id == sketch.id }))
    }
    private func entity(_ id: UUID, in document: FloeCADDocument, sketch: Sketch) throws -> SketchEntity {
        try XCTUnwrap(try current(document, sketch).entities.first(where: { $0.id == id }))
    }
    private func definition(_ id: UUID, in document: FloeCADDocument, sketch: Sketch) throws
        -> SketchCurveDefinition {
        try SketchCurveDefinition(entity(id, in: document, sketch: sketch))
    }
    private func curve(_ action: String, document: FloeCADDocument, sketch: Sketch, id: UUID,
                       boundary: UUID? = nil, pick: [Double]? = nil, distance: Double? = nil,
                       associative: Bool? = nil) -> [String: Any] {
        var args: [String: Any] = ["sketch_id": sketch.id.raw.uuidString, "entity_id": id.uuidString]
        if let boundary { args["boundary_id"] = boundary.uuidString }
        if let pick { args["pick"] = pick }
        if let distance { args["distance"] = distance }
        if let associative { args["associative"] = associative }
        return CADParameterService(document: document).handle(action: action, args: args)
    }
    private func exact(_ entity: SketchEntity, file: StaticString = #filePath,
                       line: UInt = #line) throws -> SketchCurveDefinition {
        guard case let .exactCurve(_, definition) = entity else {
            XCTFail("expected exactCurve, got \(entity)", file: file, line: line)
            throw NSError(domain: "ExactCurveTest", code: 1)
        }
        return definition
    }
    private func volume(_ document: FloeCADDocument, bodyID: BodyID) throws -> Double {
        let reply = document.measureJSON(["kind": "body", "bodyID": bodyID.raw.uuidString])
        XCTAssertTrue(reply.isOK, reply.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.payload) as? [String: Any])
        return try XCTUnwrap(object["volumeMM3"] as? Double)
    }

    func testGeneralEllipseTrimKeepsExactSupportIDMappingAndSaveReopen() async throws {
        let id = UUID(), boundaryID = UUID(), rotation = 0.37
        let ellipse = SketchEntity.ellipse(id: id, center: SIMD2(2,3), radiusX: 7, radiusY: 3, rotation: rotation)
        let direction = SIMD2(-sin(rotation), cos(rotation))
        let boundary = SketchEntity.line(id: boundaryID,
            a: SIMD2(2,3) - direction * 20, b: SIMD2(2,3) + direction * 20)
        let (document, sketch) = try await make([ellipse, boundary])
        let url = document.url
        let pick = try SketchCurveDefinition(ellipse).point(at: 0)
        let reply = curve("trimSketchCurve", document: document, sketch: sketch, id: id,
                          boundary: boundaryID, pick: [pick.x, pick.y])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let mapping = try XCTUnwrap(reply["id_mapping"] as? [String: [String]])
        XCTAssertEqual(mapping[id.uuidString], [id.uuidString])
        XCTAssertEqual(reply["removed_constraint_ids"] as? [String], [])
        let trimmed = try definition(id, in: document, sketch: sketch)
        guard case let .conic(center, rx, ry, supportRotation) = trimmed.support else {
            return XCTFail("ellipse support was replaced")
        }
        near(center, SIMD2(2,3)); XCTAssertEqual(rx, 7); XCTAssertEqual(ry, 3)
        XCTAssertEqual(supportRotation, rotation)
        XCTAssertEqual(trimmed.interval.lower, .pi / 2, accuracy: 1e-8)
        XCTAssertEqual(trimmed.interval.upper, 3 * .pi / 2, accuracy: 1e-8)
        XCTAssertFalse(trimmed.interval.periodic)
        _ = try exact(try entity(id, in: document, sketch: sketch))
        XCTAssertGreaterThanOrEqual(CADDocumentFormat.requiredFormat(document: document.session.document), 7)
        let expected = try current(document, sketch)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThanOrEqual(document.project.formatVersion, 7)
        document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try current(reopened, sketch), expected)
        near(try definition(id, in: reopened, sketch: sketch).point(at: .pi / 2),
             SIMD2(2,3) + direction * 3)
    }

    func testMultiPointSplineTrimRetainsOriginalFitPointsWithoutRefitting() throws {
        let points = [SIMD2(-10.0,-10), SIMD2(-5.0,0), SIMD2(5.0,0), SIMD2(10.0,10)]
        let id = UUID(), boundaryID = UUID()
        let spline = SketchEntity.spline(id: id, points: points, closed: false)
        let boundary = SketchEntity.line(id: boundaryID, a: SIMD2(0,-20), b: SIMD2(0,20))
        let result = try SketchCurveEditKernel.edit(spline, boundary: boundary, pick: SIMD2(5,0), kind: .trim)
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.entities[0].id, id)
        let trimmed = try exact(result.entities[0])
        guard case let .fitSpline(original, closed) = trimmed.support else {
            return XCTFail("spline was refit")
        }
        XCTAssertEqual(original, points); XCTAssertFalse(closed)
        XCTAssertEqual(trimmed.interval.lower, 0)
        XCTAssertGreaterThan(trimmed.interval.upper, 0)
        XCTAssertLessThan(trimmed.interval.upper, 1)
        near(try trimmed.point(at: trimmed.interval.upper), .zero)
        let nativeParameter = try trimmed.parameter(of: .zero)
        XCTAssertEqual(nativeParameter, trimmed.interval.upper, accuracy: 1e-7)
    }

    func testClosedSplineTrimUsesUnitPeriodAndOriginalBasis() throws {
        let id = UUID(), boundaryID = UUID()
        let points = [SIMD2(-5.0,-2), SIMD2(0.0,4), SIMD2(5.0,2), SIMD2(0.0,-4)]
        let spline = SketchEntity.spline(id: id, points: points, closed: true)
        let boundary = SketchEntity.line(id: boundaryID, a: SIMD2(0,-10), b: SIMD2(0,10))
        let result = try SketchCurveEditKernel.edit(spline, boundary: boundary,
            pick: SIMD2(5,2), kind: .trim)
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.entities[0].id, id)
        let trimmed = try exact(result.entities[0])
        guard case let .fitSpline(original, closed) = trimmed.support else { return XCTFail() }
        XCTAssertEqual(original, points); XCTAssertTrue(closed)
        XCTAssertFalse(trimmed.interval.periodic)
        XCTAssertEqual(trimmed.parameterPeriod, 1)
        XCTAssertGreaterThan(trimmed.interval.upper - trimmed.interval.lower, 0)
        XCTAssertLessThan(trimmed.interval.upper - trimmed.interval.lower, 1)
        let first = try trimmed.point(at: trimmed.interval.lower)
        let last = try trimmed.point(at: trimmed.interval.upper)
        for hit in [first, last] { XCTAssertEqual(hit.x, 0, accuracy: 1e-7) }
    }

    func testGeneralEllipseExtendsOnItsOriginalConicToSelectedBoundary() throws {
        let id = UUID(), rotation = 0.2
        let original = try SketchCurveDefinition(.ellipse(id: id, center: SIMD2(1,2),
            radiusX: 7, radiusY: 3, rotation: rotation))
        let partial = try original.replacingInterval(.init(lower: 0, upper: .pi / 4))
        let partialEntity = try partial.materialized(id: id)
        let direction = SIMD2(-sin(rotation), cos(rotation))
        let center = SIMD2(1.0,2.0)
        let boundary = SketchEntity.line(id: UUID(), a: center, b: center + direction * 20)
        let result = try SketchCurveEditKernel.edit(partialEntity, boundary: boundary,
            pick: original.point(at: .pi / 4), kind: .extend)
        let extended = try exact(result.entities[0])
        XCTAssertEqual(extended.support, original.support)
        XCTAssertEqual(extended.interval.lower, 0)
        XCTAssertEqual(extended.interval.upper, .pi / 2, accuracy: 1e-8)
        near(try extended.point(at: extended.interval.upper), center + direction * 3)
    }

    func testMultiPointSplineExtendsBothEndsByExactNativeExtrapolation() throws {
        let id = UUID()
        let points = [SIMD2(0.0,0), SIMD2(2.0,1), SIMD2(4.0,0), SIMD2(6.0,1)]
        let spline = SketchEntity.spline(id: id, points: points, closed: false)
        let original = try SketchCurveDefinition(spline)
        for extendStart in [true, false] {
            let x = extendStart ? -2.0 : 8.0
            let boundary = SketchEntity.line(id: UUID(), a: SIMD2(x,-20), b: SIMD2(x,20))
            let result = try SketchCurveEditKernel.edit(spline, boundary: boundary,
                pick: extendStart ? points[0] : points[points.count - 1],
                kind: .extend)
            let extended = try exact(result.entities[0])
            guard case let .fitSpline(originalPoints, _) = extended.support else {
                return XCTFail("extension changed the spline basis")
            }
            XCTAssertEqual(originalPoints, points)
            if extendStart { XCTAssertLessThan(extended.interval.lower, 0) }
            else { XCTAssertGreaterThan(extended.interval.upper, 1) }
            let endpoint = try extended.point(at: extendStart ? extended.interval.lower : extended.interval.upper)
            XCTAssertEqual(endpoint.x, x, accuracy: 1e-7)
            // The original fit points and their native parameters remain anchored.
            near(try extended.point(at: 0), points[0])
            near(try extended.point(at: 1), points[points.count - 1])
            for u in [0.12, 0.29, 0.51, 0.78, 0.93] {
                near(try extended.point(at: u), try original.point(at: u), accuracy: 1e-7)
            }
        }
    }

    func testEllipseNormalOffsetMatchesIndependentAnalyticNormals() throws {
        let rotation = 0.37, rx = 7.0, ry = 3.0, distance = 2.0
        let source = try SketchCurveDefinition(.ellipse(id: UUID(), center: SIMD2(2,3),
            radiusX: rx, radiusY: ry, rotation: rotation))
        let offset = try source.normalOffset(by: distance)
        XCTAssertTrue(offset.isDerivedNormalOffset)
        let diagnostics = try OCCTKernel.validateSketchNormalOffset(offset)
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertGreaterThan(diagnostics[0], 0)
        XCTAssertLessThanOrEqual(diagnostics[1], 1e-6)
        XCTAssertLessThanOrEqual(diagnostics[2], 1e-6)
        for t in [0.0, 0.31, 1.2, 2.7, 4.1, 5.8] {
            let base = try source.point(at: t)
            let localDerivative = SIMD2(-rx * sin(t), ry * cos(t))
            let derivative = SIMD2(localDerivative.x * cos(rotation) - localDerivative.y * sin(rotation),
                                   localDerivative.x * sin(rotation) + localDerivative.y * cos(rotation))
            let right = SIMD2(derivative.y, -derivative.x) / simd_length(derivative)
            near(try offset.point(at: t), base + right * distance, accuracy: 1e-7)
            let delta = try offset.point(at: t) - base
            XCTAssertEqual(simd_length(delta), distance, accuracy: 1e-8)
            XCTAssertEqual(simd_dot(delta, derivative), 0, accuracy: 1e-7)
        }
    }

    func testSplineNormalDistanceUsesIndependentNativeProjectionReference() throws {
        let source = try SketchCurveDefinition(.spline(id: UUID(), points: [
            SIMD2(-12.0,0), SIMD2(-8.0,0), SIMD2(-4.0,0), SIMD2(0.0,2),
            SIMD2(4.0,4), SIMD2(8.0,4), SIMD2(12.0,4)], closed: false))
        let distance = 0.5
        let offset = try source.normalOffset(by: distance)
        let diagnostics = try OCCTKernel.validateSketchNormalOffset(offset)
        XCTAssertLessThanOrEqual(diagnostics[1], 1e-6)
        XCTAssertLessThanOrEqual(diagnostics[2], 1e-6)
        for t in [0.0, 0.17, 0.39, 0.63, 0.82, 1.0] {
            let base = try source.point(at: t), shifted = try offset.point(at: t)
            XCTAssertEqual(simd_length(shifted - base), distance, accuracy: 1e-7)
            // Independent exact-kernel projection, not the packet's analytic helper.
            let projected = try source.parameter(of: shifted)
            XCTAssertEqual(projected, t, accuracy: 2e-5)
            let lower = max(0, t - 1e-5), upper = min(1, t + 1e-5)
            let tangent = try source.point(at: upper) - source.point(at: lower)
            XCTAssertEqual(simd_dot(shifted - base, tangent), 0, accuracy: 2e-5)
        }
    }

    func testOffCurveCursorPickProjectsOntoExactSpline() throws {
        let id = UUID()
        let spline = SketchEntity.spline(id: id, points: [
            SIMD2(-6.0,0), SIMD2(-2.0,2), SIMD2(2.0,2), SIMD2(6.0,0)], closed: false)
        let source = try SketchCurveDefinition(spline)
        let point = try source.point(at: 0.7)
        let picked = point + SIMD2(0.03, 0.08)
        let parameter = try source.parameter(of: picked)
        XCTAssertGreaterThan(parameter, 0.6)
        XCTAssertLessThan(parameter, 0.8)
        let boundary = SketchEntity.line(id: UUID(), a: SIMD2(0,-20), b: SIMD2(0,20))
        let result = try SketchCurveEditKernel.edit(spline, boundary: boundary,
            pick: picked, kind: .trim)
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.entities.first?.id, id)
        let kept = try exact(XCTUnwrap(result.entities.first))
        XCTAssertEqual(kept.support, source.support)
        XCTAssertLessThan(kept.interval.upper, 0.7)
    }

    func testLinkedEllipseAndSplineFollowSourceWithStableIDsAndOneStepUndo() async throws {
        let ellipseID = UUID()
        let (ellipseDocument, ellipseSketch) = try await make([.ellipse(id: ellipseID,
            center: .zero, radiusX: 7, radiusY: 3, rotation: 0.2)])
        defer { ellipseDocument.close() }
        let ellipseReply = curve("offsetSketchCurve", document: ellipseDocument,
            sketch: ellipseSketch, id: ellipseID, distance: 1)
        XCTAssertEqual(ellipseReply["ok"] as? Bool, true, "\(ellipseReply)")
        let ellipseTarget = try XCTUnwrap((ellipseReply["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        let ellipseLink = try XCTUnwrap(ellipseReply["link_id"] as? String)
        var update = CADParameterService(document: ellipseDocument).handle(action: "updateSketchEntity", args: [
            "sketch_id": ellipseSketch.id.raw.uuidString, "entity_id": ellipseID.uuidString,
            "radius_x": 8.0, "radius_y": 3.5])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        let changedEllipse = try definition(ellipseTarget, in: ellipseDocument, sketch: ellipseSketch)
        guard case let .normalOffset(ellipseBase, ellipseDistance, _) = changedEllipse.support,
              case let .conic(_, rx, ry, _) = ellipseBase.support else { return XCTFail("missing exact basis") }
        XCTAssertEqual(rx, 8); XCTAssertEqual(ry, 3.5); XCTAssertEqual(ellipseDistance, 1)
        XCTAssertEqual(try current(ellipseDocument, ellipseSketch).curveOffsetLinks.first?.id.uuidString, ellipseLink)
        ellipseDocument.session.undo()
        let restoredEllipse = try definition(ellipseTarget, in: ellipseDocument, sketch: ellipseSketch)
        guard case let .normalOffset(restoredEllipseBase, _, _) = restoredEllipse.support,
              case let .conic(_, undoRX, undoRY, _) = restoredEllipseBase.support else { return XCTFail() }
        XCTAssertEqual(undoRX, 7); XCTAssertEqual(undoRY, 3)
        ellipseDocument.session.redo()
        XCTAssertEqual(try current(ellipseDocument, ellipseSketch).curveOffsetLinks.first?.id.uuidString, ellipseLink)

        let splineID = UUID()
        let points = [SIMD2(-12.0,0), SIMD2(-8.0,0), SIMD2(-4.0,0), SIMD2(0.0,2),
                      SIMD2(4.0,4), SIMD2(8.0,4), SIMD2(12.0,4)]
        let (splineDocument, splineSketch) = try await make([.spline(id: splineID, points: points, closed: false)])
        defer { splineDocument.close() }
        let splineReply = curve("offsetSketchCurve", document: splineDocument,
            sketch: splineSketch, id: splineID, distance: 0.5)
        XCTAssertEqual(splineReply["ok"] as? Bool, true, "\(splineReply)")
        let splineTarget = try XCTUnwrap((splineReply["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        update = CADParameterService(document: splineDocument).handle(action: "updateSketchEntity", args: [
            "sketch_id": splineSketch.id.raw.uuidString, "entity_id": splineID.uuidString,
            "point_index": 3, "point": [0.0, 3.0]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        let changedSpline = try definition(splineTarget, in: splineDocument, sketch: splineSketch)
        guard case let .normalOffset(splineBase, splineDistance, _) = changedSpline.support,
              case let .fitSpline(updatedPoints, _) = splineBase.support else { return XCTFail("missing spline basis") }
        XCTAssertEqual(updatedPoints[3], SIMD2(0,3)); XCTAssertEqual(splineDistance, 0.5)
        splineDocument.session.undo()
        let restored = try definition(splineTarget, in: splineDocument, sketch: splineSketch)
        guard case let .normalOffset(restoredBase, _, _) = restored.support,
              case let .fitSpline(restoredPoints, _) = restoredBase.support else { return XCTFail() }
        XCTAssertEqual(restoredPoints, points)
        splineDocument.session.redo()
        XCTAssertEqual(try current(splineDocument, splineSketch).curveOffsetLinks.count, 1)
    }

    func testCuspFromSourceEditIsAtomicWithExactIDs() async throws {
        let sourceID = UUID()
        let (document, sketch) = try await make([.ellipse(id: sourceID, center: .zero,
            radiusX: 7, radiusY: 3, rotation: 0)])
        defer { document.close() }
        let created = curve("offsetSketchCurve", document: document, sketch: sketch,
                            id: sourceID, distance: -0.5)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let targetID = try XCTUnwrap((created["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        let linkID = try XCTUnwrap(created["link_id"] as? String)
        let before = try current(document, sketch)
        let undo = document.session.undoStack.undoCommands.count
        let redo = document.session.undoStack.redoCommands.count
        let reply = CADParameterService(document: document).handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.id.raw.uuidString, "entity_id": sourceID.uuidString, "radius_y": 1.0])
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["error"] as? String, "curve_offset_cusp")
        XCTAssertEqual(Set(reply["affected_entity_ids"] as? [String] ?? []),
                       Set([sourceID.uuidString, targetID.uuidString]))
        XCTAssertEqual(reply["affected_link_ids"] as? [String], [linkID])
        XCTAssertEqual(try current(document, sketch), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(document.session.undoStack.redoCommands.count, redo)
    }

    func testExactSelfIntersectionRefusalDoesNotMutateSketch() async throws {
        let sourceID = UUID()
        // Smooth crossed source: a small offset still intersects without
        // depending on an unrelated end-span tangent corner for refusal.
        let points = [SIMD2(-8.0,-8), SIMD2(-6.0,-6), SIMD2(-4.0,-4), SIMD2(4.0,4),
                      SIMD2(-4.0,4), SIMD2(4.0,-4), SIMD2(6.0,-6), SIMD2(8.0,-8)]
        let (document, sketch) = try await make([.spline(id: sourceID, points: points, closed: false)])
        defer { document.close() }
        let before = try current(document, sketch)
        let reply = curve("offsetSketchCurve", document: document, sketch: sketch,
                          id: sourceID, distance: 0.05)
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["error"] as? String, "curve_offset_self_intersection")
        XCTAssertEqual(try current(document, sketch), before)
    }

    func testOriginalCorneredSplineRefusesUndefinedNormalWithoutMutation() async throws {
        // Retain the original failing four-point source as an explicit
        // physical boundary. Its straight end spans meet at real corners.
        let id = UUID()
        let points = [SIMD2(-6.0,0), SIMD2(-2.0,2), SIMD2(2.0,2), SIMD2(6.0,0)]
        let spline = SketchEntity.spline(id: id, points: points, closed: false)
        let basis = try SketchCurveDefinition(spline)
        let parameter = try basis.parameter(of: points[1])
        let left = try points[1] - basis.point(at: parameter - 1e-6)
        let right = try basis.point(at: parameter + 1e-6) - points[1]
        XCTAssertLessThan(simd_dot(simd_normalize(left), simd_normalize(right)), 0.999,
                          "The retained original source must have distinct one-sided normals.")
        let (document, sketch) = try await make([spline])
        defer { document.close() }
        let before = try current(document, sketch)
        let undo = document.session.undoStack.undoCommands.count
        let reply = curve("offsetSketchCurve", document: document, sketch: sketch, id: id, distance: 0.5)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "curve_offset_cusp")
        XCTAssertEqual(try current(document, sketch), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
    }

    func testGeneralConstraintRefusalNamesConstraintAndKeepsBytes() async throws {
        let id = UUID(), boundaryID = UUID()
        let ellipse = SketchEntity.ellipse(id: id, center: .zero, radiusX: 7, radiusY: 3, rotation: 0)
        let boundary = SketchEntity.line(id: boundaryID, a: SIMD2(0,-10), b: SIMD2(0,10))
        let lock = SketchConstraint(kind: .fixed, refs: [.init(entityID: id, role: .whole)])
        let (document, sketch) = try await make([ellipse, boundary], constraints: [lock])
        defer { document.close() }
        let before = try current(document, sketch)
        let reply = curve("trimSketchCurve", document: document, sketch: sketch,
                          id: id, boundary: boundaryID, pick: [7,0])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "curve_edit_references")
        XCTAssertEqual(reply["affected_constraint_ids"] as? [String], [lock.id.uuidString])
        XCTAssertEqual(try current(document, sketch), before)
    }

    func testExactOffsetProfileFeatureRebuildUndoSaveReopenStayCoherent() async throws {
        let sourceID = UUID()
        let (document, sketch) = try await make([.ellipse(id: sourceID, center: .zero,
            radiusX: 7, radiusY: 3, rotation: 0)])
        let url = document.url
        let created = curve("offsetSketchCurve", document: document, sketch: sketch,
                            id: sourceID, distance: 2)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let targetID = try XCTUnwrap((created["created_entity_ids"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        let command = #"{"op":"feature.extrude","args":{"sketchID":"\#(sketch.id.raw.uuidString)","seedPoint":[8,0],"distance":3}}"#
        let extrude = document.executeJSON(Data(command.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNotNil(body.brep)
        let initialVolume = try volume(document, bodyID: body.id)
        XCTAssertGreaterThan(initialVolume, 0)
        let update = CADParameterService(document: document).handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.id.raw.uuidString, "entity_id": sourceID.uuidString, "radius_x": 7.5])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        let changedVolume = try volume(document, bodyID: body.id)
        XCTAssertGreaterThan(abs(changedVolume - initialVolume), 1e-6)
        document.session.undo()
        XCTAssertEqual(try volume(document, bodyID: body.id), initialVolume, accuracy: 1e-6)
        document.session.redo()
        XCTAssertEqual(try volume(document, bodyID: body.id), changedVolume, accuracy: 1e-6)
        XCTAssertEqual(try definition(targetID, in: document, sketch: sketch).sourceKind, .ellipse)
        let expected = try current(document, sketch)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try current(reopened, sketch), expected)
        let feature = try XCTUnwrap(reopened.session.document.features.nodes.first)
        reopened.session.rebuildFrom(feature.id)
        let reopenedBody = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertNotNil(reopenedBody.brep)
        XCTAssertEqual(try volume(reopened, bodyID: reopenedBody.id), changedVolume, accuracy: 1e-5)
    }

    func testFutureExactDefinitionIsOpaqueAndKnownBadDefinitionIsRejected() throws {
        let source = try SketchCurveDefinition(.ellipse(id: UUID(), center: .zero,
            radiusX: 7, radiusY: 3, rotation: 0))
        let partial = try source.replacingInterval(.init(lower: 0, upper: 1))
        let entity = try partial.materialized(id: UUID())
        let sketch = Sketch(plane: .ground, entities: [entity])
        var document = DesignDocument(); document.sketches = [sketch]
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: DesignDocument()), 1)
        XCTAssertGreaterThanOrEqual(CADDocumentFormat.requiredFormat(document: document), 7)
        let original = try JSONEncoder().encode(sketch)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var entities = try XCTUnwrap(object["entities"] as? [[String: Any]])
        var payload = try XCTUnwrap(entities[0]["exactCurve"] as? [String: Any])
        var definition = try XCTUnwrap(payload["definition"] as? [String: Any])
        definition["version"] = 99
        payload["definition"] = definition; entities[0]["exactCurve"] = payload; object["entities"] = entities
        let future = try JSONSerialization.data(withJSONObject: object)
        let row = CADBlobRecord(blobID: sketch.id.raw, data: future, sha256: "")
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [row])
        XCTAssertTrue(assessment.isOpaqueReadOnly)
        XCTAssertTrue(assessment.opaqueSketches.contains(sketch.id.raw))
        XCTAssertTrue(try CADDocumentFormat.cachedSketch(from: future).entities.isEmpty)

        var malformed = object
        var malformedEntities = try XCTUnwrap(malformed["entities"] as? [[String: Any]])
        var malformedPayload = try XCTUnwrap(malformedEntities[0]["exactCurve"] as? [String: Any])
        var known = try XCTUnwrap(malformedPayload["definition"] as? [String: Any])
        known["version"] = 1
        var support = try XCTUnwrap(known["support"] as? [String: Any])
        var conic = try XCTUnwrap(support["conic"] as? [String: Any])
        conic["radiusX"] = -1
        support["conic"] = conic; known["support"] = support
        malformedPayload["definition"] = known; malformedEntities[0]["exactCurve"] = malformedPayload
        malformed["entities"] = malformedEntities
        let badRow = CADBlobRecord(blobID: sketch.id.raw,
            data: try JSONSerialization.data(withJSONObject: malformed), sha256: "")
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [badRow]))
    }

    func testFutureSiblingPreservesKnownExactCurveInReadOnlyDisplay() throws {
        let source = try SketchCurveDefinition(.ellipse(id: UUID(), center: .zero,
            radiusX: 7, radiusY: 3, rotation: 0))
        let known = try source.replacingInterval(.init(lower: 0, upper: 1)).materialized(id: UUID())
        let futureSeed = try source.replacingInterval(.init(lower: 2, upper: 3)).materialized(id: UUID())
        let sketch = Sketch(plane: .ground, entities: [known, futureSeed])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sketch)) as? [String: Any])
        var entities = try XCTUnwrap(object["entities"] as? [[String: Any]])
        var payload = try XCTUnwrap(entities[1]["exactCurve"] as? [String: Any])
        var definition = try XCTUnwrap(payload["definition"] as? [String: Any])
        definition["version"] = 99
        payload["definition"] = definition; entities[1]["exactCurve"] = payload
        object["entities"] = entities
        let bytes = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try CADDocumentFormat.cachedSketch(from: bytes).entities, [known])
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [
            CADBlobRecord(blobID: sketch.id.raw, data: bytes, sha256: "")])
        XCTAssertTrue(assessment.isOpaqueReadOnly)

        var badPayload = try XCTUnwrap(entities[0]["exactCurve"] as? [String: Any])
        var badDefinition = try XCTUnwrap(badPayload["definition"] as? [String: Any])
        var badInterval = try XCTUnwrap(badDefinition["interval"] as? [String: Any])
        badInterval["upper"] = -1.0
        badDefinition["interval"] = badInterval; badPayload["definition"] = badDefinition
        entities[0]["exactCurve"] = badPayload; object["entities"] = entities
        let bad = CADBlobRecord(blobID: sketch.id.raw,
            data: try JSONSerialization.data(withJSONObject: object), sha256: "")
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [bad]))
    }
}
