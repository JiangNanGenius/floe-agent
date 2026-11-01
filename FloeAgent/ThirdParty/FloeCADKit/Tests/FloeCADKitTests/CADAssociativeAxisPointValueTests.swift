//
//  CADAssociativeAxisPointValueTests.swift
//  FloeCADKitTests
//
//  M08 value-model coverage for associative construction axes and datum
//  points: explicit semantic versions, stable source identities, exact
//  resolution from CURRENT source geometry, offset expressions, legacy
//  absolute records, and the refusals that must never become cached geometry.
//
//  These tests are pure: no OCCT, no document, no SwiftData.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

final class CADAssociativeAxisPointValueTests: XCTestCase {

    // MARK: Fixtures

    private let writer = FeatureID()
    private let bodyID = BodyID()

    private func bodyRef() -> BodyRef {
        BodyRef(producer: writer, bodyID: bodyID)
    }

    private func faceRef(normal: SIMD3<Double> = SIMD3(0, 1, 0),
                         centroid: SIMD3<Double> = SIMD3(0, 0, 0)) -> FaceRef {
        FaceRef(
            body: bodyRef(), creator: writer, role: .derived(index: 0),
            signature: FaceSignature(kind: .planar, normal: normal, centroid: centroid,
                                     area: 100, planeOffset: simd_dot(normal, centroid)),
            elementName: nil)
    }

    private func edgeRef() -> EdgeRef {
        EdgeRef(
            body: bodyRef(),
            signature: EdgeSignature(midpoint: SIMD3(0, 0, 0), direction: SIMD3(1, 0, 0),
                                     length: 100, normalA: SIMD3(0, 1, 0),
                                     normalB: SIMD3(0, 0, 1)),
            faceNames: nil)
    }

    private func frame(normal: SIMD3<Double> = SIMD3(0, 1, 0),
                       xAxis: SIMD3<Double> = SIMD3(1, 0, 0)) throws -> PlaneAttachmentFrame {
        try PlaneAttachmentFrame.make(
            faceCentroid: .zero, faceNormal: normal, referenceXAxis: xAxis)
    }

    private func face(_ centroid: SIMD3<Double> = .zero,
                      _ normal: SIMD3<Double> = SIMD3(0, 1, 0)) -> SourceFaceGeometry {
        SourceFaceGeometry(bodyID: bodyID, centroid: centroid, normal: normal)
    }

