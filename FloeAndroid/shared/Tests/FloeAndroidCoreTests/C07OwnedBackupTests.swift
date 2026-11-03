// SPDX-License-Identifier: MPL-2.0
//
// Authored C07 full-data domain tests. These are source tests for the
// coordinated Android build; the authoring lane cannot compile FloeAndroidCore
// on this host because unrelated C05/C06 targets currently fail under the
// local toolchain. They assert the closed table policy, no-replay state rules
// and wire identity without opening a real database.
import XCTest
import Foundation
import Crypto
import GRDB
import FloePersistence
import FloeAndroidDataExchange
import FloeAndroidToolResults
@testable import FloeAndroidCore

final class C07OwnedBackupTests: XCTestCase {
    func testClosedTablePolicyCoversEveryRequiredGraph() {
        let names = Set(C07OwnedDataPolicy.tableNames)
        for required in [
            "conversations", "messages", "message_parts", "runs",
            "run_events", "tool_calls", "attachments", "providers", "models",
            "task_schedules", "task_schedule_occurrences", "calendar_todos",
            "conversation_goals", "goal_events", "user_question_requests",
            "user_questions",
        ] {
            XCTAssertTrue(names.contains(required), required)
        }
        // Workspace rows are carried by `C07WorkspaceDescriptor`, not the
        // logical table policy; the closed graph still must not contain the
        // live credential/trust tables.
        XCTAssertFalse(names.contains("workspaces"))
        XCTAssertFalse(names.contains("credentials"))
        XCTAssertFalse(names.contains("approval_grants"))
        XCTAssertFalse(names.contains("hosts"))
        XCTAssertFalse(names.contains("known_hosts"))
        XCTAssertFalse(names.contains("audit_entries"))
        XCTAssertFalse(names.contains("checkpoints"))
        // Four C02 execution-evidence tables plus the 2026-11-02
        // run_dependencies recovery evidence. Live user-data tables joined
        // the graph in the same expansion.
        XCTAssertEqual(C07OwnedDataPolicy.evidenceTableNames.count, 5)
        XCTAssertTrue(C07OwnedDataPolicy.evidenceTableNames.contains(
            "task_execution_targets"))
        XCTAssertTrue(C07OwnedDataPolicy.evidenceTableNames.contains(
            "task_remote_command_receipts"))
        XCTAssertTrue(C07OwnedDataPolicy.evidenceTableNames.contains(
            "run_dependencies"))
        for userData in ["memory_entries", "memory_candidates",
                         "personalization_documents", "skills",
                         "model_preferences", "task_checklist_revisions"] {
            XCTAssertTrue(names.contains(userData), userData)
            XCTAssertEqual(C07OwnedDataPolicy.policy(for: userData)?.disposition,
                           .live, userData)
        }
    }

    func testEvidenceTablesAreNeverLiveRestoreTargets() {
        for name in C07OwnedDataPolicy.evidenceTableNames {
            guard let policy = C07OwnedDataPolicy.policy(for: name) else {
                XCTFail("missing policy \(name)"); continue
            }
            XCTAssertEqual(policy.disposition, .evidenceArchive, name)
            XCTAssertTrue(policy.optional, name)
        }
        for name in ["conversations", "runs", "task_schedules"] {
            XCTAssertEqual(C07OwnedDataPolicy.policy(for: name)?.disposition,
                           .live)
        }
    }

    func testWireVersionAndSchemaAreStableForV16() {
        XCTAssertEqual(C07DataExchangeWire.version, 16)
        XCTAssertEqual(C07DataExchangeWire.schema, "floe.data/16")
        XCTAssertEqual(C07DataExchangeWire.maximumChunkBytes, 24_576)
        XCTAssertFalse(C07BackupScope.includedIDs.contains("credentials"))
        XCTAssertTrue(C07BackupScope.includedIDs.contains("canvasMediaDocuments"))
        XCTAssertTrue(C07BackupScope.includedIDs.contains("savedSchedules"))
    }

