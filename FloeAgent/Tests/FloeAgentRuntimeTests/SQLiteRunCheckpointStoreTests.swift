// FloeAgentRuntimeTests — canonical SQLite run checkpoint store.
//
// These tests pin the migration-critical contracts of the runtime recovery
// authority:
//  * a real filesystem legacy checkpoint is read through once, adopts the
//    run's trusted pin, and its file is never rewritten or deleted;
//  * the canonical SQLite body always wins over a legacy file;
//  * a legacy import can never replace a newer concurrent canonical write;
//  * a checkpoint from an old environment generation — or a late nil-pin
//    callback — is rejected inside the same writer transaction that would
//    upsert it, preserving the newer row;
//  * run/conversation ownership and a missing run fail closed;
//  * a real TaskExecutionBindingStore.commit rebinds and snapshots the
//    canonical checkpoint in one transaction, and the next load returns the
//    new pin that AgentRuntime.resume compares against.

import Foundation
import GRDB
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

@Suite("SQLite run checkpoint store")
struct SQLiteRunCheckpointStoreTests: Sendable {
    private static let baseDate = Date(timeIntervalSince1970: 1_761_400_000)

    // MARK: - Fixtures

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func makeTarget(_ environmentID: String = "env-a") -> TaskExecutionTarget {
        TaskExecutionTarget(
            environmentID: environmentID,
            backend: .remoteSSH,
            remoteHostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
            remoteRootPath: "/home/floe/.floe/tasks/\(environmentID)",
            operatingSystem: "linux",
            architecture: "arm64",
            runtimeGeneration: "boot-1"
        )
    }

    private func makeBinding(
        _ conversationID: UUID,
        environmentID: String = "env-a",
        generation: Int64 = 1,
        updatedAt: Date = Self.baseDate
    ) -> TaskExecutionBinding {
        TaskExecutionBinding(
            conversationID: conversationID,
            target: makeTarget(environmentID),
            generation: generation,
            updatedAt: updatedAt
        )
    }

    private func makeConversationAndRun(
        _ database: DatabaseManager,
        conversationID: UUID = UUID(),
        runID: UUID = UUID(),
        binding: TaskExecutionBinding?
    ) async throws -> (UUID, UUID) {
        try await SQLiteConversationStore(database: database).saveConversation(
            ConversationRecord(
                id: conversationID,
                title: "Task",
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate
            )
        )
        try await SQLiteRunStore(database: database).saveRun(
            RunRecord(
                id: runID,
                conversationID: conversationID,
                state: "running",
                goal: "Task",
                startedAt: Self.baseDate,
                executionBinding: binding
            )
        )
        return (conversationID, runID)
    }

    private func makeCheckpoint(
        runID: UUID,
        conversationID: UUID,
        marker: String,
        binding: TaskExecutionBinding?
    ) -> AgentCheckpoint {
        AgentCheckpoint(
            runID: runID,
            conversationID: conversationID,
            state: .checkpointed(AgentState.CheckpointRef(createdAt: Self.baseDate, reason: "tests")),
            messages: [ConversationMessage(role: "user", content: marker, createdAt: Self.baseDate)],
            createdAt: Self.baseDate,
            executionBinding: binding
        )
    }

