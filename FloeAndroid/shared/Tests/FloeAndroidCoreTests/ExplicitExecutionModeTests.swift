// SPDX-License-Identifier: MPL-2.0
//
// Explicit execution-mode provenance (`agent|chat|plan|goal`).
// AUTHORED, NOT EXECUTED in this worker lane (no shared Swift build/device/
// Gradle authority). Covers the additive persistence contract:
//
//  * the wire member is PRESENCE-BASED: absent ⇒ nil/NULL, never a guessed
//    Agent; a present value must be in the closed vocabulary and agree with
//    the immutable `conversation_mode`;
//  * `runs.explicit_execution_mode` and
//    `pending_user_inputs.explicit_execution_mode` are nullable additions that
//    leave V34's three-value CHECK and every existing row/counter untouched;
//  * the checkpoint carries the value additively (format stays v5; legacy
//    files without the key decode to nil);
//  * restart/resume prefers the immutable run row, falls back to the exact
//    checkpoint, and never defaults a missing value to Agent;
//  * ordinary Agent/Chat keep the SAME task-authorized tool chain (no empty
//    Chat ceiling), while Plan and temporary narrowing still apply;
//  * an OLD v52 database upgrades through the REAL `DatabaseManager.migrate()`
//    entry: GRDB schedules by `grdb_migrations` identifiers, so v53/v54 apply
//    even though the pinned `user_version` marker stays 52, and existing
//    run/queue/schedule rows survive with NULL provenance.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeTools
import FloeSecurity
@testable import FloeAndroidCore

final class ExplicitExecutionModeTests: XCTestCase {

    // MARK: - Wire grammar

    private func startPayload(mode: String,
                              executionMode: String? = nil) -> SettingsDomainV1.JSONValue {
        var members: [String: SettingsDomainV1.JSONValue] = [
            "goal": .string("explicit mode probe"),
            "mode": .string(mode),
            "providerID": .string(UUID().uuidString),
            "modelID": .string(UUID().uuidString),
        ]
        if let executionMode {
            members["executionMode"] = .string(executionMode)
        }
        return .object(members)
    }

    func testAbsentExecutionModeStaysUnknownNeverAgent() throws {
        let query = try RunStartQuery.parse(
            payload: startPayload(mode: "chat"), conversationID: UUID())
        XCTAssertEqual(query.mode, .chat)
        XCTAssertNil(query.explicitExecutionMode,
                     "an old/unspecified launch must not be relabelled as Agent")
    }

    func testPresentExecutionModeIsParsedVerbatimAndPlanGoalStayExact() throws {
        XCTAssertEqual(try RunStartQuery.parse(
            payload: startPayload(mode: "chat", executionMode: "chat"),
            conversationID: UUID()).explicitExecutionMode, "chat")
        XCTAssertEqual(try RunStartQuery.parse(
            payload: startPayload(mode: "chat", executionMode: "agent"),
            conversationID: UUID()).explicitExecutionMode, "agent")
        let plan = try RunStartQuery.parse(
            payload: startPayload(mode: "plan", executionMode: "plan"),
            conversationID: UUID())
        XCTAssertEqual(plan.mode, .plan)
        XCTAssertEqual(plan.explicitExecutionMode, "plan")
        let goal = try RunStartQuery.parse(
            payload: startPayload(mode: "goal", executionMode: "goal"),
            conversationID: UUID())
        XCTAssertEqual(goal.mode, .goal)
        XCTAssertEqual(goal.explicitExecutionMode, "goal")
    }

    func testContradictoryOrForeignExecutionModeIsRefused() {
        XCTAssertThrowsError(try RunStartQuery.parse(
            payload: startPayload(mode: "chat", executionMode: "plan"),
            conversationID: UUID()))
        XCTAssertThrowsError(try RunStartQuery.parse(
            payload: startPayload(mode: "plan", executionMode: "chat"),
            conversationID: UUID()))
        XCTAssertThrowsError(try RunStartQuery.parse(
            payload: startPayload(mode: "chat", executionMode: "rm -rf"),
            conversationID: UUID()))
    }

