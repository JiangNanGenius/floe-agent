import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Exercises the production session, service and file store. All geometry is
/// built by the real named OCCT extrusion path (no fabricated face maps).
@MainActor
final class CADAssociativeSessionTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeDatumSession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Fixture {
        var document: FloeCADDocument
        var source: FeatureNode
        var sourceBody: BodyID
        var plane: ConstructionPlane
        var childSketch: Sketch
        var child: FeatureNode
        var childBody: BodyID
    }

    private func extrusion(_ sketch: Sketch, distance: Double, body: BodyID, name: String) -> FeatureNode {
        FeatureNode(name: name, kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: sketch.entities.map(\.id),
                                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    private func fixture(installAssociation: Bool = true) async throws -> Fixture {
        let url = directory.appendingPathComponent("\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Associated plate")
        documents.append(document)
        let sketch = Sketch(name: "Source", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60))])
        let sourceBody = BodyID()
        let source = extrusion(sketch, distance: 10, body: sourceBody, name: "Plate")
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)], title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let body = try XCTUnwrap(document.session.document.body(with: sourceBody))
        let brep = try XCTUnwrap(body.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let name = try XCTUnwrap(document.session.lastKernelNames[sourceBody]?[face.index])
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: sourceBody), creator: name.creator,
                          role: .extrudeEndCap, signature: try XCTUnwrap(face.signature), elementName: name)
        let frame = try PlaneAttachmentFrame.make(faceCentroid: face.centroid, faceNormal: face.normal,
                                                referenceXAxis: SIMD3(1, 0, 0), anchorPoint: face.centroid)
        let definition = OffsetPlaneDefinition(source: ref,
            sourceVersion: GeometryVersionRef(bodyID: sourceBody, writer: source.id),
            distance: Expr(value: 5), attachment: frame)
        let plane = ConstructionPlane(plane: .offsetGround(y: -999), size: 120, definition: .offset(definition))
        let childSketch = Sketch(name: "Supported", plane: .offsetGround(y: -888), entities: [
            .rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))],
            support: PlaneRef(source: .construction(plane.id)))
        let childBody = BodyID()
        let child = extrusion(childSketch, distance: 3, body: childBody, name: "Child")
        let result = Fixture(document: document, source: source, sourceBody: sourceBody,
                             plane: plane, childSketch: childSketch, child: child, childBody: childBody)
        if installAssociation { XCTAssertTrue(install(result)) }
        return result
    }

    @discardableResult
    private func install(_ fixture: Fixture) -> Bool {
        fixture.document.session.performAssociativeTransaction([
            AddConstructionPlaneCommand(plane: fixture.plane), AddSketchCommand(sketch: fixture.childSketch),
            AppendFeatureCommand(node: fixture.child, title: "Supported extrusion")], title: "Supported extrusion")
    }

    private func assertPlacement(_ fixture: Fixture, y: Double,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let session = fixture.document.session
        XCTAssertTrue(session.lastEvalErrors.isEmpty, "\(session.lastEvalErrors)", file: file, line: line)
        XCTAssertTrue(session.lastReferenceErrors.isEmpty, "\(session.lastReferenceErrors)", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(session.document.planes.first { $0.id == fixture.plane.id }).plane.origin.y,
                       y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(session.document.sketches.first { $0.id == fixture.childSketch.id }).plane.origin.y,
                       y, accuracy: 1e-6, file: file, line: line)
        let body = try XCTUnwrap(session.document.body(with: fixture.childBody), file: file, line: line)
        let minimumY = try XCTUnwrap(body.render.positions.map {
            body.transform.applying(to: SIMD3<Double>($0)).y
        }.min(), file: file, line: line)
        XCTAssertEqual(minimumY, y, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep)), 24, accuracy: 1e-4, file: file, line: line)
    }

    private func definition(_ fixture: Fixture) throws -> OffsetPlaneDefinition {
        let plane = try XCTUnwrap(fixture.document.session.document.planes.first { $0.id == fixture.plane.id })
        return try XCTUnwrap({
            if case let .offset(value)? = plane.definition { return value }
            return nil
        }(), "Fixture lost definition")
    }

    func testReplacingProfileIdentityNeverRebindsTheDeletedNamedWall() async throws {
        let f = try await fixture(installAssociation: false)
        let session = f.document.session
        let original = try XCTUnwrap(session.document.body(with: f.sourceBody))
        let brep = try XCTUnwrap(original.brep)
        let side = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.x > 0.99 })
        let name = try XCTUnwrap(session.lastKernelNames[f.sourceBody]?[side.index])
        guard case .profileWall = name.source else {
            return XCTFail("The fixture must select a real profile-owned wall")
        }
        let reference = FaceRef(
            body: BodyRef(producer: f.source.id, bodyID: f.sourceBody),
            creator: name.creator, role: .extrudeWall(loopIndex: 0, edgeIndex: 0),
            signature: try XCTUnwrap(side.signature), elementName: name)
        XCTAssertEqual(session.naming.resolve(reference, in: original,
                          table: session.lastFaceTables[f.sourceBody])?.elementName, name)

        // Replace the sketch entity, keeping the feature/body/sketch ids and
        // all geometric dimensions. The old wall identity was deleted; an
        // identical-looking replacement is not proof that it is the same face.
        guard case let .extrude(profile, plane, distance, symmetric, boolean, extras) = f.source.kind else {
            return XCTFail("Expected the production extrusion fixture")
        }
        let oldSketch = try XCTUnwrap(session.document.sketch(with: profile.sketchID))
        var newSketch = oldSketch
        let replacementID = UUID()
        newSketch.entities = [.rect(id: replacementID, min: SIMD2(0, 0), max: SIMD2(100, 60))]
        var newProfile = profile
        newProfile.entityIDs = [replacementID]
        let newKind = FeatureKind.extrude(
            profile: newProfile, plane: plane, distance: distance,
            symmetric: symmetric, boolean: boolean, extraProfiles: extras)
        XCTAssertTrue(session.performAssociativeTransaction([
            ReplaceSketchGeometryCommand(title: "Replace profile identity",
                                          before: oldSketch, after: newSketch),
            EditFeatureCommand(featureID: f.source.id, before: f.source.kind, after: newKind),
        ], title: "Replace profile identity"))
        XCTAssertTrue(session.lastEvalErrors.isEmpty)
        let replacement = try XCTUnwrap(session.document.body(with: f.sourceBody))
        XCTAssertEqual(replacement.render.localAABB.min, original.render.localAABB.min)
        XCTAssertEqual(replacement.render.localAABB.max, original.render.localAABB.max)
        XCTAssertFalse(session.lastKernelNames[f.sourceBody]?.values.contains(name) ?? true)
        XCTAssertNil(session.naming.resolve(reference, in: replacement,
                        table: session.lastFaceTables[f.sourceBody]),
                     "A lost named face must not silently bind to similar replacement geometry")

        session.undo()
        let restored = try XCTUnwrap(session.document.body(with: f.sourceBody))
        XCTAssertEqual(session.naming.resolve(reference, in: restored,
                          table: session.lastFaceTables[f.sourceBody])?.elementName, name)
        XCTAssertEqual(session.document.sketch(with: oldSketch.id)?.entities.map(\.id),
                       oldSketch.entities.map(\.id))
        session.redo()
        let redone = try XCTUnwrap(session.document.body(with: f.sourceBody))
        XCTAssertNil(session.naming.resolve(reference, in: redone,
                        table: session.lastFaceTables[f.sourceBody]))
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "profile replacement must save")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        reopened.session.rebuildFrom(f.source.id)
        let loaded = try XCTUnwrap(reopened.session.document.body(with: f.sourceBody))
        XCTAssertFalse(reopened.session.lastKernelNames[f.sourceBody]?.values.contains(name) ?? true)
        XCTAssertNil(reopened.session.naming.resolve(reference, in: loaded,
                        table: reopened.session.lastFaceTables[f.sourceBody]),
                     "Reopening cannot turn a deleted face identity into a geometric guess")
    }

    func testThicknessEditUpdatesPlaneSketchAndExactChildAsOneUndo() async throws {
        let f = try await fixture()
        let session = f.document.session
        try assertPlacement(f, y: 15)
        guard case let .extrude(profile, plane, _, symmetric, boolean, extras) = f.source.kind else { return XCTFail() }
        let after = FeatureKind.extrude(profile: profile, plane: plane, distance: Expr(value: 20),
            symmetric: symmetric, boolean: boolean, extraProfiles: extras)
        session.rebuildFrom(f.source.id, edit: EditFeatureCommand(featureID: f.source.id, before: f.source.kind, after: after))
        try assertPlacement(f, y: 25)
        XCTAssertEqual(session.lastBodyWriters[f.sourceBody], f.source.id)
        session.undo()
        try assertPlacement(f, y: 15)
        session.redo()
        try assertPlacement(f, y: 25)
    }

    func testCreationAndDefinitionEditIncludeAllDerivedStateInOneUndo() async throws {
        let f = try await fixture(installAssociation: false)
        let session = f.document.session
        XCTAssertTrue(install(f))
        try assertPlacement(f, y: 15)
        session.undo()
        XCTAssertFalse(session.document.planes.contains { $0.id == f.plane.id })
        XCTAssertFalse(session.document.sketches.contains { $0.id == f.childSketch.id })
        XCTAssertNil(session.document.body(with: f.childBody))
        session.redo()
        try assertPlacement(f, y: 15)
        var after = try definition(f)
        after.distance = Expr(value: -2)
        XCTAssertTrue(session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: f.plane.id, before: .offset(try definition(f)), after: .offset(after))], title: "Offset"))
        try assertPlacement(f, y: 8)
        session.undo()
        try assertPlacement(f, y: 15)
    }

    func testVariableFanOutRenameQueryDeleteAndUndoIncludeOffsetFormula() async throws {
        let f = try await fixture()
        let session = f.document.session
        let service = CADParameterService(document: f.document)
        let create = service.handle(action: "variable.create", args: ["name": "gap", "expression": "5"])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let variable = try XCTUnwrap(session.document.variables.first)
        let before = try definition(f)
        var bound = before
        bound.distance = Expr(value: 5, formula: "gap + max(0, 0)")
        XCTAssertTrue(session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: f.plane.id, before: .offset(before), after: .offset(bound))], title: "Bind"))
        let update = service.handle(action: "variable.update", args: ["variable_id": variable.id.raw.uuidString, "expression": "12"])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        try assertPlacement(f, y: 22)
        XCTAssertEqual(try definition(f).distance.value, 12)
        session.undo()
        try assertPlacement(f, y: 15)
        XCTAssertEqual(try definition(f).distance.value, 5)
        session.redo()
        try assertPlacement(f, y: 22)
        let rename = service.handle(action: "variable.update", args: ["variable_id": variable.id.raw.uuidString, "name": "offset"])
        XCTAssertEqual(rename["ok"] as? Bool, true, "\(rename)")
        XCTAssertEqual(rename["rewritten_plane_ids"] as? [String], [f.plane.id.raw.uuidString])
        XCTAssertEqual(try definition(f).distance.formula, "offset + max(0, 0)")
        let dependents = CADParameterService.variableDependents(of: "offset", in: session.document)
        XCTAssertEqual(dependents["plane_ids"] as? [String], [f.plane.id.raw.uuidString])
        let rejected = service.handle(action: "variable.delete", args: ["variable_id": variable.id.raw.uuidString])
        XCTAssertEqual(rejected["error"] as? String, "variable_in_use")
        XCTAssertEqual(rejected["dependent_plane_ids"] as? [String], [f.plane.id.raw.uuidString])
        try assertPlacement(f, y: 22)
        session.undo()
        XCTAssertEqual(try definition(f).distance.formula, "gap + max(0, 0)")
        XCTAssertEqual(session.document.variables.first?.name, "gap")
    }

    func testFailedFirstAssociationPreservesFormatPackageAndRedo() async throws {
        var f = try await fixture(installAssociation: false)
        let session = f.document.session
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: sentinel))
        session.undo()
        XCTAssertTrue(session.undoStack.canRedo)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let before = try CADAssociativeFormatFixture.bytes(f.document.url)
        let count = session.changeCount
        var broken = try XCTUnwrap(f.plane.definition)
        if case let .offset(value) = broken {
            broken = .offset(OffsetPlaneDefinition(version: value.version, source: value.source,
                sourceVersion: GeometryVersionRef(bodyID: value.sourceVersion.bodyID, writer: FeatureID()),
                distance: value.distance, attachment: value.attachment))
        }
        f.plane.definition = broken
        XCTAssertFalse(install(f))
        XCTAssertGreaterThan(session.changeCount, count)
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertEqual(f.document.project.formatVersion, 1)
        XCTAssertFalse(session.document.planes.contains { $0.id == f.plane.id })
        XCTAssertFalse(session.lastRebuildRejection.isEmpty)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), before)
        let afterSave = await f.document.save()
        XCTAssertTrue(afterSave.succeeded, afterSave.error ?? "")
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(f.document.url).schemaVersion, 1)
        session.redo()
        XCTAssertTrue(session.document.planes.contains { $0.id == sentinel.id })
        XCTAssertNil(session.document.body(with: f.childBody))
    }

    func testGraphMutationsRefuseNewBrokenUnusedDatumAndServiceReportsFailure() async throws {
        let f = try await fixture()
        let session = f.document.session
        // Remove the consumer and support, leaving a valid but unused datum.
        session.deleteFeature(f.child.id)
        session.perform(try XCTUnwrap(DeleteSketchCommand(id: f.childSketch.id, document: session.document)))
        let service = CADParameterService(document: f.document)
        let suppressed = service.handle(action: "feature.suppress", args: ["feature_id": f.source.id.raw.uuidString, "suppressed": true])
        XCTAssertEqual(suppressed["ok"] as? Bool, false, "\(suppressed)")
        XCTAssertEqual(suppressed["error"] as? String, "rebuild_failed")
        XCTAssertEqual(session.document.features.node(f.source.id)?.suppressed, false)
        XCTAssertFalse(session.lastRebuildRejection.isEmpty)
        let deleted = service.handle(action: "feature.delete", args: ["feature_id": f.source.id.raw.uuidString, "force": true])
        XCTAssertEqual(deleted["ok"] as? Bool, false, "\(deleted)")
        XCTAssertNotNil(session.document.features.node(f.source.id))
        session.setRollback(0)
        XCTAssertNil(session.document.features.rollbackIndex)
        XCTAssertFalse(session.lastRebuildRejection.isEmpty)
    }

    func testMoveBeforeSourceRefusesWithoutRebindingAndKeepsRedo() async throws {
        let f = try await fixture()
        let session = f.document.session
        let extra = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: extra))
        session.undo()
        XCTAssertTrue(session.undoStack.canRedo)
        let order = session.document.features.nodes.map(\.id)
        session.moveFeature(f.child.id, to: 0)
        XCTAssertEqual(session.document.features.nodes.map(\.id), order)
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertFalse(session.lastRebuildRejection.isEmpty)
        XCTAssertEqual(try definition(f).sourceVersion.writer, f.source.id)
        try assertPlacement(f, y: 15)
    }

    func testSaveReopenUsesVariablesAndKeepsSemanticRecordsAndGeneration() async throws {
        var f = try await fixture()
        let service = CADParameterService(document: f.document)
        XCTAssertEqual(service.handle(action: "variable.create", args: ["name": "gap", "expression": "7"])["ok"] as? Bool, true)
        var after = try definition(f)
        after.distance = Expr(value: 7, formula: "gap")
        XCTAssertTrue(f.document.session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: f.plane.id, before: f.plane.definition, after: .offset(after))], title: "Bind offset"))
        try assertPlacement(f, y: 17)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = f.document.url
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        f.document = reopened
        let generation = reopened.session.changeCount
        let bytes = try CADAssociativeFormatFixture.bytes(url)
        // Await the actual load badge replay, with a bounded yield loop rather
        // than using cached messages as evidence. No geometry is committed.
        for _ in 0..<200 where reopened.session.lastBodyWriters[f.sourceBody] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.session.lastBodyWriters[f.sourceBody], f.source.id)
        XCTAssertEqual(reopened.session.changeCount, generation)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), bytes)
        XCTAssertEqual(try definition(f).distance.formula, "gap")
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == f.childSketch.id }?.support,
                       PlaneRef(source: .construction(f.plane.id)))
        try assertPlacement(f, y: 17)
        let variable = try XCTUnwrap(reopened.session.document.variables.first)
        let result = CADParameterService(document: reopened).handle(action: "variable.update", args: [
            "variable_id": variable.id.raw.uuidString, "expression": "9"])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        try assertPlacement(f, y: 19)
    }

    func testCheckpointRestoresReferenceAndWriterDiagnostics() async throws {
        let f = try await fixture()
        let session = f.document.session
        let checkpoint = f.document.captureEditCheckpoint()
        let writers = session.lastBodyWriters
        let count = session.changeCount
        session.undo()
        XCTAssertNil(session.document.planes.first { $0.id == f.plane.id })
        f.document.restoreEditCheckpoint(checkpoint)
        XCTAssertGreaterThan(session.changeCount, count)
        XCTAssertEqual(session.lastBodyWriters, writers)
        XCTAssertTrue(session.lastReferenceErrors.isEmpty)
        try assertPlacement(f, y: 15)
    }
    func testInvalidVariableOffsetRefusesWithoutLosingRedoOrCachedGeometry() async throws {
        let f = try await fixture()
        let service = CADParameterService(document: f.document)
        let session = f.document.session
        XCTAssertEqual(service.handle(action: "variable.create", args: ["name": "divisor", "expression": "2"])["ok"] as? Bool, true)
        let variable = try XCTUnwrap(session.document.variables.first)
        var after = try definition(f)
        after.distance = Expr(value: 5, formula: "10 / divisor")
        XCTAssertTrue(session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: f.plane.id, before: f.plane.definition, after: .offset(after))], title: "Bind"))
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: sentinel))
        session.undo()
        let revision = try XCTUnwrap(session.document.body(with: f.childBody)).meshRevision
        let result = service.handle(action: "variable.update", args: [
            "variable_id": variable.id.raw.uuidString, "expression": "0"])
        XCTAssertEqual(result["error"] as? String, "rebuild_failed", "\(result)")
        XCTAssertEqual(session.document.variables.first?.expression, "2")
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertEqual(try XCTUnwrap(session.document.body(with: f.childBody)).meshRevision, revision)
        XCTAssertEqual(try definition(f).distance.value, 5)
        try assertPlacement(f, y: 15)
        session.redo()
        XCTAssertTrue(session.document.planes.contains { $0.id == sentinel.id })
    }

    func testReadOnlySourceSnapshotIsActualWriterAndDoesNotMutateDocument() async throws {
        let f = try await fixture(installAssociation: false)
        let session = f.document.session
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: sentinel))
        session.undo()
        let count = session.changeCount
        let revision = try XCTUnwrap(session.document.body(with: f.sourceBody)).meshRevision
        let snapshot = try XCTUnwrap(session.associativeSource(for: f.sourceBody))
        XCTAssertEqual(snapshot.version, GeometryVersionRef(bodyID: f.sourceBody, writer: f.source.id))
        XCTAssertFalse(snapshot.snapshot.kernelNames.isEmpty)
        XCTAssertNotNil(snapshot.snapshot.body.brep)
        XCTAssertEqual(session.changeCount, count)
        XCTAssertEqual(session.document.body(with: f.sourceBody)?.meshRevision, revision)
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertNil(session.associativeSource(for: BodyID()))
    }

    func testExistingBrokenUnusedDatumCanBeRepairedAndDoesNotBlockOtherValidEdits() async throws {
        let f = try await fixture()
        let session = f.document.session
        let original = try self.definition(f)
        var definition = OffsetPlaneDefinition(version: original.version, source: original.source,
            sourceVersion: GeometryVersionRef(bodyID: original.sourceVersion.bodyID, writer: FeatureID()),
            distance: original.distance, attachment: original.attachment)
        let broken = ConstructionPlane(plane: f.plane.plane, size: f.plane.size,
                                       definition: .offset(definition))
        // Represents a pre-existing broken package. The domain transaction must
        // compare actual baseline diagnostics, even before load badges arrive.
        session.perform(AddConstructionPlaneCommand(plane: broken))
        var validEdit = try self.definition(f)
        validEdit.distance = Expr(value: 7)
        XCTAssertTrue(session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: f.plane.id, before: f.plane.definition, after: .offset(validEdit))], title: "Valid edit"))
        XCTAssertNotNil(session.lastReferenceErrors[.plane(broken.id)])
        XCTAssertEqual(session.document.planes.first { $0.id == f.plane.id }?.plane.origin.y, 17)
        definition = OffsetPlaneDefinition(version: definition.version, source: definition.source,
            sourceVersion: GeometryVersionRef(bodyID: definition.sourceVersion.bodyID, writer: f.source.id),
            distance: definition.distance, attachment: definition.attachment)
        XCTAssertTrue(session.performAssociativeTransaction([EditConstructionPlaneDefinitionCommand(
            planeID: broken.id, before: broken.definition, after: .offset(definition))], title: "Repair"))
        XCTAssertTrue(session.lastReferenceErrors.isEmpty)
        XCTAssertEqual(session.document.planes.first { $0.id == broken.id }?.plane.origin.y, 15)
    }

    func testUnusedSketchSupportUsesGuardedSketchTransactionWithoutFeatureConsumer() async throws {
        let f = try await fixture(installAssociation: false)
        let session = f.document.session
        let sketch = Sketch(name: "Unused", plane: .ground)
        session.perform(AddSketchCommand(sketch: sketch))
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: sentinel))
        session.undo()
        let missing = ConstructionPlaneID()
        session.performWithSketchRebuild(ChangeSketchSupportCommand(
            sketchID: sketch.id, before: nil, after: PlaneRef(source: .construction(missing)),
            beforePlane: sketch.plane, afterPlane: sketch.plane), sketchID: sketch.id)
        XCTAssertNil(session.document.sketches.first { $0.id == sketch.id }?.support)
        XCTAssertEqual(session.lastRebuildRejection[.sketch(sketch.id)], .missingPlane(missing))
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertEqual(f.document.project.formatVersion, 1)
    }

    func testHistoryViewModelShowsRefusalWithoutChangingModelOrUndoHistory() async throws {
        let f = try await fixture()
        let session = f.document.session
        let vm = f.document.viewModel()
        let order = session.document.features.nodes.map(\.id)
        let bodyRevision = session.document.body(with: f.childBody)?.meshRevision
        let format = f.document.project.formatVersion
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        session.perform(AddConstructionPlaneCommand(plane: sentinel))
        session.undo()
        XCTAssertTrue(session.undoStack.canRedo)
        vm.setFeatureSuppressed(f.source.id, true)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(session.document.features.node(f.source.id)?.suppressed, false)
        XCTAssertEqual(session.document.features.nodes.map(\.id), order)
        XCTAssertEqual(session.document.body(with: f.childBody)?.meshRevision, bodyRevision)
        XCTAssertEqual(f.document.project.formatVersion, format)
        XCTAssertTrue(session.undoStack.canRedo)
        try assertPlacement(f, y: 15)
        vm.errorMessage = nil
        vm.moveFeature(f.child.id, to: 0)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(session.document.features.nodes.map(\.id), order)
        XCTAssertTrue(session.undoStack.canRedo)
    }

}
