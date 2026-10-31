//
//  CADCurveConstraintAdmissionTests.swift
//  FloeCADKitTests
//
//  R1/R2 review plus final admission correction on top of M02/M06.
//  Structural satisfaction uses per-equation backward error AND absolute
//  precision, independent of LM conditioning and transient intent. Tests also
//  cover direct service/save role admission, report/query consumers, dropped
//  relations and connected-arc branch continuity. Original suites are untouched.
//
//  Verdicts come from the production solver, the production edit gate and the
//  production document stack — no mirrored solver decides anything.
//

import XCTest
import simd
@testable import FloeCAD

// MARK: - Review fixture shadows (self.helper)

@MainActor
final class CADCurveConstraintAdmissionTests: XCTestCase {

    /// Local fixture variants for the review sketches. Shared
    /// `CurveLoopFixture` is reused where its exact contract applies; the
    /// shadows below exist because the admission/branch cases need sketches
    /// the shared fixture does not build (contradictory segment, wrap arc,
    /// two-arc junction, dropped-relation pairs).
    private struct Helper {
        struct Segment {
            var lineID: UUID
            var sketch: Sketch
        }

        /// A segment A=(0,0) B=(100*scale,0) with two driving distance
        /// dimensions on the same endpoints (values L and L+delta*scale*... in
        /// sketch units) — the contradictory same-length system.
        func contradictorySegment(scale: Double, delta: Double,
                                  distractor: Bool = false) -> Segment {
            // Fixed IDs make this the SAME deterministic symbolic system at
            // every scale; fresh UUIDs would make cross-scale blame comparison
            // meaningless. A separate case adds a huge unrelated entity.
            let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let firstID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let secondID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            let a = SIMD2<Double>(0, 0)
            let b = SIMD2<Double>(100 * scale, 0)
            let line = SketchEntity.line(id: id, a: a, b: b)
            let refA = ConstraintRef(entityID: id, role: .endpointA)
            let refB = ConstraintRef(entityID: id, role: .endpointB)
            let first = SketchDimension(id: firstID, kind: .distance, refs: [refA, refB],
                                         value: 100 * scale)
            let second = SketchDimension(id: secondID, kind: .distance, refs: [refA, refB],
                                         value: (100 + delta) * scale)
            var entities: [SketchEntity] = [line]
            if distractor {
                entities.append(.circle(
                    id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    center: SIMD2(0, 0), radius: 1e6 * scale))
            }
            return Segment(lineID: id,
                           sketch: Sketch(plane: .ground, entities: entities,
                                          constraints: [], dimensions: [first, second]))
        }


        /// A line at 10 deg off axis whose endpoints are pinned by axis
        /// driving dimensions, with the direction held transiently — the held
        /// direction row then contradicts the saved dimensions by a fixed
        /// relative amount (sin10*cos10), identical at every scale.
        func heldDirectionConflict(scale: Double) -> Sketch {
            let id = UUID()
            let theta = 10 * .pi / 180
            let a = SIMD2<Double>(0, 0)
            let b = SIMD2<Double>(100 * scale * cos(theta), 100 * scale * sin(theta))
            let line = SketchEntity.line(id: id, a: a, b: b)
            let refA = ConstraintRef(entityID: id, role: .endpointA)
            let refB = ConstraintRef(entityID: id, role: .endpointB)
            let horizontal = SketchDimension(kind: .horizontal, refs: [refA, refB],
                                             value: 100 * scale * cos(theta))
            let vertical = SketchDimension(kind: .vertical, refs: [refA, refB],
                                           value: 0)
            let lock = SketchConstraint(kind: .fixed, refs: [refA])
            return Sketch(plane: .ground, entities: [line],
                          constraints: [lock], dimensions: [horizontal, vertical])
        }

        struct WrapLoop {
            var arc: SketchEntity
            var spline: SketchEntity
            var arcID: UUID
            var splineID: UUID
            var center: SIMD2<Double>
            var radius: Double
            var startAngle: Double
            var endAngle: Double
            var sketch: Sketch
        }

        /// Connected arc+spline loop with custom arc angles (the wrap case
        /// draws the arc ACROSS 0 degrees).
        func wrapLoop(scale: Double, startDeg: Double, endDeg: Double,
                      angleDimensionDeg: Double) -> WrapLoop {
            let arcID = UUID()
            let splineID = UUID()
            let center = SIMD2<Double>(60 * scale, 0)
            let radius = 25 * scale
            let start = startDeg * .pi / 180
            let end = endDeg * .pi / 180
            let p0 = SketchEntity.arcPoint(center: center, radius: radius, angle: start)
            let p1 = SketchEntity.arcPoint(center: center, radius: radius, angle: end)
            let mid = SIMD2<Double>((p0.x + p1.x) / 2,
                                    max(p0.y, p1.y) + 18 * scale)
            let arc = SketchEntity.arc(id: arcID, center: center, radius: radius,
                                       startAngle: start, endAngle: end)
            let spline = SketchEntity.spline(id: splineID, points: [p0, mid, p1],
                                             closed: false)
            let constraints = [
                SketchConstraint(kind: .coincident, refs: [
                    ConstraintRef(entityID: arcID, role: .endpointA),
                    ConstraintRef(entityID: splineID, role: .endpointA)]),
                SketchConstraint(kind: .coincident, refs: [
                    ConstraintRef(entityID: arcID, role: .endpointB),
                    ConstraintRef(entityID: splineID, role: .endpointB)]),
                SketchConstraint(kind: .tangent, refs: [
                    ConstraintRef(entityID: arcID, role: .endpointA),
                    ConstraintRef(entityID: splineID, role: .endpointA)]),
                SketchConstraint(kind: .tangent, refs: [
                    ConstraintRef(entityID: arcID, role: .endpointB),
                    ConstraintRef(entityID: splineID, role: .endpointB)]),
                SketchConstraint(kind: .fixed, refs: [
                    ConstraintRef(entityID: arcID, role: .center)]),
            ]
            let dimension = SketchDimension(
                kind: .angle, refs: [ConstraintRef(entityID: arcID, role: .whole)],
                value: angleDimensionDeg * .pi / 180)
            return WrapLoop(arc: arc, spline: spline, arcID: arcID, splineID: splineID,
                            center: center, radius: radius,
                            startAngle: start, endAngle: end,
                            sketch: Sketch(plane: .ground, entities: [arc, spline],
                                           constraints: constraints,
                                           dimensions: [dimension]))
        }