    private func makeLegacyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacyURL(_ directory: URL, runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).checkpoint.json")
    }

    @discardableResult
    private func writeLegacy(_ checkpoint: AgentCheckpoint, to directory: URL) throws -> URL {
        let url = legacyURL(directory, runID: checkpoint.runID)
        try checkpoint.encoded().write(to: url, options: .atomic)
        return url
    }

    private func checkpointRow(
        _ database: DatabaseManager,
        runID: UUID
    ) async throws -> (body: String, updatedAt: String)? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT body_json, updated_at FROM checkpoints WHERE run_id = ?",
                arguments: [runID.uuidString]
            ) else { return nil }
            return (row["body_json"] as String, row["updated_at"] as String)
        }
    }

    private func snapshotBody(
        _ database: DatabaseManager,
        migrationID: UUID,
        runID: UUID
    ) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT body_json FROM task_environment_migration_checkpoints
                    WHERE migration_id = ? AND run_id = ?
                    """,
                arguments: [migrationID.uuidString, runID.uuidString]
            )
        }
    }

    // MARK: - Legacy read-through

    @Test("A real legacy file is imported once, adopts the trusted pin, and is never rewritten")
    func legacyFileReadThroughIsStable() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let binding = makeBinding(conversationID)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: binding
        )
        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "legacy",
            binding: nil
        )
        let url = try writeLegacy(legacy, to: directory)
        let originalBytes = try Data(contentsOf: url)
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)

        let first = try #require(try await store.load(runID: runID))
        #expect(first.runID == runID)
        #expect(first.conversationID == conversationID)
        #expect(first.executionBinding == binding)
        #expect(first.messages.last?.content == "legacy")

        let row = try #require(try await checkpointRow(database, runID: runID))
        let canonical = try AgentCheckpoint.decoded(from: Data(row.body.utf8))
        #expect(canonical.executionBinding == binding)
        #expect(try Data(contentsOf: url) == originalBytes)

        let second = try #require(try await store.load(runID: runID))
        #expect(second == first)
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test("The canonical SQLite body wins over a legacy file")
    func canonicalBodyWinsOverLegacyFile() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let binding = makeBinding(conversationID)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: binding
        )
        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)

        let canonical = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "canonical",
            binding: binding
        )
        try await store.save(canonical)
        let before = try #require(try await checkpointRow(database, runID: runID)).body

        let legacy = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "legacy",
            binding: binding
        )
        let url = try writeLegacy(legacy, to: directory)
        let originalBytes = try Data(contentsOf: url)

        let loaded = try #require(try await store.load(runID: runID))
        #expect(loaded.messages.last?.content == "canonical")
        #expect(try await checkpointRow(database, runID: runID)?.body == before)
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    @Test("A legacy import cannot overwrite a newer concurrent canonical write")
    func legacyImportCannotOverwriteNewerCanonicalWrite() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let binding = makeBinding(conversationID)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: binding
        )
        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "legacy",
            binding: binding
        )
        let url = try writeLegacy(legacy, to: directory)
        let originalBytes = try Data(contentsOf: url)
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)

        let newer = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "newer",
            binding: binding
        )
        // Both operations begin before either is awaited. Whichever order the
        // SQLite writer serializes them, the import is insert-if-absent and
        // the explicit newer write is the final body.
        async let loading = store.load(runID: runID)
        try await store.save(newer)
        _ = try await loading

        let row = try #require(try await checkpointRow(database, runID: runID))
        let final = try AgentCheckpoint.decoded(from: Data(row.body.utf8))
        #expect(final.messages.last?.content == "newer")
        #expect(final.executionBinding == binding)
        #expect(try Data(contentsOf: url) == originalBytes)
    }

    // MARK: - Stale writes and ownership

    @Test("An old environment generation is rejected atomically and preserves the newer checkpoint")
    func staleEnvironmentWriteIsRejectedAtomically() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let oldBinding = makeBinding(conversationID, environmentID: "env-old", generation: 1)
        let newBinding = makeBinding(conversationID, environmentID: "env-new", generation: 2)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: newBinding
        )
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)

        try await store.save(makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "fresh",
            binding: newBinding
        ))
        let before = try #require(try await checkpointRow(database, runID: runID))

        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: conversationID,
                marker: "stale-generation",
                binding: self.makeBinding(conversationID, environmentID: "env-new", generation: 1)
            ))
        }
        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: conversationID,
                marker: "stale-environment",
                binding: self.makeBinding(conversationID, environmentID: "env-old", generation: 2)
            ))
        }
        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: conversationID,
                marker: "untrusted-pin",
                binding: oldBinding
            ))
        }
        // A late callback that carries no pin cannot overwrite a pinned run
        // with an env-neutral body either.
        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: conversationID,
                marker: "late-nil",
                binding: nil
            ))
        }

        let after = try #require(try await checkpointRow(database, runID: runID))
        #expect(after.body == before.body)
        #expect(after.updatedAt == before.updatedAt)
    }

    @Test("Checkpoint ownership and a missing run fail closed without creating a row")
    func ownershipAndMissingRunFailClosed() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let otherConversationID = UUID()
        let binding = makeBinding(conversationID)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: binding
        )
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)

        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: otherConversationID,
                marker: "wrong-owner",
                binding: binding
            ))
        }
        #expect(try await checkpointRow(database, runID: runID) == nil)

        let missingRunID = UUID()
        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: missingRunID,
                conversationID: conversationID,
                marker: "missing-run",
                binding: binding
            ))
        }
        #expect(try await checkpointRow(database, runID: missingRunID) == nil)

        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanLegacy = makeCheckpoint(
            runID: missingRunID,
            conversationID: conversationID,
            marker: "orphan",
            binding: binding
        )
        let orphanURL = try writeLegacy(orphanLegacy, to: directory)
        let legacyStore = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)
        #expect(try await legacyStore.load(runID: missingRunID) == nil)
        #expect(try await checkpointRow(database, runID: missingRunID) == nil)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test("A legacy file owned by another conversation is never imported")
    func legacyConversationMismatchFailsClosed() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let otherConversationID = UUID()
        let binding = makeBinding(conversationID)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: binding
        )
        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreign = makeCheckpoint(
            runID: runID,
            conversationID: otherConversationID,
            marker: "foreign",
            binding: nil
        )
        let url = try writeLegacy(foreign, to: directory)
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)

        await #expect(throws: FloeError.self) {
            _ = try await store.load(runID: runID)
        }
        #expect(try await checkpointRow(database, runID: runID) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A non-nil legacy pin must match the run; updatedAt metadata is ignored")
    func legacyPinIdentityIsEnforcedWithoutTimestampNoise() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let oldBinding = makeBinding(conversationID, environmentID: "env-old", generation: 1)
        let newBinding = makeBinding(conversationID, environmentID: "env-new", generation: 2)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: newBinding
        )
        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)

        let stale = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "stale",
            binding: oldBinding
        )
        let url = try writeLegacy(stale, to: directory)
        let originalBytes = try Data(contentsOf: url)
        await #expect(throws: FloeError.self) {
            _ = try await store.load(runID: runID)
        }
        #expect(try await checkpointRow(database, runID: runID) == nil)
        #expect(try Data(contentsOf: url) == originalBytes)

        // Same identity, generation and target; only the presentation
        // timestamp differs. This is the same environment and must import.
        let sameIdentity = TaskExecutionBinding(
            conversationID: conversationID,
            target: newBinding.target,
            generation: newBinding.generation,
            updatedAt: Self.baseDate.addingTimeInterval(3_600)
        )
        let matching = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "matching",
            binding: sameIdentity
        )
        _ = try writeLegacy(matching, to: directory)
        let loaded = try #require(try await store.load(runID: runID))
        #expect(loaded.runID == runID)
        #expect(loaded.conversationID == conversationID)
        #expect(loaded.executionBinding?.conversationID == newBinding.conversationID)
        #expect(loaded.executionBinding?.generation == newBinding.generation)
        #expect(loaded.executionBinding?.target == newBinding.target)
        #expect(try await checkpointRow(database, runID: runID) != nil)
    }

    @Test("A canonical row with a stale pin is rejected instead of resumed")
    func staleCanonicalRowFailsClosed() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let oldBinding = makeBinding(conversationID, environmentID: "env-old", generation: 1)
        let newBinding = makeBinding(conversationID, environmentID: "env-new", generation: 2)
        let (_, runID) = try await makeConversationAndRun(
            database,
            conversationID: conversationID,
            binding: newBinding
        )
        let stale = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "stale",
            binding: oldBinding
        )
        let staleBody = String(decoding: try stale.encoded(), as: UTF8.self)
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO checkpoints (run_id, conversation_id, format_version, state, body_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID.uuidString,
                    conversationID.uuidString,
                    stale.formatVersion,
                    stale.state.name,
                    staleBody,
                    "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:00:00.000Z",
                ]
            )
        }
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)

        await #expect(throws: FloeError.self) {
            _ = try await store.load(runID: runID)
        }
        let row = try #require(try await checkpointRow(database, runID: runID))
        #expect(try AgentCheckpoint.decoded(from: Data(row.body.utf8)).executionBinding == oldBinding)
    }

    // MARK: - Migration

    @Test("A durable migration rebinds and snapshots the canonical checkpoint; load returns the new pin")
    func migrationRebindAndSnapshotAreAtomic() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        let oldBinding = makeBinding(conversationID, environmentID: "env-old", generation: 1)
        let bindings = TaskExecutionBindingStore(database: database)

        let runID = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            ConversationRecord(
                id: conversationID,
                title: "Task",
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate
            )
        )
        try await SQLiteRunStore(database: database).saveRun(
            RunRecord(
                id: runID,
                conversationID: conversationID,
                state: "running",
                goal: "Task",
                startedAt: Self.baseDate
            )
        )
        _ = try await bindings.bindInitial(oldBinding)
        try await bindings.pinRun(runID: runID, binding: oldBinding)

        let directory = try makeLegacyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteRunCheckpointStore(database: database, legacyDirectory: directory)
        try await store.save(makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "before-migration",
            binding: oldBinding
        ))
        let beforeBody = try #require(try await checkpointRow(database, runID: runID)).body
        // A file left behind before the migration must never win afterwards.
        let staleFile = makeCheckpoint(
            runID: runID,
            conversationID: conversationID,
            marker: "stale-file",
            binding: oldBinding
        )
        let staleURL = try writeLegacy(staleFile, to: directory)

        var migration = TaskEnvironmentMigration(source: oldBinding, target: makeTarget("env-new"))
        try await bindings.begin(migration)
        migration.phase = .verified
        migration.manifestDigest = String(repeating: "a", count: 64)
        migration.dependencyReceiptDigest = String(repeating: "b", count: 64)
        migration.skillDigests = [:]
        migration.preparedFileCount = 1
        migration.preparedBytes = 64
        migration = try await bindings.update(migration, expectedRevision: migration.revision)
        let committed = try await bindings.commit(migration)
        #expect(committed.phase == .committed)

        let newBinding = try #require(try await bindings.binding(conversationID: conversationID))
        #expect(newBinding.generation == oldBinding.generation + 1)
        #expect(newBinding.target.environmentID == "env-new")
        let runAfter = try #require(try await SQLiteRunStore(database: database).run(id: runID))
        #expect(runAfter.executionBinding == newBinding)

        // The exact pre-migration body is retained as evidence.
        #expect(try await snapshotBody(database, migrationID: committed.id, runID: runID) == beforeBody)

        let afterBody = try #require(try await checkpointRow(database, runID: runID)).body
        let rebound = try AgentCheckpoint.decoded(from: Data(afterBody.utf8))
        #expect(rebound.executionBinding == newBinding)
        #expect(rebound.messages.last?.content == "before-migration")

        // A late checkpoint from a runtime that never carried the pin is
        // rejected after commit and preserves both the new body and its
        // pre-migration snapshot.
        await #expect(throws: FloeError.self) {
            try await store.save(makeCheckpoint(
                runID: runID,
                conversationID: conversationID,
                marker: "late-nil",
                binding: nil
            ))
        }
        #expect(try await checkpointRow(database, runID: runID)?.body == afterBody)
        #expect(try await snapshotBody(database, migrationID: committed.id, runID: runID) == beforeBody)

        let loaded = try #require(try await store.load(runID: runID))
        #expect(loaded.executionBinding == newBinding)
        #expect(loaded.runID == runID)
        #expect(loaded.conversationID == conversationID)
        // AgentRuntime.resume compares exactly this pin against its immutable
        // configuration binding; equality here is the compatibility contract.
        #expect(loaded.executionBinding == runAfter.executionBinding)
        #expect(FileManager.default.fileExists(atPath: staleURL.path))
    }
}
