//
//  CADAssociativeAngleThreePointValueTests.swift
//  FloeCADKitTests
//
//  M07 — pure value/Codable/geometry contract for the angle and three-point
//  construction-plane kinds. No document, feature graph, kernel or UI is
//  involved here; the service/session behavior is in
//  CADAssociativePlaneKindsServiceTests.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeAngleThreePointValueTests: XCTestCase {
    private let bodyUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000B1")!
    private let otherBodyUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000B2")!
    private let producerUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000F1")!
    private let writerUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000F2")!
    private let creatorUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000F4")!
    private let sketchUUID = UUID(uuidString: "10000000-0000-0000-0000-0000000000C2")!
    private let entityA = UUID(uuidString: "10000000-0000-0000-0000-0000000000E1")!
    private let entityB = UUID(uuidString: "10000000-0000-0000-0000-0000000000E2")!

    private var bodyID: BodyID { BodyID(raw: bodyUUID) }
    private var otherBodyID: BodyID { BodyID(raw: otherBodyUUID) }
    private var producer: FeatureID { FeatureID(raw: producerUUID) }
    private var writer: FeatureID { FeatureID(raw: writerUUID) }
    private var creator: FeatureID { FeatureID(raw: creatorUUID) }
    private var sketchID: SketchID { SketchID(raw: sketchUUID) }

    private let faceCentroid = SIMD3<Double>(10, 20, 30)

    private func makeFaceRef() -> FaceRef {
        FaceRef(
            body: BodyRef(producer: producer, bodyID: bodyID),
            creator: creator,
            role: .boxFace(.py),
            signature: FaceSignature(
                kind: .planar,
                normal: SIMD3<Double>(0, 1, 0),
                centroid: faceCentroid,
                area: 600,
                planeOffset: 20
            ),
            elementName: ElementName(creator: creator,
                                     source: .primitiveFace(.boxFace(.py)))
        )
    }

    private func makeFrame() throws -> PlaneAttachmentFrame {
        try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid,
            faceNormal: SIMD3<Double>(0, 1, 0),
            referenceXAxis: SIMD3<Double>(1, 0, 0),
            anchorPoint: faceCentroid
        )
    }

    private func makeAngle(
        angle: Expr = Expr(value: 30),
        hinge: SIMD2<Double> = SIMD2(1, 0),
        sourceBody: BodyID? = nil,
        version: Int = AnglePlaneDefinition.supportedVersion
    ) throws -> AnglePlaneDefinition {
        AnglePlaneDefinition(
            version: version,
            source: makeFaceRef(),
            sourceVersion: GeometryVersionRef(bodyID: sourceBody ?? bodyID, writer: writer),
            hinge: hinge,
            angle: angle,
            attachment: try makeFrame()
        )
    }

    private func makeThreePoints() -> ThreePointPlaneDefinition {
        ThreePointPlaneDefinition(points: [
            SketchAnchorRef(sketchID: sketchID, entityID: entityA, role: .endpointA),
            SketchAnchorRef(sketchID: sketchID, entityID: entityA, role: .endpointB),
            SketchAnchorRef(sketchID: sketchID, entityID: entityB, role: .center),
        ])
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              accuracy: Double = 1e-9,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func assertOrthonormal(_ plane: SketchPlane,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_length(plane.xAxis), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_length(plane.yAxis), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_dot(plane.xAxis, plane.yAxis), 0, accuracy: 1e-9, file: file, line: line)
        assertVector(simd_cross(plane.xAxis, plane.yAxis), plane.normal,
                     accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - Codable + validation

    func testAngleDefinitionRoundTripKeepsDegreeFormulaAndHinge() throws {
        let definition = try makeAngle(angle: Expr(value: 30, formula: "tilt"),
                                       hinge: SIMD2(0.6, 0.8))
        let data = try encoder().encode(ConstructionPlaneDefinition.angle(definition))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["kind", "angle"]))
        XCTAssertEqual(object["kind"] as? String, "angle")
        let payload = try XCTUnwrap(object["angle"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set([
            "version", "source", "sourceVersion", "hinge", "angle", "attachment",
        ]))
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual((payload["angle"] as? [String: Any])?["formula"] as? String, "tilt")
        let decoded = try JSONDecoder().decode(ConstructionPlaneDefinition.self, from: data)
        XCTAssertEqual(decoded, .angle(definition))
    }

    func testThreePointDefinitionIsExactlyThreeDistinctPersistedAnchors() throws {
        let definition = makeThreePoints()
        let data = try encoder().encode(ConstructionPlaneDefinition.threePoints(definition))
        let decoded = try JSONDecoder().decode(ConstructionPlaneDefinition.self, from: data)
        XCTAssertEqual(decoded, .threePoints(definition))
        XCTAssertEqual(decoded.kind, .threePoints)
        XCTAssertTrue(decoded.expressionSlots.isEmpty)

        let duplicate = ThreePointPlaneDefinition(points: [
            definition.points[0], definition.points[0], definition.points[2],
        ])
        XCTAssertThrowsError(try duplicate.validate()) { error in
            guard case .invalidDefinitionShape = error as? AssociativeGeometryError else {
                return XCTFail("expected invalidDefinitionShape, got \(error)")
            }
        }
        let whole = ThreePointPlaneDefinition(points: [
            SketchAnchorRef(sketchID: sketchID, entityID: entityA, role: .whole),
            definition.points[1], definition.points[2],
        ])
        XCTAssertThrowsError(try whole.validate())

        // A known-version payload with two anchors is structurally malformed
        // and must fail at decode, not become an editable datum later.
        let encoded = try JSONSerialization.data(withJSONObject: [
            "kind": "threePoints",
            "threePoints": [
                "version": 1,
                "points": [
                    ["sketchID": ["raw": sketchUUID.uuidString],
                     "entityID": entityA.uuidString, "role": "endpointA"],
                ],
            ],
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(ConstructionPlaneDefinition.self, from: encoded)) {
            guard case .invalidDefinitionShape = $0 as? AssociativeGeometryError else {
                return XCTFail("expected invalidDefinitionShape, got \($0)")
            }
        }
    }

    func testUnknownKindsAndVersionsRefuseInsteadOfBecomingCachedPlanes() throws {
        let angle = try makeAngle()
        let angleData = try encoder().encode(ConstructionPlaneDefinition.angle(angle))
        var angleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: angleData) as? [String: Any])
        var anglePayload = try XCTUnwrap(angleObject["angle"] as? [String: Any])
        anglePayload["version"] = 2
        angleObject["angle"] = anglePayload
        let futureAngle = try JSONSerialization.data(withJSONObject: angleObject)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ConstructionPlaneDefinition.self, from: futureAngle)) { error in
                guard let error = error as? AssociativeGeometryError,
                      case .unsupportedSemanticVersion(2) = error else {
                    return XCTFail("expected unsupportedSemanticVersion(2), got \(error)")
                }
                XCTAssertTrue(error.requiresOpaqueReadOnlyDocument)
            }

        let three = makeThreePoints()
        let threeData = try encoder().encode(ConstructionPlaneDefinition.threePoints(three))
        var threeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: threeData) as? [String: Any])
        var threePayload = try XCTUnwrap(threeObject["threePoints"] as? [String: Any])
        threePayload["version"] = 7
        threeObject["threePoints"] = threePayload
        let futureThree = try JSONSerialization.data(withJSONObject: threeObject)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ConstructionPlaneDefinition.self, from: futureThree)) { error in
                guard let error = error as? AssociativeGeometryError,
                      case .unsupportedSemanticVersion(7) = error else {
                    return XCTFail("expected unsupportedSemanticVersion(7), got \(error)")
                }
            }

        let unknownKind = try JSONSerialization.data(withJSONObject: ["kind": "perpendicular"])
        XCTAssertThrowsError(try JSONDecoder().decode(
            ConstructionPlaneDefinition.self, from: unknownKind)) { error in
                guard let error = error as? AssociativeGeometryError,
                      case .unsupportedDefinitionKind("perpendicular") = error else {
                    return XCTFail("expected unsupportedDefinitionKind, got \(error)")
                }
                XCTAssertTrue(error.requiresOpaqueReadOnlyDocument)
            }
    }

    // MARK: - Angle geometry

    func testAngleResolutionConvertsDegreesOnceAndRotatesAboutHinge() throws {
        let definition = try makeAngle(angle: Expr(value: 30), hinge: SIMD2(1, 0))
        let face = SourceFaceGeometry(bodyID: bodyID, centroid: faceCentroid,
                                      normal: SIMD3<Double>(0, 1, 0))
        let plane = try definition.resolvedPlane(face: face, bodyTransform: .identity)
        assertVector(plane.origin, faceCentroid, accuracy: 1e-9)
        assertOrthonormal(plane)
        assertVector(plane.xAxis, SIMD3<Double>(1, 0, 0), accuracy: 1e-9)
        assertVector(plane.normal,
                     SIMD3<Double>(0, cos(30 * .pi / 180), sin(30 * .pi / 180)),
                     accuracy: 1e-9)

        // A second hinge (the frame y axis) rotates the other way; this is
        // the explicit local hinge, not a world-axis heuristic.
        let yHinge = try makeAngle(angle: Expr(value: 90), hinge: SIMD2(0, 1))
        let yPlane = try yHinge.resolvedPlane(face: face, bodyTransform: .identity)
        assertOrthonormal(yPlane)
        assertVector(yPlane.normal, SIMD3<Double>(1, 0, 0), accuracy: 1e-9)
        assertVector(yPlane.xAxis, SIMD3<Double>(0, -1, 0), accuracy: 1e-9)

        // Rotation + non-unit body scale + translation: the angle is applied
        // in body-local space and the offset distance is never scaled.
        var transform = Transform3D()
        transform.scale = 2
        transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3<Double>(0, 0, 1))
        transform.translation = SIMD3<Double>(100, -5, 7)
        let scaled = try definition.resolvedPlane(face: face, bodyTransform: transform)
        assertOrthonormal(scaled)
        assertVector(scaled.origin, transform.applying(to: faceCentroid), accuracy: 1e-9)
        assertVector(scaled.normal,
                     simd_normalize(transform.rotation.act(plane.normal)), accuracy: 1e-9)
    }

    func testInvalidAngleInputsRefuse() throws {
        let face = SourceFaceGeometry(bodyID: bodyID, centroid: faceCentroid,
                                      normal: SIMD3<Double>(0, 1, 0))
        let wrongBody = try makeAngle(sourceBody: otherBodyID)
        XCTAssertThrowsError(try wrongBody.resolvedPlane(face: face, bodyTransform: .identity)) {
            guard case .sourceVersionBodyMismatch = $0 as? AssociativeGeometryError else {
                return XCTFail("expected sourceVersionBodyMismatch, got \($0)")
            }
        }
        let badHinge = try makeAngle(hinge: SIMD2(2, 0))
        XCTAssertThrowsError(try badHinge.validate()) {
            guard case .invalidHingeAxis = $0 as? AssociativeGeometryError else {
                return XCTFail("expected invalidHingeAxis, got \($0)")
            }
        }
        let nanAngle = try makeAngle(angle: Expr(value: .nan))
        XCTAssertThrowsError(try nanAngle.validate()) {
            guard case .nonFiniteValue = $0 as? AssociativeGeometryError else {
                return XCTFail("expected nonFiniteValue, got \($0)")
            }
        }
        let collapsed = try makeAngle(angle: Expr(value: 0))
        let degenerateFace = SourceFaceGeometry(bodyID: bodyID, centroid: faceCentroid,
                                                normal: SIMD3<Double>(0, 1, 0))
        // The frozen x axis and current face normal are orthogonal here, so
        // the frame is valid; an unrelated body is still refused.
        XCTAssertNoThrow(try collapsed.resolvedPlane(face: degenerateFace,
                                                     bodyTransform: .identity))
    }

    // MARK: - Three-point geometry

    func testThreePointGeometryIsOrderedAndRefusesDegenerateInput() throws {
        let plane = try ThreePointPlaneDefinition.resolvedPlane(
            first: SIMD3<Double>(0, 0, 0),
            second: SIMD3<Double>(10, 0, 0),
            third: SIMD3<Double>(0, 0, 10)
        )
        assertVector(plane.origin, .zero, accuracy: 1e-9)
        assertVector(plane.xAxis, SIMD3<Double>(1, 0, 0), accuracy: 1e-9)
        assertVector(plane.normal, SIMD3<Double>(0, -1, 0), accuracy: 1e-9)
        assertOrthonormal(plane)

        let flipped = try ThreePointPlaneDefinition.resolvedPlane(
            first: SIMD3<Double>(0, 0, 0),
            second: SIMD3<Double>(10, 0, 0),
            third: SIMD3<Double>(0, 0, -10)
        )
        assertVector(flipped.normal, SIMD3<Double>(0, 1, 0), accuracy: 1e-9)

        XCTAssertThrowsError(try ThreePointPlaneDefinition.resolvedPlane(
            first: .zero, second: .zero, third: SIMD3(0, 0, 1))) {
                guard case .degenerateAnchorPoints = $0 as? AssociativeGeometryError else {
                    return XCTFail("expected degenerateAnchorPoints, got \($0)")
                }
            }
        XCTAssertThrowsError(try ThreePointPlaneDefinition.resolvedPlane(
            first: .zero, second: SIMD3(1, 0, 0), third: SIMD3(2, 0, 0))) {
                guard case .degenerateAnchorPoints = $0 as? AssociativeGeometryError else {
                    return XCTFail("expected degenerateAnchorPoints, got \($0)")
                }
            }
    }

    func testSketchAnchorRolesMatchPersistedEntityIdentity() {
        let line = SketchEntity.line(id: entityA, a: SIMD2(0, 0), b: SIMD2(10, 5))
        XCTAssertEqual(line.anchorRoles, [.endpointA, .endpointB])
        XCTAssertEqual(line.anchorPoint(for: .endpointA), SIMD2(0, 0))
        XCTAssertEqual(line.anchorPoint(for: .endpointB), SIMD2(10, 5))
        XCTAssertNil(line.anchorPoint(for: .center))

        let circle = SketchEntity.circle(id: entityB, center: SIMD2(3, 4), radius: 2)
        XCTAssertEqual(circle.anchorRoles, [.center])
        XCTAssertEqual(circle.anchorPoint(for: .center), SIMD2(3, 4))

        let closedSpline = SketchEntity.spline(id: UUID(), points: [SIMD2(0, 0), SIMD2(1, 1)],
                                               closed: true)
        XCTAssertEqual(closedSpline.anchorRoles, [])
        XCTAssertNil(closedSpline.anchorPoint(for: .endpointA))
    }

    // MARK: - Expression slots

    func testAngleExpressionStaysInPublicDegreesAndFanOutDoesNotConvertTwice() throws {
        let angle = try makeAngle(angle: Expr(value: 30, formula: "tilt"))
        let definition = ConstructionPlaneDefinition.angle(angle)
        let slots = definition.expressionSlots
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].name, "angle")
        XCTAssertEqual(slots[0].unit, "deg")
        let updated = try XCTUnwrap(definition.reevaluated(with: ["tilt": 12.5]))
        guard case let .angle(value) = updated else { return XCTFail("lost kind") }
        XCTAssertEqual(value.angle.value, 12.5, accuracy: 1e-12)
        XCTAssertEqual(value.angle.formula, "tilt")
        XCTAssertEqual(updated.expressionSlots[0].unit, "deg")

        let renamed = try XCTUnwrap(definition.rewritingFormulas { formula in
            formula == "tilt" ? "slope" : nil
        })
        guard case let .angle(renamedValue) = renamed else { return XCTFail("lost kind") }
        XCTAssertEqual(renamedValue.angle.formula, "slope")
        XCTAssertEqual(renamedValue.angle.value, 30, accuracy: 1e-12)
    }

    func testOffsetExpressionSlotKeepsMillimetres() throws {
        let definition = try makeAngle(angle: Expr(value: 5, formula: "gap"))
        _ = definition
        let frame = try makeFrame()
        let offset = OffsetPlaneDefinition(
            source: makeFaceRef(),
            sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer),
            distance: Expr(value: 5, formula: "gap"),
            attachment: frame
        )
        let slots = ConstructionPlaneDefinition.offset(offset).expressionSlots
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].name, "distance")
        XCTAssertEqual(slots[0].unit, "mm")
    }

    func testThreePointDependencyGraphInheritsEverySupportWriter() throws {
        let writerA = FeatureID()
        let writerB = FeatureID()
        let bodyA = BodyID()
        let bodyB = BodyID()
        let frame = try makeFrame()

        // Two independent feature authors, each producing one body.
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: writerA, name: "A",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [bodyA]),
            FeatureNode(id: writerB, name: "B",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [bodyB]),
        ])

        var faceA = makeFaceRef()
        faceA.body = BodyRef(producer: writerA, bodyID: bodyA)
        var faceB = makeFaceRef()
        faceB.body = BodyRef(producer: writerB, bodyID: bodyB)
        let versionA = GeometryVersionRef(bodyID: bodyA, writer: writerA)
        let versionB = GeometryVersionRef(bodyID: bodyB, writer: writerB)
        let planeA = ConstructionPlane(plane: .worldXY, size: 10, definition: .offset(
            OffsetPlaneDefinition(source: faceA, sourceVersion: versionA,
                                  distance: Expr(value: 0), attachment: frame)))
        let planeB = ConstructionPlane(plane: .worldXY, size: 10, definition: .offset(
            OffsetPlaneDefinition(source: faceB, sourceVersion: versionB,
                                  distance: Expr(value: 0), attachment: frame)))

        let lineA = UUID()
        let lineB = UUID()
        let sketchA = Sketch(name: "A", plane: .ground,
                             entities: [.line(id: lineA, a: SIMD2(0, 0), b: SIMD2(10, 0))],
                             support: PlaneRef(source: .construction(planeA.id)))
        let sketchB = Sketch(name: "B", plane: .ground,
                             entities: [.line(id: lineB, a: SIMD2(0, 5), b: SIMD2(10, 5))],
                             support: PlaneRef(source: .construction(planeB.id)))
        let threePoint = ConstructionPlane(plane: .worldXY, size: 10, definition: .threePoints(
            ThreePointPlaneDefinition(points: [
                SketchAnchorRef(sketchID: sketchA.id, entityID: lineA, role: .endpointA),
                SketchAnchorRef(sketchID: sketchA.id, entityID: lineA, role: .endpointB),
                SketchAnchorRef(sketchID: sketchB.id, entityID: lineB, role: .endpointA),
            ])))

        let dependencies = AssociativeDependencyGraph(
            graph: graph, sketches: [sketchA, sketchB],
            planes: [planeA, planeB, threePoint])
        let versions = try dependencies.sourceVersions(
            reachableFrom: .plane(threePoint.id))
        XCTAssertEqual(versions, Set([versionA, versionB]),
                       "a three-point datum must inherit every source sketch's support writer")
        XCTAssertEqual(Set(dependencies.dependencies(of: .plane(threePoint.id))),
                       Set([.sketch(sketchA.id), .sketch(sketchB.id)]))
    }
}
