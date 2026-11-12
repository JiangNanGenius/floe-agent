// FloePersistenceTests — complete environment-reference projection.
//
// These tests pin the persistence half of the legacy-recovery maintenance
// authority:
//  * every task pin (hidden/archived included), every pinned run (checkpointed
//    and failed included) and every unpinned resumable run is represented;
//  * >1000 active jobs are returned in full (no activeJobs(limit:) truncation)
//    and managed services in their running/stopping state are never filtered;
//  * a job with no environment falls back to its run pin and is explicitly
//    UNKNOWN when neither resolves;
//  * both ends of an incomplete migration are retained, including failed and
//    preparation-outcome-unknown rows;
//  * unreadable bodies make the projection incomplete with fixed blocker codes
//    instead of returning an empty/clean set;
//  * retained references never refuse byte-preserving maintenance, while
//    active/unknown/unattributed references do.

import Foundation
import GRDB
import FloeCore
import FloeModels
import Testing
@testable import FloePersistence

@Suite("Environment reference projection")
struct EnvironmentReferenceProjectionTests: Sendable {
    private static let baseDate = Date(timeIntervalSince1970: 1_761_400_000)

    @Test("all reference classes are projected from real tables")
    func allReferenceClasses() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let taskBinding = makeBinding(conversationID, env: "env-task", generation: 2)
        try await insertBinding(database, taskBinding)

        let activeRun = UUID(), checkpointedRun = UUID(), failedRun = UUID()
        let unpinnedRun = UUID(), completedRun = UUID(), completedPinnedRun = UUID()
        try await insertRun(database, id: activeRun, conversationID: conversationID,
                            state: "running", binding: makeBinding(conversationID, env: "env-run-active", generation: 3))
        try await insertRun(database, id: checkpointedRun, conversationID: conversationID,
                            state: "checkpointed", binding: makeBinding(conversationID, env: "env-run-checkpoint", generation: 4))
        try await insertRun(database, id: failedRun, conversationID: conversationID,
                            state: "failed", binding: makeBinding(conversationID, env: "env-run-failed", generation: 5))
        try await insertRun(database, id: unpinnedRun, conversationID: conversationID,
                            state: "paused", binding: nil)
        try await insertRun(database, id: completedRun, conversationID: conversationID,
                            state: "completed", binding: nil)
        try await insertRun(database, id: completedPinnedRun, conversationID: conversationID,
                            state: "completed", binding: makeBinding(conversationID, env: "env-run-completed", generation: 6))

        let explicitJob = UUID(), fallbackJob = UUID(), terminalJob = UUID()
        let jobRun = UUID()
        try await insertRun(database, id: jobRun, conversationID: conversationID,
                            state: "running", binding: makeBinding(conversationID, env: "env-job", generation: 8))
        try await insertJob(database, id: explicitJob, conversationID: conversationID,
                            runID: jobRun, state: "running", environmentID: "env-job")
        try await insertJob(database, id: fallbackJob, conversationID: conversationID,
                            runID: activeRun, state: "queued", environmentID: nil)
        try await insertJob(database, id: terminalJob, conversationID: conversationID,
                            runID: completedRun, state: "completed", environmentID: "env-terminal")

