// M05 external edge projection. Integration tests for the real named OCCT
// geometry, production session/service and transactional file store.
// Source-only packet: these assertions have not been compiled or executed.
// The original R2 test source remains immutable in its prior packet; its
// delete-refusal and failed-source assumptions are corrected here.

import Foundation
import XCTest
import Euclid
import simd
@testable import FloeCAD

@MainActor
final class CADExternalSketchProjectionTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeExternalProjection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Fixture

    private struct Plate {
        var document: FloeCADDocument
        var sourceSketch: Sketch
        var source: FeatureNode
        var bodyID: BodyID
        var targetSketch: Sketch
    }

    private func url() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).floecad")
    }

    private func open(_ url: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.open(at: url)
        documents.append(document)
        return document
    }

    private func extrusion(
        _ sketch: Sketch, distance: Double, body: BodyID, name: String
    ) -> FeatureNode {
        FeatureNode(name: name, kind: .extrude(
            profile: ProfileRef(
                sketchID: sketch.id, entityIDs: sketch.entities.map(\.id),
                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    /// Plate 100×60 extruded 10 mm up from the ground plane, plus an empty
    /// target sketch on a plane 5 mm below ground (projection plane).
    @discardableResult
    private func plate(width: Double = 100, depth: Double = 60) async throws -> Plate {
        try await plate(at: url(), width: width, depth: depth)
    }

    /// Same fixture at a caller-supplied package URL, so save/reopen tests
    /// reopen the exact document they saved.
    @discardableResult
    private func plate(at packageURL: URL, width: Double = 100, depth: Double = 60) async throws -> Plate {
        let document = try await FloeCADDocument.create(at: packageURL, name: "Projection host")
        documents.append(document)
        let sourceSketch = Sketch(name: "Source", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(width, depth)),
        ])
        let bodyID = BodyID()
        let source = extrusion(sourceSketch, distance: 10, body: bodyID, name: "Plate")
        document.session.recordAndRebuild(
            [source], extra: [AddSketchCommand(sketch: sourceSketch)], title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        let targetSketch = Sketch(name: "Projection", plane: .offsetGround(y: -5))
        document.session.perform(AddSketchCommand(sketch: targetSketch))
        return Plate(document: document, sourceSketch: sourceSketch, source: source,
                     bodyID: bodyID, targetSketch: targetSketch)
    }

    private struct SourceEdges {
        var snapshot: GeometryVersionSnapshot
        var version: GeometryVersionRef
        /// Names of the straight creases, keyed by kernel edge index.
        var straightNames: [Int: EdgeName]
        /// Names of the straight creases whose projection is parallel to the
        /// plate normal (the four vertical edges) — refused as degenerate.
        var degenerateNames: [EdgeName]
    }

    /// Read the CURRENT frozen source edges the way the Project tool does,
    /// and partition them geometrically (no assumptions about face naming).
    private func sourceEdges(_ plate: Plate) throws -> SourceEdges {
        guard let source = plate.document.session.associativeSources(for: [plate.bodyID])[plate.bodyID] else {
            struct NoSource: Error {}
            throw NoSource()
        }
        let brep = try XCTUnwrap(source.snapshot.body.brep)
        let adjacency = OCCTKernel.edgeFaceAdjacency(brep)
        let names = ElementNaming.edgeNames(adjacency: adjacency, names: source.snapshot.kernelNames)
        let curves = OCCTKernel.edgeCurves(brep)
        var straight: [Int: EdgeName] = [:]
        var degenerate: [EdgeName] = []
        let transform = source.snapshot.body.transform
        for (index, name) in names {
            guard let curve = curves[index], curve.isLine else { continue }
            let worldA = transform.applying(to: curve.start)
            let worldB = transform.applying(to: curve.end)
            if ExternalSketchProjection.project(worldA: worldA, worldB: worldB,
                                                onto: .offsetGround(y: -5)) != nil {
                straight[index] = name
            } else {
                degenerate.append(name)
            }
        }
        return SourceEdges(snapshot: source.snapshot, version: source.version,
                           straightNames: straight, degenerateNames: degenerate)
    }

    /// One name per coincident projected group: the 4 straight creases that
    /// form the rectangle footprint (the plate's horizontal boundary).
    private func rectangleEdgeNames(_ edges: SourceEdges) throws -> Set<EdgeName> {
        // 8 straight creases: 4 bottom + 4 top, projecting coincident in
        // pairs onto the parallel plane. Group by the projected carrier
        // (direction + offset + interval) and keep one name per group:
        // exactly the four rectangle sides.
        struct Key: Hashable { var dx, dy, offset, t0, t1: Int64 }
        var groups = Set<Key>()
        var picked = Set<EdgeName>()
        let brep = try XCTUnwrap(edges.snapshot.body.brep)
        let adjacency = OCCTKernel.edgeFaceAdjacency(brep)
        let names = ElementNaming.edgeNames(adjacency: adjacency, names: edges.snapshot.kernelNames)
        let curves = OCCTKernel.edgeCurves(brep)
        let transform = edges.snapshot.body.transform
        let plane = SketchPlane.offsetGround(y: -5)
        for (index, curve) in curves.sorted(by: { $0.key < $1.key }) where curve.isLine {
            guard let name = names[index], edges.straightNames[index] != nil else { continue }
            let a = plane.toLocal(transform.applying(to: curve.start))
            let b = plane.toLocal(transform.applying(to: curve.end))
            let delta = b - a
            let length = simd_length(delta)
            guard length > 1e-9 else { continue }
            var direction = delta / length
            if direction.x < 0 || (direction.x == 0 && direction.y < 0) { direction = -direction }
            let normal = SIMD2(-direction.y, direction.x)
            func q(_ v: Double) -> Int64 { Int64((v / 1e-4).rounded()) }
            let key = Key(dx: q(direction.x), dy: q(direction.y),
                          offset: q(simd_dot(a, normal)),
                          t0: q(min(simd_dot(a, direction), simd_dot(b, direction))),
                          t1: q(max(simd_dot(a, direction), simd_dot(b, direction))))
            if groups.insert(key).inserted {
                picked.insert(name)
            }
        }
        XCTAssertEqual(picked.count, 4, "expected one name per rectangle side, got \(picked.count)")
        return picked
    }

    /// Mint the linked projection of exactly the selected names the way the
    /// Project tool does for one tapped edge (here: a bounded set).
    @discardableResult
    private func project(
        _ plate: Plate, selected: Set<EdgeName>, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ProjectionKit.LinkedProjection {
        guard let source = plate.document.session.associativeSources(for: [plate.bodyID])[plate.bodyID] else {
            XCTFail("no associative source snapshot for the plate", file: file, line: line)
            return ProjectionKit.LinkedProjection()
        }
        let sketch = try XCTUnwrap(
            plate.document.session.document.sketches
                .first(where: { $0.id == plate.targetSketch.id }),
            file: file, line: line)
        let linked = ProjectionKit.linked(
            snapshot: source.snapshot, version: source.version,
            onto: sketch.plane, selected: selected)
        XCTAssertTrue(
            plate.document.session.performWithSketchRebuild(
                AddProjectedSketchEntitiesCommand(
                    sketchID: plate.targetSketch.id,
                    entities: linked.entities,
                    references: linked.references,
                    title: "Project"),
                sketchID: plate.targetSketch.id),
            "projection mint must commit", file: file, line: line)
        return linked
    }

    private func targetSketch(_ plate: Plate) -> Sketch {
        plate.document.session.document.sketches
            .first(where: { $0.id == plate.targetSketch.id }) ?? plate.targetSketch
    }

    private func maxX(in sketch: Sketch) -> Double {
        sketch.entities.reduce(0) { partial, entity in
            guard case let .line(_, a, b) = entity else { return partial }
            return max(partial, a.x, b.x)
        }
    }

    private func projectedMaxX(_ plate: Plate) -> Double {
        maxX(in: targetSketch(plate))
    }

    // MARK: - Mint (selected edges)

    func testLinkedProjectionMintsReferencesForSelectedStraightEdges() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        let rectangle = try rectangleEdgeNames(edges)

        // The four rectangle sides mint four references — one per SELECTED
        // source edge, no whole-body doubling.
        let linked = try project(plate, selected: rectangle)
        XCTAssertEqual(linked.entities.count, 4, "\(linked)")
        XCTAssertEqual(linked.references.count, 4)
        XCTAssertEqual(linked.skippedCurved, 0)

        let sketch = targetSketch(plate)
        XCTAssertEqual(sketch.externalReferences?.count, 4)
        XCTAssertTrue(sketch.entities.allSatisfy { entity in
            if case .line = entity { return true }
            return false
        })
        // Footprint: 100 mm × 60 mm in plane-local coordinates.
        XCTAssertEqual(projectedMaxX(plate), 100, accuracy: 1e-9)
        let maxY = sketch.entities.reduce(0) { partial, entity in
            guard case let .line(_, a, b) = entity else { return partial }
            return max(partial, a.y, b.y)
        }
        XCTAssertEqual(maxY, 60, accuracy: 1e-9)
        // Every reference binds its entity to a named crease on the frozen
        // plate version — the identity the rebuild resolves by.
        for reference in sketch.externalReferences ?? [] {
            XCTAssertEqual(reference.source.body.bodyID, plate.bodyID)
            XCTAssertNotNil(reference.source.faceNames)
            XCTAssertEqual(reference.sourceVersion.writer, plate.source.id)
            XCTAssertTrue(rectangle.contains(reference.source.faceNames!))
            XCTAssertTrue(sketch.entities.contains { $0.id == reference.entity })
        }
        XCTAssertTrue(plate.document.session.lastReferenceErrors.isEmpty,
                      "\(plate.document.session.lastReferenceErrors)")
    }

    /// Concident duplicates are legal ONLY as an explicit user selection of
    /// genuinely different source edges — and then the downstream profile
    /// must be demonstrably correct: the geometry service detects exactly
    /// one rectangle profile and extrudes the exact intended solid.
    func testCoincidentSelectedEdgesStayDistinctAndProfileExtrudesIntendedSolid() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        // All 8 straight creases: both rims of every rectangle side.
        let all = Set(edges.straightNames.values)
        XCTAssertEqual(all.count, 8)
        let linked = try project(plate, selected: all)
        XCTAssertEqual(linked.entities.count, 8)
        let sketch = targetSketch(plate)
        XCTAssertEqual(sketch.externalReferences?.count, 8)

        // Downstream profile truth: ONE rectangle profile, exactly 6000 mm²,
        // built from the deduped coincident straights — not zero-area slivers,
        // not a swallowed face.
        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1, "\(profiles)")
        XCTAssertEqual(abs(profiles[0].area), 6000, accuracy: 1e-6)

        // The exact intended geometry through the real geometry service: an
        // extrude of the detected profile produces a 100×60×10 solid.
        let solidID = BodyID()
        let solid = extrusion(sketch, distance: 10, body: solidID, name: "Extrude projection")
        plate.document.session.recordAndRebuild([solid], title: "Extrude projection")
        XCTAssertTrue(plate.document.session.lastEvalErrors.isEmpty,
                      "\(plate.document.session.lastEvalErrors)")
        let body = try XCTUnwrap(plate.document.session.document.body(with: solidID))
        let bounds = body.render.localAABB
        XCTAssertEqual(Double(bounds.max.x - bounds.min.x), 100, accuracy: 1e-3)
        XCTAssertEqual(Double(bounds.max.y - bounds.min.y), 10, accuracy: 1e-3)
        XCTAssertEqual(Double(bounds.max.z - bounds.min.z), 60, accuracy: 1e-3)
    }

    // MARK: - Source change

    func testSourceDimensionEditReprojectsThroughSameRebuild() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let source = try XCTUnwrap(plate.document.session.document.sketches
            .first(where: { $0.id == plate.sourceSketch.id }))
        let rectID = try XCTUnwrap(source.entities.first?.id)

        let reply = CADParameterService(document: plate.document).handle(
            action: "updateSketchEntity",
            args: ["sketch_id": plate.sourceSketch.id.raw.uuidString,
                   "entity_id": rectID.uuidString,
                   "max": [140, 60]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(projectedMaxX(plate), 140, accuracy: 1e-6)
        // The plate itself rebuilt in the SAME undo step.
        let body = try XCTUnwrap(plate.document.session.document.body(with: plate.bodyID))
        let bounds = body.render.localAABB
        XCTAssertEqual(Double(bounds.max.x - bounds.min.x), 140, accuracy: 1e-3)

        // One undo restores the source dimension AND the projected geometry.
        plate.document.session.undo()
        XCTAssertEqual(projectedMaxX(plate), 100, accuracy: 1e-6)
        // Redo re-applies both.
        plate.document.session.redo()
        XCTAssertEqual(projectedMaxX(plate), 140, accuracy: 1e-6)
    }

    // MARK: - Actual source deletion, recovery and persistence

    private func assertDeletedSourceLinks(
        _ document: FloeCADDocument, plate: Plate, geometry: [SketchEntity],
        references: [SketchExternalReference], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let session = document.session
        XCTAssertNil(session.document.features.node(plate.source.id), file: file, line: line)
        XCTAssertNil(session.document.body(with: plate.bodyID), file: file, line: line)
        let sketch = try XCTUnwrap(session.document.sketches.first {
            $0.id == plate.targetSketch.id
        }, file: file, line: line)
        XCTAssertEqual(sketch.entities, geometry, file: file, line: line)
        XCTAssertEqual(sketch.externalReferences, references, file: file, line: line)
        XCTAssertTrue(session.lastEvalErrors.isEmpty, "\(session.lastEvalErrors)", file: file, line: line)
        for reference in references {
            let error = session.lastReferenceErrors[.external(sketch.id, reference.entity)]
            XCTAssertEqual(error, .missingWriter(reference.sourceVersion), file: file, line: line)
        }
        let outcome = document.nativeQueryJSON(["scope": "sketches"])
        XCTAssertTrue(outcome.isOK, file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        let rows = object["rows"] as? [[String: Any]] ?? []
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == sketch.id.raw.uuidString })
        XCTAssertEqual(row["external_status"] as? String, "broken", file: file, line: line)
        XCTAssertEqual(row["externalBroken"] as? Int, references.count, file: file, line: line)
        let entities = row["entityRows"] as? [[String: Any]] ?? []
        for reference in references {
            let entity = try XCTUnwrap(entities.first { $0["id"] as? String == reference.entity.uuidString })
            XCTAssertEqual(entity["external_status"] as? String, "broken", file: file, line: line)
            XCTAssertEqual(entity["detach_action"] as? String, "detachExternalReferences", file: file, line: line)
        }
    }

    func testActualSourceDeleteBrokenUndoDetachSaveReopen() async throws {
        let packageURL = url()
        let plate = try await plate(at: packageURL)
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let frozen = targetSketch(plate).entities
        let references = try XCTUnwrap(targetSketch(plate).externalReferences)
        let before = plate.document.session.persistenceChangeCount
        let reply = CADParameterService(document: plate.document).handle(
            action: "feature.delete", args: ["feature_id": plate.source.id.raw.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertGreaterThan(plate.document.session.persistenceChangeCount, before)
        XCTAssertTrue(plate.document.session.lastRebuildRejection.isEmpty)
        try assertDeletedSourceLinks(plate.document, plate: plate, geometry: frozen, references: references)

        // One undo restores the actual source node and solid, then redo
        // deletes them again. Visibility and suppression are never used.
        plate.document.session.undo()
        XCTAssertNotNil(plate.document.session.document.features.node(plate.source.id))
        XCTAssertNotNil(plate.document.session.document.body(with: plate.bodyID))
        XCTAssertTrue(plate.document.session.lastReferenceErrors.isEmpty)
        XCTAssertEqual(targetSketch(plate).entities, frozen)
        plate.document.session.redo()
        try assertDeletedSourceLinks(plate.document, plate: plate, geometry: frozen, references: references)
        let brokenSave = await plate.document.save()
        XCTAssertTrue(brokenSave.succeeded, brokenSave.error ?? "")
        plate.document.close()

        let reopened = try await open(packageURL)
        // Load intentionally refreshes diagnostics off the open path. Wait
        // for its actual result, without issuing a mutation to manufacture it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, references.contains(where: {
            reopened.session.lastReferenceErrors[.external(plate.targetSketch.id, $0.entity)] == nil
        }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try assertDeletedSourceLinks(reopened, plate: plate, geometry: frozen, references: references)
        let detach = CADParameterService(document: reopened).handle(
            action: "detachExternalReferences",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "entity_ids": references.map(\.entity.uuidString)])
        XCTAssertEqual(detach["ok"] as? Bool, true, "\(detach)")
        func currentSketch() throws -> Sketch {
            try XCTUnwrap(reopened.session.document.sketches.first { $0.id == plate.targetSketch.id })
        }
        XCTAssertFalse(try currentSketch().hasExternalReferences)
        XCTAssertEqual(try currentSketch().entities, frozen)
        XCTAssertTrue(reopened.session.lastReferenceErrors.isEmpty)
        reopened.session.undo()
        try assertDeletedSourceLinks(reopened, plate: plate, geometry: frozen, references: references)
        reopened.session.redo()
        XCTAssertFalse(try currentSketch().hasExternalReferences)
        XCTAssertEqual(try currentSketch().entities, frozen)
        let detachedSave = await reopened.save()
        XCTAssertTrue(detachedSave.succeeded, detachedSave.error ?? "")
        reopened.close()

        let detached = try await open(packageURL)
        let plain = try XCTUnwrap(detached.session.document.sketches.first { $0.id == plate.targetSketch.id })
        XCTAssertFalse(plain.hasExternalReferences)
        XCTAssertEqual(plain.entities, frozen)
        XCTAssertNil(detached.session.document.features.node(plate.source.id))
        XCTAssertTrue(detached.session.lastReferenceErrors.isEmpty)
    }

    func testInvalidSourceSketchEditIsRefusedWithoutDestroyingLinks() async throws {
        let plate = try await plate()
        try project(plate, selected: rectangleEdgeNames(sourceEdges(plate)))
        let session = plate.document.session
        let geometry = targetSketch(plate).entities
        let references = targetSketch(plate).externalReferences
        let beforePersisted = session.persistenceChangeCount
        let source = try XCTUnwrap(session.document.sketches.first { $0.id == plate.sourceSketch.id })
        let rectID = try XCTUnwrap(source.entities.first?.id)
        XCTAssertFalse(session.performWithSketchRebuild(
            RemoveSketchEntitiesCommand(ids: [rectID], sketch: source), sketchID: source.id))
        XCTAssertEqual(session.persistenceChangeCount, beforePersisted)
        XCTAssertEqual(session.document.sketches.first { $0.id == source.id }?.entities, source.entities)
        XCTAssertEqual(targetSketch(plate).entities, geometry)
        XCTAssertEqual(targetSketch(plate).externalReferences, references)
        XCTAssertNotNil(session.document.features.node(plate.source.id))
        XCTAssertNotNil(session.document.body(with: plate.bodyID))
        XCTAssertTrue(session.lastReferenceErrors.isEmpty)
        XCTAssertFalse(session.lastRejectedFeatureErrors.isEmpty)
    }

    func testHardDatumOnSameWriterStillRefusesSourceDeletion() async throws {
        let plate = try await plate()
        try project(plate, selected: rectangleEdgeNames(sourceEdges(plate)))
        let session = plate.document.session
        let body = try XCTUnwrap(session.document.body(with: plate.bodyID))
        let brep = try XCTUnwrap(body.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let name = try XCTUnwrap(session.lastKernelNames[plate.bodyID]?[face.index])
        let ref = FaceRef(body: BodyRef(producer: plate.source.id, bodyID: plate.bodyID),
            creator: name.creator, role: .extrudeEndCap,
            signature: try XCTUnwrap(face.signature), elementName: name)
        let frame = try PlaneAttachmentFrame.make(faceCentroid: face.centroid, faceNormal: face.normal,
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: face.centroid)
        let definition = OffsetPlaneDefinition(source: ref,
            sourceVersion: GeometryVersionRef(bodyID: plate.bodyID, writer: plate.source.id),
            distance: Expr(value: 5), attachment: frame)
        let datum = ConstructionPlane(plane: .offsetGround(y: 15), size: 120, definition: .offset(definition))
        XCTAssertTrue(session.performAssociativeTransaction([AddConstructionPlaneCommand(plane: datum)], title: "Datum"))
        let before = session.persistenceChangeCount
        session.deleteFeature(plate.source.id)
        XCTAssertEqual(session.persistenceChangeCount, before)
        XCTAssertNotNil(session.document.features.node(plate.source.id))
        XCTAssertNotNil(session.document.body(with: plate.bodyID))
        XCTAssertNotNil(session.lastRebuildRejection[.plane(datum.id)])
        XCTAssertTrue(session.lastReferenceErrors.isEmpty)
    }

    func testInsertRefusesUnremappedExternalReferences() async throws {
        let plate = try await plate()
        try project(plate, selected: rectangleEdgeNames(sourceEdges(plate)))
        let guest = plate.document.session.document
        let host = DesignDocument()
        XCTAssertThrowsError(try ProjectMergeKit.insert(guest, into: host)) { error in
            XCTAssertEqual(error as? ProjectMergeKit.MergeError,
                           .missingAssociativeReferences(["sketch-external-references"]))
        }
        XCTAssertTrue(host.sketches.isEmpty)
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 4)
    }

    /// Mid-session broken reference at the resolver layer: the frozen writer
    /// lives but the stored crease name no longer resolves (a topology change
    /// downstream of the writer cannot cause this — the frozen version is
    /// immutable — so the honest cases are a torn/handedited reference or a
    /// future kernel that drops the name). The entity keeps its frozen
    /// geometry, and the typed failure surfaces per entity, never as a
    /// silent re-bind to a lookalike edge.
    func testBrokenReferenceReportsTypedErrorAndFreezesGeometry() throws {
        let source = Sketch(name: "Plate profile", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60)),
        ])
        let sourceBody = BodyID()
        let sourceNode = extrusion(source, distance: 10, body: sourceBody, name: "Plate")
        var revision: UInt64 = 0
        let version = GeometryVersionRef(bodyID: sourceBody, writer: sourceNode.id)
        let initial = FeatureGraph(nodes: [sourceNode]).evaluate(
            sketches: [source], planes: [], naming: SignatureNaming(),
            requestedVersions: [version],
            nextRevision: { revision += 1; return revision })
        XCTAssertTrue(initial.errors.isEmpty)
        let snapshot = try XCTUnwrap(initial.geometryVersions[version])
        let minted = ProjectionKit.linked(
            snapshot: snapshot, version: version, onto: .offsetGround(y: -5))
        XCTAssertEqual(minted.entities.count, 8)
        let target = Sketch(
            name: "Projection", plane: .offsetGround(y: -5),
            entities: minted.entities, externalReferences: minted.references)

        // Healthy replay: references resolve, geometry re-projects identically.
        let healthy = FeatureGraph(nodes: [sourceNode]).evaluate(
            sketches: [source, target], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
        XCTAssertTrue(healthy.errors.isEmpty, "\(healthy.errors)")
        XCTAssertTrue(healthy.referenceErrors.isEmpty, "\(healthy.referenceErrors)")
        XCTAssertEqual(healthy.resolvedSketchEntityUpdates[target.id]?.count, 8)

        // Tear ONE reference: its crease name becomes an identity that has
        // never existed on this plate.
        var tornReferences = minted.references
        let victim = tornReferences[0]
        tornReferences[0] = SketchExternalReference(
            entity: victim.entity,
            sourceVersion: victim.sourceVersion,
            source: EdgeRef(
                body: victim.source.body,
                signature: victim.source.signature,
                faceNames: EdgeName(
                    faceA: ElementName(creator: sourceNode.id, source: .primitiveFace(.boxFace(.px))),
                    faceB: ElementName(creator: sourceNode.id, source: .primitiveFace(.boxFace(.py))),
                    occurrence: 0)))
        let torn = Sketch(
            name: "Projection", plane: .offsetGround(y: -5),
            entities: minted.entities, externalReferences: tornReferences)
        let replayed = FeatureGraph(nodes: [sourceNode]).evaluate(
            sketches: [source, torn], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
        let error = try XCTUnwrap(
            replayed.referenceErrors[.external(torn.id, victim.entity)])
        guard case let .externalBroken(_, entity, reason) = error else {
            XCTFail("expected externalBroken, got \(error)")
            return
        }
        XCTAssertEqual(entity, victim.entity)
        guard case .missingNamedEdge = reason else {
            XCTFail("expected missingNamedEdge, got \(reason)")
            return
        }
        XCTAssertEqual(replayed.resolvedSketchEntityUpdates[torn.id]?.count, 7)
    }

    // MARK: - Detach

    func testDetachKeepsGeometryIndependentAndSurvivesSourceEdit() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let geometryBefore = targetSketch(plate).entities
        let linkedID = try XCTUnwrap(targetSketch(plate).externalReferences?.first?.entity)

        let reply = CADParameterService(document: plate.document).handle(
            action: "detachExternalReferences",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "entity_id": linkedID.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")

        var sketch = targetSketch(plate)
        XCTAssertEqual(sketch.externalReferences?.count, 3)
        XCTAssertEqual(sketch.entities, geometryBefore, "detach keeps the geometry")
        XCTAssertNil(sketch.externalReference(forEntityID: linkedID))

        // Source edit no longer moves the detached line.
        let source = try XCTUnwrap(plate.document.session.document.sketches
            .first(where: { $0.id == plate.sourceSketch.id }))
        let rectID = try XCTUnwrap(source.entities.first?.id)
        let edit = CADParameterService(document: plate.document).handle(
            action: "updateSketchEntity",
            args: ["sketch_id": plate.sourceSketch.id.raw.uuidString,
                   "entity_id": rectID.uuidString,
                   "max": [140, 60]])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        sketch = targetSketch(plate)
        XCTAssertEqual(sketch.externalReferences?.count, 3)
        let detached = try XCTUnwrap(sketch.entities.first(where: { $0.id == linkedID }))
        let original = try XCTUnwrap(geometryBefore.first(where: { $0.id == linkedID }))
        XCTAssertEqual(detached, original, "detached geometry is independent of the source")
        // The remaining linked entities DID follow the source.
        XCTAssertEqual(projectedMaxX(plate), 140, accuracy: 1e-6)
    }

    func testDetachUndoRedo() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let sketchID = plate.targetSketch.id
        let linkedID = try XCTUnwrap(targetSketch(plate).externalReferences?.first?.entity)

        let reply = CADParameterService(document: plate.document).handle(
            action: "detachExternalReferences",
            args: ["sketch_id": sketchID.raw.uuidString, "entity_id": linkedID.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 3)

        plate.document.session.undo()
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 4,
                       "undo restores the association")
        plate.document.session.redo()
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 3,
                       "redo detaches again")
    }

    func testUpdateSketchEntityRefusesLinkedEntityUntilDetached() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let sketch = targetSketch(plate)
        let linkedID = try XCTUnwrap(sketch.externalReferences?.first?.entity)
        let beforeChangeCount = plate.document.session.changeCount

        let refused = CADParameterService(document: plate.document).handle(
            action: "updateSketchEntity",
            args: ["sketch_id": sketch.id.raw.uuidString,
                   "entity_id": linkedID.uuidString,
                   "a": [1, 1], "b": [2, 2]])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "external_reference")
        XCTAssertEqual(plate.document.session.changeCount, beforeChangeCount,
                       "a refused edit must not touch the document")

        // Detach → the same edit becomes legal ordinary geometry editing.
        let detached = CADParameterService(document: plate.document).handle(
            action: "detachExternalReferences",
            args: ["sketch_id": sketch.id.raw.uuidString, "entity_id": linkedID.uuidString])
        XCTAssertEqual(detached["ok"] as? Bool, true, "\(detached)")
        let accepted = CADParameterService(document: plate.document).handle(
            action: "updateSketchEntity",
            args: ["sketch_id": sketch.id.raw.uuidString,
                   "entity_id": linkedID.uuidString,
                   "a": [1, 1], "b": [2, 2]])
        XCTAssertEqual(accepted["ok"] as? Bool, true, "\(accepted)")
    }

    // MARK: - Ownership precision (solver side effects)

    /// A driving dimension on the LINKED entity itself would require moving
    /// source-driven geometry: refused, with detach as the explicit path.
    func testDrivingDimensionCannotMoveLinkedEntity() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let sketch = targetSketch(plate)
        let linkedID = try XCTUnwrap(sketch.externalReferences?.first?.entity)
        let beforeChangeCount = plate.document.session.changeCount

        let refused = CADParameterService(document: plate.document).handle(
            action: "setSketchDimension",
            args: ["sketch_id": sketch.id.raw.uuidString,
                   "entity_id": linkedID.uuidString,
                   "kind": "length", "value": 50])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "external_reference")
        XCTAssertEqual(plate.document.session.changeCount, beforeChangeCount,
                       "a refused dimension must not touch the document")
    }

    /// Measuring FROM a linked entity TO local geometry stays ordinary: the
    /// dimension is admitted, the solver moves nothing (the local partner
    /// already sits at the measured distance), and the projection keeps its
    /// source-driven position exactly.
    func testMeasuredDimensionOnLinkedEntityDrivesLocalPartner() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        var sketch = targetSketch(plate)
        let linkedID = try XCTUnwrap(sketch.externalReferences?.first?.entity)

        // A local line whose endpointA sits exactly 5 mm from the linked
        // line's endpointA.
        let localID = UUID()
        let linkedLine = try XCTUnwrap(sketch.entities.first { $0.id == linkedID })
        guard case let .line(_, a, _) = linkedLine else {
            XCTFail("projected entity must be a line")
            return
        }
        plate.document.session.perform(AddSketchEntityCommand(
            sketchID: sketch.id,
            entity: .line(id: localID, a: a + SIMD2(5, 0), b: a + SIMD2(5, 10))))
        sketch = targetSketch(plate)

        let reply = CADParameterService(document: plate.document).handle(
            action: "setSketchDimension",
            args: ["sketch_id": sketch.id.raw.uuidString,
                   "refs": [["entity_id": linkedID.uuidString, "role": "endpointA"],
                            ["entity_id": localID.uuidString, "role": "endpointA"]],
                   "kind": "distance", "value": 5])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let after = targetSketch(plate)
        XCTAssertEqual(after.externalReferences?.count, 4, "references untouched")
        XCTAssertEqual(after.entities.first { $0.id == linkedID }, linkedLine,
                       "the linked entity keeps its source-driven geometry")
        XCTAssertEqual(after.entities.first { $0.id == localID },
                       sketch.entities.first { $0.id == localID },
                       "the local partner is not moved by a satisfied measurement")
    }

    func testDeleteLinkedEntityRemovesReferenceAtomically() async throws {
        let plate = try await plate()
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let sketch = targetSketch(plate)
        let linkedID = try XCTUnwrap(sketch.externalReferences?.first?.entity)

        let reply = CADParameterService(document: plate.document).handle(
            action: "deleteSketchEntity",
            args: ["sketch_id": sketch.id.raw.uuidString,
                   "entity_id": linkedID.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        var after = targetSketch(plate)
        XCTAssertNil(after.entities.first(where: { $0.id == linkedID }))
        XCTAssertNil(after.externalReference(forEntityID: linkedID))
        XCTAssertEqual(after.externalReferences?.count, 3)

        plate.document.session.undo()
        after = targetSketch(plate)
        XCTAssertNotNil(after.entities.first(where: { $0.id == linkedID }))
        XCTAssertNotNil(after.externalReference(forEntityID: linkedID),
                        "undo restores entity and reference together")
    }

    // MARK: - Service creation through the real query/identity path

    func testServiceProjectsSelectedEdgesWithQueryToken() async throws {
        let plate = try await plate()

        // The real selected-edge query token/identity path.
        let outcome = plate.document.nativeQueryJSON(["scope": "edges"])
        XCTAssertTrue(outcome.isOK)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        let rows = object["rows"] as? [[String: Any]] ?? []
        let bodyRow = try XCTUnwrap(rows.first { $0["bodyID"] as? String == plate.bodyID.raw.uuidString })
        XCTAssertEqual(bodyRow["naming_stale"] as? Bool, false)
        let token = try XCTUnwrap(bodyRow["query_token"] as? String)
        let edgeRows = bodyRow["edges"] as? [[String: Any]] ?? []
        XCTAssertEqual(edgeRows.count, 12)
        // All 12 named straight finite creases are projectable in principle;
        // which of them degenerate depends on the TARGET plane, and that is
        // the service's degenerate_projection call below.
        func endpointsY(_ row: [String: Any]) -> (Double, Double)? {
            guard let pair = row["endpoints"] as? [[Double]], pair.count == 2,
                  pair[0].count == 3, pair[1].count == 3 else { return nil }
            return (pair[0][1], pair[1][1])
        }
        let straight = edgeRows.filter { ($0["curve"] as? String) == "line" }
        XCTAssertEqual(straight.count, 12, "4 bottom + 4 top + 4 vertical creases")
        XCTAssertEqual(edgeRows.filter { $0["projectable"] as? Bool == true }.count, 12)
        let horizontal = straight.filter { endpointsY($0).map { $0.0 == $0.1 } ?? false }
        let vertical = straight.filter { endpointsY($0).map { $0.0 != $0.1 } ?? false }
        XCTAssertEqual(horizontal.count, 8, "top+bottom rims are the horizontal set")
        XCTAssertEqual(vertical.count, 4, "the four vertical creases")
        XCTAssertNotNil(try XCTUnwrap(straight.first)["edge_name"],
                        "a projectable row carries its stable crease name")

        // Create through the SAME service the UI palette action reaches:
        // the 8 horizontal rims — coincident top/bottom pairs included — so
        // the projection also covers the doubled-profile case end to end.
        let service = CADParameterService(document: plate.document)
        let indexes = horizontal.compactMap { $0["index"] as? Int }
        XCTAssertEqual(indexes.count, 8)
        let created = service.handle(
            action: "projectExternalEdges",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "body_id": plate.bodyID.raw.uuidString,
                   "edge_indexes": indexes,
                   "query_token": token])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        XCTAssertEqual(created["external_references"] as? Int, 8)
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 8)

        // Creation itself advances changeCount. Re-query before checking
        // duplicate/degenerate refusals, and retain the old token for the
        // separate stale-generation assertion below.
        let refreshedOutcome = plate.document.nativeQueryJSON(["scope": "edges"])
        let refreshedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: refreshedOutcome.payload) as? [String: Any])
        let refreshedRows = refreshedObject["rows"] as? [[String: Any]] ?? []
        let refreshedBody = try XCTUnwrap(refreshedRows.first { $0["bodyID"] as? String == plate.bodyID.raw.uuidString })
        let currentToken = try XCTUnwrap(refreshedBody["query_token"] as? String)
        let stale = service.handle(action: "projectExternalEdges", args: [
            "sketch_id": plate.targetSketch.id.raw.uuidString, "body_id": plate.bodyID.raw.uuidString,
            "edge_indexes": indexes, "query_token": token])
        XCTAssertEqual(stale["error"] as? String, "requery_required", "\(stale)")
        let beforeChangeCount = plate.document.session.changeCount
        let duplicate = service.handle(
            action: "projectExternalEdges",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "body_id": plate.bodyID.raw.uuidString,
                   "edge_indexes": indexes,
                   "query_token": currentToken])
        XCTAssertEqual(duplicate["error"] as? String, "duplicate_projection", "\(duplicate)")
        XCTAssertEqual(plate.document.session.changeCount, beforeChangeCount)

        // A degenerate (normal-parallel) edge refuses with the typed code.
        let verticalIndexes = vertical.compactMap { $0["index"] as? Int }
        let refused = service.handle(
            action: "projectExternalEdges",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "body_id": plate.bodyID.raw.uuidString,
                   "edge_index": verticalIndexes[0],
                   "query_token": currentToken])
        XCTAssertEqual(refused["error"] as? String, "degenerate_projection", "\(refused)")

        // An index that does not exist on the current source refuses.
        let unknown = service.handle(
            action: "projectExternalEdges",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "body_id": plate.bodyID.raw.uuidString,
                   "edge_index": 999,
                   "query_token": currentToken])
        XCTAssertEqual(unknown["error"] as? String, "unknown_edge", "\(unknown)")

        // Index without any generation/midpoint proof refuses as not-an-identity.
        let noProof = service.handle(
            action: "projectExternalEdges",
            args: ["sketch_id": plate.targetSketch.id.raw.uuidString,
                   "body_id": plate.bodyID.raw.uuidString,
                   "edge_index": indexes[0]])
        XCTAssertEqual(noProof["error"] as? String, "requery_required", "\(noProof)")

        // Source edit → the projection follows through the same rebuild.
        let source = try XCTUnwrap(plate.document.session.document.sketches
            .first(where: { $0.id == plate.sourceSketch.id }))
        let rectID = try XCTUnwrap(source.entities.first?.id)
        let edit = service.handle(
            action: "updateSketchEntity",
            args: ["sketch_id": plate.sourceSketch.id.raw.uuidString,
                   "entity_id": rectID.uuidString,
                   "max": [140, 60]])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(projectedMaxX(plate), 140, accuracy: 1e-6)

        // Detach through the service; the row count drops and a re-create of
        // the same edge becomes legal again.
        let sketch = targetSketch(plate)
        let firstID = try XCTUnwrap(sketch.externalReferences?.first?.entity)
        let detached = service.handle(
            action: "detachExternalReferences",
            args: ["sketch_id": sketch.id.raw.uuidString, "entity_id": firstID.uuidString])
        XCTAssertEqual(detached["ok"] as? Bool, true, "\(detached)")
        XCTAssertEqual(targetSketch(plate).externalReferences?.count, 7)
    }

    func testMidpointProofMustCoverEveryRequestedEdgeAndNumericIndexesAreExact() async throws {
        let plate = try await plate()
        let outcome = plate.document.nativeQueryJSON(["scope": "edges"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        let rows = object["rows"] as? [[String: Any]] ?? []
        let body = try XCTUnwrap(rows.first { $0["bodyID"] as? String == plate.bodyID.raw.uuidString })
        let token = try XCTUnwrap(body["query_token"] as? String)
        let edges = body["edges"] as? [[String: Any]] ?? []
        let first = try XCTUnwrap(edges.first)
        let index = try XCTUnwrap(first["index"] as? Int)
        let second = try XCTUnwrap(edges.dropFirst().first?["index"] as? Int)
        let midpoint = try XCTUnwrap(first["midpoint"] as? [Double])
        let service = CADParameterService(document: plate.document)
        let before = plate.document.session.persistenceChangeCount
        let badMidpoints: [Any] = [[midpoint], [[0, 0]], [[Double.nan, 0, 0], midpoint]]
        for proof in badMidpoints {
            let result = service.handle(action: "projectExternalEdges", args: [
                "sketch_id": plate.targetSketch.id.raw.uuidString,
                "body_id": plate.bodyID.raw.uuidString,
                "edge_indexes": [index, second], "edge_midpoints": proof])
            XCTAssertEqual(result["error"] as? String, "stale_edge_ref", "\(result)")
        }
        let badIndexes: [Any] = [true, 1.5, Double.infinity]
        for value in badIndexes {
            let result = service.handle(action: "projectExternalEdges", args: [
                "sketch_id": plate.targetSketch.id.raw.uuidString,
                "body_id": plate.bodyID.raw.uuidString,
                "edge_index": value, "query_token": token])
            XCTAssertEqual(result["error"] as? String, "bad_edge_indexes", "\(result)")
        }
        XCTAssertEqual(plate.document.session.persistenceChangeCount, before)
        XCTAssertFalse(targetSketch(plate).hasExternalReferences)
    }

    /// Real curved kernel rims are refused by the exact projection adapter.
    func testCurvedKernelEdgesAreRefusedExactly() throws {
        let spec = PrimitiveSpec.cylinder(radius: 20, height: 30)
        var body = Body(name: "Cylinder", euclidMesh: .primitive(spec), revision: 0)
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))
        XCTAssertTrue(body.adoptBRep(brep))
        let writer = FeatureID()
        let table = SignatureNaming().faceTable(for: body, createdBy: writer, scheme: .generic)
        let named = ElementNaming.namePrimitiveEntries(table, creator: writer)
        let kernelNames = ElementNaming.kernelNames(
            from: named, channel: OCCTKernel.renderMeshFaceChannel(from: brep))
        XCTAssertFalse(kernelNames.isEmpty)
        let snapshot = GeometryVersionSnapshot(
            body: body, faceTable: table, kernelNames: kernelNames, stamp: 1)
        let linked = ProjectionKit.linked(
            snapshot: snapshot,
            version: GeometryVersionRef(bodyID: body.id, writer: writer),
            onto: .ground)
        XCTAssertEqual(linked.entities.count, 0)
        XCTAssertEqual(linked.references.count, 0)
        XCTAssertEqual(linked.skippedCurved, 2, "two circular rims refused exactly")
    }

    // MARK: - Save / reopen

    func testSaveReopenPersistsReferencesAndReprojects() async throws {
        let url = url()
        let plate = try await plate(at: url)
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let saved = await plate.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        plate.document.close()

        let reopened = try await open(url)
        let sketch = try XCTUnwrap(reopened.session.document.sketches
            .first(where: { $0.id == plate.targetSketch.id }))
        XCTAssertEqual(sketch.externalReferences?.count, 4,
                       "references persist through save/reopen")
        XCTAssertEqual(maxX(in: sketch), 100, accuracy: 1e-6)

        // A source edit after reopen re-projects through the ordinary rebuild.
        let source = try XCTUnwrap(reopened.session.document.sketches
            .first(where: { $0.id == plate.sourceSketch.id }))
        let rectID = try XCTUnwrap(source.entities.first?.id)
        let reply = CADParameterService(document: reopened).handle(
            action: "updateSketchEntity",
            args: ["sketch_id": plate.sourceSketch.id.raw.uuidString,
                   "entity_id": rectID.uuidString,
                   "max": [140, 60]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let plateAgain = Plate(document: reopened, sourceSketch: plate.sourceSketch,
                               source: plate.source, bodyID: plate.bodyID,
                               targetSketch: plate.targetSketch)
        XCTAssertEqual(projectedMaxX(plateAgain), 140, accuracy: 1e-6)
    }

    // MARK: - Coordinated non-additive format floor

    func testLinkedSketchRaisesExternalProjectionFormatFloor() async throws {
        let url = url()
        let plate = try await plate(at: url)
        // The plain plate + empty target sketch is still an additive
        // format-1 document; only the LINKED sketch is non-additive.
        let plain = await plate.document.save()
        XCTAssertTrue(plain.succeeded, plain.error ?? "")
        XCTAssertEqual(try manifestSchemaVersion(url), 1)
        let edges = try sourceEdges(plate)
        try project(plate, selected: rectangleEdgeNames(edges))
        let linked = await plate.document.save()
        XCTAssertTrue(linked.succeeded, linked.error ?? "")
        XCTAssertEqual(try manifestSchemaVersion(url),
                       CADDocumentFormat.externalSketchProjectionVersion,
                       "a sketch carrying external references raises the new "
                        + "non-additive floor older released writers cannot open")
    }

    /// Old-reader/floor honesty at the row boundary: a reference at a FUTURE
    /// semantic version opens opaque read-only (bytes preserved, display
    /// portion proven readable); a KNOWN-version reference with a corrupt
    /// contract is malformed corruption, never reinterpreted as plain
    /// geometry. The M07 support floor stays intact for support-only rows.
    func testReferenceVersionFloorAndUnknownRefAdmission() throws {
        // Base rows come from a REAL encoded sketch so the only variable in
        // each scenario is the association payload itself.
        let sketch = Sketch(name: "Projection", plane: .ground, entities: [])
        let baseRow = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sketch)) as? [String: Any])
        func blob(_ object: [String: Any]) throws -> CADBlobRecord {
            CADBlobRecord(blobID: sketch.id.raw,
                          data: try JSONSerialization.data(withJSONObject: object),
                          sha256: "test")
        }

        // Future semantic version → opaque read-only at the new floor.
        var future = baseRow
        future["externalReferences"] = [[
            "version": SketchExternalReference.supportedVersion + 1,
            "entity": UUID().uuidString,
            "sourceVersion": ["bodyID": UUID().uuidString, "writer": UUID().uuidString],
            "source": ["body": ["producer": UUID().uuidString, "bodyID": UUID().uuidString],
                       "signature": [:], "faceNames": [:]],
        ]]
        let futureAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [blob(future)])
        XCTAssertEqual(futureAssessment.requiredVersion,
                       CADDocumentFormat.externalSketchProjectionVersion)
        XCTAssertTrue(futureAssessment.opaqueSketches.contains(sketch.id.raw))

        // Known version with a corrupt contract → malformed, not plain.
        var corrupt = baseRow
        corrupt["externalReferences"] = [["version": 1, "entity": "not-a-uuid"]]
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [blob(corrupt)])) { error in
            guard case CADDocumentFormatError.malformedAssociation(let field) = error else {
                XCTFail("expected malformedAssociation, got \(error)")
                return
            }
            XCTAssertEqual(field, "sketch-external-reference")
        }

        // M07 invariant: a support-only row keeps the associative floor(2).
        var supported = baseRow
        supported["support"] = ["source": ["ground": [:]], "offset": [:]]
        let supportedAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [blob(supported)])
        XCTAssertEqual(supportedAssessment.requiredVersion,
                       CADDocumentFormat.associativeVersion)
        XCTAssertFalse(supportedAssessment.isOpaqueReadOnly)
    }

    func testMalformedExternalReferenceFieldCannotDowngradeToPlainSketch() throws {
        let sketch = Sketch(name: "Projection", plane: .ground)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sketch)) as? [String: Any])
        let future: [String: Any] = ["version": SketchExternalReference.supportedVersion + 1]
        let badValues: [Any] = [
            NSNull(), "not-an-array", ["version": 1],
            ["not-a-reference"], [NSNull()], [["version": true]],
            [["version": 1.5]], [["version": 0]],
            [future, ["version": 1, "entity": "not-a-uuid"]],
            [future, "bad-sibling"],
        ]
        for value in badValues {
            var row = base
            row["externalReferences"] = value
            let blob = CADBlobRecord(blobID: sketch.id.raw,
                data: try JSONSerialization.data(withJSONObject: row), sha256: "test")
            XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [blob])) { error in
                XCTAssertEqual(error as? CADDocumentFormatError,
                               .malformedAssociation("sketch-external-reference"))
            }
        }
        var empty = base
        empty["externalReferences"] = []
        let emptyBlob = CADBlobRecord(blobID: sketch.id.raw,
            data: try JSONSerialization.data(withJSONObject: empty), sha256: "test")
        XCTAssertEqual(try CADDocumentFormat.assess(planes: [], sketches: [emptyBlob]).requiredVersion, 1)
    }

    private func manifestSchemaVersion(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["schemaVersion"] as? Int)
    }
}
