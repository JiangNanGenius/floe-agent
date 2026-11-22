import Foundation
import XCTest
@testable import FloeDesktopSync

final class LocalOnlyDataTests: XCTestCase {
    func testDeviceLocalBindingsAndBridgeAliasesNeverEnterSyncData() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let workspace = try TestIDs.workspace(3)
        let store = try database.makeStore(deviceID: device)
        let secretRoot = "/Users/alice/Secret Project/工作区"
        let secretBookmark = Data([0x00, 0x01, 0xFE, 0xFF])

        try await store.setLocalWorkspaceBinding(
            workspaceID: workspace,
            rootPath: secretRoot,
            bookmark: secretBookmark
        )
        let binding = try await store.localWorkspaceBinding(workspaceID: workspace)
        XCTAssertEqual(binding?.rootPath, secretRoot)
        XCTAssertEqual(binding?.bookmark, secretBookmark)
        XCTAssertEqual(binding?.deviceID, device)

        let workspaceFile = try SyncRecord.test(
            kind: .workspaceFile,
            entityID: try TestIDs.entity(4),
            revision: 1,
            originDeviceID: device,
            taskID: task,
            workspaceID: workspace,
            payload: .object([
                "path": .string("notes/a.md"),
                "digest": .string("sha256:00"),
                "bytes": .string("12")
            ])
        )
        _ = try await store.commitLocalRecord(workspaceFile)

        let legacy = try LegacyBridgeIdentifier(
            validating: "/Users/alice/Secret Project/工作区/.floe/bridge"
        )
        let stableID = workspaceFile.entityID
        let mapping = try await store.registerLegacyBridgeIdentifier(
            legacy,
            kind: .workspaceFile,
            stableID: stableID
        )
        XCTAssertEqual(mapping.stableID, stableID)
        let repeated = try await store.registerLegacyBridgeIdentifier(
            legacy,
            kind: .workspaceFile,
            stableID: stableID
        )
        XCTAssertEqual(repeated, mapping)
        await XCTAssertThrowsSyncError(.legacyMappingConflict(legacy.rawValue)) {
            try await store.registerLegacyBridgeIdentifier(
                legacy,
                kind: .workspaceFile,
                stableID: try TestIDs.entity(99)
            )
        }

        let descriptor = try await store.openSnapshot()
        XCTAssertEqual(descriptor.recordCount, 1)
        let page = try await store.snapshotPage(
            descriptor.snapshotID,
            after: nil,
            limit: 10
        )
        let changes = try await store.changes(after: .zero, limit: 10)
        XCTAssertEqual(changes.entries.count, 1)

