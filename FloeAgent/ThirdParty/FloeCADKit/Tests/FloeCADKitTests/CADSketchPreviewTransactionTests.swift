import Foundation
import XCTest
import Dispatch
import simd
@testable import FloeCAD

/// Production Session + named OCCT + package store. Test gates synchronize on
/// actual prewarm/commit entry; no yield/sleep guesses establish race order.
@MainActor
final class CADSketchPreviewTransactionTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADSketchPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        for document in documents {
            document.session.savePrewarmSuspensionForTesting = nil
            document.close()
        }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private struct Fixture {
        var document: FloeCADDocument
        var sourceSketch: Sketch
        var source: FeatureNode
        var sourceBody: BodyID
        var plane: ConstructionPlaneID
        var childSketch: SketchID
        var child: BodyID
    }
    private func extrude(_ sketch: Sketch, distance: Double, body: BodyID) -> FeatureNode {
        FeatureNode(name: "Extrusion", kind: .extrude(profile: ProfileRef(sketchID: sketch.id,
            entityIDs: sketch.entities.map(\.id), holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance), symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [body])
    }
    private func fixture(drawing: Bool = false) async throws -> Fixture {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Preview")
        documents.append(document)
        let sketch = Sketch(name: "Source", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(40, 30))])
        let sourceBody = BodyID()
        let source = extrude(sketch, distance: 10, body: sourceBody)
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)], title: "Plate")
        let faces = try query(document, "faces")
        let face = try XCTUnwrap(faces.first {
            ($0["bodyID"] as? String) == sourceBody.raw.uuidString && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99
        })
        let created = CADParameterService(document: document).handle(action: "datum.offsetPlane.create", args: [
            "body_id": sourceBody.raw.uuidString, "face_index": try XCTUnwrap(face["index"]),
            "query_token": try XCTUnwrap(face["query_token"]), "expression": "5"])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let plane = ConstructionPlaneID(raw: try XCTUnwrap((created["plane_id"] as? String).flatMap(UUID.init(uuidString:))))
        let frame = try XCTUnwrap(document.session.document.planes.first { $0.id == plane }).plane
        let childSketch = Sketch(name: "Supported", plane: frame, entities: [
            .rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))], support: PlaneRef(source: .construction(plane)))
        let child = BodyID()
        document.session.recordAndRebuild([extrude(childSketch, distance: 3, body: child)],
            extra: [AddSketchCommand(sketch: childSketch)], title: "Child")
        if drawing {
            let sheet = CADDrawingService(document: document).handle(action: "standardSheet", args: ["bodyID": sourceBody.raw.uuidString])
            XCTAssertEqual(sheet["ok"] as? Bool, true, "\(sheet)")
        }
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertFalse(document.hasUnsavedChanges)
        return Fixture(document: document, sourceSketch: sketch, source: source, sourceBody: sourceBody,
                       plane: plane, childSketch: childSketch.id, child: child)
    }
    private func query(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let result = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(result.isOK, result.message ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }
    private func currentSketch(_ f: Fixture) throws -> Sketch {
        try XCTUnwrap(f.document.session.document.sketches.first { $0.id == f.sourceSketch.id })
    }
    private func changedSketch(_ f: Fixture, width: Double) throws -> Sketch {
        var sketch = try currentSketch(f)
        guard case let .rect(id, min, max) = sketch.entities[0] else { throw NSError(domain: "fixture", code: 1) }
        sketch.entities[0] = .rect(id: id, min: min, max: SIMD2(width, max.y))
        return sketch
    }
    private func assertDerived(_ f: Fixture, x: Double,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let session = f.document.session
        XCTAssertTrue(session.lastEvalErrors.isEmpty, "\(session.lastEvalErrors)", file: file, line: line)
        XCTAssertTrue(session.lastReferenceErrors.isEmpty, "\(session.lastReferenceErrors)", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(session.document.planes.first { $0.id == f.plane }).plane.origin.x,
                       x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(session.document.sketches.first { $0.id == f.childSketch }).plane.origin.x,
                       x, accuracy: 1e-5, file: file, line: line)
        let child = try XCTUnwrap(session.document.body(with: f.child), file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(child.brep)), 24, accuracy: 1e-4, file: file, line: line)
        let minimum = try XCTUnwrap(child.render.positions.map { child.transform.applying(to: SIMD3<Double>($0)).x }.min())
        XCTAssertEqual(minimum, x - 2, accuracy: 1e-4, file: file, line: line)
    }
    private func savedRedo(_ f: Fixture) async throws -> ConstructionPlaneID {
        let sentinel = ConstructionPlane(plane: .ground, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        return sentinel.id
    }

    func testPreviewChangesOnlySourceAndCommitRebuildsAllInOneUndo() async throws {
        let f = try await fixture()
        let session = f.document.session
        let before = try currentSketch(f)
        let undoCount = session.undoStack.undoCommands.count
        let bodyRevisions = session.document.bodies.map(\.meshRevision)
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let marker = session.persistenceChangeCount
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: before.id, title: "Move rectangle"))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 50), token: token))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        XCTAssertNotEqual(try currentSketch(f), before)
        XCTAssertEqual(session.persistenceChangeCount, marker)
        XCTAssertEqual(session.document.bodies.map(\.meshRevision), bodyRevisions)
        XCTAssertEqual(session.undoStack.undoCommands.count, undoCount)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(f.document.hasUnsavedChanges)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
        try assertDerived(f, x: 20)
        XCTAssertTrue(session.commitSketchPreview(token))
        XCTAssertEqual(session.undoStack.undoCommands.count, undoCount + 1)
        XCTAssertTrue(f.document.hasUnsavedChanges)
        try assertDerived(f, x: 30)
        session.undo()
        XCTAssertEqual(try currentSketch(f), before)
        try assertDerived(f, x: 20)
        session.redo()
        try assertDerived(f, x: 30)
    }

    func testInvalidCollapsedProfileRestoresBaselineRedoAndDoesNotScheduleSave() async throws {
        let f = try await fixture()
        let sentinel = try await savedRedo(f)
        let session = f.document.session
        let before = try currentSketch(f)
        let generation = session.changeCount
        let marker = session.persistenceChangeCount
        let count = session.undoStack.undoCommands.count
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: before.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 0), token: token))
        XCTAssertFalse(session.commitSketchPreview(token))
        XCTAssertFalse(session.isSketchPreviewActive)
        XCTAssertEqual(try currentSketch(f), before)
        XCTAssertGreaterThan(session.changeCount, generation)
        XCTAssertEqual(session.persistenceChangeCount, marker)
        XCTAssertEqual(session.undoStack.undoCommands.count, count)
        XCTAssertTrue(session.undoStack.canRedo)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(f.document.hasUnsavedChanges)
        XCTAssertFalse(session.lastRebuildRejection.isEmpty && session.lastRejectedFeatureErrors.isEmpty)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
        try assertDerived(f, x: 20)
        session.redo()
        XCTAssertTrue(session.document.planes.contains { $0.id == sentinel })
    }

    func testNoAcceptedFrameAndChangedThenEqualNoOpLeaveHistoryAndFileUntouched() async throws {
        let f = try await fixture()
        let session = f.document.session
        let before = try currentSketch(f)
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let marker = session.persistenceChangeCount
        let count = session.undoStack.undoCommands.count
        let empty = try XCTUnwrap(session.beginSketchPreview(sketchID: before.id))
        XCTAssertTrue(session.commitSketchPreview(empty))
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: before.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        XCTAssertTrue(session.updateSketchPreview(before, token: token))
        XCTAssertTrue(session.commitSketchPreview(token))
        XCTAssertEqual(session.undoStack.undoCommands.count, count)
        XCTAssertEqual(session.persistenceChangeCount, marker)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(f.document.hasUnsavedChanges)
        let flush = await f.document.flushIfDirty()
        XCTAssertNil(flush)
        f.document.close()
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
    }

    func testCompleteSketchSolverDimensionsAndWeldShareSingleUndo() async throws {
        let f = try await fixture()
        let session = f.document.session
        let before = try currentSketch(f)
        var proposed = try changedSketch(f, width: 60)
        let dimension = SketchDimension(kind: .horizontal, refs: [
            ConstraintRef(entityID: proposed.entities[0].id, role: .endpointA),
            ConstraintRef(entityID: proposed.entities[0].id, role: .endpointB)], value: 60)
        proposed.dimensions.append(dimension)
        let a = UUID(), b = UUID()
        proposed.entities += [.line(id: a, a: SIMD2(5, 5), b: SIMD2(7, 5)),
                              .line(id: b, a: SIMD2(7, 5), b: SIMD2(9, 6))]
        proposed.constructionEntityIDs.formUnion([a, b])
        let weld = SketchConstraint(kind: .coincident, refs: [ConstraintRef(entityID: a, role: .endpointB),
                                                             ConstraintRef(entityID: b, role: .endpointA)])
        proposed.constraints.append(weld)
        let solved = SketchSolverBridge.solveOutcome(proposed, movingEntity: nil, dragTarget: nil)
        XCTAssertLessThanOrEqual(solved.structuralResidual, 1e-3)
        proposed.entities = solved.entities
        let count = session.undoStack.undoCommands.count
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: before.id))
        XCTAssertTrue(session.updateSketchPreview(proposed, token: token))
        XCTAssertTrue(session.commitSketchPreview(token))
        XCTAssertEqual(try currentSketch(f), proposed)
        XCTAssertEqual(session.undoStack.undoCommands.count, count + 1)
        try assertDerived(f, x: 30)
        session.undo()
        XCTAssertEqual(try currentSketch(f), before)
        try assertDerived(f, x: 20)
        session.redo()
        XCTAssertEqual(try currentSketch(f).dimensions.map(\.id), [dimension.id])
        XCTAssertEqual(try currentSketch(f).constraints.map(\.id), [weld.id])
    }

    func testOtherWritersExplicitlyRefuseButReadDiscoveryRemainsAvailable() async throws {
        let f = try await fixture(drawing: true)
        let session = f.document.session
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let thumbnail = f.document.project.thumbnail
        let modified = f.document.project.modifiedAt
        let projectSource = try XCTUnwrap(f.document.project.sketches.first { $0.sketchID == f.sourceSketch.id.raw }).sketchData
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: f.sourceSketch.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        let count = session.undoStack.undoCommands.count
        XCTAssertFalse(f.document.isReadOnly)
        func refused(_ value: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(value["error"] as? String, "edit_in_progress", "\(value)", file: file, line: line)
            XCTAssertNotEqual(value["mutated"] as? Bool, true, file: file, line: line)
        }
        let material = CADMaterialService(document: f.document)
        for action in ["create", "update", "remove", "apply", "applyFaces", "mapping", "textures", "libraryImport", "undo", "redo"] {
            refused(material.handle(action: action, args: [:]))
        }
        for action in CADParameterService.actions where action != "list" {
            refused(CADParameterService(document: f.document).handle(action: action, args: [:]))
        }
        for action in CADServiceOperations.mutatingAssemblyActions {
            refused(CADAssemblyService(document: f.document).handle(action: action, args: [:]))
            refused(await CADAssemblyService(document: f.document).handleAsync(action: action, args: [:]))
        }
        for action in CADServiceOperations.mutatingDrawingActions {
            refused(CADDrawingService(document: f.document).handle(action: action, args: [:]))
        }
        for action in CADServiceOperations.mutatingMeshActions {
            refused(CADMeshService(document: f.document).handle(action: action, args: [:]))
        }
        for action in CADServiceOperations.mutatingScriptActions {
            refused(await CADScriptService(document: f.document).handle(action: action, args: [:]))
        }
        for action in CADDatumService.actions { refused(CADDatumService(document: f.document).handle(action: action, args: [:])) }
        XCTAssertEqual(f.document.animationJSON(["action": "createClip"] ).errorCode, "edit_in_progress")
        do { _ = try f.document.createAnimationClip(); XCTFail("Direct animation must be blocked") }
        catch let error as CADDocumentError { XCTAssertEqual(error.code, "edit_in_progress") }
        XCTAssertEqual(f.document.execute(["op": "sketch.create", "args": [:]]).errorCode, "edit_in_progress")
        let imported = f.document.nativeImportData(Data(), format: "obj", fileName: nil, unitScale: nil)
        XCTAssertFalse(imported.isOK)
        XCTAssertTrue(String(decoding: imported.payload, as: UTF8.self).contains("edit_in_progress"))
        let blockedSave = await f.document.save()
        XCTAssertFalse(blockedSave.succeeded)
        let previewSave = await f.document.saveViewportPreview(Data([1, 2, 3]))
        XCTAssertFalse(previewSave.succeeded)
        XCTAssertNil(session.commitNow())
        XCTAssertEqual(f.document.project.thumbnail, thumbnail)
        XCTAssertEqual(f.document.project.modifiedAt, modified)
        XCTAssertEqual(try XCTUnwrap(f.document.project.sketches.first { $0.sketchID == f.sourceSketch.id.raw }).sketchData, projectSource)
        XCTAssertEqual(material.handle(action: "list", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(CADParameterService(document: f.document).handle(action: "list", args: [:])["ok"] as? Bool, true)
        XCTAssertEqual(CADAssemblyService(document: f.document).handle(action: "instances", args: [:])["ok"] as? Bool, true)
        let scriptRead = await CADScriptService(document: f.document).handle(action: "list", args: [:])
        XCTAssertEqual(scriptRead["ok"] as? Bool, true)
        XCTAssertEqual(CADMeshService(document: f.document).handle(action: "boundary", args: ["bodyID": f.sourceBody.raw.uuidString])["ok"] as? Bool, true)
        let drawingBefore = session.document.drawingsData
        let page = try XCTUnwrap(CADDrawingSet.decode(from: drawingBefore).pages.first)
        let projection = CADDrawingService(document: f.document).handle(action: "project", args: ["pageID": page.id.uuidString])
        XCTAssertEqual(projection["ok"] as? Bool, true, "\(projection)")
        XCTAssertEqual(projection["mutated"] as? Bool, false)
        XCTAssertEqual(session.document.drawingsData, drawingBefore)
        XCTAssertTrue(f.document.animationJSON(["action": "list"]).isOK)
        for scope in ["planes", "sketches", "features", "variables", "faces"] {
            let result = f.document.nativeQueryJSON(["scope": scope])
            XCTAssertTrue(result.isOK)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
            XCTAssertEqual((object["write_block"] as? [String: Any])?["code"] as? String, "edit_in_progress")
            if scope == "planes", let row = (object["rows"] as? [[String: Any]])?.first {
                XCTAssertEqual(row["editable"] as? Bool, false)
                XCTAssertNil(row["update_action"])
            }
        }
        XCTAssertEqual(session.undoStack.undoCommands.count, count)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
        XCTAssertTrue(session.cancelSketchPreview(token))
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(f.document.hasUnsavedChanges)
    }

    func testTokensFenceCancelNewOwnerOutsideEditAndBeginAloneAdvancesEpoch() async throws {
        let f = try await fixture()
        let session = f.document.session
        let baseline = try currentSketch(f)
        let generationAfterMutation = session.changeCount
        let old = try XCTUnwrap(session.beginSketchPreview(sketchID: baseline.id))
        XCTAssertGreaterThan(session.changeCount, generationAfterMutation,
            "begin alone must fence an older NativeEditCommit continuation before first tick")
        XCTAssertNil(session.beginSketchPreview(sketchID: baseline.id))
        XCTAssertTrue(session.cancelSketchPreview(old))
        let current = try XCTUnwrap(session.beginSketchPreview(sketchID: baseline.id))
        XCTAssertFalse(session.cancelSketchPreview(old))
        XCTAssertFalse(session.updateSketchPreview(try changedSketch(f, width: 80), token: old))
        XCTAssertFalse(session.commitSketchPreview(old))
        XCTAssertTrue(session.isSketchPreviewActive)
        let foreignSketch = try XCTUnwrap(session.document.sketches.first { $0.id == f.childSketch })
        XCTAssertFalse(session.updateSketchPreview(foreignSketch, token: current))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: current))
        XCTAssertTrue(session.cancelSketchPreview(current))
        let outside = ConstructionPlane(plane: .ground, size: 12)
        session.perform(AddConstructionPlaneCommand(plane: outside))
        XCTAssertFalse(session.updateSketchPreview(baseline, token: current))
        XCTAssertFalse(session.cancelSketchPreview(current))
        XCTAssertTrue(session.document.planes.contains { $0.id == outside.id })
        XCTAssertEqual(try currentSketch(f), baseline)
        f.document.close()
        XCTAssertFalse(session.commitSketchPreview(current))
    }

    func testReadOnlyOpaqueAndPlainDocumentsCannotAcquireOwner() async throws {
        let plain = try await FloeCADDocument.create(at: directory.appendingPathComponent("plain.floecad"), name: "Plain")
        documents.append(plain)
        let sketch = Sketch(plane: .ground)
        plain.session.perform(AddSketchCommand(sketch: sketch))
        XCTAssertNil(plain.session.beginSketchPreview(sketchID: sketch.id))
        XCTAssertFalse(plain.session.isSketchPreviewActive)
        let url = directory.appendingPathComponent("opaque.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .supportCase)
        let opaque = try await FloeCADDocument.open(at: url)
        documents.append(opaque)
        let cached = try XCTUnwrap(opaque.session.document.sketches.first)
        XCTAssertNil(opaque.session.beginSketchPreview(sketchID: cached.id))
        XCTAssertFalse(opaque.session.isSketchPreviewActive)
        XCTAssertEqual(opaque.session.writeBlock?.code, "read_only")
        let known = try await fixture()
        known.document.project.formatVersion = Project.currentFormatVersion + 1
        XCTAssertNil(known.document.session.beginSketchPreview(sketchID: known.sourceSketch.id))
        XCTAssertFalse(known.document.session.isSketchPreviewActive)
    }

    func testCloseCancelsCleanPreviewWithoutWritingBaselineOrMetadata() async throws {
        let f = try await fixture()
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let baseline = try currentSketch(f)
        let token = try XCTUnwrap(f.document.session.beginSketchPreview(sketchID: baseline.id))
        XCTAssertTrue(f.document.session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        f.document.close()
        XCTAssertEqual(try currentSketch(f), baseline)
        XCTAssertFalse(f.document.session.isSketchPreviewActive)
        XCTAssertFalse(f.document.session.cancelSketchPreview(token))
        XCTAssertFalse(f.document.session.hasPendingAutosaveForTesting)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
    }

    func testCloseResumesOnlyPreviouslyPendingBaselineSave() async throws {
        let f = try await fixture()
        let session = f.document.session
        let baseline = try currentSketch(f)
        let sourceBody = try XCTUnwrap(session.document.body(with: f.sourceBody))
        session.perform(RenameItemCommand(item: .body(f.sourceBody), before: sourceBody.name, after: "Pending baseline"))
        XCTAssertTrue(session.hasPendingAutosaveForTesting)
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: baseline.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with: f.sourceBody)?.name, "Pending baseline")
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == baseline.id }, baseline)
        XCTAssertFalse(session.isSketchPreviewActive)
    }

    func testSaveSuspendedInsidePrewarmCannotPreparePreviewAndReturnsStableLocalError() async throws {
        let f = try await fixture()
        let session = f.document.session
        let body = try XCTUnwrap(session.document.body(with: f.sourceBody))
        session.perform(RenameItemCommand(item: .body(f.sourceBody), before: body.name, after: "Dirty baseline"))
        let projectBytes = try XCTUnwrap(f.document.project.sketches.first { $0.sketchID == f.sourceSketch.id.raw }).sketchData
        let modified = f.document.project.modifiedAt
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let gate = PrewarmGate()
        session.savePrewarmSuspensionForTesting = { await gate.suspend() }
        let saving = Task { await f.document.save() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { gate.release(); _ = await saving.value; return }
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: f.sourceSketch.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        let blocked = await saving.value
        XCTAssertFalse(blocked.succeeded)
        XCTAssertEqual(blocked.error, session.writeBlock?.message)
        XCTAssertEqual(try XCTUnwrap(f.document.project.sketches.first { $0.sketchID == f.sourceSketch.id.raw }).sketchData, projectBytes)
        XCTAssertEqual(f.document.project.modifiedAt, modified)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
        XCTAssertTrue(session.cancelSketchPreview(token))
        XCTAssertFalse(blocked.succeeded, "owner release must not turn the completed local refusal into success")
        XCTAssertTrue(session.hasPendingAutosaveForTesting, "the pre-existing dirty baseline save must resume")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with: f.sourceBody)?.name, "Dirty baseline")
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == f.sourceSketch.id }, f.sourceSketch)
        XCTAssertFalse(gate.timedOut)
    }

    func testAlreadyPreparedBaselinePayloadFinishesAndDoesNotScheduleDuplicateOnCancel() async throws {
        let f = try await fixture()
        let session = f.document.session
        let body = try XCTUnwrap(session.document.body(with: f.sourceBody))
        session.perform(RenameItemCommand(item: .body(f.sourceBody), before: body.name, after: "Prepared baseline"))
        let gate = CommitGate()
        CADDocumentFaultInjection.beforeCommit = { try gate.suspend() }
        defer { gate.release(); CADDocumentFaultInjection.beforeCommit = nil }
        let saving = Task { await f.document.save() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { gate.release(); _ = await saving.value; return }
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: f.sourceSketch.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        gate.release()
        let result = await saving.value
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertTrue(result.succeeded, result.error ?? "")
        XCTAssertTrue(session.isSketchPreviewActive)
        let committedBytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        XCTAssertTrue(session.cancelSketchPreview(token))
        XCTAssertFalse(session.hasPendingAutosaveForTesting, "the earlier payload already saved that exact baseline")
        XCTAssertFalse(f.document.hasUnsavedChanges)
        f.document.close()
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), committedBytes)
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with: f.sourceBody)?.name, "Prepared baseline")
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == f.sourceSketch.id }, f.sourceSketch)
    }

    func testRestoredPersistenceMarkerNeverAliasesAnotherSavedEdit() async throws {
        let f = try await fixture()
        let checkpoint = f.document.captureEditCheckpoint()
        let first = ConstructionPlane(plane: .ground, size: 11)
        f.document.session.perform(AddConstructionPlaneCommand(plane: first))
        let savedFirst = await f.document.save()
        XCTAssertTrue(savedFirst.succeeded, savedFirst.error ?? "")
        let firstMarker = f.document.session.persistenceChangeCount
        f.document.restoreEditCheckpoint(checkpoint)
        let second = ConstructionPlane(plane: .ground, size: 22)
        f.document.session.perform(AddConstructionPlaneCommand(plane: second))
        XCTAssertGreaterThan(f.document.session.persistenceChangeCount, firstMarker)
        XCTAssertTrue(f.document.hasUnsavedChanges)
        let savedSecond = await f.document.save()
        XCTAssertTrue(savedSecond.succeeded, savedSecond.error ?? "")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertTrue(reopened.session.document.planes.contains { $0.id == second.id })
        XCTAssertFalse(reopened.session.document.planes.contains { $0.id == first.id })
    }
    func testPreviewBlockDoesNotHideRealCommitFailureAndRetrySavesBaseline() async throws {
        let f = try await fixture()
        let session = f.document.session
        let body = try XCTUnwrap(session.document.body(with: f.sourceBody))
        session.perform(RenameItemCommand(item: .body(f.sourceBody), before: body.name, after: "Retry baseline"))
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "CADPreviewTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic commit failure"])
        }
        let failed = await f.document.save()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded)
        let realError = try XCTUnwrap(session.lastSaveError)
        XCTAssertTrue(session.saveFailureRequiresRetry)
        let token = try XCTUnwrap(session.beginSketchPreview(sketchID: f.sourceSketch.id))
        XCTAssertTrue(session.updateSketchPreview(try changedSketch(f, width: 60), token: token))
        let blocked = await f.document.save()
        XCTAssertFalse(blocked.succeeded)
        XCTAssertEqual(session.lastSaveError, realError)
        XCTAssertTrue(session.cancelSketchPreview(token))
        XCTAssertEqual(session.lastSaveError, realError)
        let retried = await f.document.save()
        XCTAssertTrue(retried.succeeded, retried.error ?? "")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with: f.sourceBody)?.name, "Retry baseline")
        XCTAssertEqual(reopened.session.document.sketches.first { $0.id == f.sourceSketch.id }, f.sourceSketch)
    }

}