    func testOwnerRequiresNonEmptyTokenAndEpoch() throws {
        XCTAssertThrowsError(try C07ExchangeOwner(token: "short", nativeEpoch: 1))
        XCTAssertThrowsError(try C07ExchangeOwner(
            token: String(repeating: "a", count: 8), nativeEpoch: 0))
        let owner = try C07ExchangeOwner(
            token: String(repeating: "a", count: 8), nativeEpoch: 42)
        XCTAssertEqual(owner.nativeEpoch, 42)
    }

    func testNoReplayRowsCannotStayExecutable() {
        let run: C07DBRow = [
            "id": .string(UUID().uuidString),
            "conversation_id": .string(UUID().uuidString),
            "state": .string("waitingApproval"),
            "goal": .string("x"),
            "started_at": .string("2026-01-01T00:00:00Z"),
        ]
        XCTAssertEqual(C07OwnedDataPolicy.restoredRow(
            table: "runs", row: run)["state"]?.stringValue, "interrupted")
        let schedule: C07DBRow = [
            "id": .string(UUID().uuidString),
            "is_enabled": .int(1),
            "policy_json": .string(#"{"approval":"auto"}"#),
        ]
        XCTAssertEqual(C07OwnedDataPolicy.restoredRow(
            table: "task_schedules", row: schedule)["is_enabled"]?.integerValue, 0)
        let question: C07DBRow = [
            "question_id": .string("q"),
            "status": .string("pending"),
        ]
        XCTAssertEqual(C07OwnedDataPolicy.restoredRow(
            table: "user_questions", row: question)["status"]?.stringValue,
                       "expired")
    }

    // MARK: - Coverage / tool-result / reminder regressions

    func testCalendarTodosBecomeRequiredOnlyFromCoordinatedSchema52() {
        XCTAssertFalse(C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: 51).contains("calendar_todos"))
        XCTAssertTrue(C07OwnedDataPolicy.mandatoryTableNames(
            forSchema: 52).contains("calendar_todos"))
        let policy = C07OwnedDataPolicy.policy(for: "calendar_todos")
        XCTAssertEqual(policy?.disposition, .live)
        XCTAssertFalse(policy?.isExpected(at: 51) ?? true)
        XCTAssertTrue(policy?.isExpected(at: 52) ?? false)
        XCTAssertTrue(policy?.requiredColumns(at: 52)
            .contains("reminders_suspended") ?? false)
        XCTAssertFalse(policy?.requiredColumns(at: 51)
            .contains("reminders_suspended") ?? true)
    }

    func testRestoredTodoSuspendsReminderButKeepsContentDueAndCompletion() {
        let row: C07DBRow = [
            "id": .string(UUID().uuidString),
            "title": .string("Buy milk"),
            "notes": .string("2 litres"),
            "due_at": .string("2026-11-03T09:00:00Z"),
            "completed": .int(1),
            "reminder_minutes_before": .int(30),
            "revision": .int(4),
            "owner_environment_id": .string(UUID().uuidString),
            "reminders_suspended": .int(0),
        ]
        let restored = C07OwnedDataPolicy.restoredRow(
            table: "calendar_todos", row: row)
        XCTAssertEqual(restored["reminders_suspended"]?.integerValue, 1)
        XCTAssertEqual(restored["reminder_minutes_before"]?.integerValue, 30)
        XCTAssertEqual(restored["due_at"]?.stringValue, "2026-11-03T09:00:00Z")
        XCTAssertEqual(restored["completed"]?.integerValue, 1)
        XCTAssertEqual(restored["title"]?.stringValue, "Buy milk")
        XCTAssertEqual(restored["owner_environment_id"], .null)
    }