        let serialized = page.records.map { $0.payload.canonicalJSON() }
            + changes.entries.compactMap { $0.payload?.canonicalJSON() }
        for text in serialized {
            XCTAssertFalse(text.contains("/Users/alice"))
            XCTAssertFalse(text.contains("Secret Project"))
            XCTAssertFalse(text.contains("bookmark"))
            XCTAssertFalse(text.contains(secretBookmark.base64EncodedString()))
        }
        XCTAssertEqual(page.records.first?.payload["path"]?.stringValue, "notes/a.md")

        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.recordCount, 1)
        XCTAssertEqual(metadata.commandCount, 0)

        // A legacy path is device-local: the same path may map to a different
        // stable identity in another device's database.
        let otherDevice = try TestIDs.device(50)
        let otherDatabase = try TestDatabase()
        addTeardownBlock { otherDatabase.remove() }
        let otherStore = try otherDatabase.makeStore(deviceID: otherDevice)
        let otherStableID = try TestIDs.entity(500)
        let otherMapping = try await otherStore.registerLegacyBridgeIdentifier(
            legacy,
            kind: .workspaceFile,
            stableID: otherStableID
        )
        XCTAssertEqual(otherMapping.stableID, otherStableID)
        let original = try await store.legacyMapping(for: legacy)
        XCTAssertEqual(original?.stableID, stableID)
        await otherStore.close()
        await store.close()
    }

    func testPortableRecordValidationRejectsLocalFieldsAndPaths() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let workspace = try TestIDs.workspace(3)
        let store = try database.makeStore(deviceID: device)

        let withRootPath = try SyncRecord.test(
            entityID: try TestIDs.entity(10),
            revision: 1,
            originDeviceID: device,
            taskID: task,
            payload: .object(["rootPath": .string("/Users/alice/project")])
        )
        await XCTAssertThrowsSyncError(.nonPortableField("rootPath")) {
            try await store.commitLocalRecord(withRootPath)
        }
        let missing = try await store.storedRecord(
            kind: .task,
            entityID: withRootPath.entityID
        )
        XCTAssertNil(missing)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, .zero)

        for path in ["/tmp/a.md", "../a.md", "notes\\a.md", "C:/a.md"] {
            let invalid = try SyncRecord.test(
                kind: .workspaceFile,
                entityID: try TestIDs.entity(11),
                revision: 1,
                originDeviceID: device,
                taskID: task,
                workspaceID: workspace,
                payload: .object(["path": .string(path)])
            )
            await XCTAssertThrowsSyncError(.invalidPortablePath(path)) {
                try await store.commitLocalRecord(invalid)
            }
        }

        let relative = try SyncRecord.test(
            kind: .workspaceFile,
            entityID: try TestIDs.entity(12),
            revision: 1,
            originDeviceID: device,
            taskID: task,
            workspaceID: workspace,
            payload: .object(["path": .string("notes/说明.md")])
        )
        _ = try await store.commitLocalRecord(relative)

        let wrongOrigin = try SyncRecord.test(
            entityID: try TestIDs.entity(13),
            revision: 1,
            originDeviceID: try TestIDs.device(9),
            taskID: task
        )
        await XCTAssertThrowsSyncError(
            .recordOriginMismatch(expected: device, found: try TestIDs.device(9))
        ) {
            try await store.commitLocalRecord(wrongOrigin)
        }

        let command = SyncCommand(
            commandID: try TestIDs.command(14),
            kind: .taskSubmit,
            taskID: task,
            payload: .object([
                "goal": .string("x"),
                "devicePermissions": .array([.string("camera")])
            ])
        )
        await XCTAssertThrowsSyncError(.nonPortableField("devicePermissions")) {
            try await store.accept(command)
        }
        let commandReceipt = try await store.receipt(for: command.commandID)
        XCTAssertNil(commandReceipt)

        let absoluteWorkspaceCommand = SyncCommand(
            commandID: try TestIDs.command(15),
            kind: .workspaceCommitFile,
            workspaceID: workspace,
            payload: .object(["path": .string("/tmp/absolute.md")])
        )
        await XCTAssertThrowsSyncError(.invalidPortablePath("/tmp/absolute.md")) {
            try await store.accept(absoluteWorkspaceCommand)
        }
        let absoluteReceipt = try await store.receipt(
            for: absoluteWorkspaceCommand.commandID
        )
        XCTAssertNil(absoluteReceipt)
        await store.close()
    }

    func testWrongDeviceCannotOpenAnExistingDatabase() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let store = try database.makeStore(deviceID: device)
        let record = try SyncRecord.test(
            entityID: try TestIDs.entity(20),
            revision: 1,
            originDeviceID: device,
            taskID: task
        )
        _ = try await store.commitLocalRecord(record)
        await store.close()

        let otherDevice = try TestIDs.device(2)
        XCTAssertThrowsError(try database.makeStore(deviceID: otherDevice)) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .deviceIdentityMismatch(
                    expected: otherDevice.canonical,
                    found: device.canonical
                )
            )
        }

        let reopened = try database.makeStore(deviceID: device)
        let stored = try await reopened.storedRecord(kind: .task, entityID: record.entityID)
        XCTAssertEqual(stored?.record.payload, record.payload)
        await reopened.close()

        let closedStore = try database.makeStore(deviceID: device)
        await closedStore.close()
        await XCTAssertThrowsSyncError(.closed) {
            try await closedStore.latestChangeCursor()
        }
    }
}
