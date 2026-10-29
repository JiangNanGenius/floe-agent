// SPDX-License-Identifier: MPL-2.0
//
// Task-policy convergence regressions (2026-10-29, C17 persistent
// Full-access refusal). Proven chain: device read-only probe showed ZERO
// task_policies rows against five real runs; ownership was pre-bound by the
// provider-free terminal preparation. Ownership pre-bound without a policy
// row => WorkspaceStore.taskPolicy synthesizes a fresh Date() on EVERY read
// => run.policy.update's CAS stamp (RunWireRevision.taskPolicyVersion) never
// remains stable => deterministic typed staleRevision refusal behind the
// generic ordinaryRuntimeBlocked outer code.
//
// AUTHORED, NOT EXECUTED. Main compiles/runs this cohort with the Core09
// batch. Real GRDB in-memory stores and the REAL registered migration
// closure: the v47→v48 repair is exercised by rewinding ONLY the GRDB
// applied-migration bookkeeping (test-only fixture step, exactly the owned
// pre-v48 shape a shipping v47 database has), seeding the broken state, and
// letting DatabaseManager.migrate() apply the production v48 identifier —
// no production SQL or registration list is duplicated here.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class TaskPolicyConvergenceTests: XCTestCase {

    /// Sendable projection of a task_policies row (GRDB Row is not Sendable
    /// and cannot cross DatabaseManager.reader's <T: Sendable> boundary).
    private struct PolicyProbe: Sendable {
        let approvalMode: String?
        let allowedToolNamesJSON: String?
        let filePathsJSON: String?
        let networkAllowed: Int64?
        let browserControlAllowed: Int64?
        let uploadAllowed: Int64?
        let credentialsAllowed: Int64?
        let remoteExecutionAllowed: Int64?
        let recoveryPolicy: String?
        let notificationPolicy: String?
        let updatedAt: String
    }

    private func migrated() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return manager
    }

    /// TEST-ONLY fixture step: rewind the GRDB applied-migration bookkeeping
    /// and user_version from v48 back to v47 WITHOUT touching any data, so
    /// the next `migrate()` re-applies the REAL registered v48 closure
    /// against seeded pre-repair state — the same shape a shipping v47
    /// database has at cold-open. Never used outside this test file.
    private func rewindBookkeepingToV47(_ manager: DatabaseManager) async throws {
        try await manager.writer { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v48_task_policy_convergence'")
            try db.execute(sql: "PRAGMA user_version = 47")
        }
    }

    private func seedConversation(_ manager: DatabaseManager, id: UUID,
                                  purpose: String = "ordinary") async throws {
        let stamp = "2026-10-29T05:33:41.028Z"
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations
                        (id, title, created_at, updated_at, purpose)
                    VALUES (?, '', ?, ?, ?)
                    """,
                arguments: [id.uuidString, stamp, stamp, purpose])
        }
    }

    /// Ownership WITHOUT a policy row — the exact terminal-first shape that
    /// produced the C17 device state.
    private func seedOwnershipWithoutPolicy(_ manager: DatabaseManager,
                                            conversationID: UUID) async throws -> UUID {
        let workspaceID = UUID()
        let stamp = "2026-10-29T05:33:41.028Z"
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces (
                        id, name, root_bookmark, last_opened_at,
                        active_target_kind, active_target_host_id,
                        inspector_state_json, instructions_rel_path,
                        created_at, updated_at, kind, internal_relative_path
                    ) VALUES (?, 'Probe', ?, NULL, 'local', NULL, '{}', NULL,
                              ?, ?, 'privateTask', ?)
                    """,
                arguments: [workspaceID.uuidString, Data(), stamp, stamp,
                            "PrivateTasks/\(conversationID.uuidString)"])
            try db.execute(
                sql: """
                    INSERT INTO conversation_workspace_ownership
                        (conversation_id, workspace_id, assigned_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [conversationID.uuidString, workspaceID.uuidString, stamp])
        }
        return workspaceID
    }

    private func policyProbe(_ manager: DatabaseManager,
                             conversationID: UUID) async throws -> PolicyProbe? {
        let id = conversationID.uuidString
        return try await manager.reader { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT * FROM task_policies WHERE conversation_id = ?",
                arguments: [id]) else { return nil }
            return PolicyProbe(
                approvalMode: row["approval_mode"],
                allowedToolNamesJSON: row["allowed_tool_names_json"],
                filePathsJSON: row["file_paths_json"],
                networkAllowed: row["network_allowed"],
                browserControlAllowed: row["browser_control_allowed"],
                uploadAllowed: row["upload_allowed"],
                credentialsAllowed: row["credentials_allowed"],
                remoteExecutionAllowed: row["remote_execution_allowed"],
                recoveryPolicy: row["recovery_policy"],
                notificationPolicy: row["notification_policy"],
                updatedAt: row["updated_at"])
        }
    }

    // ------------------------------------------------------------ v48 repair

    func testColdOpenRepairMaterializesCanonicalDefaultForOwnedOrdinaryTask() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        try await seedOwnershipWithoutPolicy(manager, conversationID: conversationID)
        // Rewind ONLY the bookkeeping, then let the real registered v48
        // migration run against the broken state — the genuine cold-open path.
        try await rewindBookkeepingToV47(manager)
        let before = try await policyProbe(manager, conversationID: conversationID)
        XCTAssertNil(before)

        try await manager.migrate()

        let repaired = try await policyProbe(manager, conversationID: conversationID)
        let row = try XCTUnwrap(repaired)
        XCTAssertEqual(row.approvalMode, "ask")
        XCTAssertEqual(row.recoveryPolicy, "safePoint")
        XCTAssertEqual(row.notificationPolicy, "stages")
        XCTAssertEqual(row.updatedAt.count, 24) // fractional ISO-8601, decodeable
        // Idempotent cold-open: the migration bookkeeping now holds v48, and
        // a further migrate() repairs nothing and changes nothing.
        let stamp = row.updatedAt
        try await manager.migrate()
        let after = try await policyProbe(manager, conversationID: conversationID)
        let again = try XCTUnwrap(after)
        XCTAssertEqual(again.updatedAt, stamp)
        let applied = try await manager.appliedMigrations()
        XCTAssertTrue(applied.contains("v48_task_policy_convergence"))
        let version = try await manager.userVersion()
        XCTAssertEqual(version, 48)
    }

    func testColdOpenRepairPreservesExistingNonDefaultPolicyByteForByte() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        try await seedOwnershipWithoutPolicy(manager, conversationID: conversationID)
        let preservedStamp = "2026-10-20T01:02:03.456Z"
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO task_policies (
                        conversation_id, approval_mode, allowed_tool_names_json,
                        file_paths_json, network_allowed, browser_control_allowed,
                        upload_allowed, credentials_allowed, remote_execution_allowed,
                        recovery_policy, notification_policy, updated_at
                    ) VALUES (?, 'fullAccess', '["mcp.fs.read"]', '["/tmp"]',
                              1, 1, 0, 0, 1, 'alwaysRetry', 'critical', ?)
                    """,
                arguments: [conversationID.uuidString, preservedStamp])
        }
        try await rewindBookkeepingToV47(manager)

        try await manager.migrate()

        let probe = try await policyProbe(manager, conversationID: conversationID)
        let row = try XCTUnwrap(probe)
        XCTAssertEqual(row.approvalMode, "fullAccess")
        XCTAssertEqual(row.allowedToolNamesJSON, "[\"mcp.fs.read\"]")
        XCTAssertEqual(row.filePathsJSON, "[\"/tmp\"]")
        XCTAssertEqual(row.networkAllowed, 1)
        XCTAssertEqual(row.browserControlAllowed, 1)
        XCTAssertEqual(row.uploadAllowed, 0)
        XCTAssertEqual(row.credentialsAllowed, 0)
        XCTAssertEqual(row.remoteExecutionAllowed, 1)
        XCTAssertEqual(row.recoveryPolicy, "alwaysRetry")
        XCTAssertEqual(row.notificationPolicy, "critical")
        XCTAssertEqual(row.updatedAt, preservedStamp)
    }

    func testColdOpenRepairSkipsUnownedAndNotesConversations() async throws {
        let manager = try await migrated()
        let unownedOrdinary = UUID()
        let notesOwned = UUID()
        let ownedOrdinary = UUID()
        try await seedConversation(manager, id: unownedOrdinary)
        try await seedConversation(manager, id: notesOwned, purpose: "notes")
        try await seedConversation(manager, id: ownedOrdinary)
        try await seedOwnershipWithoutPolicy(manager, conversationID: notesOwned)
        try await seedOwnershipWithoutPolicy(manager, conversationID: ownedOrdinary)
        try await rewindBookkeepingToV47(manager)

        try await manager.migrate()

        let unownedProbe = try await policyProbe(manager, conversationID: unownedOrdinary)
        XCTAssertNil(unownedProbe)
        let notesProbe = try await policyProbe(manager, conversationID: notesOwned)
        XCTAssertNil(notesProbe)
        let ownedProbe = try await policyProbe(manager, conversationID: ownedOrdinary)
        XCTAssertNotNil(ownedProbe)
    }

    // --------------------------------------------- launch reuse-branch repair

    func testLaunchReuseBranchMaterializesPolicyRowFromLaunchDraftPolicy() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        try await seedOwnershipWithoutPolicy(manager, conversationID: conversationID)

        let launch = SQLiteRunLaunchStore(database: manager)
        _ = try await launch.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "hello",
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(
                approvalMode: .automatic,
                recoveryPolicy: .alwaysRetry,
                notificationPolicy: .critical)))

        let probe = try await policyProbe(manager, conversationID: conversationID)
        let row = try XCTUnwrap(probe)
        XCTAssertEqual(row.approvalMode, "automatic")
        XCTAssertEqual(row.recoveryPolicy, "alwaysRetry")
        XCTAssertEqual(row.notificationPolicy, "critical")
    }

    func testLaunchReuseBranchNeverOverwritesExistingPolicyRow() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        try await seedOwnershipWithoutPolicy(manager, conversationID: conversationID)
        let preservedStamp = "2026-10-21T09:00:00.000Z"
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO task_policies (
                        conversation_id, approval_mode, allowed_tool_names_json,
                        network_allowed, recovery_policy, notification_policy, updated_at
                    ) VALUES (?, 'fullAccess', '["mcp.git.commit"]', 1,
                              'safePoint', 'stages', ?)
                    """,
                arguments: [conversationID.uuidString, preservedStamp])
        }

        let launch = SQLiteRunLaunchStore(database: manager)
        _ = try await launch.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "hello",
            conversationMode: "chat"))

        let probe = try await policyProbe(manager, conversationID: conversationID)
        let row = try XCTUnwrap(probe)
        XCTAssertEqual(row.approvalMode, "fullAccess")
        XCTAssertEqual(row.allowedToolNamesJSON, "[\"mcp.git.commit\"]")
        XCTAssertEqual(row.networkAllowed, 1)
        XCTAssertEqual(row.updatedAt, preservedStamp)
    }

    func testPolicyStampStableAcrossReadsAfterMaterialization() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        try await seedOwnershipWithoutPolicy(manager, conversationID: conversationID)
        let launch = SQLiteRunLaunchStore(database: manager)
        _ = try await launch.prepare(RunLaunchRequest(
            conversationID: conversationID, goal: "hello", conversationMode: "chat"))

        let store = SQLiteWorkspaceStore(database: manager)
        let first = try await store.taskPolicy(conversationID: conversationID)
        let second = try await store.taskPolicy(conversationID: conversationID)
        XCTAssertEqual(first.updatedAt, second.updatedAt)
        XCTAssertEqual(RunWireRevision.taskPolicyVersion(updatedAt: first.updatedAt),
                       RunWireRevision.taskPolicyVersion(updatedAt: second.updatedAt))
        // The CAS identity the App echoes is now a REAL persisted row stamp:
        // identical across reads, so a policy update composed from the
        // snapshot page passes the guard on the first human gesture.
    }

    func testOrphanUsedHeaderRefusalMaterializesNothing() async throws {
        let manager = try await migrated()
        let conversationID = UUID()
        try await seedConversation(manager, id: conversationID)
        // No ownership row at all and no createIntent opt-in: the launch
        // gate refuses exactly like the original code.
        let launch = SQLiteRunLaunchStore(database: manager)
        do {
            _ = try await launch.prepare(RunLaunchRequest(
                conversationID: conversationID, goal: "hello", conversationMode: "chat"))
            XCTFail("orphan header without ownership must refuse the launch")
        } catch {
            // Expected: storageCorrupted("Conversation has no canonical workspace").
        }
        let probe = try await policyProbe(manager, conversationID: conversationID)
        XCTAssertNil(probe)
    }

    // ------------------------------------------------ typed wire vocabulary

    func testTerminalResultCarriesTypedWireCodeAlongsideDiagnostics() async {
        let refused = RunDomainReply.terminalResult(
            for: RunDomainError(.staleRevision, .revisionMismatch))
        XCTAssertEqual(refused.kind, .rejected)
        XCTAssertEqual(refused.detail?["wire"], "staleRevision")
        XCTAssertEqual(refused.detail?["error"], "staleRevision")
        XCTAssertEqual(refused.detail?["reason"], "revisionMismatch")

        let absent = RunDomainReply.terminalResult(
            for: RunDomainError(.staleRevision, .revisionAbsent))
        XCTAssertEqual(absent.detail?["wire"], "staleRevision")

        let missing = RunDomainReply.terminalResult(
            for: RunDomainError(.notFound, .runMissing))
        XCTAssertEqual(missing.kind, .rejected)
        XCTAssertEqual(missing.detail?["wire"], "notFound")

        let storeFailure = RunDomainReply.terminalResult(
            for: RunDomainError(.persistenceUnavailable, .storeReadFailed))
        XCTAssertEqual(storeFailure.kind, .failed)
        XCTAssertEqual(storeFailure.detail?["wire"], "persistenceUnavailable")
        // wireObject members remain intact for diagnostics; no grammar or
        // authority change — the App's frozen detail["wire"] decode now
        // surfaces the typed code instead of the generic outer code.
    }
}
