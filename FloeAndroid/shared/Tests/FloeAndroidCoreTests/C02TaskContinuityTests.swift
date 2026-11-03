// SPDX-License-Identifier: MPL-2.0
//
// C02 durable task-continuity tests. AUTHORED, NOT RUN by this source lane.
// They exercise the real SQLite pause CAS, the real recovery sidecar, the
// real user-question store/run event thread and deterministic fake run/target
// ports. No network, provider, device, Root, ADB, provider cloud or App UI.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class C02TaskContinuityStoreTests: XCTestCase {
    private func withDatabase(_ body: (DatabaseManager) async throws -> Void) async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        do {
            try await body(database)
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
    }

    private func createSchema(_ database: DatabaseManager) async throws {
        try await database.writer { db in
            for statement in C02TaskContinuitySchema.createStatements {
                try db.execute(sql: statement)
            }
        }
    }

    private func marker(
        taskID: UUID,
        runID: UUID,
        markerID: String = "marker-1",
        state: TaskContinuityPauseState = .awaitingStorageRecovery,
        updatedAt: Date = Date()
    ) -> TaskContinuityPauseMarker {
        TaskContinuityPauseMarker(
            markerID: markerID,
            taskID: taskID,
            runID: runID,
            rootEpoch: 7,
            rootFingerprint: String(repeating: "a", count: 64),
            reason: .volumeFull,
            state: state,
            durability: .taskDatabase,
            detectedAt: updatedAt,
            updatedAt: updatedAt,
            resumeAttempt: 0,
            targetRevision: 3,
            targetRootEpoch: 7,
            environmentID: "env-a",
            workspaceID: UUID(),
            shellRootHash: String(repeating: "b", count: 64),
            engineOwnerHash: String(repeating: "c", count: 64),
            runCheckpointed: true,
            unknownOutcomeCount: 2)
    }

    func testSchemaIsTypedUnavailableBeforeRegistration() async throws {
        try await withDatabase { database in
            // Deliberately missing table, rather than expecting production
            // migrate() to omit the now-registered v52 table.
            try await database.writer { db in
                try db.execute(sql: "DROP TABLE task_continuity_pauses")
            }
            let store = C02SQLiteTaskContinuityStore(database: database)
            do {
                _ = try await store.activePause(taskID: UUID())
                XCTFail("expected schemaUnavailable")
            } catch let error as C02TaskContinuityError {
                guard case .schemaUnavailable = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
        }
    }

    func testRecordIsIdempotentAndResumeClaimIsExactlyOnce() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let store = C02SQLiteTaskContinuityStore(database: database)
            let taskID = UUID()
            let runID = UUID()
            let first = marker(taskID: taskID, runID: runID)
            let recorded = try await store.record(first)
            XCTAssertEqual(recorded.markerID, first.markerID)
            var refreshed = first
            refreshed.reason = .volumeReadOnly
            refreshed.updatedAt = Date()
            let second = try await store.record(refreshed)
            XCTAssertEqual(second.markerID, first.markerID)
            XCTAssertEqual(second.reason, .volumeReadOnly)

            let claimed = try await store.claimResume(
                markerID: first.markerID,
                taskID: taskID,
                runID: runID,
                expectedRootEpoch: 7,
                now: Date())
            XCTAssertEqual(claimed?.state, .resumeInProgress)
            XCTAssertEqual(claimed?.resumeAttempt, 1)
            let duplicate = try await store.claimResume(
                markerID: first.markerID,
                taskID: taskID,
                runID: runID,
                expectedRootEpoch: 7,
                now: Date())
            XCTAssertNil(duplicate)

            let settled = try await store.settleResume(
                markerID: first.markerID,
                expectedRootEpoch: 7,
                state: .resumed,
                runCheckpointed: true,
                now: Date())
            XCTAssertEqual(settled?.state, .resumed)
            let active = try await store.activePause(taskID: taskID)
            XCTAssertNil(active)
            let latest = try await store.latestPause(taskID: taskID)
            XCTAssertEqual(latest?.state, .resumed)
            let cleared = try await store.clear(
                markerID: first.markerID, taskID: taskID,
                runID: runID, rootEpoch: 7)
            XCTAssertTrue(cleared)
            let gone = try await store.marker(id: first.markerID)
            XCTAssertNil(gone)
        }
    }

    func testWrongRootOrRunCannotClaimOrClear() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let store = C02SQLiteTaskContinuityStore(database: database)
            let taskID = UUID()
            let runID = UUID()
            _ = try await store.record(marker(taskID: taskID, runID: runID))
            let wrongRoot = try await store.claimResume(
                markerID: "marker-1", taskID: taskID, runID: runID,
                expectedRootEpoch: 8, now: Date())
            XCTAssertNil(wrongRoot)
            let wrongRun = try await store.claimResume(
                markerID: "marker-1", taskID: taskID, runID: UUID(),
                expectedRootEpoch: 7, now: Date())
            XCTAssertNil(wrongRun)
            let cleared = try await store.clear(
                markerID: "marker-1", taskID: taskID,
                runID: UUID(), rootEpoch: 7)
            XCTAssertFalse(cleared)
        }
    }

    func testRecoverySidecarIsBoundedAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-continuity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = TaskContinuityFileRecoveryMetadata(directory: directory)
        let taskID = UUID()
        let runID = UUID()
        let value = marker(taskID: taskID, runID: runID)
        try await recovery.save(value)
        let loaded = try await recovery.load(taskID: taskID)
        XCTAssertEqual(loaded?.markerID, value.markerID)
        XCTAssertEqual(loaded?.durability, .recoveryMetadata)
        let byID = try await recovery.load(markerID: value.markerID)
        XCTAssertEqual(byID?.runID, runID)
        let cleared = try await recovery.clear(
            markerID: value.markerID, taskID: taskID,
            runID: runID, rootEpoch: 7)
        XCTAssertTrue(cleared)
        let empty = try await recovery.load(taskID: taskID)
        XCTAssertNil(empty)
    }

    func testStaleSidecarCannotResurrectAResumedDatabaseRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-continuity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withDatabase { database in
            try await createSchema(database)
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityFileRecoveryMetadata(directory: directory)
            let taskID = UUID()
            let runID = UUID()
            let value = marker(taskID: taskID, runID: runID)
            _ = try await store.record(value)
            try await recovery.save(value)
            _ = try await store.claimResume(
                markerID: value.markerID, taskID: taskID, runID: runID,
                expectedRootEpoch: 7, now: Date())
            _ = try await store.settleResume(
                markerID: value.markerID, expectedRootEpoch: 7,
                state: .resumed, runCheckpointed: true, now: Date())

            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "checkpointed",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: FakeStorage(.ready),
                store: store,
                recovery: recovery,
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            let snapshot = try await coordinator.snapshot(taskID: taskID, runID: runID)
            XCTAssertNil(snapshot.pause)
            let stale = try await recovery.load(taskID: taskID)
            XCTAssertNil(stale)
        }
    }

    // MARK: - Coordinator factory

    private final class FakeStorage: TaskContinuityStorageProbing, @unchecked Sendable {
        var status: TaskContinuityStorageStatus
        init(_ condition: TaskContinuityStorageCondition, bytes: Int64? = nil) {
            status = TaskContinuityStorageStatus(
                condition: condition, checkedAt: Date(), availableBytes: bytes)
        }
        func probe() async -> TaskContinuityStorageStatus { status }
    }

    private struct FakeTasks: TaskContinuityTaskReading {
        let map: [UUID: TaskContinuityTaskDescriptor]
        func task(taskID: UUID) async throws -> TaskContinuityTaskDescriptor? {
            map[taskID]
        }
    }

    private struct ThrowingTasks: TaskContinuityTaskReading {
        func task(taskID: UUID) async throws -> TaskContinuityTaskDescriptor? {
            throw C02TaskContinuityError.storeUnavailable("taskRead")
        }
    }

    private struct FakeTargets: TaskContinuityTargetReading {
        let snapshot: TaskContinuityTargetSnapshot
        func target(taskID: UUID, runID: UUID) async throws
            -> TaskContinuityTargetSnapshot { snapshot }
    }

    private struct FakeWaits: TaskContinuityWaitProviding {
        var read = TaskContinuityWaitRead(waits: [])
        func pendingWaits(taskID: UUID, runID: UUID?) async throws
            -> TaskContinuityWaitRead { read }
    }

    final class FakeRuns: TaskContinuityRunCoordinating, @unchecked Sendable {
        var descriptor: TaskContinuityRunDescriptor
        var pauseResult = true
        var resumeError: Error?
        private(set) var pauseCalls = 0
        private(set) var resumeCalls = 0

        init(descriptor: TaskContinuityRunDescriptor) {
            self.descriptor = descriptor
        }

        func run(taskID: UUID, runID: UUID) async throws -> TaskContinuityRunDescriptor {
            guard descriptor.taskID == taskID, descriptor.runID == runID else {
                throw C02TaskContinuityError.runNotFound
            }
            return descriptor
        }

        func latestRun(taskID: UUID) async throws -> TaskContinuityRunDescriptor? {
            descriptor.taskID == taskID ? descriptor : nil
        }

        func requestPause(taskID: UUID, runID: UUID) async -> Bool {
            pauseCalls += 1
            return pauseResult
        }

        func resume(
            taskID: UUID,
            runID: UUID,
            expectedState: String,
            markerID: String
        ) async throws -> TaskContinuityRunResumeResult {
            resumeCalls += 1
            if let resumeError { throw resumeError }
            return TaskContinuityRunResumeResult(detail: ["resumed": "true"])
        }
    }

    private func makeCoordinator(
        storage: FakeStorage,
        store: any TaskContinuityPauseStoring,
        recovery: any TaskContinuityRecoveryMetadataStoring,
        tasks: [UUID: TaskContinuityTaskDescriptor],
        runs: FakeRuns?
    ) -> TaskContinuityCoordinator {
        let taskID = tasks.keys.first ?? UUID()
        let descriptor = TaskContinuityRunDescriptor(
            taskID: taskID,
            runID: runs?.descriptor.runID ?? UUID(),
            state: "checkpointed",
            conversationMode: "chat",
            modelID: UUID(),
            providerID: UUID())
        let runCoordinator = runs ?? FakeRuns(descriptor: descriptor)
        return TaskContinuityCoordinator(
            epoch: 7,
            rootFingerprint: String(repeating: "a", count: 64),
            taskReader: FakeTasks(map: tasks),
            runCoordinator: runCoordinator,
            targetReader: FakeTargets(snapshot: TaskContinuityTargetSnapshot(
                targetRevision: 3,
                targetRootEpoch: 7,
                environmentID: "env-a",
                workspaceID: UUID(),
                shellRootHash: String(repeating: "b", count: 64),
                engineOwnerHash: String(repeating: "c", count: 64),
                unknownOutcomeCount: 2)),
            waitProvider: FakeWaits(),
            store: store,
            recovery: recovery,
            storage: storage)
    }

    func testPauseRecordsMarkerAndAdmissionBlocksLaunch() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityMemoryRecoveryMetadata()
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "checkpointed",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: FakeStorage(.volumeFull),
                store: store,
                recovery: recovery,
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            let receipt = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .volumeFull)
            XCTAssertEqual(receipt.marker.reason, .volumeFull)
            XCTAssertTrue(receipt.marker.explicitResumeOnly)
            XCTAssertEqual(runs.pauseCalls, 1)
            let launch = await coordinator.admissionDecision(
                taskID: taskID, runID: nil, operation: .launch)
            guard case .paused(let markerID, let reason) = launch else {
                return XCTFail("expected paused admission")
            }
            XCTAssertEqual(markerID, receipt.marker.markerID)
            XCTAssertEqual(reason, .volumeFull)
        }
    }

    func testResumeRequiresExplicitActionReadyStorageAndSameTarget() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityMemoryRecoveryMetadata()
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "checkpointed",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: FakeStorage(.ready),
                store: store,
                recovery: recovery,
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            let receipt = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .volumeReadOnly)
            let base = TaskContinuityResumeRequest(
                taskID: taskID,
                runID: runID,
                markerID: receipt.marker.markerID,
                expectedRootEpoch: 7,
                expectedTargetRevision: 3,
                explicitUserAction: true)

            var outcome = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: base.taskID, runID: base.runID,
                    markerID: base.markerID, expectedRootEpoch: 7,
                    expectedTargetRevision: 3, explicitUserAction: false))
            guard case .refused(.explicitActionRequired) = outcome else {
                return XCTFail("expected explicitActionRequired")
            }

            outcome = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: taskID, runID: runID,
                    markerID: receipt.marker.markerID,
                    expectedRootEpoch: 8,
                    expectedTargetRevision: 3,
                    explicitUserAction: true))
            guard case .refused(.rootEpochChanged) = outcome else {
                return XCTFail("expected rootEpochChanged")
            }

            outcome = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: taskID, runID: runID,
                    markerID: receipt.marker.markerID,
                    expectedRootEpoch: 7,
                    expectedTargetRevision: 99,
                    explicitUserAction: true))
            guard case .refused(.targetChanged) = outcome else {
                return XCTFail("expected targetChanged")
            }
            XCTAssertEqual(runs.resumeCalls, 0)

            outcome = try await coordinator.resume(base)
            guard case .accepted(let result, _) = outcome else {
                return XCTFail("expected accepted")
            }
            XCTAssertEqual(result.detail["resumed"], "true")
            XCTAssertEqual(runs.resumeCalls, 1)

            outcome = try await coordinator.resume(base)
            guard case .refused = outcome else {
                return XCTFail("a resumed marker cannot be resumed twice")
            }
            XCTAssertEqual(runs.resumeCalls, 1)
        }
    }

    func testStorageStillUnavailableRefusesBeforeRunDispatch() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityMemoryRecoveryMetadata()
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "checkpointed",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: FakeStorage(.volumeFull),
                store: store,
                recovery: recovery,
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            _ = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .volumeFull)
            // Same coordinator keeps the non-ready probe: resume refuses and
            // no model/provider dispatch is attempted.
            let stored = try await coordinator.snapshot(
                taskID: taskID, runID: runID).pause
            let outcome = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: taskID, runID: runID,
                    markerID: stored!.markerID,
                    expectedRootEpoch: 7,
                    expectedTargetRevision: 3,
                    explicitUserAction: true))
            guard case .refused(.storageStillUnavailable(.volumeFull)) = outcome else {
                return XCTFail("expected storageStillUnavailable")
            }
            XCTAssertEqual(runs.resumeCalls, 0)
        }
    }

    func testDatabaseUnavailablePauseUsesRecoveryMetadataWithoutTaskRead() async throws {
        try await withDatabase { database in
            // No continuity table and no task row: a real task read would
            // throw. The recovery-only path must still record and expose the
            // nonsecret marker while storage is unavailable.
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityMemoryRecoveryMetadata()
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "executingTool",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = TaskContinuityCoordinator(
                epoch: 7,
                rootFingerprint: String(repeating: "a", count: 64),
                taskReader: ThrowingTasks(),
                runCoordinator: runs,
                targetReader: FakeTargets(snapshot: TaskContinuityTargetSnapshot()),
                waitProvider: FakeWaits(),
                store: store,
                recovery: recovery,
                storage: FakeStorage(.databaseUnavailable))
            let receipt = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .databaseUnavailable)
            XCTAssertEqual(receipt.marker.reason, .databaseUnavailable)
            XCTAssertEqual(receipt.marker.durability, .memoryOnly)
            let snapshot = try await coordinator.snapshot(
                taskID: taskID, runID: runID)
            XCTAssertEqual(snapshot.pause?.reason, .databaseUnavailable)
            XCTAssertTrue(snapshot.waits.isEmpty)
            let refused = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: taskID, runID: runID,
                    markerID: receipt.marker.markerID,
                    expectedRootEpoch: 7,
                    expectedTargetRevision: nil,
                    explicitUserAction: true))
            guard case .refused(.storageStillUnavailable(.databaseUnavailable)) = refused else {
                return XCTFail("expected storageStillUnavailable before task read")
            }
        }
    }

    func testRecoveryPauseEnrichesFromRunPinBeforeResume() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let recovery = TaskContinuityMemoryRecoveryMetadata()
            let storage = FakeStorage(.databaseUnavailable)
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "checkpointed",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: storage,
                store: store,
                recovery: recovery,
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            let receipt = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .databaseUnavailable)
            XCTAssertNil(receipt.marker.targetRevision)
            storage.status = TaskContinuityStorageStatus(
                condition: .ready, checkedAt: Date())
            let outcome = try await coordinator.resume(
                TaskContinuityResumeRequest(
                    taskID: taskID, runID: runID,
                    markerID: receipt.marker.markerID,
                    expectedRootEpoch: 7,
                    expectedTargetRevision: nil,
                    explicitUserAction: true))
            guard case .accepted = outcome else {
                return XCTFail("expected accepted after pin enrichment")
            }
            XCTAssertEqual(runs.resumeCalls, 1)
            let latest = try await store.latestPause(taskID: taskID)
            XCTAssertEqual(latest?.state, .resumed)
            XCTAssertEqual(latest?.targetRevision, 3)
        }
    }

    func testTemporaryTaskNeverPersistsAPause() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let coordinator = makeCoordinator(
                storage: FakeStorage(.volumeFull),
                store: store,
                recovery: TaskContinuityMemoryRecoveryMetadata(),
                tasks: [taskID: .init(taskID: taskID, purpose: "temporary")],
                runs: FakeRuns(descriptor: .init(
                    taskID: taskID, runID: UUID(), state: "checkpointed",
                    conversationMode: "chat", modelID: nil, providerID: nil)))
            do {
                _ = try await coordinator.pause(
                    taskID: taskID, runID: UUID(), reason: .volumeFull)
                XCTFail("expected temporaryTaskRefused")
            } catch let error as C02TaskContinuityError {
                guard case .temporaryTaskRefused = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
            let active = try await store.activePause(taskID: taskID)
            XCTAssertNil(active)
        }
    }

    func testStaleResumeReconcilesInsteadOfDuplicating() async throws {
        try await withDatabase { database in
            try await createSchema(database)
            let taskID = UUID()
            let runID = UUID()
            let store = C02SQLiteTaskContinuityStore(database: database)
            let runs = FakeRuns(descriptor: .init(
                taskID: taskID, runID: runID, state: "executingTool",
                conversationMode: "chat", modelID: nil, providerID: nil))
            let coordinator = makeCoordinator(
                storage: FakeStorage(.ready),
                store: store,
                recovery: TaskContinuityMemoryRecoveryMetadata(),
                tasks: [taskID: .init(taskID: taskID, purpose: "ordinary")],
                runs: runs)
            _ = try await coordinator.pause(
                taskID: taskID, runID: runID, reason: .databaseUnavailable)
            let record = try await store.activePause(taskID: taskID)
            let stale = Date().addingTimeInterval(
                -C02TaskContinuityWire.resumingStaleSeconds - 10)
            _ = try await store.claimResume(
                markerID: record!.markerID, taskID: taskID, runID: runID,
                expectedRootEpoch: 7, now: stale)
            let snapshot = try await coordinator.snapshot(taskID: taskID, runID: runID)
            // The live run proves the resume reached execution; the marker is
            // settled as resumed and never replayed.
            XCTAssertNil(snapshot.pause)
            XCTAssertEqual(runs.resumeCalls, 0)
        }
    }
}

