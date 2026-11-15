// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import MetalKit
import simd
@testable import FloeCAD

/// Real document commands, package persistence and the production camera.
/// Authored for the independent iOS host; no synthetic pass is implied.
@MainActor
final class CADBuildingDraftingTests: XCTestCase {
    private func fixture(_ work: (FloeCADDocument, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildingDrafting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Project.floecad"), name: "Drafting")
        do {
            try await work(document, root)
            document.close()
            if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
        } catch { document.close(); throw error }
    }
    private func building(_ document: FloeCADDocument) throws -> CADBuildingDocument {
        var model = CADBuildingDocument(name: "Interior")
        model.storeys[0].name = "Same name"
        model.storeys.append(CADBuildingStorey(name: "Same name", elevationMM: 3200, heightMM: 2700))
        try document.setBuilding(model)
        return model
    }
    private func line(_ document: FloeCADDocument, _ id: SketchID) -> UUID {
        let entity = UUID()
        document.session.perform(AddSketchEntityCommand(sketchID: id,
            entity: .line(id: entity, a: .zero, b: SIMD2(1200, 600))))
        return entity
    }

    func testInitialFloorAndDrawingShareOneUndoAndRedo() async throws {
        try await fixture { document, _ in
            let initial = CADBuildingDocument(name: "Initial")
            let depth = document.session.undoStack.undoCommands.count
            let lease = try CADBuildingDraftingSession(document: document, storeyID: initial.storeys[0].id,
                                                      initialBuilding: initial)
            XCTAssertEqual(document.session.undoStack.undoCommands.count, depth + 1)
            XCTAssertEqual(try document.building()?.storeys.map(\.id), initial.storeys.map(\.id))
            let id = lease.sketchID
            XCTAssertEqual(document.viewModel().activeSketch?.id, id)
            XCTAssertEqual(document.viewModel().activeSketch?.plane, SketchPlane.ground)
            lease.end()
            document.session.undo()
            XCTAssertNil(try document.building())
            XCTAssertFalse(document.session.document.sketches.contains { $0.id == id })
            document.session.redo()
            XCTAssertEqual(try document.building()?.storeys.map(\.id), initial.storeys.map(\.id))
            XCTAssertEqual(document.session.document.sketches.filter { $0.id == id }.count, 1)
        }
    }

    func testSameNamedFloorsUseDistinctSketchesAndKeepOtherSketches() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let ordinary = Sketch(name: "Existing drawing", plane: .worldXY,
                                  entities: [.line(id: UUID(), a: .zero, b: SIMD2(5, 8))])
            document.session.perform(AddSketchCommand(sketch: ordinary))
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            defer { lease.end() }
            let first = lease.sketchID
            let firstEntity = line(document, first)
            try lease.selectStorey(model.storeys[1].id)
            let second = lease.sketchID
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(document.viewModel().activeSketch?.plane, SketchPlane.offsetGround(y: 3200))
            _ = line(document, second)
            try lease.selectStorey(model.storeys[0].id)
            XCTAssertEqual(lease.sketchID, first)
            XCTAssertEqual(document.viewModel().activeSketch?.entities.map(\.id), [firstEntity])
            XCTAssertEqual(document.session.document.sketches.first { $0.id == ordinary.id }, ordinary)
            XCTAssertEqual(Set(document.session.document.sketches.map(\.id)), [ordinary.id, first, second])
        }
    }

    func testRenameAndNativeReopenRetainFloorDrawingIdentityAndGeometry() async throws {
        try await fixture { document, _ in
            var model = try building(document)
            let floor = model.storeys[0].id
            let lease = try CADBuildingDraftingSession(document: document, storeyID: floor)
            let id = lease.sketchID, entity = line(document, lease.sketchID)
            model.storeys[0].name = "Renamed floor"
            try document.setBuilding(model)
            lease.refresh(); XCTAssertNil(lease.issue)
            try lease.ensureActiveSketch()
            XCTAssertEqual(lease.sketchID, id)
            lease.end()
            let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
            let url = document.url
            document.close()
            let reopened = try await FloeCADDocument.open(at: url)
            defer { reopened.close() }
            let resumed = try CADBuildingDraftingSession(document: reopened, storeyID: floor)
            defer { resumed.end() }
            XCTAssertEqual(resumed.sketchID, id)
            XCTAssertEqual(reopened.viewModel().activeSketch?.entities.map(\.id), [entity])
            XCTAssertEqual(try reopened.building()?.storeys[0].name, "Renamed floor")
            XCTAssertEqual(reopened.session.document.sketches.filter { $0.id == id }.count, 1)
        }
    }

    func testUnknownFloorAndWrongPlaneRefuseWithoutWritesOrTakingOwnership() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let before = document.buildingChangeCount
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: UUID()))
            XCTAssertEqual(document.buildingChangeCount, before)
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
            let collision = Sketch(id: CADBuildingDraftingSession.sketchID(for: model.storeys[0].id),
                                   plane: .worldXY, entities: [.circle(id: UUID(), center: .zero, radius: 12)])
            document.session.perform(AddSketchCommand(sketch: collision))
            let count = document.buildingChangeCount
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id))
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertEqual(document.session.document.sketches, [collision])
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
        }
    }

    func testFloorElevationNeedsExplicitMoveAndStaleReviewIsRefused() async throws {
        try await fixture { document, _ in
            var model = try building(document)
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            defer { lease.end() }
            let entity = line(document, lease.sketchID)
            model.storeys[0].elevationMM = 450
            try document.setBuilding(model)
            lease.refresh()
            XCTAssertNotNil(lease.issue); XCTAssertTrue(lease.canMoveToFloor)
            XCTAssertNil(document.viewModel().activeSketch, "An invalid floor plane cannot remain editable via Pencil/keyboard")
            let beforeDraw = document.buildingChangeCount
            document.viewModel().startSketch(tool: .rect)
            XCTAssertEqual(document.buildingChangeCount, beforeDraw)
            document.session.perform(AddSketchCommand(sketch: Sketch(name: "Other", plane: .worldXY)))
            lease.refresh(); XCTAssertFalse(lease.canMoveToFloor)
            let beforeRefusal = document.buildingChangeCount
            XCTAssertThrowsError(try lease.moveDrawingToCurrentFloor())
            XCTAssertEqual(document.buildingChangeCount, beforeRefusal)
            lease.reviewPlane(); XCTAssertTrue(lease.canMoveToFloor)
            try lease.moveDrawingToCurrentFloor()
            XCTAssertEqual(document.viewModel().activeSketch?.plane, SketchPlane.offsetGround(y: 450))
            XCTAssertEqual(document.viewModel().activeSketch?.entities.map(\.id), [entity])
            document.session.undo(); lease.refresh()
            XCTAssertEqual(document.session.document.sketches.first { $0.id == lease.sketchID }?.plane, SketchPlane.ground)
            XCTAssertNotNil(lease.issue)
        }
    }

    func testUndoAndReadonlyRefreshKeepRedoUntilTheUserDrawsAgain() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            defer { lease.end() }
            let id = lease.sketchID
            document.session.undo()
            let count = document.buildingChangeCount
            for _ in 0..<3 { lease.refresh() }
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertTrue(document.session.undoStack.canRedo)
            XCTAssertFalse(document.session.document.sketches.contains { $0.id == id })
            document.session.redo()
            XCTAssertEqual(document.session.document.sketches.filter { $0.id == id }.count, 1)
            document.session.undo()
            document.viewModel().startSketch(tool: .line)
            XCTAssertEqual(document.viewModel().activeSketch?.id, id)
            XCTAssertEqual(document.viewModel().mode.sketchTool, .line)
            XCTAssertFalse(document.session.undoStack.canRedo)
        }
    }

    func testRemovedFloorAndBusyModelCannotRedirectEditsToAnotherFloor() async throws {
        try await fixture { document, _ in
            var model = try building(document)
            document.viewModel().mode = .extruding
            let before = document.buildingChangeCount
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id))
            XCTAssertEqual(document.buildingChangeCount, before)
            document.viewModel().mode = .idle
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            defer { lease.end() }
            let id = lease.sketchID
            _ = line(document, id)
            model.storeys.removeFirst(); try document.setBuilding(model)
            lease.refresh(); XCTAssertNotNil(lease.issue)
            let count = document.buildingChangeCount
            document.viewModel().startSketch(tool: .circle)
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertNil(document.viewModel().activeSketch)
            XCTAssertEqual(lease.sketchID, id)
            XCTAssertFalse(document.session.document.sketches.contains { $0.id == CADBuildingDraftingSession.sketchID(for: model.storeys[0].id) })
        }
    }

    func testOneOwnerAndDepartedOrClosedSessionCannotRearmTheDocument() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            let before = document.buildingChangeCount
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: model.storeys[1].id))
            XCTAssertEqual(document.buildingChangeCount, before)
            XCTAssertTrue(document.viewModel().buildingDraftingOwner === lease)
            lease.end()
            let count = document.buildingChangeCount
            XCTAssertThrowsError(try lease.ensureActiveSketch())
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
            let another = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[1].id)
            document.close()
            XCTAssertThrowsError(try another.ensureActiveSketch())
            another.end()
            XCTAssertFalse(another.isActive)
            XCTAssertTrue(document.isClosed)
        }
    }

    func testToolSwitchPreservesPanZoomAndDepartureRestoresActual3DCamera() async throws {
        try await fixture { document, _ in
            let model = try building(document), editor = document.viewModel()
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            let coordinator = ViewportCoordinator(viewModel: editor)
            coordinator.attach(to: view)
            let renderer = try XCTUnwrap(coordinator.renderer, "Requires the actual native Metal viewport")
            let original = TurntableCamera(target: SIMD3(20, 30, 40), distance: 6000,
                azimuth: 0.75, elevation: 0.45, projection: .perspective(fovY: 0.8))
            renderer.camera = original; editor.orthographicEnabled = false
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            _ = line(document, lease.sketchID)
            var panned = renderer.camera
            panned.target = SIMD3(90, 0, -70); panned.distance = 2200
            renderer.camera = panned
            let pending = coordinator.pendingCameraTarget
            try lease.ensureActiveSketch(); editor.startSketch(tool: .line); editor.startSketch(tool: .rect)
            XCTAssertEqual(renderer.camera, panned)
            XCTAssertEqual(coordinator.pendingCameraTarget, pending)
            lease.end()
            XCTAssertFalse(editor.permanentDraftingNavigationOnly)
            XCTAssertFalse(editor.mode.isSketching)
            XCTAssertEqual(renderer.camera, original)
            XCTAssertTrue(renderer.showsOrientationCube)
            XCTAssertFalse(editor.orthographicEnabled)
        }
    }

    func testProjectCheckpointDefersDepartureAndFencesFurtherDrafting() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            let id = lease.sketchID, entity = line(document, lease.sketchID)
            let checkpoint = try document.beginBuildingDraftingCheckpoint()
            let capture = try XCTUnwrap(checkpoint)
            let count = document.buildingChangeCount
            lease.end()
            XCTAssertFalse(lease.isActive)
            XCTAssertTrue(document.viewModel().buildingDraftingOwner === lease, "A departing view cannot flush CAD during the project snapshot")
            XCTAssertThrowsError(try lease.ensureActiveSketch())
            document.viewModel().startSketch(tool: .circle)
            XCTAssertEqual(document.buildingChangeCount, count)
            let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
            XCTAssertEqual(document.session.document.sketches.first { $0.id == id }?.entities.map(\.id), [entity])
            capture.finish(); capture.finish()
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
            XCTAssertFalse(document.viewModel().mode.isSketching)
            XCTAssertEqual(document.buildingChangeCount, count)
        }
    }

    func testUnfinishedInputRefusesProjectCheckpointAndKeepsItsDraft() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let lease = try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id)
            defer { lease.end() }
            let pending = SketchEntity.line(id: UUID(), a: .zero, b: SIMD2(100, 200))
            document.viewModel().pendingEntity = pending
            let count = document.buildingChangeCount
            XCTAssertThrowsError(try document.beginBuildingDraftingCheckpoint())
            XCTAssertEqual(document.viewModel().pendingEntity, pending)
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertTrue(lease.isActive)
            document.viewModel().pendingEntity = nil
            let checkpoint = try document.beginBuildingDraftingCheckpoint()
            let capture = try XCTUnwrap(checkpoint)
            capture.finish()
            XCTAssertEqual(document.viewModel().activeSketch?.id, lease.sketchID)
        }
    }

    func testPendingInputSurvivesSectionDepartureAndResumesOnlyOnItsOwnFloor() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let floor = model.storeys[0].id
            let lease = try CADBuildingDraftingSession(document: document, storeyID: floor)
            let pending = SketchEntity.line(id: UUID(), a: .zero, b: SIMD2(400, 200))
            document.viewModel().pendingEntity = pending
            XCTAssertThrowsError(try lease.selectStorey(model.storeys[1].id))
            XCTAssertEqual(lease.storeyID, floor)
            lease.end()
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
            XCTAssertEqual(document.viewModel().pendingEntity, pending)
            XCTAssertTrue(document.hasUnfinishedBuildingDraftingInput)
            XCTAssertThrowsError(try document.beginBuildingDraftingCheckpoint(), "A hidden draft remains a project save blocker")
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: model.storeys[1].id))
            let resumed = try CADBuildingDraftingSession(document: document, storeyID: floor)
            XCTAssertEqual(document.viewModel().pendingEntity, pending)
            XCTAssertEqual(resumed.sketchID, lease.sketchID)
            document.viewModel().pendingEntity = nil
            resumed.end()
        }
    }

    func testStandaloneDraftingWithoutBuildingOwnerKeepsTheExistingSketch() async throws {
        try await fixture { document, _ in
            let ordinary = Sketch(name: "Standalone", plane: .worldXY,
                                  entities: [.line(id: UUID(), a: .zero, b: SIMD2(8, 5))])
            document.session.perform(AddSketchCommand(sketch: ordinary))
            let count = document.buildingChangeCount
            document.activate2DWorkspace()
            let editor = document.viewModel()
            XCTAssertNil(editor.buildingDraftingOwner)
            XCTAssertTrue(editor.permanentDraftingNavigationOnly)
            XCTAssertEqual(editor.activeSketch?.id, ordinary.id)
            editor.startSketch(tool: .rect)
            XCTAssertEqual(editor.activeSketch?.id, ordinary.id)
            XCTAssertEqual(document.buildingChangeCount, count)
            let capture = try document.beginBuildingDraftingCheckpoint()
            XCTAssertNil(capture)
            XCTAssertEqual(document.session.document.sketches, [ordinary])
        }
    }

    func testPendingOtherSketchCannotBeReplacedByTheFloorEntrance() async throws {
        try await fixture { document, _ in
            let model = try building(document)
            let ordinary = Sketch(name: "Other drawing", plane: .worldXY)
            document.session.perform(AddSketchCommand(sketch: ordinary))
            document.viewModel().openItemSketch(ordinary.id)
            let pending = SketchEntity.line(id: UUID(), a: .zero, b: SIMD2(11, 20))
            document.viewModel().pendingEntity = pending
            let count = document.buildingChangeCount
            XCTAssertThrowsError(try CADBuildingDraftingSession(document: document, storeyID: model.storeys[0].id))
            XCTAssertEqual(document.viewModel().pendingEntity, pending)
            XCTAssertEqual(document.viewModel().activeSketch?.id, ordinary.id)
            XCTAssertEqual(document.buildingChangeCount, count)
            XCTAssertNil(document.viewModel().buildingDraftingOwner)
            document.viewModel().pendingEntity = nil
        }
    }
}
#endif
