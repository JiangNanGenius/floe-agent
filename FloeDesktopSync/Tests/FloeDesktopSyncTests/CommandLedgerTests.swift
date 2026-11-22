import Foundation
import XCTest
@testable import FloeDesktopSync

final class CommandLedgerTests: XCTestCase {
    func testAcceptanceIsIdempotentAcrossRestart() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let commandID = try TestIDs.command(3)
        let clock = TestClock()

        let command = SyncCommand(
            commandID: commandID,
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("整理笔记")])
        )

        let firstStore = try database.makeStore(deviceID: device, clock: clock)
        let first = try await firstStore.accept(command)
        XCTAssertFalse(first.isDuplicate)
        XCTAssertEqual(first.receipt.state, .accepted)
        XCTAssertNil(first.receipt.result)
        _ = try await firstStore.markStarted(commandID, authenticatedDeviceID: device)
        let duplicateAfterStart = try await firstStore.accept(command)
        XCTAssertTrue(duplicateAfterStart.isDuplicate)
        XCTAssertEqual(duplicateAfterStart.receipt.state, .started)
        await firstStore.close()

        let reopened = try database.makeStore(deviceID: device, clock: clock)
        let second = try await reopened.accept(command)
        XCTAssertTrue(second.isDuplicate)
        XCTAssertEqual(second.receipt, duplicateAfterStart.receipt)
        XCTAssertEqual(second.receipt.state, .started)

        let stored = try await reopened.storedCommand(for: commandID)
        XCTAssertEqual(stored?.command, command)
        XCTAssertEqual(stored?.receipt, duplicateAfterStart.receipt)
        XCTAssertEqual(stored?.payloadDigest, try command.fingerprints().payload)

        let metadata = try await reopened.metadata()
        XCTAssertEqual(metadata.schemaVersion, 5)
        XCTAssertEqual(metadata.deviceID, device)
        XCTAssertEqual(metadata.commandCount, 1)
        XCTAssertEqual(metadata.recordCount, 0)
        XCTAssertEqual(metadata.journalMode, "wal")
        XCTAssertTrue(metadata.foreignKeysEnabled)
        XCTAssertGreaterThan(database.walFamilySize, 0)
        await reopened.close()
    }

    func testSameIdentityDifferentPayloadIsRejected() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let commandID = try TestIDs.command(3)
        let store = try database.makeStore(deviceID: device)

        let original = SyncCommand(
            commandID: commandID,
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("original")])
        )
        let accepted = try await store.accept(original)
        XCTAssertFalse(accepted.isDuplicate)

        let conflictingPayload = SyncCommand(
            commandID: commandID,
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("changed")])
        )
        await XCTAssertThrowsSyncError(.payloadConflict(commandID)) {
            try await store.accept(conflictingPayload)
        }

        let conflictingKind = SyncCommand(
            commandID: commandID,
            kind: .taskStop,
            taskID: task,
            payload: .object(["goal": .string("original")])
        )
        await XCTAssertThrowsSyncError(.payloadConflict(commandID)) {
            try await store.accept(conflictingKind)
        }

        let stored = try await store.storedCommand(for: commandID)
        XCTAssertEqual(stored?.receipt, accepted.receipt)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.commandCount, 1)
        await store.close()
    }

    func testWireKeyOrderIsTheSameIdempotentIntent() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let store = try database.makeStore(deviceID: device)

        let firstWire = """
        {"protocolMajor":1,"protocolMinor":0,
         "commandID":"00000000-0000-4000-8000-000000000001",
         "kind":"task.submit",
         "taskID":"00000000-0000-4000-8000-000000000002",
         "payload":{"goal":"same","mode":"chat"}}
        """
        let secondWire = """
        {
          "payload": {"mode": "chat", "goal": "same"},
          "taskID": "00000000-0000-4000-8000-000000000002",
          "kind": "task.submit",
          "commandID": "00000000-0000-4000-8000-000000000001",
          "protocolMinor": 0,
          "protocolMajor": 1
        }
        """
        let first = try await store.accept(try SyncCommand(wireJSON: firstWire))
        XCTAssertFalse(first.isDuplicate)
        let second = try await store.accept(try SyncCommand(wireJSON: secondWire))
        XCTAssertTrue(second.isDuplicate)
        XCTAssertEqual(second.receipt, first.receipt)
        await store.close()
    }

    func testExecutionEpochRejectsStaleWriterWithoutLosingOriginalReceipt() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let run = try TestIDs.run(3)
        let store = try database.makeStore(deviceID: device)

        _ = try await store.establishExecutionHead(
            runID: run,
            taskID: task,
            epoch: try TestIDs.epoch(1),
            ownerDeviceID: device
        )

        let epochOneCommand = SyncCommand(
            commandID: try TestIDs.command(10),
            kind: .runStop,
            taskID: task,
            runID: run,
            executionEpoch: try TestIDs.epoch(1),
            payload: .object(["reason": .string("user")])
        )
        let accepted = try await store.accept(epochOneCommand)
        XCTAssertFalse(accepted.isDuplicate)

        let futureEpochCommand = SyncCommand(
            commandID: try TestIDs.command(11),
            kind: .runStop,
            taskID: task,
            runID: run,
            executionEpoch: try TestIDs.epoch(2),
            payload: .object(["reason": .string("user")])
        )
        await XCTAssertThrowsSyncError(
            .executionEpochNotEstablished(run, try TestIDs.epoch(2))
        ) {
            try await store.accept(futureEpochCommand)
        }
        let futureReceipt = try await store.receipt(for: futureEpochCommand.commandID)
        XCTAssertNil(futureReceipt)

        _ = try await store.establishExecutionHead(
            runID: run,
            taskID: task,
            epoch: try TestIDs.epoch(3),
            ownerDeviceID: device
        )

        let staleCommand = SyncCommand(
            commandID: try TestIDs.command(12),
            kind: .runStop,
            taskID: task,
            runID: run,
            executionEpoch: try TestIDs.epoch(2),
            payload: .object(["reason": .string("user")])
        )
        await XCTAssertThrowsSyncError(
            .staleExecutionEpoch(
                run,
                try TestIDs.epoch(2),
                current: try TestIDs.epoch(3)
            )
        ) {
            try await store.accept(staleCommand)
        }
        let staleReceipt = try await store.receipt(for: staleCommand.commandID)
        XCTAssertNil(staleReceipt)

        // The already accepted old-epoch command can still be queried by its
        // original ID, but must not start under the new head.
        let replay = try await store.accept(epochOneCommand)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.receipt, accepted.receipt)
        await XCTAssertThrowsSyncError(
            .staleExecutionEpoch(run, try TestIDs.epoch(1), current: try TestIDs.epoch(3))
        ) {
            try await store.markStarted(
                epochOneCommand.commandID,
                authenticatedDeviceID: device
            )
        }
        let oldEpochReceipt = try await store.receipt(for: epochOneCommand.commandID)
        XCTAssertEqual(oldEpochReceipt?.state, .accepted)

        await XCTAssertThrowsSyncError(
            .executionEpochOwnerConflict(run, try TestIDs.epoch(3))
        ) {
            _ = try await store.establishExecutionHead(
                runID: run,
                taskID: task,
                epoch: try TestIDs.epoch(3),
                ownerDeviceID: try TestIDs.device(99)
            )
        }
        await XCTAssertThrowsSyncError(
            .staleExecutionEpoch(run, try TestIDs.epoch(2), current: try TestIDs.epoch(3))
        ) {
            _ = try await store.establishExecutionHead(
                runID: run,
                taskID: task,
                epoch: try TestIDs.epoch(2),
                ownerDeviceID: device
            )
        }

        let missingEpoch = SyncCommand(
            commandID: try TestIDs.command(13),
            kind: .runStart,
            taskID: task,
            runID: run,
            payload: .object([:])
        )
        await XCTAssertThrowsSyncError(.missingExecutionEpoch(.runStart)) {
            try await store.accept(missingEpoch)
        }
        await store.close()
    }

    func testInterruptedStartedCommandBecomesOutcomeUnknown() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let interruptedID = try TestIDs.command(20)
        let acceptedID = try TestIDs.command(21)
        let clock = TestClock()

        var store: SyncStore? = try database.makeStore(deviceID: device, clock: clock)
        let interrupted = SyncCommand(
            commandID: interruptedID,
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("long running")])
        )
        let accepted = SyncCommand(
            commandID: acceptedID,
            kind: .taskStop,
            taskID: task,
            payload: .object(["reason": .string("queued")])
        )
        _ = try await store!.accept(interrupted)
        _ = try await store!.accept(accepted)
        _ = try await store!.markStarted(interruptedID, authenticatedDeviceID: device)
        await store!.close()
        store = nil

        let reopened = try database.makeStore(deviceID: device, clock: clock)
        let recovered = try await reopened.recoverInterruptedCommands()
        XCTAssertEqual(recovered, [interruptedID])
        let unknown = try await reopened.receipt(for: interruptedID)
        XCTAssertEqual(unknown?.state, .outcomeUnknown)
        XCTAssertNil(unknown?.result)
        let acceptedReceipt = try await reopened.receipt(for: acceptedID)
        XCTAssertEqual(acceptedReceipt?.state, .accepted)
        let secondRecovery = try await reopened.recoverInterruptedCommands()
        XCTAssertEqual(secondRecovery, [])

        await XCTAssertThrowsSyncError(
            .invalidTransition(interruptedID, from: .outcomeUnknown, to: .started)
        ) {
            try await reopened.markStarted(
                interruptedID,
                authenticatedDeviceID: device
            )
        }

        let completed = try await reopened.complete(
            interruptedID,
            result: .object(["summary": .string("finished")])
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.result?["summary"]?.stringValue, "finished")
        await XCTAssertThrowsSyncError(
            .invalidTransition(interruptedID, from: .completed, to: .failed)
        ) {
            try await reopened.fail(interruptedID)
        }
        await reopened.close()

        let third = try database.makeStore(deviceID: device, clock: clock)
        let persisted = try await third.receipt(for: interruptedID)
        XCTAssertEqual(persisted?.state, .completed)
        XCTAssertEqual(persisted?.result?["summary"]?.stringValue, "finished")
        await third.close()
    }


    func testReplaySurvivesATighterPayloadLimitAfterReopen() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let commandID = try TestIDs.command(30)
        let clock = TestClock()
        let command = SyncCommand(
            commandID: commandID,
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("a payload larger than ten bytes")])
        )

        let wide = try database.makeStore(deviceID: device, clock: clock)
        let accepted = try await wide.accept(command)
        XCTAssertFalse(accepted.isDuplicate)
        await wide.close()

        let narrow = try database.makeStore(
            deviceID: device,
            clock: clock,
            configuration: SyncStoreConfiguration(maxPayloadBytes: 10)
        )
        let replay = try await narrow.accept(command)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.receipt, accepted.receipt)

        let tooLarge = SyncCommand(
            commandID: try TestIDs.command(31),
            kind: .taskSubmit,
            taskID: task,
            payload: .object(["goal": .string("a payload larger than ten bytes")])
        )
        await XCTAssertThrowsSyncError(.payloadTooLarge(limit: 10)) {
            try await narrow.accept(tooLarge)
        }
        let tooLargeReceipt = try await narrow.receipt(for: tooLarge.commandID)
        XCTAssertNil(tooLargeReceipt)
        await narrow.close()
    }
    func testLegacyExpectedRevisionWithoutTargetStillReplaysByOriginalReceipt() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let commandID = try TestIDs.command(40)
        let store = try database.makeStore(deviceID: device)
        let legacy = SyncCommand(
            commandID: commandID,
            kind: .taskStop,
            taskID: task,
            expectedRevision: try TestIDs.revision(1),
            payload: .object(["reason": .string("legacy")])
        )
        let fingerprints = try legacy.fingerprints()
        let raw = try database.rawConnection()
        let insert = try raw.prepare(
            """
            INSERT INTO commands (
                command_id, protocol_major, protocol_minor, kind, task_id,
                workspace_id, run_id, expected_revision, execution_epoch,
                target_entity_kind, target_entity_id, payload, payload_digest,
                command_digest, state, result, accepted_at, updated_at
            ) VALUES (?, 1, 0, ?, ?, NULL, NULL, 1, NULL, NULL, NULL, ?, ?, ?, 'accepted', NULL, 1, 1)
            """
        )
        try insert.bind(1, commandID.canonical)
        try insert.bind(2, CommandKind.taskStop.rawValue)
        try insert.bind(3, task.canonical)
        try insert.bind(4, legacy.payload.canonicalUTF8)
        try insert.bind(5, fingerprints.payload.description)
        try insert.bind(6, fingerprints.intent.description)
        _ = try insert.step()
        raw.close()

        let replay = try await store.accept(legacy)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.receipt.state, .accepted)
        XCTAssertEqual(replay.receipt.commandID, commandID)
        await store.close()
    }

}
