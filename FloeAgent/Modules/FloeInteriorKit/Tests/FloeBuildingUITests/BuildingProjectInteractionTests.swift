// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingUI
import FloeBuildingWorkspace
import FloeBuildingRecords

@MainActor
final class BuildingProjectInteractionTests: XCTestCase {
    func testHostLocaleIsPerProjectAndUpdatesNumericInputLocale() {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first=BuildingWorkspaceSession(directory:base.appendingPathComponent("First"))
        let second=BuildingWorkspaceSession(directory:base.appendingPathComponent("Second"))
        first.locale=Locale(identifier:"zh_CN");second.locale=Locale(identifier:"en_US")
        XCTAssertEqual(first.text("柜体","Cabinet"),"柜体")
        XCTAssertEqual(second.text("柜体","Cabinet"),"Cabinet")
        first.locale=Locale(identifier:"de_DE")
        XCTAssertEqual(first.numberInputs.locale.decimalSeparator,",")
        XCTAssertEqual(second.numberInputs.locale.decimalSeparator,".")
        XCTAssertEqual(BuildingSection.cabinet.title(locale:Locale(identifier:"zh_CN")),"柜体与图纸")
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.path))
    }
    private enum Injected: Error {case checkpoint, cabinet}
    @MainActor private final class Hooks {
        var unpublished = false
        var failCheckpoint = false
        var failCabinet = false
        var checkpoints: [BuildingWorkbenchCheckpoint] = []
        var cabinets: [BuildingWorkbenchCheckpoint] = []
        var closed = 0
        var reopened = 0
        var departureAllowed = true
        var departureFinished = 0
        var replaceOnReopen = false
        var revisions: [(ProjectID, Int)] = []
    }

    private func settled(_ session: BuildingWorkspaceSession) async throws {
        for _ in 0..<200 {
            if !session.busy {return}
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The owned UI operation did not finish")
        throw CancellationError()
    }

    private func fixture(_ body: (BuildingWorkspaceSession, Hooks) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = BuildingWorkspaceService(projectDirectory: root)
        let hooks = Hooks()
        let actions = BuildingWorkbenchProjectActions(
            hasUnpublishedChanges: {hooks.unpublished},
            checkpoint: {request in
                hooks.checkpoints.append(request)
                if hooks.failCheckpoint {throw Injected.checkpoint}
                hooks.unpublished = false
            },
            applyCabinet: {request in
                hooks.cabinets.append(request)
                if hooks.failCabinet {throw Injected.cabinet}
                hooks.unpublished = true
            },
            reopen: {hooks.reopened += 1;return hooks.replaceOnReopen ? .replacedWorkspace:.reloadWorkspace},
            close: {hooks.closed += 1},
            beforeDeparture: {_ in hooks.departureAllowed},
            departureEnded: {hooks.departureFinished += 1},
            recordsChanged: {hooks.revisions.append(($0, $1))})
        let session = BuildingWorkspaceSession(service: service, projectActions: actions)
        do {
            session.reload()
            try await settled(session)
            XCTAssertTrue(session.editorsReady)
            try await body(session, hooks)
            try await service.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await service.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func testWholeProjectCheckpointIncludesAllSavedComponentsWithoutPlacingACabinet() async throws {
        try await fixture {session, hooks in
            session.editors.cabinet.value.recipe.widthMM = 2600
            session.saveProject()
            try await self.settled(session)
            let request = try XCTUnwrap(hooks.checkpoints.last)
            let stored = try await session.service.loadProject()
            XCTAssertEqual(request.recordsRevision, stored.snapshot.project.revision)
            XCTAssertEqual(request.projectID, stored.snapshot.project.id)
            XCTAssertEqual(request.cabinetRecipe.widthMM, 2600)
            for kind in BuildingComponentKind.allCases {XCTAssertNotNil(stored.components[kind]?.payload)}
            XCTAssertTrue(hooks.cabinets.isEmpty, "Saving a default design must not place unsolicited geometry")
            XCTAssertNil(session.error)
        }
    }

    func testFailedProjectPublicationRemainsDirtyAndCanRetryTheSameWorkingCopy() async throws {
        try await fixture {session, hooks in
            hooks.unpublished = true
            hooks.failCheckpoint = true
            session.editors.cabinet.value.recipe.widthMM = 2700
            session.saveProject()
            try await self.settled(session)
            XCTAssertNotNil(session.error)
            XCTAssertTrue(hooks.unpublished)
            session.requestClose()
            XCTAssertTrue(session.reopenConfirmation)
            XCTAssertEqual(hooks.closed, 0)
            XCTAssertEqual(session.editors.cabinet.value.recipe.widthMM, 2700)
            hooks.failCheckpoint = false
            session.saveProject()
            try await self.settled(session)
            XCTAssertEqual(hooks.checkpoints.count, 2)
            XCTAssertFalse(hooks.unpublished)
            XCTAssertNil(session.error)
        }
    }

    func testUnsubmittedFormPreventsProjectPublicationAndRetainsInput() async throws {
        try await fixture {session, hooks in
            session.roomDraftName = "Kitchen pending"
            session.saveProject()
            XCTAssertFalse(session.busy)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
            XCTAssertEqual(session.roomDraftName, "Kitchen pending")
            XCTAssertNotNil(session.error)
        }
    }

    func testCabinetPlacementIsExplicitAndFailureDoesNotLoseTheRecipe() async throws {
        try await fixture {session, hooks in
            session.editors.cabinet.value.recipe.widthMM = 2800
            hooks.failCabinet = true
            session.applyCabinet()
            try await self.settled(session)
            XCTAssertEqual(hooks.cabinets.count, 1)
            XCTAssertEqual(session.editors.cabinet.value.recipe.widthMM, 2800)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
            XCTAssertNotNil(session.error)
            hooks.failCabinet = false
            session.applyCabinet()
            try await self.settled(session)
            XCTAssertTrue(hooks.unpublished)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
            XCTAssertNil(session.error)
        }
    }

    func testCleanCloseCallsOneHostCloseWithoutPublishing() async throws {
        try await fixture {session, hooks in
            session.requestClose()
            try await self.settled(session)
            XCTAssertEqual(hooks.closed, 1)
            XCTAssertEqual(hooks.reopened, 0)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
        }
    }

    func testDirtyCloseRequiresDecisionAndSaveClosesOnlyAfterCheckpoint() async throws {
        try await fixture {session, hooks in
            hooks.unpublished = true
            session.requestClose()
            XCTAssertTrue(session.closingProject)
            XCTAssertTrue(session.reopenConfirmation)
            XCTAssertEqual(hooks.closed, 0)
            session.saveAllAndReopen()
            try await self.settled(session)
            XCTAssertEqual(hooks.checkpoints.count, 1)
            XCTAssertEqual(hooks.closed, 1)
            XCTAssertEqual(hooks.reopened, 0)
        }
    }

    func testDiscardCloseDoesNotPublishAndReopenUsesItsOwnHostAction() async throws {
        try await fixture {session, hooks in
            hooks.unpublished = true
            session.requestClose()
            session.reopenDiscarding()
            try await self.settled(session)
            XCTAssertEqual(hooks.closed, 1)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
        }
        try await fixture {session, hooks in
            session.requestReopen()
            try await self.settled(session)
            XCTAssertEqual(hooks.reopened, 1)
            XCTAssertEqual(hooks.closed, 0)
            XCTAssertTrue(session.editorsReady)
        }
    }

    func testDirectRecordsMutationNotifiesTheSameProjectRevision() async throws {
        try await fixture {session, hooks in
            session.targetDraftName = "Installation bill"
            session.createTarget()
            try await self.settled(session)
            let project = try XCTUnwrap(session.snapshot?.project)
            XCTAssertEqual(hooks.revisions.last?.0, project.id)
            XCTAssertEqual(hooks.revisions.last?.1, project.revision)
        }
    }

    func testHostDepartureCancellationDoesNotPublishOrClose() async throws {
        try await fixture {session,hooks in
            hooks.unpublished=true;hooks.departureAllowed=false
            session.requestClose();session.saveAllAndReopen()
            try await self.settled(session)
            XCTAssertTrue(hooks.checkpoints.isEmpty)
            XCTAssertEqual(hooks.closed,0)
            XCTAssertEqual(hooks.departureFinished,1)
            XCTAssertNotNil(session.snapshot)
        }
    }

    func testReplacedMountDoesNotReloadTheRetiredWorkspace() async throws {
        try await fixture {session,hooks in
            hooks.replaceOnReopen=true
            session.requestReopen()
            try await self.settled(session)
            XCTAssertEqual(hooks.reopened,1)
            XCTAssertNil(session.snapshot)
            XCTAssertFalse(session.editorsReady)
        }
    }

    func testExternalRoomMetadataRefreshKeepsUnsavedDesignAndFormInput() async throws {
        try await fixture {session,_ in
            let project=try XCTUnwrap(session.snapshot?.project)
            session.editors.cabinet.value.recipe.widthMM=2650
            session.roomDraftName="Unsubmitted room"
            let change=try await session.service.createRoomIdentified(name:"Native-linked room",projectID:project.id,expectedRevision:project.revision)
            session.syncExternalMetadata(revision:change.snapshot.project.revision)
            try await self.settled(session)
            XCTAssertTrue(session.snapshot?.rooms.contains(where:{$0.id==change.room.id}) == true)
            XCTAssertEqual(session.editors.cabinet.value.recipe.widthMM,2650)
            XCTAssertTrue(session.editors.cabinet.isDirty)
            XCTAssertEqual(session.roomDraftName,"Unsubmitted room")
        }
    }
}
