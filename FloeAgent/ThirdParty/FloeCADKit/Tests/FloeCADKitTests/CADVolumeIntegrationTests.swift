import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Real pinned OCCT exact-geometry integration regressions. The existing
/// public health report remains part of each case; no mesh-volume golden,
/// relaxed tolerance or timing fallback substitutes for a result.
@MainActor
final class CADVolumeIntegrationTests: XCTestCase {
    private let oblique = Transform3D(translation: SIMD3(71.25, -22.5, 13.75),
        rotation: simd_quatd(angle: 0.71, axis: simd_normalize(SIMD3(1, 2, 3))), scale: 1)

    private func assertMass(_ shape: BRepHandle, expected: Double, route: String,
                            label: String, accuracy: Double = 1e-3,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        // The existing sampled hang is inside this actual public health call,
        // before a boolean. Do not substitute a weaker/synthetic checker.
        let started = ContinuousClock.now
        let raw = OCCTKernel.healthReportDictionary(for: shape, runBOPCheck: false)
        let duration = started.duration(to: .now)
        let health = ShapeHealth(dictionary: raw)
        XCTAssertNil(health.error, file: file, line: line)
        XCTAssertTrue(health.isValid, health.findingsSummary, file: file, line: line)
        XCTAssertEqual(health.counts["solids"], 1, file: file, line: line)
        XCTAssertEqual(health.openFreeWires, 0, file: file, line: line)
        XCTAssertEqual(raw["volumeIntegration"] as? String, route, file: file, line: line)
        XCTAssertEqual(health.volumeMM3, expected, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(shape), expected, accuracy: accuracy, file: file, line: line)
        let attachment = XCTAttachment(string: "\(label): health duration=\(duration), route=\(raw["volumeIntegration"] ?? "missing"), volume=\(health.volumeMM3), expected=\(expected)")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func revolvedTool(cone: Bool, placement: Transform3D) throws -> BRepHandle {
        let r = 3.0, h = 7.0
        let points: [SIMD2<Double>] = cone ? [.zero, SIMD2(r, 0), SIMD2(0, h)]
            : [.zero, SIMD2(r, 0), SIMD2(r, h), SIMD2(0, h)]
        let plane = SketchPlane(origin: placement.translation,
            xAxis: placement.rotation.act(SIMD3(1, 0, 0)),
            yAxis: placement.rotation.act(SIMD3(0, 1, 0)))
        return try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: Profile(loop: points, kind: .polygonal, sourceEntityIDs: []), holes: [], plane: plane,
            axisOrigin: placement.translation, axisDirection: plane.yAxis, angleRadians: 2 * .pi))
    }

    func testRotatedAndScaledAnalyticPrimitivesKeepExactGeometryMassAndHealth() async throws {
        let cases: [(PrimitiveSpec, Double)] = [
            (.box(width: 40, depth: 20, height: 10), 8000),
            (.cylinder(radius: 3, height: 7), .pi * 9 * 7),
            (.sphere(radius: 5), 4 * .pi * 125 / 3)
        ]
        for scale in [1.0, 1.5] {
            var placement = oblique; placement.scale = scale
            for (spec, expected) in cases {
                let shape = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: placement))
                try assertMass(shape, expected: expected * pow(scale, 3), route: "occt-adaptive-gauss",
                               label: "rotated primitive \(spec) scale\(scale)")
            }
        }
    }

    func testDirectObliqueConeAndCylinderRevolvesDoNotEnterNestedKronrod() async throws {
        for cone in [false, true] {
            let expected = Double.pi * 9 * 7 / (cone ? 3 : 1)
            let direct = try revolvedTool(cone: cone, placement: oblique)
            try assertMass(direct, expected: expected, route: "occt-adaptive-gauss", label: "direct oblique cone=\(cone)")
            let baseline = try revolvedTool(cone: cone, placement: .identity)
            let transformed = try XCTUnwrap(OCCTKernel.transformed(baseline, by: oblique))
            try assertMass(transformed, expected: expected, route: "occt-adaptive-gauss", label: "transformed cone=\(cone)")
        }
    }

    func testObliqueTorusMatchesClosedFormOnExactSurfaceRoute() async throws {
        let major = 8.0, minor = 2.0
        let centre = SIMD2(major, 0.0)
        let loop = (0..<48).map { index in
            let angle = Double(index) * 2 * .pi / 48
            return centre + SIMD2(cos(angle), sin(angle)) * minor
        }
        let profile = Profile(loop: loop, kind: .circle(center: centre, radius: minor), sourceEntityIDs: [])
        let plane = SketchPlane(origin: oblique.translation,
            xAxis: oblique.rotation.act(SIMD3(1, 0, 0)), yAxis: oblique.rotation.act(SIMD3(0, 1, 0)))
        let torus = try XCTUnwrap(OCCTKernel.revolveSolid(outer: profile, holes: [], plane: plane,
            axisOrigin: plane.origin, axisDirection: plane.yAxis, angleRadians: 2 * .pi))
        try assertMass(torus, expected: 2 * .pi * .pi * major * minor * minor,
                       route: "occt-adaptive-gauss", label: "oblique analytic torus")
    }

    func testObliqueAndScaledExactBooleanHoleRetainsMassHealthAndInput() async throws {
        let target = try XCTUnwrap(OCCTKernel.extrudeShape(
            outerLoop: [.zero, SIMD2(40, 0), SIMD2(40, 20), SIMD2(0, 20)], holes: [], zMin: 0, zMax: 10,
            origin: .zero, xAxis: SketchPlane.ground.xAxis, yAxis: SketchPlane.ground.yAxis,
            normal: SketchPlane.ground.normal))
        for scale in [1.0, 1.5] {
            var placement = oblique; placement.scale = scale
            let input = try XCTUnwrap(OCCTKernel.transformed(target, by: placement))
            let origin = placement.applying(to: SIMD3(20, 0, -10))
            let plane = SketchPlane(origin: origin, xAxis: placement.rotation.act(SIMD3(1, 0, 0)),
                                     yAxis: placement.rotation.act(SIMD3(0, 1, 0)))
            let depth = 10 * scale
            let cutter = try XCTUnwrap(OCCTKernel.revolveSolid(outer: Profile(
                loop: [SIMD2(0, -2), SIMD2(3, -2), SIMD2(3, depth + 2), SIMD2(0, depth + 2)],
                kind: .polygonal, sourceEntityIDs: []), holes: [], plane: plane,
                axisOrigin: origin, axisDirection: plane.yAxis, angleRadians: 2 * .pi))
            try assertMass(cutter, expected: .pi * 9 * (depth + 4), route: "occt-adaptive-gauss", label: "actual cutter health")
            let cut = try OCCTKernel.booleanResultWithAncestry(input, cutter, op: OCCTKernel.booleanOp(.subtract)).get()
            XCTAssertEqual(cut.outcome.solidCount, 1)
            try assertMass(cut.outcome.handle, expected: 8000 * pow(scale, 3) - .pi * 9 * depth,
                           route: "occt-adaptive-gauss", label: "rotated cut scale\(scale)")
            try assertMass(input, expected: 8000 * pow(scale, 3), route: "occt-adaptive-gauss", label: "unmodified input")
        }
    }

    private let controls: [SIMD2<Double>] = [
        SIMD2(0, 0), SIMD2(50, 0), SIMD2(45, 10), SIMD2(30, 17), SIMD2(0, 12)
    ]
    private func spline(_ points: [SIMD2<Double>]) throws -> BRepHandle {
        let entity = UUID()
        let sketch = Sketch(plane: .ground, entities: [.spline(id: entity, points: points, closed: true)])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        XCTAssertFalse(profile.segments.isEmpty)
        return try XCTUnwrap(OCCTKernel.extrudeSolid(outer: profile, holes: [], extras: [], zMin: 0, zMax: 7,
            origin: .zero, xAxis: SketchPlane.ground.xAxis, yAxis: SketchPlane.ground.yAxis,
            normal: SketchPlane.ground.normal))
    }

    func testClosedSplineCyclicParameterizationsKeepOriginalSpanPrecision() async throws {
        // Reuse the project's EXISTING exact polynomial span-area helper;
        // do not add a new integrator or tessellated golden.
        // Historical upstream pins require relative1e-6. Check the stronger
        // configured GK relative1e-7, not a scale-independent absolute1e-6.
        let area = abs(CatmullRomBezier.signedArea(CatmullRomBezier.spans(controls, closed: true)))
        for offset in controls.indices {
            let sameCurve = Array(controls[offset...]) + Array(controls[..<offset])
            let sameArea = abs(CatmullRomBezier.signedArea(CatmullRomBezier.spans(sameCurve, closed: true)))
            XCTAssertEqual(sameArea, area, accuracy: 1e-9)
            try assertMass(spline(sameCurve), expected: area * 7, route: "occt-kronrod-spans",
                           label: "closed spline start\(offset)", accuracy: abs(area * 7) * 1e-7)
        }
    }

    func testObliqueSplineRemainsSpanPrecisionPathWithoutAnalyticMisclassification() async throws {
        // Deliberately not hidden by the analytic repair. If this old GK path
        // is also pathological, preserve/report it as a remaining issue rather
        // than switching splines to a less accurate rule or timing fallback.
        let area = abs(CatmullRomBezier.signedArea(CatmullRomBezier.spans(controls, closed: true)))
        let rotated = try XCTUnwrap(OCCTKernel.transformed(spline(controls), by: oblique))
        try assertMass(rotated, expected: area * 7, route: "occt-kronrod-spans", label: "oblique spline", accuracy: abs(area * 7) * 1e-7)
    }
}