    private func faceAxis(offset: Double = 0,
                          frame: PlaneAttachmentFrame? = nil) throws -> FaceAxisDefinition {
        FaceAxisDefinition(
            source: faceRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer),
            attachment: try frame ?? self.frame(), offset: Expr(value: offset))
    }

    private func edgeAxis(offset: Double = 0,
                          reference: SIMD3<Double> = SIMD3(0, 1, 0)) -> EdgeAxisDefinition {
        EdgeAxisDefinition(
            source: edgeRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer),
            reference: reference, offset: Expr(value: offset))
    }

    private func edge() -> SourceAxisGeometry {
        SourceAxisGeometry.alongEdge(bodyID: bodyID, start: SIMD3(-50, 0, 0),
                                     end: SIMD3(50, 0, 0))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              accuracy: Double = 1e-9, _ label: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(label) x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(label) y", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "\(label) z", file: file, line: line)
    }

    // MARK: - Codable and versions

    func testFaceAxisDefinitionRoundTripKeepsOffsetFrameAndVersion() throws {
        var definition = try faceAxis(offset: 12.5)
        definition.offset = Expr(value: 12.5, formula: "12.5")
        let decoded = try roundTrip(ConstructionAxisDefinition.face(definition))
        guard case let .face(copy) = decoded else { return XCTFail("kind changed") }
        XCTAssertEqual(copy.version, FaceAxisDefinition.supportedVersion)
        XCTAssertEqual(copy.offset, Expr(value: 12.5, formula: "12.5"))
        XCTAssertEqual(copy.attachment, definition.attachment)
        XCTAssertEqual(copy.sourceVersion, definition.sourceVersion)
        XCTAssertEqual(copy.source.elementName, definition.source.elementName)
    }

    func testEveryAxisAndPointKindRoundTripsAndKeepsItsVersion() throws {
        let axisKinds: [ConstructionAxisDefinition] = [
            .face(try faceAxis()),
            .edge(edgeAxis()),
            .twoPoints(TwoPointAxisDefinition(points: [
                .sketchAnchor(SketchAnchorRef(sketchID: SketchID(), entityID: UUID(),
                                              role: .endpointA)),
                .datumPoint(DatumPointID()),
            ])),
            .twoPlanes(TwoPlaneAxisDefinition(planes: [ConstructionPlaneID(),
                                                       ConstructionPlaneID()])),
        ]
        for definition in axisKinds {
            let decoded = try roundTrip(definition)
            XCTAssertEqual(decoded, definition)
            XCTAssertEqual(decoded.semanticVersion, 1)
            XCTAssertTrue(decoded.isSupportedSemanticVersion)
        }

        let pointKinds: [DatumPointDefinition] = [
            .faceCenter(FaceCenterPointDefinition(
                source: faceRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer))),
            .edgePoint(EdgePointDefinition(
                source: edgeRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer),
                offset: Expr(value: -3))),
            .twoPointMidpoint(TwoPointMidpointDefinition(points: [
                .datumPoint(DatumPointID()), .datumPoint(DatumPointID()),
            ])),
            .axisPoint(AxisPointDefinition(axis: ConstructionAxisID(), offset: Expr(value: 5))),
            .axisPlane(AxisPlanePointDefinition(axis: ConstructionAxisID(),
                                                plane: ConstructionPlaneID())),
        ]
        for definition in pointKinds {
            let decoded = try roundTrip(definition)
            XCTAssertEqual(decoded, definition)
            XCTAssertEqual(decoded.semanticVersion, 1)
            XCTAssertTrue(decoded.isSupportedSemanticVersion)
        }
    }

    /// A present definition this build cannot read must THROW (so the document
    /// opens opaque/read-only), never decode to a value that could be mistaken
    /// for a legacy absolute datum.
    func testUnknownKindsAndVersionsRefuseInsteadOfCachedGeometry() throws {
        let valid = try JSONEncoder().encode(ConstructionAxisDefinition.face(try faceAxis()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var futureFace = try XCTUnwrap(object["face"] as? [String: Any])
        futureFace["version"] = 99
        object["face"] = futureFace
        let futureAxis = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConstructionAxisDefinition.self,
                                     from: futureAxis)) { error in
            guard let error = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(error, .unsupportedSemanticVersion(99))
            XCTAssertTrue(error.requiresOpaqueReadOnlyDocument)
        }

        let unknownKind = Data(#"{"kind":"helix","helix":{"version":1}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConstructionAxisDefinition.self, from: unknownKind)) { error in
            XCTAssertEqual(error as? AssociativeAxisPointError,
                           .unsupportedDefinitionKind("helix"))
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(DatumPointDefinition.self, from: unknownKind)) { error in
            XCTAssertEqual(error as? AssociativeAxisPointError,
                           .unsupportedDefinitionKind("helix"))
        }

        let validPoint = try JSONEncoder().encode(DatumPointDefinition.faceCenter(
            FaceCenterPointDefinition(
                source: faceRef(),
                sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer))))
        var pointObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validPoint) as? [String: Any])
        var futureCenter = try XCTUnwrap(pointObject["faceCenter"] as? [String: Any])
        futureCenter["version"] = 2
        pointObject["faceCenter"] = futureCenter
        let futurePoint = try JSONSerialization.data(withJSONObject: pointObject)
        XCTAssertThrowsError(
            try JSONDecoder().decode(DatumPointDefinition.self, from: futurePoint)) { error in
            XCTAssertEqual(error as? AssociativeAxisPointError,
                           .unsupportedSemanticVersion(2))
        }
    }

    /// A legacy absolute axis/point keeps its exact stored shape: nil
    /// definition is omitted, never encoded as null.
    func testLegacyAbsoluteAxisAndPointEncodeWithoutDefinition() throws {
        let axis = try XCTUnwrap(ConstructionAxis(
            origin: SIMD3(1, 2, 3), direction: SIMD3(0, 0, 1), length: 40,
            name: "Absolute", isHidden: true))
        let data = try JSONEncoder().encode(axis)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("definition"))
        let decoded = try JSONDecoder().decode(ConstructionAxis.self, from: data)
        XCTAssertNil(decoded.definition)
        XCTAssertEqual(decoded.origin, axis.origin)
        XCTAssertEqual(decoded.direction, axis.direction)
        XCTAssertEqual(decoded.length, 40)
        XCTAssertTrue(decoded.isHidden)

        let point = DatumPoint(position: SIMD3(4, 5, 6), name: "Pinned")
        let pointData = try JSONEncoder().encode(point)
        let pointText = try XCTUnwrap(String(data: pointData, encoding: .utf8))
        XCTAssertFalse(pointText.contains("definition"))
        XCTAssertEqual(try JSONDecoder().decode(DatumPoint.self, from: pointData), point)

        // And an associative one round-trips through the same row type.
        var associative = axis
        associative.definition = .edge(edgeAxis())
        let associativeData = try JSONEncoder().encode(associative)
        XCTAssertEqual(try JSONDecoder().decode(ConstructionAxis.self,
                                                from: associativeData).definition?.kind,
                       .edge)
    }

    // MARK: - Face axis

    func testFaceAxisResolutionProjectsFrameAndAppliesOffsetOnce() throws {
        let definition = try faceAxis(offset: 10)
        let transform = Transform3D(translation: SIMD3(0, 5, 0))
        let resolved = try definition.resolvedAxis(face: face(), bodyTransform: transform,
                                                   extent: 20)
        assertVector(resolved.origin, SIMD3(10, 5, 0), "face axis origin")
        assertVector(resolved.direction, SIMD3(0, 1, 0), "face axis direction")
        XCTAssertEqual(resolved.extent, 20)

        // A body rotation carries the axis with it.
        let rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let rotated = try definition.resolvedAxis(
            face: face(), bodyTransform: Transform3D(translation: .zero, rotation: rotation),
            extent: 20)
        XCTAssertEqual(rotated.direction.x, -1, accuracy: 1e-9)
        XCTAssertEqual(rotated.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rotated.origin.y, 10, accuracy: 1e-9)
    }

    func testFaceAxisRejectsUnsupportedFrameBodyAndOffsetState() throws {
        var anchored = try faceAxis()
        anchored = FaceAxisDefinition(
            source: anchored.source, sourceVersion: anchored.sourceVersion,
            attachment: PlaneAttachmentFrame(normal: SIMD3(0, 1, 0), xAxis: SIMD3(1, 0, 0),
                                             anchorOffset: SIMD2(1, 0)),
            offset: Expr(value: 0))
        XCTAssertThrowsError(try anchored.validate()) { error in
            guard case .invalidAttachmentFrame = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }

        let definition = try faceAxis()
        let otherBody = SourceFaceGeometry(bodyID: BodyID(), centroid: .zero,
                                           normal: SIMD3(0, 1, 0))
        XCTAssertThrowsError(try definition.resolvedAxis(
            face: otherBody, bodyTransform: .identity, extent: 10)) { error in
            guard case .sourceBodyMismatch = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }

        var nonFinite = definition
        nonFinite.offset = Expr(value: .nan)
        XCTAssertThrowsError(try nonFinite.validate())
    }

    // MARK: - Edge axis

    func testEdgeAxisResolutionUsesFrozenPerpendicularAndRefusesCollapse() throws {
        let definition = edgeAxis(offset: 4)
        let resolved = try definition.resolvedAxis(edge: edge(), bodyTransform: .identity,
                                                   scale: 1)
        assertVector(resolved.origin, SIMD3(0, 4, 0), "edge axis origin")
        assertVector(resolved.direction, SIMD3(1, 0, 0), "edge axis direction")
        XCTAssertEqual(resolved.extent, 100, accuracy: 1e-9)

        // Scale applies to the body-local edge exactly once, not the offset.
        let scaled = try definition.resolvedAxis(
            edge: edge(), bodyTransform: Transform3D(scale: 2), scale: 2)
        assertVector(scaled.origin, SIMD3(0, 4, 0), "scaled edge axis origin")
        XCTAssertEqual(scaled.extent, 200, accuracy: 1e-9)

        // A frozen reference parallel to the current edge collapses: refuse
        // instead of inventing a perpendicular.
        let collapsing = edgeAxis(offset: 1, reference: SIMD3(1, 0, 0))
        XCTAssertThrowsError(try collapsing.resolvedAxis(
            edge: edge(), bodyTransform: .identity, scale: 1)) { error in
            guard case .degenerateReference = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Two-point axis

    func testTwoPointAxisOrderingAndCoincidenceRefusal() throws {
        let first = SIMD3<Double>(1, 2, 3)
        let second = SIMD3<Double>(1, 2, 13)
        let resolved = try TwoPointAxisDefinition.resolvedAxis(first: first, second: second)
        XCTAssertEqual(resolved.origin, first)
        XCTAssertEqual(resolved.direction, SIMD3(0, 0, 1))
        XCTAssertEqual(resolved.extent, 10, accuracy: 1e-9)

        let reversed = try TwoPointAxisDefinition.resolvedAxis(first: second, second: first)
        XCTAssertEqual(reversed.direction, SIMD3(0, 0, -1))

        XCTAssertThrowsError(try TwoPointAxisDefinition.resolvedAxis(first: first, second: first)) {
            XCTAssertEqual($0 as? AssociativeAxisPointError,
                           .coincidentPoints("the two axis points coincide"))
        }
    }

    func testPointSourceIdentitiesAreSemanticAndDistinct() throws {
        let anchorA = SketchAnchorRef(sketchID: SketchID(), entityID: UUID(), role: .endpointA)
        let anchorB = SketchAnchorRef(sketchID: SketchID(), entityID: UUID(), role: .endpointB)
        let definition = TwoPointAxisDefinition(points: [.sketchAnchor(anchorA),
                                                         .sketchAnchor(anchorB)])
        XCTAssertNoThrow(try definition.validate())
        XCTAssertNotEqual(definition.points[0].diagnosticKey,
                          definition.points[1].diagnosticKey)

        let duplicated = TwoPointAxisDefinition(points: [.sketchAnchor(anchorA),
                                                         .sketchAnchor(anchorA)])
        XCTAssertThrowsError(try duplicated.validate()) { error in
            guard case .invalidDefinitionShape = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }
        // A single point, or a third one, is a shape error — not a silent trim.
        let wrongCount = TwoPointAxisDefinition(points: [.sketchAnchor(anchorA)])
        XCTAssertThrowsError(try wrongCount.validate())
        // Same point id in both roles is still ONE identity.
        let pointID = DatumPointID()
        let samePoint = TwoPointAxisDefinition(points: [.datumPoint(pointID), .datumPoint(pointID)])
        XCTAssertThrowsError(try samePoint.validate())
    }

    // MARK: - Two-plane axis

    func testTwoPlaneAxisIntersectionAndParallelRefusal() throws {
        let ground = SketchPlane.worldXY
        let vertical = SketchPlane(origin: SIMD3(10, 0, 0), xAxis: SIMD3(0, 0, -1),
                                   yAxis: SIMD3(0, 1, 0))
        let resolved = try TwoPlaneAxisDefinition.resolvedAxis(
            first: ground, second: vertical, sizes: (40, 20))
        XCTAssertEqual(resolved.origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(resolved.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(abs(resolved.direction.y), 1, accuracy: 1e-9)
        XCTAssertEqual(resolved.extent, 20, accuracy: 1e-9)

        XCTAssertThrowsError(try TwoPlaneAxisDefinition.resolvedAxis(
            first: ground, second: ground, sizes: (40, 40))) { error in
            guard case .parallelSources = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Datum points

    func testDatumPointKindsResolveCurrentGeometry() throws {
        let transform = Transform3D(translation: SIMD3(0, 0, 7))

        let faceCenter = FaceCenterPointDefinition(
            source: faceRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer))
        let center = try faceCenter.resolvedPoint(
            face: face(SIMD3(3, 4, 5), SIMD3(0, 1, 0)), bodyTransform: transform)
        assertVector(center.position, SIMD3(3, 4, 12), "face centre point")

        let edgePoint = EdgePointDefinition(
            source: edgeRef(), sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer),
            offset: Expr(value: 12))
        let onEdge = try edgePoint.resolvedPoint(edge: edge(), bodyTransform: .identity)
        assertVector(onEdge.position, SIMD3(12, 0, 0), "edge point")

        let midpoint = try TwoPointMidpointDefinition.resolvedPoint(
            first: SIMD3(0, 0, 0), second: SIMD3(10, 0, 0))
        XCTAssertEqual(midpoint.position, SIMD3(5, 0, 0))

        let axisFrame = ResolvedAxisGeometry(origin: SIMD3(0, 0, 0),
                                             direction: SIMD3(0, 0, 1), extent: 10)
        let axisPoint = try AxisPointDefinition(axis: ConstructionAxisID(),
                                                offset: Expr(value: -2.5))
            .resolvedPoint(axis: axisFrame)
        assertVector(axisPoint.position, SIMD3(0, 0, -2.5), "axis point")

        let crossing = try AxisPlanePointDefinition(axis: ConstructionAxisID(),
                                                    plane: ConstructionPlaneID())
            .resolvedPoint(axis: axisFrame,
                           plane: SketchPlane(origin: SIMD3(0, 0, 4), xAxis: SIMD3(1, 0, 0),
                                              yAxis: SIMD3(0, 1, 0)))
        assertVector(crossing.position, SIMD3(0, 0, 4), "axis/plane point")

        // A parallel axis/plane pair has no unique point.
        XCTAssertThrowsError(try AxisPlanePointDefinition(axis: ConstructionAxisID(),
                                                          plane: ConstructionPlaneID())
            .resolvedPoint(axis: axisFrame,
                           plane: SketchPlane(origin: SIMD3(0, 0, 4), xAxis: SIMD3(0, 0, -1),
                                              yAxis: SIMD3(0, 1, 0)))) { error in
            guard case .parallelSources = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Offsets and expression slots

    func testAxisAndPointOffsetExpressionsReevaluateAndRewrite() throws {
        var definition = ConstructionAxisDefinition.edge(edgeAxis(offset: 0))
        guard let offsetSlot = definition.expressionSlots.first else {
            return XCTFail("an edge axis owns one offset slot")
        }
        XCTAssertEqual(offsetSlot.name, "offset")
        XCTAssertEqual(offsetSlot.unit, "mm")

        definition = definition.settingExpression(
            named: "offset",
            to: Expr(value: 0, formula: "gap * 2")) ?? definition
        let reevaluated = try XCTUnwrap(definition.reevaluated(with: ["gap": 3]))
        XCTAssertEqual(reevaluated.expressionSlots.first?.expr.value, 6)
        XCTAssertEqual(reevaluated.expressionSlots.first?.expr.formula, "gap * 2")

        let renamed = try XCTUnwrap(definition.rewritingFormulas { $0 == "gap * 2" ? "slotWidth" : nil })
        XCTAssertEqual(renamed.expressionSlots.first?.expr.formula, "slotWidth")

        // A two-plane/two-point axis follows geometry and owns no slot.
        let twoPlanes = ConstructionAxisDefinition.twoPlanes(
            TwoPlaneAxisDefinition(planes: [ConstructionPlaneID(), ConstructionPlaneID()]))
        XCTAssertTrue(twoPlanes.expressionSlots.isEmpty)
        XCTAssertNil(twoPlanes.reevaluated(with: ["gap": 1]))

        var point = DatumPointDefinition.axisPoint(
            AxisPointDefinition(axis: ConstructionAxisID(), offset: Expr(value: 0)))
        point = point.settingExpression(named: "offset", to: Expr(value: 0, formula: "gap")) ?? point
        let pointReevaluated = try XCTUnwrap(point.reevaluated(with: ["gap": -4]))
        XCTAssertEqual(pointReevaluated.expressionSlots.first?.expr.value, -4)
        XCTAssertTrue(DatumPointDefinition.faceCenter(
            FaceCenterPointDefinition(
                source: faceRef(),
                sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: writer)))
            .expressionSlots.isEmpty)
    }

    // MARK: - Writer and source identity

    func testFrozenWriterAndBodyIdentityAreEnforced() throws {
        let wrongVersion = FaceAxisDefinition(
            source: faceRef(),
            sourceVersion: GeometryVersionRef(bodyID: BodyID(), writer: writer),
            attachment: try frame(), offset: Expr(value: 0))
        XCTAssertThrowsError(try wrongVersion.validate()) { error in
            guard case .sourceVersionBodyMismatch = error as? AssociativeAxisPointError else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(ConstructionAxisDefinition.face(wrongVersion).writerVersion,
                       wrongVersion.sourceVersion)
        XCTAssertNil(ConstructionAxisDefinition.twoPoints(
            TwoPointAxisDefinition(points: [.datumPoint(DatumPointID()),
                                            .datumPoint(DatumPointID())])).writerVersion)
    }

    func testResolvedAxisFrameKeepsUnitDirectionAndPositiveExtent() throws {
        let frame = ResolvedAxisGeometry(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 1, 0),
                                         extent: 3)
        XCTAssertEqual(simd_length(frame.direction), 1, accuracy: 1e-12)
        XCTAssertEqual(try roundTrip(frame), frame)
    }
}