        let migrationID = UUID()
        let migration = TaskEnvironmentMigration(
            id: migrationID,
            source: makeBinding(conversationID, env: "env-src", generation: 7),
            target: TaskExecutionTarget(environmentID: "env-dst", backend: .linuxVM,
                                        operatingSystem: "linux", architecture: "arm64",
                                        runtimeGeneration: "boot-dst")
        )
        try await insertMigration(database, migration)

        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.isComplete)
        #expect(projection.blockers.isEmpty)
        #expect(projection.fingerprint.count == 64)

        let taskPins = projection.references.filter { $0.source == .taskBinding }
        #expect(taskPins.count == 1)
        #expect(taskPins.first?.environmentID == "env-task")
        #expect(taskPins.first?.classification == .retained)

        let activeRunRef = projection.references.first { $0.ownerID == activeRun && $0.source == .runBinding }
        #expect(activeRunRef?.environmentID == "env-run-active")
        #expect(activeRunRef?.classification == .active)
        let checkpointed = projection.references.first { $0.ownerID == checkpointedRun }
        #expect(checkpointed?.classification == .retained)
        let failed = projection.references.first { $0.ownerID == failedRun }
        #expect(failed?.classification == .retained)
        let completedPinned = projection.references.first { $0.ownerID == completedPinnedRun }
        #expect(completedPinned?.environmentID == "env-run-completed")
        #expect(completedPinned?.classification == .retained)
        let unpinned = projection.references.first { $0.ownerID == unpinnedRun }
        #expect(unpinned?.classification == .unknown)
        #expect(unpinned?.environmentID == nil)
        #expect(!projection.references.contains { $0.ownerID == completedRun })

        let explicit = projection.references.first { $0.ownerID == explicitJob }
        #expect(explicit?.environmentID == "env-job")
        #expect(explicit?.classification == .active)
        let fallback = projection.references.first { $0.ownerID == fallbackJob }
        #expect(fallback?.environmentID == "env-run-active")
        #expect(fallback?.classification == .active)
        #expect(!projection.references.contains { $0.ownerID == terminalJob })

        let sources = projection.references.filter { $0.ownerID == migrationID }
        #expect(Set(sources.map(\.source)) == [.migrationSource, .migrationTarget])
        #expect(Set(sources.compactMap(\.environmentID)) == ["env-src", "env-dst"])
        #expect(sources.allSatisfy { $0.classification == .active })

        // Retained references do not refuse byte-preserving maintenance.
        #expect(projection.maintenanceVerdict(environmentID: "env-run-checkpoint") == .clear)
        #expect(projection.maintenanceVerdict(environmentID: "env-run-failed") == .clear)
        #expect(projection.maintenanceVerdict(environmentID: "env-run-completed") == .clear)
        // Active run and its fallback job refuse.
        if case .busy(let reasons) = projection.maintenanceVerdict(environmentID: "env-run-active") {
            #expect(!reasons.isEmpty)
        } else {
            Issue.record("an active run/job must refuse maintenance")
        }
        // Migration both ends refuse.
        if case .busy = projection.maintenanceVerdict(environmentID: "env-src") {} else {
            Issue.record("the migration source must refuse maintenance")
        }
        if case .busy = projection.maintenanceVerdict(environmentID: "env-dst") {} else {
            Issue.record("the migration target must refuse maintenance")
        }
        // A retained task pin, plus a non-live resumable unpinned run, is not
        // a live owner of any target: byte-preserving maintenance is clear.
        #expect(projection.maintenanceVerdict(environmentID: "env-task") == .clear)
    }

    @Test("more than one thousand active jobs remain complete and untruncated")
    func moreThanOneThousandJobs() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let runID = UUID()
        // Terminal, unpinned run: the job rows carry their own environment, so
        // the projection's job set is exactly the 1050 active jobs.
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "completed", binding: nil)
        let count = 1_050
        try await database.writer { db in
            for index in 0..<count {
                try Self.insertJobSQL(
                    db, id: UUID(), conversationID: conversationID, runID: runID,
                    state: index % 2 == 0 ? "running" : "queued",
                    environmentID: "env-many", targetTool: index % 3 == 0 ? "exec.localService" : "exec.shell"
                )
            }
        }
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.isComplete)
        let jobs = projection.references.filter { $0.source == .backgroundJob }
        #expect(jobs.count == count)
        #expect(Set(jobs.map(\.classification)) == [.active])
        if case .busy(let reasons) = projection.maintenanceVerdict(environmentID: "env-many") {
            #expect(reasons.count == count)
        } else {
            Issue.record("1050 active jobs must all refuse maintenance")
        }
    }

    @Test("checkpointed/failed runs and failed/unknown migrations retain both ends")
    func recoverableAndFailedRowsRetain() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertRun(database, id: UUID(), conversationID: conversationID,
                            state: "checkpointed", binding: makeBinding(conversationID, env: "env-check", generation: 2))
        try await insertRun(database, id: UUID(), conversationID: conversationID,
                            state: "failed", binding: makeBinding(conversationID, env: "env-failed", generation: 3))
        var migration = TaskEnvironmentMigration(
            source: makeBinding(conversationID, env: "env-source", generation: 4),
            target: TaskExecutionTarget(environmentID: "env-target", backend: .linuxVM,
                                        operatingSystem: "linux", architecture: "arm64")
        )
        migration.phase = .failed
        migration.preparationOutcomeUnknown = true
        migration.preparationOperationIDs = [UUID()]
        migration.revision = 5
        try await insertMigration(database, migration)

        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(!projection.isComplete)
        #expect(projection.blockers.contains("migration_preparation_outcome_unknown"))
        #expect(projection.blockers.contains("migration_preparation_operation_open"))
        #expect(projection.references.contains { $0.environmentID == "env-check" && $0.classification == .retained })
        #expect(projection.references.contains { $0.environmentID == "env-failed" && $0.classification == .retained })
        let migrationRefs = projection.references.filter { $0.ownerID == migration.id }
        #expect(Set(migrationRefs.compactMap(\.environmentID)) == ["env-source", "env-target"])
        #expect(migrationRefs.allSatisfy { $0.classification == .active })
        if case .incomplete(let blockers) = projection.maintenanceVerdict(environmentID: "env-source") {
            #expect(!blockers.isEmpty)
        } else {
            Issue.record("an incomplete projection must refuse")
        }
    }

    @Test("unreadable bodies are incomplete, never an empty clean projection")
    func unreadableBodies() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO task_execution_bindings(conversation_id,generation,body_json) VALUES(?,?,?)",
                           arguments: [conversationID.uuidString, 1, "not json"])
            try db.execute(sql: """
                INSERT INTO runs(id,conversation_id,state,goal,started_at,ended_at,execution_binding_json)
                VALUES(?,?,?,?,?,NULL,?)
                """, arguments: [UUID().uuidString, conversationID.uuidString, "running", "x",
                                  Self.iso(Self.baseDate), "also not json"])
            try db.execute(sql: """
                INSERT INTO task_environment_migrations(id,conversation_id,phase,revision,body_json,updated_at)
                VALUES(?,?,?,?,?,?)
                """, arguments: [UUID().uuidString, conversationID.uuidString, "preparing", 1,
                                  "broken migration", Self.iso(Self.baseDate)])
        }
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(!projection.isComplete)
        #expect(projection.blockers.contains("task_binding_unreadable"))
        #expect(projection.blockers.contains("run_binding_unreadable"))
        #expect(projection.blockers.contains("migration_unreadable"))
        #expect(projection.references.contains { $0.classification == .unknown && $0.environmentID == nil })
        if case .incomplete = projection.maintenanceVerdict(environmentID: "anything") {} else {
            Issue.record("unreadable bodies must make the projection incomplete")
        }
    }

    @Test("archived conversations are not filtered out")
    func archivedConversations() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID, archived: true)
        try await insertBinding(database, makeBinding(conversationID, env: "env-archived", generation: 1))
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.isComplete)
        #expect(projection.references.contains { $0.environmentID == "env-archived" })
    }

    @Test("a service in its running stopping state is included unfiltered")
    func stoppingServiceIncluded() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID(), runID = UUID(), jobID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "running", binding: makeBinding(conversationID, env: "env-service", generation: 1))
        try await insertJob(database, id: jobID, conversationID: conversationID,
                            runID: runID, state: "running", environmentID: "env-service",
                            targetTool: "exec.localService",
                            lastError: "Stop requested; waiting for the executor to exit")
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        let ref = projection.references.first { $0.ownerID == jobID }
        #expect(ref?.classification == .active)
        #expect(ref?.state == "running")
    }

    @Test("unpinned resumable run is unknown; terminal unpinned run is not a reference")
    func unpinnedRunSemantics() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let paused = UUID(), interrupted = UUID(), completed = UUID(), cancelled = UUID()
        try await insertRun(database, id: paused, conversationID: conversationID, state: "paused", binding: nil)
        try await insertRun(database, id: interrupted, conversationID: conversationID, state: "interrupted", binding: nil)
        try await insertRun(database, id: completed, conversationID: conversationID, state: "completed", binding: nil)
        try await insertRun(database, id: cancelled, conversationID: conversationID, state: "cancelled", binding: nil)
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.references.contains { $0.ownerID == paused && $0.classification == .unknown })
        // interrupted is outside nonTerminalRuns, but the binding store can
        // still rebind it (`state NOT IN ('completed','cancelled')`), so it is
        // an explicit unknown reference, not dropped.
        #expect(projection.references.contains { $0.ownerID == interrupted && $0.classification == .unknown })
        #expect(!projection.references.contains { $0.ownerID == completed })
        #expect(!projection.references.contains { $0.ownerID == cancelled })
    }

    @Test("an unattributed live job refuses every target")
    func unattributedLiveJobRefuses() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID(), runID = UUID(), jobID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "paused", binding: nil)
        try await insertJob(database, id: jobID, conversationID: conversationID,
                            runID: runID, state: "running", environmentID: nil)
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.isComplete)
        let job = projection.references.first { $0.ownerID == jobID }
        #expect(job?.classification == .unknown)
        #expect(job?.isLive == true)
        if case .busy(let reasons) = projection.maintenanceVerdict(environmentID: "env-unrelated") {
            #expect(reasons.contains { $0.contains(jobID.uuidString) })
        } else {
            Issue.record("a live job with an unresolved environment must refuse every target")
        }
    }

    @Test("a non-live unpinned resumable run does not block byte-preserving maintenance")
    func nonLiveUnknownDoesNotBlock() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID(), runID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "paused", binding: nil)
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.isComplete)
        let run = projection.references.first { $0.ownerID == runID }
        #expect(run?.classification == .unknown)
        #expect(run?.isLive == false)
        #expect(projection.maintenanceVerdict(environmentID: "env-anywhere") == .clear)
    }

    @Test("an unrecognized run state remains live and refuses maintenance")
    func unrecognizedRunStateRefuses() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID(), runID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "future_running_state", binding: nil)
        let projection = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(projection.references.first { $0.ownerID == runID }?.isLive == true)
        if case .busy = projection.maintenanceVerdict(environmentID: "env-anywhere") {} else {
            Issue.record("unknown states must not be treated as idle")
        }
    }

    @Test("fingerprint is stable across timestamps and changes with references")
    func fingerprintStability() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID(), runID = UUID()
        try await insertConversation(database, id: conversationID)
        try await insertBinding(database, makeBinding(conversationID, env: "env-fingerprint", generation: 1))
        try await insertRun(database, id: runID, conversationID: conversationID,
                            state: "running", binding: makeBinding(conversationID, env: "env-fingerprint", generation: 1))
        let first = try await EnvironmentReferenceProjectionStore(database: database).project()
        let second = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(first.fingerprint == second.fingerprint)
        try await insertJob(database, id: UUID(), conversationID: conversationID,
                            runID: runID, state: "queued", environmentID: "env-fingerprint")
        let third = try await EnvironmentReferenceProjectionStore(database: database).project()
        #expect(first.fingerprint != third.fingerprint)
    }

    // MARK: - Fixtures

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeBinding(_ conversationID: UUID, env: String, generation: Int64) -> TaskExecutionBinding {
        TaskExecutionBinding(
            conversationID: conversationID,
            target: TaskExecutionTarget(
                environmentID: env, backend: .linuxVM,
                operatingSystem: "linux", architecture: "arm64",
                runtimeGeneration: "boot-\(generation)"
            ),
            generation: generation,
            updatedAt: Self.baseDate
        )
    }

    private func insertConversation(
        _ database: DatabaseManager, id: UUID, archived: Bool = false
    ) async throws {
        let now = Self.iso(Self.baseDate)
        let archivedAt: String? = archived ? now : nil
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations(id,title,created_at,updated_at,archived_at)
                VALUES(?,'Task',?,?,?)
                """, arguments: [id.uuidString, now, now, archivedAt])
        }
    }

    private func insertBinding(_ database: DatabaseManager, _ binding: TaskExecutionBinding) async throws {
        let body = try binding.encoded()
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO task_execution_bindings(conversation_id,generation,body_json) VALUES(?,?,?)",
                           arguments: [binding.conversationID.uuidString, binding.generation, body])
        }
    }

    private func insertRun(
        _ database: DatabaseManager, id: UUID, conversationID: UUID,
        state: String, binding: TaskExecutionBinding?
    ) async throws {
        let body = try binding?.encoded()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO runs(id,conversation_id,state,goal,started_at,ended_at,execution_binding_json)
                VALUES(?,?,?,?,?,NULL,?)
                """, arguments: [id.uuidString, conversationID.uuidString, state, "Task",
                                  Self.iso(Self.baseDate), body])
        }
    }

    private func insertJob(
        _ database: DatabaseManager, id: UUID, conversationID: UUID, runID: UUID,
        state: String, environmentID: String?, targetTool: String = "exec.shell",
        lastError: String? = nil
    ) async throws {
        try await database.writer { db in
            try Self.insertJobSQL(
                db, id: id, conversationID: conversationID, runID: runID,
                state: state, environmentID: environmentID,
                targetTool: targetTool, lastError: lastError
            )
        }
    }

    private static func insertJobSQL(
        _ db: Database, id: UUID, conversationID: UUID, runID: UUID,
        state: String, environmentID: String?, targetTool: String = "exec.shell",
        lastError: String? = nil
    ) throws {
        let now = iso(baseDate)
        try db.execute(sql: """
            INSERT INTO background_jobs(
                id,conversation_id,run_id,kind,target_tool,payload_json,state,
                environment_id,retry_count,created_at,updated_at,last_error
            ) VALUES(?,?,?,?,?,?,?,?,0,?,?,?)
            """, arguments: [id.uuidString, conversationID.uuidString, runID.uuidString,
                              "tool", targetTool, Data("{}".utf8), state, environmentID,
                              now, now, lastError])
    }

    private func insertMigration(_ database: DatabaseManager, _ migration: TaskEnvironmentMigration) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = String(decoding: try encoder.encode(migration), as: UTF8.self)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO task_environment_migrations(id,conversation_id,phase,revision,body_json,updated_at)
                VALUES(?,?,?,?,?,?)
                """, arguments: [migration.id.uuidString, migration.source.conversationID.uuidString,
                                  migration.phase.rawValue, migration.revision, body,
                                  Self.iso(migration.updatedAt)])
        }
    }
}