        /// Independent closure/tangency/on-circle readout for a WrapLoop,
        /// measured purely from entity geometry (same construction as
        /// `CurveLoopFixture.measure`, which is typed to its own fixture).
        struct WrapMeasurement {
            var junctionGapStart: Double
            var junctionGapEnd: Double
            var onCircleStart: Double
            var onCircleEnd: Double
            var tangentDeviationStart: Double
            var tangentDeviationEnd: Double
        }

        func measure(_ entities: [SketchEntity], loop: WrapLoop) -> WrapMeasurement? {
            guard let arcEntity = entities.first(where: { $0.id == loop.arcID }),
                  case let .arc(_, center, radius, startAngle, endAngle) = arcEntity,
                  let splineEntity = entities.first(where: { $0.id == loop.splineID }),
                  case let .spline(_, points, closed) = splineEntity,
                  !closed, points.count >= 2 else { return nil }
            let a0 = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
            let a1 = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
            let charLength = max(simd_distance(a0, a1) + radius, 1e-300)

            func onCircle(_ p: SIMD2<Double>) -> Double {
                abs(simd_length(p - center) - radius) / charLength
            }
            func g1(_ p: SIMD2<Double>, tangent: SIMD2<Double>) -> Double {
                let radiusVec = p - center
                let rLen = simd_length(radiusVec)
                let tLen = simd_length(tangent)
                guard rLen > 1e-12, tLen > 1e-12 else { return .infinity }
                let arcTangent = SIMD2<Double>(-radiusVec.y / rLen, radiusVec.x / rLen)
                let dot = min(1.0, abs(simd_dot(arcTangent, tangent / tLen)))
                return acos(dot)
            }
            let spans = CatmullRomBezier.spans(points, closed: false)
            let t0 = CatmullRomBezier.derivative(spans[0], 0)
            let t1 = CatmullRomBezier.derivative(spans[spans.count - 1], 1)
            return WrapMeasurement(
                junctionGapStart: simd_distance(points.first!, a0) / charLength,
                junctionGapEnd: simd_distance(points.last!, a1) / charLength,
                onCircleStart: onCircle(a0),
                onCircleEnd: onCircle(a1),
                tangentDeviationStart: g1(a0, tangent: t0),
                tangentDeviationEnd: g1(a1, tangent: t1))
        }
    }

    private var helper: Helper { Helper() }

    // MARK: - Finding 1 (final): per-equation backward error AND absolute
    // product precision; a best fit is never written as satisfied

    /// The historical near conflict — the same length driven
    /// 0.01/0.05/0.10/0.15 mm apart on a 100 mm sketch — must be REFUSED,
    /// attributed to the actual dimensions, and reported conflicting. The
    /// gate-equivalent score preserves the public 1e-3 threshold while the
    /// independent backward/raw fields expose the physical verdict inputs.
    func testNearConflictRefusedAtWorkingScaleWithExactBlame() throws {
        for delta in [0.01, 0.05, 0.10, 0.15] {
            let segment = helper.contradictorySegment(scale: 1, delta: delta)
            let outcome = SketchSolverBridge.solveOutcome(
                segment.sketch, movingEntity: nil, dragTarget: nil)
            XCTAssertGreaterThan(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance,
                                 "delta \(delta) mm on a 100 mm sketch is a real "
                                 + "contradiction and must not be written as satisfied")
            let report = SketchSolverBridge.definitionReport(segment.sketch)
            XCTAssertTrue(report.conflicting, "delta \(delta): report must say conflicting")
            let blame = SketchSolverBridge.conflictAttribution(segment.sketch)
            XCTAssertEqual(blame.dimensionIDs,
                           Set(segment.sketch.dimensions.map(\.id)),
                           "delta \(delta): both driving dimensions must be highlighted")
        }
    }

    /// The same RELATIVE contradiction refuses at EVERY scale. delta/L =
    /// 0.15 (the 25-vs-40 class of conflict) exceeds the normalized component
    /// of the gate at 10^-3, 1 and 10^3 alike, with the SAME attributed ids —
    /// the immutable M06 requirement.
    func testGenuineRelativeConflictRefusedAtAllScales() throws {
        var verdicts: [Bool] = []
        var blamed: Set<UUID>?
        for scale in [1e-3, 1.0, 1e3] {
            let segment = helper.contradictorySegment(scale: scale, delta: 15)
            let refused = SketchSolverBridge.residualNorm(segment.sketch)
                > SketchSolverBridge.overConstraintTolerance
            verdicts.append(refused)
            let blame = SketchSolverBridge.conflictAttribution(segment.sketch)
            if blamed == nil {
                blamed = blame.dimensionIDs
            } else {
                XCTAssertEqual(blame.dimensionIDs, blamed,
                               "scale \(scale): blame ids must match every other scale")
            }
        }
        XCTAssertEqual(verdicts, [true, true, true],
                       "a genuinely contradictory relative system must refuse at all scales")
    }

