//
//  CADAssociativeGeometryValueTests.swift
//  FloeCADKitTests
//
//  M07 package A — pure value/Codable contract for associative offset
//  construction planes.
//
//  These tests deliberately use no document, no feature graph, no kernel and
//  no simulator UI: package A is the stored value model plus one bounded
//  geometric adapter. Package B/C integration (named-version lookup, replay,
//  transactional write-back, format-2 gating) is proven separately.
//
//  Covered here:
//    * legacy ConstructionPlane/Sketch values keep their exact key set —
//      omitted optional fields, byte-identical re-encode, nil default;
//    * complete definition/support round-trip, including a writer that is NOT
//      the BodyRef producer;
//    * unknown definition kinds and semantic versions throw instead of
//      decoding to nil absolute geometry;
//    * body identity mismatches, corrupt attachment frames and invalid body
//      transforms are explicit failures;
//    * the frame adapter is deterministic, centroid-relative, right-handed
//      under rotation/non-unit scale, and offsets by world millimetres after
//      the snapshot transform (never by body-local millimetres twice);
//    * opposite normals and collapsed projections have defined outcomes.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeGeometryValueTests: XCTestCase {

    // MARK: - Fixed identities

    private let bodyUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let otherBodyUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let producerUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    private let writerUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
    private let otherWriterUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
    private let creatorUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!
    private let planeUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let sketchUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

    private var bodyID: BodyID { BodyID(raw: bodyUUID) }
    private var otherBodyID: BodyID { BodyID(raw: otherBodyUUID) }
    private var producer: FeatureID { FeatureID(raw: producerUUID) }
    private var writer: FeatureID { FeatureID(raw: writerUUID) }
    private var otherWriter: FeatureID { FeatureID(raw: otherWriterUUID) }
    private var creator: FeatureID { FeatureID(raw: creatorUUID) }
    private var planeID: ConstructionPlaneID { ConstructionPlaneID(raw: planeUUID) }
    private var sketchID: SketchID { SketchID(raw: sketchUUID) }

    private let faceCentroid = SIMD3<Double>(10, 20, 30)

    // MARK: - Fixtures

    private func makeFaceRef() -> FaceRef {
        FaceRef(
            body: BodyRef(producer: producer, bodyID: bodyID),
            creator: creator,
            role: .boxFace(.pz),
            signature: FaceSignature(
                kind: .planar,
                normal: SIMD3<Double>(0, 1, 0),
                centroid: faceCentroid,
                area: 600,
                planeOffset: 20
            ),
            elementName: ElementName(
                creator: creator,
                source: .primitiveFace(.boxFace(.pz))
            )
        )
    }

    private func makeFrame() throws -> PlaneAttachmentFrame {
        try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid,
            faceNormal: SIMD3<Double>(0, 1, 0),
            referenceXAxis: SIMD3<Double>(1, 0, 0),
            anchorPoint: SIMD3<Double>(13, 20, 34)
        )
    }

    private func makeDefinition(
        version: Int = OffsetPlaneDefinition.supportedVersion,
        writer: FeatureID? = nil,
        distance: Expr = Expr(value: 5),
        sourceVersionBody: BodyID? = nil
    ) throws -> OffsetPlaneDefinition {
        OffsetPlaneDefinition(
            version: version,
            source: makeFaceRef(),
            sourceVersion: GeometryVersionRef(
                bodyID: sourceVersionBody ?? bodyID,
                writer: writer ?? self.writer
            ),
            distance: distance,
            attachment: try makeFrame()
        )
    }

    private func makeSourceFace(
        body: BodyID? = nil,
        centroid: SIMD3<Double>? = nil,
        normal: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
    ) -> SourceFaceGeometry {
        SourceFaceGeometry(
            bodyID: body ?? bodyID,
            centroid: centroid ?? faceCentroid,
            normal: normal
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertVector(
        _ actual: SIMD3<Double>,
        _ expected: SIMD3<Double>,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func assertOrthonormalRightHanded(
        _ plane: SketchPlane,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(simd_length(plane.xAxis), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_length(plane.yAxis), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_dot(plane.xAxis, plane.yAxis), 0, accuracy: 1e-9, file: file, line: line)
        assertVector(simd_cross(plane.xAxis, plane.yAxis), plane.normal,
                     accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - Legacy shape

    func testLegacyValuesDecodeAndEncodeWithoutAssociativeFields() throws {
        let plane = ConstructionPlane(id: planeID, plane: .worldXY, size: 120)
        XCTAssertNil(plane.definition)

        let planeData = try encoder().encode(plane)
        let planeText = try XCTUnwrap(String(data: planeData, encoding: .utf8))
        XCTAssertFalse(planeText.contains("definition"),
                       "a nil definition must be omitted, not encoded as null")
        let planeObject = try jsonObject(planeData)
        XCTAssertEqual(Set(planeObject.keys), Set(["id", "plane", "size", "isHidden"]),
                       "the legacy ConstructionPlane key set must not grow")
        let decodedPlane = try JSONDecoder().decode(ConstructionPlane.self, from: planeData)
        XCTAssertEqual(decodedPlane, plane)
        XCTAssertNil(decodedPlane.definition)
        XCTAssertEqual(try encoder().encode(decodedPlane), planeData,
                       "legacy ConstructionPlane must re-encode byte-identically")

        // A pre-A8 plane has no isHidden either; both nil/default fields must
        // keep the legacy behavior.
        let legacyPlaneJSON = """
        {"id":{"raw":"\(planeUUID.uuidString)"},"plane":\
        {"origin":[0,0,0],"xAxis":[1,0,0],"yAxis":[0,1,0]},"size":80}
        """
        let legacyPlane = try JSONDecoder().decode(
            ConstructionPlane.self, from: Data(legacyPlaneJSON.utf8))
        XCTAssertNil(legacyPlane.definition)
        XCTAssertFalse(legacyPlane.isHidden)
        XCTAssertEqual(legacyPlane.size, 80)

        let sketch = Sketch(id: sketchID, name: "Base", plane: .worldXY)
        XCTAssertNil(sketch.support)
        let sketchData = try encoder().encode(sketch)
        let sketchText = try XCTUnwrap(String(data: sketchData, encoding: .utf8))
        XCTAssertFalse(sketchText.contains("support"),
                       "a nil support must be omitted, not encoded as null")
        let sketchObject = try jsonObject(sketchData)
        XCTAssertEqual(Set(sketchObject.keys), Set([
            "id", "name", "plane", "entities", "isHidden", "constructionEntityIDs",
            "constraints", "dimensions", "patternLinks", "rectangleSizingAnchors",
            "disconnectedEndpoints", "rotatedRectangleEdges", "circleRadiusDirections",
            "lineDimensionKinds",
        ]), "the legacy Sketch key set must not grow")
        let decodedSketch = try JSONDecoder().decode(Sketch.self, from: sketchData)
        XCTAssertNil(decodedSketch.support)
        XCTAssertEqual(decodedSketch, sketch)
        XCTAssertEqual(try encoder().encode(decodedSketch), sketchData,
                       "legacy Sketch must re-encode byte-identically")

        let legacySketchJSON = """
        {"id":{"raw":"\(sketchUUID.uuidString)"},"plane":\
        {"origin":[0,0,0],"xAxis":[1,0,0],"yAxis":[0,1,0]},"entities":[]}
        """
        let legacySketch = try JSONDecoder().decode(
            Sketch.self, from: Data(legacySketchJSON.utf8))
        XCTAssertNil(legacySketch.support)
        XCTAssertEqual(legacySketch.name, "Sketch")
        XCTAssertFalse(legacySketch.isHidden)
    }

    // MARK: - Complete value round-trip

    func testCompleteDefinitionAndSupportRoundTrip() throws {
        let definition = try makeDefinition(
            distance: Expr(value: -2.5, formula: "plateOffset"))
        let plane = ConstructionPlane(
            id: planeID,
            plane: .worldXY,
            size: 200,
            isHidden: true,
            definition: .offset(definition)
        )
        let sketch = Sketch(
            id: sketchID,
            name: "Offset sketch",
            plane: .worldXY,
            support: PlaneRef(source: .construction(planeID))
        )

        let planeData = try encoder().encode(plane)
        let planeObject = try jsonObject(planeData)
        XCTAssertNotNil(planeObject["definition"])
        let decodedPlane = try JSONDecoder().decode(ConstructionPlane.self, from: planeData)
        XCTAssertEqual(decodedPlane, plane)
        XCTAssertEqual(decodedPlane.definition?.kind, .offset)
        XCTAssertEqual(decodedPlane.definition?.semanticVersion, 1)

        guard case let .offset(decodedDefinition)? = decodedPlane.definition else {
            return XCTFail("expected an offset definition after round-trip")
        }
        XCTAssertEqual(decodedDefinition, definition)
        XCTAssertEqual(decodedDefinition.version, 1)
        XCTAssertEqual(decodedDefinition.distance.value, -2.5)
        XCTAssertEqual(decodedDefinition.distance.formula, "plateOffset")
        XCTAssertEqual(decodedDefinition.sourceVersion.bodyID, bodyID)
        XCTAssertEqual(decodedDefinition.sourceVersion.writer, writer)
        XCTAssertEqual(decodedDefinition.source.elementName?.creator, creator)
        XCTAssertEqual(decodedDefinition.attachment, try makeFrame())
        // The actual writer and the naming provenance are different contracts.
        XCTAssertNotEqual(decodedDefinition.sourceVersion.writer,
                          decodedDefinition.source.body.producer)

        let sketchData = try encoder().encode(sketch)
        let sketchObject = try jsonObject(sketchData)
        XCTAssertNotNil(sketchObject["support"])
        let decodedSketch = try JSONDecoder().decode(Sketch.self, from: sketchData)
        XCTAssertEqual(decodedSketch, sketch)
        XCTAssertEqual(decodedSketch.support,
                       PlaneRef(source: .construction(planeID)))

        XCTAssertEqual(try encoder().encode(decodedPlane), planeData)
        XCTAssertEqual(try encoder().encode(decodedSketch), sketchData)
    }

    func testWriterIsIndependentOfProvenanceAndDoesNotChangeResolution() throws {
        let face = makeSourceFace()
        let first = try makeDefinition(writer: writer)
        let second = try makeDefinition(writer: otherWriter)
        XCTAssertEqual(first.source.body.producer, producer)
        XCTAssertNotEqual(first.sourceVersion, second.sourceVersion)
        XCTAssertNotEqual(first, second)

        let firstPlane = try first.resolvedPlane(face: face, bodyTransform: .identity)
        let secondPlane = try second.resolvedPlane(face: face, bodyTransform: .identity)
        XCTAssertEqual(firstPlane, secondPlane,
                       "resolution takes the source face from the caller; it must not re-derive or compare the writer")

        // A writer identical to the producer is legal too — but the field is
        // the actual writer, not a copy of provenance.
        let provenanceWriter = try makeDefinition(writer: producer)
        XCTAssertEqual(try provenanceWriter.resolvedPlane(face: face, bodyTransform: .identity),
                       firstPlane)
    }

    // MARK: - Unsupported definitions

    func testUnsupportedDefinitionKindAndVersionAreRejected() throws {
        let plane = ConstructionPlane(
            id: planeID, plane: .worldXY, size: 100,
            definition: .offset(try makeDefinition()))
        let data = try encoder().encode(plane)
        let root = try jsonObject(data)
        let definition = try XCTUnwrap(root["definition"] as? [String: Any])
        let offset = try XCTUnwrap(definition["offset"] as? [String: Any])

        var futureVersion = root
        var futureVersionDefinition = definition
        var futureVersionOffset = offset
        futureVersionOffset["version"] = 2
        futureVersionDefinition["offset"] = futureVersionOffset
        futureVersion["definition"] = futureVersionDefinition
        let futureVersionData = try JSONSerialization.data(withJSONObject: futureVersion)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConstructionPlane.self, from: futureVersionData)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .unsupportedSemanticVersion(2))
        }

        var futureKind = root
        var futureKindDefinition = definition
        futureKindDefinition["kind"] = "projected"
        futureKind["definition"] = futureKindDefinition
        let futureKindData = try JSONSerialization.data(withJSONObject: futureKind)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConstructionPlane.self, from: futureKindData)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .unsupportedDefinitionKind("projected"))
        }

        // The same guarantee when the definition is decoded directly: a
        // present, unsupported payload never becomes an empty/absent value.
        XCTAssertThrowsError(try JSONDecoder().decode(
            ConstructionPlaneDefinition.self,
            from: Data(#"{"kind":"future"}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .unsupportedDefinitionKind("future"))
        }

        // Programmatic values are validated before geometry is touched.
        let constructedFuture = try makeDefinition(version: 2)
        XCTAssertThrowsError(try constructedFuture.resolvedPlane(
            face: makeSourceFace(), bodyTransform: .identity)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .unsupportedSemanticVersion(2))
        }

        // The opaque/read-only classification is explicit for package C:
        // unsupported semantics never mean "treat the cached plane as valid".
        XCTAssertTrue(AssociativeGeometryError.unsupportedSemanticVersion(2)
            .requiresOpaqueReadOnlyDocument)
        XCTAssertTrue(AssociativeGeometryError.unsupportedDefinitionKind("future")
            .requiresOpaqueReadOnlyDocument)
    }

    // MARK: - Body identity & semantic validation

    func testBodyIdentityMismatchesAreRejected() throws {
        let face = makeSourceFace()

        let mismatchedVersion = try makeDefinition(sourceVersionBody: otherBodyID)
        XCTAssertThrowsError(try mismatchedVersion.validate()) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .sourceVersionBodyMismatch(
                               source: bodyID, version: otherBodyID))
        }
        XCTAssertThrowsError(try mismatchedVersion.resolvedPlane(
            face: face, bodyTransform: .identity)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .sourceVersionBodyMismatch(
                               source: bodyID, version: otherBodyID))
        }

        let definition = try makeDefinition()
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: makeSourceFace(body: otherBodyID), bodyTransform: .identity)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .faceBodyMismatch(expected: bodyID, actual: otherBodyID))
        }
        XCTAssertFalse(AssociativeGeometryError.faceBodyMismatch(
            expected: bodyID, actual: otherBodyID).requiresOpaqueReadOnlyDocument)

        let nonFiniteDistance = try makeDefinition(
            distance: Expr(value: .nan))
        XCTAssertThrowsError(try nonFiniteDistance.validate()) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .nonFiniteValue("offset distance"))
        }
    }

    // MARK: - Attachment frame creation and validation

    func testAttachmentFrameCreationAndValidation() throws {
        let frame = try makeFrame()
        assertVector(frame.normal, SIMD3<Double>(0, 1, 0), accuracy: 1e-12)
        assertVector(frame.xAxis, SIMD3<Double>(1, 0, 0), accuracy: 1e-12)
        assertVector(frame.yAxis, SIMD3<Double>(0, 0, -1), accuracy: 1e-12)
        XCTAssertEqual(frame.anchorOffset.x, 3, accuracy: 1e-12)
        XCTAssertEqual(frame.anchorOffset.y, -4, accuracy: 1e-12)
        try frame.validate()

        // The reference axis is projected, and an out-of-plane anchor pick is
        // stored only through its in-plane components.
        let projected = try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid,
            faceNormal: SIMD3<Double>(0, 2, 0),
            referenceXAxis: SIMD3<Double>(1, 1, 0),
            anchorPoint: SIMD3<Double>(13, 25, 34)
        )
        assertVector(projected.normal, SIMD3<Double>(0, 1, 0), accuracy: 1e-12)
        assertVector(projected.xAxis, SIMD3<Double>(1, 0, 0), accuracy: 1e-12)
        XCTAssertEqual(projected.anchorOffset.x, 3, accuracy: 1e-12)
        XCTAssertEqual(projected.anchorOffset.y, -4, accuracy: 1e-12)

        // An already in-plane diagonal must retain its direction. It is not
        // projected onto a world axis or substituted with the readable basis.
        let diagonal = try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid, faceNormal: SIMD3<Double>(0, 2, 0),
            referenceXAxis: SIMD3<Double>(1, 0, 1),
            anchorPoint: SIMD3<Double>(13, 25, 34))
        let halfRoot = sqrt(0.5)
        assertVector(diagonal.xAxis, SIMD3<Double>(halfRoot, 0, halfRoot), accuracy: 1e-12)
        assertVector(diagonal.yAxis, SIMD3<Double>(halfRoot, 0, -halfRoot), accuracy: 1e-12)
        XCTAssertEqual(diagonal.anchorOffset.x, 7 * halfRoot, accuracy: 1e-12)
        XCTAssertEqual(diagonal.anchorOffset.y, -halfRoot, accuracy: 1e-12)

        XCTAssertThrowsError(try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid,
            faceNormal: SIMD3<Double>(0, 1, 0),
            referenceXAxis: SIMD3<Double>(0, 2, 0))
        ) { error in
            guard case .degenerateFaceGeometry = error as? AssociativeGeometryError else {
                return XCTFail("expected degenerateFaceGeometry, got \(error)")
            }
        }
        XCTAssertThrowsError(try PlaneAttachmentFrame.make(
            faceCentroid: faceCentroid,
            faceNormal: .zero,
            referenceXAxis: SIMD3<Double>(1, 0, 0))
        ) { error in
            guard case .degenerateFaceGeometry = error as? AssociativeGeometryError else {
                return XCTFail("expected degenerateFaceGeometry, got \(error)")
            }
        }

        let nonUnit = PlaneAttachmentFrame(
            normal: SIMD3<Double>(0, 2, 0),
            xAxis: SIMD3<Double>(1, 0, 0),
            anchorOffset: SIMD2<Double>(0, 0))
        XCTAssertThrowsError(try nonUnit.validate()) { error in
            guard case .invalidAttachmentFrame = error as? AssociativeGeometryError else {
                return XCTFail("expected invalidAttachmentFrame, got \(error)")
            }
        }

        let nonOrthogonal = PlaneAttachmentFrame(
            normal: SIMD3<Double>(0, 1, 0),
            xAxis: simd_normalize(SIMD3<Double>(1, 1, 0)),
            anchorOffset: SIMD2<Double>(0, 0))
        XCTAssertThrowsError(try nonOrthogonal.validate()) { error in
            guard case .invalidAttachmentFrame = error as? AssociativeGeometryError else {
                return XCTFail("expected invalidAttachmentFrame, got \(error)")
            }
        }

        let nonFinite = PlaneAttachmentFrame(
            normal: SIMD3<Double>(.nan, 1, 0),
            xAxis: SIMD3<Double>(1, 0, 0),
            anchorOffset: SIMD2<Double>(0, 0))
        XCTAssertThrowsError(try nonFinite.validate()) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .nonFiniteValue("attachment normal"))
        }

        let nonFiniteAnchor = PlaneAttachmentFrame(
            normal: SIMD3<Double>(0, 1, 0),
            xAxis: SIMD3<Double>(1, 0, 0),
            anchorOffset: SIMD2<Double>(.infinity, 0))
        XCTAssertThrowsError(try nonFiniteAnchor.validate()) { error in
            guard case .invalidAttachmentFrame = error as? AssociativeGeometryError else {
                return XCTFail("expected invalidAttachmentFrame, got \(error)")
            }
        }
    }

    // MARK: - World-space resolution

    func testResolutionAppliesRotationScaleAndWorldMillimetreOffset() throws {
        let definition = try makeDefinition(distance: Expr(value: 5))
        let rotation = simd_quatd(angle: .pi / 2, axis: SIMD3<Double>(0, 0, 1))
        var transform = Transform3D()
        transform.translation = SIMD3<Double>(100, -50, 7)
        transform.rotation = rotation
        transform.scale = 2.5

        let plane = try definition.resolvedPlane(
            face: makeSourceFace(), bodyTransform: transform)

        // Body-local anchor = centroid + 3·x - 4·y = (13, 20, 34).
        // Scale 2.5 → (32.5, 50, 85), rotate +90° about Z → (-50, 32.5, 85),
        // translate → (50, -17.5, 92). The 5 mm offset is applied in WORLD
        // millimetres along the rotated unit normal (-1, 0, 0) → (45, …).
        assertVector(plane.origin, SIMD3<Double>(45, -17.5, 92), accuracy: 1e-9)
        assertVector(plane.normal, SIMD3<Double>(-1, 0, 0), accuracy: 1e-9)
        assertVector(plane.xAxis, SIMD3<Double>(0, 1, 0), accuracy: 1e-9)
        assertVector(plane.yAxis, SIMD3<Double>(0, 0, -1), accuracy: 1e-9)
        assertOrthonormalRightHanded(plane)

        // Regression guard against double-scaling: putting the offset into
        // body-local space first would move x to 37.5, i.e. 5·(2.5−1).
        let doubleScaledLocal = bodyLocalDoubleScaledOrigin(transform: transform)
        XCTAssertNotEqual(plane.origin.x, doubleScaledLocal, accuracy: 1e-9)
        XCTAssertEqual(plane.origin.x - doubleScaledLocal, 7.5, accuracy: 1e-9)

        // The basis follows the stored reference axis rotated by the body
        // transform, NOT a world "readable" heuristic. `readable` for the
        // world normal (-1,0,0) would choose x = (0,0,1); the frozen frame
        // keeps (0,1,0).
        let readable = SketchPlane.readable(origin: plane.origin, normal: plane.normal)
        XCTAssertNotEqual(plane.xAxis, readable.xAxis)
    }

    /// The wrong (body-local) offset placement the adapter must never do:
    /// `transform(anchor + normal * distance)`, which multiplies the offset
    /// by the body scale. Kept explicit so the assertion reads as a contract.
    private func bodyLocalDoubleScaledOrigin(transform: Transform3D) -> Double {
        let localAnchor = faceCentroid
            + SIMD3<Double>(1, 0, 0) * 3
            + SIMD3<Double>(0, 0, -1) * -4
        let wrongLocal = localAnchor + SIMD3<Double>(0, 1, 0) * 5
        return transform.applying(to: wrongLocal).x
    }

    func testSignedZeroAndNegativeOffsets() throws {
        let definition = try makeDefinition()
        let face = makeSourceFace()
        let rotation = simd_quatd(
            angle: .pi / 3, axis: simd_normalize(SIMD3<Double>(1, 2, 3)))
        var transform = Transform3D()
        transform.translation = SIMD3<Double>(-4, 8, 12)
        transform.rotation = rotation
        transform.scale = 1.75

        let zero = try makeDefinition(distance: Expr(value: 0))
            .resolvedPlane(face: face, bodyTransform: transform)
        let signedZero = try makeDefinition(distance: Expr(value: -0.0))
            .resolvedPlane(face: face, bodyTransform: transform)
        XCTAssertEqual(zero.origin, signedZero.origin)
        XCTAssertEqual(zero.xAxis, signedZero.xAxis)
        XCTAssertEqual(zero.yAxis, signedZero.yAxis)

        let positive = try makeDefinition(distance: Expr(value: 5))
            .resolvedPlane(face: face, bodyTransform: transform)
        let negative = try makeDefinition(distance: Expr(value: -5))
            .resolvedPlane(face: face, bodyTransform: transform)
        assertVector(positive.origin, zero.origin + zero.normal * 5)
        assertVector(negative.origin, zero.origin - zero.normal * 5)
        assertVector(positive.origin + negative.origin, zero.origin * 2)
        XCTAssertEqual(definition.distance.value, 5)
    }

    func testOppositeNormalsAreDeterministicAndCollapsedAxisIsRejected() throws {
        let definition = try makeDefinition(distance: Expr(value: 5))
        let opposite = makeSourceFace(normal: SIMD3<Double>(0, -1, 0))
        let plane = try definition.resolvedPlane(
            face: opposite, bodyTransform: .identity)

        // Projecting x = (1,0,0) into the flipped plane keeps x; y flips:
        // y' = n' × x = (0,-1,0) × (1,0,0) = (0,0,1), a proper 180° rotation
        // about the frozen x axis. Anchor = (13,20,26); +5 along n'.
        assertVector(plane.origin, SIMD3<Double>(13, 15, 26), accuracy: 1e-9)
        assertVector(plane.normal, SIMD3<Double>(0, -1, 0), accuracy: 1e-9)
        assertVector(plane.xAxis, SIMD3<Double>(1, 0, 0), accuracy: 1e-9)
        assertVector(plane.yAxis, SIMD3<Double>(0, 0, 1), accuracy: 1e-9)
        assertOrthonormalRightHanded(plane)

        // Same call twice is bit-identical (simd math is deterministic).
        XCTAssertEqual(plane, try definition.resolvedPlane(
            face: opposite, bodyTransform: .identity))

        // Current normal parallel to the frozen x axis: the in-plane
        // projection collapses, so no unique frame exists → explicit failure.
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: makeSourceFace(normal: SIMD3<Double>(1, 0, 0)),
            bodyTransform: .identity)
        ) { error in
            guard case .degenerateFaceGeometry = error as? AssociativeGeometryError else {
                return XCTFail("expected degenerateFaceGeometry, got \(error)")
            }
        }
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: makeSourceFace(normal: SIMD3<Double>(1, 0, 1e-9)),
            bodyTransform: .identity)
        ) { error in
            guard case .degenerateFaceGeometry = error as? AssociativeGeometryError else {
                return XCTFail("expected degenerateFaceGeometry, got \(error)")
            }
        }
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: makeSourceFace(normal: .zero),
            bodyTransform: .identity)
        ) { error in
            guard case .degenerateFaceGeometry = error as? AssociativeGeometryError else {
                return XCTFail("expected degenerateFaceGeometry, got \(error)")
            }
        }
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: makeSourceFace(normal: SIMD3<Double>(.nan, 1, 0)),
            bodyTransform: .identity)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .nonFiniteValue("face normal"))
        }
    }

    func testInvalidBodyTransformsAreRejected() throws {
        let definition = try makeDefinition()
        let face = makeSourceFace()

        for scale in [0.0, -1.0, Double.infinity] {
            var transform = Transform3D()
            transform.scale = scale
            XCTAssertThrowsError(try definition.resolvedPlane(
                face: face, bodyTransform: transform)
            ) { error in
                guard case .invalidBodyTransform = error as? AssociativeGeometryError else {
                    return XCTFail("expected invalidBodyTransform, got \(error)")
                }
            }
        }

        var nonFiniteTranslation = Transform3D()
        nonFiniteTranslation.translation = SIMD3<Double>(.nan, 0, 0)
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: face, bodyTransform: nonFiniteTranslation)
        ) { error in
            XCTAssertEqual(error as? AssociativeGeometryError,
                           .nonFiniteValue("body translation"))
        }

        var nonUnitRotation = Transform3D()
        nonUnitRotation.rotation = simd_quatd(ix: 1, iy: 0, iz: 0, r: 1)
        XCTAssertThrowsError(try definition.resolvedPlane(
            face: face, bodyTransform: nonUnitRotation)
        ) { error in
            guard case .invalidBodyTransform = error as? AssociativeGeometryError else {
                return XCTFail("expected invalidBodyTransform, got \(error)")
            }
        }
    }

    // MARK: - Determinism / centroid-relative anchor

    func testResolutionIsDeterministicAndCentroidRelative() throws {
        let definition = try makeDefinition()
        let face = makeSourceFace()
        var transform = Transform3D()
        transform.translation = SIMD3<Double>(5, -3, 2)
        transform.rotation = simd_quatd(angle: 0.7, axis: SIMD3<Double>(0, 1, 0))
        transform.scale = 1.4

        let cold = try definition.resolvedPlane(face: face, bodyTransform: transform)

        // Resolve a different (moved) face in between. There is no cache, so
        // the next call must ignore it entirely.
        let shiftedCentroid = faceCentroid + SIMD3<Double>(2, 0, 1)
        let moved = try definition.resolvedPlane(
            face: makeSourceFace(centroid: shiftedCentroid),
            bodyTransform: transform)

        let hot = try definition.resolvedPlane(face: face, bodyTransform: transform)
        XCTAssertEqual(cold, hot)
        XCTAssertEqual(cold, try definition.resolvedPlane(
            face: makeSourceFace(), bodyTransform: transform))

        // The anchor is relative to the face centroid: an in-plane centroid
        // shift translates the resolved origin by the transformed shift and
        // leaves the basis untouched.
        assertVector(moved.xAxis, cold.xAxis, accuracy: 1e-12)
        assertVector(moved.yAxis, cold.yAxis, accuracy: 1e-12)
        let expectedShift = transform.rotation.act(
            SIMD3<Double>(2, 0, 1) * transform.scale)
        assertVector(moved.origin - cold.origin, expectedShift, accuracy: 1e-9)
        // A definition decoded from disk gives the same result as the live
        // value — no in-memory-only field participates in resolution.
        let decoded = try JSONDecoder().decode(
            OffsetPlaneDefinition.self, from: try encoder().encode(definition))
        XCTAssertEqual(try decoded.resolvedPlane(face: face, bodyTransform: transform),
                       cold)
    }
}
