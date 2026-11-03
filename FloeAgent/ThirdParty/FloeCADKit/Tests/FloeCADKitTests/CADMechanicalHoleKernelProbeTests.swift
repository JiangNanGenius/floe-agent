import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Engine qualification ONLY. No HoleSpec/feature/document format/UI exists
/// here. The tiny r,t polygon adapter feeds the existing OCCT revolve+cut.
@MainActor
final class CADMechanicalHoleKernelProbeTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADHoleKernelProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }
    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private nonisolated enum Cutter: String, CaseIterable {
        case through, blind, counterbore, countersink
        var pilotRadius: Double { self == .through ? 5 : (self == .blind ? 4 : 3) }
        var openingRadius: Double {
            switch self {
            case .through: 5
            case .blind: 4
            case .counterbore: 5.5
            case .countersink: 6
            }
        }
    }
    private struct Setup {
        var target: BRepHandle
        var entry: SIMD3<Double>
        /// Positive t is INSIDE the material, decided explicitly by fixture.
        var inward: SIMD3<Double>
        var radial: SIMD3<Double>
        var across: SIMD3<Double> { simd_cross(inward, radial) }
        var thickness: Double
        var initialVolume: Double
        var projectedBounds: ClosedRange<Double>
        var pilotRadius: Double
    }
    private struct Cut {
        var setup: Setup
        var cutter: BRepHandle
        var result: BRepHandle
        var ancestry: ShapeAncestry
        var removedVolume: Double
        var coneDepth: Double
    }

    private func setup(_ kind: Cutter, transform: Transform3D = .identity,
                       bottomEntry: Bool = false, centre: SIMD2<Double> = SIMD2(50, 30)) throws -> Setup {
        let ground = SketchPlane.ground
        let outer = Profile(loop: [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 60), SIMD2(0, 60)],
                            kind: .polygonal, sourceEntityIDs: [])
        let local = try XCTUnwrap(OCCTKernel.extrudeSolid(outer: outer, holes: [], extras: [],
            zMin: 0, zMax: 10, origin: ground.origin, xAxis: ground.xAxis,
            yAxis: ground.yAxis, normal: ground.normal))
        let target = try XCTUnwrap(OCCTKernel.transformed(local, by: transform))
        // Circle owns centre/radius. Its plane basis is unit/world-mm; target
        // scale changes the placement coordinates, not the drill diameter.
        let plane = SketchPlane(origin: transform.applying(to: SIMD3(0, bottomEntry ? 0 : 10, 0)),
            xAxis: transform.rotation.act(ground.xAxis), yAxis: transform.rotation.act(ground.yAxis))
        let sketch = Sketch(plane: plane, entities: [.circle(id: UUID(), center: centre * transform.scale, radius: kind.pilotRadius)])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        guard case let .circle(point, radius) = profile.kind else { throw ProbeError.notCircle }
        let entry = plane.toWorld(point)
        let inward = simd_normalize(plane.normal) * (bottomEntry ? 1 : -1)
        let radial = simd_normalize(plane.xAxis)
        let localCorners = [0.0, 100.0].flatMap { x in [0.0, 10.0].flatMap { y in
            [-60.0, 0.0].map { z in transform.applying(to: SIMD3(x, y, z)) }
        }}
        let minimum = localCorners.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, $1) }
        let maximum = localCorners.reduce(SIMD3<Double>(repeating: -.infinity)) { simd_max($0, $1) }
        // Conservative WORLD AABB projection, including oblique placements.
        let projected = [minimum.x, maximum.x].flatMap { x in [minimum.y, maximum.y].flatMap { y in
            [minimum.z, maximum.z].map { z in simd_dot(SIMD3(x, y, z) - entry, inward) }
        }}
        let lower = try XCTUnwrap(projected.min())
        let upper = try XCTUnwrap(projected.max())
        let bounds = lower...upper
        XCTAssertLessThanOrEqual(lower, 1e-7)
        XCTAssertGreaterThanOrEqual(upper, 10 * transform.scale - 1e-7)
        let result = Setup(target: target, entry: entry, inward: inward, radial: radial,
            thickness: 10 * transform.scale, initialVolume: 60_000 * pow(transform.scale, 3),
            projectedBounds: bounds, pilotRadius: radius)
        XCTAssertEqual(OCCTKernel.volume(target), result.initialVolume, accuracy: 1e-3)
        return result
    }
    private nonisolated enum ProbeError: Error { case notCircle }

    private func cut(_ kind: Cutter, transform: Transform3D = .identity,
                     bottomEntry: Bool = false, centre: SIMD2<Double> = SIMD2(50, 30),
                     sinkAngle: Double = 90) throws -> Cut {
        let setup = try setup(kind, transform: transform, bottomEntry: bottomEntry, centre: centre)
        let r = setup.pilotRadius, opening = kind.openingRadius
        let lead = 1.0, end = setup.projectedBounds.upperBound + 1
        let coneDepth = (opening - r) / tan(sinkAngle * .pi / 360)
        // Hypothesis to qualify: a face closed along r=0 revolves to one valid
        // solid; slanted line is an analytic cone, never a faceted mesh.
        let points: [SIMD2<Double>]
        let removed: Double
        switch kind {
        case .through:
            let start = setup.projectedBounds.lowerBound - lead
            points = [SIMD2(0, start), SIMD2(r, start), SIMD2(r, end), SIMD2(0, end)]
            removed = .pi * r * r * setup.thickness
        case .blind:
            points = [SIMD2(0, -lead), SIMD2(r, -lead), SIMD2(r, 6), SIMD2(0, 6)]
            removed = .pi * r * r * 6
        case .counterbore:
            points = [SIMD2(0, -lead), SIMD2(opening, -lead), SIMD2(opening, 5),
                      SIMD2(r, 5), SIMD2(r, end), SIMD2(0, end)]
            removed = .pi * r * r * setup.thickness + .pi * (opening * opening - r * r) * 5
        case .countersink:
            points = [SIMD2(0, -lead), SIMD2(opening, -lead), SIMD2(opening, 0),
                      SIMD2(r, coneDepth), SIMD2(r, end), SIMD2(0, end)]
            let frustum = .pi * coneDepth * (opening * opening + opening * r + r * r) / 3
            removed = .pi * r * r * setup.thickness + frustum - .pi * r * r * coneDepth
        }
        XCTAssertGreaterThan(Profile.signedArea(points), 0)
        let axialPlane = SketchPlane(origin: setup.entry, xAxis: setup.radial, yAxis: setup.inward)
        let profile = Profile(loop: points, kind: .polygonal, sourceEntityIDs: [])
        let tool = try XCTUnwrap(OCCTKernel.revolveSolid(outer: profile, holes: [], plane: axialPlane,
            axisOrigin: setup.entry, axisDirection: setup.inward, angleRadians: 2 * .pi), "\(kind) revolve refused")
        try assertHealthy(tool)
        let result = try OCCTKernel.booleanResultWithAncestry(setup.target, tool,
            op: OCCTKernel.booleanOp(.subtract)).get()
        XCTAssertEqual(result.outcome.solidCount, 1)
        try assertHealthy(result.outcome.handle)
        XCTAssertEqual(OCCTKernel.volume(result.outcome.handle), setup.initialVolume - removed, accuracy: 1e-3)
        XCTAssertEqual(OCCTKernel.volume(setup.target), setup.initialVolume, accuracy: 1e-3, "Cut must not modify input")
        return Cut(setup: setup, cutter: tool, result: result.outcome.handle,
                   ancestry: result.ancestry, removedVolume: removed, coneDepth: coneDepth)
    }

    private func assertHealthy(_ shape: BRepHandle, file: StaticString = #filePath, line: UInt = #line) throws {
        let health = OCCTKernel.healthReport(for: shape)
        XCTAssertNil(health.error, file: file, line: line)
        XCTAssertTrue(health.isValid, health.findingsSummary, file: file, line: line)
        XCTAssertEqual(health.counts["solids"], 1, file: file, line: line)
        XCTAssertEqual(health.openFreeWires, 0, file: file, line: line)
        XCTAssertGreaterThan(health.volumeMM3, 0, file: file, line: line)
    }
    private func cylinder(_ cut: Cut, radius: Double, from start: Double, to end: Double,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let faces = OCCTKernel.faceInfo(cut.result).filter {
            guard case let .cylindrical(actual)? = $0.signature?.kind else { return false }
            return abs(actual - radius) < 1e-6
        }
        XCTAssertFalse(faces.isEmpty, "Missing analytic cylinder r=\(radius)", file: file, line: line)
        let area = faces.reduce(0) { $0 + $1.area }
        XCTAssertEqual(area, 2 * .pi * radius * (end - start), accuracy: 1e-4, file: file, line: line)
        guard area > 0 else { return }
        let centroid = faces.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
        let delta = centroid - cut.setup.entry
        let depth = simd_dot(delta, cut.setup.inward)
        XCTAssertEqual(depth, (start + end) / 2, accuracy: 1e-5, file: file, line: line)
        XCTAssertLessThan(simd_length(delta - depth * cut.setup.inward), 1e-5, file: file, line: line)
        for face in faces {
            XCTAssertEqual(abs(simd_dot(simd_normalize(face.normal), cut.setup.inward)), 1,
                           accuracy: 1e-7, file: file, line: line)
        }
    }
    private func floor(_ cut: Cut, depth: Double, area: Double,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let face = try XCTUnwrap(OCCTKernel.faceInfo(cut.result).first {
            $0.signature?.kind == .planar && abs(simd_dot($0.centroid - cut.setup.entry, cut.setup.inward) - depth) < 1e-5
                && simd_dot($0.normal, cut.setup.inward) < -0.999999 && abs($0.area - area) < 1e-4
        }, "Missing correctly oriented blind floor/annular shoulder", file: file, line: line)
        let delta = face.centroid - cut.setup.entry
        XCTAssertLessThan(simd_length(delta - depth * cut.setup.inward), 1e-5, file: file, line: line)
    }
    private func innerSection(_ cut: Cut, at depth: Double, limit: Double) -> [SIMD3<Double>] {
        let curves = OCCTKernel.sectionPolylines(cut.result,
            origin: cut.setup.entry + depth * cut.setup.inward, normal: cut.setup.inward, deflection: 0.005)
        return curves.filter { !$0.isEmpty && $0.allSatisfy { point in
            let delta = point - cut.setup.entry
            return simd_length(delta - simd_dot(delta, cut.setup.inward) * cut.setup.inward) < limit
        }}.flatMap { $0 }
    }
    private func section(_ cut: Cut, at depth: Double, radius: Double, limit: Double = 8,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let points = innerSection(cut, at: depth, limit: limit)
        XCTAssertGreaterThan(points.count, 8, "No circular inner section at t=\(depth)", file: file, line: line)
        for point in points {
            let delta = point - cut.setup.entry
            let along = simd_dot(delta, cut.setup.inward)
            XCTAssertEqual(along, depth, accuracy: 1e-5, file: file, line: line)
            XCTAssertEqual(simd_length(delta - along * cut.setup.inward), radius, accuracy: 1e-4, file: file, line: line)
        }
        let x = points.map { simd_dot($0 - cut.setup.entry, cut.setup.radial) }
        let y = points.map { simd_dot($0 - cut.setup.entry, cut.setup.across) }
        XCTAssertEqual(try XCTUnwrap(x.max()), radius, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(x.min()), -radius, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(y.max()), radius, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(y.min()), -radius, accuracy: 0.03, file: file, line: line)
    }
    private func assertGeometry(_ cut: Cut, _ kind: Cutter,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let r = kind.pilotRadius, thickness = cut.setup.thickness
        switch kind {
        case .through:
            try cylinder(cut, radius: r, from: 0, to: thickness, file: file, line: line)
            try section(cut, at: thickness * 0.2, radius: r, file: file, line: line)
            try section(cut, at: thickness * 0.8, radius: r, file: file, line: line)
        case .blind:
            try cylinder(cut, radius: r, from: 0, to: 6, file: file, line: line)
            try floor(cut, depth: 6, area: .pi * r * r, file: file, line: line)
            try section(cut, at: 3, radius: r, file: file, line: line)
            XCTAssertTrue(innerSection(cut, at: 7, limit: 8).isEmpty, "Blind floor must leave material", file: file, line: line)
        case .counterbore:
            try cylinder(cut, radius: kind.openingRadius, from: 0, to: 5, file: file, line: line)
            try cylinder(cut, radius: r, from: 5, to: thickness, file: file, line: line)
            try floor(cut, depth: 5, area: .pi * (pow(kind.openingRadius, 2) - r * r), file: file, line: line)
            try section(cut, at: 2, radius: kind.openingRadius, file: file, line: line)
            try section(cut, at: 7, radius: r, file: file, line: line)
        case .countersink:
            try cylinder(cut, radius: r, from: cut.coneDepth, to: thickness, file: file, line: line)
            let other = OCCTKernel.faceInfo(cut.result).filter { $0.signature?.kind == .nativeSurface(type: 2) }
            XCTAssertFalse(other.isEmpty, file: file, line: line)
            let area = other.reduce(0) { $0 + $1.area }
            let slant = hypot(kind.openingRadius - r, cut.coneDepth)
            XCTAssertEqual(area, .pi * (kind.openingRadius + r) * slant, accuracy: 1e-4, file: file, line: line)
            if area > 0 {
                let centroid = other.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
                let depth = simd_dot(centroid - cut.setup.entry, cut.setup.inward)
                XCTAssertEqual(depth, cut.coneDepth * (kind.openingRadius + 2 * r) / (3 * (kind.openingRadius + r)),
                               accuracy: 1e-5, file: file, line: line)
            }
            for fraction in [0.25, 0.75] {
                try section(cut, at: cut.coneDepth * fraction,
                    radius: kind.openingRadius + (r - kind.openingRadius) * fraction, file: file, line: line)
            }
            try section(cut, at: (cut.coneDepth + thickness) / 2, radius: r, file: file, line: line)
        }
    }
    private func assertSTEP(_ cut: Cut, _ kind: Cutter, label: String) throws {
        let url = directory.appendingPathComponent("\(label)-\(kind.rawValue).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([cut.result], to: url))
        let bytes = try Data(contentsOf: url)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("CYLINDRICAL_SURFACE"), "Exact cylinder must survive export")
        if kind == .countersink { XCTAssertTrue(text.contains("CONICAL_SURFACE"), "Cone is an analytic STEP surface, not merely other") }
        let restored = try XCTUnwrap(OCCTKernel.readSTEP(from: url).only)
        try assertHealthy(restored)
        XCTAssertEqual(OCCTKernel.volume(restored), cut.setup.initialVolume - cut.removedVolume, accuracy: 1e-3)
        var roundTrip = cut; roundTrip.result = restored
        try assertGeometry(roundTrip, kind)
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
        attachment.name = "\(label)-\(kind.rawValue).step"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testThroughCutterExactVolumeAxisSectionsAndSTEP() async throws {
        let result = try cut(.through)
        XCTAssertEqual(result.removedVolume, 250 * .pi, accuracy: 1e-9)
        try assertGeometry(result, .through)
        try assertSTEP(result, .through, label: "top")
    }
    func testBlindCutterPreservesFlatFloorAndMaterialBeyondDepth() async throws {
        let result = try cut(.blind)
        XCTAssertEqual(result.removedVolume, 96 * .pi, accuracy: 1e-9)
        try assertGeometry(result, .blind)
        try assertSTEP(result, .blind, label: "top")
    }
    func testCounterboreThroughPilotCoaxialCylindersAndOrientedShoulder() async throws {
        let result = try cut(.counterbore)
        XCTAssertEqual(result.removedVolume, 196.25 * .pi, accuracy: 1e-9)
        try assertGeometry(result, .counterbore)
        try assertSTEP(result, .counterbore, label: "top")
    }
    func testCountersinkExactConeSectionsAreaAndSTEPType() async throws {
        let result = try cut(.countersink)
        XCTAssertEqual(result.coneDepth, 3, accuracy: 1e-9)
        XCTAssertEqual(result.removedVolume, 126 * .pi, accuracy: 1e-9)
        try assertGeometry(result, .countersink)
        try assertSTEP(result, .countersink, label: "top")
    }
    func testObliqueRigidTransformPreservesAllFourExactHoleShapesAndLocation() async throws {
        let placement = Transform3D(translation: SIMD3(71.25, -22.5, 13.75),
            rotation: simd_quatd(angle: 0.71, axis: simd_normalize(SIMD3(1, 2, 3))), scale: 1)
        for kind in Cutter.allCases {
            let result = try cut(kind, transform: placement, centre: SIMD2(40, 20))
            XCTAssertLessThan(simd_distance(result.setup.entry, placement.applying(to: SIMD3(40, 10, -20))), 1e-7)
            try assertGeometry(result, kind)
        }
    }
    func testBottomEntryReversesAxisAndOpeningSideForAllFourShapes() async throws {
        for kind in Cutter.allCases {
            let result = try cut(kind, bottomEntry: true)
            XCTAssertEqual(result.setup.entry.y, 0, accuracy: 1e-9)
            XCTAssertEqual(result.setup.inward.y, 1, accuracy: 1e-9)
            try assertGeometry(result, kind)
        }
    }
    func testScaledRotatedTargetKeepsToolDimensionsInWorldMillimetres() async throws {
        let placement = Transform3D(translation: SIMD3(-120, 45, 88),
            rotation: simd_quatd(angle: 0.43, axis: simd_normalize(SIMD3(2, -1, 1))), scale: 1.5)
        for kind in Cutter.allCases {
            let result = try cut(kind, transform: placement)
            XCTAssertEqual(result.setup.thickness, 15, accuracy: 1e-8)
            XCTAssertEqual(result.setup.pilotRadius, kind.pilotRadius, accuracy: 1e-9)
            try assertGeometry(result, kind)
        }
    }
    func testSixtyDegreeIncludedSinkChangesDepthWithoutChangingOpeningDiameters() async throws {
        let result = try cut(.countersink, sinkAngle: 60)
        XCTAssertEqual(result.coneDepth, 3 * sqrt(3), accuracy: 1e-9)
        XCTAssertEqual(result.removedVolume, (90 + 36 * sqrt(3)) * .pi, accuracy: 1e-8)
        try assertGeometry(result, .countersink)
    }
    func testCounterboreCavityFacesHaveActualToolAncestryForFutureNaming() async throws {
        let result = try cut(.counterbore)
        XCTAssertFalse(result.ancestry.rows.isEmpty)
        let cavity = OCCTKernel.faceInfo(result.result).filter {
            if case .cylindrical? = $0.signature?.kind { return true }; return false
        }
        XCTAssertFalse(cavity.isEmpty)
        XCTAssertTrue(cavity.contains { face in
            result.ancestry.ancestors(ofResultFace: face.index).contains { $0.inputOrdinal == 1 && $0.inputKind == .face }
        }, "Geometry alone is insufficient for later stable hole-face naming")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