    /// Coordinator's primary counterexample: the SAME 0.05% contradiction
    /// must refuse at 10^-3/1/10^3, with identical blame and independently
    /// measured driving errors. Product display precision is not structural
    /// satisfaction; a 5e-4 relative variant also refuses instead of pinning
    /// the old "below floor therefore satisfied" defect.
    func testRelativeContradictionsRefusedAtAllScalesWithIndependentReadout() throws {
        for delta in [0.05, 5e-4] {
            var blamed: Set<UUID>?
            for scale in [1e-3, 1.0, 1e3] {
                let segment = helper.contradictorySegment(scale: scale, delta: delta)
                let outcome = SketchSolverBridge.solveOutcome(
                    segment.sketch, movingEntity: nil, dragTarget: nil)
                XCTAssertFalse(outcome.converged && outcome.structuralResidual
                               <= SketchSolverBridge.overConstraintTolerance,
                               "delta \(delta), scale \(scale): best fit admitted")
                XCTAssertGreaterThan(outcome.structuralBackwardError,
                                     SketchSolverBridge.relativeSatisfactionTolerance)
                let report = SketchSolverBridge.definitionReport(segment.sketch)
                XCTAssertTrue(report.conflicting)
                XCTAssertFalse(report.isFullyDefined)
                let blame = SketchSolverBridge.conflictAttribution(segment.sketch)
                XCTAssertFalse(blame.dimensionIDs.isEmpty)
                XCTAssertTrue(blame.dimensionIDs.isSubset(of:
                    Set(segment.sketch.dimensions.map(\.id))))
                if delta == 0.05 {
                    if let blamed { XCTAssertEqual(blame.dimensionIDs, blamed) }
                    blamed = blame.dimensionIDs
                }
                guard case let .line(_, a, b)? = outcome.entities.first(where: {
                    $0.id == segment.lineID
                }) else { XCTFail("line missing"); continue }
                let fitted = simd_length(b - a)
                let errors = segment.sketch.dimensions.map { abs(fitted - $0.value) }
                XCTAssertTrue(errors.contains(where: { $0 > 0 }),
                              "a compromise cannot satisfy both driving dimensions")
                if delta == 0.05 {
                    for (index, dimension) in segment.sketch.dimensions.enumerated() {
                        XCTAssertGreaterThan(errors[index] / dimension.value,
                                             SketchSolverBridge.relativeSatisfactionTolerance,
                                             "scale \(scale): dimension \(index) error hidden")
                    }
                }
            }
            if delta == 0.05 {
                XCTAssertEqual(blamed, Set([UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                                            UUID(uuidString: "33333333-3333-3333-3333-333333333333")!]))
            }
        }
    }

    /// Per-equation backward error, not global best-fit loss: a huge unrelated
    /// circle cannot dilute the small line's contradictory driving dimension.
    func testSmallDimensionConflictIsNotDilutedByLargeGeometry() throws {
        let segment = helper.contradictorySegment(scale: 1, delta: 0.05, distractor: true)
        let outcome = SketchSolverBridge.solveOutcome(
            segment.sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertFalse(outcome.converged && outcome.structuralResidual
                       <= SketchSolverBridge.overConstraintTolerance)
        XCTAssertGreaterThan(outcome.structuralBackwardError,
                             SketchSolverBridge.relativeSatisfactionTolerance)
        XCTAssertFalse(SketchSolverBridge.conflictAttribution(segment.sketch).dimensionIDs.isEmpty)
    }

    /// SERVICE regression: a document holding the near-conflicting pair
    /// (0.05 mm apart on a 100 mm sketch) refuses a further driving edit with
    /// constraint_conflict, names BOTH dimensions, changes nothing — the
    /// least-squares best fit is never written under the label satisfied.
    func testServiceRefusesNearConflictWithoutHalfChanges() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("near-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Near")
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"N"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"line","a":[0,0],"b":[100,0]}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        let liveSketch = try XCTUnwrap(document.session.document.sketches.first {
            $0.id == sid
        })
        let lineID = liveSketch.entities[0].id
        let refA = ConstraintRef(entityID: lineID, role: .endpointA)
        let refB = ConstraintRef(entityID: lineID, role: .endpointB)
        let first = SketchDimension(kind: .distance, refs: [refA, refB], value: 100)
        let second = SketchDimension(kind: .distance, refs: [refA, refB], value: 100.05)
        document.session.perform(AddSketchDimensionCommand(sketchID: sid, dimension: first))
        document.session.perform(AddSketchDimensionCommand(sketchID: sid, dimension: second))
        let baseline = document.session.document.sketches.first { $0.id == sid }!.entities

        let sketch = document.session.document.sketches.first { $0.id == sid }!
        let report = SketchSolverBridge.definitionReport(sketch)
        XCTAssertTrue(report.conflicting,
                      "near conflict must report conflicting, not fully defined")

        let service = CADParameterService(document: document)
        let refused = service.handle(action: "setSketchDimension", args: [
            "sketch_id": sketchID,
            "entity_id": lineID.uuidString,
            "kind": "distance",
            "value": 90.0,
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "constraint_conflict", "\(refused)")
        let message = try XCTUnwrap(refused["message"] as? String)
        XCTAssertTrue(message.contains(first.id.uuidString),
                      "refusal must name the first dimension: \(message)")
        XCTAssertTrue(message.contains(second.id.uuidString),
                      "refusal must name the second dimension: \(message)")
        XCTAssertTrue(message.contains("Nothing was changed"), "\(message)")
        let after = document.session.document.sketches.first { $0.id == sid }!.entities
        XCTAssertEqual(after, baseline, "refused edit must leave every byte unchanged")
        document.close()
    }


