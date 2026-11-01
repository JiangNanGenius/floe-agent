//
//  CADAssociativeCylinderAxisValueTests.swift
//  FloeCADKitTests
//
//  M08 R2 value coverage for the CYLINDRICAL construction axis and the
//  construction-axis → revolve adapter.
//
//  The cylinder axis is the one case where a direction is not enough: the
//  resolved line must pass through the cylinder's OWN analytic axis point, so
//  a partial/shifted face does not silently revolve about a centroid line.
//  The revolve adapter must accept exactly the coplanar axes the existing 2D
//  kernel can consume and refuse everything else.
//
//  Pure: no OCCT, no document, no SwiftData.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

final class CADAssociativeCylinderAxisValueTests: XCTestCase {

    // MARK: Fixtures

    private let writer = FeatureID()
    private let bodyID = BodyID()

    private func bodyRef() -> BodyRef {
        BodyRef(producer: writer, bodyID: bodyID)
    }

    private func version() -> GeometryVersionRef {
        GeometryVersionRef(bodyID: bodyID, writer: writer)
    }

    private func cylinderRef(radius: Double = 4,
                             centroid: SIMD3<Double> = SIMD3(9, 12, -1),
                             axis: SIMD3<Double> = SIMD3(0, 1, 0)) -> FaceRef {
        FaceRef(
            body: bodyRef(), creator: writer, role: .derived(index: 3),
            signature: FaceSignature(
                kind: .cylindrical(radius: radius), normal: axis, centroid: centroid,
                area: 2 * Double.pi * radius * 10, planeOffset: simd_dot(axis, centroid)),
            elementName: nil)
    }

    private func cylinderDefinition(
        radius: Double = 4
    ) -> CylinderAxisDefinition {
        CylinderAxisDefinition(source: cylinderRef(radius: radius), sourceVersion: version())
    }

    /// A partial cylinder: the face centroid (9,12,-1) is deliberately NOT on
    /// the axis through (7.5,-2,3.25) along +Y, which is the whole point of
    /// reading the analytic axis point instead of the centroid.
    private func cylinder() -> SourceCylinderGeometry {
        SourceCylinderGeometry(
            bodyID: bodyID,
            centroid: SIMD3(9, 12, -1),
            axisPoint: SIMD3(7.5, -2, 3.25),
            axisDirection: SIMD3(0, 2, 0),
            radius: 4,
            extent: 12)
    }

    private func distanceToLine(_ point: SIMD3<Double>, _ line: ResolvedAxisGeometry) -> Double {
        let delta = point - line.origin
        return simd_length(delta - line.direction * simd_dot(delta, line.direction))
    }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              accuracy: Double = 1e-9, _ label: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(label) x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(label) y", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "\(label) z", file: file, line: line)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Codable / versioning