    func testToolResultCheckpointRewriteUsesTheRestoredRefAndDropsStaleLinks() throws {
        let oldRun = UUID()
        let oldTask = UUID()
        let newRun = UUID()
        let newTask = UUID()
        let newCall = UUID().uuidString
        let oldCall = UUID().uuidString
        let newRef = ToolResultCaptureStore.reference(
            runID: newRun, callID: newCall)
        let oldRef = ToolResultCaptureStore.reference(
            runID: oldRun, callID: oldCall)
        let entry = C07ToolResultPlanEntry(
            oldTaskID: oldTask, oldRunID: oldRun, oldCallID: oldCall,
            newTaskID: newTask, newRunID: newRun, newCallID: newCall,
            newRef: newRef, byteCount: 12,
            sha256: String(repeating: "a", count: 64), originalDigest: nil)
        let payload = """
        {"tool":"exec.shell","id":"\(oldCall)","status":"ok",
         "summary":"done ref=\(oldRef)","outputDigest":"\(String(repeating: "b", count: 64))",
         "artifactRefsJSON":"[{\"relativePath\":\"GeneratedImages/x.png\"}]",
         "outputFilesJSON":"[{\"displayName\":\"x\"}]"}
        """
        let rewritten = try C07ToolResultReceipt.rewrite(
            payload, oldRunID: oldRun.uuidString, oldCallID: oldCall,
            entries: [entry])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rewritten.utf8))
                as? [String: Any])
        XCTAssertEqual(object["id"] as? String, newCall)
        XCTAssertEqual(object["captureRef"] as? String, newRef)
        XCTAssertEqual(object["captureBytes"] as? Int, 12)
        XCTAssertNil(object["artifactRefsJSON"])
        XCTAssertNil(object["outputFilesJSON"])
        let captureInfo = try XCTUnwrap(object["captureInfo"] as? [String: Any])
        XCTAssertEqual(captureInfo["ref"] as? String, newRef)
        XCTAssertEqual(captureInfo["available"] as? Bool, true)
        let summary = try XCTUnwrap(object["summary"] as? String)
        XCTAssertTrue(summary.contains(newRef))
        XCTAssertFalse(summary.contains(oldRef))
    }

    func testToolResultCheckpointWithoutCarriedBytesIsMarkedUnavailable() throws {
        let oldRun = UUID()
        let oldCall = UUID().uuidString
        let oldRef = ToolResultCaptureStore.reference(
            runID: oldRun, callID: oldCall)
        let payload = """
        {"tool":"exec.shell","id":"\(oldCall)","status":"ok","summary":"ref=\(oldRef)"}
        """
        let rewritten = try C07ToolResultReceipt.rewrite(
            payload, oldRunID: oldRun.uuidString, oldCallID: oldCall,
            entries: [])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rewritten.utf8))
                as? [String: Any])
        let summary = try XCTUnwrap(object["summary"] as? String)
        XCTAssertFalse(summary.contains(oldRef))
        XCTAssertTrue(summary.contains("ref=unavailable"))
        XCTAssertEqual(object["captureUnavailable"] as? Bool, true)
        let captureInfo = try XCTUnwrap(object["captureInfo"] as? [String: Any])
        XCTAssertEqual(captureInfo["available"] as? Bool, false)
    }

    func testRetainedToolResultsRestoreWithNewIdsAndStableReadback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "c07-toolresults-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolResultCaptureStore(
            durableRoot: root, caps: .durableStandard)
        let oldTask = UUID()
        let oldRun = UUID()
        let oldCall = UUID().uuidString
        let text = "line one\nline two\n"
        let receipt = await store.capture(
            conversationID: oldTask, runID: oldRun, callID: oldCall,
            toolName: "exec.shell", status: "ok", text: text,
            temporary: false)
        XCTAssertEqual(receipt.outcome, .retained)
        XCTAssertEqual(receipt.durability, .durable)

        let export = await ToolResultBackupExchange.export(
            store: store, storeRoot: root, conversationID: oldTask)
        XCTAssertEqual(export.records.count, 1)
        XCTAssertEqual(export.excludedUnreadable, 0)
        let record = try XCTUnwrap(export.records.first)
        XCTAssertEqual(record.runID, oldRun)
        XCTAssertEqual(record.callID, oldCall)

        let newTask = UUID()
        let newRun = UUID()
        let newCall = UUID().uuidString
        let restored = try await ToolResultBackupExchange.restore(
            records: [record], store: store,
            destinationTaskID: newTask,
            runMap: [oldRun: newRun], callMap: [oldCall: newCall])
        let verified = try await ToolResultBackupExchange.verifyReadback(
            receipts: restored, store: store, conversationID: newTask)
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified.first?.sha256, record.sha256)
        XCTAssertTrue(verified.first?.readbackVerified == true)
        let newRef = ToolResultCaptureStore.reference(
            runID: newRun, callID: newCall)
        XCTAssertEqual(verified.first?.ref, newRef)
        XCTAssertNotEqual(newRef, ToolResultCaptureStore.reference(
            runID: oldRun, callID: oldCall))
        let readback = await store.retainedCapture(
            conversationID: newTask, ref: newRef)
        XCTAssertEqual(readback?.text, text)
        XCTAssertEqual(readback?.sha256, record.sha256)

        // An unmapped call is never written under a guessed identity.
        do {
            _ = try await ToolResultBackupExchange.restore(
                records: [record], store: store,
                destinationTaskID: newTask, runMap: [:], callMap: [:])
            XCTFail("expected identityMissing")
        } catch let error as ToolResultBackupExchangeError {
            guard case .identityMissing = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testToolResultBackupRecordRejectsByteOrDigestMismatch() throws {
        let data = Data("hello".utf8)
        let valid = ToolResultBackupRecord(
            taskID: UUID(), runID: UUID(), callID: "c", toolName: "t",
            status: "ok", textBase64: data.base64EncodedString(),
            byteCount: data.count,
            sha256: data.map { String(format: "%02x", $0) }.joined(),
            originalDigest: nil, executionReportedTruncation: false,
            retentionTruncated: false, capturedAt: Date())
        XCTAssertThrowsError(try valid.validate())
        var fixed = valid
        fixed.sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try fixed.validate())
        var corrupt = fixed
        corrupt.byteCount += 1
        XCTAssertThrowsError(try corrupt.validate())
    }


    func testContinuityExecutionControlIsNeverBackedUpOrRestored() {
        let names = Set(C07OwnedDataPolicy.tableNames)
        XCTAssertFalse(names.contains("task_continuity_pauses"))
        XCTAssertFalse(names.contains("run_stream_checkpoints"))
        XCTAssertFalse(names.contains("checkpoints"))
        XCTAssertTrue(C07ScopePolicy.excluded.contains {
            $0.id == "taskContinuityExecutionControl"
        })
        // Nonterminal historical work is preserved as interrupted history,
        // never as a resumable pause marker, root fingerprint or CAS claim.
        for state in ["paused", "resumeInProgress", "waitingApproval",
                      "executingTool", "checkpointedActive"] {
            let row: C07DBRow = [
                "id": .string(UUID().uuidString),
                "conversation_id": .string(UUID().uuidString),
                "state": .string(state),
                "goal": .string("x"),
                "started_at": .string("2026-01-01T00:00:00Z"),
            ]
            let restored = C07OwnedDataPolicy.restoredRow(
                table: "runs", row: row)
            XCTAssertEqual(restored["state"]?.stringValue, "interrupted", state)
            XCTAssertNil(restored["root_fingerprint"])
            XCTAssertNil(restored["resume_marker"])
            XCTAssertNil(restored["resume_in_progress"])
        }
    }

    // MARK: - User-data restore adapters (real in-memory schema)

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    func testPersonalizationDocumentsRenumberAboveTargetAndKeepActiveSlot() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            // Target already has an active global soul at revision 10.
            try db.execute(sql: """
                INSERT INTO personalization_documents (
                    id, kind, workspace_id, revision, content, source_kind,
                    evidence_digest, is_active, created_at
                ) VALUES (?, 'soul', NULL, 10, 'current soul', 'user', '', 1, ?)
                """, arguments: [UUID().uuidString, "2026-01-01T00:00:00.000Z"])
            var receipt = C07OwnedDataCommitReceipt()
            var warnings: [String] = []
            for (revision, active, text) in [(1, 0, "old soul"),
                                             (2, 1, "newer soul")] {
                let values: C07DBRow = [
                    "id": .string(UUID().uuidString),
                    "kind": .string("soul"),
                    "revision": .int(Int64(revision)),
                    "content": .string(text),
                    "source_kind": .string("user"),
                    "evidence_digest": .string(""),
                    "is_active": .int(Int64(active)),
                    "created_at": .string("2026-06-01T00:00:00.000Z"),
                ]
                try C07UserDataAdapters.commitRow(
                    table: "personalization_documents", values: values,
                    restoreID: UUID(), db: db, receipt: &receipt,
                    warnings: &warnings)
            }
            XCTAssertEqual(receipt.personalizationDocuments, 2)
            let rows = try Row.fetchAll(db, sql: """
                SELECT revision, content, is_active FROM personalization_documents
                WHERE kind = 'soul' AND workspace_id IS NULL ORDER BY revision
                """)
            XCTAssertEqual(rows.map { $0["revision"] as Int? }, [10, 11, 12])
            XCTAssertEqual(rows.map { $0["is_active"] as Int? }, [1, 0, 0])
            // The pre-existing active document stays active; the restored
            // history is preserved in order above it.
            XCTAssertEqual(rows[2]["content"] as String?, "newer soul")
            XCTAssertTrue(warnings.contains(
                "personalizationKeptCurrentActive:soul"))
        }
    }

    func testPersonalizationDocumentBecomesActiveWhenSlotIsEmpty() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            var receipt = C07OwnedDataCommitReceipt()
            var warnings: [String] = []
            let values: C07DBRow = [
                "id": .string(UUID().uuidString),
                "kind": .string("userProfile"),
                "revision": .int(4),
                "content": .string("restored profile"),
                "source_kind": .string("user"),
                "evidence_digest": .string(""),
                "is_active": .int(1),
                "created_at": .string("2026-06-01T00:00:00.000Z"),
            ]
            try C07UserDataAdapters.commitRow(
                table: "personalization_documents", values: values,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            let row = try Row.fetchOne(db, sql: """
                SELECT revision, is_active FROM personalization_documents
                WHERE kind = 'userProfile' AND workspace_id IS NULL
                """)
            XCTAssertEqual(row?["revision"] as Int?, 4)
            XCTAssertEqual(row?["is_active"] as Int?, 1)
            XCTAssertEqual(receipt.personalizationDocuments, 1)
        }
    }

    func testSkillRestoreIsDisabledReferenceAndNameConflictSurvives() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            // Existing same-name skill with different content.
            try db.execute(sql: """
                INSERT INTO skills (
                    id, name, version, status, skill_markdown, manifest_json,
                    declared_capabilities_json, effective_capabilities_json,
                    source_url, source_digest, rewritten_digest,
                    rewrite_model_id, compatibility_report_json,
                    created_at, updated_at
                ) VALUES (?, 'Local Skill', '1', 'enabled', '# Local', '{}',
                          '[]', '["files.read"]', NULL, NULL,
                          'cc00000000000000000000000000000000000000000000000000000000000000',
                          NULL, '{}', ?, ?)
                """, arguments: [
                    UUID().uuidString, "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:00:00.000Z",
                ])
            var receipt = C07OwnedDataCommitReceipt()
            var warnings: [String] = []
            let restoredValues: C07DBRow = [
                "id": .string(UUID().uuidString),
                "name": .string("local skill"),
                "version": .string("2"),
                "status": .string("enabled"),
                "skill_markdown": .string("# Restored\nDifferent body."),
                "manifest_json": .string(#"{"name":"Local Skill"}"#),
                "declared_capabilities_json": .string("[]"),
                "effective_capabilities_json": .string("[]"),
                "source_url": .string("https://example.invalid/s.tgz"),
                "source_digest": .string("dd" + String(repeating: "0", count: 62)),
                "rewritten_digest": .string("ee" + String(repeating: "0", count: 62)),
                "compatibility_report_json": .string("{}"),
                "created_at": .string("2026-06-01T00:00:00.000Z"),
                "updated_at": .string("2026-06-01T00:00:00.000Z"),
            ]
            try C07UserDataAdapters.commitRow(
                table: "skills", values: restoredValues,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            XCTAssertEqual(receipt.skills, 1)
            XCTAssertTrue(warnings.contains("skillNameRestored:local skill"))
            let rows = try Row.fetchAll(
                db, sql: "SELECT name, status, skill_markdown FROM skills")
            XCTAssertEqual(rows.count, 2)
            let restored = try XCTUnwrap(rows.first {
                ($0["skill_markdown"] as String?)
                    == "# Restored\nDifferent body."
            })
            XCTAssertEqual(restored["name"] as String?, "local skill (restored)")
            XCTAssertEqual(restored["status"] as String?, "disabled")
            // No capability grant rows are ever written by the restore.
            let grants = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM skill_permissions") ?? 0
            XCTAssertEqual(grants, 0)

            // Byte-identical definition de-duplicates instead of restoring.
            let identical: C07DBRow = [
                "id": .string(UUID().uuidString),
                "name": .string("local skill"),
                "version": .string("1"),
                "status": .string("enabled"),
                "skill_markdown": .string("# Local"),
                "manifest_json": .string("{}"),
                "declared_capabilities_json": .string("[]"),
                "effective_capabilities_json": .string("[]"),
                "source_url": .null,
                "source_digest": .null,
                "rewritten_digest": .string("cc" + String(repeating: "0", count: 62)),
                "compatibility_report_json": .string("{}"),
                "created_at": .string("2026-06-01T00:00:00.000Z"),
                "updated_at": .string("2026-06-01T00:00:00.000Z"),
            ]
            try C07UserDataAdapters.commitRow(
                table: "skills", values: identical,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            XCTAssertEqual(receipt.skills, 1)
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM skills") ?? 0, 2)
        }
    }

    func testModelPreferencesMergeFillsUnsetRoutesButKeepsLocalChoices() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            let localModel = UUID().uuidString
            let restoredModel = UUID().uuidString
            let visionModel = UUID().uuidString
            // Local user has already chosen a default agent and onboarding.
            try db.execute(sql: """
                INSERT INTO model_preferences (
                    id, onboarding_status, default_agent_model_id,
                    auxiliary_image_mode, updated_at, sync_revision
                ) VALUES ('default', 'seen', ?, 'separate',
                          '2026-01-01T00:00:00.000Z', 4)
                """, arguments: [localModel])
            var receipt = C07OwnedDataCommitReceipt()
            var warnings: [String] = []
            let values: C07DBRow = [
                "id": .string("default"),
                "onboarding_status": .string("seen"),
                "default_agent_model_id": .string(restoredModel),
                "vision_model_id": .string(visionModel),
                "auxiliary_image_mode": .string("shared"),
                "updated_at": .string("2026-06-01T00:00:00.000Z"),
                "sync_revision": .int(0),
            ]
            try C07UserDataAdapters.commitRow(
                table: "model_preferences", values: values,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            XCTAssertEqual(receipt.modelPreferences, 1)
            let row = try XCTUnwrap(Row.fetchOne(
                db, sql: "SELECT * FROM model_preferences WHERE id = 'default'"))
            // Explicit local default survives; unset vision route is filled.
            XCTAssertEqual(row["default_agent_model_id"] as String?, localModel)
            XCTAssertEqual(row["vision_model_id"] as String?, visionModel)
            XCTAssertEqual(row["onboarding_status"] as String?, "seen")
            XCTAssertEqual(row["auxiliary_image_mode"] as String?, "separate")
            XCTAssertEqual(row["sync_revision"] as Int64?, 5)
            XCTAssertTrue(warnings.contains(
                "modelPreferencesExistingKept:default_agent_model_id"))

            // A factory-fresh target adopts the restored routes wholesale.
            try db.execute(sql: "DELETE FROM model_preferences WHERE id = 'default'")
            try db.execute(sql: """
                INSERT INTO model_preferences (
                    id, onboarding_status, auxiliary_image_mode,
                    updated_at, sync_revision
                ) VALUES ('default', 'unseen', 'shared',
                          '1970-01-01T00:00:00.000Z', 0)
                """)
            warnings.removeAll()
            try C07UserDataAdapters.commitRow(
                table: "model_preferences", values: values,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            let fresh = try XCTUnwrap(Row.fetchOne(
                db, sql: "SELECT * FROM model_preferences WHERE id = 'default'"))
            XCTAssertEqual(fresh["default_agent_model_id"] as String?,
                           restoredModel)
            XCTAssertEqual(fresh["vision_model_id"] as String?, visionModel)
            XCTAssertEqual(fresh["onboarding_status"] as String?, "seen")
        }
    }

    func testPersonalizationCursorInsertsOnlyWhenAbsent() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO personalization_update_cursors (
                    kind, workspace_key, workspace_id,
                    automatic_updates_enabled, last_generated_at,
                    completed_runs_since_update, user_messages_since_update,
                    updated_at
                ) VALUES ('soul', '', NULL, 0, '2026-05-01T00:00:00.000Z',
                          9, 9, '2026-05-01T00:00:00.000Z')
                """)
            var receipt = C07OwnedDataCommitReceipt()
            var warnings: [String] = []
            // Same key already exists: kept, never overwritten.
            let existing: C07DBRow = [
                "kind": .string("soul"),
                "workspace_key": .string(""),
                "automatic_updates_enabled": .int(1),
                "completed_runs_since_update": .int(0),
                "user_messages_since_update": .int(0),
                "updated_at": .string("2026-06-01T00:00:00.000Z"),
            ]
            try C07UserDataAdapters.commitRow(
                table: "personalization_update_cursors", values: existing,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            XCTAssertEqual(receipt.personalizationCursors, 0)
            let kept = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT automatic_updates_enabled, completed_runs_since_update
                    FROM personalization_update_cursors
                    WHERE kind = 'soul' AND workspace_key = ''
                    """))
            XCTAssertEqual(kept["automatic_updates_enabled"] as Int?, 0)
            XCTAssertEqual(kept["completed_runs_since_update"] as Int?, 9)

            // A new workspace-scoped key is inserted with the user toggle.
            let workspace = UUID().uuidString
            let inserted: C07DBRow = [
                "kind": .string("userProfile"),
                "workspace_key": .string(workspace),
                "workspace_id": .string(workspace),
                "automatic_updates_enabled": .int(1),
                "completed_runs_since_update": .int(0),
                "user_messages_since_update": .int(0),
                "updated_at": .string("2026-06-01T00:00:00.000Z"),
            ]
            try C07UserDataAdapters.commitRow(
                table: "personalization_update_cursors", values: inserted,
                restoreID: UUID(), db: db, receipt: &receipt,
                warnings: &warnings)
            XCTAssertEqual(receipt.personalizationCursors, 1)
            let row = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT workspace_key, automatic_updates_enabled,
                           last_generated_at
                    FROM personalization_update_cursors
                    WHERE kind = 'userProfile' AND workspace_key = ?
                    """, arguments: [workspace]))
            XCTAssertEqual(row["automatic_updates_enabled"] as Int?, 1)
            XCTAssertTrue((row["last_generated_at"] as String?) == nil)
        }
    }
}
