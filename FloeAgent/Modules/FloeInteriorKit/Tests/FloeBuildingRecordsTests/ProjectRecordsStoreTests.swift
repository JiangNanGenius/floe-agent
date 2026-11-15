import Foundation
import XCTest
import GRDB
@testable import FloeBuildingRecords

final class ProjectRecordsStoreTests: XCTestCase {
    func testCreateReopenAndRevision() throws {
        let project = try TestProject(name: "Reopen Home")
        defer { project.cleanup() }

        XCTAssertEqual(try project.store.currentRevision(), 0)
        XCTAssertEqual(try project.store.currentProject().name, "Reopen Home")
        let room = try createRoom(
            project.store,
            name: "厨房",
            storey: "1F",
            kind: .kitchen,
            aliases: ["中厨"],
            revision: 0
        )
        XCTAssertEqual(room.receipt.revision, 1)
        XCTAssertEqual(room.value.name, "厨房")
        let roomID = room.value.id
        let projectID = project.store.projectID

        try project.store.close()
        let reopened = try ProjectRecordsStore.openProject(at: project.root)
        defer { try? reopened.close() }
        XCTAssertEqual(reopened.projectID, projectID)
        XCTAssertEqual(try reopened.currentRevision(), 1)
        XCTAssertEqual(try reopened.room(roomID).name, "厨房")
        XCTAssertEqual(try reopened.currentProject().name, "Reopen Home")
    }

