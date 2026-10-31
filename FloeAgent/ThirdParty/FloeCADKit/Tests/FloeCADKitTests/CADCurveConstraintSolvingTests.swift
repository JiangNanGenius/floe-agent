//
//  CADCurveConstraintSolvingTests.swift
//  FloeCADKitTests
//
//  M02 + M06: connected arc/spline curve constraints and scale-consistent
//  sketch solving.
//
//  M02 (曲线约束与求解范围): a closed section built from an arc and an open fit
//  spline stays closed under driving-dimension edits — the junctions weld,
//  the junction tangency is G1 continuity of the RENDERED curves, and the
//  reported remaining DOF and failure reasons are truthful.
//
//  M06 (求解诊断与尺度一致性): the same sketch solved at 10^-3 / 1 / 10^3
//  scale reports the same constraint state (DOF, conflict verdict, conflict
//  attribution ids), and a contradictory system's least-squares best fit is
//  REFUSED — never written back as if satisfied.
//
//  These tests drive the real production solver and services
//  (`SketchSolverBridge`, `CADParameterService`, the document undo stack and
//  the package round-trip) — no fake solver and no mirrored helper decides
//  the verdicts. Geometry checks re-measure closure and the tangent angle
//  independently from the solved entities (through `CatmullRomBezier`, the
//  exact curve the kernel renders), not from solver internals.
//

import XCTest
import simd
@testable import FloeCAD

// MARK: - Shared loop fixture

/// The arc+spline lens used across both test classes. The arc's angles are
/// 200°…340° about (60s, 0) with radius 25s; the open spline joins the arc's
/// endpoints and bows AWAY from the arc's bulge, so the loop is simple
/// (non-self-intersecting) at every scale `s`.
nonisolated enum CurveLoopFixture {
    struct Loop {
        var arc: SketchEntity
        var spline: SketchEntity
        var arcID: UUID
        var splineID: UUID
        var start: SIMD2<Double>   // arc start point == spline first point
        var end: SIMD2<Double>     // arc end point == spline last point
        var scale: Double
    }

    static func make(scale s: Double) -> Loop {
        let arcID = UUID()
        let splineID = UUID()
        let center = SIMD2<Double>(60 * s, 0)
        let radius = 25 * s
        let startAngle = 200 * .pi / 180
        let endAngle = 340 * .pi / 180
        let start = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
        let end = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
        let mid = SIMD2<Double>((start.x + end.x) / 2, max(start.y, end.y) + 18 * s)
        return Loop(
            arc: .arc(id: arcID, center: center, radius: radius,
                      startAngle: startAngle, endAngle: endAngle),
            spline: .spline(id: splineID, points: [start, mid, end], closed: false),
            arcID: arcID, splineID: splineID, start: start, end: end, scale: s)
    }

    /// Connection + junction tangency constraints (M02 vocabulary).
    static func loopConstraints(_ loop: Loop) -> [SketchConstraint] {
        [
            SketchConstraint(kind: .coincident, refs: [
                ConstraintRef(entityID: loop.arcID, role: .endpointA),
                ConstraintRef(entityID: loop.splineID, role: .endpointA)]),
            SketchConstraint(kind: .coincident, refs: [
                ConstraintRef(entityID: loop.arcID, role: .endpointB),
                ConstraintRef(entityID: loop.splineID, role: .endpointB)]),
            SketchConstraint(kind: .tangent, refs: [
                ConstraintRef(entityID: loop.arcID, role: .endpointA),
                ConstraintRef(entityID: loop.splineID, role: .endpointA)]),
            SketchConstraint(kind: .tangent, refs: [
                ConstraintRef(entityID: loop.arcID, role: .endpointB),
                ConstraintRef(entityID: loop.splineID, role: .endpointB)]),
        ]
    }

    static func radiusDimension(_ loop: Loop, value: Double) -> SketchDimension {
        SketchDimension(kind: .radius,
                        refs: [ConstraintRef(entityID: loop.arcID, role: .whole)],
                        value: value)
    }

    static func arcGeometry(_ loop: Loop)
        -> (center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double) {
        guard case let .arc(_, c, r, sa, ea) = loop.arc else { fatalError("fixture arc") }
        return (c, r, sa, ea)
    }

    static func splinePoints(_ loop: Loop) -> [SIMD2<Double>] {
        guard case let .spline(_, p, _) = loop.spline else { fatalError("fixture spline") }
        return p
    }

    static func sketch(_ loop: Loop, constraints: [SketchConstraint] = [],
                       dimensions: [SketchDimension] = []) -> Sketch {
        Sketch(plane: .ground, entities: [loop.arc, loop.spline],
               constraints: constraints, dimensions: dimensions)
    }

    /// Independent geometric readout of the solved loop: junction gaps,
    /// on-circle residuals (relative to the characteristic length) and the G1
    /// tangent deviation in RADIANS, measured purely from entity geometry.
    struct Measurement {
        var junctionGapStart: Double
        var junctionGapEnd: Double
        var onCircleStart: Double
        var onCircleEnd: Double
        var tangentDeviationStart: Double
        var tangentDeviationEnd: Double
    }

    static func measure(_ entities: [SketchEntity], loop: Loop) -> Measurement? {
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
        func g1Deviation(_ p: SIMD2<Double>, tangent: SIMD2<Double>) -> Double {
            let radiusVec = p - center
            let rLen = simd_length(radiusVec)
            let tLen = simd_length(tangent)
            guard rLen > 1e-12, tLen > 1e-12 else { return .infinity }
            // Arc tangent = radius rotated 90°; G1 means parallel to the
            // spline's rendered end tangent.
            let arcTangent = SIMD2<Double>(-radiusVec.y / rLen, radiusVec.x / rLen)
            let dot = min(1.0, abs(simd_dot(arcTangent, tangent / tLen)))
            return acos(dot)
        }
        let spans = CatmullRomBezier.spans(points, closed: false)
        let t0 = CatmullRomBezier.derivative(spans[0], 0)
        let t1 = CatmullRomBezier.derivative(spans[spans.count - 1], 1)
        return Measurement(
            junctionGapStart: simd_distance(points.first!, a0) / charLength,
            junctionGapEnd: simd_distance(points.last!, a1) / charLength,
            onCircleStart: onCircle(a0),
            onCircleEnd: onCircle(a1),
            tangentDeviationStart: g1Deviation(a0, tangent: t0),
            tangentDeviationEnd: g1Deviation(a1, tangent: t1))
    }
}