final class C02TaskContinuityWaitTests: XCTestCase {
    private struct Fixture {
        let database: DatabaseManager
        let taskID: UUID
        let runID: UUID
        let runStore: SQLiteRunStore
        let questionStore: UserQuestionStore
    }

    private func makeFixture(
        state: String = "executingTool"
    ) async throws -> Fixture {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let taskID = UUID()
        let runID = UUID()
        let conversations = SQLiteConversationStore(database: database)
        try await conversations.saveConversation(ConversationRecord(
            id: taskID,
            title: "Continuity",
            createdAt: Date(),
            updatedAt: Date(),
            purpose: .ordinary))
        let runs = SQLiteRunStore(database: database)
        try await runs.saveRun(RunRecord(
            id: runID,
            conversationID: taskID,
            state: state,
            goal: "test",
            startedAt: Date(),
            conversationMode: "chat"))
        return Fixture(
            database: database, taskID: taskID, runID: runID,
            runStore: runs, questionStore: UserQuestionStore(database: database))
    }

    private func registerQuestion(
        _ fixture: Fixture,
        toolCallID: String = "call-1",
        requestSuffix: String = "a",
        createdAt: Date = Date()
    ) async throws -> UserQuestionWaitingSnapshot {
        let requestID = "uq_" + String(repeating: requestSuffix, count: 32)
        let request = try UserQuestionRequest(
            waitPolicy: .required,
            questions: [UserQuestionDraft(
                id: "q1",
                question: "Which file should I use?",
                options: [
                    UserQuestionOption(id: "a", label: "A"),
                    UserQuestionOption(id: "b", label: "B"),
                ],
                selection: .single,
                allowsFreeText: false)])
        let questions = try request.makeQuestions(
            requestID: requestID,
            conversationID: fixture.taskID,
            runID: fixture.runID,
            toolCallID: toolCallID,
            createdAt: createdAt)
        let registration = UserQuestionRegistration(
            requestID: requestID,
            requestDigest: String(repeating: "d", count: 64),
            conversationID: fixture.taskID,
            runID: fixture.runID,
            toolCallID: toolCallID,
            waitPolicy: .required,
            questions: questions,
            createdAt: createdAt,
            isEphemeral: false)
        return try await fixture.questionStore.register(registration)
    }