    func testStaleRevisionRejectedWithoutMutation() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        _ = try createRoom(project.store, name: "厨房", revision: 0)
        assertRecordsError(
            try project.store.createRoom(RoomDraft(name: "客厅"), expectedRevision: 0),
            .revisionConflict(expected: 0, actual: 1)
        )
        XCTAssertEqual(try project.store.rooms().count, 1)
        XCTAssertEqual(try project.store.currentRevision(), 1)
    }

    func testProjectRenameUsesCASAndNoOp() throws {
        let project = try TestProject(name: "Old Name")
        defer { project.cleanup() }

        let renamed = try project.store.renameProject(to: "New Name", expectedRevision: 0)
        XCTAssertTrue(renamed.receipt.didChange)
        XCTAssertEqual(renamed.receipt.revision, 1)
        XCTAssertEqual(renamed.value.name, "New Name")

        let noOp = try project.store.renameProject(to: "New Name", expectedRevision: 0)
        XCTAssertFalse(noOp.receipt.didChange)
        XCTAssertEqual(noOp.receipt.revision, 1)
        XCTAssertEqual(try project.store.currentRevision(), 1)

        assertRecordsError(
            try project.store.renameProject(to: "Other Name", expectedRevision: 0),
            .revisionConflict(expected: 0, actual: 1)
        )
        XCTAssertEqual(try project.store.currentProject().name, "New Name")
    }

    func testRoomRenamePreservesSourceObservationAndAlias() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let room = try createRoom(
            project.store,
            name: "厨房",
            storey: "1F",
            aliases: ["中厨"],
            revision: 0
        )
        let imported = try importTextSource(
            project.store,
            title: "厨房说明",
            name: "kitchen.txt",
            text: "厨房 3.6 m",
            roomIDs: [room.value.id],
            revision: room.receipt.revision
        )
        let observation = try project.store.recordObservation(
            ObservationDraft(
                roomID: room.value.id,
                propertyKey: "room.length_m",
                rawValue: "厨房 3.6 m",
                normalizedValue: try RecordedValue(number: 3.6, unit: "m"),
                sourceVersionID: imported.value.version.id
            ),
            expectedRevision: imported.receipt.revision
        )

        let renamed = try project.store.renameRoom(
            room.value.id,
            to: "开放式厨房",
            expectedRevision: observation.receipt.revision
        )
        XCTAssertEqual(renamed.value.name, "开放式厨房")
        XCTAssertTrue(try project.store.source(imported.value.source.id).roomIDs.contains(room.value.id))
        XCTAssertEqual(try project.store.observation(observation.value.id).roomID, room.value.id)
        XCTAssertEqual(try project.store.room(room.value.id).aliases, ["中厨"])
    }

    func testSourceImportIsContentAddressedAndIdempotent() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let request = SourceImportRequest(
            kind: .note,
            title: "Measurements",
            originalName: "measurements.txt",
            mediaType: "text/plain",
            data: Data("kitchen 3.6m".utf8),
            idempotencyKey: "measurements-v1"
        )
        let first = try project.store.importSource(request, expectedRevision: 0)
        XCTAssertTrue(first.receipt.didChange)
        XCTAssertEqual(first.receipt.revision, 1)
        let firstVersion = first.value.version
        let firstSource = first.value.source
        let blobURL = project.root.appendingPathComponent(firstVersion.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))

        let replay = try project.store.importSource(request, expectedRevision: 0)
        XCTAssertFalse(replay.receipt.didChange)
        XCTAssertEqual(replay.receipt.revision, 1)
        XCTAssertEqual(replay.value.version.id, firstVersion.id)
        XCTAssertEqual(replay.value.source.id, firstSource.id)

        var staleRequest = request
        staleRequest.idempotencyKey = "measurements-stale"
        assertRecordsError(
            try project.store.importSource(staleRequest, expectedRevision: 0),
            .revisionConflict(expected: 0, actual: 1)
        )
        XCTAssertEqual(try project.store.sources(limit: 10).count, 1)

        var secondRequest = request
        secondRequest.idempotencyKey = "measurements-v2"
        let second = try project.store.importSource(secondRequest, expectedRevision: 1)
        XCTAssertEqual(second.receipt.revision, 2)
        XCTAssertNotEqual(second.value.source.id, firstSource.id)
        XCTAssertEqual(second.value.version.relativePath, firstVersion.relativePath)
        XCTAssertEqual(try project.store.sources(limit: 10).count, 2)

        let appended = try project.store.addSourceVersion(
            firstSource.id,
            data: Data("kitchen 4.0m".utf8),
            originalName: "measurements-v2.txt",
            mediaType: "text/plain",
            note: "revised",
            expectedRevision: 2
        )
        XCTAssertTrue(appended.receipt.didChange)
        XCTAssertEqual(appended.value.version, 2)
        XCTAssertEqual(try project.store.sourceVersions(of: firstSource.id).count, 2)
        XCTAssertEqual(try project.store.sourceVersionContent(firstVersion.id).data, Data("kitchen 3.6m".utf8))
        XCTAssertEqual(try project.store.sourceVersionContent(appended.value.id).data, Data("kitchen 4.0m".utf8))
    }

    func testSourceImportRejectsUnsafeNameAndSize() throws {
        let project = try TestProject(limits: RecordsLimits(maxSourceBytes: 8))
        defer { project.cleanup() }

        assertRecordsError(
            try project.store.importSource(
                SourceImportRequest(
                    kind: .note,
                    title: "Too big",
                    originalName: "large.txt",
                    mediaType: "text/plain",
                    data: Data(repeating: 0x41, count: 9)
                ),
                expectedRevision: 0
            ),
            .contentTooLarge(limit: 8, actual: 9)
        )
        assertRecordsError(
            try project.store.importSource(
                SourceImportRequest(
                    kind: .note,
                    title: "Traversal",
                    originalName: "../outside.txt",
                    mediaType: "text/plain",
                    data: Data("x".utf8)
                ),
                expectedRevision: 0
            ),
            .invalidOriginalName
        )
        XCTAssertEqual(try project.store.sources(limit: 10).count, 0)
        XCTAssertEqual(try project.store.currentRevision(), 0)
    }

    func testObservationAdoptionHistoryAndNoOpReplay() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let room = try createRoom(project.store, name: "厨房", revision: 0)
        let first = try project.store.recordObservation(
            ObservationDraft(
                roomID: room.value.id,
                propertyKey: "room.length_m",
                rawValue: "3.6 m",
                normalizedValue: try RecordedValue(number: 3.6, unit: "m")
            ),
            expectedRevision: 1
        )
        let second = try project.store.recordObservation(
            ObservationDraft(
                roomID: room.value.id,
                propertyKey: "room.length_m",
                rawValue: "4.0 m",
                normalizedValue: try RecordedValue(number: 4.0, unit: "m"),
                origin: .manualMeasurement
            ),
            expectedRevision: 2
        )
        XCTAssertEqual(first.value.adoptionState, .unverified)
        XCTAssertEqual(second.value.adoptionState, .unverified)

        let adoptedFirst = try project.store.adoptObservation(first.value.id, expectedRevision: 3)
        XCTAssertEqual(adoptedFirst.receipt.revision, 4)
        XCTAssertEqual(adoptedFirst.value.value, try RecordedValue(number: 3.6, unit: "m"))
        XCTAssertEqual(try project.store.observation(first.value.id).adoptionState, .adopted(adoptedFirst.value.id))

        let adoptedSecond = try project.store.adoptObservation(second.value.id, expectedRevision: 4)
        XCTAssertEqual(adoptedSecond.receipt.revision, 5)

        let history = try project.store.adoptedValueHistory(
            roomID: room.value.id,
            propertyKey: "room.length_m"
        )
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first(where: { $0.supersededBy == nil })?.id, adoptedSecond.value.id)
        XCTAssertEqual(
            history.first(where: { $0.id == adoptedFirst.value.id })?.supersededBy,
            adoptedSecond.value.id
        )
        if case .superseded(let by) = try project.store.observation(first.value.id).adoptionState {
            XCTAssertEqual(by, adoptedSecond.value.id)
        } else {
            XCTFail("The first observation should be superseded")
        }

        let replay = try project.store.adoptObservation(second.value.id, expectedRevision: 3)
        XCTAssertFalse(replay.receipt.didChange)
        XCTAssertEqual(replay.receipt.revision, 5)
        XCTAssertEqual(try project.store.currentRevision(), 5)
        XCTAssertEqual(
            try project.store.adoptedValue(roomID: room.value.id, propertyKey: "room.length_m")?.value,
            try RecordedValue(number: 4.0, unit: "m")
        )
    }

    func testBatchObservationRollback() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let room = try createRoom(project.store, name: "客厅", revision: 0)
        let invalidRoomID = RoomID()
        assertRecordsError(
            try project.store.recordObservations(
                [
                    ObservationDraft(
                        roomID: room.value.id,
                        propertyKey: "room.width_m",
                        rawValue: "4 m",
                        normalizedValue: try RecordedValue(number: 4, unit: "m")
                    ),
                    ObservationDraft(
                        roomID: invalidRoomID,
                        propertyKey: "room.width_m",
                        rawValue: "5 m",
                        normalizedValue: try RecordedValue(number: 5, unit: "m")
                    )
                ],
                expectedRevision: 1
            ),
            .roomNotFound(invalidRoomID)
        )
        XCTAssertEqual(try project.store.observations(limit: 10).count, 0)
        XCTAssertEqual(try project.store.currentRevision(), 1)
    }

    func testSourceAssociationsCASAndRoomRename() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let living = try createRoom(project.store, name: "客厅", revision: kitchen.receipt.revision)
        let imported = try importTextSource(
            project.store,
            title: "Shared plan",
            name: "plan.txt",
            text: "shared plan",
            revision: living.receipt.revision
        )
        let associated = try project.store.setSourceRooms(
            imported.value.source.id,
            roomIDs: [kitchen.value.id],
            expectedRevision: imported.receipt.revision
        )
        XCTAssertEqual(associated.value.roomIDs, [kitchen.value.id])
        XCTAssertTrue(associated.receipt.didChange)

        let noOp = try project.store.setSourceRooms(
            imported.value.source.id,
            roomIDs: [kitchen.value.id],
            expectedRevision: imported.receipt.revision
        )
        XCTAssertFalse(noOp.receipt.didChange)
        XCTAssertEqual(noOp.receipt.revision, associated.receipt.revision)

        assertRecordsError(
            try project.store.setSourceRooms(
                imported.value.source.id,
                roomIDs: [kitchen.value.id, living.value.id],
                expectedRevision: imported.receipt.revision
            ),
            .revisionConflict(expected: imported.receipt.revision, actual: associated.receipt.revision)
        )
        let both = try project.store.setSourceRooms(
            imported.value.source.id,
            roomIDs: [kitchen.value.id, living.value.id],
            expectedRevision: associated.receipt.revision
        )
        XCTAssertEqual(Set(both.value.roomIDs), Set([kitchen.value.id, living.value.id]))

        let renamed = try project.store.renameRoom(
            kitchen.value.id,
            to: "开放式厨房",
            expectedRevision: both.receipt.revision
        )
        XCTAssertEqual(renamed.value.name, "开放式厨房")
        XCTAssertEqual(
            Set(try project.store.source(imported.value.source.id).roomIDs),
            Set([kitchen.value.id, living.value.id])
        )
    }

    func testSearchIsBoundedAndUsesAliases() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let living = try createRoom(
            project.store,
            name: "客厅",
            aliases: ["起居室"],
            revision: 0
        )
        _ = try createRoom(project.store, name: "厨房", revision: living.receipt.revision)
        let source = try importTextSource(
            project.store,
            title: "客厅手绘说明",
            name: "living.txt",
            text: "living room note",
            revision: 2
        )
        XCTAssertEqual(source.receipt.revision, 3)

        let byName = try project.store.search("客厅")
        XCTAssertTrue(byName.contains { $0.reference == .room(living.value.id) })
        XCTAssertTrue(byName.contains { $0.reference == .source(source.value.source.id) })

        let byAlias = try project.store.search("起居")
        XCTAssertTrue(byAlias.contains { $0.reference == .room(living.value.id) })

        XCTAssertEqual(try project.store.search("厨房", limit: 1).count, 1)
        XCTAssertTrue(try project.store.search(" ").isEmpty)
        assertRecordsError(
            try project.store.search("x", offset: 1_001),
            .invalidValue(field: "search.offset", reason: "must be 0...1000")
        )
        assertRecordsError(
            try project.store.search(String(repeating: "x", count: 201)),
            .invalidValue(field: "search.query", reason: "must be at most 200 characters")
        )
    }

    func testIntegrityReportStagingAndMissingBlob() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let room = try createRoom(project.store, name: "厨房", revision: 0)
        let imported = try importTextSource(
            project.store,
            title: "Source",
            name: "source.txt",
            text: "source bytes",
            roomIDs: [room.value.id],
            revision: 1
        )
        let stagingDirectory = project.root.appendingPathComponent(
            "Building/Sources/.staging",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: stagingDirectory.appendingPathComponent("leftover.part"))

        let report = try project.store.integrityReport(deepVerify: true)
        XCTAssertTrue(report.databaseCheckPassed)
        XCTAssertEqual(report.sourceVersionCount, 1)
        XCTAssertTrue(report.orphanStagingFiles.contains("leftover.part"))
        XCTAssertEqual(try project.store.discardStagedImports(), 1)
        XCTAssertTrue(try project.store.integrityReport().orphanStagingFiles.isEmpty)

        let blobURL = project.root.appendingPathComponent(imported.value.version.relativePath)
        try FileManager.default.removeItem(at: blobURL)
        let missing = try project.store.integrityReport(deepVerify: true)
        XCTAssertTrue(missing.missingSourceVersionIDs.contains(imported.value.version.id))
        XCTAssertThrowsError(try project.store.sourceVersionContent(imported.value.version.id)) { error in
            XCTAssertEqual(error as? BuildingRecordsError, .sourceFileMissing(imported.value.version.id))
        }
    }
    func testLegacyObservationOriginMigrationAndNewOriginPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-legacy-origin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let building = root.appendingPathComponent("Building")
        try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: building.appendingPathComponent("Records.sqlite").path)
        try ProjectRecordsStore.makeMigrator().migrate(queue, upTo: "building.records.v2.bom")
        let projectID = ProjectID(), roomID = RoomID(), oldID = ObservationID(), now = Date()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO project_state(singleton,project_id,name,created_at,updated_at,records_revision) VALUES(1,?,?,?,?,0)", arguments: [projectID.rawValue.uuidString.lowercased(), "Legacy", now, now])
            try db.execute(sql: "INSERT INTO room(id,project_id,name,kind,notes,created_at,updated_at) VALUES(?,?,?,'other','',?,?)", arguments: [roomID.rawValue.uuidString.lowercased(), projectID.rawValue.uuidString.lowercased(), "Legacy room", now, now])
            try db.execute(sql: "INSERT INTO observation(id,project_id,room_id,property_key,raw_value,value_kind,value_number,value_unit,created_at) VALUES(?,?,?,'length','3.6m','number',3.6,'m',?)", arguments: [oldID.rawValue.uuidString.lowercased(), projectID.rawValue.uuidString.lowercased(), roomID.rawValue.uuidString.lowercased(), now])
        }
        try queue.close()
        let store = try ProjectRecordsStore.openProject(at: root)
        XCTAssertEqual(try store.observation(oldID).origin, .unknown)
        XCTAssertEqual(try store.observation(oldID).rawValue, "3.6m")
        let fresh = try store.recordObservation(.init(roomID: roomID, propertyKey: "length", rawValue: "4.2m", normalizedValue: try .init(number: 4.2, unit: "m"), origin: .manualMeasurement), expectedRevision: 0)
        try store.close()
        let reopened = try ProjectRecordsStore.openProject(at: root)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.observation(oldID).origin, .unknown)
        XCTAssertEqual(try reopened.observation(fresh.value.id).origin, .manualMeasurement)
        XCTAssertEqual(try reopened.currentRevision(), 1)
    }

}