    func testCylinderAxisDefinitionRoundTripsAsItsOwnKind() throws {
        let definition = cylinderDefinition()
        let decoded = try roundTrip(ConstructionAxisDefinition.cylinder(definition))
        XCTAssertEqual(decoded, .cylinder(definition))
        XCTAssertEqual(decoded.kind, .cylinder)
        XCTAssertEqual(decoded.semanticVersion, CylinderAxisDefinition.supportedVersion)
        XCTAssertEqual(decoded.writerVersion, definition.sourceVersion)
        XCTAssertTrue(decoded.expressionSlots.isEmpty,
                      "a cylinder axis follows the face's own line and has no offset slot")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "cylinder",
                       "the payload must be its own kind, never a planar face")
        XCTAssertNil(object["face"],
                     "an older reader must not find a face payload it could misread")
        XCTAssertNotNil(object["cylinder"])
    }

    func testOlderReadersRejectACylinderInsteadOfTreatingItAsAPlanarAxis() throws {
        // A raw v2 cylinder payload (a future semantic contract) must be an
        // opaque-read-only decode failure, not a cached absolute line.
        let encoded = try JSONEncoder().encode(ConstructionAxisDefinition.cylinder(cylinderDefinition()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(object["cylinder"] as? [String: Any])
        payload["version"] = 2
        object["cylinder"] = payload
        let future = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ConstructionAxisDefinition.self, from: future)) {
            guard let error = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected a typed refusal, got \($0)")
            }
            XCTAssertEqual(error, .unsupportedSemanticVersion(2))
            XCTAssertTrue(error.requiresOpaqueReadOnlyDocument)
        }

        // An unknown kind (which is what a reader WITHOUT the cylinder kind
        // sees) is an explicit unsupported-kind refusal.
        let unknownKind = try JSONSerialization.data(withJSONObject: [
            "kind": "helicalAxis",
            "helicalAxis": ["version": 1],
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(ConstructionAxisDefinition.self,
                                                      from: unknownKind)) {
            guard let error = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected a typed refusal, got \($0)")
            }
            XCTAssertEqual(error, .unsupportedDefinitionKind("helicalAxis"))
            XCTAssertTrue(error.requiresOpaqueReadOnlyDocument,
                          "an unreadable kind must open the document read-only, not rebind it")
        }

        // A cylinder payload missing its required source is malformed, not a
        // silent absolute axis.
        let malformed = try JSONSerialization.data(withJSONObject: [
            "kind": "cylinder",
            "cylinder": ["version": 1],
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(ConstructionAxisDefinition.self,
                                                      from: malformed))
    }

    func testLegacyAbsoluteAxisStillEncodesWithoutADefinition() throws {
        let absolute = ConstructionAxis(origin: SIMD3(1, 2, 3), direction: SIMD3(0, 1, 0),
                                        length: 40, name: "Axis 1")
        let legacy = try XCTUnwrap(absolute)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(object["definition"], "the legacy key set must stay byte-identical")
        let decoded = try JSONDecoder().decode(ConstructionAxis.self,
                                               from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.definition)
        XCTAssertEqual(decoded.origin, SIMD3(1, 2, 3))
    }

    // MARK: - Exact analytic line

    func testCylinderResolutionPassesThroughTheExactAxisPointNotTheCentroid() throws {
        let line = try cylinderDefinition().resolvedAxis(
            cylinder: cylinder(), bodyTransform: .identity, scale: 1)
        // The line is the analytic axis line.
        assertVector(line.direction, SIMD3(0, 1, 0), accuracy: 1e-12, "axis direction")
        XCTAssertEqual(distanceToLine(SIMD3(7.5, -2, 3.25), line), 0, accuracy: 1e-9,
                       "the resolved line must pass through the exact axis point")
        // The anchor is slid ALONG the same line to the face centroid's height,
        // which cannot move the line; its x/z equal the axis point's.
        XCTAssertEqual(line.origin.x, 7.5, accuracy: 1e-9)
        XCTAssertEqual(line.origin.z, 3.25, accuracy: 1e-9)
        XCTAssertEqual(line.origin.y, 12, accuracy: 1e-9, "display anchor at the face height")
        XCTAssertEqual(line.extent, 12, accuracy: 1e-12)

        // The centroid is NOT on the line — this is the failure mode a
        // centroid-built "axis" would have had.
        XCTAssertGreaterThan(distanceToLine(SIMD3(9, 12, -1), line), 1.0)
    }

    func testCylinderResolutionAppliesTheBodyTransformExactlyOnce() throws {
        let rotation = simd_quatd(angle: .pi / 3, axis: simd_normalize(SIMD3(1, 2, -1)))
        let transform = Transform3D(translation: SIMD3(3, -4, 5), rotation: rotation, scale: 2.5)
        let line = try cylinderDefinition().resolvedAxis(
            cylinder: cylinder(), bodyTransform: transform, scale: transform.scale)

        let expectedPoint = transform.applying(to: SIMD3(7.5, -2, 3.25))
        XCTAssertEqual(distanceToLine(expectedPoint, line), 0, accuracy: 1e-9,
                       "the transformed exact axis point stays on the resolved line")
        assertVector(line.direction, simd_normalize(rotation.act(SIMD3(0, 1, 0))),
                     accuracy: 1e-9, "rotated axis direction")
        XCTAssertEqual(line.extent, 30, accuracy: 1e-9,
                       "the display extent is scaled exactly once")
    }

    func testCylinderResolutionRefusesWrongBodyAndDegenerateAxis() throws {
        let other = SourceCylinderGeometry(
            bodyID: BodyID(), centroid: .zero, axisPoint: .zero,
            axisDirection: SIMD3(0, 1, 0), radius: 2, extent: 4)
        XCTAssertThrowsError(try cylinderDefinition().resolvedAxis(
            cylinder: other, bodyTransform: .identity, scale: 1)) {
            guard case .sourceBodyMismatch = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected sourceBodyMismatch, got \($0)")
            }
        }

        let collapsed = SourceCylinderGeometry(
            bodyID: bodyID, centroid: .zero, axisPoint: .zero,
            axisDirection: .zero, radius: 2, extent: 4)
        XCTAssertThrowsError(try cylinderDefinition().resolvedAxis(
            cylinder: collapsed, bodyTransform: .identity, scale: 1)) {
            guard case .degenerateDirection = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected degenerateDirection, got \($0)")
            }
        }

        XCTAssertNoThrow(try cylinderDefinition().validate())
    }

    func testCylinderDefinitionRejectsAWriterBodyMismatch() {
        let definition = CylinderAxisDefinition(
            source: cylinderRef(),
            sourceVersion: GeometryVersionRef(bodyID: BodyID(), writer: writer))
        XCTAssertThrowsError(try definition.validate()) {
            guard case .sourceVersionBodyMismatch = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected sourceVersionBodyMismatch, got \($0)")
            }
        }
    }

    // MARK: - Revolve consumer adapter

    func testRevolveBindingProjectsAnInPlaneLineIntoThePlaneBasis() throws {
        // An arbitrary rotated/translated plane, so the basis conversion is
        // exercised rather than the identity.
        let rotation = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, -1, 0.5)))
        let plane = SketchPlane(
            origin: SIMD3(4, -3, 8),
            xAxis: simd_normalize(rotation.act(SIMD3(1, 0, 0))),
            yAxis: simd_normalize(rotation.act(SIMD3(0, 1, 0))))
        let worldPoint = plane.toWorld(SIMD2(12, -5))
        let worldDirection = plane.xAxis * 0.6 + plane.yAxis * 0.8
        let line = ResolvedAxisGeometry(origin: worldPoint,
                                        direction: worldDirection, extent: 20)
        let local = try RevolveAxisBinding.planeLocal(line, plane: plane)
        XCTAssertEqual(local.point.x, 12, accuracy: 1e-9)
        XCTAssertEqual(local.point.y, -5, accuracy: 1e-9)
        XCTAssertEqual(local.direction.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(local.direction.y, 0.8, accuracy: 1e-9)
    }

    func testRevolveBindingRefusesAnAxisOffThePlaneOrPerpendicularToIt() throws {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))

        // Parallel to the plane but offset 2 mm along its normal: a 2D
        // projection would silently revolve about a different line.
        let offPlane = ResolvedAxisGeometry(origin: SIMD3(0, 0, 2),
                                            direction: SIMD3(1, 0, 0), extent: 10)
        XCTAssertThrowsError(try RevolveAxisBinding.planeLocal(offPlane, plane: plane)) {
            guard case let .axisNotInPlane(reason) = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected axisNotInPlane, got \($0)")
            }
            XCTAssertFalse(reason.isEmpty)
        }

        // Perpendicular to the plane: no 2D direction at all.
        let perpendicular = ResolvedAxisGeometry(origin: .zero,
                                                 direction: SIMD3(0, 0, 1), extent: 10)
        XCTAssertThrowsError(try RevolveAxisBinding.planeLocal(perpendicular, plane: plane)) {
            guard case .axisNotInPlane = $0 as? AssociativeAxisPointError else {
                return XCTFail("expected axisNotInPlane, got \($0)")
            }
        }

        // In-plane and exact: accepted.
        let inPlane = ResolvedAxisGeometry(origin: SIMD3(5, -4, 0),
                                           direction: SIMD3(0, 1, 0), extent: 10)
        let local = try RevolveAxisBinding.planeLocal(inPlane, plane: plane)
        XCTAssertEqual(local.point, SIMD2(5, -4))
        XCTAssertEqual(local.direction, SIMD2(0, 1))
    }

    func testRevolveBindingToleranceIsOnlyRoundOff() throws {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        // A sub-micron round-off height is accepted; a real displacement is not.
        let roundOff = ResolvedAxisGeometry(origin: SIMD3(0, 0, 1e-9),
                                            direction: SIMD3(1, 0, 0), extent: 100)
        XCTAssertNoThrow(try RevolveAxisBinding.planeLocal(roundOff, plane: plane))
        let displaced = ResolvedAxisGeometry(origin: SIMD3(0, 0, 1e-4),
                                             direction: SIMD3(1, 0, 0), extent: 100)
        XCTAssertThrowsError(try RevolveAxisBinding.planeLocal(displaced, plane: plane))
    }
}