    private func provider(
        _ fixture: Fixture,
        liveApproval: TaskContinuityLiveApproval? = nil
    ) -> C02SQLiteTaskContinuityWaitProvider {
        C02SQLiteTaskContinuityWaitProvider(
            database: fixture.database,
            epoch: 7,
            rootFingerprint: String(repeating: "a", count: 64),
            liveApproval: { _, _ in liveApproval })
    }

    func testPendingQuestionSurvivesColdReadAndIsNeverMutated() async throws {
        let fixture = try await makeFixture()
        _ = try await registerQuestion(fixture)
        let before = try await fixture.questionStore.snapshots(
            conversationID: fixture.taskID, includeSettled: false)
        let read = try await provider(fixture).pendingWaits(
            taskID: fixture.taskID, runID: fixture.runID)
        let after = try await fixture.questionStore.snapshots(
            conversationID: fixture.taskID, includeSettled: false)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.state, .awaitingAnswer)
        XCTAssertEqual(read.waits.count, 1)
        let wait = read.waits[0]
        XCTAssertEqual(wait.identity.kind, .question)
        XCTAssertEqual(wait.identity.itemID, before[0].questions[0].questionID)
        XCTAssertEqual(wait.identity.toolCallID, "call-1")
        XCTAssertEqual(wait.identity.rootEpoch, 7)
        XCTAssertTrue(wait.requiresResume)
        XCTAssertFalse(wait.answerableNow)
        XCTAssertFalse(wait.requestDigest?.isEmpty ?? true)
        XCTAssertFalse(wait.answerNonce?.isEmpty ?? true)
        XCTAssertEqual(wait.identity.waitID, read.waits[0].identity.waitID)
    }

    func testSettledQuestionDisappearsAndDuplicateAnswerIsRejected() async throws {
        let fixture = try await makeFixture()
        let snapshot = try await registerQuestion(fixture)
        let question = snapshot.questions[0]
        let target = UserQuestionAnswerTarget(
            requestID: snapshot.requestID,
            questionID: question.questionID,
            conversationID: fixture.taskID,
            runID: fixture.runID,
            expectedRevision: question.revision)
        let answer = UserQuestionAnswer(selectedOptionIDs: ["a"])
        let first = try await fixture.questionStore.submitHumanAnswer(
            target: target, answer: answer, now: Date())
        XCTAssertTrue(first.accepted)
        let second = try await fixture.questionStore.submitHumanAnswer(
            target: target, answer: answer, now: Date())
        XCTAssertFalse(second.accepted)
        XCTAssertTrue(second.alreadySettled)
        let read = try await provider(fixture).pendingWaits(
            taskID: fixture.taskID, runID: fixture.runID)
        XCTAssertTrue(read.waits.isEmpty)
    }

    func testDurableApprovalBecomesResumeRequiredAndLiveOwnerIsCanonical() async throws {
        let fixture = try await makeFixture(state: "waitingApproval")
        try await fixture.runStore.appendEvent(
            runID: fixture.runID,
            kind: .approval,
            payloadJSON: """
                {"tool":"exec.shell","callID":"call-1","scope":"local","reason":"needs approval"}
                """)
        let durable = try await provider(fixture).pendingWaits(
            taskID: fixture.taskID, runID: fixture.runID)
        XCTAssertEqual(durable.waits.count, 1)
        XCTAssertEqual(durable.waits[0].identity.kind, .approval)
        XCTAssertEqual(durable.waits[0].identity.itemID, "call-1")
        XCTAssertTrue(durable.waits[0].requiresResume)
        XCTAssertFalse(durable.waits[0].answerableNow)

        let live = TaskContinuityLiveApproval(
            callID: "call-1", tool: "exec.shell",
            reason: "needs approval", requestedAt: Date())
        let liveRead = try await provider(fixture, liveApproval: live).pendingWaits(
            taskID: fixture.taskID, runID: fixture.runID)
        XCTAssertEqual(liveRead.waits.count, 1)
        XCTAssertTrue(liveRead.waits[0].answerableNow)
        XCTAssertFalse(liveRead.waits[0].requiresResume)
        XCTAssertNotNil(liveRead.waits[0].approvalVersion)

        try await fixture.runStore.appendEvent(
            runID: fixture.runID,
            kind: .toolResult,
            payloadJSON: #"{"callID":"call-1","status":"ok"}"#)
        let after = try await provider(fixture).pendingWaits(
            taskID: fixture.taskID, runID: fixture.runID)
        XCTAssertTrue(after.waits.isEmpty)
    }

    func testWaitIdentityIsStablePerGenerationAndDisjointAcrossRuns() async throws {
        let fixture = try await makeFixture()
        let snapshot = try await registerQuestion(fixture)
        let question = snapshot.questions[0]
        func identity(
            runID: UUID = fixture.runID,
            rootEpoch: UInt64 = 7,
            itemID: String? = nil
        ) -> TaskContinuityWaitIdentity {
            TaskContinuityWaitIdentity(
                kind: .question,
                rootEpoch: rootEpoch,
                rootFingerprint: String(repeating: "a", count: 64),
                taskID: fixture.taskID,
                runID: runID,
                toolCallID: "call-1",
                requestID: snapshot.requestID,
                itemID: itemID ?? question.questionID,
                revision: 1)
        }
        XCTAssertEqual(identity().waitID, identity().waitID)
        XCTAssertNotEqual(identity().waitID, identity(runID: UUID()).waitID)
        XCTAssertNotEqual(identity().waitID, identity(rootEpoch: 8).waitID)
        XCTAssertNotEqual(
            identity().waitID,
            TaskContinuityWaitIdentity(
                kind: .approval,
                rootEpoch: 7,
                rootFingerprint: String(repeating: "a", count: 64),
                taskID: fixture.taskID,
                runID: fixture.runID,
                toolCallID: "call-1",
                requestID: "call-1",
                itemID: "call-1",
                revision: 1).waitID)
    }
}