    /// Direction/projection rows remain millimetre-normalized for LM, but
    /// they are transient candidate preferences, not saved equations. Adding
    /// one cannot change structural DOF/verdict or mint phantom blame. The
    /// unit/large-scale no-preference nonconvergence is a frozen R2 numerical
    /// baseline and is asserted identically on both paths, not hidden.
    func testTransientDirectionPreferenceDoesNotChangeStructuralAdmission() throws {
        for scale in [1e-3, 1.0, 1e3] {
            let sketch = helper.heldDirectionConflict(scale: scale)
            let lineID = sketch.entities[0].id
            let preferred = SketchSolverBridge.solveOutcome(
                sketch, movingEntity: nil, dragTarget: nil,
                preservingLineDirection: lineID)
            let plain = SketchSolverBridge.solveOutcome(
                sketch, movingEntity: nil, dragTarget: nil)
            let preferredAdmitted = preferred.converged && preferred.structuralResidual
                <= SketchSolverBridge.overConstraintTolerance
            let plainAdmitted = plain.converged && plain.structuralResidual
                <= SketchSolverBridge.overConstraintTolerance
            XCTAssertEqual(preferredAdmitted, plainAdmitted, "scale \(scale)")
            XCTAssertEqual(preferred.dof, plain.dof, "scale \(scale)")
            let blame = SketchSolverBridge.conflictAttribution(sketch)
            XCTAssertTrue(blame.constraintIDs.isEmpty && blame.entityIDs.isEmpty)
            XCTAssertTrue(blame.dimensionIDs.isSubset(of:
                Set(sketch.dimensions.map(\.id))))
            if plainAdmitted {
                guard case let .line(_, _, end)? = preferred.entities.first(where: {
                    $0.id == lineID
                }) else { XCTFail("line missing"); continue }
                XCTAssertLessThan(abs(end.y), 1e-8 * max(1, scale),
                                  "saved vertical dimension must win over preference")
            } else {
                XCTAssertFalse(preferredAdmitted)
                XCTAssertFalse(SketchSolverBridge.definitionReport(sketch).converged)
            }
        }
    }

    // MARK: - Finding 2: the transient radiusOnly anchor never persists

