import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeMergeTests: XCTestCase {
    private var revision: UInt64 = 0

    private struct Fixture {
        var document: DesignDocument
        var producer: FeatureID
        var writer: FeatureID
        var body: BodyID
        var entity: UUID
        var sourceTransform: Transform3D
        var definition: OffsetPlaneDefinition
    }

    private func nextRevision() -> UInt64 { revision += 1; return revision }

    private func fixture() throws -> Fixture {
        let entity = UUID()
        let base = Sketch(name: "Source profile", plane: .ground, entities: [
            .rect(id: entity, min: SIMD2(0, 0), max: SIMD2(40, 30))
        ])
        let body = BodyID()
        let source = FeatureNode(name: "Source extrusion", kind: .extrude(
            profile: ProfileRef(sketchID: base.id, entityIDs: [entity],
                                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(base.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
        var delta = Transform3D()
        delta.translation = SIMD3(7, 11, -13)
        delta.rotation = simd_quatd(angle: .pi / 3, axis: SIMD3(0, 0, 1))
        delta.scale = 1.5
        let writer = FeatureNode(name: "Source placement", kind: .transform(
            body: BodyRef(producer: source.id, bodyID: body), delta: delta),
            // The actual writer is independent of its output placeholder.
            outputBodyIDs: [BodyID()])
        let graph = FeatureGraph(nodes: [source, writer])
        let result = graph.evaluate(sketches: [base], planes: [], naming: SignatureNaming(),
                                    nextRevision: nextRevision)
        XCTAssertTrue(result.errors.isEmpty)
        let solid = try XCTUnwrap(result.bodies.first { $0.id == body })
        let brep = try XCTUnwrap(solid.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let name = try XCTUnwrap(result.kernelNames[body]?[face.index])
        let frame = try PlaneAttachmentFrame.make(
            faceCentroid: face.centroid, faceNormal: face.normal,
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: face.centroid + SIMD3(2, 0, 3))
        let definition = OffsetPlaneDefinition(
            source: FaceRef(body: BodyRef(producer: source.id, bodyID: body),
                            creator: name.creator, role: .extrudeEndCap,
                            signature: try XCTUnwrap(face.signature), elementName: name),
            sourceVersion: GeometryVersionRef(bodyID: body, writer: writer.id),
            distance: Expr(value: 4), attachment: frame)
        let plane = try definition.resolvedPlane(
            face: SourceFaceGeometry(bodyID: body, centroid: face.centroid, normal: face.normal),
            bodyTransform: solid.transform)
        let datum = ConstructionPlane(plane: plane, size: 80, definition: .offset(definition))
        let supported = Sketch(name: "Supported profile", plane: plane,
                               support: PlaneRef(source: .construction(datum.id)))
        var document = DesignDocument()
        document.features = graph
        document.bodies = result.bodies
        document.sketches = [base, supported]
        document.planes = [datum]
        return Fixture(document: document, producer: source.id, writer: writer.id,
                       body: body, entity: entity, sourceTransform: solid.transform,
                       definition: definition)
    }

    private func offset(_ plane: ConstructionPlane) throws -> OffsetPlaneDefinition {
        guard case let .offset(value)? = plane.definition else {
            throw XCTUnwrapError.missingDefinition
        }
        return value
    }

    private enum XCTUnwrapError: Error { case missingDefinition }

    private func assertVector(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-8, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-8, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-8, file: file, line: line)
    }

    func testCollidingHostIDsRemapSourceWriterSupportAndRecursiveNames() async throws {
        var fixture = try fixture()
        var definition = fixture.definition
        var source = definition.source
        source.elementName = ElementName(creator: fixture.writer, source: .opFace(
            operation: fixture.writer, parents: [
                ElementName(creator: fixture.producer,
                            source: .profileWall(entity: fixture.entity, occurrence: 2)),
                ElementName(creator: fixture.producer, source: .profileCap(end: true))
            ], index: 3))
        definition = OffsetPlaneDefinition(source: source, sourceVersion: definition.sourceVersion,
                                           distance: definition.distance, attachment: definition.attachment)
        fixture.document.planes[0].definition = .offset(definition)
        let shift = SIMD3<Double>(21, -8, 6)
        let insertion = try ProjectMergeKit.insert(fixture.document, into: fixture.document,
                                                   translation: shift)
        let inserted = try offset(XCTUnwrap(insertion.document.planes.last))
        let newProducer = insertion.featureIDs[0]
        let newWriter = insertion.featureIDs[1]
        XCTAssertNotEqual(newProducer, fixture.producer)
        XCTAssertNotEqual(newWriter, fixture.writer)
        XCTAssertEqual(inserted.source.body.producer, newProducer)
        XCTAssertEqual(inserted.sourceVersion.writer, newWriter)
        XCTAssertNotEqual(inserted.sourceVersion.writer, inserted.source.body.producer)
        XCTAssertNotEqual(inserted.sourceVersion.bodyID, fixture.body)
        XCTAssertEqual(inserted.source.body.bodyID, inserted.sourceVersion.bodyID)
        XCTAssertEqual(inserted.attachment, definition.attachment)
        XCTAssertEqual(inserted.distance, definition.distance)
        assertVector(inserted.source.signature.centroid, source.signature.centroid + shift)
        XCTAssertEqual(inserted.source.signature.planeOffset,
                       source.signature.planeOffset + simd_dot(source.signature.normal, shift),
                       accuracy: 1e-9)
        let name = try XCTUnwrap(inserted.source.elementName)
        XCTAssertEqual(name.creator, newWriter)
        guard case let .opFace(operation, parents, index) = name.source,
              case let .profileWall(entity, occurrence) = parents[0].source else {
            return XCTFail("Recursive element name lost")
        }
        XCTAssertEqual(operation, newWriter)
        XCTAssertEqual(index, 3)
        XCTAssertEqual(parents[0].creator, newProducer)
        XCTAssertNotEqual(entity, fixture.entity)
        XCTAssertEqual(entity, insertion.document.sketches[2].entities[0].id)
        XCTAssertEqual(occurrence, 2)
        XCTAssertEqual(insertion.document.sketches.last?.support,
                       PlaneRef(source: .construction(try XCTUnwrap(insertion.document.planes.last).id)))
        XCTAssertNotEqual(insertion.document.planes.last?.id, fixture.document.planes[0].id)
    }

    func testRealReplayTranslatesRotatedScaledSourceAndDatumExactlyOnce() async throws {
        let fixture = try fixture()
        let shift = SIMD3<Double>(31, -17, 23)
        let insertion = try ProjectMergeKit.insert(fixture.document, into: DesignDocument(),
                                                   translation: shift)
        let merged = insertion.document
        let definition = try offset(XCTUnwrap(merged.planes.first))
        let result = merged.features.evaluate(sketches: merged.sketches, planes: merged.planes,
                                              naming: SignatureNaming(), nextRevision: nextRevision)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.referenceErrors.isEmpty)
        let plane = try XCTUnwrap(result.resolvedPlaneUpdates[merged.planes[0].id])
        assertVector(plane.origin, fixture.document.planes[0].plane.origin + shift)
        assertVector(plane.xAxis, fixture.document.planes[0].plane.xAxis)
        assertVector(plane.yAxis, fixture.document.planes[0].plane.yAxis)
        let source = try XCTUnwrap(result.bodies.first { $0.id == definition.sourceVersion.bodyID })
        // Extrude planes bake insertion into BRep coordinates, whereas the
        // cached body carries it in TRS. Compare actual world geometry, not
        // those deliberately different representations.
        let rebuiltBRep = try XCTUnwrap(source.brep)
        let rebuiltFace = try XCTUnwrap(OCCTKernel.faceInfo(rebuiltBRep).first { $0.normal.y > 0.99 })
        let originalCentroid = fixture.definition.source.signature.centroid
        let expectedWorld = fixture.sourceTransform.applying(to: originalCentroid) + shift
        assertVector(source.transform.applying(to: rebuiltFace.centroid), expectedWorld)
        XCTAssertEqual(source.transform.scale, fixture.sourceTransform.scale)
        XCTAssertEqual(definition.attachment, fixture.definition.attachment)
        XCTAssertEqual(result.resolvedSketchSupportUpdates[merged.sketches[1].id], plane)
        let cached = try XCTUnwrap(merged.bodies.first { $0.id == definition.sourceVersion.bodyID })
        assertVector(cached.transform.applying(to: originalCentroid), expectedWorld)
    }

    func testAssociativeVariableCollisionIsCaseInsensitiveAndLeavesInputsUntouched() async throws {
        var fixture = try fixture()
        fixture.document.variables = [Variable(name: "Gap", expression: "4", value: 4)]
        var host = DesignDocument()
        host.variables = [Variable(name: "gap", expression: "99", value: 99)]
        XCTAssertThrowsError(try ProjectMergeKit.insert(fixture.document, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError,
                           .associativeVariableCollision(["Gap"]))
        }
        XCTAssertTrue(host.features.nodes.isEmpty)
        XCTAssertEqual(host.variables[0].value, 99)
        XCTAssertEqual(fixture.document.variables[0].value, 4)
    }

    func testAssociativeVariableIdentitiesAreRemintedWithoutChangingFormula() async throws {
        var fixture = try fixture()
        let variable = Variable(name: "gap", expression: "4", value: 4)
        fixture.document.variables = [variable]
        let insertion = try ProjectMergeKit.insert(fixture.document, into: DesignDocument())
        let inserted = try XCTUnwrap(insertion.document.variables.first)
        XCTAssertNotEqual(inserted.id, variable.id)
        XCTAssertEqual(inserted.name, variable.name)
        XCTAssertEqual(inserted.expression, variable.expression)
        XCTAssertEqual(inserted.value, variable.value)
    }

    func testMissingGuestWriterCannotBindToSameUUIDInHost() async throws {
        var fixture = try fixture()
        let external = FeatureNode(name: "Host only", kind: .primitive(
            spec: .box(width: 1, depth: 1, height: 1), placement: .identity),
            outputBodyIDs: [BodyID()])
        let bad = OffsetPlaneDefinition(source: fixture.definition.source,
                                        sourceVersion: GeometryVersionRef(bodyID: fixture.body,
                                                                          writer: external.id),
                                        distance: fixture.definition.distance,
                                        attachment: fixture.definition.attachment)
        fixture.document.planes[0].definition = .offset(bad)
        var host = DesignDocument()
        host.features = FeatureGraph(nodes: [external])
        XCTAssertThrowsError(try ProjectMergeKit.insert(fixture.document, into: host)) { error in
            guard case let .missingAssociativeReferences(refs) = error as? ProjectMergeKit.MergeError else {
                return XCTFail("Expected explicit missing-reference refusal, got \(error)")
            }
            XCTAssertTrue(refs.contains("feature:\(external.id.raw.uuidString)"))
        }
        XCTAssertEqual(host.features.nodes.count, 1)
    }

    func testMissingGuestSupportCannotBindToHostPlane() async throws {
        var guest = DesignDocument()
        let hostPlane = ConstructionPlane(plane: .ground, size: 20)
        guest.sketches = [Sketch(plane: .ground,
                                 support: PlaneRef(source: .construction(hostPlane.id)))]
        var host = DesignDocument()
        host.planes = [hostPlane]
        XCTAssertThrowsError(try ProjectMergeKit.insert(guest, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError,
                           .missingAssociativeReferences(["plane:\(hostPlane.id.raw.uuidString)"]))
        }
    }

    func testMissingFeatureFormulaCannotCaptureHostVariable() async throws {
        var fixture = try fixture()
        fixture.document.features.nodes[0].kind = try XCTUnwrap(DocumentSession.replacingExpression(
            in: fixture.document.features.nodes[0].kind, named: "distance",
            with: Expr(value: 10, formula: "host_only")))
        var host = DesignDocument()
        host.variables = [Variable(name: "host_only", expression: "20", value: 20)]
        XCTAssertThrowsError(try ProjectMergeKit.insert(fixture.document, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError, .invalidAssociativeExpressions([
                "feature:\(fixture.producer.raw.uuidString):distance"
            ]))
        }
    }

    func testMissingDatumFormulaCannotCaptureHostVariable() async throws {
        var fixture = try fixture()
        var definition = fixture.definition
        definition.distance = Expr(value: 4, formula: "host_only + 1")
        fixture.document.planes[0].definition = .offset(definition)
        var host = DesignDocument()
        host.variables = [Variable(name: "host_only", expression: "20", value: 20)]
        XCTAssertThrowsError(try ProjectMergeKit.insert(fixture.document, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError, .invalidAssociativeExpressions([
                "plane:\(fixture.document.planes[0].id.raw.uuidString):distance"
            ]))
        }
    }

    func testNamedEdgesAndBooleanTargetsRemapThroughExistingHistory() async throws {
        var fixture = try fixture()
        let cap = ElementName(creator: fixture.producer, source: .profileCap(end: true))
        let wall = ElementName(creator: fixture.producer,
                               source: .profileWall(entity: fixture.entity, occurrence: 1))
        let ref = BodyRef(producer: fixture.producer, bodyID: fixture.body)
        let edge = EdgeRef(body: ref, signature: EdgeSignature(
            midpoint: SIMD3(1, 2, 3), direction: SIMD3(1, 0, 0), length: 10,
            normalA: SIMD3(0, 1, 0), normalB: SIMD3(1, 0, 0)),
            faceNames: EdgeName(faceA: cap, faceB: wall, occurrence: 0))
        fixture.document.features.nodes.append(FeatureNode(name: "Blend", kind: .fillet(
            body: ref, edges: [edge], radius: Expr(value: 1)), outputBodyIDs: [fixture.body]))
        fixture.document.features.nodes.append(FeatureNode(name: "Boolean profile", kind: .extrude(
            profile: ProfileRef(sketchID: fixture.document.sketches[0].id,
                                entityIDs: [fixture.entity], holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .ground), distance: Expr(value: 1), symmetric: false,
            boolean: BooleanIntent(op: .union, resolvedTargets: [ref]), extraProfiles: []),
            outputBodyIDs: [BodyID()]))
        let shift = SIMD3<Double>(3, 4, 5)
        let insertion = try ProjectMergeKit.insert(fixture.document, into: DesignDocument(),
                                                   translation: shift)
        guard case let .fillet(body, edges, _) = insertion.document.features.nodes[2].kind,
              case let .extrude(_, plane, _, _, intent, _) = insertion.document.features.nodes[3].kind,
              case let .explicit(ground) = plane.source else {
            return XCTFail("Inserted feature type lost")
        }
        XCTAssertNotEqual(body.bodyID, fixture.body)
        XCTAssertEqual(intent.resolvedTargets, [body])
        XCTAssertEqual(edges[0].faceNames?.faceA.creator, insertion.featureIDs[0])
        guard case let .profileWall(entity, _)? = edges[0].faceNames?.faceB.source else {
            return XCTFail("Named edge identity lost")
        }
        XCTAssertEqual(entity, insertion.document.sketches[0].entities[0].id)
        assertVector(edges[0].signature.midpoint, edge.signature.midpoint + shift)
        assertVector(ground.origin, shift)
    }

    private func plainHistory(count: Int, rollback: Int? = nil) -> DesignDocument {
        var document = DesignDocument()
        document.features = FeatureGraph(nodes: (0..<count).map { index in
            FeatureNode(name: "Plain \(index)", kind: .primitive(
                spec: .box(width: 1, depth: 1, height: 1), placement: .identity),
                outputBodyIDs: [BodyID()])
        }, rollbackIndex: rollback)
        return document
    }

    func testAssociatedHostRollbackDoesNotActivateItsSuffixForPlainGuest() async throws {
        var host = try fixture().document
        host.features.nodes += plainHistory(count: 3).features.nodes
        host.features.rollbackIndex = 2
        let guest = plainHistory(count: 3)
        let hostIDs = host.features.nodes.map(\.id)
        let guestIDs = guest.features.nodes.map(\.id)
        let originalActive = Array(host.features.nodes.prefix(2).map(\.id))
        XCTAssertThrowsError(try ProjectMergeKit.insert(guest, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError, .associativeRollback)
        }
        XCTAssertEqual(host.features.nodes.count, 5)
        XCTAssertEqual(host.features.nodes.map(\.id), hostIDs)
        XCTAssertEqual(host.features.rollbackIndex, 2)
        XCTAssertEqual(Array(host.features.nodes.prefix(host.features.rollbackIndex ?? 5).map(\.id)),
                       originalActive)
        XCTAssertEqual(guest.features.nodes.map(\.id), guestIDs)
        XCTAssertNil(guest.features.rollbackIndex)
    }

    func testAssociatedGuestRefusesPlainHostRollbackWithoutMutatingInputs() async throws {
        let guest = try fixture().document
        let host = plainHistory(count: 5, rollback: 2)
        let hostIDs = host.features.nodes.map(\.id)
        let guestIDs = guest.features.nodes.map(\.id)
        XCTAssertThrowsError(try ProjectMergeKit.insert(guest, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError, .associativeRollback)
        }
        XCTAssertEqual(host.features.nodes.map(\.id), hostIDs)
        XCTAssertEqual(host.features.rollbackIndex, 2)
        XCTAssertEqual(guest.features.nodes.map(\.id), guestIDs)
        XCTAssertNil(guest.features.rollbackIndex)
    }

    func testAssociatedGuestRollbackIsNotDiscarded() async throws {
        var guest = try fixture().document
        guest.features.rollbackIndex = 1
        let host = DesignDocument()
        let guestIDs = guest.features.nodes.map(\.id)
        XCTAssertThrowsError(try ProjectMergeKit.insert(guest, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError, .associativeRollback)
        }
        XCTAssertEqual(guest.features.rollbackIndex, 1)
        XCTAssertEqual(guest.features.nodes.map(\.id), guestIDs)
        XCTAssertTrue(host.features.nodes.isEmpty)
        XCTAssertTrue(host.planes.isEmpty)
    }

    func testLegacyPlainRollbackMergeRetainsExistingPolicy() async throws {
        let host = plainHistory(count: 5, rollback: 2)
        let guest = plainHistory(count: 3, rollback: 1)
        let insertion = try ProjectMergeKit.insert(guest, into: host)
        // Frozen legacy behavior is outside this association-only safeguard.
        XCTAssertEqual(insertion.document.features.rollbackIndex, 5)
        XCTAssertEqual(insertion.document.features.nodes.count, 8)
        XCTAssertEqual(Array(insertion.document.features.nodes.prefix(5).map(\.id)),
                       host.features.nodes.map(\.id))
        XCTAssertEqual(host.features.rollbackIndex, 2)
        XCTAssertEqual(guest.features.rollbackIndex, 1)
    }

    func testLegacyAbsoluteMergeKeepsVariableCollisionPolicyAndNoAssociation() async throws {
        let plane = ConstructionPlane(plane: .ground, size: 20)
        let variable = Variable(name: "width", expression: "5", value: 5)
        var guest = DesignDocument()
        guest.sketches = [Sketch(plane: .ground)]
        guest.planes = [plane]
        guest.variables = [variable]
        var host = DesignDocument()
        host.variables = [Variable(name: "width", expression: "10", value: 10)]
        let shift = SIMD3<Double>(2, 3, 4)
        let insertion = try ProjectMergeKit.insert(guest, into: host, translation: shift)
        XCTAssertNil(insertion.document.planes[0].definition)
        XCTAssertNil(insertion.document.sketches[0].support)
        assertVector(insertion.document.planes[0].plane.origin, shift)
        XCTAssertEqual(insertion.document.variables, host.variables)
        XCTAssertEqual(ProjectMergeKit.droppedVariableNames(inserting: guest, into: host), ["width"])
        XCTAssertNotEqual(insertion.document.planes[0].id, plane.id)
    }
}
