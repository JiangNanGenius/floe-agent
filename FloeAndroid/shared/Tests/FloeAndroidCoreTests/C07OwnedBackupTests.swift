// SPDX-License-Identifier: MPL-2.0
//
// Authored C07 full-data domain tests. These are source tests for the
// coordinated Android build; the authoring lane cannot compile FloeAndroidCore
// on this host because unrelated C05/C06 targets currently fail under the
// local toolchain. They assert the closed table policy, no-replay state rules
// and wire identity without opening a real database.
import XCTest
import Foundation
import FloeAndroidDataExchange
@testable import FloeAndroidCore

final class C07OwnedBackupTests: XCTestCase {
    func testClosedTablePolicyCoversEveryRequiredGraph() {
        let names = Set(C07OwnedDataPolicy.tableNames)
        for required in [
            "conversations", "messages", "message_parts", "runs",
            "run_events", "tool_calls", "attachments", "providers", "models",
            "workspaces", "task_schedules", "task_schedule_occurrences",
            "conversation_goals", "goal_events", "user_question_requests",
            "user_questions",
        ] {
            XCTAssertTrue(names.contains(required), required)
        }
        XCTAssertFalse(names.contains("credentials"))
        XCTAssertFalse(names.contains("approval_grants"))
        XCTAssertFalse(names.contains("hosts"))
        XCTAssertFalse(names.contains("known_hosts"))
        XCTAssertFalse(names.contains("audit_entries"))
        XCTAssertFalse(names.contains("checkpoints"))
        XCTAssertEqual(C07OwnedDataPolicy.evidenceTableNames.count, 4)
        XCTAssertTrue(C07OwnedDataPolicy.evidenceTableNames.contains(
            "task_execution_targets"))
        XCTAssertTrue(C07OwnedDataPolicy.evidenceTableNames.contains(
            "task_remote_command_receipts"))
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
}