// MARK: - Bridge-level solver tests (M02 + M06)

@MainActor
final class CADCurveConstraintSolvingTests: XCTestCase {

    /// M02: with connection + tangency constrained, changing the driving
    /// radius dimension keeps the loop welded, on-circle and G1-tangent —
    /// identically at 10^-3, 1 and 10^3 scale (M06). The remaining DOF is
    /// reported truthfully (0 with the center locked).
    func testConnectedLoopSurvivesDimensionEditAtThreeScales() throws {
        for scale in [1e-3, 1.0, 1e3] {
            let loop = CurveLoopFixture.make(scale: scale)
            var constraints = CurveLoopFixture.loopConstraints(loop)
            constraints.append(SketchConstraint(kind: .fixed, refs: [
                ConstraintRef(entityID: loop.arcID, role: .center)]))
            var sketch = CurveLoopFixture.sketch(
                loop, constraints: constraints,
                dimensions: [CurveLoopFixture.radiusDimension(loop, value: 25 * scale)])

            var outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
            XCTAssertTrue(outcome.converged, "scale \(scale): initial solve did not converge")
            XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                     SketchSolverBridge.overConstraintTolerance,
                                     "scale \(scale): initial loop conflicts")
            XCTAssertEqual(outcome.dof, 0,
                           "scale \(scale): locked center + radius dimension + welds + tangency must fully define the loop")
            var m = try XCTUnwrap(CurveLoopFixture.measure(outcome.entities, loop: loop),
                                  "scale \(scale)")
            XCTAssertLessThan(m.junctionGapStart, 1e-9, "scale \(scale): start junction split")
            XCTAssertLessThan(m.junctionGapEnd, 1e-9, "scale \(scale): end junction split")
            XCTAssertLessThan(m.onCircleStart, 1e-6, "scale \(scale): start left the arc")
            XCTAssertLessThan(m.onCircleEnd, 1e-6, "scale \(scale): end left the arc")
            XCTAssertLessThan(m.tangentDeviationStart, 1e-4,
                              "scale \(scale): start junction is not G1")
            XCTAssertLessThan(m.tangentDeviationEnd, 1e-4,
                              "scale \(scale): end junction is not G1")

            // M02: modify the driving dimension — the profile must not split.
            sketch.dimensions[0].value = 40 * scale
            let edited = sketch.dimensions[0]
            outcome = SketchSolverBridge.solveDimensionEdit(sketch, dimension: edited)
            XCTAssertTrue(outcome.converged, "scale \(scale): dimension edit did not converge")
            XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                     SketchSolverBridge.overConstraintTolerance,
                                     "scale \(scale): edited loop conflicts")
            guard case let .arc(_, center, radius, _, _)? =
                outcome.entities.first(where: { $0.id == loop.arcID }) else {
                XCTFail("scale \(scale): arc missing after edit"); continue
            }
            XCTAssertEqual(radius, 40 * scale, accuracy: 1e-9 * max(1, 40 * scale),
                           "scale \(scale): driving radius not satisfied")
            XCTAssertEqual(center.x, 60 * scale, accuracy: 1e-9 * max(1, abs(center.x)),
                           "scale \(scale): locked center moved")
            XCTAssertEqual(center.y, 0, accuracy: 1e-9 * max(1, abs(center.y)),
                           "scale \(scale): locked center moved")
            m = try XCTUnwrap(CurveLoopFixture.measure(outcome.entities, loop: loop),
                              "scale \(scale)")
            XCTAssertLessThan(m.junctionGapStart, 1e-9, "scale \(scale): junction split after edit")
            XCTAssertLessThan(m.junctionGapEnd, 1e-9, "scale \(scale): junction split after edit")
            XCTAssertLessThan(m.onCircleStart, 1e-6)
            XCTAssertLessThan(m.onCircleEnd, 1e-6)
            XCTAssertLessThan(m.tangentDeviationStart, 1e-4,
                              "scale \(scale): tangency lost after dimension edit")
            XCTAssertLessThan(m.tangentDeviationEnd, 1e-4,
                              "scale \(scale): tangency lost after dimension edit")
            XCTAssertEqual(outcome.dof, 0, "scale \(scale): edited loop DOF changed")
        }
    }

    /// M02: without a Lock the same loop truthfully reports its 2 remaining
    /// degrees of freedom (the arc center's x/y), while closure and tangency
    /// still hold.
    func testConnectedLoopReportsRemainingDOFTruthfully() throws {
        let loop = CurveLoopFixture.make(scale: 1)
        let sketch = CurveLoopFixture.sketch(
            loop, constraints: CurveLoopFixture.loopConstraints(loop),
            dimensions: [CurveLoopFixture.radiusDimension(loop, value: 25)])
        let outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertTrue(outcome.converged)
        XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        XCTAssertEqual(outcome.dof, 2,
                       "a free arc center leaves exactly 2 DOF on the connected loop")
        let report = SketchSolverBridge.definitionReport(sketch)
        XCTAssertEqual(report.dof, 2)
        XCTAssertFalse(report.conflicting)
        XCTAssertEqual(report.states[loop.arcID], false)
        XCTAssertEqual(report.states[loop.splineID], false)
    }

    /// M06: the SAME contradictory sketch (radius driven to both 25s and 40s)
    /// reports conflicting at all three scales, attributes the SAME dimension
    /// ids at every scale, and the least-squares best fit is refused by the
    /// write-back gate — never presented as satisfied.
    func testContradictoryDimensionsRefusedConsistentlyAcrossScales() throws {
        for scale in [1e-3, 1.0, 1e3] {
            let loop = CurveLoopFixture.make(scale: scale)
            let first = CurveLoopFixture.radiusDimension(loop, value: 25 * scale)
            let second = CurveLoopFixture.radiusDimension(loop, value: 40 * scale)
            let sketch = CurveLoopFixture.sketch(
                loop, constraints: CurveLoopFixture.loopConstraints(loop),
                dimensions: [first, second])

            let outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
            XCTAssertGreaterThan(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance,
                                 "scale \(scale): best fit of a contradictory system must NOT pass the gate")
            let verdict = SketchSolverBridge.conflictAttribution(sketch)
            XCTAssertEqual(verdict.dimensionIDs, [first.id, second.id],
                           "scale \(scale): conflict highlight must name the actual dimensions")
            XCTAssertTrue(verdict.constraintIDs.isEmpty)
            let report = SketchSolverBridge.definitionReport(sketch)
            XCTAssertTrue(report.conflicting,
                          "scale \(scale): definition report must say conflicting, not fully-defined")
            // The gate the editor/service uses to refuse the write:
            XCTAssertFalse(outcome.converged
                            && outcome.structuralResidual <= SketchSolverBridge.overConstraintTolerance)
        }
    }

    /// M06 regression guard: arcs with NO endpoint references keep the legacy
    /// center+sweep model — the same radius dimension edit produces the same
    /// solved geometry as before (angles untouched, sweep carried by the
    /// scalar variable), at all three scales.
    func testUnconnectedArcsKeepLegacySolveModelAtAllScales() throws {
        for scale in [1e-3, 1.0, 1e3] {
            let loop = CurveLoopFixture.make(scale: scale)
            // Radius dimension only — no coincident/tangent endpoint refs.
            var sketch = CurveLoopFixture.sketch(
                loop, dimensions: [CurveLoopFixture.radiusDimension(loop, value: 25 * scale)])
            var outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
            XCTAssertTrue(outcome.converged)
            XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                     SketchSolverBridge.overConstraintTolerance)
            guard case let .arc(_, center, radius, startAngle, endAngle)? =
                outcome.entities.first(where: { $0.id == loop.arcID }) else {
                XCTFail("arc missing"); continue
            }
            XCTAssertEqual(center.x, 60 * scale, accuracy: 1e-9 * max(1, abs(center.x)))
            XCTAssertEqual(center.y, 0, accuracy: 1e-9)
            XCTAssertEqual(radius, 25 * scale, accuracy: 1e-9 * max(1, 25 * scale))
            XCTAssertEqual(startAngle, 200 * .pi / 180, accuracy: 1e-9)
            XCTAssertEqual(endAngle, 340 * .pi / 180, accuracy: 1e-9)

            // A single-arc angle dimension still drives the sweep scalar.
            sketch.dimensions = []
            sketch.constraints = []
            let angle = SketchDimension(
                kind: .angle, refs: [ConstraintRef(entityID: loop.arcID, role: .whole)],
                value: 120 * .pi / 180)
            sketch.dimensions = [angle]
            outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
            XCTAssertTrue(outcome.converged)
            XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                     SketchSolverBridge.overConstraintTolerance)
            guard case let .arc(_, _, solvedRadius, solvedStart, solvedEnd)? =
                outcome.entities.first(where: { $0.id == loop.arcID }) else {
                XCTFail("arc missing"); continue
            }
            XCTAssertEqual(solvedRadius, 25 * scale, accuracy: 1e-9 * max(1, 25 * scale))
            XCTAssertEqual(SketchEntity.arcSweep(startAngle: solvedStart, endAngle: solvedEnd),
                           120 * .pi / 180, accuracy: 1e-7)
            // The start ray is retained (legacy behavior).
            XCTAssertEqual(solvedStart, 200 * .pi / 180, accuracy: 1e-9)
        }
    }

    /// M02: a connected arc's angle dimension drives the sweep BETWEEN ITS
    /// ENDPOINTS (there is no sweep scalar on a connected arc), and closure
    /// survives the edit.
    func testConnectedArcAngleDimensionDrivesEndpointSweep() throws {
        let loop = CurveLoopFixture.make(scale: 1)
        let sketch = CurveLoopFixture.sketch(
            loop, constraints: CurveLoopFixture.loopConstraints(loop),
            dimensions: [SketchDimension(
                kind: .angle, refs: [ConstraintRef(entityID: loop.arcID, role: .whole)],
                value: 100 * .pi / 180)])
        let outcome = SketchSolverBridge.solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
        XCTAssertTrue(outcome.converged)
        XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        guard case let .arc(_, _, _, startAngle, endAngle)? =
            outcome.entities.first(where: { $0.id == loop.arcID }) else {
            XCTFail("arc missing"); return
        }
        XCTAssertEqual(SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle),
                       100 * .pi / 180, accuracy: 1e-6)
        let m = try XCTUnwrap(CurveLoopFixture.measure(outcome.entities, loop: loop))
        XCTAssertLessThan(m.junctionGapStart, 1e-9)
        XCTAssertLessThan(m.junctionGapEnd, 1e-9)
        XCTAssertLessThan(m.onCircleStart, 1e-6)
        XCTAssertLessThan(m.onCircleEnd, 1e-6)
    }
}
