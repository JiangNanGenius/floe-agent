//
//  CADCurveConstraintServiceTests.swift
//  FloeCADKitTests
//
//  M02 + M06 through the REAL production services: `CADParameterService`
//  (`setSketchDimension` / `updateSketchEntity`), the document command stack
//  (`AddSketchConstraintCommand`, `AddSketchDimensionCommand`), one-step undo
//  and redo, and the package save/reopen round trip. The connected arc/spline
//  loop must stay closed and tangent through dimension edits, entity edits
//  must move related geometry in ONE undo step, and contradictory driving
//  values must refuse WITHOUT half changes.
//
//  No fake solver: the verdicts come from the production residual gate and
//  the production conflict attribution.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADCurveConstraintServiceTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func makeDocument(_ name: String = "CurveService") async throws -> (FloeCADDocument, URL) {
        let url = workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        return (document, url)
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

    private func sketchEntities(_ document: FloeCADDocument, sketchID: String) throws -> [SketchEntity] {
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == sketchID
        })
        return sketch.entities
    }

    /// Independent ray-cast containment over a profile loop (pure arithmetic,
    /// not `Profile.contains`), proving a chosen extrude seed really is
    /// interior to the detected boundary.
    private static func contains(_ point: SIMD2<Double>,
                                 inPolygon loop: [SIMD2<Double>]) -> Bool {
        guard loop.count >= 3 else { return false }
        var inside = false
        var previous = loop.count - 1
        for current in loop.indices {
            let a = loop[previous], b = loop[current]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    private struct ConnectedLoop {
        var sketchID: String
        var arcID: String
        var splineID: String
        var fixture: CurveLoopFixture.Loop
    }

    /// Creates the arc+spline loop document and adds connection + tangency +
    /// a `25·scale` radius driving dimension through the REAL command stack.
    /// The constraint rows are NOT solved at add time (same as the interactive
    /// editor) — the first driving edit below solves them.
    private func makeConnectedLoop(_ document: FloeCADDocument,
                                   name: String = "Loop",
                                   scale: Double = 1) throws -> ConnectedLoop {
        let fixture = CurveLoopFixture.make(scale: scale)
        let arc = CurveLoopFixture.arcGeometry(fixture)
        let points = CurveLoopFixture.splinePoints(fixture)
        func num(_ v: Double) -> String {
            // JSON numbers with enough precision for 1e-3/1e3 scales.
            String(format: "%.17g", v)
        }
        let pointJSON = points.map { "[\(num($0.x)),\(num($0.y))]" }.joined(separator: ",")
        let created = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(created["sketchID"] as? String)
        let added = try run(document, #"""
        {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
          {"kind":"arc","center":[\#(num(arc.center.x)),\#(num(arc.center.y))],
           "radius":\#(num(arc.radius)),
           "startAngle":\#(num(arc.startAngle)),"endAngle":\#(num(arc.endAngle))},
          {"kind":"spline","points":[\#(pointJSON)],"closed":false}]}}
        """#)
        // JSON creation owns the real entity IDs AND the stored doubles: the
        // command API parses JSONSerialization numbers, whose decimal parser
        // is not bit-exact for every Double (the 1e-3 fixture's fit points
        // move by 1-2 ULP). One undo restores the command's `before` value,
        // i.e. the entity the document actually stored — not the in-process
        // fixture copy. Bind every later ref, undo baseline and measurement
        // to the live entities so the exact snapshot assertion compares the
        // real pre-edit document state.
        let idRows = try XCTUnwrap(added["entityIDs"] as? [String])
        XCTAssertEqual(idRows.count, 2)
        let actualArcID = try XCTUnwrap(UUID(uuidString: idRows[0]))
        let actualSplineID = try XCTUnwrap(UUID(uuidString: idRows[1]))
        let liveEntities = try sketchEntities(document, sketchID: sketchID)
        XCTAssertEqual(liveEntities.map(\.id), [actualArcID, actualSplineID])
        XCTAssertEqual(liveEntities.count, 2)
        var bound = fixture
        bound.arcID = actualArcID
        bound.splineID = actualSplineID
        bound.arc = liveEntities[0]
        bound.spline = liveEntities[1]
        if case let .spline(_, storedPoints, _) = liveEntities[1] {
            XCTAssertEqual(storedPoints.count, points.count)
            bound.start = storedPoints.first ?? bound.start
            bound.end = storedPoints.last ?? bound.end
        }
        let sketch = SketchID(raw: UUID(uuidString: sketchID)!)
        for constraint in CurveLoopFixture.loopConstraints(bound) {
            document.session.perform(AddSketchConstraintCommand(sketchID: sketch, constraint: constraint))
        }
        document.session.perform(AddSketchDimensionCommand(
            sketchID: sketch,
            dimension: CurveLoopFixture.radiusDimension(bound, value: 25 * scale)))
        return ConnectedLoop(sketchID: sketchID,
                             arcID: bound.arcID.uuidString,
                             splineID: bound.splineID.uuidString,
                             fixture: bound)
    }

    // MARK: - M02: dimension edit keeps the section closed

    /// The M02 acceptance through the product surface: constrain connection
    /// and tangency on an arc+spline closed section, modify the driving
    /// radius dimension, and the profile does not split — then one undo
    /// restores BOTH entities, redo reapplies, and save/reopen keeps the
    /// solved geometry.
    func testDimensionEditKeepsLoopClosedThroughUndoRedoAndReopen() async throws {
        for scale in [1e-3, 1.0, 1e3] {
            let (document, url) = try await makeDocument("Loop-\(scale)")
            let loop = try makeConnectedLoop(document, scale: scale)
            let service = CADParameterService(document: document)

            let edited = service.handle(action: "setSketchDimension", args: [
                "sketch_id": loop.sketchID,
                "entity_id": loop.arcID,
                "kind": "radius",
                "value": 40 * scale,
            ])
            XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
            XCTAssertEqual(edited["mutated"] as? Bool, true, "\(edited)")

            let entities = try sketchEntities(document, sketchID: loop.sketchID)
            XCTAssertEqual(entities.map(\.id).map(\.uuidString).sorted(),
                           [loop.arcID, loop.splineID].sorted(),
                           "scale \(scale): entity ids changed")
            guard case let .arc(_, center, radius, _, _) =
                entities.first(where: { $0.id.uuidString == loop.arcID }) else {
                XCTFail("scale \(scale): arc missing"); continue
            }
            XCTAssertEqual(radius, 40 * scale, accuracy: 1e-9 * max(1, 40 * scale),
                           "scale \(scale): driving radius not applied")
            let m = try XCTUnwrap(CurveLoopFixture.measure(entities, loop: loop.fixture),
                                  "scale \(scale)")
            XCTAssertLessThan(m.junctionGapStart, 1e-9, "scale \(scale): start junction split")
            XCTAssertLessThan(m.junctionGapEnd, 1e-9, "scale \(scale): end junction split")
            XCTAssertLessThan(m.onCircleStart, 1e-6, "scale \(scale): start off the arc")
            XCTAssertLessThan(m.onCircleEnd, 1e-6, "scale \(scale): end off the arc")
            XCTAssertLessThan(m.tangentDeviationStart, 1e-4,
                              "scale \(scale): start junction not G1 after the edit")
            XCTAssertLessThan(m.tangentDeviationEnd, 1e-4,
                              "scale \(scale): end junction not G1 after the edit")
            _ = center

            // One undo restores BOTH the arc and the spline (one transaction).
            XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
            let undone = try sketchEntities(document, sketchID: loop.sketchID)
            XCTAssertEqual(undone, [loop.fixture.arc, loop.fixture.spline],
                           "scale \(scale): one undo must restore the whole transaction")

            XCTAssertEqual(service.handle(action: "redo", args: [:])["ok"] as? Bool, true)
            let redone = try sketchEntities(document, sketchID: loop.sketchID)
            guard case let .arc(_, _, redoneRadius, _, _) =
                redone.first(where: { $0.id.uuidString == loop.arcID }) else {
                XCTFail("scale \(scale): arc missing after redo"); continue
            }
            XCTAssertEqual(redoneRadius, 40 * scale, accuracy: 1e-9 * max(1, 40 * scale))

            // Save / reopen keeps the solved, closed loop.
            let saved = await document.save()
            XCTAssertTrue(saved.succeeded, saved.error ?? "")
            document.close()
            let reopened = try await FloeCADDocument.open(at: url)
            let reopenedEntities = try sketchEntities(reopened, sketchID: loop.sketchID)
            let m2 = try XCTUnwrap(CurveLoopFixture.measure(reopenedEntities, loop: loop.fixture))
            XCTAssertLessThan(m2.junctionGapStart, 1e-9)
            XCTAssertLessThan(m2.junctionGapEnd, 1e-9)
            XCTAssertLessThan(m2.onCircleStart, 1e-6)
            XCTAssertLessThan(m2.onCircleEnd, 1e-6)
            XCTAssertLessThan(m2.tangentDeviationStart, 1e-4)
            XCTAssertLessThan(m2.tangentDeviationEnd, 1e-4)
            let reopenedSketch = try XCTUnwrap(reopened.session.document.sketches.first {
                $0.id.raw.uuidString == loop.sketchID
            })
            XCTAssertTrue(reopenedSketch.validateConstraintRefs())
            reopened.close()
        }
    }

    /// The edited closed section still RESOLVES as one profile: extruding it
    /// produces a solid whose volume is consistent with the larger radius.
    /// A split profile would refuse to resolve instead.
    func testEditedLoopStillExtrudesAsOneProfile() async throws {
        let (document, _) = try await makeDocument()
        let loop = try makeConnectedLoop(document)
        let service = CADParameterService(document: document)
        XCTAssertEqual(service.handle(action: "setSketchDimension", args: [
            "sketch_id": loop.sketchID,
            "entity_id": loop.arcID,
            "kind": "radius",
            "value": 40.0,
        ])["ok"] as? Bool, true)

        // The true G1 solution puts the 3-point spline's interior fit point on
        // the tangent-line intersection BELOW the arc: the closed face is the
        // lens between the arc and that lower spline, and the old [60,0] seed
        // is outside it. Ask the actual production profile detector for the
        // one profile bounded by these two entities and seed the extrude with
        // the point it guarantees to be interior. A split/unresolved loop
        // fails here instead of being guessed from a hand-picked point.
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == loop.sketchID
        })
        let arcID = try XCTUnwrap(UUID(uuidString: loop.arcID))
        let splineID = try XCTUnwrap(UUID(uuidString: loop.splineID))
        let loopProfiles = ProfileDetector.detectProfiles(in: sketch).filter {
            $0.sourceEntityIDs == Set([arcID, splineID])
        }
        XCTAssertEqual(loopProfiles.count, 1,
                       "the edited loop must resolve as exactly one closed profile")
        let profile = try XCTUnwrap(loopProfiles.first)
        let seed = profile.interiorPoint
        XCTAssertTrue(Self.contains(seed, inPolygon: profile.loop),
                      "the profile interior seed must lie inside its closed loop")
        XCTAssertFalse(Self.contains(SIMD2<Double>(60, 0), inPolygon: profile.loop),
                       "the old centre seed is outside the true tangent lens")
        let seededProfiles = ProfileDetector.profiles(at: seed, in: sketch)
        XCTAssertEqual(seededProfiles.count, 1,
                       "the extrude seed must select exactly one closed profile")
        XCTAssertEqual(seededProfiles.first?.sourceEntityIDs, Set([arcID, splineID]))

        let extrude = try run(document, #"""
        {"op":"feature.extrude","args":{"sketchID":"\#(loop.sketchID)",
          "seedPoint":[\#(seed.x),\#(seed.y)],"distance":10}}
        """#)
        let bodyID = try XCTUnwrap(
            (extrude["producedBodyIDs"] as? [String])?.first
                ?? (extrude["changedBodyIDs"] as? [String])?.first)
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        XCTAssertTrue(outcome.isOK, "measure failed: \(outcome.errorCode ?? "")")
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
        let volume = try XCTUnwrap(object["volumeMM3"] as? Double)
        XCTAssertGreaterThan(volume, 0)
        // The true lens area is on the order of chord(≈75) × mean height(≈17);
        // anything near zero means the profile split or collapsed.
        XCTAssertGreaterThan(volume / 10, 300, "profile volume implausible: \(volume)")
    }

    // MARK: - M02: entity edit moves related geometry in one undo step

    /// Editing the arc's radius through `updateSketchEntity` solves the saved
    /// system and commits the related spline movement in the SAME undo step;
    /// ids and constraints are preserved; the requested radius stays exact.
    func testArcEntityEditMovesSplineInOneUndoStep() async throws {
        let (document, _) = try await makeDocument()
        let loop = try makeConnectedLoop(document)
        let service = CADParameterService(document: document)

        let edited = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": loop.sketchID,
            "entity_id": loop.arcID,
            "radius": 40.0,
            "expected_radius": 25.0,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        XCTAssertEqual(edited["mutated"] as? Bool, true, "\(edited)")

        let entities = try sketchEntities(document, sketchID: loop.sketchID)
        XCTAssertEqual(entities.map(\.id).map(\.uuidString).sorted(),
                       [loop.arcID, loop.splineID].sorted())
        guard case let .arc(_, _, radius, _, _) =
            entities.first(where: { $0.id.uuidString == loop.arcID }),
              case let .spline(_, points, _) =
            entities.first(where: { $0.id.uuidString == loop.splineID }) else {
            XCTFail("entities missing")
            return
        }
        XCTAssertEqual(radius, 40, accuracy: 1e-9)
        // The spline followed the arc: its ends sit on the new circle.
        let m = try XCTUnwrap(CurveLoopFixture.measure(entities, loop: loop.fixture))
        XCTAssertLessThan(m.junctionGapStart, 1e-9)
        XCTAssertLessThan(m.junctionGapEnd, 1e-9)
        XCTAssertLessThan(m.onCircleStart, 1e-6)
        XCTAssertLessThan(m.onCircleEnd, 1e-6)
        XCTAssertFalse(points.contains(loop.fixture.start),
                       "the spline end did not follow the arc")

        // ONE undo step restores BOTH entities to the baseline.
        XCTAssertEqual(service.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        let undone = try sketchEntities(document, sketchID: loop.sketchID)
        XCTAssertEqual(undone, [loop.fixture.arc, loop.fixture.spline],
                       "one undo must restore arc and spline together")
    }

    /// An IMPOSSIBLE entity edit on a LOCKED entity refuses through the real
    /// whole-entity Lock fence (`locked_entity`, naming the arc's exact fixed
    /// constraint) instead of pretending the solver produced a satisfiable
    /// compromise. Geometry, source IDs and undo/redo history stay unchanged.
    func testImpossibleArcEditRefusesWithoutHalfChanges() async throws {
        let (document, _) = try await makeDocument()
        let loop = try makeConnectedLoop(document)
        let service = CADParameterService(document: document)
        let baseline = try sketchEntities(document, sketchID: loop.sketchID)

        // Freeze the loop: the arc's own fixed constraint is a whole-entity
        // solver fence (rebuilding from a proposed value would silently
        // re-lock it, so the edit gate must refuse it), and the two spline
        // endpoint locks make the requested centre move unsatisfiable too.
        let sketchID = SketchID(raw: UUID(uuidString: loop.sketchID)!)
        let arcLock = SketchConstraint(kind: .fixed, refs: [
            ConstraintRef(entityID: loop.fixture.arcID, role: .center)])
        document.session.perform(AddSketchConstraintCommand(sketchID: sketchID, constraint: arcLock))
        document.session.perform(AddSketchConstraintCommand(sketchID: sketchID, constraint:
            SketchConstraint(kind: .fixed, refs: [
                ConstraintRef(entityID: loop.fixture.splineID, role: .endpointA)])))
        document.session.perform(AddSketchConstraintCommand(sketchID: sketchID, constraint:
            SketchConstraint(kind: .fixed, refs: [
                ConstraintRef(entityID: loop.fixture.splineID, role: .endpointB)])))
        let countBefore = document.session.changeCount
        let canUndoBefore = document.session.undoStack.canUndo
        let canRedoBefore = document.session.undoStack.canRedo

        let refused = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": loop.sketchID,
            "entity_id": loop.arcID,
            "center": [0.0, 0.0],
            "expected_center": [60.0, 0.0],
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "locked_entity", "\(refused)")
        let message = try XCTUnwrap(refused["message"] as? String)
        XCTAssertTrue(message.contains(loop.arcID),
                      "the refusal must name the edited entity: \(message)")
        XCTAssertTrue(message.contains(arcLock.id.uuidString),
                      "the refusal must name the actual fixed constraint: \(message)")
        XCTAssertTrue(message.contains("Nothing was changed"), "\(message)")

        let after = try sketchEntities(document, sketchID: loop.sketchID)
        XCTAssertEqual(after, baseline, "refused edit must not leave half changes")
        let sketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == loop.sketchID
        })
        XCTAssertTrue(sketch.validateConstraintRefs())
        XCTAssertEqual(document.session.changeCount, countBefore,
                       "a refused edit must not create a document change")
        XCTAssertEqual(document.session.undoStack.canUndo, canUndoBefore,
                       "a refused edit must not push an undo step")
        XCTAssertEqual(document.session.undoStack.canRedo, canRedoBefore,
                       "a refused edit must not clear redo")
    }

    // MARK: - M06: contradictory driving values refuse at every scale

    /// A sketch holding two contradictory radius driving dimensions reports
    /// the SAME conflict verdict, highlights the SAME dimension ids, and
    /// refuses further driving edits WITHOUT half changes at 10^-3, 1 and
    /// 10^3 scale — the least-squares best fit is never written as satisfied.
    func testContradictoryRadiusDimensionsRefusedAtAllScales() async throws {
        for scale in [1e-3, 1.0, 1e3] {
            let (document, _) = try await makeDocument("Conflict-\(scale)")
            let loop = try makeConnectedLoop(document, scale: scale)
            let service = CADParameterService(document: document)

            // Inject the contradictory second driving dimension through the
            // real command stack (a document can hold it; the solver must
            // diagnose it truthfully at every scale).
            let sketchID = SketchID(raw: UUID(uuidString: loop.sketchID)!)
            document.session.perform(AddSketchDimensionCommand(
                sketchID: sketchID,
                dimension: CurveLoopFixture.radiusDimension(loop.fixture, value: 40 * scale)))
            let baseline = try sketchEntities(document, sketchID: loop.sketchID)
            let sketch = try XCTUnwrap(document.session.document.sketches.first {
                $0.id.raw.uuidString == loop.sketchID
            })
            let radiusDimensions = sketch.dimensions.filter { $0.kind == .radius }
            XCTAssertEqual(radiusDimensions.count, 2,
                           "scale \(scale): fixture must hold both radius dimensions")

            // Scale-consistent diagnosis: same attributed ids, same verdict.
            let blame = SketchSolverBridge.conflictAttribution(sketch)
            XCTAssertEqual(blame.dimensionIDs, Set(radiusDimensions.map(\.id)),
                           "scale \(scale): conflict highlight must name the actual dimensions")
            XCTAssertGreaterThan(SketchSolverBridge.residualNorm(sketch),
                                 SketchSolverBridge.overConstraintTolerance,
                                 "scale \(scale): best fit must not read as satisfied")
            let report = SketchSolverBridge.definitionReport(sketch)
            XCTAssertTrue(report.conflicting,
                          "scale \(scale): definition report must say conflicting")

            // Any further driving edit refuses — no half change survives.
            let conflict = service.handle(action: "setSketchDimension", args: [
                "sketch_id": loop.sketchID,
                "entity_id": loop.arcID,
                "kind": "radius",
                "value": 30 * scale,
            ])
            XCTAssertEqual(conflict["ok"] as? Bool, false, "\(conflict)")
            XCTAssertEqual(conflict["error"] as? String, "constraint_conflict", "\(conflict)")
            let after = try sketchEntities(document, sketchID: loop.sketchID)
            XCTAssertEqual(after, baseline, "scale \(scale): refused edit left half changes")
            document.close()
        }
    }
}
