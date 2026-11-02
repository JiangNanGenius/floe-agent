import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Custom NORMAL-section 60-degree ridge, NOT ISO M8 geometry/fit/runout.
/// Fixtures call only the pinned native OCCT helix/sweep/boolean wrappers.
@MainActor
final class CADThreadEngineProbeTests: XCTestCase {
    private struct Fixture {
        let pitch: Double
        let length: Double
        let hand: Double
        let helix: HelixSpec
        let tool: BRepHandle
        let clipped: BRepHandle
        let core: BRepHandle
        let blank: BRepHandle
        let sectionArea: Double
    }
    private let majorRadius = 4.0
    private let rootRadius = 3.5
    private let overlap = 0.1

    private func note(_ message: String) {
        let attachment = XCTAttachment(string: message)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func healthy(_ shape: BRepHandle, label: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let start = ContinuousClock.now
        let h = OCCTKernel.healthReport(for: shape)
        XCTAssertNil(h.error, file: file, line: line)
        XCTAssertTrue(h.isValid, "\(label): \(h.findingsSummary)", file: file, line: line)
        XCTAssertEqual(h.counts["solids"], 1, file: file, line: line)
        XCTAssertEqual(h.openFreeWires, 0, file: file, line: line)
        XCTAssertGreaterThan(h.volumeMM3, 0, file: file, line: line)
        XCTAssertTrue(h.volumeMM3.isFinite, file: file, line: line)
        XCTAssertLessThan(h.counts["faces"] ?? Int.max, 500, "bounded fixture topology", file: file, line: line)
        XCTAssertEqual(h.volumeMM3, OCCTKernel.volume(shape), accuracy: 1e-3, file: file, line: line)
        XCTAssertFalse(try XCTUnwrap(OCCTKernel.serialize(shape), file: file, line: line).isEmpty,
                       file: file, line: line)
        note("\(label): health=\(start.duration(to: .now)), volume=\(h.volumeMM3), counts=\(h.counts)")
        return h.volumeMM3
    }

    private func cylinder(radius: Double, length: Double, bore: Double? = nil) throws -> BRepHandle {
        func circle(_ r: Double) -> Profile {
            let loop = (0..<64).map { i -> SIMD2<Double> in
                let a = 2 * Double.pi * Double(i) / 64
                return SIMD2(r * cos(a), r * sin(a))
            }
            return Profile(loop: loop, kind: .circle(center: .zero, radius: r), sourceEntityIDs: [])
        }
        let plane = SketchPlane.ground
        return try XCTUnwrap(OCCTKernel.extrudeSolid(outer: circle(radius),
            holes: bore.map { [circle($0)] } ?? [], extras: [], zMin: 0, zMax: length,
            origin: plane.origin, xAxis: plane.xAxis, yAxis: plane.yAxis, normal: plane.normal))
    }

    private func boolean(_ a: BRepHandle, _ b: BRepHandle, _ op: BooleanKind,
                         label: String) throws -> BRepHandle {
        let aBefore = try XCTUnwrap(OCCTKernel.serialize(a))
        let bBefore = try XCTUnwrap(OCCTKernel.serialize(b))
        let start = ContinuousClock.now
        let result = OCCTKernel.booleanResult(a, b, op: OCCTKernel.booleanOp(op))
        switch result {
        case .failure(let error):
            note("REFUSED \(label): \(error); elapsed=\(start.duration(to: .now))")
            // Refusal is retained as evidence, NEVER counted as thread success.
            XCTAssertEqual(OCCTKernel.serialize(a), aBefore)
            XCTAssertEqual(OCCTKernel.serialize(b), bBefore)
            throw error
        case .success(let outcome):
            note("\(label): boolean=\(start.duration(to: .now)), solids=\(outcome.solidCount)")
            XCTAssertEqual(outcome.solidCount, 1)
            XCTAssertEqual(OCCTKernel.serialize(a), aBefore, "boolean must preserve target exact input")
            XCTAssertEqual(OCCTKernel.serialize(b), bBefore, "boolean must preserve tool exact input")
            _ = try healthy(outcome.handle, label: label)
            return outcome.handle
        }
    }

    private func fixture(pitch: Double = 1.25, length: Double = 10, hand: Double = 1) throws -> Fixture {
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
        let height = majorRadius - rootRadius + overlap
        let halfWidth = height * tan(Double.pi / 6)
        // Apex angle is exactly60deg in the plane NORMAL to the helix.
        // It is intentionally not a claim about a standard axial tooth angle.
        let points = [SIMD2(-overlap, -halfWidth), SIMD2(height - overlap, 0), SIMD2(-overlap, halfWidth)]
        let apex = points[1]
        let a = simd_normalize(points[0] - apex), b = simd_normalize(points[2] - apex)
        XCTAssertEqual(acos(simd_dot(a, b)), Double.pi / 3, accuracy: 1e-12)
        let area = abs(Profile.signedArea(points))
        XCTAssertEqual(area, height * halfWidth, accuracy: 1e-12)
        XCTAssertLessThan(2 * halfWidth, pitch, "non-overlapping turns required by this fixture")
        // One pitch lead/overrun at either end, then exact flat-end clipping.
        // Negative pitch descends from the TOP; no material-side inference.
        let yStart = hand > 0 ? -pitch : length + pitch
        let helix = HelixSpec(axisPoint: SIMD3(0, yStart, 0), axisDirection: SIMD3(0, 1, 0),
            referenceDirection: SIMD3(1, 0, 0), radius: rootRadius,
            pitch: hand * pitch, turns: (length + 2 * pitch) / pitch, startAngle: 0)
        let tangent = simd_normalize(SIMD3(0, hand * pitch / (2 * .pi), -rootRadius))
        let radial = SIMD3<Double>(1, 0, 0)
        let binormal = simd_normalize(simd_cross(tangent, radial))
        let plane = SketchPlane(origin: SIMD3(rootRadius, yStart, 0), xAxis: radial, yAxis: binormal)
        XCTAssertEqual(abs(simd_dot(plane.normal, tangent)), 1, accuracy: 1e-12)
        let start = ContinuousClock.now
        let tool = try XCTUnwrap(OCCTKernel.sweepSolid(
            outer: Profile(loop: points, kind: .polygonal, sourceEntityIDs: []), holes: [], plane: plane,
            spine: helix.sampledSpine(perTurn: 16), helix: helix), "native exact helix sweep refused")
        note("sweep hand=\(hand) pitch=\(pitch) length=\(length): \(start.duration(to: .now))")
        let toolVolume = try healthy(tool, label: "untrimmed helical ridge")
        // Curvature Jacobian gives an independent conservative mass bound for
        // this normal section; do not fit an expected volume to OCCT output.
        let curvature = rootRadius / (rootRadius * rootRadius + pow(pitch / (2 * .pi), 2))
        let sweptLength = helix.turns * hypot(2 * .pi * rootRadius, pitch)
        XCTAssertGreaterThan(toolVolume, area * sweptLength * (1 - curvature * overlap) - 1e-3)
        XCTAssertLessThan(toolVolume, area * sweptLength * (1 + curvature * (height - overlap)) + 1e-3)
        let envelope = try cylinder(radius: majorRadius + 0.25, length: length)
        let clipped = try boolean(tool, envelope, .intersect, label: "flat-end trim")
        let core = try cylinder(radius: rootRadius, length: length)
        let blank = try cylinder(radius: 6, length: length, bore: rootRadius)
        XCTAssertEqual(OCCTKernel.volume(core), .pi * rootRadius * rootRadius * length, accuracy: 1e-3)
        XCTAssertEqual(OCCTKernel.volume(blank), .pi * (36 - rootRadius * rootRadius) * length, accuracy: 1e-3)
        return Fixture(pitch: pitch, length: length, hand: hand, helix: helix,
            tool: tool, clipped: clipped, core: core, blank: blank, sectionArea: area)
    }

    private func crestEvidence(_ shape: BRepHandle, fixture f: Fixture,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        // Check exact-kernel sections at two azimuths, against independently
        // calculated world crest locations. This observes returned geometry,
        // not HelixSpec.point()/sampledSpine or render triangle ordering.
        for theta in [Double.pi / 2, Double.pi] {
            let radial = SIMD3(cos(theta), 0, -sin(theta))
            let planeNormal = SIMD3(-sin(theta), 0, -cos(theta))
            let points = OCCTKernel.sectionPolylines(shape, origin: .zero, normal: planeNormal,
                                                     deflection: 0.002).flatMap { $0 }
            XCTAssertFalse(points.isEmpty, file: file, line: line)
            var expectedYs: [Double] = []
            for turn in 0..<Int(ceil(f.helix.turns)) {
                let y = f.helix.axisPoint.y + f.hand * f.pitch * (Double(turn) + theta / (2 * .pi))
                guard y > f.pitch, y < f.length - f.pitch else { continue }
                expectedYs.append(y)
                let expected = radial * majorRadius + SIMD3(0, y, 0)
                let distance = points.map { simd_distance($0, expected) }.min() ?? .infinity
                XCTAssertLessThan(distance, 0.01, "missing crest at \(expected), hand=\(f.hand)", file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(expectedYs.count, 2, file: file, line: line)
            for pair in zip(expectedYs, expectedYs.dropFirst()) {
                XCTAssertEqual(abs(pair.1 - pair.0), f.pitch, accuracy: 1e-10, file: file, line: line)
            }
            if theta == Double.pi / 2 {
                // Reversing the predicted angular advance shifts the crest by
                // half a pitch. It must not find the same returned crest edge.
                let y = expectedYs[expectedYs.count / 2] + f.hand * f.pitch / 2
                let wrongHand = radial * majorRadius + SIMD3(0, y, 0)
                let distance = points.map { simd_distance($0, wrongHand) }.min() ?? .infinity
                XCTAssertGreaterThan(distance, 0.05, "geometry must distinguish hand", file: file, line: line)
            }
        }
    }

    private func flatEnds(_ shape: BRepHandle, length: Double) {
        let faces = OCCTKernel.faceInfo(shape)
        for end in [0.0, length] {
            XCTAssertTrue(faces.contains { face in
                guard case .planar? = face.signature?.kind else { return false }
                return abs(face.centroid.y - end) < 1e-5 && abs(face.normal.y) > 0.999
            }, "missing planar clipped end at y=\(end)")
        }
        let vertices = OCCTKernel.renderMesh(from: shape).positions
        XCTAssertFalse(vertices.isEmpty)
        XCTAssertGreaterThanOrEqual(vertices.map { Double($0.y) }.min() ?? -.infinity, -1e-4)
        XCTAssertLessThanOrEqual(vertices.map { Double($0.y) }.max() ?? .infinity, length + 1e-4)
    }

    private func external(_ f: Fixture) throws -> BRepHandle {
        let overlapShape = try boolean(f.core, f.clipped, .intersect, label: "root overlap")
        let result = try boolean(f.core, f.clipped, .union, label: "external custom thread")
        let v = OCCTKernel.volume(result), coreV = OCCTKernel.volume(f.core)
        XCTAssertGreaterThan(v, coreV + 0.1)
        XCTAssertLessThan(v, .pi * majorRadius * majorRadius * f.length)
        XCTAssertEqual(v, coreV + OCCTKernel.volume(f.clipped) - OCCTKernel.volume(overlapShape), accuracy: 0.01)
        try crestEvidence(result, fixture: f)
        flatEnds(result, length: f.length)
        return result
    }

    private func internalThread(_ f: Fixture) throws -> BRepHandle {
        let removed = try boolean(f.blank, f.clipped, .intersect, label: "groove material")
        let result = try boolean(f.blank, f.clipped, .subtract, label: "internal custom thread")
        let v = OCCTKernel.volume(result), blankV = OCCTKernel.volume(f.blank)
        XCTAssertLessThan(v, blankV - 0.1)
        XCTAssertGreaterThan(v, .pi * (36 - majorRadius * majorRadius) * f.length)
        XCTAssertEqual(v, blankV - OCCTKernel.volume(removed), accuracy: 0.01)
        try crestEvidence(result, fixture: f)
        flatEnds(result, length: f.length)
        return result
    }

    func testCustom60DegreeExternalMajor8Pitch125Length10RightHand() async throws {
        _ = try external(fixture())
    }
    func testCustom60DegreeExternalMajor8Pitch125Length10LeftHand() async throws {
        _ = try external(fixture(hand: -1))
    }
    func testCustom60DegreeInternalMajor8Pitch125Length10RightHand() async throws {
        _ = try internalThread(fixture())
    }
    func testCustom60DegreeInternalMajor8Pitch125Length10LeftHand() async throws {
        _ = try internalThread(fixture(hand: -1))
    }
    func testReasonablePitchAndLengthVariationRemainsExactSingleSolid() async throws {
        for (pitch, length, hand) in [(1.0, 6.0, 1.0), (1.5, 9.0, -1.0)] {
            let f = try fixture(pitch: pitch, length: length, hand: hand)
            _ = try external(f)
            _ = try internalThread(f)
        }
    }
    func testObliquePlacementPreservesExactThreadAndSectionEvidence() async throws {
        let f = try fixture()
        let local = try external(f)
        let placement = Transform3D(translation: SIMD3(27, -13, 8),
            rotation: simd_quatd(angle: 0.61, axis: simd_normalize(SIMD3(1, 2, 3))), scale: 1)
        let moved = try XCTUnwrap(OCCTKernel.transformed(local, by: placement))
        XCTAssertEqual(try healthy(moved, label: "oblique thread"), OCCTKernel.volume(local), accuracy: 0.01)
        let theta = Double.pi / 2
        let points = OCCTKernel.sectionPolylines(moved, origin: placement.translation,
            normal: placement.rotation.act(SIMD3(-sin(theta), 0, -cos(theta))), deflection: 0.002).flatMap { $0 }
        let y = -f.pitch + f.pitch * (3 + theta / (2 * .pi))
        let expected = placement.applying(to: SIMD3(majorRadius * cos(theta), y, -majorRadius * sin(theta)))
        XCTAssertLessThan(points.map { simd_distance($0, expected) }.min() ?? .infinity, 0.01)
    }
    func testExactSerializationRetainsHelicalGeometryAndFlatEnds() async throws {
        let f = try fixture()
        let result = try internalThread(f)
        let data = try XCTUnwrap(OCCTKernel.serialize(result))
        let restored = try XCTUnwrap(OCCTKernel.deserialize(data))
        XCTAssertEqual(try healthy(restored, label: "BRep reopen"), OCCTKernel.volume(result), accuracy: 0.01)
        try crestEvidence(restored, fixture: f)
        flatEnds(restored, length: f.length)
    }
    func testZeroPitchRefusalPreservesExistingTargetExactBRep() async throws {
        let target = try cylinder(radius: rootRadius, length: 10)
        let before = try XCTUnwrap(OCCTKernel.serialize(target))
        let invalid = HelixSpec(axisPoint: .zero, axisDirection: SIMD3(0, 1, 0),
            referenceDirection: SIMD3(1, 0, 0), radius: rootRadius, pitch: 0, turns: 8)
        let profile = Profile(loop: [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0, 0.3)],
                              kind: .polygonal, sourceEntityIDs: [])
        let result = OCCTKernel.sweepSolid(outer: profile, holes: [],
            plane: SketchPlane(origin: SIMD3(rootRadius, 0, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            spine: invalid.sampledSpine(), helix: invalid)
        XCTAssertNil(result, "existing native helix entry rejects zero pitch")
        XCTAssertEqual(OCCTKernel.serialize(target), before)
        XCTAssertEqual(OCCTKernel.volume(target), .pi * rootRadius * rootRadius * 10, accuracy: 1e-3)
    }

    // MARK: - Helix sampling safety (M15 input boundary)

    /// The exact pre-change sampling expression. This is a value-level
    /// reference for the byte-identity assertion below, not an App/native
    /// integration test and not a second implementation used by production.
    private func legacySampledSpine(_ spec: HelixSpec, perTurn: Int) -> [SIMD3<Double>] {
        let count = max(1, Int((spec.turns * Double(perTurn)).rounded()))
        return (0...count).map {
            spec.point(at: spec.startAngle + 2 * .pi * spec.turns * Double($0) / Double(count))
        }
    }

    func testCheckedHelixSamplingIsByteIdenticalForValidParameters() throws {
        let fixtures: [(pitch: Double, turns: Double, start: Double, perTurn: Int)] = [
            (1.25, 10, 0, 16),
            (1.25, 10, 0.37, 36),
            (-1.5, 6.25, -0.8, 36),
            (0.75, 0.5, 1.1, 7),
        ]
        for fixture in fixtures {
            let spec = HelixSpec(
                axisPoint: SIMD3(1.5, -2, 3),
                axisDirection: SIMD3(0, 0.6, 0.8),
                referenceDirection: SIMD3(1, 0, 0),
                radius: 3.5, pitch: fixture.pitch, turns: fixture.turns,
                startAngle: fixture.start)
            let before = legacySampledSpine(spec, perTurn: fixture.perTurn)
            let after = try spec.checkedSampledSpine(perTurn: fixture.perTurn)
            XCTAssertEqual(after.count, before.count)
            for (actual, expected) in zip(after, before) {
                XCTAssertEqual(actual.x.bitPattern, expected.x.bitPattern)
                XCTAssertEqual(actual.y.bitPattern, expected.y.bitPattern)
                XCTAssertEqual(actual.z.bitPattern, expected.z.bitPattern)
            }
            XCTAssertEqual(spec.sampledSpine(perTurn: fixture.perTurn).count, before.count)
        }
    }

    func testHelixSamplingRefusesHugeAndInvalidRequestsWithoutAllocating() {
        func makeSpec(turns: Double = 10, radius: Double = 3.5, pitch: Double = 1.25,
                      startAngle: Double = 0,
                      axisPoint: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
                      axisDirection: SIMD3<Double> = SIMD3<Double>(0, 1, 0),
                      referenceDirection: SIMD3<Double> = SIMD3<Double>(1, 0, 0)) -> HelixSpec {
            HelixSpec(axisPoint: axisPoint, axisDirection: axisDirection,
                      referenceDirection: referenceDirection, radius: radius,
                      pitch: pitch, turns: turns, startAngle: startAngle)
        }
        func assertThrows(_ spec: HelixSpec,
                          perTurn: Int = HelixSamplingLimits.defaultSamplesPerTurn,
                          file: StaticString = #filePath, line: UInt = #line,
                          _ check: (HelixSamplingError) -> Void) {
            XCTAssertThrowsError(try spec.checkedSampledSpine(perTurn: perTurn),
                                 file: file, line: line) { error in
                guard let sampling = error as? HelixSamplingError else {
                    return XCTFail("unexpected error \(error)", file: file, line: line)
                }
                check(sampling)
            }
            XCTAssertTrue(spec.sampledSpine(perTurn: perTurn).isEmpty, file: file, line: line)
        }

        for turns in [1e20, 1e9, 1e18] {
            assertThrows(makeSpec(turns: turns)) { error in
                guard case let .sampleLimit(requested, maximum) = error else {
                    return XCTFail("expected sampleLimit, got \(error)")
                }
                XCTAssertGreaterThan(requested, Double(maximum))
                XCTAssertEqual(maximum, HelixSamplingLimits.maximumSpineSegments)
            }
        }
        assertThrows(makeSpec(turns: .greatestFiniteMagnitude)) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        for turns in [Double.infinity, .nan, 0, -1] {
            assertThrows(makeSpec(turns: turns)) { error in
                guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
            }
        }
        for radius in [Double.infinity, .nan, 0, -1] {
            assertThrows(makeSpec(radius: radius)) { error in
                guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
            }
        }
        for pitch in [Double.infinity, .nan, 0, 1e-12] {
            assertThrows(makeSpec(pitch: pitch)) { error in
                guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
            }
        }
        assertThrows(makeSpec(startAngle: .infinity)) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(axisPoint: SIMD3<Double>(.nan, 0, 0))) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(axisDirection: SIMD3<Double>(0, 0, 0))) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(axisDirection: SIMD3<Double>(1e308, 1e308, 0))) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(referenceDirection: SIMD3<Double>(0, 0, 0))) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(referenceDirection: SIMD3<Double>(0, 1, 0))) { error in
            guard case .invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
        assertThrows(makeSpec(), perTurn: 0) { XCTAssertEqual($0, .invalidPerTurn) }
        assertThrows(makeSpec(), perTurn: -36) { XCTAssertEqual($0, .invalidPerTurn) }
        assertThrows(makeSpec(), perTurn: Int.max) { error in
            guard case .sampleLimit = error else {
                return XCTFail("expected sampleLimit, got \(error)")
            }
        }
    }

