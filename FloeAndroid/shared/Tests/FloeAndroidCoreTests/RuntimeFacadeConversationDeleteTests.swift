// SPDX-License-Identifier: MPL-2.0
//
// RB-3 conversation.delete — destructive ORDERING, ownership fences and
// durable-queue recoverability over the REAL original stores on a file-backed
// schema-46 database (private source candidate; AUTHORED, NOT executed by
// this package).
//
// Main review corrections (2026-10-19) proved here:
// * CH-R1 — the expected raw-row/purpose CAS + original memory preservation
//   + original RunLifecycleRetention/cascades/V11/V36 DELETE run in ONE
//   DatabaseManager writer transaction. An external writer after admission
//   is refused before memory is reclassified; a DB-level rollback keeps the
//   conversation, messages, memory and spool artifact intact.
// * CH-R2 — deletion A is gated ONLY by A's exact owned-work tokens
//   (`isAttached` evidence) and A's pending launches. An unrelated active
//   conversation B, and the GLOBAL epoch counts it contributes, neither
//   block nor get cancelled by deleting A.
// * CH-R3 — operation-owned fence begin/drain/commit/abort on every exit;
//   cancellation/error/stale paths abort the exact token; a surviving
//   conversation can retry after its real owned work settles; an old abort
//   cannot clear a newer guard; a foreign token is refused; post-commit
//   settlement is reported honestly.
//
// These methods are AUTHORED, NOT RUN. No compiler or XCTest execution is
// claimed by this lane.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadeConversationDeleteTests: XCTestCase {

    private func revision(_ bundle: RB3TestBed.DomainBundle, _ id: UUID) async throws -> BaseRevision {
        try await RB3TestBed.revision(bundle.stores.database, id)
    }

    // MARK: Fail-closed dependency gates

    func testDeleteWithoutRealLifecycleFailsClosedZeroEffect() async throws {
        let stores = try await RB3TestBed.stores()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "kept")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "body")
        let rev = try await revision(bundle, record.id)
        do {
            _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
            XCTFail("delete must fail closed without the real RB4 lifecycle")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
            XCTAssertEqual(error.wireReason, "conversationDeletionLifecycleUnregistered")
        }
        let __xctestHoist1 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNotNil(__xctestHoist1)
        let __xctestHoist2 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist2, 1)
        let __xctestHoist3 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist3, 0)
        let __xctestHoist4 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(__xctestHoist4, 0)
    }

    func testAntiFakeZeroRegistryCountsRefuseBeforeAnyDestructiveWrite() async throws {
        // Every scenario must refuse BEFORE memory preservation or any
        // destructive write. The corrected contract no longer treats the
        // GLOBAL counts as a per-conversation gate; the hard evidence is the
        // target token list + pending launches. Missing evidence is still a
        // hard refusal (no default fake zero).
        let scenarios = ["absentCounts", "absentEvidence", "absentPending",
                         "pending", "foreignEpoch", "stillAttached", "negative"]
        for scenario in scenarios {
            let stores = try await RB3TestBed.stores()
            let lifecycle = ScriptedLifecycle()
            let record = try await RB3TestBed.seedOrdinary(stores, title: "guarded")
            try await stores.database.writer { db in
                try Self.insertMemoryFixture(db, conversationID: record.id)
            }
            switch scenario {
            case "absentCounts":
                lifecycle.countsProvider = { _ in nil }
            case "absentEvidence":
                lifecycle.reportOverride = { fence in
                    ConversationQuiescenceReport(
                        conversationID: fence.conversationID,
                        launchesFenced: true,
                        endCountsByKind: ScriptedLifecycle.drainedCounts(),
                        countsEpoch: fence.epoch,
                        targetOwnedWork: nil,
                        pendingLaunchCount: 0)
                }
            case "absentPending":
                lifecycle.pendingLaunchProvider = { _ in nil }
            case "pending":
                lifecycle.pendingLaunchProvider = { _ in 2 }
            case "foreignEpoch":
                lifecycle.echoExpectedEpoch = false
            case "stillAttached":
                lifecycle.attachOwnedWork(conversationID: record.id, kind: .run, epoch: 1)
                lifecycle.detachTargetOnDrain = false
            default:
                lifecycle.countsProvider = { _ in
                    ["run": -1, "childRun": 0, "tool": 0, "conversation": 0]
                }
            }
            let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
            let rev = try await revision(bundle, record.id)
            do {
                _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
                XCTFail("unverified quiescence (\(scenario)) must refuse")
            } catch let error as ConversationDomainError {
                switch scenario {
                case "absentCounts":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "ownedWorkCountsAbsent")
                case "absentEvidence":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "targetOwnedWorkEvidenceAbsent")
                case "absentPending":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "pendingLaunchEvidenceAbsent")
                case "pending":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "pendingLaunchesNotDrained")
                case "foreignEpoch":
                    XCTAssertEqual(error.wireCode, "sessionFenced")
                    XCTAssertEqual(error.wireReason, "quiescenceEpochMismatch")
                case "stillAttached":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "ownedWorkNotDrained:run")
                default:
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "ownedWorkCountNegative")
                }
            }
            let __xctestHoist5 = try await stores.conversations.conversation(id: record.id)
            XCTAssertNotNil(__xctestHoist5, scenario)
            let memory = try await Self.memoryFields(stores.database, conversationID: record.id)
            XCTAssertEqual(memory.conversationID, record.id.uuidString,
                           "refused delete must not reach the memory reclassification")
            XCTAssertNil(memory.originOwnerLabel, "\(scenario): memory must be untouched")
            XCTAssertNil(memory.ownerDeletedAt, "\(scenario): memory must be untouched")
            XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1,
                           "\(scenario): every pre-commit exit must abort the exact fence")
            XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("commit:") }.count, 0)
        }
    }

    // MARK: Ordering + real cascades

    func testDeleteOrderingFenceThenDrainThenOriginalCascade() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let drain = RecordingCredentialDrain(database: stores.database)
        let cleaning = try TempWorkspaceCleaning()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle,
                                           credentialDrain: drain,
                                           workspaceCleaning: cleaning)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "order test")

        // Owned durable state across the whole original graph.
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "hello")
        let runID = UUID()
        try await RB3TestBed.seedRun(stores.database, conversationID: record.id, id: runID)
        try await RB3TestBed.seedPendingInput(stores, conversationID: record.id, content: "queued")
        try await stores.database.writer { db in
            try Self.insertMemoryFixture(db, conversationID: record.id)
            // V46 lifecycle rows WITHOUT foreign keys — only the ORIGINAL
            // deleteConversation (RunLifecycleRetention) clears these.
            try db.execute(sql: """
                INSERT INTO child_runs (id, parent_run_id, root_run_id, conversation_id,
                    child_index, kind, task_summary, state, iteration_count,
                    started_at, updated_at)
                VALUES (?, ?, ?, ?, 0, 'delegate', 'synthetic', 'running', 0, 'x', 'x')
                """, arguments: [UUID().uuidString, runID.uuidString, runID.uuidString,
                                 record.id.uuidString])
            try db.execute(sql: """
                INSERT INTO run_dependencies (job_id, run_id, conversation_id, kind, state, created_at)
                VALUES (?, ?, ?, 'job', 'pending', 'x')
                """, arguments: [UUID().uuidString, runID.uuidString, record.id.uuidString])
            // Conversation-owned credential metadata (V11 queue trigger).
            try db.execute(sql: """
                INSERT INTO credential_records (id, kind, owner_kind, conversation_id,
                    label, keychain_account, synchronizable, device_bound,
                    created_at, updated_at)
                VALUES (?, 'genericToken', 'conversation', ?, 'token', 'acorder1',
                    0, 0, 'x', 'x')
                """, arguments: [UUID().uuidString, record.id.uuidString])
        }
        // Private-task workspace + on-disk directory through the ORIGINAL
        // ensureWorkspace primitive (V8 columns; V36 trigger path).
        _ = try await stores.workspaces.ensureWorkspace(conversationID: record.id,
                                                        title: "order test")
        let workspaceURL = try cleaning.seedPrivateTaskDirectory(conversationID: record.id)

        let rev = try await revision(bundle, record.id)
        let reply = try await bundle.domain.delete(conversationID: record.id, revision: rev)

        // ORDERING: begin strictly before drain, drain end strictly before
        // commit; exactly one begin and exactly one commit; no abort.
        let events = lifecycle.events
        guard let beginIndex = events.firstIndex(where: { $0.hasPrefix("begin:") }),
              let drainStart = events.firstIndex(where: { $0.hasPrefix("drainStart:") }),
              let drainEnd = events.firstIndex(where: { $0.hasPrefix("drainEnd:") }),
              let commitIndex = events.firstIndex(where: { $0.hasPrefix("commit:") }) else {
            return XCTFail("lifecycle events missing: \(events)")
        }
        XCTAssertLessThan(beginIndex, drainStart)
        XCTAssertLessThan(drainStart, drainEnd)
        XCTAssertLessThan(drainEnd, commitIndex)
        XCTAssertEqual(events.filter { $0.hasPrefix("begin:") }.count, 1)
        XCTAssertEqual(events.filter { $0.hasPrefix("commit:") }.count, 1)
        XCTAssertTrue(events.filter { $0.hasPrefix("abort:") }.isEmpty)
        XCTAssertEqual(reply.fenceSettlement, .released)

        // ORIGINAL DB delete + real cascades.
        let __xctestHoist6 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist6)
        let __xctestHoist7 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist7, 0, "FK cascade")
        let __xctestHoist8 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist8, 0)
        let __xctestHoist9 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM pending_user_inputs WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist9, 0)
        let __xctestHoist10 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM child_runs WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist10, 0,
            "proves the ORIGINAL RunLifecycleRetention path ran, not a bare DELETE")
        let __xctestHoist11 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM run_dependencies WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist11, 0)
        // Durable memory preserved (reclassified), NOT silently deleted.
        let __xctestHoist12 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM memory_entries WHERE origin_conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist12, 1)
        let liveMemories = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM memory_entries WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(liveMemories, 0, "same-writer memory preservation ran first")

        // Credential intent: queue row existed via the trigger and was then
        // drained by the bound vault double exactly once.
        let __xctestHoist13 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist13, 0)
        let __xctestHoist1 = await drain.calls()
        XCTAssertEqual(__xctestHoist1, 1)
        XCTAssertEqual(reply.credentialDrain,
                       ConversationCredentialDrainStatus.drained(
                            CredentialDeletionDrainSummary(drained: 1, deferredCount: 0,
                                                           failedCount: 0)))

        // Private-task workspace files + durable queue bookkeeping done.
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceURL.path))
        let __xctestHoist14 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(__xctestHoist14, 0)
        XCTAssertEqual(reply.workspaceCleanup, .removed)
        let __xctestHoist2 = await cleaning.removalAttempts.isEmpty
        XCTAssertFalse(__xctestHoist2)
        XCTAssertEqual(reply.quiescence.pendingLaunchCount, 0)
        XCTAssertEqual(reply.quiescence.targetOwnedWork, [])
    }

    func testCredentialQueueSurvivesUnboundVaultAndRecoversLater() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle,
                                           credentialDrain: nil)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "vault deferred")
        let account = "acctdefer1"
        try await stores.database.writer { db in
            try db.execute(sql: """
                INSERT INTO credential_records (id, kind, owner_kind, conversation_id,
                    label, keychain_account, synchronizable, device_bound,
                    created_at, updated_at)
                VALUES (?, 'genericToken', 'conversation', ?, 'token', ?, 0, 0, 'x', 'x')
                """, arguments: [UUID().uuidString, record.id.uuidString, account])
        }
        let reply = try await bundle.domain.delete(
            conversationID: record.id, revision: try await revision(bundle, record.id))
        XCTAssertEqual(reply.credentialDrain, .deferredUnbound)
        let queued = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue WHERE keychain_account = ?",
            StatementArguments([account]))
        XCTAssertEqual(queued, 1,
                       "the V11 trigger row is the durable process-death intent")

        // Later vault binding drains the REAL surviving queue.
        let drain = RecordingCredentialDrain(database: stores.database)
        let summary = await drain.drainDeletionQueue()
        XCTAssertEqual(summary.drained, 1)
        let __xctestHoist15 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist15, 0)
    }

    func testWorkspaceCleanupFailureStaysQueuedAndRetryCompletes() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let cleaning = try TempWorkspaceCleaning(failOnce: true)
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle,
                                           workspaceCleaning: cleaning)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "cleanup retry")
        _ = try await stores.workspaces.ensureWorkspace(conversationID: record.id,
                                                        title: "cleanup retry")
        let directory = try cleaning.seedPrivateTaskDirectory(conversationID: record.id)
        let reply = try await bundle.domain.delete(
            conversationID: record.id, revision: try await revision(bundle, record.id))
        XCTAssertEqual(reply.workspaceCleanup, .failed("cleanupThrew"))
        // The durable V36 queue row REMAINS (process-death recoverable).
        let __xctestHoist16 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup WHERE relative_path LIKE ?",
            StatementArguments(["PrivateTasks/%"]))
        XCTAssertEqual(__xctestHoist16, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        // Launch-retry sweep completes the removal through the ORIGINAL
        // store bookkeeping + the same host port.
        let failures = await bundle.domain.retryPendingLocalWorkspaceCleanup()
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let __xctestHoist17 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(__xctestHoist17, 0)
    }

    // MARK: Drain-window semantics (CH-R1)

    func testLegitimateFinalOwnedWritesDuringDrainAreAllowed() async throws {
        let stores = try await RB3TestBed.stores()
        let record = try await RB3TestBed.seedOrdinary(stores, title: "final writes")
        let conversations = stores.conversations
        let lifecycle = ScriptedLifecycle()
        // The owned run service flushes a final assistant message INSIDE
        // the drain window (appendMessage also advances conversations
        // .updated_at — ConversationStore.swift:412-416). This is the exact
        // legitimate-write case the admission requires to pass.
        lifecycle.midDrain = {
            let flush = PersistedMessage(id: UUID(), conversationID: record.id,
                                         role: "assistant", content: "final flush",
                                         createdAt: Date())
            try await conversations.appendMessage(flush)
        }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let reply = try await bundle.domain.delete(
            conversationID: record.id,
            revision: try await revision(bundle, record.id))
        XCTAssertTrue(reply.quiescence.launchesFenced)
        let __xctestHoist18 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist18)
        let __xctestHoist19 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist19, 0,
            "the final flush is cascade-deleted with the conversation")
    }

    func testExternalMetadataMutationDuringDrainIsStaleAndZeroEffect() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let victimID = UUID()
        lifecycle.midDrain = {
            // NOT an owned producer: an external writer renames mid-flight
            // straight through SQLite (bypassing the facade scope). The
            // in-writer expected-row CAS must observe it.
            try await stores.database.writer { db in
                try db.execute(sql: "UPDATE conversations SET title = 'external hijack' WHERE id = ?",
                               arguments: [victimID.uuidString])
            }
        }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "before", id: victimID)
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "keep me")
        try await stores.database.writer { db in
            try Self.insertMemoryFixture(db, conversationID: record.id)
        }
        let rev = try await revision(bundle, record.id)
        do {
            _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
            XCTFail("external metadata drift must abort the delete")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let survivorRaw = try await stores.conversations.conversation(id: record.id)
        let survivor = try XCTUnwrap(survivorRaw)
        XCTAssertEqual(survivor.title, "external hijack",
                       "abort must leave EVERY row (including the drift) untouched")
        let __xctestHoist20 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist20, 1)
        // CH-R1: the stale refusal happened before memory preservation.
        let memory = try await Self.memoryFields(stores.database, conversationID: record.id)
        XCTAssertEqual(memory.conversationID, record.id.uuidString)
        XCTAssertNil(memory.originOwnerLabel)
        XCTAssertNil(memory.ownerDeletedAt)
        let __xctestHoist21 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist21, 0,
            "aborted delete must not fire the V11 trigger")
        let __xctestHoist22 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(__xctestHoist22, 0,
            "aborted delete must not fire the V36 trigger")
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("commit:") }.count, 0)
    }

    func testSameWriterCASRejectsOtherRawColumnDriftAndPreservesOwnedResources() async throws {
        // A different raw-column drift (archived_at + is_searchable, neither
        // is updated_at) must also be refused by the SAME in-writer CAS, and
        // the memory/credential/workspace owned resources must survive.
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let cleaning = try TempWorkspaceCleaning()
        let victimID = UUID()
        lifecycle.midDrain = {
            try await stores.database.writer { db in
                try db.execute(sql: """
                    UPDATE conversations
                    SET archived_at = '2026-01-01T00:00:00.000Z', is_searchable = 0
                    WHERE id = ?
                    """, arguments: [victimID.uuidString])
            }
        }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle,
                                           workspaceCleaning: cleaning)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "raw drift", id: victimID)
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "body")
        try await stores.database.writer { db in
            try Self.insertMemoryFixture(db, conversationID: record.id)
            try db.execute(sql: """
                INSERT INTO credential_records (id, kind, owner_kind, conversation_id,
                    label, keychain_account, synchronizable, device_bound,
                    created_at, updated_at)
                VALUES (?, 'genericToken', 'conversation', ?, 'token', 'acctrawdrift',
                    0, 0, 'x', 'x')
                """, arguments: [UUID().uuidString, record.id.uuidString])
        }
        _ = try await stores.workspaces.ensureWorkspace(conversationID: record.id,
                                                        title: "raw drift")
        let directory = try cleaning.seedPrivateTaskDirectory(conversationID: record.id)
        do {
            _ = try await bundle.domain.delete(
                conversationID: record.id,
                revision: try await revision(bundle, record.id))
            XCTFail("any non-updated_at raw-column drift must refuse")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let __xctestHoist23 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNotNil(__xctestHoist23)
        let memory = try await Self.memoryFields(stores.database, conversationID: record.id)
        XCTAssertEqual(memory.conversationID, record.id.uuidString)
        XCTAssertNil(memory.originOwnerLabel)
        let __xctestHoist24 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist24, 0)
        let __xctestHoist25 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM local_workspace_cleanup")
        XCTAssertEqual(__xctestHoist25, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)
    }

    func testRollbackKeepsCascadeMemoryAndSpoolAtomicThenRetrySucceeds() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "rollback")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "keep")
        let runID = UUID()
        try await RB3TestBed.seedRun(stores.database, conversationID: record.id, id: runID)
        try await stores.database.writer { db in
            try Self.insertMemoryFixture(db, conversationID: record.id)
        }

        // Real spool artifact under the canonical ORIGINAL spool root.
        guard let spoolRoot = BackgroundJobOutputSpoolRoot.url() else {
            throw XCTSkip("host has no canonical spool root")
        }
        try FileManager.default.createDirectory(at: spoolRoot,
                                                withIntermediateDirectories: true)
        let jobID = UUID()
        let spoolURL = spoolRoot.appendingPathComponent("\(jobID.uuidString).txt")
        try Data("spooled output".utf8).write(to: spoolURL)
        defer { try? FileManager.default.removeItem(at: spoolURL) }
        try await stores.database.writer { db in
            try db.execute(sql: """
                INSERT INTO background_jobs (id, conversation_id, run_id, kind,
                    target_tool, payload_json, state, created_at, updated_at,
                    output_path)
                VALUES (?, ?, ?, 'tool', 'exec.localPython', ?, 'completed',
                    'x', 'x', ?)
                """, arguments: [jobID.uuidString, record.id.uuidString,
                                 runID.uuidString, Data("{}".utf8),
                                 spoolURL.path])
        }

        // DB-level failure AFTER memory preservation + retention deletion
        // starts: the trigger aborts the DELETE statement, proving the whole
        // same-writer transaction rolls back atomically.
        try await stores.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER rb3_abort_conversation_delete
                BEFORE DELETE ON conversations
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic delete failure');
                END;
                """)
        }
        let rev = try await revision(bundle, record.id)
        do {
            _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
            XCTFail("the synthetic trigger must abort the delete transaction")
        } catch {
            // expected — original transaction rolled back
        }
        let __xctestHoist26 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNotNil(__xctestHoist26)
        let __xctestHoist27 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist27, 1)
        let rolledBackMemory = try await Self.memoryFields(stores.database,
                                                           conversationID: record.id)
        XCTAssertEqual(rolledBackMemory.conversationID, record.id.uuidString,
                       "memory UPDATE must roll back with the delete")
        XCTAssertNil(rolledBackMemory.originOwnerLabel)
        let __xctestHoist28 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM background_jobs WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist28, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolURL.path),
                      "spool removal happens only after a committed transaction")
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)

        // Drop the synthetic failure and retry: the durable state is intact
        // and the same revision still names the unchanged row.
        try await stores.database.writer { db in
            try db.execute(sql: "DROP TRIGGER rb3_abort_conversation_delete")
        }
        let reply = try await bundle.domain.delete(conversationID: record.id, revision: rev)
        XCTAssertEqual(reply.fenceSettlement, .released)
        let __xctestHoist29 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist29)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolURL.path),
                       "spool artifact is removed after the successful commit")
        let __xctestHoist30 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM background_jobs WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist30, 0)
        let __xctestHoist31 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM memory_entries WHERE origin_conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist31, 1)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("begin:") }.count, 2)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("commit:") }.count, 1)
    }

    func testOriginalDefaultDeleteCallerPathIsUnchanged() async throws {
        // The additive overload must not alter the existing default caller:
        // calling deleteConversation(id:) directly still performs the
        // ORIGINAL cascade and does NOT reclassify memory first (the memory
        // row is cascade-deleted exactly as before this lane).
        let stores = try await RB3TestBed.stores()
        let record = try await RB3TestBed.seedOrdinary(stores, title: "default caller")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "body")
        try await stores.database.writer { db in
            try Self.insertMemoryFixture(db, conversationID: record.id)
        }
        try await stores.conversations.deleteConversation(id: record.id)
        let __xctestHoist32 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist32)
        let __xctestHoist33 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist33, 0)
        let __xctestHoist34 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM memory_entries")
        XCTAssertEqual(__xctestHoist34, 0,
            "the default path keeps the original cascade semantics")
    }

    // MARK: CH-R2 — per-conversation evidence; never unrelated B

    func testDeleteARemainsIndependentOfUnrelatedActiveConversationB() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let a = try await RB3TestBed.seedOrdinary(stores, title: "A deleted")
        let b = try await RB3TestBed.seedOrdinary(stores, title: "B survives")
        let bToken = lifecycle.attachOwnedWork(conversationID: b.id, kind: .run, epoch: 1)
        // The GLOBAL epoch snapshot legitimately shows B's live run. It must
        // not gate A (the old CH-R2 mistake).
        lifecycle.countsProvider = { _ in
            ["run": 1, "childRun": 0, "tool": 0, "conversation": 0]
        }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let reply = try await bundle.domain.delete(
            conversationID: a.id, revision: try await revision(bundle, a.id))
        let __xctestHoist35 = try await stores.conversations.conversation(id: a.id)
        XCTAssertNil(__xctestHoist35)
        let __xctestHoist36 = try await stores.conversations.conversation(id: b.id)
        XCTAssertNotNil(__xctestHoist36,
                        "deleting A must never delete/cancel unrelated B")
        XCTAssertEqual(lifecycle.attachedTokens(for: b.id), [bToken],
                       "B's exact owned token remains attached and untouched")
        XCTAssertEqual(reply.quiescence.targetOwnedWork, [],
                       "only A's target evidence gates A")
        XCTAssertEqual(reply.fenceSettlement, .released)
        XCTAssertTrue(lifecycle.events.allSatisfy { !$0.contains(b.id.uuidString) },
                      "A's deletion lifecycle never names B: \(lifecycle.events)")
    }

    func testDeleteAwaitsOnlyTargetOwnedTokenTrueCompletion() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let a = try await RB3TestBed.seedOrdinary(stores, title: "A waits")
        let b = try await RB3TestBed.seedOrdinary(stores, title: "B active")
        let aToken = lifecycle.attachOwnedWork(conversationID: a.id, kind: .run, epoch: 1)
        let bToken = lifecycle.attachOwnedWork(conversationID: b.id, kind: .childRun, epoch: 1)
        lifecycle.detachTargetOnDrain = false
        let hold = RB3HoldBox(initial: true)
        lifecycle.holdDrain = { await hold.get() }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let done = RB3FlagBox()

        // Qualifier repair (2026-10-19): precompute the base revision and
        // capture the Sendable domain actor, not the non-Sendable bundle
        // (Swift 6 sending-closure rule). Same semantics.
        let revisionA = try await revision(bundle, a.id)
        let domain = bundle.domain
        let task = Task {
            let reply = try await domain.delete(conversationID: a.id, revision: revisionA)
            done.set(true)
            return reply
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("drainStart:") }.count, 1)
        XCTAssertFalse(done.value, "A's delete must wait for A's real token")
        XCTAssertEqual(lifecycle.attachedTokens(for: a.id), [aToken])
        XCTAssertEqual(lifecycle.attachedTokens(for: b.id), [bToken],
                       "B's in-flight work is never awaited or cancelled")

        // REAL completion of A's work, then release the drain.
        lifecycle.detachOwnedWork(aToken)
        await hold.set(false)
        let reply = try await task.value
        XCTAssertTrue(done.value)
        let __xctestHoist37 = try await stores.conversations.conversation(id: a.id)
        XCTAssertNil(__xctestHoist37)
        let __xctestHoist38 = try await stores.conversations.conversation(id: b.id)
        XCTAssertNotNil(__xctestHoist38)
        XCTAssertEqual(lifecycle.attachedTokens(for: b.id), [bToken])
        XCTAssertEqual(reply.quiescence.targetOwnedWork?.count, 1)
        XCTAssertEqual(reply.quiescence.targetOwnedWork?.first?.token, aToken)
        XCTAssertEqual(reply.quiescence.targetOwnedWork?.first?.stillAttached, false)
    }

    func testWrongConversationOrEpochEvidenceIsRefused() async throws {
        let scenarios = ["foreignConversation", "foreignTokenEpoch", "wrongReportConversation"]
        for scenario in scenarios {
            let stores = try await RB3TestBed.stores()
            let lifecycle = ScriptedLifecycle()
            let a = try await RB3TestBed.seedOrdinary(stores, title: "A")
            let b = try await RB3TestBed.seedOrdinary(stores, title: "B")
            let token = ScriptedLifecycle.token(seed: 7, epoch: 1,
                                                kind: .run, ownerID: b.id.uuidString)
            lifecycle.reportOverride = { fence in
                switch scenario {
                case "foreignConversation":
                    return ConversationQuiescenceReport(
                        conversationID: fence.conversationID, launchesFenced: true,
                        endCountsByKind: ScriptedLifecycle.drainedCounts(),
                        countsEpoch: fence.epoch,
                        targetOwnedWork: [ConversationOwnedWorkObservation(
                            conversationID: b.id, token: token, stillAttached: false)],
                        pendingLaunchCount: 0)
                case "foreignTokenEpoch":
                    let foreignEpochToken = ScriptedLifecycle.token(
                        seed: 8, epoch: fence.epoch &+ 1000,
                        kind: .run, ownerID: a.id.uuidString)
                    return ConversationQuiescenceReport(
                        conversationID: fence.conversationID, launchesFenced: true,
                        endCountsByKind: ScriptedLifecycle.drainedCounts(),
                        countsEpoch: fence.epoch,
                        targetOwnedWork: [ConversationOwnedWorkObservation(
                            conversationID: a.id, token: foreignEpochToken,
                            stillAttached: false)],
                        pendingLaunchCount: 0)
                default:
                    return ConversationQuiescenceReport(
                        conversationID: b.id, launchesFenced: true,
                        endCountsByKind: ScriptedLifecycle.drainedCounts(),
                        countsEpoch: fence.epoch,
                        targetOwnedWork: [],
                        pendingLaunchCount: 0)
                }
            }
            let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
            do {
                _ = try await bundle.domain.delete(
                    conversationID: a.id, revision: try await revision(bundle, a.id))
                XCTFail("\(scenario) must be refused")
            } catch let error as ConversationDomainError {
                switch scenario {
                case "foreignConversation":
                    XCTAssertEqual(error.wireCode, "runtimeUnavailable")
                    XCTAssertEqual(error.wireReason, "ownedWorkForeignConversation")
                case "foreignTokenEpoch":
                    XCTAssertEqual(error.wireCode, "sessionFenced")
                    XCTAssertEqual(error.wireReason, "ownedWorkForeignEpoch")
                default:
                    XCTAssertEqual(error.wireCode, "sessionFenced")
                    XCTAssertEqual(error.wireReason, "quiescenceConversationMismatch")
                }
            }
            let __xctestHoist39 = try await stores.conversations.conversation(id: a.id)
            XCTAssertNotNil(__xctestHoist39)
            let __xctestHoist40 = try await stores.conversations.conversation(id: b.id)
            XCTAssertNotNil(__xctestHoist40)
            XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)
        }
    }

    func testLateTargetAttachIsFencedAfterBegin() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let a = try await RB3TestBed.seedOrdinary(stores, title: "A fenced")
        let b = try await RB3TestBed.seedOrdinary(stores, title: "B free")
        let hold = RB3HoldBox(initial: true)
        lifecycle.holdDrain = { await hold.get() }
        let probe = RB3Flags()
        lifecycle.midDrain = { [weak lifecycle] in
            // The real RB4 fence must refuse a NEW launch/attach for A while
            // the deletion guard is held; B is unaffected.
            guard let lifecycle else { return }
            probe.set(lateTargetRefused: !lifecycle.attemptNewLaunch(conversationID: a.id),
                      otherStillAllowed: lifecycle.attemptNewLaunch(conversationID: b.id))
        }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let revisionA = try await revision(bundle, a.id)
        let domain = bundle.domain
        let task = Task {
            try await domain.delete(conversationID: a.id, revision: revisionA)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(lifecycle.currentGuard)
        XCTAssertEqual(probe.value.lateTargetRefused, true)
        XCTAssertEqual(probe.value.otherStillAllowed, true)
        await hold.set(false)
        _ = try await task.value
        let __xctestHoist41 = try await stores.conversations.conversation(id: a.id)
        XCTAssertNil(__xctestHoist41)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("commit:") }.count, 1)
    }

    // MARK: Concurrency + cancellation (CH-R3)

    func testConcurrentOperationsScopeSemantics() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let holdBox = RB3HoldBox(initial: true)
        lifecycle.holdDrain = { await holdBox.get() }
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let doomed = try await RB3TestBed.seedOrdinary(stores, title: "doomed")
        let fresh = try await RB3TestBed.seedOrdinary(stores, title: "fresh")
        let doomedRevision = try await revision(bundle, doomed.id)
        let freshRevision = try await revision(bundle, fresh.id)

        let domain = bundle.domain
        let deleteTask = Task {
            try await domain.delete(conversationID: doomed.id, revision: doomedRevision)
        }
        // Give the delete time to fence + enter the held drain.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("drainStart:") }.count, 1)

        // (1) A metadata mutation against the DELETING conversation is
        //     refused by the scope.
        do {
            _ = try await bundle.domain.rename(
                conversationID: doomed.id, revision: doomedRevision,
                payload: .object(["title": .string("late rename")]))
            XCTFail("mutation during deletion must be fenced")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "sessionFenced")
            XCTAssertEqual(error.wireReason, "conversationDeleting")
        }
        // (2) A second delete for the SAME conversation is refused as an
        //     in-flight duplicate (no double drain, no noop success).
        do {
            _ = try await bundle.domain.delete(conversationID: doomed.id,
                                               revision: doomedRevision)
            XCTFail("duplicate delete must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "duplicateInFlight")
        }
        // (3) READS still work during the drain window (navigation is not
        //     blocked by destructive scoping) — and other conversations are
        //     unaffected: the fresh revision is readable.
        let snapshot = try await bundle.domain.get(conversationID: fresh.id)
        XCTAssertEqual(snapshot.revision, freshRevision.version)

        await holdBox.set(false)
        _ = try await deleteTask.value
        let __xctestHoist42 = try await stores.conversations.conversation(id: doomed.id)
        XCTAssertNil(__xctestHoist42)
        // (4) A LATE echo delete of the (now gone) conversation cannot touch
        //     the OTHER/NEW conversation: same old token replay is typed
        //     notFound; fresh remains byte-identical.
        do {
            _ = try await bundle.domain.delete(conversationID: doomed.id,
                                               revision: doomedRevision)
            XCTFail("late echo delete must be typed gone")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "notFound")
        }
        let untouched = try await revision(bundle, fresh.id)
        XCTAssertEqual(untouched.version, freshRevision.version,
                       "late callbacks can neither delete nor clear another conversation's route")
    }

    func testCancellationDuringDrainKeepsEveryRowIntact() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        lifecycle.holdDrain = { true }   // never drains: caller must cancel
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "cancel me")
        try await RB3TestBed.seedMessage(stores, conversationID: record.id, content: "body")
        let rev = try await revision(bundle, record.id)

        let domain = bundle.domain
        let task = Task {
            try await domain.delete(conversationID: record.id, revision: rev)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled drain must abort")
        } catch is CancellationError {
            // expected — honoured BEFORE the commit.
        } catch {
            // Task.checkCancellation inside the double may surface as the
            // double's own error; rows below are the real assertion.
        }
        let __xctestHoist43 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNotNil(__xctestHoist43)
        let __xctestHoist44 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([record.id.uuidString]))
        XCTAssertEqual(__xctestHoist44, 1)
        let __xctestHoist45 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM credential_deletion_queue")
        XCTAssertEqual(__xctestHoist45, 0)
        // CH-R3: caller cancellation is NOT quiescence and the exact fence
        // was aborted (released) so a real retry can begin a NEW operation.
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)
        XCTAssertNil(lifecycle.currentGuard)
        lifecycle.holdDrain = { false }
        let retry = try await bundle.domain.delete(conversationID: record.id, revision: rev)
        XCTAssertEqual(retry.workspaceCleanup, .none)
        XCTAssertEqual(retry.fenceSettlement, .released)
        let __xctestHoist46 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist46)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("begin:") }.count, 2)
    }

    func testDrainFailureAbortsExactFenceAndRetrySucceeds() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        lifecycle.drainFailure = .drainUnavailable("syntheticDrain")
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "drain failure")
        let rev = try await revision(bundle, record.id)
        do {
            _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
            XCTFail("a failed drain must fail closed")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
            XCTAssertEqual(error.wireReason, "deletionDrainUnavailable:syntheticDrain")
        }
        let __xctestHoist47 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNotNil(__xctestHoist47)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("abort:") }.count, 1)
        XCTAssertNil(lifecycle.currentGuard)

        // The surviving conversation can relaunch (a new operation begins)
        // once the authority drain is healthy again.
        lifecycle.drainFailure = nil
        let reply = try await bundle.domain.delete(conversationID: record.id, revision: rev)
        XCTAssertEqual(reply.fenceSettlement, .released)
        let __xctestHoist48 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist48)
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("begin:") }.count, 2)
    }

    func testBeginFailureLeavesRowsUntouchedAndRegistersNoFence() async throws {
        let cases: [(ConversationDeletionLifecycleFailure, String, String?)] = [
            (.fenceHeld, "duplicateInFlight", nil),
            (.epochMismatch, "sessionFenced", "deletionFenceEpochMismatch"),
            (.ownerUnavailable("authorityDown"), "runtimeUnavailable",
             "deletionOwnerUnavailable:authorityDown"),
        ]
        for (failure, code, reason) in cases {
            let stores = try await RB3TestBed.stores()
            let lifecycle = ScriptedLifecycle()
            lifecycle.beginFailure = failure
            let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
            let record = try await RB3TestBed.seedOrdinary(stores, title: "begin failure")
            do {
                _ = try await bundle.domain.delete(
                    conversationID: record.id,
                    revision: try await revision(bundle, record.id))
                XCTFail("begin failure \(failure) must refuse")
            } catch let error as ConversationDomainError {
                XCTAssertEqual(error.wireCode, code)
                XCTAssertEqual(error.wireReason, reason)
            }
            let __xctestHoist49 = try await stores.conversations.conversation(id: record.id)
            XCTAssertNotNil(__xctestHoist49)
            XCTAssertNil(lifecycle.currentGuard)
            XCTAssertTrue(lifecycle.events.isEmpty,
                          "a failed atomic begin registers nothing: \(lifecycle.events)")
        }
    }

    func testOldAbortCannotClearNewerGuardAndForeignTokenRefuses() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        lifecycle.drainFailure = .drainUnavailable("firstAttempt")
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "guard generations")
        let rev = try await revision(bundle, record.id)
        do {
            _ = try await bundle.domain.delete(conversationID: record.id, revision: rev)
            XCTFail("first attempt must fail")
        } catch {}
        guard let oldFence = lifecycle.fences.first else {
            return XCTFail("first begin fence missing")
        }
        XCTAssertNil(lifecycle.currentGuard)

        // Second operation holds a NEW guard.
        lifecycle.drainFailure = nil
        let hold = RB3HoldBox(initial: true)
        lifecycle.holdDrain = { await hold.get() }
        let domain = bundle.domain
        let task = Task {
            try await domain.delete(conversationID: record.id, revision: rev)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let newFence = lifecycle.currentGuard else {
            return XCTFail("new guard missing")
        }
        XCTAssertNotEqual(oldFence, newFence)

        // An OLD settled token is idempotent and cannot clear the new guard.
        let oldSettlement = await lifecycle.abortDeletionFence(oldFence)
        XCTAssertEqual(oldSettlement, .alreadySettled)
        XCTAssertEqual(lifecycle.currentGuard, newFence)

        // A fabricated/foreign token is refused and touches nothing.
        let foreign = ConversationDeletionFence(
            conversationID: record.id, epoch: 1,
            operationID: UUID(), authorityReceipt: "fence:v1:foreign")
        let foreignSettlement = await lifecycle.abortDeletionFence(foreign)
        XCTAssertEqual(foreignSettlement, .refusedForeignToken)
        XCTAssertEqual(lifecycle.currentGuard, newFence)
        XCTAssertEqual(lifecycle.events.filter { $0.hasSuffix(":refused") }.count, 1)

        await hold.set(false)
        let reply = try await task.value
        XCTAssertEqual(reply.fenceSettlement, .released)
        let __xctestHoist50 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist50)
    }

    func testPostCommitFenceSettlementIsReportedHonestly() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        lifecycle.commitSettlementOverride = .unavailable("authorityGone")
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "postcommit")
        let reply = try await bundle.domain.delete(
            conversationID: record.id,
            revision: try await revision(bundle, record.id))
        // The DB commit is the source of truth; the failed guard release is
        // reported honestly and remains recoverable, never re-deleted.
        let __xctestHoist51 = try await stores.conversations.conversation(id: record.id)
        XCTAssertNil(__xctestHoist51)
        XCTAssertEqual(reply.fenceSettlement, .unavailable("authorityGone"))
        XCTAssertNotNil(lifecycle.currentGuard,
                        "an unavailable settlement does not fake a release")
        XCTAssertEqual(lifecycle.events.filter { $0.hasSuffix(":unavailable") }.count, 1)
    }

    // MARK: Notes independence + schema invariants

    func testNotesConversationsAreForeignAndSurviveOrdinaryDeletion() async throws {
        let stores = try await RB3TestBed.stores()
        let lifecycle = ScriptedLifecycle()
        let bundle = RB3TestBed.makeDomain(stores: stores, lifecycle: lifecycle)
        let notes = ConversationRecord(id: UUID(), title: "Notes doc assistant",
                                       createdAt: Date(), updatedAt: Date(),
                                       purpose: .notes)
        try await stores.conversations.saveConversation(notes)
        try await RB3TestBed.seedMessage(stores, conversationID: notes.id, content: "notes body")
        let ordinary = try await RB3TestBed.seedOrdinary(stores, title: "ordinary gone")

        // This API cannot even see the notes row: same typed denial as
        // absent, so no probing oracle leaks its existence.
        let notesRevision = try await RB3TestBed.revision(stores.database, notes.id)
        do { _ = try await bundle.domain.get(conversationID: notes.id)
             XCTFail("get(notes) must be denied") }
        catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do { _ = try await bundle.domain.rename(conversationID: notes.id,
                                                revision: notesRevision,
                                                payload: .object(["title": .string("x")]))
             XCTFail() }
        catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        do { _ = try await bundle.domain.delete(conversationID: notes.id,
                                                revision: notesRevision)
             XCTFail() }
        catch let error as ConversationDomainError { XCTAssertEqual(error.wireCode, "notFound") }
        XCTAssertEqual(lifecycle.events.count, 0,
                       "denied foreign deletes must not fence/drain anything")

        // Deleting the ordinary conversation leaves Notes storage intact.
        _ = try await bundle.domain.delete(
            conversationID: ordinary.id,
            revision: try await revision(bundle, ordinary.id))
        let __xctestHoist52 = try await stores.conversations.conversation(id: notes.id)
        XCTAssertNotNil(__xctestHoist52)
        let __xctestHoist53 = try await RB3TestBed.count(stores.database,
            "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
            StatementArguments([notes.id.uuidString]))
        XCTAssertEqual(__xctestHoist53, 1)
    }

    func testTemporaryPurposeIsNotPersistableAtAll() async throws {
        let stores = try await RB3TestBed.stores()
        do {
            try await stores.database.writer { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at, purpose)
                    VALUES (?, 'temp', 'x', 'y', 'temporary')
                    """, arguments: [UUID().uuidString])
            }
            XCTFail("schema V41 CHECK must reject persisting 'temporary'")
        } catch is GRDB.DatabaseError {
            // expected: temporary chat storage is RAM-only BY SCHEMA; the
            // facade therefore has no temporary persistence path to guard.
        }
    }

    // MARK: Fixture helpers

    struct MemoryFields {
        let conversationID: String?
        let originOwnerLabel: String?
        let ownerDeletedAt: String?
    }

    private static func memoryFields(_ database: DatabaseManager,
                                     conversationID: UUID) async throws -> MemoryFields {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT conversation_id, origin_owner_label, owner_deleted_at
                FROM memory_entries WHERE origin_conversation_id = ? OR conversation_id = ?
                LIMIT 1
                """, arguments: [conversationID.uuidString, conversationID.uuidString]) else {
                throw RB3TestBed.RB3FixtureError("memory fixture missing")
            }
            return MemoryFields(conversationID: row["conversation_id"],
                                originOwnerLabel: row["origin_owner_label"],
                                ownerDeletedAt: row["owner_deleted_at"])
        }
    }

    /// Minimal memory_entries row (V7 base + V8 conversation_id,
    /// ON DELETE CASCADE — which is exactly why preservation must run
    /// FIRST in the same transaction).
    private static func insertMemoryFixture(_ db: Database, conversationID: UUID) throws {
        try db.execute(sql: """
            INSERT INTO memory_entries (id, scope, status, content, normalized_content,
                source_kind, created_at, updated_at, conversation_id)
            VALUES (?, 'user', 'active', 'synthetic fact', 'synthetic fact',
                'explicitUserRequest', 'x', 'y', ?)
            """, arguments: [UUID().uuidString, conversationID.uuidString])
    }
}

/// Small actor-isolated holder so a Swift 6 test can flip the drain-hold
/// flag while the double polls it (the holding itself stays inside the
/// DOUBLE — the production contract forbids timer-released drains).
actor RB3HoldBox {
    private var held: Bool
    init(initial: Bool) { held = initial }
    func get() -> Bool { held }
    func set(_ value: Bool) { held = value }
}

/// Lock-protected test flags (no XCTest assertions inside async closures).
final class RB3FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ value: Bool) { lock.lock(); flag = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class RB3Flags: @unchecked Sendable {
    private let lock = NSLock()
    private var flags = (lateTargetRefused: false, otherStillAllowed: false)
    func set(lateTargetRefused: Bool, otherStillAllowed: Bool) {
        lock.lock()
        flags = (lateTargetRefused, otherStillAllowed)
        lock.unlock()
    }
    var value: (lateTargetRefused: Bool, otherStillAllowed: Bool) {
        lock.lock(); defer { lock.unlock() }; return flags
    }
}