    func testCreateIntentGrammarInheritsTheOptionalMemberWithoutBreakingOldCalls() throws {
        // `run.startTask` shares RunStartQuery's closed keys plus `title`;
        // the meeting assistant's existing call keeps working unchanged.
        var members: [String: SettingsDomainV1.JSONValue] = [
            "title": .string("meeting note"),
            "goal": .string("summarize the transcript"),
            "mode": .string("chat"),
            "providerID": .string(UUID().uuidString),
            "modelID": .string(UUID().uuidString),
        ]
        let old = try RunStartTaskQuery.parse(payload: .object(members))
        XCTAssertNil(old.inner.explicitExecutionMode)
        members["executionMode"] = .string("chat")
        let explicit = try RunStartTaskQuery.parse(payload: .object(members))
        XCTAssertEqual(explicit.inner.explicitExecutionMode, "chat")
    }

    // MARK: - Durable run provenance

    private func migratedDatabase() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        let version = try await manager.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        // The additive v54 columns are applied by identifier even though the
        // pinned shipped marker stays 52 (the v53 precedent).
        let applied = try await manager.appliedMigrations()
        XCTAssertTrue(applied.contains("v54_explicit_execution_mode"))
        return manager
    }

    func testLaunchPersistsOnlyTheProvidedExplicitModeAndKeepsTheThreeValueContract() async throws {
        let manager = try await migratedDatabase()
        let launches = SQLiteRunLaunchStore(database: manager)
        let runs = SQLiteRunStore(database: manager)

        let chatConversation = UUID()
        let chatRun = try await launches.prepare(RunLaunchRequest(
            conversationID: nil,
            newConversationID: chatConversation,
            conversationTitle: "chat provenance",
            goal: "hello",
            conversationMode: "chat",
            explicitExecutionMode: "chat"))
        let chatRecord = try await runs.run(id: chatRun.run.id)
        let storedChat = try XCTUnwrap(chatRecord)
        XCTAssertEqual(storedChat.conversationMode, "chat")
        XCTAssertEqual(storedChat.explicitExecutionMode, "chat")

        // An internal/older launch that never supplied the member records NULL.
        let internalConversation = UUID()
        let internalRun = try await launches.prepare(RunLaunchRequest(
            conversationID: nil,
            newConversationID: internalConversation,
            conversationTitle: "unlabeled launch",
            goal: "hello",
            conversationMode: "chat"))
        let internalRecord = try await runs.run(id: internalRun.run.id)
        let storedInternal = try XCTUnwrap(internalRecord)
        XCTAssertEqual(storedInternal.conversationMode, "chat")
        XCTAssertNil(storedInternal.explicitExecutionMode,
                     "never fabricate a user selection for an unlabeled launch")

        // A contradictory pair is refused BEFORE any durable effect.
        let refusedConversation = UUID()
        do {
            _ = try await launches.prepare(RunLaunchRequest(
                conversationID: nil,
                newConversationID: refusedConversation,
                conversationTitle: "contradiction",
                goal: "hello",
                conversationMode: "plan",
                explicitExecutionMode: "agent"))
            XCTFail("a contradictory explicit mode must never reach the writer")
        } catch { }
        let refusedRuns = try await runs.runs(conversationID: refusedConversation)
        XCTAssertTrue(refusedRuns.isEmpty)

        // The original three-value CHECK is still the only launch contract.
        do {
            try await manager.writer { db in
                try db.execute(sql:
                    "UPDATE runs SET conversation_mode = 'agent' WHERE id = '\(storedChat.id.uuidString)'")
            }
            XCTFail("conversation_mode must keep its closed chat|plan|goal CHECK")
        } catch { }
        // The new nullable column's vocabulary is enforced by the DB too.
        do {
            try await manager.writer { db in
                try db.execute(sql:
                    "UPDATE runs SET explicit_execution_mode = 'rm -rf' WHERE id = '\(storedChat.id.uuidString)'")
            }
            XCTFail("explicit_execution_mode must keep its closed CHECK")
        } catch { }
    }

    func testOldV52DatabaseAppliesV53AndV54ThroughTheRealManagerAndPreservesRows() async throws {
        // Build a REAL pre-v54 database: the exact identifier bookkeeping of
        // the shipped v52 chain (derived from the real manager, not a
        // duplicated list) plus the v12/v34/v46 table shapes V53/V54 consume.
        let probe = try DatabaseManager.inMemory()
        try await probe.migrate()
        let allIdentifiers = try await probe.appliedMigrations()
        let oldIdentifiers = allIdentifiers.filter {
            $0 != "v53_android_system_conditions" &&
                $0 != "v54_explicit_execution_mode"
        }
        XCTAssertEqual(oldIdentifiers.count, allIdentifiers.count - 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-v52-upgrade-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let conversationID = UUID()
        let runID = UUID()
        let inputID = UUID()
        let scheduleID = UUID()
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = timestampFormatter.string(from: Date())
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql:
                "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in oldIdentifiers {
                try db.execute(sql:
                    "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier])
            }
            try db.execute(sql: """
                CREATE TABLE runs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    goal TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    goal_id TEXT,
                    provider_id TEXT,
                    model_id TEXT,
                    provider_name_snapshot TEXT,
                    model_name_snapshot TEXT,
                    conversation_mode TEXT
                        CHECK(conversation_mode IN ('chat', 'plan', 'goal'))
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE pending_user_inputs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    target_run_id TEXT,
                    content TEXT NOT NULL,
                    mode TEXT NOT NULL CHECK(mode IN ('queue', 'steer')),
                    status TEXT NOT NULL CHECK(status IN (
                        'queued', 'promoting', 'steerPending', 'consumed', 'cancelled'
                    )),
                    position INTEGER NOT NULL,
                    attachments_json TEXT NOT NULL DEFAULT '[]',
                    selected_model_id TEXT,
                    workspace_id TEXT,
                    execution_mode TEXT NOT NULL DEFAULT 'agent',
                    consumed_run_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    consumed_at TEXT
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE task_schedules (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    workspace_id TEXT,
                    cadence TEXT NOT NULL CHECK (cadence IN (
                        'once', 'daily', 'weekly', 'interval', 'afterSuccess'
                    )),
                    scheduled_at TEXT NOT NULL,
                    weekday INTEGER,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    last_started_at TEXT,
                    next_expected_at TEXT,
                    policy_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    interval_seconds INTEGER,
                    anchor_timezone TEXT,
                    upstream_run_id TEXT,
                    model_id TEXT,
                    environment_id TEXT,
                    permission_json TEXT
                ) STRICT
                """)
            try db.execute(sql: """
                INSERT INTO runs (
                    id, conversation_id, state, goal, started_at, conversation_mode
                ) VALUES (?, ?, 'checkpointed', 'old run', ?, 'chat')
                """, arguments: [runID.uuidString, conversationID.uuidString, now])
            try db.execute(sql: """
                INSERT INTO pending_user_inputs (
                    id, conversation_id, content, mode, status, position,
                    execution_mode, created_at, updated_at
                ) VALUES (?, ?, 'old queued row', 'queue', 'queued', 1, 'chat', ?, ?)
                """, arguments: [inputID.uuidString, conversationID.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO task_schedules (
                    id, title, prompt, cadence, scheduled_at, created_at, updated_at
                ) VALUES (?, 'old schedule', 'old prompt', 'daily', ?, ?, ?)
                """, arguments: [scheduleID.uuidString, now, now, now])
        }
        try queue.close()

        // The REAL production entry: DatabaseManager registers and applies the
        // chain. No fixture-local migrator, no duplicated SQL.
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()

        let applied = try await manager.appliedMigrations()
        XCTAssertTrue(applied.contains("v53_android_system_conditions"))
        XCTAssertEqual(applied.filter { $0 == "v54_explicit_execution_mode" }.count, 1,
                       "v54 must apply exactly once, never skipped by the marker")
        let version = try await manager.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)

        let run = try await manager.reader { db -> (String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT conversation_mode, explicit_execution_mode FROM runs WHERE id = ?",
                arguments: [runID.uuidString])
            return (row?["conversation_mode"], row?["explicit_execution_mode"])
        }
        XCTAssertEqual(run.0, "chat")
        XCTAssertNil(run.1, "an upgraded legacy run must not be relabelled")

        let queued = try await manager.reader { db -> (String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT execution_mode, explicit_execution_mode FROM pending_user_inputs WHERE id = ?",
                arguments: [inputID.uuidString])
            return (row?["execution_mode"], row?["explicit_execution_mode"])
        }
        XCTAssertEqual(queued.0, "chat")
        XCTAssertNil(queued.1)

        let scheduleTitle = try await manager.reader { db in
            try String.fetchOne(
                db, sql: "SELECT title FROM task_schedules WHERE id = ?",
                arguments: [scheduleID.uuidString])
        }
        XCTAssertEqual(scheduleTitle, "old schedule",
                       "v53 must preserve the existing schedule row")
        try? await manager.close()
    }

    func testLegacyRunRowsReadAsAbsentProvenance() async throws {
        let manager = try await migratedDatabase()
        let runs = SQLiteRunStore(database: manager)
        let conversationID = UUID()
        let runID = UUID()
        // The on-disk shape of a row migrated from v52/v53: the new nullable
        // column is NULL and the original columns are untouched.
        try await DBRecordProbe.insertConversation(manager, id: conversationID)
        try await DBRecordProbe.insertLegacyRun(
            manager, id: runID, conversationID: conversationID,
            conversationMode: "chat")
        let legacyRecord = try await runs.run(id: runID)
        let stored = try XCTUnwrap(legacyRecord)
        XCTAssertEqual(stored.conversationMode, "chat")
        XCTAssertNil(stored.explicitExecutionMode)
    }

    func testExplicitModeSurvivesARunStateUpsertWithoutOverwritingTheFirstValue() async throws {
        let manager = try await migratedDatabase()
        let runs = SQLiteRunStore(database: manager)
        let runID = UUID()
        let conversationID = UUID()
        try await DBRecordProbe.insertConversation(manager, id: conversationID)
        try await runs.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "preparing",
            goal: "x", startedAt: Date(), conversationMode: "chat",
            explicitExecutionMode: "chat"))
        // A later compatibility save without the value must not clear it.
        try await runs.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "completed",
            goal: "x", startedAt: Date(), conversationMode: "chat"))
        let updatedRecord = try await runs.run(id: runID)
        let stored = try XCTUnwrap(updatedRecord)
        XCTAssertEqual(stored.state, "completed")
        XCTAssertEqual(stored.explicitExecutionMode, "chat")
    }

    // MARK: - Queue provenance

    func testQueuedRowProvenanceIsPresenceBasedAndLegacyRowsStayNull() async throws {
        let manager = try await migratedDatabase()
        let inputs = SQLiteRunningInputStore(database: manager)
        let conversationID = UUID()
        try await DBRecordProbe.insertConversation(manager, id: conversationID)

        let explicit = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, content: "queued chat",
            mode: .queue, executionMode: "chat"), explicitExecutionMode: "chat")
        let explicitStored = try await inputs.explicitExecutionMode(id: explicit.id)
        XCTAssertEqual(explicitStored, "chat")

        let unlabeled = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, content: "unlabeled",
            mode: .queue, executionMode: "agent"))
        let unlabeledStored = try await inputs.explicitExecutionMode(id: unlabeled.id)
        XCTAssertNil(unlabeledStored,
                     "the historical queue default is not a user selection")

        // A row written by an older build (no new column value) stays NULL.
        let legacyID = UUID()
        try await DBRecordProbe.insertLegacyQueuedInput(
            manager, id: legacyID, conversationID: conversationID)
        let legacyStored = try await inputs.explicitExecutionMode(id: legacyID)
        XCTAssertNil(legacyStored)

        // The closed vocabulary is refused before any row is written.
        do {
            _ = try await inputs.enqueue(PendingUserInput(
                conversationID: conversationID, content: "bad", mode: .queue),
                explicitExecutionMode: "rm -rf")
            XCTFail("a foreign explicit mode must be refused")
        } catch { }
    }

    func testDrainMappingAcceptsOnlyConsistentStoredProvenance() {
        XCTAssertEqual(FacadeRunDomain.queuedExplicitExecutionMode("chat", launchMode: .chat), "chat")
        XCTAssertEqual(FacadeRunDomain.queuedExplicitExecutionMode("agent", launchMode: .chat), "agent")
        XCTAssertEqual(FacadeRunDomain.queuedExplicitExecutionMode("plan", launchMode: .plan), "plan")
        XCTAssertEqual(FacadeRunDomain.queuedExplicitExecutionMode("goal", launchMode: .goal), "goal")
        XCTAssertNil(FacadeRunDomain.queuedExplicitExecutionMode(nil, launchMode: .chat))
        XCTAssertNil(FacadeRunDomain.queuedExplicitExecutionMode("chat", launchMode: .plan))
        XCTAssertNil(FacadeRunDomain.queuedExplicitExecutionMode("browserHandoff", launchMode: .chat))
    }

    // MARK: - Checkpoint + restart

    func testCheckpointCarriesTheModeAdditivelyAndLegacyFilesDecodeNil() throws {
        let explicit = AgentCheckpoint(
            runID: UUID(), conversationID: UUID(), state: .idle, messages: [],
            conversationMode: .chat, explicitExecutionMode: .chat)
        let decoded = try AgentCheckpoint.decoded(from: explicit.encoded())
        XCTAssertEqual(decoded.explicitExecutionMode, .chat)
        XCTAssertEqual(decoded.formatVersion, AgentCheckpoint.currentFormatVersion)

        let legacy = AgentCheckpoint(
            runID: UUID(), conversationID: UUID(), state: .idle, messages: [],
            conversationMode: .chat)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
        object.removeValue(forKey: "explicitExecutionMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys])
        let legacyDecoded = try AgentCheckpoint.decoded(from: legacyData)
        XCTAssertNil(legacyDecoded.explicitExecutionMode)
        XCTAssertEqual(legacyDecoded.conversationMode, .chat)
    }

    func testRestartPrefersTheRowThenTheCheckpointAndNeverDefaultsAgent() {
        let conversationID = UUID()
        let rowChat = RunRecord(
            id: UUID(), conversationID: conversationID, state: "checkpointed",
            goal: "x", startedAt: Date(), conversationMode: "chat",
            explicitExecutionMode: "chat")
        let checkpointAgent = AgentCheckpoint(
            runID: UUID(), conversationID: conversationID, state: .idle, messages: [],
            conversationMode: .chat, explicitExecutionMode: .agent)
        XCTAssertEqual(FacadeRunDomain.resumedExplicitExecutionMode(
            record: rowChat, checkpoint: checkpointAgent), .chat)

        let rowUnlabeled = RunRecord(
            id: UUID(), conversationID: conversationID, state: "checkpointed",
            goal: "x", startedAt: Date(), conversationMode: "chat")
        XCTAssertEqual(FacadeRunDomain.resumedExplicitExecutionMode(
            record: rowUnlabeled, checkpoint: checkpointAgent), .agent)

        XCTAssertNil(FacadeRunDomain.resumedExplicitExecutionMode(
            record: rowUnlabeled, checkpoint: nil))
    }

    // MARK: - Real tool chain / narrowing

    private func descriptor(_ name: String,
                            riskLabels: Set<RiskLabel>,
                            isSideEffecting: Bool,
                            effect: ToolEffect) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "explicit-mode tool policy fixture",
            parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect)
    }

    func testAgentAndChatShareTheTaskAuthorizedChainAndPlanTemporaryKeepTheirNarrowing() {
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(
            descriptor: descriptor("exec.shell", riskLabels: [.executesRemoteCommand],
                                   isSideEffecting: true, effect: .mutating),
            run: { _, _ in ToolExecutionOutput(digesting: "ok", exitStatus: 0) }))
        registry.register(AnyAgentTool(
            descriptor: descriptor("web.fetch", riskLabels: [.networkAccess],
                                   isSideEffecting: false, effect: .readOnly),
            run: { _, _ in ToolExecutionOutput(digesting: "ok", exitStatus: 0) }))
        let assembly = RunToolAssembly(registry: registry)
        let policy = TaskPolicy(
            conversationID: UUID(),
            allowedToolNames: ["exec.shell", "web.fetch"])

        // Chat and Agent use the SAME persisted task ceiling. No mode-driven
        // empty ceiling exists on the native side.
        let chat = assembly.allowedToolNames(
            taskPolicy: policy, hostCeiling: nil, mode: .chat, temporary: false)
        XCTAssertEqual(chat, Set(["exec.shell", "web.fetch"]))

        // A REAL host-authored empty ceiling (e.g. the meeting assistant's
        // text-only launch) is still honoured exactly.
        let emptyHostCeiling = assembly.allowedToolNames(
            taskPolicy: policy, hostCeiling: [], mode: .chat, temporary: false)
        XCTAssertEqual(emptyHostCeiling, Set<String>())

        // Plan still drops the side-effecting shell route.
        let plan = assembly.allowedToolNames(
            taskPolicy: policy, hostCeiling: nil, mode: .plan, temporary: false)
        XCTAssertNotNil(plan)
        XCTAssertFalse(plan?.contains("exec.shell") ?? true,
                       "Plan must keep its read-only projection")

        // Temporary keeps the separate frozen public-web ceiling.
        let temporary = assembly.allowedToolNames(
            taskPolicy: policy, hostCeiling: nil, mode: .chat, temporary: true)
        XCTAssertNotNil(temporary)
        XCTAssertEqual(temporary, Set(["web.fetch"]),
                       "temporary ceiling never widens to task tools")
    }
}

// MARK: - Narrow SQL helpers

/// Direct-SQL probes for the on-disk shapes this test must prove (legacy NULL
/// rows, CHECK enforcement). Test-only; never used by production code.
private enum DBRecordProbe {
    static func insertConversation(_ manager: DatabaseManager, id: UUID) async throws {
        let now = isoTimestamp()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO conversations
                    (id, title, created_at, updated_at, mode, title_origin)
                VALUES (?, 'probe', ?, ?, 'chat', 'manual')
                """, arguments: [id.uuidString, now, now])
        }
    }

    static func insertLegacyRun(_ manager: DatabaseManager,
                                id: UUID, conversationID: UUID,
                                conversationMode: String) async throws {
        let now = isoTimestamp()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO runs (
                    id, conversation_id, state, goal, started_at, ended_at, goal_id,
                    provider_id, model_id, provider_name_snapshot, model_name_snapshot,
                    conversation_mode, explicit_execution_mode
                ) VALUES (?, ?, 'checkpointed', 'legacy', ?, NULL, NULL, NULL, NULL,
                          NULL, NULL, ?, NULL)
                """, arguments: [id.uuidString, conversationID.uuidString, now,
                                 conversationMode])
        }
    }

    static func insertLegacyQueuedInput(_ manager: DatabaseManager,
                                        id: UUID, conversationID: UUID) async throws {
        let now = isoTimestamp()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO pending_user_inputs (
                    id, conversation_id, target_run_id, content, mode, status, position,
                    attachments_json, selected_model_id, workspace_id, execution_mode,
                    explicit_execution_mode, consumed_run_id, created_at, updated_at, consumed_at
                ) VALUES (?, ?, NULL, 'legacy', 'queue', 'queued', 1, '[]', NULL, NULL,
                          'agent', NULL, NULL, ?, ?, NULL)
                """, arguments: [id.uuidString, conversationID.uuidString, now, now])
        }
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