    func testSweepParserRefusesUnsafeHelixAndPreservesExistingSpinePrecedence() throws {
        let sketch = UUID().uuidString
        func command(turns: Double,
                     spine: [[Double]]? = nil,
                     reference: [Double]? = [1, 0, 0],
                     axis: [Double] = [0, 1, 0],
                     pitch: Double = 1.25,
                     radius: Double = 3.5) -> [String: Any] {
            var helix: [String: Any] = [
                "axisPoint": [0, 0, 0],
                "axisDirection": axis,
                "radius": radius,
                "pitch": pitch,
                "turns": turns,
            ]
            if let reference { helix["referenceDirection"] = reference }
            var args: [String: Any] = [
                "sketchID": sketch,
                "seedPoint": [0, 0],
                "helix": helix,
            ]
            if let spine { args["spine"] = spine }
            return ["op": "feature.sweep", "args": args]
        }
        func expectFailure(_ command: [String: Any], code: String,
                           file: StaticString = #filePath, line: UInt = #line) {
            switch AgentExec.parse(command) {
            case .success:
                XCTFail("expected \(code)", file: file, line: line)
            case .failure(let error):
                XCTAssertEqual(error.code, code, error.message, file: file, line: line)
            }
        }

        for turns in [1e20, 1e9, 1e18] {
            expectFailure(command(turns: turns), code: "helix_sampling_limit")
        }
        for turns in [Double.infinity, .nan] {
            expectFailure(command(turns: turns), code: "non_finite")
        }
        expectFailure(command(turns: 10, pitch: 0), code: "bad_helix")
        expectFailure(command(turns: 10, radius: 0), code: "bad_helix")
        expectFailure(command(turns: 10, axis: [0, 0, 0]), code: "bad_helix")
        expectFailure(command(turns: 10, axis: [1e308, 1e308, 0]), code: "bad_helix")
        // The dot product itself overflows here, so the projected reference is
        // not normalizable; this is the precise bad_helix refusal.
        expectFailure(command(turns: 10, reference: [1.5e308, 1.5e308, 0],
                              axis: [1, 1, 0]),
                     code: "bad_helix")

        // A supplied render spine still wins over sampling (old semantics),
        // while unsafe helix arithmetic is refused even with that spine.
        let supplied: [[Double]] = [[0, 0, 0], [0, 1, 0]]
        guard case let .success(op) = AgentExec.parse(command(turns: 10, spine: supplied)),
              case let .sweep(_, _, parsedSpine, _, _, parsedHelix, _) = op else {
            return XCTFail("valid supplied spine + helix must parse")
        }
        XCTAssertEqual(parsedSpine, [SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 1, 0)])
        XCTAssertEqual(try XCTUnwrap(parsedHelix).turns, 10)
        expectFailure(command(turns: 1e20, spine: supplied), code: "helix_sampling_limit")

