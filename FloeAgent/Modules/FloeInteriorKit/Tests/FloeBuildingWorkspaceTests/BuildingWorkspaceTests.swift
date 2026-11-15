// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeBuildingRecords
@testable import FloeBuildingWorkspace

@MainActor
final class BuildingWorkspaceTests: XCTestCase {
    private func withWorkspace(limits: RecordsLimits = .init(), _ body: (BuildingWorkspaceService, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-workspace-test-" + UUID().uuidString)
        let service = BuildingWorkspaceService(projectDirectory: root, recordsLimits: limits)
        do {
            try await body(service, root)
            try await service.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await service.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    func testSourceRoomAssociationSurvivesRenameAndReopen() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            let roomState = try await service.createRoom(name: "客厅", projectID: initial.project.id, expectedRevision: initial.project.revision)
            let room = try XCTUnwrap(roomState.rooms.first)
            let data = Data("手绘墙长 4200 mm".utf8)
            let imported = try await service.importData(.init(kind: .sketch, title: "手绘", originalName: "sketch.txt", mediaType: "text/plain", data: data), projectID: initial.project.id, expectedRevision: roomState.project.revision)
            let source = try XCTUnwrap(imported.sources.first)
            let assigned = try await service.associateSource(source.id, roomIDs: [room.id], projectID: initial.project.id, expectedRevision: imported.project.revision)
            _ = try await service.renameRoom(room.id, name: "起居室", projectID: initial.project.id, expectedRevision: assigned.project.revision)
            try await service.close()
            let reopened = try await service.snapshot()
            XCTAssertEqual(reopened.rooms.first?.id, room.id)
            XCTAssertEqual(reopened.rooms.first?.name, "起居室")
            XCTAssertEqual(reopened.sources.first?.roomIDs, [room.id])
            let content = try await service.sourceContent(source.latestVersionID, projectID: initial.project.id)
            XCTAssertEqual(content.data, data)
        }
    }
    func testWrongProjectAndStaleMutationDoNotWrite() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            _ = try await service.createRoom(name: "A", projectID: initial.project.id, expectedRevision: initial.project.revision)
            do {
                _ = try await service.createRoom(name: "stale", projectID: initial.project.id, expectedRevision: initial.project.revision)
                XCTFail("stale mutation accepted")
            } catch { }
            do {
                _ = try await service.createRoom(name: "outside", projectID: ProjectID(), expectedRevision: 1)
                XCTFail("wrong project accepted")
            } catch { XCTAssertEqual(error as? BuildingWorkspaceError, .wrongProject) }
            let final = try await service.snapshot()
            XCTAssertEqual(final.rooms.map(\.name), ["A"])
        }
    }
    func testCSVReplayAndApplyDoNotDuplicateSourceDraftTargetOrItems() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            let room = try await service.createRoom(name: "客厅", projectID: initial.project.id, expectedRevision: initial.project.revision)
            let csv = Data("品牌,型号,数量,单位,房间,角色,通道数\r\nSynthetic,AP-A,2,台,客厅,设计,1\r\nSynthetic,Relay-B,1,台,客厅,设计,4\r\n".utf8)
            let first = try await service.importCSV(csv, originalName: "bill.csv", projectID: initial.project.id, expectedRevision: room.project.revision, replayKey: "import-1")
            let second = try await service.importCSV(csv, originalName: "bill.csv", projectID: initial.project.id, expectedRevision: first.snapshot.project.revision, replayKey: "import-1")
            XCTAssertEqual(first.draft.id, second.draft.id)
            XCTAssertEqual(second.snapshot.sources.count, 1)
            XCTAssertEqual(second.snapshot.targets.count, 1)
            XCTAssertEqual(second.snapshot.drafts.count, 1)
            let target = try XCTUnwrap(second.draft.targetID)
            let applied = try await service.applyDraft(second.draft.id, targetID: target, projectID: initial.project.id, expectedRevision: second.snapshot.project.revision)
            let repeated = try await service.applyDraft(second.draft.id, targetID: target, projectID: initial.project.id, expectedRevision: applied.project.revision)
            XCTAssertEqual(repeated.items.count, 2)
            XCTAssertEqual(repeated.items.reduce(0) { $0 + $1.quantity }, 3)
            XCTAssertEqual(repeated.items.first(where: { $0.rawModel == "Relay-B" })?.channelsPerDevice, 4)
            try await service.close()
            let reopened = try await service.snapshot()
            XCTAssertEqual(reopened.items.count, 2)
        }
    }
    func testMalformedCSVStillPreservesOriginalForRecovery() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            let bytes = Data("brand,model,quantity\r\n\"unterminated".utf8)
            do {
                _ = try await service.importCSV(bytes, originalName: "broken.csv", projectID: initial.project.id, expectedRevision: initial.project.revision, replayKey: "broken")
                XCTFail("malformed CSV accepted")
            } catch { }
            let state = try await service.snapshot()
            XCTAssertEqual(state.sources.count, 1)
            let source = try XCTUnwrap(state.sources.first)
            let content = try await service.sourceContent(source.latestVersionID, projectID: initial.project.id)
            XCTAssertEqual(content.data, bytes)
            XCTAssertTrue(state.drafts.isEmpty)
        }
    }
    func testComponentSaveCreatesVersionsAndReopensExactPayload() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            let first = try await service.saveComponent(.cabinet, payload: Data("{\"width\":2400}".utf8), projectID: initial.project.id, expectedRevision: initial.project.revision)
            let bytes = Data("{\"width\":3000}".utf8)
            let second = try await service.saveComponent(.cabinet, payload: bytes, projectID: initial.project.id, expectedRevision: first.project.revision)
            XCTAssertEqual(second.sources.count, 1)
            XCTAssertEqual(second.sources.first?.versionCount, 2)
            try await service.close()
            let content = try await service.component(.cabinet, projectID: initial.project.id)
            XCTAssertEqual(content, bytes)
            let missing = try await service.component(.lighting, projectID: initial.project.id)
            XCTAssertNil(missing)
        }
    }
    func testComponentBudgetAndForeignReadsAreRejected() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            do {
                _ = try await service.saveComponent(.cabinet, payload: Data(count: 8 * 1024 * 1024 + 1), projectID: initial.project.id, expectedRevision: initial.project.revision)
                XCTFail("oversized component accepted")
            } catch { XCTAssertEqual(error as? BuildingWorkspaceError, .componentBudget) }
            do {
                _ = try await service.component(.cabinet, projectID: ProjectID())
                XCTFail("foreign read accepted")
            } catch { XCTAssertEqual(error as? BuildingWorkspaceError, .wrongProject) }
            let final = try await service.snapshot()
            XCTAssertTrue(final.sources.isEmpty)
        }
    }
    func testTypedAssistantExtractionKeepsRawSourceUntilExplicitAdoption() async throws {
        try await withWorkspace { service, _ in
            let start = try await service.snapshot()
            let rooms = try await service.createRoom(name: "厨房", projectID: start.project.id, expectedRevision: start.project.revision)
            let room = try XCTUnwrap(rooms.rooms.first)
            let imported = try await service.importData(.init(kind: .note, title: "现场补充", originalName: "note.txt", mediaType: "text/plain", data: Data("厨房长4.2米".utf8)), projectID: start.project.id, expectedRevision: rooms.project.revision)
            let source = try XCTUnwrap(imported.sources.first)
            let observation = ObservationDraft(roomID: room.id, propertyKey: "room.length", rawValue: "4.2米", normalizedValue: try .init(number: 4200, unit: "mm"), origin: .aiExtracted, sourceVersionID: source.latestVersionID, locator: .text(span: nil))
            let command = BuildingWorkspaceCommand.recordObservations([observation])
            let decoded = try JSONDecoder().decode(BuildingWorkspaceCommand.self, from: JSONEncoder().encode(command))
            let result = try await service.execute(decoded, projectID: start.project.id, expectedRevision: imported.project.revision)
            guard case .recorded(let mutation) = result, let candidate = mutation.value.first else { return XCTFail("record result missing") }
            XCTAssertEqual(candidate.rawValue, "4.2米")
            XCTAssertEqual(candidate.adoptionState, .unverified)
            XCTAssertEqual(candidate.sourceVersionID, source.latestVersionID)
            let adopted = try await service.execute(.adoptObservation(candidate.id), projectID: start.project.id, expectedRevision: mutation.receipt.revision)
            guard case .adopted(let value) = adopted else { return XCTFail("adoption missing") }
            XCTAssertEqual(value.value.value.number, 4200)
            try await service.close()
            let reopened = try await service.execute(.observations(roomID: room.id), projectID: start.project.id)
            guard case .observations(let values) = reopened else { return XCTFail("observations missing") }
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values[0].origin, .aiExtracted)
            guard case .adopted = values[0].adoptionState else { return XCTFail("adoption did not persist") }
            let found = try await service.execute(.search(query: "4.2米", limit: 20, offset: 0), projectID: start.project.id)
            guard case .searchHits(let hits) = found else { return XCTFail("search result missing") }
            XCTAssertTrue(hits.contains { $0.reference == .observation(candidate.id) })
        }
    }

    func testMultipleBillTargetsRequireExplicitSelection() async throws {
        try await withWorkspace { service, root in
            let start = try await service.snapshot()
            let csv = Data("型号,数量,单位,角色\r\nAP-A,2,台,设计\r\n".utf8)
            let imported = try await service.importCSV(csv, originalName: "one.csv", projectID: start.project.id, expectedRevision: start.project.revision, replayKey: "one")
            let firstID = try XCTUnwrap(imported.draft.targetID)
            _ = try await service.applyDraft(imported.draft.id, targetID: firstID, projectID: start.project.id, expectedRevision: imported.snapshot.project.revision)
            let secondStore = try ProjectRecordsStore.openProject(at: root)
            let second = try secondStore.createBOMTarget(name: "Cabinet hardware", expectedRevision: secondStore.currentRevision())
            try secondStore.close()
            let neutral = try await service.snapshot()
            XCTAssertEqual(neutral.targets.count, 2)
            XCTAssertNil(neutral.selectedTargetID)
            XCTAssertTrue(neutral.items.isEmpty)
            let chosen = try await service.snapshot(targetID: firstID)
            XCTAssertEqual(chosen.selectedTargetID, firstID)
            XCTAssertEqual(chosen.items.count, 1)
            let other = try await service.snapshot(targetID: second.value.id)
            XCTAssertTrue(other.items.isEmpty)
            do { _ = try await service.snapshot(targetID: BOMTargetID()); XCTFail("foreign target accepted") }
            catch { }
        }
    }
    func testExplicitDraftSelectionAdoptsOnlyChosenReadyRows() async throws {
        try await withWorkspace { service, _ in
            let start = try await service.snapshot()
            let csv = Data("型号,数量,单位,角色\r\nAP-A,2,台,设计\r\nRelay-B,1,台,设计\r\n".utf8)
            let imported = try await service.importCSV(csv, originalName: "selected.csv", projectID: start.project.id, expectedRevision: start.project.revision, replayKey: "selected")
            let first = try XCTUnwrap(imported.draft.rows.first)
            let target = try XCTUnwrap(imported.draft.targetID)
            let applied = try await service.applyDraft(imported.draft.id, targetID: target, projectID: start.project.id, expectedRevision: imported.snapshot.project.revision, selectedRowIDs: [first.id])
            XCTAssertEqual(applied.items.count, 1)
            XCTAssertEqual(applied.items.first?.rawModel, "AP-A")
            XCTAssertEqual(applied.items.first?.quantity, 2)
            let repeated = try await service.applyDraft(imported.draft.id, targetID: target, projectID: start.project.id, expectedRevision: applied.project.revision, selectedRowIDs: [first.id])
            XCTAssertEqual(repeated.items.count, 1)
            XCTAssertEqual(repeated.items.first?.quantity, 2)
            do {
                _ = try await service.applyDraft(imported.draft.id, targetID: target, projectID: start.project.id, expectedRevision: repeated.project.revision, selectedRowIDs: [])
                XCTFail("empty selection accepted")
            } catch { XCTAssertEqual(error as? BuildingRecordsError, .emptySelection) }
        }
    }
    func testSourcePagesRetainRoomFilterAndBoundProject() async throws {
        try await withWorkspace { service, _ in
            let initial = try await service.snapshot()
            var current = try await service.createRoom(name: "书房", projectID: initial.project.id, expectedRevision: initial.project.revision)
            let room = try XCTUnwrap(current.rooms.first)
            for index in 0..<15 {
                current = try await service.importData(.init(kind: .note, title: "N" + String(index), originalName: "n" + String(index) + ".txt", mediaType: "text/plain", data: Data(String(index).utf8), roomIDs: index < 5 ? [room.id] : []), projectID: initial.project.id, expectedRevision: current.project.revision)
            }
            let first = try await service.sourcePage(projectID: initial.project.id, pageSize: 7)
            let second = try await service.sourcePage(projectID: initial.project.id, pageSize: 7, offset: try XCTUnwrap(first.nextOffset))
            let third = try await service.sourcePage(projectID: initial.project.id, pageSize: 7, offset: try XCTUnwrap(second.nextOffset))
            XCTAssertEqual(Set((first.items + second.items + third.items).map(\.id)).count, 15)
            XCTAssertNil(third.nextOffset)
            XCTAssertFalse(third.requiresFilter)
            XCTAssertEqual(first.revision, current.project.revision)
            let filtered = try await service.sourcePage(projectID: initial.project.id, roomID: room.id)
            XCTAssertEqual(filtered.items.count, 5)
            do { _ = try await service.sourcePage(projectID: ProjectID()); XCTFail("foreign project accepted") }
            catch { XCTAssertEqual(error as? BuildingWorkspaceError, .wrongProject) }
            do { _ = try await service.sourcePage(projectID: initial.project.id, pageSize: 0); XCTFail("zero page accepted") }
            catch { }
        }
    }
    func testPageBudgetSignalsNeedToFilterWithoutLosingOriginals() async throws {
        try await withWorkspace(limits: .init(maxSearchOffset: 0)) { service, _ in
            var current = try await service.snapshot()
            for index in 0..<3 {
                current = try await service.importData(.init(kind: .note, title: "N" + String(index), originalName: "n.txt", mediaType: "text/plain", data: Data(String(index).utf8)), projectID: current.project.id, expectedRevision: current.project.revision)
            }
            let first = try await service.sourcePage(projectID: current.project.id, pageSize: 2)
            XCTAssertEqual(first.items.count, 2)
            XCTAssertNil(first.nextOffset)
            XCTAssertTrue(first.requiresFilter)
            XCTAssertEqual(current.sources.count, 3)
            do { _ = try await service.sourcePage(projectID: current.project.id, pageSize: 2, offset: 2); XCTFail("budget bypass") }
            catch { }
        }
    }

    func testVersionedSaveRejectsAnExternalComponentChangeAfterMetadataRefresh() async throws {
        try await withWorkspace { service, root in
            let initial = try await service.loadProject()
            XCTAssertEqual(initial.components[.cabinet]?.base, .absent)
            let first = try await service.saveComponentVersioned(.cabinet, payload: Data("first".utf8), projectID: initial.snapshot.project.id, expectedRevision: initial.snapshot.project.revision, expectedBase: .absent)
            let other = BuildingWorkspaceService(projectDirectory: root)
            let external = try await other.saveComponentVersioned(.cabinet, payload: Data("external".utf8), projectID: first.snapshot.project.id, expectedRevision: first.snapshot.project.revision, expectedBase: first.base)
            try await other.close()
            let refreshed = try await service.snapshot()
            XCTAssertEqual(refreshed.project.revision, external.snapshot.project.revision)
            do {
                _ = try await service.saveComponentVersioned(.cabinet, payload: Data("stale local".utf8), projectID: refreshed.project.id, expectedRevision: refreshed.project.revision, expectedBase: first.base)
                XCTFail("refreshed metadata must not permit overwriting an unseen component version")
            } catch { XCTAssertEqual(error as? BuildingWorkspaceError, .componentChanged) }
            let current = try await service.componentState(.cabinet, projectID: refreshed.project.id)
            XCTAssertEqual(current.payload, Data("external".utf8))
            XCTAssertEqual(current.base, external.base)
        }
    }
    func testUnboundIntakeRequiresExplicitTargetAndKeepsSourceIdentity() async throws {
        try await withWorkspace { service, _ in
            let start = try await service.snapshot()
            let bytes = Data("品牌,型号,数量,单位,角色\r\nSynthetic,AP,2,台,设计\r\n".utf8)
            let intake = try await service.intakeCSV(bytes, originalName: "unbound.csv", projectID: start.project.id, expectedRevision: start.project.revision, replayKey: "unbound")
            XCTAssertNil(intake.draft.targetID)
            XCTAssertTrue(intake.snapshot.targets.isEmpty)
            XCTAssertEqual(intake.sourceID, intake.snapshot.sources.first?.id)
            let target = try await service.createBOMTarget(name: "已确认方案", projectID: start.project.id, expectedRevision: intake.snapshot.project.revision)
            let id = try XCTUnwrap(target.selectedTargetID)
            let applied = try await service.applyDraft(intake.draft.id, targetID: id, projectID: start.project.id, expectedRevision: target.project.revision, selectedRowIDs: Set(intake.draft.rows.map(\.id)))
            XCTAssertEqual(applied.items.count, 1)
            XCTAssertEqual(applied.items.first?.quantity, 2)
            XCTAssertEqual(applied.sources.count, 1)
        }
    }
    func testIntakeFailureCarriesRecoverableArchivedSource() async throws {
        try await withWorkspace { service, _ in
            let start = try await service.snapshot()
            let bytes = Data("brand,model\r\n\"unterminated".utf8)
            do {
                _ = try await service.intakeCSV(bytes, originalName: "broken.csv", projectID: start.project.id, expectedRevision: start.project.revision, replayKey: "broken-intake")
                XCTFail("malformed table accepted")
            } catch let error as BuildingWorkspaceIntakeError {
                XCTAssertEqual(error.archived.snapshot.sources.count, 1)
                let content = try await service.sourceContent(error.archived.version.id, projectID: start.project.id)
                XCTAssertEqual(content.data, bytes)
                XCTAssertEqual(error.archived.source.id, content.version.sourceID)
            }
            let stored = try await service.snapshot()
            XCTAssertTrue(stored.drafts.isEmpty)
            XCTAssertTrue(stored.targets.isEmpty)
        }
    }

}