/// Actual async prewarm gate. The timeout is only a failure watchdog; ordering
/// assertions wait for the explicit entry event, never elapsed time.
@MainActor
private final class PrewarmGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Bool, Never>] = []
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var timedOut = false
    func suspend() async {
        entered = true
        let waiters = entryWaiters; entryWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        if released { return }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.released else { return }
            self.timedOut = true; self.release()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
        watchdog.cancel()
    }
    func waitUntilEntered() async -> Bool {
        if entered { return true }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.entered else { return }
            self.timedOut = true
            let waiters = self.entryWaiters; self.entryWaiters.removeAll()
            waiters.forEach { $0.resume(returning: false) }
            self.release()
        }
        let result = await withCheckedContinuation { entryWaiters.append($0) }
        watchdog.cancel()
        return result
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

private nonisolated final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private nonisolated enum Failure: Error { case timeout }
    func suspend() throws {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            entered = true; defer { waiter = nil }; return waiter
        }
        pending?.resume(returning: true)
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw Failure.timeout }
    }
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard !entered else { return nil }; defer { waiter = nil }; return waiter
                }
                pending?.resume(returning: false)
            }
            let ready = lock.withLock { () -> Bool in
                if entered { return true }; waiter = continuation; return false
            }
            if ready { continuation.resume(returning: true) }
        }
    }
    func release() { semaphore.signal() }
}