        guard case let .success(op) = AgentExec.parse(command(turns: 10, reference: nil)),
              case let .sweep(_, _, sampled, _, _, helix, _) = op else {
            return XCTFail("valid opaque helix must parse")
        }
        XCTAssertEqual(sampled.count, 361)
        let validSpec = try XCTUnwrap(helix)
        XCTAssertEqual(validSpec.pitch, 1.25)
        XCTAssertEqual(validSpec.turns, 10)
        XCTAssertEqual(simd_length(validSpec.referenceDirection), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(validSpec.referenceDirection, SIMD3<Double>(0, 1, 0)),
                       0, accuracy: 1e-12)

        // A parallel/absent reference keeps its existing deterministic fallback.
        guard case let .success(op) = AgentExec.parse(
            command(turns: 2, reference: [0, 1, 0])),
              case let .sweep(_, _, _, _, _, fallbackHelix, _) = op else {
            return XCTFail("parallel reference must use the deterministic fallback")
        }
        let fallbackSpec = try XCTUnwrap(fallbackHelix)
        XCTAssertEqual(simd_length(fallbackSpec.referenceDirection), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(fallbackSpec.referenceDirection, SIMD3<Double>(0, 1, 0)),
                       0, accuracy: 1e-12)

        // Negative pitch is valid and descends along the +Y axis.
        guard case let .success(op) = AgentExec.parse(command(turns: 10, pitch: -1.25)),
              case let .sweep(_, _, descending, _, _, negativeHelix, _) = op else {
            return XCTFail("negative pitch must parse")
        }
        XCTAssertEqual(try XCTUnwrap(negativeHelix).pitch, -1.25)
        XCTAssertEqual(descending.count, 361)
        XCTAssertLessThan(descending.last!.y, descending.first!.y)
    }

    func testHelixKitPathRefusesUnsafeSamplingArithmetic() {
        let plane = SketchPlane.ground
        XCTAssertTrue(HelixKit.path(radius: 3.5, pitch: 1.25, turns: 1e20, in: plane).isEmpty)
        XCTAssertTrue(HelixKit.path(radius: 3.5, pitch: 1.25, turns: 1e9, in: plane).isEmpty)
        XCTAssertTrue(HelixKit.path(radius: .infinity, pitch: 1.25, turns: 10,
                                    in: plane).isEmpty)
        XCTAssertEqual(HelixKit.path(radius: 3.5, pitch: 1.25, turns: 10,
                                     in: plane).count, 481)
    }

    func testExactKernelSweepRefusesUnsafeHelixBeforeOCCT() {
        let profile = Profile(loop: [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0, 0.3)],
                              kind: .polygonal, sourceEntityIDs: [])
        let plane = SketchPlane(origin: SIMD3(3.5, 0, 0), xAxis: SIMD3(1, 0, 0),
                                yAxis: SIMD3(0, 1, 0))
        let spine = [SIMD3<Double>(3.5, 0, 0), SIMD3<Double>(3.5, 1.25, 0)]
        for turns in [1e20, 1e9, 1e18] {
            let helix = HelixSpec(axisPoint: .zero, axisDirection: SIMD3(0, 1, 0),
                                  referenceDirection: SIMD3(1, 0, 0), radius: 3.5,
                                  pitch: 1.25, turns: turns)
            XCTAssertNil(OCCTKernel.sweepSolid(outer: profile, holes: [], plane: plane,
                                               spine: spine, helix: helix),
                         "unsafe helix must not reach OS3DHelixWire")
        }
    }

    func testGeneratedSweepMeshBudgetRefusesProfileMultiplicationWithoutOverflow() {
        XCTAssertNil(HelixSamplingLimits.sweepMeshError(spinePointCount: 2,
                                                       loopVertexCount: 3))
        XCTAssertNil(HelixSamplingLimits.sweepMeshError(spinePointCount: 83_334,
                                                       loopVertexCount: 3))
        XCTAssertNotNil(HelixSamplingLimits.sweepMeshError(spinePointCount: 83_335,
                                                           loopVertexCount: 3))
        XCTAssertNotNil(HelixSamplingLimits.sweepMeshError(spinePointCount: Int.max,
                                                           loopVertexCount: 3))
        XCTAssertNil(HelixSamplingLimits.sweepMeshError(spinePointCount: Int.max,
                                                       loopVertexCount: 0))
    }

    func testSavedMalformedHelixIsRefusedByGraphEvaluation() {
        let malformed = HelixSpec(
            axisPoint: SIMD3<Double>(0, 0, 0),
            axisDirection: SIMD3<Double>(0, 1, 0),
            referenceDirection: SIMD3<Double>(1, 0, 0),
            radius: 3.5, pitch: 1.25, turns: 1e20)
        let node = FeatureNode(
            name: "Saved malformed helix",
            kind: .sweep(
                profile: ProfileRef(sketchID: SketchID(), entityIDs: [],
                                    holeEntityIDs: [], seedPoint: SIMD2<Double>(0, 0)),
                plane: PlaneRef(source: .ground),
                spine: [PointWrapper(SIMD3<Double>(0, 0, 0)),
                        PointWrapper(SIMD3<Double>(0, 1, 0))],
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                helix: malformed),
            outputBodyIDs: [BodyID()])
        var revision: UInt64 = 0
        let result = FeatureGraph(nodes: [node]).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision &+= 1; return revision })
        guard let error = result.errors[node.id],
              case .kernelFailure(let message) = error else {
            return XCTFail("saved malformed helix must be refused: \(result.errors)")
        }
        XCTAssertTrue(message.contains("helix"), message)
        XCTAssertTrue(result.bodies.isEmpty)
    }

    func testExecRejectsHugeHelixBeforeMutationThenBuildsValidHelix() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADHelixSafety-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("Helix.floecad"), name: "Helix safety")
        defer { document.close() }

        let created = document.execute([
            "op": "sketch.create",
            "args": ["origin": [3.5, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]],
        ])
        XCTAssertTrue(created.isOK, created.message ?? "")
        let createdPayload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: created.payload) as? [String: Any])
        let sketchID = try XCTUnwrap(createdPayload["sketchID"] as? String)
        let entities = document.execute([
            "op": "sketch.addEntities",
            "args": ["sketchID": sketchID,
                     "entities": [["kind": "circle", "center": [0, 0], "radius": 0.5]]],
        ])
        XCTAssertTrue(entities.isOK, entities.message ?? "")

        var helix: [String: Any] = [
            "axisPoint": [0, 0, 0],
            "axisDirection": [0, 1, 0],
            "referenceDirection": [1, 0, 0],
            "radius": 3.5,
            "pitch": 1.25,
            "turns": 1e20,
        ]
        let huge = document.execute([
            "op": "feature.sweep",
            "args": ["sketchID": sketchID, "seedPoint": [0, 0], "helix": helix],
        ])
        XCTAssertFalse(huge.isOK)
        XCTAssertEqual(huge.errorCode, "helix_sampling_limit", huge.message ?? "")
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        XCTAssertTrue(document.session.document.bodies.isEmpty)

        helix["turns"] = 2.0
        let valid = document.execute([
            "op": "feature.sweep",
            "args": ["sketchID": sketchID, "seedPoint": [0, 0], "helix": helix],
        ])
        XCTAssertTrue(valid.isOK,
                      "\(valid.errorCode ?? "") \(valid.message ?? "")")
        XCTAssertEqual(document.session.document.features.nodes.count, 1)
        XCTAssertEqual(document.session.document.bodies.count, 1)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertGreaterThan(body.render.triangleCount, 0)
        let beforeBounds = body.render.localAABB

        // The saved-document path: a malformed spec must be refused by the
        // evaluator without rebuilding/corrupting the last-good body.
        let malformed = HelixSpec(
            axisPoint: SIMD3<Double>(0, 0, 0),
            axisDirection: SIMD3<Double>(0, 1, 0),
            referenceDirection: SIMD3<Double>(1, 0, 0),
            radius: 3.5, pitch: 1.25, turns: 1e20)
        let savedSketch = SketchID(raw: try XCTUnwrap(UUID(uuidString: sketchID)))
        let badNode = FeatureNode(
            name: "Malformed Helix Sweep",
            kind: .sweep(
                profile: ProfileRef(sketchID: savedSketch, entityIDs: [],
                                    holeEntityIDs: [], seedPoint: SIMD2<Double>(0, 0)),
                plane: PlaneRef(source: .sketch(savedSketch)),
                spine: [PointWrapper(SIMD3<Double>(0, 0, 0)),
                        PointWrapper(SIMD3<Double>(0, 1, 0))],
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                helix: malformed),
            outputBodyIDs: [BodyID()])
        document.session.recordAndRebuild([badNode], title: "Malformed Helix Sweep")
        guard let evalError = document.session.lastEvalErrors[badNode.id],
              case .kernelFailure(let message) = evalError else {
            return XCTFail("saved malformed helix must be refused: "
                           + "\(document.session.lastEvalErrors)")
        }
        XCTAssertTrue(message.contains("helix"), message)
        XCTAssertEqual(document.session.document.bodies.count, 1)
        let after = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(after.id, body.id)
        let afterBounds = after.render.localAABB
        XCTAssertLessThan(simd_length(afterBounds.min - beforeBounds.min), 1e-6)
        XCTAssertLessThan(simd_length(afterBounds.max - beforeBounds.max), 1e-6)
    }
}
