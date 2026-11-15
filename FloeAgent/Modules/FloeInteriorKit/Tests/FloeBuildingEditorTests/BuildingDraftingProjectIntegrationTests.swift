// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import XCTest
@testable import FloeCAD
@testable import FloeBuildingEditor

@MainActor
final class BuildingDraftingProjectIntegrationTests: XCTestCase {
    func testFloorDraftingAndRoomRecordsPublishAndReopenInOneProjectGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftingProject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("Project"), library = root.appendingPathComponent("Library")
        let session = try await BuildingEditorProjectSession.create(at: project, name: "Drafting joint", assetLibraryDirectory: library)
        do {
            let initial = try await session.recordsSnapshot()
            let room = try await session.createRoomRecord(name: "Living", expectedRevision: initial.project.revision)
            try await session.createInitialRoom(recordsRoomID: room, widthMM: 4000, depthMM: 3200, heightMM: 2700, wallThicknessMM: 200)
            let document = session.nativeDocument
            let currentBuilding = try document.building()
            let building = try XCTUnwrap(currentBuilding), floor = try XCTUnwrap(building.storeys.first?.id)
            let drafting = try CADBuildingDraftingSession(document: document, storeyID: floor)
            let sketch = drafting.sketchID, entity = UUID()
            document.session.perform(AddSketchEntityCommand(sketchID: sketch,
                entity: .line(id: entity, a: SIMD2(500, 600), b: SIMD2(2100, 600))))
            XCTAssertTrue(session.hasUnpublishedChanges)
            try await session.checkpoint()
            let generation = try XCTUnwrap(session.published?.generationID)
            XCTAssertFalse(session.hasUnpublishedChanges)
            XCTAssertTrue(document.viewModel().buildingDraftingOwner === drafting)
            drafting.end()
            try await session.close()
            let reopened = try await BuildingEditorProjectSession.open(at: project, assetLibraryDirectory: library)
            do {
                XCTAssertEqual(reopened.published?.generationID, generation)
                let records = try await reopened.recordsSnapshot()
                XCTAssertEqual(records.rooms.map(\.id), [room])
                let resumed = try CADBuildingDraftingSession(document: reopened.nativeDocument, storeyID: floor)
                XCTAssertEqual(resumed.sketchID, sketch)
                XCTAssertEqual(reopened.nativeDocument.viewModel().activeSketch?.entities.map(\.id), [entity])
                XCTAssertEqual(try reopened.nativeDocument.building()?.storeys.first?.id, floor)
                resumed.end(); try await reopened.close()
                if testRun?.failureCount == 0 { try FileManager.default.removeItem(at: root) }
            } catch { try? await reopened.close(discardWorkingCopy: false); throw error }
        } catch { if !session.closed { try? await session.close(discardWorkingCopy: false) }; throw error }
    }
}
#endif
