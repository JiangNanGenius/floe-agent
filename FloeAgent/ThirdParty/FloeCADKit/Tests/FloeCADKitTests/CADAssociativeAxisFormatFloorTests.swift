//
//  CADAssociativeAxisFormatFloorTests.swift
//  FloeCADKitTests
//
//  M08 R3 — the package-format floor follows the CONSUMER REFERENCE, not only
//  the axis/point definition. A new circular-pattern `axisRef` or revolve
//  `AxisRef.constructionAxis` can point at a LEGACY absolute axis
//  (`definition == nil`), and a datum point row is a new top-level entity even
//  when the point itself is absolute. A released format-1 writer (v1.7.65/306
//  `fc7d8b240a214be96d3891fb40b8d1a052252e3c`, `Project.currentFormatVersion
//  = 1`) ignores `axisRef`, rejects the unknown revolve source and has no
//  `datumPoints` column, so leaving the floor at 1 lets it stay writable and
//  drop the new relationship on its next save.
//
//  These are REAL document/service tests (OCCT kernel required for the save/
//  reopen cases). The raw-record cases exercise the SAME production
//  `CADDocumentFormat.assess` / `validateWrite` contract with encoded production
//  values; no authored successful `.floecad` substitute and no new schema 8.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssociativeAxisFormatFloorTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxisFormatFloor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func url() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).floecad")
    }

    private func open(_ url: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.open(at: url)
        documents.append(document)
        return document
    }

    private func manifest(_ url: URL) throws -> CADManifest {
        try JSONDecoder().decode(
            CADManifest.self,
            from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
    }

    private func attach(_ document: FloeCADDocument, feature: FeatureID,
                        axis: ConstructionAxisID) -> [String: Any] {
        CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": feature.raw.uuidString,
            "changes": ["axis_id": axis.raw.uuidString],
        ])
    }

    @discardableResult
    private func addLegacyAxis(
        _ document: FloeCADDocument,
        origin: SIMD3<Double> = SIMD3(20, 0, 0),
        direction: SIMD3<Double> = SIMD3(0, 1, 0)
    ) throws -> ConstructionAxisID {
        let axis = try XCTUnwrap(ConstructionAxis(origin: origin, direction: direction))
        XCTAssertNil(axis.definition, "the fixture must be a LEGACY absolute axis")
        document.session.perform(AddConstructionAxisCommand(axis: axis))
        return axis.id
    }

    // MARK: - Real pattern consumer, legacy absolute axis

    /// Ground-plane plate + circular pattern. The sketch has `support == nil`
    /// and the document has no associative definition: with the pattern's
    /// absolute line and a legacy absolute axis this is a real format-1
    /// document until the pattern REFERENCES that axis.
    private func patternDocument() async throws -> (FloeCADDocument, FeatureID) {
        let document = try await FloeCADDocument.create(at: url(), name: "Pattern floor")
        documents.append(document)
        let sketch = Sketch(name: "Plate", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 20)),
        ])
        let body = BodyID()
        let source = FeatureNode(
            name: "Plate",
            kind: .extrude(
                profile: ProfileRef(sketchID: sketch.id,
                                    entityIDs: sketch.entities.map(\.id),
                                    holeEntityIDs: [], seedPoint: SIMD2(20, 10)),
                plane: PlaneRef(source: .sketch(sketch.id)),
                distance: Expr(value: 10), symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []),
            outputBodyIDs: [body])
        let pattern = FeatureNode(
            name: "Pattern",
            kind: .pattern(
                body: BodyRef(producer: source.id, bodyID: body),
                spec: PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                                  count: 3, spacing: 0, totalAngle: 2 * .pi,
                                  rotateInstances: true, axisRef: nil)),
            outputBodyIDs: [BodyID(), BodyID()])
        document.session.recordAndRebuild(
            [source, pattern], extra: [AddSketchCommand(sketch: sketch)],
            title: "Plate and pattern")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        XCTAssertNil(document.session.document.sketches.first?.support)
        return (document, pattern.id)
    }

    func testPatternAttachedToALegacyAbsoluteAxisRaisesTheFloorOnTheActualSave() async throws {
        let (document, patternID) = try await patternDocument()
        let axis = try addLegacyAxis(document)

        // Control: an absolute pattern and an UNREFERENCED legacy absolute axis
        // are still an ordinary format-1 document.
        let control = await document.save()
        XCTAssertTrue(control.succeeded, control.error ?? "")
        XCTAssertEqual(try manifest(document.url).schemaVersion, 1)
        XCTAssertEqual(document.project.formatVersion, 1)

        let reply = attach(document, feature: patternID, axis: axis)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        guard case let .pattern(_, spec)? = document.session.document.features.node(patternID)?.kind else {
            return XCTFail("the pattern node disappeared")
        }
        XCTAssertEqual(spec.axisRef?.axisID, axis, "the attach must store the axis IDENTITY")

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let savedSchema = try manifest(document.url).schemaVersion
        XCTAssertGreaterThanOrEqual(savedSchema, CADDocumentFormat.associativeVersion)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion,
                                    CADDocumentFormat.associativeVersion)
        XCTAssertGreaterThanOrEqual(
            CADDocumentFormat.requiredFormat(document: document.session.document),
            CADDocumentFormat.associativeVersion)

        let url = document.url
        document.close()
        let reopened = try await open(url)
        let node = try XCTUnwrap(reopened.session.document.features.node(patternID))
        guard case let .pattern(_, reopenedSpec) = node.kind else {
            return XCTFail("the pattern did not survive reopen")
        }
        XCTAssertEqual(reopenedSpec.axisRef?.axisID, axis,
                       "the reference identity, not a baked line, must be persisted")
        let reopenedAxis = try XCTUnwrap(reopened.session.document.axes.first { $0.id == axis })
        XCTAssertNil(reopenedAxis.definition, "the source axis stays a legacy absolute axis")
        XCTAssertGreaterThanOrEqual(try manifest(url).schemaVersion,
                                    CADDocumentFormat.associativeVersion)
    }

    // MARK: - Real revolve consumer, legacy absolute axis

    private func revolveDocument() async throws -> (FloeCADDocument, FeatureID, BodyID, Sketch) {
        let document = try await FloeCADDocument.create(at: url(), name: "Revolve floor")
        documents.append(document)
        let profileID = UUID()
        let sketch = Sketch(name: "Revolve profile", plane: .ground, entities: [
            .rect(id: profileID, min: SIMD2(24, -10), max: SIMD2(34, 10)),
        ])
        let body = BodyID()
        let revolve = FeatureNode(
            name: "Revolve",
            kind: .revolve(
                profile: ProfileRef(sketchID: sketch.id, entityIDs: [profileID],
                                    holeEntityIDs: [], seedPoint: SIMD2(29, 0)),
                plane: PlaneRef(source: .sketch(sketch.id)),
                axis: AxisRef(source: .explicit(
                    RevolveAxis(point: SIMD2(20, 0), direction: SIMD2(0, 1)))),
                angle: Expr(value: 360),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [body])
        document.session.recordAndRebuild(
            [revolve], extra: [AddSketchCommand(sketch: sketch)], title: "Revolve")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        XCTAssertNil(document.session.document.sketches.first?.support)
        return (document, revolve.id, body, sketch)
    }

    func testRevolveAttachedToALegacyAbsoluteAxisRaisesTheFloorOnTheActualSave() async throws {
        let (document, revolveID, body, _) = try await revolveDocument()
        let initialBrep = try XCTUnwrap(document.session.document.body(with: body)?.brep)
        let volumeBefore = OCCTKernel.volume(initialBrep)
        // The ground sketch maps v → -worldZ, so the legacy absolute line that
        // is the old explicit 2D axis (u = 20, direction +v) is world
        // (20, 0, 0) along -Z — exactly in the revolve plane.
        let axis = try addLegacyAxis(document, origin: SIMD3(20, 0, 0),
                                     direction: SIMD3(0, 0, -1))

        let control = await document.save()
        XCTAssertTrue(control.succeeded, control.error ?? "")
        XCTAssertEqual(try manifest(document.url).schemaVersion, 1)
        XCTAssertEqual(document.project.formatVersion, 1)

        let reply = attach(document, feature: revolveID, axis: axis)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        guard case let .revolve(_, _, reference, _, _)? =
                document.session.document.features.node(revolveID)?.kind else {
            return XCTFail("the revolve node disappeared")
        }
        XCTAssertEqual(reference.source, .constructionAxis(axis))

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThanOrEqual(try manifest(document.url).schemaVersion,
                                    CADDocumentFormat.associativeVersion)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion,
                                    CADDocumentFormat.associativeVersion)

        let url = document.url
        document.close()
        let reopened = try await open(url)
        for _ in 0..<200 where reopened.session.lastBodyWriters[body] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let node = try XCTUnwrap(reopened.session.document.features.node(revolveID))
        guard case let .revolve(_, _, reopenedReference, _, _) = node.kind else {
            return XCTFail("the revolve did not survive reopen")
        }
        XCTAssertEqual(reopenedReference.source, .constructionAxis(axis),
                       "the axis identity, not a baked line, must be persisted")
        let reopenedBrep = try XCTUnwrap(reopened.session.document.body(with: body)?.brep)
        XCTAssertEqual(OCCTKernel.volume(reopenedBrep), volumeBefore,
                       accuracy: max(0.01, volumeBefore * 1e-9),
                       "attaching the same in-plane line must not change the geometry")
    }

    // MARK: - Datum point rows

    func testAnAbsoluteDatumPointRowRaisesTheFloorWhileAnEmptyListStaysLegacy() async throws {
        let empty = try await FloeCADDocument.create(at: url(), name: "No points")
        documents.append(empty)
        empty.session.perform(AddSketchCommand(sketch: Sketch(plane: .ground)))
        let emptySave = await empty.save()
        XCTAssertTrue(emptySave.succeeded, emptySave.error ?? "")
        XCTAssertEqual(try manifest(empty.url).schemaVersion, 1,
                       "an empty datum-point list is ordinary legacy content")

        let document = try await FloeCADDocument.create(at: url(), name: "Absolute point")
        documents.append(document)
        document.session.perform(AddSketchCommand(sketch: Sketch(plane: .ground)))
        let point = DatumPoint(position: SIMD3(10, 0, -5), name: "Point 1", definition: nil)
        document.session.perform(AddDatumPointCommand(point: point))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertGreaterThanOrEqual(try manifest(document.url).schemaVersion,
                                    CADDocumentFormat.associativeVersion)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion,
                                    CADDocumentFormat.associativeVersion)

        let url = document.url
        document.close()
        let reopened = try await open(url)
        let reopenedPoint = try XCTUnwrap(
            reopened.session.document.datumPoints.first { $0.id == point.id })
        XCTAssertEqual(reopenedPoint.position, point.position)
        XCTAssertNil(reopenedPoint.definition,
                     "an absolute point row stays absolute; the floor is the protection")
    }

    // MARK: - Typed intent matrix (pure value, no kernel)

    func testTypedFloorRecognizesConsumerReferencesAndDatumPointsAndKeepsHigherFloors() throws {
        let axis = try XCTUnwrap(
            ConstructionAxis(origin: SIMD3(20, 0, 0), direction: SIMD3(0, 1, 0)))
        let producer = FeatureID()
        let body = BodyID()

        func pattern(axisRef: ConstructionAxisRef?) -> FeatureNode {
            FeatureNode(
                name: "Pattern",
                kind: .pattern(
                    body: BodyRef(producer: producer, bodyID: body),
                    spec: PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                                      count: 2, spacing: 0, totalAngle: .pi,
                                      rotateInstances: true, axisRef: axisRef)),
                outputBodyIDs: [])
        }
        func revolve(_ source: AxisRef.Source) -> FeatureNode {
            FeatureNode(
                name: "Revolve",
                kind: .revolve(
                    profile: ProfileRef(sketchID: SketchID(), entityIDs: [],
                                        holeEntityIDs: [], seedPoint: nil),
                    plane: PlaneRef(source: .ground),
                    axis: AxisRef(source: source),
                    angle: Expr(value: 360),
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [])
        }

        var legacy = DesignDocument()
        legacy.axes = [axis]
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: legacy), 1,
                       "a legacy absolute axis alone is format 1")
        legacy.features = FeatureGraph(nodes: [pattern(axisRef: nil)])
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: legacy), 1,
                       "an absolute pattern is still format 1")
        legacy.features = FeatureGraph(nodes: [pattern(axisRef: ConstructionAxisRef(axis.id))])
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: legacy), 2,
                       "the consumer REFERENCE is the intent even with a nil definition")

        var explicitRevolve = DesignDocument()
        explicitRevolve.axes = [axis]
        explicitRevolve.features = FeatureGraph(nodes: [
            revolve(.explicit(RevolveAxis(point: SIMD2(20, 0), direction: SIMD2(0, 1)))),
        ])
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: explicitRevolve), 1,
                       "an ordinary explicit revolve line stays format 1")
        explicitRevolve.features = FeatureGraph(nodes: [revolve(.constructionAxis(axis.id))])
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: explicitRevolve), 2)

        var points = DesignDocument()
        points.datumPoints = []
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: points), 1,
                       "an empty datum-point list is legacy")
        points.datumPoints = [DatumPoint(position: SIMD3(1, 2, 3), definition: nil)]
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: points), 2,
                       "a datum-point ROW is a new top-level entity even when absolute")

        var higher = legacy
        higher.drawingsData = Data(#"{"pages":[{"units":"millimetre"}]}"#.utf8)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: higher),
                       CADDocumentFormat.drawingManufacturingVersion,
                       "a higher existing floor is never lowered by the M08 intent")
    }

    // MARK: - Raw record / raw payload contract

    private func axisBlob(_ axis: ConstructionAxis) throws -> CADBlobRecord {
        CADBlobRecord(blobID: axis.id.raw, data: try JSONEncoder().encode(axis), sha256: "")
    }

    private func pointBlob(_ point: DatumPoint) throws -> CADBlobRecord {
        CADBlobRecord(blobID: point.id.raw, data: try JSONEncoder().encode(point), sha256: "")
    }

    private func featureRow(_ kind: FeatureKind) throws -> CADFeatureRecord {
        CADFeatureRecord(
            featureID: UUID(), orderIndex: 0, name: "Feature", suppressed: false,
            kind: try JSONEncoder().encode(kind),
            outputBodyIDs: try JSONEncoder().encode([BodyID()]))
    }

    private func patternKind(axisRef: ConstructionAxisRef?) -> FeatureKind {
        .pattern(
            body: BodyRef(producer: FeatureID(), bodyID: BodyID()),
            spec: PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                              count: 2, spacing: 0, totalAngle: .pi,
                              rotateInstances: true, axisRef: axisRef))
    }

    private func revolveKind(_ source: AxisRef.Source) -> FeatureKind {
        .revolve(
            profile: ProfileRef(sketchID: SketchID(), entityIDs: [],
                                holeEntityIDs: [], seedPoint: nil),
            plane: PlaneRef(source: .ground),
            axis: AxisRef(source: source),
            angle: Expr(value: 360),
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []))
    }

    private func record(features: [CADFeatureRecord] = [],
                        axes: [CADBlobRecord] = [],
                        datumPoints: [CADBlobRecord]? = nil,
                        drawings: Data? = nil) -> CADDocumentRecord {
        CADDocumentRecord(
            bodies: [], sketches: [], planes: [], axes: axes, images: [], symbols: [],
            features: features, variables: [], rollbackIndex: nil, folderID: nil,
            itemFolders: nil, assembly: nil, drawings: drawings, scripts: nil,
            sceneSettings: nil, materials: nil, animation: nil,
            datumPoints: datumPoints)
    }

    private func payload(_ record: CADDocumentRecord, schema: Int) -> CADWritePayload {
        CADWritePayload(
            expectedRevision: 0, schemaVersion: schema, name: "Raw",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            unit: nil, tolerance: nil, appBuild: "test",
            document: record, blobs: [:], thumbnail: nil)
    }

    private func assertLowSchemaRefused(
        _ record: CADDocumentRecord, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let assessment = try CADDocumentFormat.assess(record)
        XCTAssertEqual(assessment.requiredVersion, CADDocumentFormat.associativeVersion,
                       file: file, line: line)
        XCTAssertThrowsError(
            try CADDocumentFormat.validateWrite(payload(record, schema: 1)),
            file: file, line: line
        ) { error in
            XCTAssertEqual(
                error as? CADDocumentFormatError,
                .insufficientFormat(provided: 1, required: 2),
                file: file, line: line)
        }
    }

    func testRawPayloadClaimingFormatOneRefusesEachNewIntent() throws {
        let axis = try XCTUnwrap(
            ConstructionAxis(origin: SIMD3(20, 0, 0), direction: SIMD3(0, 1, 0)))
        let axisRecord = try axisBlob(axis)

        // 1. A pattern that actually stores axisRef (source may be legacy).
        let patternRecord = record(
            features: [try featureRow(patternKind(axisRef: ConstructionAxisRef(axis.id)))],
            axes: [axisRecord])
        try assertLowSchemaRefused(patternRecord)

        // 2. A revolve that actually stores AxisRef.constructionAxis.
        let revolveRecord = record(
            features: [try featureRow(revolveKind(.constructionAxis(axis.id)))],
            axes: [axisRecord])
        try assertLowSchemaRefused(revolveRecord)

        // 3. Any nonempty datum-point row, even with `definition == nil`.
        let point = DatumPoint(position: SIMD3(10, 0, -5), definition: nil)
        let pointRecord = record(datumPoints: [try pointBlob(point)])
        try assertLowSchemaRefused(pointRecord)

        // True legacy controls: none of these intents is present.
        let explicitRevolve = record(
            features: [try featureRow(
                revolveKind(.explicit(RevolveAxis(point: SIMD2(20, 0),
                                                  direction: SIMD2(0, 1)))))],
            axes: [axisRecord])
        XCTAssertEqual(try CADDocumentFormat.assess(explicitRevolve).requiredVersion, 1)
        XCTAssertNoThrow(try CADDocumentFormat.validateWrite(payload(explicitRevolve, schema: 1)))

        let absolutePattern = record(
            features: [try featureRow(patternKind(axisRef: nil))],
            axes: [axisRecord])
        XCTAssertEqual(try CADDocumentFormat.assess(absolutePattern).requiredVersion, 1)
        XCTAssertNoThrow(try CADDocumentFormat.validateWrite(payload(absolutePattern, schema: 1)))

        let emptyPoints = record(datumPoints: [])
        XCTAssertEqual(try CADDocumentFormat.assess(emptyPoints).requiredVersion, 1)
        XCTAssertNoThrow(try CADDocumentFormat.validateWrite(payload(emptyPoints, schema: 1)))

        // A higher drawing floor stays the maximum; the M08 intent never lowers it.
        let drawing = Data(#"{"pages":[{"units":"millimetre"}]}"#.utf8)
        let higher = record(
            features: [try featureRow(patternKind(axisRef: ConstructionAxisRef(axis.id)))],
            axes: [axisRecord], drawings: drawing)
        XCTAssertEqual(try CADDocumentFormat.assess(higher).requiredVersion,
                       CADDocumentFormat.drawingManufacturingVersion)
        XCTAssertThrowsError(try CADDocumentFormat.validateWrite(payload(higher, schema: 6))) { error in
            XCTAssertEqual(
                error as? CADDocumentFormatError,
                .insufficientFormat(provided: 6,
                                    required: CADDocumentFormat.drawingManufacturingVersion))
        }
    }

    func testRawUnknownDatumDefinitionStaysOpaqueWithItsOriginalBytesAndUnknownFeatureStaysPreserved() throws {
        // A PRESENT future definition must not decode to nil (which would turn
        // an associative point into an editable absolute coordinate). It opens
        // opaque/read-only with its original bytes and a display-only cache.
        let point = DatumPoint(position: SIMD3(10, 0, -5), name: "Future", definition: nil)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as? [String: Any])
        object["definition"] = ["kind": "futureDatum", "futureDatum": ["version": 9]]
        let futureData = try JSONSerialization.data(withJSONObject: object)
        let futureRow = CADBlobRecord(blobID: point.id.raw, data: futureData, sha256: "")
        let futureRecord = record(datumPoints: [futureRow])
        let assessment = try CADDocumentFormat.assess(futureRecord)
        XCTAssertTrue(assessment.isOpaqueReadOnly)
        XCTAssertTrue(assessment.opaqueDatumPoints.contains(point.id.raw))
        XCTAssertGreaterThanOrEqual(assessment.requiredVersion,
                                    CADDocumentFormat.associativeVersion)
        XCTAssertThrowsError(try CADDocumentFormat.validateWrite(payload(futureRecord, schema: 2))) {
            error in
            XCTAssertEqual(error as? CADDocumentFormatError, .opaqueAssociations)
        }
        let cached = try CADDocumentFormat.cachedDatumPoint(from: futureData)
        XCTAssertEqual(cached.id, point.id)
        XCTAssertEqual(cached.position, point.position)
        XCTAssertNil(cached.definition)
        XCTAssertEqual(futureRow.data, futureData, "the original row bytes stay untouched")

        // An unknown future FEATURE kind keeps the existing unreadable-row
        // preservation contract: skip it, keep its bytes, no invented floor.
        let unknownFeature = CADFeatureRecord(
            featureID: UUID(), orderIndex: 0, name: "Future", suppressed: false,
            kind: Data(#"{"futureFeature":{"payload":{"x":1}}}"#.utf8),
            outputBodyIDs: try JSONEncoder().encode([BodyID()]))
        let unknownRecord = record(features: [unknownFeature])
        let unknownAssessment = try CADDocumentFormat.assess(unknownRecord)
        XCTAssertFalse(unknownAssessment.isOpaqueReadOnly)
        XCTAssertEqual(unknownAssessment.requiredVersion, 1)
        XCTAssertEqual(unknownFeature.kind,
                       Data(#"{"futureFeature":{"payload":{"x":1}}}"#.utf8))
    }

    func testRawMalformedAxisReferenceIsCorruptionNotASilentLegacyRow() throws {
        let axis = try XCTUnwrap(
            ConstructionAxis(origin: SIMD3(20, 0, 0), direction: SIMD3(0, 1, 0)))
        let axisRecord = try axisBlob(axis)

        var patternObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(patternKind(
                    axisRef: ConstructionAxisRef(axis.id)))) as? [String: Any])
        var patternPayload = try XCTUnwrap(patternObject["pattern"] as? [String: Any])
        var patternSpec = try XCTUnwrap(patternPayload["spec"] as? [String: Any])
        let malformedReferences: [Any] = [42, "not-an-object", true,
                                           [1, 2], ["axisID": "not-a-reference"]]
        for malformedReference in malformedReferences {
            patternSpec["axisRef"] = malformedReference
            patternPayload["spec"] = patternSpec
            patternObject["pattern"] = patternPayload
            let malformedPattern = CADFeatureRecord(
                featureID: UUID(), orderIndex: 0, name: "Malformed", suppressed: false,
                kind: try JSONSerialization.data(withJSONObject: patternObject),
                outputBodyIDs: try JSONEncoder().encode([BodyID()]))
            XCTAssertThrowsError(
                try CADDocumentFormat.assess(record(features: [malformedPattern],
                                                    axes: [axisRecord]))
            ) { error in
                XCTAssertEqual(error as? CADDocumentFormatError,
                               .malformedAssociation("pattern-axis-reference"))
            }
        }

        var revolveObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(revolveKind(.constructionAxis(axis.id)))) as? [String: Any])
        var revolvePayload = try XCTUnwrap(revolveObject["revolve"] as? [String: Any])
        var revolveAxis = try XCTUnwrap(revolvePayload["axis"] as? [String: Any])
        var revolveSource = try XCTUnwrap(revolveAxis["source"] as? [String: Any])
        revolveSource["constructionAxis"] = ["_0": "not-a-uuid"]
        revolveAxis["source"] = revolveSource
        revolvePayload["axis"] = revolveAxis
        revolveObject["revolve"] = revolvePayload
        let malformedRevolve = CADFeatureRecord(
            featureID: UUID(), orderIndex: 0, name: "Malformed", suppressed: false,
            kind: try JSONSerialization.data(withJSONObject: revolveObject),
            outputBodyIDs: try JSONEncoder().encode([BodyID()]))
        XCTAssertThrowsError(
            try CADDocumentFormat.assess(record(features: [malformedRevolve],
                                                axes: [axisRecord]))
        ) { error in
            XCTAssertEqual(error as? CADDocumentFormatError,
                           .malformedAssociation("revolve-axis-reference"))
        }
    }

    // MARK: - Frozen shipped reader contract (source-shaped, not an old App run)

    /// Mirrors `fc7d8b24` `PatternSpec` exactly: the released decoder has no
    /// `axisRef` key, so it decodes the M08 spec successfully and silently
    /// loses the reference on re-encode. The released session gate is
    /// `formatVersion > 1` (`DocumentSession.swift:699`), which is exactly why
    /// the writer floor must become 2.
    private nonisolated struct SchemaOnePatternSpecReader: Decodable {
        enum Kind: String, Decodable, Equatable { case linear, circular }
        let kind: Kind
        let axis: SIMD3<Double>
        let center: SIMD3<Double>
        let count: Int
        let spacing: Double
        let totalAngle: Double
        let rotateInstances: Bool
        private enum CodingKeys: String, CodingKey {
            case kind, axis, center, count, spacing, totalAngle, rotateInstances
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            axis = try c.decode(SIMD3<Double>.self, forKey: .axis)
            center = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .center) ?? .zero
            count = try c.decode(Int.self, forKey: .count)
            spacing = try c.decode(Double.self, forKey: .spacing)
            totalAngle = try c.decode(Double.self, forKey: .totalAngle)
            rotateInstances = try c.decode(Bool.self, forKey: .rotateInstances)
        }
        static func sessionAllowsWrite(schema: Int) -> Bool { !(schema > 1) }
    }

    /// Mirrors `fc7d8b24` `AxisRef.Source`: no `constructionAxis` case exists.
    private nonisolated struct SchemaOneAxisRefReader: Decodable {
        enum Source: Decodable {
            case sketchLine(SketchID, UUID)
            case explicit(RevolveAxis)
        }
        let source: Source
    }

    func testFixedSchemaOneContractDropsThePatternReferenceAndCannotReadTheRevolveSource() throws {
        let axis = try XCTUnwrap(
            ConstructionAxis(origin: SIMD3(20, 0, 0), direction: SIMD3(0, 1, 0)))
        let spec = PatternSpec(kind: .circular, axis: SIMD3(0, 1, 0), center: .zero,
                               count: 4, spacing: 0, totalAngle: .pi,
                               rotateInstances: true,
                               axisRef: ConstructionAxisRef(axis.id))
        let legacy = try JSONDecoder().decode(
            SchemaOnePatternSpecReader.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(legacy.kind, .circular)
        XCTAssertEqual(legacy.count, 4)
        XCTAssertTrue(SchemaOnePatternSpecReader.sessionAllowsWrite(schema: 1))
        XCTAssertFalse(SchemaOnePatternSpecReader.sessionAllowsWrite(schema: 2),
                       "the shipped format-1 session gate refuses the protected document")

        let revolveAxis = AxisRef(source: .constructionAxis(axis.id))
        XCTAssertThrowsError(
            try JSONDecoder().decode(SchemaOneAxisRefReader.self,
                                     from: JSONEncoder().encode(revolveAxis))
        ) { error in
            XCTAssertTrue(error is DecodingError,
                          "the shipped reader has no constructionAxis source case")
        }
    }
}