    /// Drives a connected-arc radius edit through the real service (the only
    /// producer of the transient `.radiusOnly` hold) and verifies the saved
    /// document vocabulary is unchanged: no constraint or dimension carries
    /// the role, before and after a save/reopen round trip, and the legacy
    /// four-role payload still decodes. The persistence boundary itself is
    /// the saved-role admission: a payload that DOES contain the role in a
    /// saved relation is REFUSED at decode with a precise error (R2) — the
    /// public saved-role contract stays truthful and no hand-written archive
    /// can smuggle a solver-local anchor into the document.
    func testRadiusOnlyAnchorNeverPersistsAndLegacyRolesRoundTrip() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("radius-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Radius")
        let loop = CurveLoopFixture.make(scale: 1)
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"L"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        func num(_ v: Double) -> String { String(format: "%.17g", v) }
        let arc = CurveLoopFixture.arcGeometry(loop)
        let points = CurveLoopFixture.splinePoints(loop)
        let pointJSON = points.map { "[\($0.x),\($0.y)]" }.joined(separator: ",")
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"arc","center":[\#(num(arc.center.x)),\#(num(arc.center.y))],
               "radius":\#(num(arc.radius)),
               "startAngle":\#(num(arc.startAngle)),"endAngle":\#(num(arc.endAngle))},
              {"kind":"spline","points":[\#(pointJSON)],"closed":false}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        for constraint in CurveLoopFixture.loopConstraints(loop) {
            document.session.perform(AddSketchConstraintCommand(sketchID: sid, constraint: constraint))
        }

        let service = CADParameterService(document: document)
        let edited = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketchID,
            "entity_id": loop.arcID.uuidString,
            "radius": 40.0,
            "expected_radius": 25.0,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")

        func assertPersistedVocabulary(_ sketches: [Sketch], _ label: String) {
            for sketch in sketches {
                for constraint in sketch.constraints {
                    for ref in constraint.refs {
                        XCTAssertNotEqual(ref.role, .radiusOnly,
                                          "\(label): radiusOnly leaked into a saved constraint")
                    }
                }
                for dimension in sketch.dimensions {
                    for ref in dimension.refs {
                        XCTAssertNotEqual(ref.role, .radiusOnly,
                                          "\(label): radiusOnly leaked into a saved dimension")
                    }
                }
                XCTAssertTrue(sketch.validateConstraintRefs())
            }
        }
        assertPersistedVocabulary(document.session.document.sketches, "in-memory after edit")

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        assertPersistedVocabulary(reopened.session.document.sketches, "after save/reopen")
        reopened.close()

        // Legacy persisted vocabulary decodes exactly as before.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let entityID = UUID()
        for role in [PointRole.endpointA, .endpointB, .center, .whole] {
            let ref = ConstraintRef(entityID: entityID, role: role)
            let roundTripped = try decoder.decode(
                ConstraintRef.self, from: encoder.encode(ref))
            XCTAssertEqual(roundTripped, ref, "legacy role \(role.rawValue) must round-trip")
        }
        // R2: the transient role in a SAVED payload is refused at decode —
        // the decode boundary is the saved-role admission check.
        let payload = #"{"entityID":"\#(entityID.uuidString)","role":"radiusOnly"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ConstraintRef.self, from: payload)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("expected DecodingError.dataCorrupted, got \(error)"); return
            }
            XCTAssertTrue(context.debugDescription.contains("radiusOnly"),
                          "refusal must explain the role: \(context.debugDescription)")
        }
        // Save-side admission is independent of decode: even a future direct
        // programmatic path must not CREATE an archive that fails on reopen.
        XCTAssertThrowsError(try encoder.encode(
            ConstraintRef(entityID: entityID, role: .radiusOnly))) { error in
            guard case EncodingError.invalidValue(let value, let context) = error else {
                XCTFail("expected EncodingError.invalidValue, got \(error)"); return
            }
            XCTAssertEqual(value as? PointRole, .radiusOnly)
            XCTAssertTrue(context.debugDescription.contains("radiusOnly"))
        }
    }

    /// DIRECT service admission (not decoder-only): explicit unsupported roles
    /// are rejected before trial/document commands; omitted roles keep their
    /// legacy default and valid roles still save/reopen. Rejected attempts do
    /// not touch geometry, dimensions, revision, changeCount or undo state.
    func testServiceRejectsUnsupportedExplicitRolesAtomicallyAndReopens() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("roles-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Roles")
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"R"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"line","a":[0,0],"b":[100,0]},
              {"kind":"circle","center":[200,0],"radius":25}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        let initial = try XCTUnwrap(document.session.document.sketches.first { $0.id == sid })
        let lineID = initial.entities[0].id, circleID = initial.entities[1].id
        let baselineRevision = document.revision
        let baselineChangeCount = document.session.changeCount
        let baselineUndo = document.session.undoStack.canUndo
        let service = CADParameterService(document: document)

        for role in ["radiusOnly", "notARole"] {
            let refused = service.handle(action: "setSketchDimension", args: [
                "sketch_id": sketchID, "kind": "distance", "value": 100.0,
                "refs": [
                    ["entity_id": lineID.uuidString, "role": "endpointA"],
                    ["entity_id": lineID.uuidString, "role": role],
                ],
            ])
            XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
            XCTAssertEqual(refused["error"] as? String, "bad_refs", "\(refused)")
            XCTAssertTrue((refused["message"] as? String)?.contains(role) == true)
            XCTAssertEqual(document.session.document.sketches.first { $0.id == sid }, initial)
            XCTAssertEqual(document.revision, baselineRevision)
            XCTAssertEqual(document.session.changeCount, baselineChangeCount)
            XCTAssertEqual(document.session.undoStack.canUndo, baselineUndo)
        }
        let rejectedSave = await document.save()
        XCTAssertTrue(rejectedSave.succeeded, rejectedSave.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == sid }, initial)

        // Omitted role keeps the legacy `.whole` default on a radius dimension.
        let validService = CADParameterService(document: reopened)
        let validDefault = validService.handle(action: "setSketchDimension", args: [
            "sketch_id": sketchID, "kind": "radius", "value": 10.0,
            "refs": [["entity_id": circleID.uuidString]],
        ])
        XCTAssertEqual(validDefault["ok"] as? Bool, true, "\(validDefault)")
        // Explicit legacy point roles remain valid on a driving line length.
        let validExplicit = validService.handle(action: "setSketchDimension", args: [
            "sketch_id": sketchID, "kind": "distance", "value": 110.0,
            "refs": [
                ["entity_id": lineID.uuidString, "role": "endpointA"],
                ["entity_id": lineID.uuidString, "role": "endpointB"],
            ],
        ])
        XCTAssertEqual(validExplicit["ok"] as? Bool, true, "\(validExplicit)")
        let validSave = await reopened.save()
        XCTAssertTrue(validSave.succeeded, validSave.error ?? "")
        reopened.close()

        let roundTripped = try await FloeCADDocument.open(at: url)
        let saved = try XCTUnwrap(roundTripped.session.document.sketches.first { $0.id == sid })
        XCTAssertEqual(saved.dimensions.count, 2)
        XCTAssertEqual(saved.dimensions.first { $0.kind == .radius }?.refs.map(\.role), [.whole])
        XCTAssertEqual(saved.dimensions.first { $0.kind == .distance }?.refs.map(\.role),
                       [.endpointA, .endpointB])
        XCTAssertTrue(saved.dimensions.flatMap(\.refs).allSatisfy { $0.role.isPersistable })
        roundTripped.close()
    }

    /// The save boundary itself is exercised through the real document stack:
    /// a future command that bypasses the service cannot create an archive
    /// which only fails when reopened. The last healthy package remains readable.
    func testDocumentSaveRefusesProgrammaticRadiusOnlyAndPreservesHealthyPackage() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("save-role-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "SaveRole")
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"S"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"circle","center":[0,0],"radius":25}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        let circleID = document.session.document.sketches.first { $0.id == sid }!.entities[0].id
        let healthySave = await document.save()
        XCTAssertTrue(healthySave.succeeded, healthySave.error ?? "")

        let invalid = SketchDimension(kind: .radius, refs: [
            ConstraintRef(entityID: circleID, role: .radiusOnly)], value: 25)
        document.session.perform(AddSketchDimensionCommand(sketchID: sid, dimension: invalid))
        let refusedSave = await document.save()
        XCTAssertFalse(refusedSave.succeeded, "save must refuse a transient persisted role")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let healthy = try XCTUnwrap(reopened.session.document.sketches.first { $0.id == sid })
        XCTAssertTrue(healthy.dimensions.isEmpty,
                      "failed save must not replace the last healthy package")
        XCTAssertEqual(healthy.entities.count, 1)
        reopened.close()
    }

    // MARK: - Finding 3: dropped relations are diagnosed, never faked

    /// A parallel relation on an arc lowers NOTHING (an arc is never a line
    /// pair). The solver must report the system it actually solved — same
    /// DOF with and without the dropped constraint, zero residual — and the
    /// relation must never appear in conflict attribution (it owns no row).
    func testParallelOnArcLowersNothingAndConsumesNoDOF() throws {
        let lineID = UUID()
        let arcID = UUID()
        let line = SketchEntity.line(id: lineID, a: SIMD2(0, 0), b: SIMD2(100, 0))
        let arc = SketchEntity.arc(id: arcID, center: SIMD2(300, 0), radius: 25,
                                   startAngle: 0, endAngle: .pi)
        let parallel = SketchConstraint(kind: .parallel, refs: [
            ConstraintRef(entityID: lineID, role: .whole),
            ConstraintRef(entityID: arcID, role: .whole)])
        func outcome(_ constraints: [SketchConstraint])
            -> SketchSolverBridge.Outcome {
            SketchSolverBridge.solveOutcome(
                Sketch(plane: .ground, entities: [line, arc],
                       constraints: constraints, dimensions: []),
                movingEntity: nil, dragTarget: nil)
        }
        let with = outcome([parallel])
        let without = outcome([])
        XCTAssertEqual(with.dof, without.dof,
                       "a dropped parallel must consume no degrees of freedom")
        XCTAssertLessThanOrEqual(with.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        let blame = SketchSolverBridge.conflictAttribution(
            Sketch(plane: .ground, entities: [line, arc],
                   constraints: [parallel], dimensions: []))
        XCTAssertFalse(blame.constraintIDs.contains(parallel.id),
                       "a constraint owning no residual row must never be blamed")
        // R2: the report must name it UNSUPPORTED instead of counting it as
        // satisfied by omission — a status that only shows DOF would
        // silently pass over an ignored saved relation.
        let report = SketchSolverBridge.definitionReport(
            Sketch(plane: .ground, entities: [line, arc],
                   constraints: [parallel], dimensions: []))
        XCTAssertEqual(report.unsupportedRelationIDs, [parallel.id],
                       "a relation that lowers to no row must be reported unsupported")
        XCTAssertFalse(report.conflicting,
                       "unsupported is a separate state from conflicting")
    }

    /// A sketch that carries BOTH a real conflict and an ignored relation
    /// must surface the two states independently: the conflict blames the
    /// actual dimensions, the ignored relation is listed unsupported, and
    /// neither state hides the other.
    func testUnsupportedRelationCoexistsWithRealConflict() throws {
        let lineID = UUID()
        let arcID = UUID()
        let line = SketchEntity.line(id: lineID, a: SIMD2(0, 0), b: SIMD2(100, 0))
        let arc = SketchEntity.arc(id: arcID, center: SIMD2(300, 0), radius: 25,
                                   startAngle: 0, endAngle: .pi)
        let parallel = SketchConstraint(kind: .parallel, refs: [
            ConstraintRef(entityID: lineID, role: .whole),
            ConstraintRef(entityID: arcID, role: .whole)])
        let refA = ConstraintRef(entityID: lineID, role: .endpointA)
        let refB = ConstraintRef(entityID: lineID, role: .endpointB)
        let first = SketchDimension(kind: .distance, refs: [refA, refB], value: 100)
        let second = SketchDimension(kind: .distance, refs: [refA, refB], value: 100.05)
        let sketch = Sketch(plane: .ground, entities: [line, arc],
                            constraints: [parallel], dimensions: [first, second])
        let report = SketchSolverBridge.definitionReport(sketch)
        XCTAssertTrue(report.conflicting, "the real near conflict must surface")
        XCTAssertEqual(report.unsupportedRelationIDs, [parallel.id],
                       "the ignored relation must surface independently")
        let blame = SketchSolverBridge.conflictAttribution(sketch)
        XCTAssertEqual(blame.dimensionIDs, [first.id, second.id])
        XCTAssertFalse(blame.constraintIDs.contains(parallel.id))
    }

    /// A tangent saved between two ARC ENDPOINTS has no junction lowering in
    /// the M02 vocabulary (that path serves an open-spline end only), so the
    /// legacy fall-through lowers whole-CIRCLE tangency. The review verified
    /// the consequence is NOT a faked junction tangency claim: the weld keeps
    /// the junction on both circles, the coherence rows force the weld to the
    /// single contact point of two externally tangent circles, and the shared
    /// tangent line there follows from the geometry — every fact measured
    /// independently from the solved entities.
    func testArcEndpointTangentFallsBackToCircleTangencyAndStaysWelded() throws {
        let arc1 = SketchEntity.arc(id: UUID(), center: SIMD2(0, 0), radius: 25,
                                    startAngle: .pi, endAngle: 0)
        let arc2 = SketchEntity.arc(id: UUID(), center: SIMD2(50, 0), radius: 25,
                                    startAngle: .pi, endAngle: 0)
        let j1 = ConstraintRef(entityID: arc1.id, role: .endpointB)
        let j2 = ConstraintRef(entityID: arc2.id, role: .endpointA)
        let sketch = Sketch(
            plane: .ground, entities: [arc1, arc2],
            constraints: [
                SketchConstraint(kind: .coincident, refs: [j1, j2]),
                SketchConstraint(kind: .tangent, refs: [j1, j2]),
            ],
            dimensions: [])
        let outcome = SketchSolverBridge.solveOutcome(
            sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertTrue(outcome.converged)
        XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        guard case let .arc(_, c1, r1, _, _)? =
            outcome.entities.first(where: { $0.id == arc1.id }),
              case let .arc(_, c2, r2, _, _)? =
            outcome.entities.first(where: { $0.id == arc2.id }) else {
            XCTFail("arcs missing"); return
        }
        // The lowered row is whole-circle tangency.
        let centerDistance = simd_length(c2 - c1)
        XCTAssertEqual(centerDistance, r1 + r2, accuracy: 1e-9,
                       "the enforced relation is circle-circle tangency")
        // The weld is the unique contact point of the two circles.
        let junction = SketchEntity.arcPoint(center: c1, radius: r1, angle: 0)
        let contact = c1 + (c2 - c1) / centerDistance * r1
        XCTAssertLessThan(simd_distance(junction, contact), 1e-9,
                          "the welded junction must sit at the circle contact point")
        // The tangent lines coincide there (perpendicular to the centre ray).
        let ray = simd_normalize(contact - c1)
        let t1 = SIMD2<Double>(-ray.y, ray.x)
        let t2 = SIMD2<Double>(ray.y, -ray.x)
        XCTAssertEqual(abs(simd_dot(t1, t2)), 1, accuracy: 1e-12,
                       "contact tangents are the same line")
    }

    /// The review-tightened edit gate must refuse arc edits against a saved
    /// arc-endpoint relation the solver cannot lower (coincident to a whole
    /// CIRCLE), naming the exact constraint — while the executable
    /// counterpart (coincident to an open-spline end) still edits freely.
    func testServiceRefusesGhostArcEndpointRelationsWithExactIDs() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("ghost-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Ghost")
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"G"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        let arcID = UUID()
        let circleID = UUID()
        let splineID = UUID()
        let arc = SketchEntity.arc(id: arcID, center: SIMD2(0, 0), radius: 25,
                                   startAngle: 200 * .pi / 180, endAngle: 340 * .pi / 180)
        let ghost = SketchEntity.circle(id: circleID, center: SIMD2(200, 0), radius: 10)
        let pA = SketchEntity.arcPoint(center: SIMD2(0, 0), radius: 25, angle: 200 * .pi / 180)
        let openSpline = SketchEntity.spline(
            id: splineID, points: [pA, pA + SIMD2(-30, -40)], closed: false)
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"arc","center":[0,0],"radius":25,
               "startAngle":\#(200 * .pi / 180),"endAngle":\#(340 * .pi / 180)},
              {"kind":"circle","center":[200,0],"radius":10},
              {"kind":"spline","points":[[\#(pA.x),\#(pA.y)],[\#(pA.x - 30),\#(pA.y - 40)]],"closed":false}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        // Ghost: arc endpoint welded to a whole circle — the solver has no
        // such lowering.
        let ghostConstraint = SketchConstraint(kind: .coincident, refs: [
            ConstraintRef(entityID: arcID, role: .endpointA),
            ConstraintRef(entityID: circleID, role: .whole)])
        // Control: arc endpoint welded to the open spline end — executable.
        let controlConstraint = SketchConstraint(kind: .coincident, refs: [
            ConstraintRef(entityID: arcID, role: .endpointA),
            ConstraintRef(entityID: splineID, role: .endpointA)])
        document.session.perform(AddSketchConstraintCommand(sketchID: sid, constraint: ghostConstraint))
        document.session.perform(AddSketchConstraintCommand(sketchID: sid, constraint: controlConstraint))

        let service = CADParameterService(document: document)
        let refused = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketchID,
            "entity_id": arcID.uuidString,
            "radius": 40.0,
            "expected_radius": 25.0,
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "dependent_reference", "\(refused)")
        let message = try XCTUnwrap(refused["message"] as? String)
        XCTAssertTrue(message.contains(ghostConstraint.id.uuidString),
                      "refusal must name the ghost constraint: \(message)")
        XCTAssertFalse(message.contains(controlConstraint.id.uuidString),
                       "the executable counterpart must not be blamed: \(message)")
    }

    /// Zero DOF is rank, not satisfaction. Unsupported and nonconverged are
    /// independent report states and neither may produce `isFullyDefined`.
    func testDefinitionReportDoesNotHideFailureStatesBehindZeroDOF() throws {
        let lineID = UUID(), arcID = UUID()
        let line = SketchEntity.line(id: lineID, a: SIMD2(0, 0), b: SIMD2(100, 0))
        let arc = SketchEntity.arc(id: arcID, center: SIMD2(300, 0), radius: 25,
                                   startAngle: 0, endAngle: .pi)
        let unsupported = SketchConstraint(kind: .parallel, refs: [
            ConstraintRef(entityID: lineID, role: .whole),
            ConstraintRef(entityID: arcID, role: .whole)])
        let locks = [lineID, arcID].map {
            SketchConstraint(kind: .fixed, refs: [ConstraintRef(entityID: $0, role: .whole)])
        }
        let unsupportedReport = SketchSolverBridge.definitionReport(
            Sketch(plane: .ground, entities: [line, arc],
                   constraints: [unsupported] + locks, dimensions: []))
        XCTAssertEqual(unsupportedReport.dof, 0)
        XCTAssertTrue(unsupportedReport.converged)
        XCTAssertFalse(unsupportedReport.conflicting)
        XCTAssertEqual(unsupportedReport.unsupportedRelationIDs, [unsupported.id])
        XCTAssertFalse(unsupportedReport.isFullyDefined)

        let wrong = SketchDimension(kind: .distance, refs: [
            ConstraintRef(entityID: lineID, role: .endpointA),
            ConstraintRef(entityID: lineID, role: .endpointB)], value: 90)
        let failedReport = SketchSolverBridge.definitionReport(
            Sketch(plane: .ground, entities: [line], constraints: [
                SketchConstraint(kind: .fixed, refs: [
                    ConstraintRef(entityID: lineID, role: .whole)])], dimensions: [wrong]))
        XCTAssertEqual(failedReport.dof, 0)
        XCTAssertFalse(failedReport.converged)
        XCTAssertTrue(failedReport.conflicting)
        XCTAssertFalse(failedReport.isFullyDefined)
    }

    /// Actual query consumer: conflicting rows name only the real dimensions,
    /// the dropped arc relation is unsupported, and no row claims the sketch
    /// is fully defined merely because its Jacobian has full rank.
    func testConstraintQueryConsumesConflictAndUnsupportedStates() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADCurveReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("query-state-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "QueryState")
        let created = document.executeJSON(Data(#"""
            {"op":"sketch.create","args":{"name":"Q"}}
            """#.utf8))
        XCTAssertTrue(created.isOK)
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: created.payload)) as? [String: Any])?["sketchID"] as? String)
        let added = document.executeJSON(Data(#"""
            {"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":[
              {"kind":"line","a":[0,0],"b":[100,0]},
              {"kind":"arc","center":[300,0],"radius":25,"startAngle":0,"endAngle":3.141592653589793}]}}
            """#.utf8))
        XCTAssertTrue(added.isOK, added.message ?? "")
        let sid = SketchID(raw: UUID(uuidString: sketchID)!)
        let initial = try XCTUnwrap(document.session.document.sketches.first { $0.id == sid })
        let lineID = initial.entities[0].id, arcID = initial.entities[1].id
        let a = ConstraintRef(entityID: lineID, role: .endpointA)
        let b = ConstraintRef(entityID: lineID, role: .endpointB)
        let first = SketchDimension(kind: .distance, refs: [a, b], value: 100)
        let second = SketchDimension(kind: .distance, refs: [a, b], value: 100.05)
        let unsupported = SketchConstraint(kind: .parallel, refs: [
            ConstraintRef(entityID: lineID, role: .whole),
            ConstraintRef(entityID: arcID, role: .whole)])
        document.session.perform(AddSketchConstraintCommand(sketchID: sid, constraint: unsupported))
        document.session.perform(AddSketchDimensionCommand(sketchID: sid, dimension: first))
        document.session.perform(AddSketchDimensionCommand(sketchID: sid, dimension: second))

        let outcome = document.nativeQueryJSON(["scope": "constraints"])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        for id in [first.id, second.id] {
            let row = try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
            XCTAssertEqual(row["relation_state"] as? String, "conflicting")
            XCTAssertEqual(row["sketch_fully_defined"] as? Bool, false)
            XCTAssertTrue(["conflicting", "nonconverged"].contains(
                row["sketch_solver_state"] as? String ?? ""))
        }
        let dropped = try XCTUnwrap(rows.first {
            ($0["id"] as? String) == unsupported.id.uuidString
        })
        XCTAssertEqual(dropped["relation_state"] as? String, "unsupported")
        XCTAssertEqual(dropped["sketch_fully_defined"] as? Bool, false)
        document.close()
    }

    // MARK: - Finding 4: sweep branch continuity

    /// An arc drawn ACROSS the wrap (start 350 deg, end 10 deg, 20 deg
    /// sweep) keeps its branch: the solved sweep stays 20 deg and the end
    /// stays near its drawn position — the complement is NOT silently
    /// chosen. A large edit to a 340 deg sweep lands on the demanded major
    /// arc (closure and tangency intact); a small edit to 25 deg stays on
    /// the same branch.
    func testConnectedArcAngleEditAcrossWrapStaysOnBranch() throws {
        // T=20 deg: end at 350+20 = 10 deg (drawn, trivial solve).
        // T=340 deg: end at (350+340) mod 360 = 330 deg (demanded major arc).
        // T=25 deg: end at 15 deg (small edit, same branch).
        for (targetDeg, expectedEndDeg, toleranceDeg) in
            [(20.0, 10.0, 0.01), (340.0, 330.0, 0.5), (25.0, 15.0, 0.5)] {
            let loop = helper.wrapLoop(scale: 1, startDeg: 350, endDeg: 10,
                                       angleDimensionDeg: targetDeg)
            let outcome = SketchSolverBridge.solveDimensionEdit(
                loop.sketch, dimension: loop.sketch.dimensions[0])
            XCTAssertTrue(outcome.converged, "target \(targetDeg) deg did not converge")
            XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                     SketchSolverBridge.overConstraintTolerance,
                                     "target \(targetDeg) deg conflicts")
            guard case let .arc(_, center, radius, startAngle, endAngle)? =
                outcome.entities.first(where: { $0.id == loop.arcID }) else {
                XCTFail("target \(targetDeg): arc missing"); continue
            }
            XCTAssertGreaterThanOrEqual(startAngle, 0)
            XCTAssertLessThan(startAngle, 2 * .pi, "written start must be normalised")
            XCTAssertEqual(SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle),
                           targetDeg * .pi / 180, accuracy: 1e-6,
                           "target \(targetDeg): solved sweep must equal the demanded sweep")
            let solvedEnd = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
            let expectedEnd = SketchEntity.arcPoint(
                center: loop.center, radius: loop.radius,
                angle: expectedEndDeg * .pi / 180)
            XCTAssertLessThan(simd_distance(solvedEnd, expectedEnd),
                              loop.radius * toleranceDeg * .pi / 180 + 1e-9,
                              "target \(targetDeg): endpoint left its branch")
            // Closure and tangency survive every edit (independent readout).
            let m = try XCTUnwrap(helper.measure(outcome.entities, loop: loop))
            XCTAssertLessThan(m.junctionGapStart, 1e-9)
            XCTAssertLessThan(m.junctionGapEnd, 1e-9)
            XCTAssertLessThan(m.onCircleStart, 1e-6)
            XCTAssertLessThan(m.onCircleEnd, 1e-6)
            XCTAssertLessThan(m.tangentDeviationStart, 1e-2)
            XCTAssertLessThan(m.tangentDeviationEnd, 1e-2)
        }
    }
}
